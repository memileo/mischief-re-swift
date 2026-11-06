//
//  LiveDocumentWindow.swift
//  ArtQuickLook
//
//  Opens an .art document in its own window, rendered with the live Metal view.
//
//  Why this exists
//  ---------------
//  A Quick Look preview is hosted out-of-process, which makes it an awkward target for
//  Instruments: Metal System Trace and the GPU Frame Debugger want a process you can
//  attach to, and the extension's process comes and goes with the preview panel. A normal
//  app window runs the *same* renderer and the *same* kernels in a process you can
//  profile — build ArtQuickLook, run it, open a document, then attach Instruments (or
//  Product ▸ Profile) to "ArtQuickLook".
//
//  It also makes the interactive path convenient to exercise by hand: pan/zoom/rotate with
//  the frame breakdown on screen, no Finder or Quick Look in the way.
//
//  Scope note
//  ----------
//  `LivePreviewView` (extension target) is the canonical live view. This is a deliberately
//  small copy: the two targets cannot share one file without adding it to both of them in
//  the Xcode project, and a profiling harness is not worth that. Keep the behaviour in step
//  with the extension, but do not treat this as the reference implementation.
//
//  Renderer API used (identical to the extension's):
//      Renderer.buildLiveRenderCache(art:scale:)          once per document
//      Renderer.renderLive(cache:art:camera:viewport:)    per view change
//      Renderer.presentLiveCanvas(_:to:transform:clearColor:)  per drawn frame
//

import SwiftUI
import MetalKit
import Metal
import QuartzCore
import CoreGraphics
import ArtParser
import ArtRenderLibrary

// MARK: - Window

/// One document per window; several may be open at once.
struct LiveDocumentWindow: View {
    let url: URL

    var body: some View {
        LiveDocumentContainer(url: url)
    }
}

/// SwiftUI shell: hosts the MTKView and shows its status line.
private struct LiveDocumentContainer: View {
    let url: URL
    @StateObject private var model = DocumentStatus()

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            LiveMTKViewRepresentable(url: url) { model.text = $0 }

            if let text = model.text {
                Text(text)
                    .font(.caption.monospaced())
                    .foregroundStyle(.white)
                    .padding(6)
                    .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                    .padding(10)
            }
        }
    }
}

/// The MTKView writes its frame readout here; SwiftUI observes it.
private final class DocumentStatus: ObservableObject {
    @Published var text: String?
}

// MARK: - Session

/// Owns the renderer + geometry cache for one document and re-rasterises on view changes.
///
/// Same shape as the extension's `LivePreviewSession`: exactly one render in flight,
/// requests coalesce to the newest state, and only finished values cross to the main
/// thread (the renderer itself never does — it stays on the render queue).
final class LiveDocumentSession {
    private let renderQueue = DispatchQueue(label: "org.potato.ArtQuickLook.document",
                                           qos: .userInitiated)
    var art: ArtParser
    private let canvasSize: CGSize
    private let scale: CGFloat

    // ── render queue only ──
    private var renderer: ArtRenderLibrary.Renderer?
    private var cache: LiveRenderCache?

    // ── main thread only ──
    private var latestRequest: Request?
    /// Display-link (or timer) pacing: exactly one render in flight, the newest request
    /// starts on the next display tick.
    private let pacer: LiveFramePacer
    /// Last time the status line was posted. Posting it on every frame makes SwiftUI
    /// re-lay-out a text view inside the present path at frame rate; 5 Hz reads the same
    /// and keeps the main thread free for the drawable handoff.
    private var lastStatusAt: CFTimeInterval = 0
    private static let statusInterval: CFTimeInterval = 0.2

    struct Request {
        let transform: LiveViewTransform
        let viewport: CGSize
    }

    /// Main thread: a finished canvas, the transform to present it with, and the renderer
    /// that produced it (it stays owned by this session's queue — only its reference is
    /// handed over, which is what makes presenting from the main thread safe).
    var onCanvas: ((LiveRenderedCanvas, LiveViewTransform, ArtRenderLibrary.Renderer?) -> Void)?
    /// Main thread: status line for the UI.
    var onStatus: ((String) -> Void)?

    init(url: URL) throws {
        guard let data = try? Data(contentsOf: url),
              let art = ArtParser(data: [UInt8](data)) else {
            throw NSError(domain: "ArtQuickLook", code: 1/*,
                          userDescription: "Could not read or parse \(url.lastPathComponent)"*/)
        }
        self.art = art
        // Same numbers the Quick Look preview uses. The canvas is the *reference* space the
        // geometry cache is built in; the interactive path then renders into a
        // viewport-sized canvas, so this only fixes the initial framing.
        let settings = Settings()
        self.scale = CGFloat(max(settings.previewScale, 0.25))
        self.canvasSize = CGSize(width: 1920, height: 1080)
        // Same cap the Quick Look preview honours (0 = uncapped).
        self.pacer = LiveFramePacer(maxFPS: settings.liveMaxFPS)
        self.pacer.onStart = { [weak self] in self?.startPendingRender() }
    }

