//
//  LivePreviewView.swift
//  ArtQuickLookExtension
//
//  The interactive live preview: an MTKView that presents the already-composited
//  canvas through a pan / zoom / rotate view transform.
//
//  Design notes
//  - The document is rendered **once** into GPU textures (`Renderer.renderLive`).
//    Panning / zooming / rotating only rewrites a small uniform buffer, so the view
//    can be redrawn at display rate without touching the CPU compositor.
//  - `isPaused = true` by default: frames are produced only when something changes
//    (a drag, a reset, a resize, a freshly installed canvas).
//  - All input funnels through `commitTransform(...)`, which mutates the transform,
//    tells the shared HUD and schedules a redraw — one code path for gestures and
//    resets alike.
//

import Cocoa
import MetalKit
import ArtRenderLibrary

final class LivePreviewView: MTKView, MTKViewDelegate {

    // MARK: - Model

    private var canvas: LiveRenderedCanvas?
    private var renderer: ArtRenderLibrary.Renderer?
    private var viewTransform = LiveViewTransform()

    private let hud = LiveHUDController()
    private lazy var hudView: LiveHUDView = {
        let view = LiveHUDView(frame: .zero)
        view.autoresizingMask = [.width, .height]
        return view
    }()

    // Drag bookkeeping
    private var isDragging = false
    private var dragMode: LiveInteractionMode = .pan
    private var dragAnchor = CGPoint.zero        // grab point, in view pixels
    private var lastDragLocation = CGPoint.zero  // previous event, in view pixels

    // Redraw gating
    private var pauseWork: DispatchWorkItem?

    // Gesture tuning (per **point** of mouse travel, so the feel is the same on
    // Retina and non-Retina; the transform itself works in pixels)
    private static let zoomSensitivity: CGFloat = 0.010     // exp factor per point
    private static let rotateSensitivity: CGFloat = 0.010  // radians per point
    private static let interactionHold: TimeInterval = 0.35
    private static let resetHold: TimeInterval = 0.5

    private static var isMiddleButtonDown: Bool {
        NSEvent.pressedMouseButtons & Int(NSEvent.EventTypeMask.otherMouseDown.rawValue) != 0
    }

    // MARK: - Init

    /// Note: this class deliberately declares **no** initializers, so it inherits every
    /// MTKView initializer (`init(frame:device:)`, `init?(coder:)`, …) unchanged and
    /// there is no chance of clashing with MTKView's designated initializers.
    /// Use `make(device:)` so the view is configured before it is used.
    static func make(device: MTLDevice) -> LivePreviewView {
        let view = LivePreviewView(frame: .zero, device: device)
        view.configure()
        return view
    }

    private var isConfigured = false

    private func configure() {
        guard !isConfigured else { return }
        isConfigured = true

        framebufferOnly = true
        colorPixelFormat = .bgra8Unorm
//        isOpaque = true // readonly
        clearColor = MTLClearColorMake(0.11, 0.11, 0.12, 1)
        autoResizeDrawable = true
        enableSetNeedsDisplay = true
        preferredFramesPerSecond = 60
        delegate = self
        isPaused = true                    // only refresh when something changes
        menu = Self.makeResetMenu(target: self)
        addSubview(hudView)
        hud.onChange = { [weak self] state in self?.hudView.state = state }
    }

    // MARK: - Canvas

    /// Installs a freshly rendered canvas (called on the main thread).
    func install(canvas: LiveRenderedCanvas, renderer: ArtRenderLibrary.Renderer) {
        self.canvas = canvas
        self.renderer = renderer
        viewTransform = LiveViewTransform()     // show the file's own view matrix first
        hud.reset()
        // The view may only just have been sized; let the drawable catch up first.
        refreshFrameSoon()
    }

    // MARK: - Public API (status + reset functions)

    /// Transient status line through the same HUD the gestures use (e.g. "Rendering…"
    /// while the GPU canvas is being built).
    func showStatus(_ message: String, hold: TimeInterval = 1.5) {
        hud.announce(message, zoomPercent: viewTransform.zoomPercent, hold: hold)
    }

