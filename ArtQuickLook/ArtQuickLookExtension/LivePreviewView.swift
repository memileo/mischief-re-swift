//
//  LivePreviewView.swift
//  ArtQuickLookExtension
//
//  The interactive live preview surface: an MTKView plus input handling, a HUD and the
//  reset functions.
//
//  Design notes
//  - The document itself is owned by `LivePreviewSession`. This view only owns the
//    **view transform** (pan / zoom / rotate) and reports changes:
//        `onRenderRequest(transform, viewport)` → session re-rasterises
//        `present(canvas, transform, drawable, clearColor)` → session draws
//    In interactive mode a canvas already contains the camera, so it is presented 1:1;
//    in the single-raster fallback the live transform is used instead.
//  - Frame pacing is owned by `LivePreviewSession` (`LiveFramePacer`), not by MTKView:
//    the session uses its own `CVDisplayLink` (with a timer fallback) to start renders
//    just after a flip, and the view still draws when a canvas arrives, when the
//    transform changes in fallback mode, or on a resize. That keeps the gesture
//    responsive inside a Quick Look panel, where MTKView's CADisplayLink is not
//    something we can rely on.
//  - All input funnels through `commitTransform(...)`, which mutates the transform, tells
//    the shared HUD and asks for a refresh — one code path for gestures and resets alike.
//  - Bindings: left drag pans (shift → rotate, cmd → zoom), middle drag pans (cmd → zoom,
//    shift → rotate), the scroll wheel zooms at the pointer, and 0/P/Z/R + the context menu
//    do the resets.
//

import Cocoa
import CoreGraphics
import MetalKit
import QuartzCore        // CACurrentMediaTime
import ArtRenderLibrary

final class LivePreviewView: MTKView, MTKViewDelegate {

    // MARK: - Wiring to the session

    /// Something changed: re-rasterise the document for this transform + viewport
    /// (viewport in device pixels).
    var onRenderRequest: ((LiveViewTransform, CGSize) -> Void)?
    /// Draw a canvas into a drawable. The transform is the one to present with.
    var present: ((LiveRenderedCanvas, LiveViewTransform, MTLDrawable, MTLClearColor) -> Void)?

    // MARK: - Model

    private var canvas: LiveRenderedCanvas?
    private var viewTransform = LiveViewTransform()

    private let hud = LiveHUDController()
    private lazy var hudView: LiveHUDView = {
        let view = LiveHUDView(frame: .zero)
        view.autoresizingMask = [.width, .height]
        return view
    }()

    /// Drag bookkeeping
    private var isDragging = false
    private var dragMode: LiveInteractionMode = .pan
    private var dragAnchor = CGPoint.zero        // grab point, in view pixels
    private var lastDragLocation = CGPoint.zero  // previous event, in view pixels
    /// The `…MouseDown` mask of the button that started the current drag, so a release
    /// outside the view can be detected from `pressedMouseButtons`.
    private var dragButtonMask: NSEvent.EventTypeMask = []
    /// Local monitor used to notice a button release that happens outside this view
    /// (in which case no `…MouseUp` is delivered here). Removed in `endDrag()`.
    private var dragMonitor: Any?
    /// When the last drag event arrived — see `dragLapseGrace`.
    private var lastDragEventTime: CFTimeInterval = CACurrentMediaTime()

    /// Viewport (device pixels) last reported to the session.
    private var reportedViewport = CGSize.zero
    /// Tracks the last frame we counted for the FPS readout, so a redundant
    /// `display()` of an unchanged canvas/transform is not counted twice.
    private var lastCountedCanvas: LiveRenderedCanvas?
    private var lastCountedTransform = LiveViewTransform()