    deinit {
        // Stop a display link that is still ticking if the window closes mid-gesture.
        pacer.invalidate()
    }

    // MARK: Requests (main thread)

    func invalidateCache() {
        cache = nil
    }

    func request(transform: LiveViewTransform, viewport: CGSize) {
        guard viewport.width >= 1, viewport.height >= 1 else { return }
        latestRequest = Request(transform: transform, viewport: viewport)
        pacer.request()
    }

    private func startPendingRender() {
        guard let request = latestRequest else { return }
        latestRequest = nil                 // coalesce: only the newest state survives
        run(request)
    }

    // MARK: Rendering (render queue)

    private func run(_ request: Request) {
        renderQueue.async { [weak self] in
            guard let self = self else { return }

            if self.renderer == nil {
                self.status("Building renderer…")
                self.renderer = ArtRenderLibrary.Renderer(
                    canvasSize: self.canvasSize,
                    scale: self.scale,
                    forceCPU: false,
                    useSegmentRendering: true)
            }
            guard let renderer = self.renderer else {
                self.status("Renderer unavailable")
                self.finish(timing: nil)
                return
            }

            // Interactive path: re-rasterise the cached document for the current camera.
            if self.cache == nil {
                self.status("Building geometry cache…")
                self.cache = renderer.buildLiveRenderCache(art: self.art, scale: self.scale)
            }
            if let cache = self.cache {
                let canvas = renderer.renderLive(cache: cache,
                                                 art: self.art,
                                                 camera: request.transform,
                                                 viewport: request.viewport)
                let timing = renderer.lastLiveFrameTiming
                // A viewport-sized canvas already contains the camera → present it 1:1.
                self.finish(canvas: canvas, transform: LiveViewTransform(), timing: timing)
                return
            }

            // Fallback: one document render, transformed while presenting.
            self.status("Geometry cache unavailable — single-raster mode")
            let canvas = renderer.renderLive(art: self.art)
            self.finish(canvas: canvas, transform: request.transform, timing: nil)
        }
    }

    private func finish(canvas: LiveRenderedCanvas? = nil,
                        transform: LiveViewTransform = LiveViewTransform(),
                        timing: LiveFrameTiming?) {
        let renderer = self.renderer
        DispatchQueue.main.async {
            // Present first: the drawable handoff should not wait on text layout.
            if let canvas { self.onCanvas?(canvas, transform, renderer) }
            if let timing {
                let now = CACurrentMediaTime()
                if now - self.lastStatusAt >= Self.statusInterval {
                    self.lastStatusAt = now
                    self.onStatus?(String(format: "%.0f ms  (bin %.0f · encode %.0f · gpu %.0f)"
                                          + "   %d strokes · %d segments · %d culled",
                                          timing.totalMilliseconds, timing.binMilliseconds,
                                          timing.encodeMilliseconds, timing.gpuMilliseconds,
                                          timing.strokes, timing.segments, timing.culledStrokes))
                }
            }
            self.pacer.renderFinished()
        }
    }

    private func status(_ message: String) {
        DispatchQueue.main.async { self.onStatus?(message) }
    }
}

// MARK: - MTKView

private struct LiveMTKViewRepresentable: NSViewRepresentable {
    let url: URL
    let onStatus: (String?) -> Void

    func makeNSView(context: Context) -> LiveMTKView {
        let view = LiveMTKView(url: url)
        view.onStatus = onStatus
        return view
    }

    func updateNSView(_ view: LiveMTKView, context: Context) {
        view.onStatus = onStatus
    }
}

/// The live view itself: a paused `MTKView` that draws when a canvas arrives or the
/// transform changed — never on a timer, so an idle window costs nothing.
final class LiveMTKView: MTKView, MTKViewDelegate {
    /// Wired up by the SwiftUI shell; called on the main thread. Setting it replays a
    /// message produced before the shell existed (e.g. a file that failed to parse).
    var onStatus: ((String?) -> Void)? {
        didSet { if let pending = pendingStatus { pendingStatus = nil; onStatus?(pending) } }
    }
    private var pendingStatus: String?

    private var canvas: LiveRenderedCanvas?
    private var viewTransform = LiveViewTransform()

