//
//  LivePreviewController.swift
//  ArtQuickLookExtension
//
//  Owns the lifetime of a live preview: renders the document on a background queue
//  (the GPU work in Renderer.renderLive blocks on every dispatch, so it must not run on
//  the main thread), hands the finished canvas to the view on the main thread, and
//  reports failure so the caller can fall back to the static preview.
//

import Cocoa
import Metal
import ArtParser
import ArtRenderLibrary

enum LivePreviewError: LocalizedError {
    case noMetalDevice
    case viewUnavailable

    var errorDescription: String? {
        switch self {
            case .noMetalDevice:    return "No Metal device for the live view"
            case .viewUnavailable:  return "Could not create the live Metal view"
        }
    }
}

final class LivePreviewSession {
    /// Serialises all rendering for one preview (the MetalRenderer is stateful).
    private let renderQueue = DispatchQueue(label: "org.potato.ArtQuickLook.live",
                                           qos: .userInitiated)
    private let canvasSize: CGSize
    private let scale: CGFloat
    private var art: ArtParser?

    /// Main thread only.
    let view: LivePreviewView

    /// - Note: deliberately *no* `Renderer` yet — constructing one loads the metallib,
    ///   builds every pipeline and allocates render targets, which must not happen on
    ///   the main thread while Quick Look is opening the preview.
    init(art: ArtParser, canvasSize: CGSize, scale: CGFloat) throws {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw LivePreviewError.noMetalDevice
        }
        self.canvasSize = canvasSize
        self.scale = scale
        self.view = LivePreviewView.make(device: device)
        self.art = art
    }

    /// Renders the document. `onReady` and `onFailure` are called on the main thread.
    func render(onReady: @escaping (LivePreviewView) -> Void,
                onFailure: @escaping (Error) -> Void) {
        guard let art = art else {
            DispatchQueue.main.async { onFailure(LivePreviewError.viewUnavailable) }
            return
        }

        let canvasSize = self.canvasSize
        let scale = self.scale
        view.showStatus("Rendering…", hold: 3)

        renderQueue.async { [weak self] in
            let renderer = ArtRenderLibrary.Renderer(canvasSize: canvasSize,
                                                     scale: scale,
                                                     forceCPU: false,
                                                     useSegmentRendering: true)
            let canvas = renderer.renderLive(art: art)
            DispatchQueue.main.async {
                guard let self = self, let canvas = canvas else {
                    onFailure(LivePreviewError.viewUnavailable)
                    return
                }
                self.view.install(canvas: canvas, renderer: renderer)
                onReady(self.view)
            }
        }
    }
}
