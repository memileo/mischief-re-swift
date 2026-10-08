//
//  LiveHUD.swift
//  ArtQuickLookExtension
//
//  The single source of HUD truth for the live view.
//
//  Every pan / zoom / rotate / reset entry point funnels through `LiveHUD`, so the FPS
//  counter, the zoom readout and the transient "Reset view" message behave identically
//  no matter what triggered them. The HUD is deliberately separate from
//  `LivePreviewView` (which owns input and redraws) and from the renderer.
//

import Cocoa

// MARK: - Modes

/// What the user is doing right now. Drives the HUD label and what gets measured.
enum LiveInteractionMode: String {
    case idle, pan, zoom, rotate

    var label: String {
        switch self {
            case .idle:   return ""
            case .pan:    return "Pan"
            case .zoom:   return "Zoom"
            case .rotate: return "Rotate"
        }
    }

    /// Only zooming needs the percentage readout (that is when the number is
    /// actionable), plus the zoom reset which changes it.
    var showsZoomPercent: Bool { self == .zoom }
}

/// Which reset function ran, for the transient HUD message.
enum LiveResetKind: String {
    case all, pan, zoom, rotation

    var label: String {
        switch self {
            case .all:      return "Reset view"
            case .pan:      return "Reset pan"
            case .zoom:     return "Reset zoom"
            case .rotation: return "Reset rotation"
        }
    }
}

// MARK: - State

struct LiveHUDState: Equatable {
    var isVisible = false
    var mode: LiveInteractionMode = .idle
    var zoomPercent = 100.0
    var showZoomPercent = false
    var message: String?
    var fps: Double?
}

// MARK: - Controller

final class LiveHUDController {
    private(set) var state = LiveHUDState() {
        didSet {
            guard state != oldValue else { return }
            onChange?(state)
        }
    }
    /// Called on the main thread whenever `state` changes.
    var onChange: ((LiveHUDState) -> Void)?

    private let fpsWindow: CFTimeInterval = 0.4
    private var frameTimes: [CFTimeInterval] = []
    private var hideWork: DispatchWorkItem?
    private var interacting = false

    // MARK: The shared entry points — every interaction/reset function uses these

    /// A gesture started (mouse down on the middle button).
    func beginInteraction(_ mode: LiveInteractionMode, zoomPercent: Double) {
        interacting = true
        frameTimes.removeAll(keepingCapacity: true)
        cancelScheduledHide()
        apply(visible: true,
              mode: mode,
              zoomPercent: zoomPercent,
              showZoomPercent: mode.showsZoomPercent,
              message: nil,
              fps: nil)
    }

    /// A gesture moved. Called once per drag event.
    func updateInteraction(_ mode: LiveInteractionMode, zoomPercent: Double) {
        apply(visible: true,
              mode: mode,
              zoomPercent: zoomPercent,
              showZoomPercent: mode.showsZoomPercent,
              message: nil,
              fps: state.fps)
    }

    /// The gesture ended. The HUD stays up briefly so the final state is readable.
    func endInteraction(message: String? = nil, hold: TimeInterval = 0.6) {
        interacting = false
        apply(visible: true,
              mode: .idle,
              zoomPercent: state.zoomPercent,
              showZoomPercent: false,
              message: message,
              fps: state.fps)
        scheduleHide(after: hold)
    }

    /// One-shot feedback for a reset function (no drag involved).
    func announce(_ message: String, zoomPercent: Double, hold: TimeInterval = 0.8) {
        apply(visible: true,
              mode: .idle,
              zoomPercent: zoomPercent,
              showZoomPercent: false,
              message: message,
              fps: nil)
        scheduleHide(after: hold)
    }