    // Overlay ring around the rotation dead zone.
    private var rotateRingContainer: CALayer?
    private var rotateRingInner: CAShapeLayer?
    private var rotateRingOuter: CAShapeLayer?
    private var session: LiveDocumentSession?
    private var lastReportedViewport = CGSize.zero
    /// Set together with `canvas`; owned by the render queue, only used to present.
    private var presentingRenderer: ArtRenderLibrary.Renderer?
    private var commandQueue: MTLCommandQueue?

    // drag bookkeeping
    private var isDragging = false
    private var dragMode: Mode = .pan
    private var dragAnchor = CGPoint.zero
    private var lastDragLocation = CGPoint.zero
    private var dragButton: NSEvent.EventTypeMask = []
    private var dragMonitor: Any?
    /// When the last drag event arrived; a "button not pressed" reading is only believed
    /// after a quiet spell, because a Quick Look-style host can swallow the button-down.
    private var lastDragEventTime: CFTimeInterval = CACurrentMediaTime()
    private static let dragLapseGrace: TimeInterval = 3.0

    private enum Mode { case pan, zoom, rotate }

    // Per-point speeds, same feel as the Quick Look live view.
    private static let zoomSensitivity: CGFloat = 0.010
    private static let rotateSensitivity: CGFloat = 0.010
    private static let scrollZoomSensitivity: CGFloat = 0.060

    init(url: URL) {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        configure()   // configure() now also does: commandQueue = device?.makeCommandQueue()
        do {
            let session = try LiveDocumentSession(url: url)
            session.onStatus = { [weak self] message in self?.onStatus?(message) }
            session.onCanvas = { [weak self] canvas, transform, renderer in
                guard let self else { return }
                self.presentingRenderer = renderer
                self.canvas = canvas
                self.drawFrame()
            }
            self.session = session
        } catch {
            pendingStatus = error.localizedDescription
            DispatchQueue.main.async { [weak self] in self?.onStatus?(self?.pendingStatus) }
        }
    }

    // MetalKit quirk: MTKView redeclares initWithCoder: without `nullable`
    // (NSView's is failable, this one isn't), so the override must match.
    required init(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    private func configure() {
        commandQueue = device?.makeCommandQueue()
        
        framebufferOnly = true
        colorPixelFormat = .bgra8Unorm
        colorspace = nil
        clearColor = MTLClearColorMake(0.11, 0.11, 0.12, 1)
        autoResizeDrawable = true
        enableSetNeedsDisplay = true
        preferredFramesPerSecond = 60
        delegate = self
        isPaused = true
        let resetMenu = Self.makeResetMenu(target: self)
        resetMenu.delegate = self
        menu = resetMenu
    }

    // MARK: Draw

    private func drawFrame() {
        guard canvas != nil, window != nil else { return }
        display()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.drawFrame()
            self.reportChange()
        }
    }

    func draw(in view: MTKView) {
        if isDragging,
           !Self.isPressed(dragButton),
           CACurrentMediaTime() - lastDragEventTime > Self.dragLapseGrace {
            endDrag()
        }
        guard currentDrawable != nil else { return }
        
        // Nothing rendered yet (or a failure): show the clear colour instead of
        // an undefined drawable. The encoder does nothing on purpose — the pass
        // descriptor's loadAction is .clear, so committing it paints the background.
        guard let canvas, let renderer = presentingRenderer else {
            clearToBackground()
            return
        }
        
        guard let drawable = currentDrawable else { return }
        
        // A viewport-sized canvas was rasterised for the current camera already.
        let transform = canvas.isViewportRerendered ? LiveViewTransform() : viewTransform
        renderer.presentLiveCanvas(canvas, to: drawable,
                                   transform: transform,
                                   clearColor: clearColor)
        drawable.present()
    }
    
    /// `makeRenderCommandEncoder` and `commit` live on MTLCommandBuffer, not on
    /// MTKView — hence the dedicated queue + buffer here.
    private func clearToBackground() {
        guard let descriptor = currentRenderPassDescriptor,
              let commandBuffer = commandQueue?.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }
        