    /// Back to the view matrix stored in the file: no pan, 100% zoom, no rotation.
    @objc func resetView() { performReset(.all) }
    /// Pan only.
    @objc func resetPanTransform() { performReset(.pan) }
    /// Zoom only.
    @objc func resetZoomTransform() { performReset(.zoom) }
    /// Rotation only.
    @objc func resetRotationTransform() { performReset(.rotation) }

    private func performReset(_ kind: LiveResetKind) {
        commitTransform(mode: .idle) { viewTransform in
            switch kind {
                case .all:      viewTransform.resetAll()
                case .pan:      viewTransform.resetPan()
                case .zoom:     viewTransform.resetZoom()
                case .rotation: viewTransform.resetRotation()
            }
        }
        hud.announce(kind.label, zoomPercent: viewTransform.zoomPercent, hold: Self.resetHold)
        // Let a few frames through so the FPS readout covers the reset too, and keep
        // rendering for as long as the HUD stays up.
        beginContinuousUpdates()
        endContinuousUpdates(after: Self.resetHold)
    }

    // MARK: - The shared funnel

    /// The single place a transform change becomes a HUD update + redraw.
    private func commitTransform(mode: LiveInteractionMode,
                                 _ mutate: (inout LiveViewTransform) -> Void) {
        let before = viewTransform
        mutate(&viewTransform)
        guard viewTransform != before else { return }
        hud.updateInteraction(mode, zoomPercent: viewTransform.zoomPercent)
        refreshFrame()
    }

    // MARK: - Redraw gating

    private func refreshFrame() {
        guard canvas != nil else { return }
        if isPaused {
            // `display()` alone gives one immediate frame (a paused MTKView routes it
            // to the delegate). Adding setNeedsDisplay(true) as well would schedule a
            // second, redundant frame — and inflate the FPS readout.
            display()
        }
    }

    /// For cases where the drawable is not ready *yet* (resize, just-added view).
    private func refreshFrameSoon() {
        DispatchQueue.main.async { [weak self] in self?.refreshFrame() }
    }

    private func beginContinuousUpdates() {
        pauseWork?.cancel()
        pauseWork = nil
        if isPaused { isPaused = false }
    }

    private func endContinuousUpdates(after delay: TimeInterval = LivePreviewView.interactionHold) {
        pauseWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self = self, !self.isDragging else { return }
            self.isPaused = true
        }
        pauseWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // The drawable is resized *after* this callback, so refresh on the next turn of
        // the run loop instead of drawing into the old (possibly zero-sized) drawable.
        refreshFrameSoon()
    }

    func draw(in view: MTKView) {
        // The middle button can be released outside the view, in which case no
        // `otherMouseUp` is delivered here. We are redrawing every frame while dragging
        // (the HUD is up), so this is a cheap place to notice.
        if isDragging && !Self.isMiddleButtonDown {
            finishDrag()
        }

        guard let canvas = canvas, let renderer = renderer else { return }
        let timestamp = CACurrentMediaTime()
        guard let drawable = currentDrawable else { return }

        renderer.presentLiveCanvas(canvas, to: drawable, transform: viewTransform,
                                  clearColor: clearColor)
        drawable.present()

        hud.registerFrame(at: timestamp, zoomPercent: viewTransform.zoomPercent)
    }

    // MARK: - Layout / focus

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        configure()                     // no-op when built through make(device:)
        guard window != nil else {
            hud.reset()
            return
        }
        window?.makeFirstResponder(self)
        refreshFrameSoon()
    }