    /// Called once per presented frame from the draw loop while the HUD is up.
    /// Keeps a rolling window of frame timestamps and derives the FPS readout.
    func registerFrame(at timestamp: CFTimeInterval, zoomPercent: Double) {
        guard state.isVisible else { return }

        frameTimes.append(timestamp)
        // Drop everything older than the window (keep one sample so a paused
        // sequence doesn't divide by zero).
        while let first = frameTimes.first, timestamp - first > fpsWindow {
            frameTimes.removeFirst()
        }

        var fps: Double?
        if let first = frameTimes.first, frameTimes.count > 1 {
            let span = timestamp - first
            if span > 0.0001 {
                fps = Double(frameTimes.count - 1) / span
            }
        }

        apply(visible: true,
              mode: state.mode,
              zoomPercent: zoomPercent,
              showZoomPercent: state.showZoomPercent,
              message: state.message,
              fps: fps)
    }

    /// Clears everything (used when the canvas is replaced / the view goes away).
    func reset() {
        interacting = false
        frameTimes.removeAll()
        cancelScheduledHide()
        state = LiveHUDState()
    }

    // MARK: Internals

    private func apply(visible: Bool,
                       mode: LiveInteractionMode,
                       zoomPercent: Double,
                       showZoomPercent: Bool,
                       message: String?,
                       fps: Double?) {
        state = LiveHUDState(isVisible: visible,
                             mode: mode,
                             zoomPercent: zoomPercent,
                             showZoomPercent: showZoomPercent,
                             message: message,
                             fps: fps)
    }

    private func scheduleHide(after delay: TimeInterval) {
        cancelScheduledHide()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.interacting else { return }
            self.frameTimes.removeAll()
            self.state = LiveHUDState()          // hidden + empty
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func cancelScheduledHide() {
        hideWork?.cancel()
        hideWork = nil
    }
}

// MARK: - Overlay

/// Draws `LiveHUDState` in the top-left corner. Never receives mouse events.
final class LiveHUDView: NSView {
    var state = LiveHUDState() {
        didSet {
            guard state != oldValue else { return }
            needsDisplay = true
        }
    }

    override var isFlipped: Bool { true }

    /// The live view underneath must keep receiving the middle-button drags.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    private static let padding: CGFloat = 8
    private static let cornerRadius: CGFloat = 5
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)

    override func draw(_ dirtyRect: NSRect) {
        // AppKit does not clear an opaque view's backing store for us, so wipe the
        // dirty rect even when there is nothing to draw — otherwise the last HUD frame
        // stays on screen after it hides.
        NSColor.clear.setFill()
        dirtyRect.fill()

        let lines = Self.textLines(for: state)
        guard state.isVisible, !lines.isEmpty else { return }

        let lineHeight = (Self.font.ascender - Self.font.descender) + 2
        let width = lines.map { $0.size().width }.max() ?? 0
        let boxSize = NSSize(width: width + Self.padding * 2,
                             height: lineHeight * CGFloat(lines.count) + Self.padding * 2)
        let box = NSRect(x: Self.padding, y: Self.padding, width: boxSize.width, height: boxSize.height)

        NSColor.black.withAlphaComponent(0.55).setFill()
        let path = NSBezierPath(roundedRect: box, xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        path.fill()

        for (index, line) in lines.enumerated() {
            let origin = NSPoint(x: box.minX + Self.padding,
                                 y: box.minY + Self.padding + lineHeight * CGFloat(index))
            line.draw(at: origin)
        }
    }

    /// HUD content: an optional mode label, the FPS readout while something is
    /// changing, the zoom percentage while zooming, and any transient message.
    static func textLines(for state: LiveHUDState) -> [NSAttributedString] {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white
        ]
        var parts: [String] = []
        if !state.mode.label.isEmpty { parts.append(state.mode.label) }
        if state.showZoomPercent {
            parts.append(String(format: "%.0f%%", state.zoomPercent))
        }
        if let fps = state.fps {
            parts.append(String(format: "%.0f fps", fps))
        }
        var lines: [NSAttributedString] = []
        if !parts.isEmpty {
            lines.append(NSAttributedString(string: parts.joined(separator: "   "),
                                            attributes: attributes))
        }
        if let message = state.message, !message.isEmpty {
            lines.append(NSAttributedString(string: message, attributes: attributes))
        }
        return lines
    }
}