    // Gesture tuning (per **point** of mouse travel, so the feel is the same on Retina
    // and non-Retina; the transform itself works in pixels)
    private static let zoomSensitivity: CGFloat = 0.010     // exp factor per point
    private static let rotateSensitivity: CGFloat = 0.010  // radians per point
    /// `scrollWheel` reports lines, not points; converted to an exp factor here.
    private static let scrollZoomSensitivity: CGFloat = 0.060
    private static let interactionHold: TimeInterval = 0.35
    private static let resetHold: TimeInterval = 0.5

    /// A drag button can be released outside the view, in which case no `…MouseUp` is
    /// delivered here — `draw(in:)` notices and ends the gesture.
    ///
    /// Only trusted *after* the drag has been quiet for a moment (see `dragLapseGrace`):
    /// inside a Quick Look host `pressedMouseButtons` can read empty while the user is
    /// still dragging, which used to cancel the gesture after its first frame.
    private static func isPressed(_ mask: NSEvent.EventTypeMask) -> Bool {
        !mask.isEmpty && NSEvent.pressedMouseButtons & Int(mask.rawValue) != 0
    }

    /// How long a drag must be silent before a "button not down" reading is believed.
    private static let dragLapseGrace: TimeInterval = 1.0

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
        colorspace = nil
        clearColor = MTLClearColorMake(0.11, 0.11, 0.12, 1)
        autoResizeDrawable = true
        enableSetNeedsDisplay = true
        preferredFramesPerSecond = 60
        delegate = self
        isPaused = true                    // nothing redraws unless something asks
        menu = Self.makeResetMenu(target: self)
        addSubview(hudView)
        hud.onChange = { [weak self] state in self?.hudView.state = state }
    }

    // MARK: - Canvas

    var hasCanvas: Bool { canvas != nil }

    /// Installs a freshly rendered canvas (main thread).
    func install(canvas: LiveRenderedCanvas) {
        let first = self.canvas == nil
        self.canvas = canvas
        if first {
            viewTransform = LiveViewTransform()   // show the file's view matrix first
            hud.reset()
        }
        refreshFrameSoon()
    }

    /// Transient status line through the same HUD the gestures use.
    func showStatus(_ message: String, hold: TimeInterval = 1.5) {
        hud.announce(message, zoomPercent: viewTransform.zoomPercent, hold: hold)
    }

    /// Asks the session for the document at the current transform. Safe to call before
    /// the view has a window: the first report happens as soon as the viewport is known.
    func requestFirstRender() {
        if viewportSize != .zero {
            reportChange()
        } else {
            pendingFirstRender = true
        }
    }

    private var pendingFirstRender = false

    // MARK: - Public API (reset functions)

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
    }

    // MARK: - The shared funnel

    /// The single place a transform change becomes a HUD update + a redraw request.
    private func commitTransform(mode: LiveInteractionMode,
                                 _ mutate: (inout LiveViewTransform) -> Void) {
        let before = viewTransform
        mutate(&viewTransform)
        guard viewTransform != before else { return }
        hud.updateInteraction(mode, zoomPercent: viewTransform.zoomPercent)
        // The session decides what this means: a re-render (interactive mode) or just a
        // redraw of the same canvas with the new transform (single-raster fallback).
        // Deliberately no extra frame here — presenting a stale canvas would make the
        // FPS readout lie about how fast the view actually updates.
        reportChange()
    }

    /// Asks the session for the current state, and remembers the viewport we reported.
    private func reportChange() {
        let viewport = viewportSize
        guard viewport != .zero else { return }
        reportedViewport = viewport
        pendingFirstRender = false
        onRenderRequest?(viewTransform, viewport)
    }

    // MARK: - Redraw

    /// Redraw the current canvas once (no re-render).
    func refresh() {
        refreshFrame()
    }

    private func refreshFrame() {
        guard canvas != nil else { return }
        // `display()` alone gives one immediate frame (a paused MTKView routes it to the
        // delegate). Adding setNeedsDisplay(true) as well would schedule a second,
        // redundant frame — and inflate the FPS readout.
        display()
    }

    /// For cases where the drawable is not ready *yet* (resize, just-installed canvas).
    private func refreshFrameSoon() {
        DispatchQueue.main.async { [weak self] in self?.refreshFrame() }
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        // The drawable is resized *after* this callback, so ask the session on the next
        // turn of the run loop instead of drawing into the old (possibly 0-sized) one.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.refreshFrameSoon()
            if self.pendingFirstRender || (size != self.reportedViewport && self.canvas != nil) {
                self.reportChange()
            }
        }
    }

    func draw(in view: MTKView) {
        // A drag button can be released outside the view, in which case no `…MouseUp` is
        // delivered here. Guarded by the grace period: a single frame with an empty
        // `pressedMouseButtons` is not proof of a release (the Quick Look host can swallow
        // the button-down), and acting on it killed the gesture after one frame.
        if isDragging,
           !Self.isPressed(dragButtonMask),
           CACurrentMediaTime() - lastDragEventTime > Self.dragLapseGrace {
            endDrag()
        }

        guard let canvas = canvas, let present = present else { return }
        guard let drawable = currentDrawable else { return }

        // A viewport-sized canvas was rasterised for the current camera already.
        let transform = canvas.isViewportRerendered ? LiveViewTransform() : viewTransform
        present(canvas, transform, drawable, clearColor)
        drawable.present()

        // Count this as a displayed frame update (timestamp taken after present).
        hud.registerFrame(at: CACurrentMediaTime(), zoomPercent: viewTransform.zoomPercent)
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
        // The viewport is only known now: ask for the first frame.
        refreshFrameSoon()
        reportChange()
    }

    override func layout() {
        super.layout()
        hudView.frame = bounds
        if viewportSize != reportedViewport {
            refreshFrameSoon()
            if canvas != nil { reportChange() }
        }
    }

    // MARK: - Pointer interaction
    //
    // Two equivalent bindings, so the view feels normal on a trackpad-less mouse as well
    // as with one that has a middle button:
    //
    //   left button          pan           (shift → rotate, cmd → zoom)
    //   middle button        pan           (cmd → zoom, shift → rotate)
    //   scroll wheel         zoom at the pointer

    /// Backing scale of the window (the target's SDK does not expose
    /// `NSView.contentScaleFactor`).
    private var pixelScale: CGFloat {
        max(window?.backingScaleFactor ?? 1, 1)
    }

    /// Event location → **screen pixels, y down** (view pixel scale applied).
    ///
    /// This is still AppKit's y-down space. Turning it into the transform's y-up view space
    /// is `LiveViewSpace.point(_:viewportHeight:)`, done by the gesture code below — that
    /// split is deliberate, because the conversion belongs next to the gesture maths it
    /// feeds (`LiveViewTransform.clipMatrix` maps view pixels y-up to the drawable).
    ///
    /// AppKit event coordinates are y-up for a non-flipped view, so the y axis is mirrored
    /// here — but only when the receiver is actually not flipped (`MTKView`'s flippedness
    /// differs between OS/SDK versions, so ask instead of assuming).
    private func pixelLocation(of event: NSEvent) -> CGPoint {
        let point = convert(event.locationInWindow, from: nil)
        let scale = pixelScale
        let y = isFlipped ? point.y : (bounds.maxY - point.y)
        return CGPoint(x: point.x * scale, y: y * scale)
    }

    /// Screen point → the transform's view space (see `LiveViewSpace`).
    private func viewSpacePoint(_ screenPoint: CGPoint) -> CGPoint {
        LiveViewSpace.point(screenPoint, viewportHeight: viewportSize.height)
    }

    /// Modifiers pick the mode; cmd wins over shift.
    private func mode(for flags: NSEvent.ModifierFlags) -> LiveInteractionMode {
        if flags.contains(.command) { return .zoom }
        if flags.contains(.shift) { return .rotate }
        return .pan
    }

    private var viewportSize: CGSize {
        let size = drawableSize
        return size.width > 0 && size.height > 0 ? size : .zero
    }

    // ── Left button ──

    override func mouseDown(with event: NSEvent) {
        beginDrag(mode: mode(for: event.modifierFlags),
                  location: pixelLocation(of: event),
                  button: .leftMouseDown)
        // A left drag is a pan, not a selection, so the view must not also start a text
        // selection or hand the event back to the window.
        window?.makeFirstResponder(self)
    }

    override func mouseDragged(with event: NSEvent) {
        drag(to: pixelLocation(of: event), mode: mode(for: event.modifierFlags))
    }

    override func mouseUp(with event: NSEvent) {
        endDrag()
    }

    // ── Middle button ──

    override func otherMouseDown(with event: NSEvent) {
        beginDrag(mode: mode(for: event.modifierFlags),
                  location: pixelLocation(of: event),
                  button: .otherMouseDown)
    }

    override func otherMouseDragged(with event: NSEvent) {
        drag(to: pixelLocation(of: event), mode: mode(for: event.modifierFlags))
    }

    override func otherMouseUp(with event: NSEvent) {
        endDrag()
    }

    // ── Scroll wheel ──

    override func scrollWheel(with event: NSEvent) {
        // Natural scrolling can invert the sign; `hasPreciseScrollingDeltas` means points
        // instead of lines, so the sensitivity is calibrated for lines and scaled.
        var delta = event.scrollingDeltaY
        if event.hasPreciseScrollingDeltas { delta *= 0.1 }

        guard delta != 0, viewportSize != .zero else {
            super.scrollWheel(with: event)
            return
        }
        // Scrolling up zooms in, anchored at the pointer (converted to view space).
        let factor = exp(delta * Self.scrollZoomSensitivity)
        let anchor = viewSpacePoint(pixelLocation(of: event))
        commitTransform(mode: .zoom) { viewTransform in
            viewTransform.zoom(by: factor, anchor: anchor, viewportSize: viewportSize)
        }
    }

    // ── Shared drag handling ──

    private func beginDrag(mode: LiveInteractionMode,
                           location: CGPoint,
                           button: NSEvent.EventTypeMask) {
        // `NSEvent.EventTypeMask.leftMouseDown` / `.otherMouseDown` — note that `.left` and
        // `.other` are `NSEvent.ButtonType` cases, not mask cases.
        isDragging = true
        dragMode = mode
        dragButtonMask = button
        dragAnchor = location
        lastDragLocation = location
        lastDragEventTime = CACurrentMediaTime()
        hud.beginInteraction(mode, zoomPercent: viewTransform.zoomPercent)
        NSCursor.closedHand.set()

        // Notice a release that lands outside this view (no `…MouseUp` delivered here).
        dragMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp, .otherMouseUp, .rightMouseUp]) { [weak self] event in
            self?.endDrag()
            return event
        }
    }

    private func drag(to location: CGPoint, mode eventMode: LiveInteractionMode) {
        guard isDragging else { return }

        // Keep the hand cursor for the whole press, even if the host resets it.
        NSCursor.closedHand.set()

        // Modifiers pressed/released mid-drag: re-anchor at the current location so the
        // gesture continues from where the pointer is instead of jumping.
        if eventMode != dragMode {
            dragMode = eventMode
            dragAnchor = location
            lastDragLocation = location
            hud.updateInteraction(dragMode, zoomPercent: viewTransform.zoomPercent)
            return
        }

        lastDragEventTime = CACurrentMediaTime()
        let dx = location.x - lastDragLocation.x
        let dy = location.y - lastDragLocation.y

        let viewport = viewportSize

        // A teleport-induced jump (cursor warped to the other side) must not be
        // applied as a giant delta — just re-anchor.
        if viewport.width > 0, (abs(dx) > viewport.width / 2 || abs(dy) > viewport.height / 2) {
            lastDragLocation = location
            return
        }

        lastDragLocation = location
        guard dx != 0 || dy != 0 else {
            warpIfNeeded(location, viewport: viewport)
            return
        }

        // Zoom/rotate speeds are specified per point; the deltas arrive in pixels.
        let pointScale = pixelScale
        switch dragMode {
            case .pan:
                // y is negated: dragging down on screen must move content down, and view
                // space is y-up (LiveViewSpace).
                commitTransform(mode: .pan) { viewTransform in
                    viewTransform.pan(by: LiveViewSpace.delta(CGPoint(x: dx, y: dy)))
                }
            case .zoom:
                let factor = exp(-(dy / pointScale) * Self.zoomSensitivity)
                let anchor = viewSpacePoint(dragAnchor)
                commitTransform(mode: .zoom) { viewTransform in
                    viewTransform.zoom(by: factor, anchor: anchor, viewportSize: viewport)
                }
            case .rotate:
                // Rotation is about the middle of the view, not the pointer: rotating from
                // an edge then moves a lot, rotating near the centre almost not at all,
                // which makes it far easier to line a shape up. No y sign flip needed here —
                // see LiveViewSpace.
                let delta = (dx / pointScale) * Self.rotateSensitivity
                let centre = LiveViewSpace.centre(viewportSize: viewport)
                commitTransform(mode: .rotate) { viewTransform in
                    viewTransform.rotate(by: delta, anchor: centre, viewportSize: viewport)
                }
            case .idle:
                break
        }

        // Teleport the cursor to the opposite edge when it reaches one, so a drag can
        // continue past the screen edge (Blender-style).
        warpIfNeeded(location, viewport: viewport)
    }

    // MARK: - Cursor teleport (continuous drag past screen edges)

    private func warpIfNeeded(_ location: CGPoint, viewport: CGSize) {
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
        let pointInWindow: NSPoint
        if isFlipped {
            pointInWindow = NSPoint(x: viewPixelPoint.x / scale,
                                    y: viewPixelPoint.y / scale)
        } else {
            pointInWindow = NSPoint(x: viewPixelPoint.x / scale,
                                    y: bounds.maxY - viewPixelPoint.y / scale)
        }
        let screenPoint = window.convertToScreen(NSRect(origin: pointInWindow, size: .zero)).origin
        let primaryHeight = NSScreen.screens.first?.frame.height ?? window.screen?.frame.height ?? 0
        let quartzPoint = CGPoint(x: screenPoint.x, y: primaryHeight - screenPoint.y)
        CGAssociateMouseAndMouseCursorPosition(0)
        CGWarpMouseCursorPosition(quartzPoint)
        CGAssociateMouseAndMouseCursorPosition(1)
    }

    private func endDrag() {
        guard isDragging else { return }
        isDragging = false
        dragButtonMask = []
        if let monitor = dragMonitor {
            NSEvent.removeMonitor(monitor)
            dragMonitor = nil
        }
        NSCursor.arrow.set()
        hud.endInteraction(hold: Self.interactionHold)
    }

    // MARK: - Context menu

    /// Right-click menu with the reset functions. Assigned to the inherited `menu`
    /// property in `configure()` (it is readwrite on NSView, so it cannot be overridden
    /// with a read-only computed property).
    private static func makeResetMenu(target: LivePreviewView) -> NSMenu {
        let menu = NSMenu()
        menu.addItem(item("Reset View", "", #selector(LivePreviewView.resetView), target))
        menu.addItem(item("Reset Pan", "", #selector(LivePreviewView.resetPanTransform), target))
        menu.addItem(item("Reset Zoom", "", #selector(LivePreviewView.resetZoomTransform), target))
        menu.addItem(item("Reset Rotation", "", #selector(LivePreviewView.resetRotationTransform), target))
        return menu
    }

    private static func item(_ title: String, _ key: String,
                             _ action: Selector, _ target: LivePreviewView) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        return item
    }
}