//    override func acceptsFirstResponder() -> Bool { true }

    override func layout() {
        super.layout()
        hudView.frame = bounds
    }

    // MARK: - Middle-button interaction

    /// Event location → **view pixels, y down**.
    ///
    /// NSEvent locations are AppKit coordinates (origin bottom-left, y up) and
    /// `MTKView.isFlipped` is false, whereas the transform maths (and the canvas
    /// texture row order) is y-down top-left — hence the vertical flip here.
    private func pixelLocation(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
//        let scale = contentScaleFactor
        let scale = 1.0
        return CGPoint(x: point.x * scale,
                       y: (bounds.maxY - point.y) * scale)
    }

    /// mmb pan, mmb+cmd zoom, mmb+shift rotate (cmd wins over shift).
    private func mode(for flags: NSEvent.ModifierFlags) -> LiveInteractionMode {
        if flags.contains(.command) { return .zoom }
        if flags.contains(.shift) { return .rotate }
        return .pan
    }

    private var viewportSize: CGSize {
        let size = drawableSize
        return size.width > 0 && size.height > 0 ? size : CGSize(width: 1, height: 1)
    }

    override func otherMouseDown(with event: NSEvent) {
        isDragging = true
        dragMode = mode(for: event.modifierFlags)
        let location = pixelLocation(of: event)
        dragAnchor = location
        lastDragLocation = location
        hud.beginInteraction(dragMode, zoomPercent: viewTransform.zoomPercent)
        beginContinuousUpdates()
//        NSCursor.closed.set() // Type 'NSCursor' has no member 'closed'
    }

    override func otherMouseDragged(with event: NSEvent) {
        guard isDragging else { return }
        let location = pixelLocation(of: event)
        let eventMode = mode(for: event.modifierFlags)

        // Modifiers pressed/released mid-drag: re-anchor at the current location so the
        // gesture continues from where the pointer is instead of jumping.
        if eventMode != dragMode {
            dragMode = eventMode
            dragAnchor = location
            lastDragLocation = location
            hud.updateInteraction(dragMode, zoomPercent: viewTransform.zoomPercent)
            return
        }

        let dx = location.x - lastDragLocation.x
        let dy = location.y - lastDragLocation.y
        lastDragLocation = location
        guard dx != 0 || dy != 0 else { return }

        let viewport = viewportSize
        // Zoom/rotate speeds are specified per point; the deltas arrive in pixels.
        let pointScale = max(1.0, 1) // Cannot find 'contentScaleFactor' in scope
        switch dragMode {
            case .pan:
                commitTransform(mode: .pan) { viewTransform in
                    viewTransform.pan(by: CGPoint(x: dx, y: dy))
                }
            case .zoom:
                let factor = exp(-(dy / pointScale) * Self.zoomSensitivity)
                commitTransform(mode: .zoom) { viewTransform in
                    viewTransform.zoom(by: factor, anchor: dragAnchor, viewportSize: viewport)
                }
            case .rotate:
                let delta = (dx / pointScale) * Self.rotateSensitivity
                commitTransform(mode: .rotate) { viewTransform in
                    viewTransform.rotate(by: delta, anchor: dragAnchor, viewportSize: viewport)
                }
            case .idle:
                break
        }
    }

    override func otherMouseUp(with event: NSEvent) {
        finishDrag()
    }

    private func finishDrag() {
        guard isDragging else { return }
        isDragging = false
        NSCursor.arrow.set()
        // HUD and redraw stop together so the FPS number never freezes on screen.
        hud.endInteraction(hold: Self.interactionHold)
        endContinuousUpdates(after: Self.interactionHold)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.charactersIgnoringModifiers?.lowercased() {
            case "0": resetView()
            case "p": resetPanTransform()
            case "z": resetZoomTransform()
            case "r": resetRotationTransform()
            default: super.keyDown(with: event)
        }
    }

    // MARK: - Context menu

    /// Right-click menu with the reset functions. Assigned to the inherited `menu`
    /// property in `configure()` (it is readwrite on NSView, so it cannot be overridden
    /// with a read-only computed property).
    private static func makeResetMenu(target: LivePreviewView) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Reset View", "0", #selector(LivePreviewView.resetView), target))
        menu.addItem(item("Reset Pan", "p", #selector(LivePreviewView.resetPanTransform), target))
        menu.addItem(item("Reset Zoom", "z", #selector(LivePreviewView.resetZoomTransform), target))
        menu.addItem(item("Reset Rotation", "r", #selector(LivePreviewView.resetRotationTransform), target))
        return menu
    }

    private static func item(_ title: String, _ key: String,
                             _ action: Selector, _ target: LivePreviewView) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
}