        encoder.endEncoding()
        if let drawable = currentDrawable {
            commandBuffer.present(drawable)   // MTKView doesn't present for you
        }
        commandBuffer.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        DispatchQueue.main.async { [weak self] in self?.reportChange() }
    }

    override func layout() {
        super.layout()
        ensureRotateRing()
        updateRotateRing()
        guard viewportSize != lastReportedViewport else { return }
        DispatchQueue.main.async { [weak self] in
            self?.drawFrame()
            self?.reportChange()
        }
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        super.resetCursorRects()
        if isDragging {
            addCursorRect(bounds, cursor: .closedHand)
        } else {
            addCursorRect(bounds, cursor: .arrow)
        }
    }

    // MARK: Input

    private var pixelScale: CGFloat { max(window?.backingScaleFactor ?? 1, 1) }

    /// Screen pixels, y down. Converted to the transform's y-up view space by
    /// `viewSpacePoint(_:)` — see `LiveViewSpace`.
    private func pixelLocation(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let scale = pixelScale
        let y = isFlipped ? point.y : (bounds.maxY - point.y)
        return CGPoint(x: point.x * scale, y: y * scale)
    }

    private func viewSpacePoint(_ screenPoint: CGPoint) -> CGPoint {
        LiveViewSpace.point(screenPoint, viewportHeight: viewportSize.height)
    }

    private var viewportSize: CGSize {
        let size = drawableSize
        return size.width > 0 && size.height > 0 ? size : .zero
    }

    private static func isPressed(_ mask: NSEvent.EventTypeMask) -> Bool {
        !mask.isEmpty && NSEvent.pressedMouseButtons & Int(mask.rawValue) != 0
    }

    private func mode(for flags: NSEvent.ModifierFlags) -> Mode {
        if flags.contains(.command) { return .zoom }
        if flags.contains(.shift) { return .rotate }
        return .pan
    }

    override func mouseDown(with event: NSEvent) {
        begin(mode: mode(for: event.modifierFlags),
              location: pixelLocation(of: event),
              button: .leftMouseDown)
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        drag(to: pixelLocation(of: event), mode: mode(for: event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) { endDrag() }

    override func otherMouseDown(with event: NSEvent) {
        begin(mode: mode(for: event.modifierFlags),
              location: pixelLocation(of: event),
              button: .otherMouseDown)
    }

    override func otherMouseDragged(with event: NSEvent) {
        drag(to: pixelLocation(of: event), mode: mode(for: event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) { endDrag() }

    override func scrollWheel(with event: NSEvent) {
        var delta = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas { delta *= 0.1 }
        guard delta != 0, viewportSize != .zero else {
            super.scrollWheel(with: event)
            return
        }
        let factor = exp(delta * Self.scrollZoomSensitivity)
        let anchor = viewSpacePoint(pixelLocation(of: event))
        commit { transform in
            transform.zoom(by: factor, anchor: anchor, viewportSize: viewportSize)
        }
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "0" where flags.isEmpty:
            commit { $0.resetAll() }
        case "p" where flags == [.command, .shift]:
            commit { $0.resetPan() }
        case "5" where flags.isEmpty:
            commit { $0.resetZoom() }
        case "r" where flags == [.command, .shift]:
            commit { $0.resetRotation() }
        default:
            super.keyDown(with: event)
        }
    }

    private func begin(mode: Mode, location: CGPoint, button: NSEvent.EventTypeMask) {
        isDragging = true
        dragMode = mode
        dragButton = button
        ensureRotateRing()
        rotateRingContainer?.isHidden = (mode != .rotate)
        dragAnchor = location
        lastDragLocation = location
        lastDragEventTime = CACurrentMediaTime()
        NSCursor.closedHand.set()
        NSCursor.closedHand.push()
        window?.invalidateCursorRects(for: self)

        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .otherMouseUp, .rightMouseUp]) { [weak self] event in
            self?.endDrag()
            return event
        }
    }

    private func drag(to location: CGPoint, mode eventMode: Mode) {
        guard isDragging else { return }
        
        // Keep the hand cursor for the whole press.
        NSCursor.closedHand.set()
        
        if eventMode != dragMode {
            dragMode = eventMode
            dragAnchor = location
            lastDragLocation = location
            rotateRingContainer?.isHidden = (dragMode != .rotate)
            return
        }
        lastDragEventTime = CACurrentMediaTime()
        let dx = location.x - lastDragLocation.x
        let dy = location.y - lastDragLocation.y
        
        let viewport = viewportSize
        
        // Teleport-induced jump: re-anchor instead of applying.
        if viewport.width > 0, (abs(dx) > viewport.width / 2 || abs(dy) > viewport.height / 2) {
            lastDragLocation = location
            return
        }
        
        let previous = lastDragLocation
        lastDragLocation = location
        guard dx != 0 || dy != 0 else {
            warpIfNeeded(location, viewport: viewport)
            return
        }
        
        let pointScale = pixelScale
        switch dragMode {
            case .pan:
                commit { $0.pan(by: LiveViewSpace.delta(CGPoint(x: dx, y: dy))) }
            case .zoom:
                let factor = exp(-(dy / pointScale) * Self.zoomSensitivity)
                let anchor = viewSpacePoint(dragAnchor)
                commit { $0.zoom(by: factor, anchor: anchor, viewportSize: viewport) }
            case .rotate:
                // Angular drag: the pointer pushes a disk pinned at the view centre.
                // Angular travel per pixel shrinks with radius, so edge drags are finer.
                let centre = LiveViewSpace.centre(viewportSize: viewport)
                guard
                    let from = dragAngle(at: previous, around: centre),
                    let to = dragAngle(at: location, around: centre)
                else {
                    // Pointer is parked in the hub dead zone; lastDragLocation is
                    // already updated, so the next event re-anchors cleanly.
                    return
                }
                var delta = to - from
                // Normalise to (-π, π] so crossing the atan2 seam doesn't spin the view.
                if delta > .pi { delta -= 2 * .pi }
                if delta < -.pi { delta += 2 * .pi }
                commit { $0.rotate(by: -delta, anchor: centre, viewportSize: viewport) }
        }
        
        warpIfNeeded(location, viewport: viewport)
    }
    
    /// Angle of a drag location around the view centre, in drag coordinates.
    /// Returns nil inside the hub dead zone, where the angle is unstable.
    private func dragAngle(at point: CGPoint, around centre: CGPoint) -> CGFloat? {
        let vx = point.x - centre.x
        let vy = point.y - centre.y
        guard hypot(vx, vy) > LiveViewSpace.minRotateRadius else { return nil }
        return atan2(vy, vx)
    }

    private func ensureRotateRing() {
        guard rotateRingContainer == nil else { return }
        guard let hostLayer = self.layer else { return }
        let container = CALayer()
        let inner = CAShapeLayer()
        let outer = CAShapeLayer()
        inner.fillColor = CGColor.clear
        inner.strokeColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)
        inner.lineWidth = 1.5
        outer.fillColor = CGColor.clear
        outer.strokeColor = CGColor(red: 1, green: 1, blue: 1, alpha: 1)
        outer.lineWidth = 1.5
        container.opacity = 0.5
        container.addSublayer(inner)
        container.addSublayer(outer)
        hostLayer.addSublayer(container)
        rotateRingContainer = container
        rotateRingInner = inner
        rotateRingOuter = outer
        container.isHidden = true
    }

    private func updateRotateRing() {
        guard let container = rotateRingContainer,
              let inner = rotateRingInner,
              let outer = rotateRingOuter else { return }
        container.frame = bounds
        let scale = pixelScale
        let radius = LiveViewSpace.minRotateRadius / scale
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        let segments = 128
        let twoPi: CGFloat = 2.0 * .pi

        let innerPath = CGMutablePath()
        for i in 0...segments {
            let t = CGFloat(i) / CGFloat(segments) * twoPi
            let px = centre.x + radius * cos(t)
            let py = centre.y + radius * sin(t)
            if i == 0 {
                innerPath.move(to: CGPoint(x: px, y: py))
            } else {
                innerPath.addLine(to: CGPoint(x: px, y: py))
            }
        }
        innerPath.closeSubpath()
        inner.path = innerPath

        let outerRadius = radius + (2.0 / scale)
        let outerPath = CGMutablePath()
        for i in 0...segments {
            let t = CGFloat(i) / CGFloat(segments) * twoPi
            let px = centre.x + outerRadius * cos(t)
            let py = centre.y + outerRadius * sin(t)
            if i == 0 {
                outerPath.move(to: CGPoint(x: px, y: py))
            } else {
                outerPath.addLine(to: CGPoint(x: px, y: py))
            }
        }
        outerPath.closeSubpath()
        outer.path = outerPath
    }

    private func endDrag() {
        guard isDragging else { return }
        isDragging = false
        dragButton = []
        rotateRingContainer?.isHidden = true
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
            dragMonitor = nil
        }
        NSCursor.pop()
        NSCursor.arrow.set()
        window?.invalidateCursorRects(for: self)
    }

    // MARK: - Cursor teleport (continuous drag past screen edges)

    private func warpIfNeeded(_ location: CGPoint, viewport: CGSize) {
        guard dragMode != .rotate else { return } // Disable warp for rotation
        guard viewport.width > 0, viewport.height > 0 else { return }
        let margin: CGFloat = 4
        var nearEdge = false
        var newLoc = location
        if location.x < margin {
            newLoc.x = viewport.width - margin
            nearEdge = true
        } else if location.x > viewport.width - margin {
            newLoc.x = margin
            nearEdge = true
        }
        if location.y < margin {
            newLoc.y = viewport.height - margin
            nearEdge = true
        } else if location.y > viewport.height - margin {
            newLoc.y = margin
            nearEdge = true
        }
        guard nearEdge else { return }
        lastDragLocation = newLoc
        warpCursor(to: newLoc)
    }

    private func warpCursor(to viewPixelPoint: CGPoint) {
        guard let window = window else { return }
        let scale = pixelScale
        let pointInView = NSPoint(x: viewPixelPoint.x / scale,
                                  y: isFlipped ? viewPixelPoint.y / scale
                                               : bounds.maxY - viewPixelPoint.y / scale)
        let pointInWindow = convert(pointInView, to: nil)
        let screenPoint = window.convertToScreen(NSRect(origin: pointInWindow, size: .zero)).origin
        let primaryHeight = NSScreen.screens.first?.frame.height ?? window.screen?.frame.height ?? 0
        let quartzPoint = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
        CGAssociateMouseAndMouseCursorPosition(0)
        CGWarpMouseCursorPosition(quartzPoint)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    // MARK: - Context menu

    @objc func resetView() { performReset(.all) }
    @objc func resetPanTransform() { performReset(.pan) }
    @objc func resetZoomTransform() { performReset(.zoom) }
    @objc func resetRotationTransform() { performReset(.rotation) }

    @objc func flipHorizontalTransform() {
        commit { $0.flipHorizontally() }
    }
    @objc func flipVerticalTransform() {
        commit { $0.flipVertically() }
    }

    private static func makeResetMenu(target: LiveMTKView) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Reset View", "0", [], #selector(LiveMTKView.resetView), target))
        menu.addItem(item("Reset Pan", "p", [.command, .shift], #selector(LiveMTKView.resetPanTransform), target))
        menu.addItem(item("Reset Zoom", "5", [], #selector(LiveMTKView.resetZoomTransform), target))
        menu.addItem(item("Reset Rotation", "r", [.command, .shift], #selector(LiveMTKView.resetRotationTransform), target))
        menu.addItem(.separator())
        let flipH = item("Flip Horizontal", "", [], #selector(LiveMTKView.flipHorizontalTransform), target)
        flipH.tag = 2001
        menu.addItem(flipH)
        let flipV = item("Flip Vertical", "", [], #selector(LiveMTKView.flipVerticalTransform), target)
        flipV.tag = 2002
        menu.addItem(flipV)
        return menu
    }

    private static func item(_ title: String, _ key: String, _ modifiers: NSEvent.ModifierFlags = [],
                             _ action: Selector, _ target: LiveMTKView) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = target
        return item
    }

    // MARK: Menu access
    //
    // The View menu drives the focused document window. Going through the responder chain
    // (`NSApp.keyWindow`'s content view) keeps the menu independent of which window or
    // coordinator owns the view.

    enum ResetKind { case all, pan, zoom, rotation }

    /// The live view in the key window, if any.
    static weak var lastFocusedDocumentView: LiveMTKView?
    static var focusedDocumentView: LiveMTKView? {
        guard let content = NSApp.keyWindow?.contentView else { return nil }
        if let found = findLiveMTKView(in: content) {
            lastFocusedDocumentView = found
            return found
        }
        return nil
    }

    /// The front-most document view, falling back to the only open document
    /// when nothing is key (so the layer panel keeps showing its contents).
    static var frontmostDocumentView: LiveMTKView? {
        if let focused = focusedDocumentView { return focused }
        if let last = lastFocusedDocumentView, last.window != nil {
            return last
        }
        // Collect document views across all windows.
        var candidates: [LiveMTKView] = []
        for window in NSApp.windows {
            if let cv = window.contentView, let v = findLiveMTKView(in: cv) { candidates.append(v) }
        }
        if candidates.count == 1 { return candidates.first }
        if let main = NSApp.mainWindow, let cv = main.contentView, let v = findLiveMTKView(in: cv) { return v }
        return candidates.first
    }

    static var hasFocusedDocument: Bool { focusedDocumentView != nil }

    static func resetFocused(_ kind: ResetKind) {
        guard let view = focusedDocumentView else { return }
        view.performReset(kind)
    }

    static func flipFocusedHorizontal() {
        focusedDocumentView?.flipHorizontalTransform()
    }
    static func flipFocusedVertical() {
        focusedDocumentView?.flipVerticalTransform()
    }

    static var focusedFlipHorizontal: Bool {
        focusedDocumentView?.viewTransform.flipHorizontal ?? false
    }
    static var focusedFlipVertical: Bool {
        focusedDocumentView?.viewTransform.flipVertical ?? false
    }

    private static func findLiveMTKView(in view: NSView) -> LiveMTKView? {
        if let live = view as? LiveMTKView { return live }
        for subview in view.subviews {
            if let live = findLiveMTKView(in: subview) { return live }
        }
        return nil
    }

    func performReset(_ kind: ResetKind) {
        switch kind {
        case .all:      commit { $0.resetAll() }
        case .pan:      commit { $0.resetPan() }
        case .zoom:     commit { $0.resetZoom(viewportSize: self.viewportSize) }
        case .rotation: commit { $0.resetRotation(viewportSize: self.viewportSize) }
        }
    }

    /// The one place a transform change turns into a new frame request.
    private func commit(_ mutate: (inout LiveViewTransform) -> Void) {
        let before = viewTransform
        mutate(&viewTransform)
        guard viewTransform != before else { return }
        reportChange()
    }

    private func reportChange() {
        let viewport = viewportSize
        guard viewport != .zero else { return }
        lastReportedViewport = viewport
        session?.request(transform: viewTransform, viewport: viewport)
    }
}

// MARK: - DocumentWindow

/// Opens one window per document — stand-in for `WindowGroup(id:for:)` +
/// `openWindow(id:value:)`, which don't exist until macOS 13.
final class DocumentWindowCoordinator {
    static let shared = DocumentWindowCoordinator()
    
    private var controllers: [URL: DocumentWindowController] = [:]
    
    func open(url: URL) {
        let key = url.standardizedFileURL
        
        // Already open: bring it to the front instead of duplicating it.
        if let controller = controllers[key] {
            NSApp.activate(ignoringOtherApps: true)
            controller.window?.makeKeyAndOrderFront(nil)
            return
        }
        
        // Only genuinely new documents enter the recents list — re-focusing an
        // open document does not, matching standard app behaviour. This is the
        // one open path (menu, Finder, dock drop, Open With…, Open Recent).
        AppController.shared.addRecentDocument(key)
        
        let controller = DocumentWindowController(url: key) { [weak self] in
            self?.controllers.removeValue(forKey: key)
        }
        controllers[key] = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }
}

final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    private let url: URL
    private let onClose: () -> Void
    
    init(url: URL, onClose: @escaping () -> Void) {
        self.url = url
        self.onClose = onClose
        
        // was .defaultSize(width: 1100, height: 800)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 800),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        
        // Call the configuration helper on the window
        window.configureAsArtDocument(url: url)
        
        super.init(window: window)
        
        // was .frame(minWidth: 480, minHeight: 360)
        window.contentMinSize = NSSize(width: 1280, height: 720)
        window.contentViewController = NSHostingController(rootView: LiveDocumentWindow(url: url))
        window.title = url.lastPathComponent
        window.isReleasedWhenClosed = false   // we own it; freed with the controller
        window.center()
        window.delegate = self
    }
    
    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
    
    func windowWillClose(_ notification: Notification) {
        // Defer so the controller isn't torn down mid-close.
        DispatchQueue.main.async(execute: onClose)
    }
    
    @objc override func newWindowForTab(_ sender: Any?) {
        AppController.shared.openDocument(sender)
    }
}

extension LiveMTKView: NSMenuDelegate {
    public func menuWillOpen(_ menu: NSMenu) {
        for item in menu.items {
            if item.tag == 2001 {
                item.state = viewTransform.flipHorizontal ? .on : .off
            } else if item.tag == 2002 {
                item.state = viewTransform.flipVertical ? .on : .off
            }
        }
    }
}

// MARK: - Layer stack (app only)

extension LiveMTKView {
    /// The parsed document currently shown by this view, if any.
    var currentArt: ArtParser? { session?.art }

    /// Mutate a layer's stored visibility/opacity in the underlying document.
    func setLayerVisible(_ id: Int, _ visible: Bool) {
        guard let session = session, id < session.art.layers.count else { return }
        session.art.layers[id]["visible"] = visible ? 1 : 0
    }
    func setLayerOpacity(_ id: Int, _ opacity: Float) {
        guard let session = session, id < session.art.layers.count else { return }
        session.art.layers[id]["opacity"] = opacity
    }

    /// Re-render after a layer visibility/opacity edit.
    func reportChangeAfterLayerEdit() { reportChange() }

    /// Drop the live geometry cache so a newly un-hidden layer gets rebuilt.
    func invalidateLiveCache() { session?.invalidateCache() }
}

final class LayerStackModel: ObservableObject {
    static let shared = LayerStackModel()

    struct LayerRow: Identifiable {
        let id: Int
        var name: String
        var isVisible: Bool
        var opacity: Double
    }

    @Published var layers: [LayerRow] = []
    @Published var selectedLayerIndex: Int?

    private var observer: NSObjectProtocol?

    private init() {
        observer = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        refresh()
    }

    func refresh() {
        guard let view = LiveMTKView.frontmostDocumentView, let art = view.currentArt else {
            layers = []
            selectedLayerIndex = nil
            return
        }
        let order = art.layerOrder.isEmpty ? Array(art.layers.indices) : art.layerOrder.reversed()
        var rows: [LayerRow] = []
        for idx in order {
            guard idx < art.layers.count else { continue }
            let layer = art.layers[idx]
            let name = (layer["name"] as? String) ?? "Layer \(idx + 1)"
            // Hidden Sketch layers (free transform pastes) are not part of
            // art.layerOrder, so iterating layerOrder already excludes them.
            let visible = (layer["visible"] as? Int ?? 1) != 0
            let opacity = Double(layer["opacity"] as? Float ?? 1.0)
            rows.append(LayerRow(id: idx, name: name, isVisible: visible, opacity: opacity))
        }
        let previous = selectedLayerIndex
        layers = rows
        if let previous, rows.contains(where: { $0.id == previous }) {
            selectedLayerIndex = previous
        } else {
            selectedLayerIndex = rows.first?.id
        }
    }

    func toggleVisibility(_ id: Int) {
        guard let view = LiveMTKView.frontmostDocumentView, let art = view.currentArt else { return }
        guard id < art.layers.count else { return }
        let current = (view.currentArt?.layers[id]["visible"] as? Int ?? 1) != 0
        let turningVisible = !current
        view.setLayerVisible(id, !current)
        if turningVisible {
            view.invalidateLiveCache()
        }
        if let i = layers.firstIndex(where: { $0.id == id }) {
            layers[i].isVisible = !current
            layers = layers
        }
        view.reportChangeAfterLayerEdit()
    }

    func setOpacity(_ id: Int, _ value: Double) {
        guard let view = LiveMTKView.frontmostDocumentView, let art = view.currentArt else { return }
        guard id < art.layers.count else { return }
        view.setLayerOpacity(id, Float(value))
        if let i = layers.firstIndex(where: { $0.id == id }) {
            layers[i].opacity = value
            layers = layers
        }
        view.reportChangeAfterLayerEdit()
    }
}

struct LayerStackView: View {
    @ObservedObject var model: LayerStackModel

    var body: some View {
        VStack(spacing: 2) {
            if model.layers.isEmpty {
                Text("No document")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(selection: $model.selectedLayerIndex) {
                    ForEach(model.layers) { row in
                        HStack {
                            Button(action: { model.toggleVisibility(row.id) }) {
                                Image(systemName: row.isVisible ? "eye" : "eye.slash")
                                    .opacity(row.isVisible ? 1.0 : 0.4)
                            }
                            .buttonStyle(.borderless)
                            Text(row.name)
                                .foregroundStyle(row.isVisible ? .primary : .secondary)
                                .opacity(row.isVisible ? 1.0 : 0.4)
                            if row.opacity < 0.999 {
                                Text(String(format: "%.0f%%", row.opacity * 100))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                        .tag(row.id)
                    }
                }
                .listStyle(.inset)

                if let sel = model.selectedLayerIndex,
                   let row = model.layers.first(where: { $0.id == sel }) {
                    VStack(alignment: .leading) {
                        HStack {
                            Text("Opacity")
//                                .font(.caption)
                            Text(String(format: "%.0f%%", row.opacity * 100))
//                                .font(.caption)
//                                .foregroundStyle(.secondary)
                        }
                        Slider(value: Binding(
                            get: { row.opacity },
                            set: { model.setOpacity(sel, $0) }
                        ), in: 0...1)
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 4)
                }
            }
        }
        .frame(minWidth: 148, idealWidth: 164, minHeight: 148, idealHeight: 182)
    }
}

final class LayerStackPanelController {
    static let shared = LayerStackPanelController()
    private var panel: NSPanel?

    func toggle() {
        if panel == nil { create() }
        guard let panel = panel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            LayerStackModel.shared.refresh()
            panel.makeKeyAndOrderFront(nil)
        }
    }

    private func create() {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 420),
                            styleMask: [.titled, .closable, .resizable, .utilityWindow, .hudWindow, .unifiedTitleAndToolbar],
                            backing: .buffered, defer: false)
        panel.title = "Layers"
        panel.contentViewController = NSHostingController(rootView: LayerStackView(model: LayerStackModel.shared))
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
//        panel.hidesOnDeactivate = false
        self.panel = panel
    }
}
