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
    private let art: ArtParser
    private let canvasSize: CGSize
    private let scale: CGFloat

    // ── render queue only ──
    private var renderer: ArtRenderLibrary.Renderer?
    private var cache: LiveRenderCache?

    // ── main thread only ──
    private var latestRequest: Request?
    private var rendering = false
    private let throttle: LiveFrameThrottle
    private var lastFrameFinishedAt: CFTimeInterval = CACurrentMediaTime()

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
        self.throttle = LiveFrameThrottle(maxFPS: settings.liveMaxFPS)
    }

    // MARK: Requests (main thread)

    func request(transform: LiveViewTransform, viewport: CGSize) {
        guard viewport.width >= 1, viewport.height >= 1 else { return }
        latestRequest = Request(transform: transform, viewport: viewport)
        kick()
    }

    private func kick() {
        guard !rendering, let request = latestRequest else { return }
        latestRequest = nil                 // coalesce: only the newest state survives
        rendering = true
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
            if let canvas { self.onCanvas?(canvas, transform, renderer) }
            if let timing {
                self.onStatus?(String(format: "%.0f ms  (bin %.0f · encode %.0f · gpu %.0f)"
                                      + "   %d strokes · %d segments · %d culled",
                                      timing.totalMilliseconds, timing.binMilliseconds,
                                      timing.encodeMilliseconds, timing.gpuMilliseconds,
                                      timing.strokes, timing.segments, timing.culledStrokes))
            }
            self.lastFrameFinishedAt = CACurrentMediaTime()
            self.rendering = false
            if self.latestRequest != nil { self.kick() }
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
    /// When the last drag event arrived; a "button not pressed" reading is only believed
    /// after a quiet spell, because a Quick Look-style host can swallow the button-down.
    private var lastDragEventTime: CFTimeInterval = CACurrentMediaTime()
    private static let dragLapseGrace: TimeInterval = 0.35

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
        clearColor = MTLClearColorMake(0.11, 0.11, 0.12, 1)
        autoResizeDrawable = true
        enableSetNeedsDisplay = true
        preferredFramesPerSecond = 60
        delegate = self
        isPaused = true
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
        guard viewportSize != lastReportedViewport else { return }
        DispatchQueue.main.async { [weak self] in
            self?.drawFrame()
            self?.reportChange()
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
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "0": commit { $0.resetAll() }
        case "p": commit { $0.resetPan() }
        case "z": commit { $0.resetZoom() }
        case "r": commit { $0.resetRotation() }
        default: super.keyDown(with: event)
        }
    }

    private func begin(mode: Mode, location: CGPoint, button: NSEvent.EventTypeMask) {
        isDragging = true
        dragMode = mode
        dragButton = button
        dragAnchor = location
        lastDragLocation = location
        lastDragEventTime = CACurrentMediaTime()
        NSCursor.closedHand.set()
    }

    private func drag(to location: CGPoint, mode eventMode: Mode) {
        guard isDragging else { return }
        if eventMode != dragMode {
            dragMode = eventMode
            dragAnchor = location
            lastDragLocation = location
            return
        }
        lastDragEventTime = CACurrentMediaTime()
        let dx = location.x - lastDragLocation.x
        let dy = location.y - lastDragLocation.y
        lastDragLocation = location
        guard dx != 0 || dy != 0 else { return }

        let viewport = viewportSize
        let pointScale = pixelScale
        switch dragMode {
        case .pan:
            // y negated: screen is y-down, view space is y-up (LiveViewSpace).
            commit { $0.pan(by: LiveViewSpace.delta(CGPoint(x: dx, y: dy))) }
        case .zoom:
            let factor = exp(-(dy / pointScale) * Self.zoomSensitivity)
            let anchor = viewSpacePoint(dragAnchor)
            commit { $0.zoom(by: factor, anchor: anchor, viewportSize: viewport) }
        case .rotate:
            // About the view centre, not the pointer — see the extension's LivePreviewView.
            let delta = (dx / pointScale) * Self.rotateSensitivity
            let centre = LiveViewSpace.centre(viewportSize: viewport)
            commit { $0.rotate(by: delta, anchor: centre, viewportSize: viewport) }
        }
    }

    private func endDrag() {
        guard isDragging else { return }
        isDragging = false
        dragButton = []
        NSCursor.arrow.set()
    }

    // MARK: Menu access
    //
    // The View menu drives the focused document window. Going through the responder chain
    // (`NSApp.keyWindow`'s content view) keeps the menu independent of which window or
    // coordinator owns the view.

    enum ResetKind { case all, pan, zoom, rotation }

    /// The live view in the key window, if any.
    static var focusedDocumentView: LiveMTKView? {
        guard let content = NSApp.keyWindow?.contentView else { return nil }
        return findLiveMTKView(in: content)
    }

    static var hasFocusedDocument: Bool { focusedDocumentView != nil }

    static func resetFocused(_ kind: ResetKind) {
        guard let view = focusedDocumentView else { return }
        view.performReset(kind)
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
        case .zoom:     commit { $0.resetZoom() }
        case .rotation: commit { $0.resetRotation() }
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
        super.init(window: window)
        
        // was .frame(minWidth: 480, minHeight: 360)
        window.contentMinSize = NSSize(width: 480, height: 360)
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
}
