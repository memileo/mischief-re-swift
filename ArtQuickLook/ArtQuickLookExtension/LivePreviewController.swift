//
//  LivePreviewController.swift
//  ArtQuickLookExtension
//
//  Owns a live preview: builds the render cache once, then re-rasterises the document
//  on a background queue whenever the view transform changes.
//
//  Scheduling
//  ----------
//  Every change (drag event, reset, resize, first frame) is a *request*, not a frame:
//  the request records the latest transform, and `LiveFramePacer` starts it on the next
//  display-refresh tick (or after the rest of the frame-rate slot, if the panel's link
//  is unavailable). While a render is in flight further requests only overwrite that
//  latest transform, so a fast mouse produces a handful of frames instead of one per
//  event. The view never depends on MTKView's display link running inside the Quick Look
//  host. Exactly one render is in flight at a time — the renderer relies on that (its
//  per-frame geometry arena is reused between frames).
//
//  Threading
//  ---------
//  The render queue owns the `ArtRenderLibrary.Renderer` and the geometry cache; the main
//  thread owns everything the view touches. The two only meet through immutable values
//  handed over in `finish(...)`, so there is no shared mutable state between them.
//
//  Two modes
//  ---------
//  - interactive (default): the document is rasterised for the current camera into a
//    viewport-sized canvas, so zooming in shows real detail instead of a magnified
//    bitmap. Transform changes schedule a re-render.
//  - single raster (fallback): the document is rendered once and transformed while
//    presenting. Used when the geometry cache does not fit the memory budget or Metal /
//    the live kernels are unavailable. Transform changes only redraw.
//

import Cocoa
import Metal
import QuartzCore        // CACurrentMediaTime
import ArtParser
import ArtRenderLibrary

enum LivePreviewError: LocalizedError {
    case noMetalDevice
    case viewUnavailable
    case renderUnavailable

    var errorDescription: String? {
        switch self {
            case .noMetalDevice:    return "No Metal device for the live view"
            case .viewUnavailable:  return "Could not create the live Metal view"
            case .renderUnavailable: return "Live Metal rendering failed"
        }
    }
}

final class LivePreviewSession {
    /// Serialises all rendering for one preview (the MetalRenderer is stateful).
    private let renderQueue = DispatchQueue(label: "org.potato.ArtQuickLook.live",
                                           qos: .userInitiated)
    /// Frames slower than this log their stage breakdown (bin / encode / gpu / paper), so
    /// "the preview feels sluggish" can be diagnosed without a rebuild.
    private static let slowFrameMilliseconds: Double = 250
    /// Frame-rate cap and display-refresh pacing, shared with the app's document windows
    /// (`LiveFramePacer`).
    private let pacer: LiveFramePacer
    private let canvasSize: CGSize
    private let scale: CGFloat

    // ── Render queue only ──
    private var queueRenderer: ArtRenderLibrary.Renderer?
    private var cache: LiveRenderCache?
    private let art: ArtParser

    // ── Main thread only ──
    private var latestRequest: LiveRenderRequest?
    private var didShowStatus = false
    private var didAnnounceFallback = false
    /// Published from `finish(...)` so the present closure (main thread) never has to
    /// read the render-queue-owned renderer.
    private var presentRenderer: ArtRenderLibrary.Renderer?

    let view: LivePreviewView
    /// True while the document is re-rasterised per view change.
    private(set) var isInteractive = false
    /// Called on the main thread when nothing can be shown at all.
    var onFailure: ((Error) -> Void)?

    /// - Note: deliberately *no* `Renderer` yet — constructing one loads the metallib,
    ///   builds every pipeline and allocates render targets, which must not happen on the
    ///   main thread while Quick Look is opening the preview.
    init(art: ArtParser, canvasSize: CGSize, scale: CGFloat) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw LivePreviewError.noMetalDevice
        }
        self.canvasSize = canvasSize
        self.scale = scale
        // 0 = uncapped. A display cannot show more than its refresh rate, so anything
        // above that only burns GPU time.
        self.pacer = LiveFramePacer(maxFPS: Settings().liveMaxFPS)
        self.art = art
        self.view = LivePreviewView.make(device: device)

        self.pacer.onStart = { [weak self] in self?.startPendingRender() }

        view.onRenderRequest = { [weak self] transform, viewport in
            self?.request(transform: transform, viewport: viewport)
        }
        view.present = { [weak self] canvas, transform, drawable, clearColor in
            guard let self = self, let renderer = self.presentRenderer else { return }
            renderer.presentLiveCanvas(canvas, to: drawable,
                                       transform: transform,
                                       clearColor: clearColor)
        }
    }

    deinit {
        // Stop a display link that is still ticking when the preview goes away.
        pacer.invalidate()
    }

    // MARK: - Requests (main thread)

    /// Something changed: make the document look like this.
    func request(transform: LiveViewTransform, viewport: CGSize) {
        guard viewport.width >= 1, viewport.height >= 1 else { return }

        // Single-raster mode already shows any transform without re-rendering — the view
        // simply presents again with the new transform.
        guard isInteractive || presentRenderer == nil else {
            view.refresh()
            return
        }

        // The first request also builds the renderer + geometry cache, which can take a
        // moment on a large document.
        if !didShowStatus {
            didShowStatus = true
            view.showStatus("Rendering…", hold: 3)
        }

        latestRequest = LiveRenderRequest(transform: transform, viewport: viewport)
        pacer.request()
    }

    private func startPendingRender() {
        guard let request = latestRequest else { return }
        latestRequest = nil                 // coalesce: only the newest state survives
        run(request)
    }

    /// Hand a finished render over to the main thread.
    ///
    /// - Note: `renderer` is passed by value so the main thread never reads
    ///   render-queue state.
    private func finish(_ canvas: LiveRenderedCanvas?,
                        renderer: ArtRenderLibrary.Renderer?,
                        interactive: Bool,
                        failed: Bool = false) {
        DispatchQueue.main.async {
            if let canvas = canvas {
                self.presentRenderer = renderer
                self.view.install(canvas: canvas)
                self.isInteractive = interactive
            } else if failed && !self.view.hasCanvas {
                // Nothing was ever drawn: hand over to the static preview.
                self.pacer.invalidate()
                self.onFailure?(LivePreviewError.renderUnavailable)
                return
            }
            // A nil canvas with one already on screen is a transient failure: keep the
            // current mode so the next change retries the same way.
            self.pacer.renderFinished()
        }
    }

    // MARK: - Rendering (render queue)

    private func run(_ request: LiveRenderRequest) {
        renderQueue.async { [weak self] () -> Void in
            guard let self = self else { return }

            // First time: build the renderer, then the geometry cache.
            if self.queueRenderer == nil {
                let renderer = ArtRenderLibrary.Renderer(canvasSize: self.canvasSize,
                                                         scale: self.scale,
                                                         forceCPU: false,
                                                         useSegmentRendering: true)
                self.queueRenderer = renderer
                if let cache = renderer.buildLiveRenderCache(art: self.art, scale: self.scale) {
                    self.cache = cache
                }
            }

            guard let renderer = self.queueRenderer else {
                self.finish(nil, renderer: nil, interactive: false, failed: true)
                return
            }

            // Interactive path: re-rasterise the cached document for this camera.
            if let cache = self.cache {
                let canvas = renderer.renderLive(cache: cache,
                                                 art: self.art,
                                                 camera: request.transform,
                                                 viewport: request.viewport)
                if let timing = renderer.lastLiveFrameTiming,
                   timing.totalMilliseconds > Self.slowFrameMilliseconds {
                    NSLog("ArtQuickLook live frame (slow): %@", timing.summary)
                }
                self.finish(canvas, renderer: renderer,
                            interactive: canvas != nil,
                            failed: canvas == nil)
                return
            }

            // Fallback: one document render, transformed while presenting.
            let canvas = renderer.renderLive(art: self.art)
            if !self.didAnnounceFallback {
                self.didAnnounceFallback = true
                DispatchQueue.main.async {
                    NSLog("ArtQuickLook live view: single-raster mode for this document "
                          + "(geometry cache unavailable or over budget)")
                }
            }
            self.finish(canvas, renderer: renderer, interactive: false, failed: canvas == nil)
        }
    }
}

/// A queued "make the document look like this" request.
private struct LiveRenderRequest {
    let transform: LiveViewTransform
    let viewport: CGSize
}