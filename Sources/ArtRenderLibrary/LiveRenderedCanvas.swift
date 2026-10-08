//
//  LiveRenderedCanvas.swift
//  ArtRenderLibrary
//
//  The GPU-side result of a live-path render: a fully composited document that can be
//  re-presented as many times as we like without touching the CPU compositor.
//

import Foundation

#if canImport(Metal)
import Metal
#if os(Linux)
import CoreFoundation
import Silica
#elseif os(macOS)
import CoreGraphics
#endif

/// Immutable result of a live render.
///
/// Two textures, both the size of the rendered canvas:
/// - `canvasTexture`: premultiplied RGBA8, one layer composited on top of the next,
/// - `backgroundTexture`: opaque RGBA8 with paper colour + tiled paper texture +
///   the art file's background multiply, baked by `livePaperBackgroundKernel`.
///
/// Two live modes produce these:
/// - **single-raster mode** (`Renderer.renderLive`): the canvas is a document-sized
///   render that gets *transformed* while presenting, so `presentTransform` is whatever
///   the user currently has,
/// - **interactive mode** (`Renderer.renderLive(cache:camera:viewport:)`): the canvas is
///   viewport-sized and already contains the camera, so `presentTransform` is identity.
///
/// Threading: instances are produced on the render queue and handed to the main thread
/// by replacing the reference; the textures themselves are immutable once handed over.
public final class LiveRenderedCanvas {
    public let device: MTLDevice
    public let canvasTexture: MTLTexture
    public let backgroundTexture: MTLTexture
    /// Size of both textures, in pixels.
    public let pixelSize: CGSize
    /// Transform to use when presenting. Identity for interactive renders (the camera is
    /// already baked in); the live view transform for single-raster canvases.
    public let presentTransform: LiveViewTransform
    /// True when the canvas *is* the viewport and was rasterised for the current camera,
    /// i.e. it must be presented 1:1. False for the single-raster fallback.
    public let isViewportRerendered: Bool

    init(device: MTLDevice,
         canvasTexture: MTLTexture,
         backgroundTexture: MTLTexture,
         pixelSize: CGSize,
         presentTransform: LiveViewTransform = LiveViewTransform(),
         isViewportRerendered: Bool = false) {
        self.device = device
        self.canvasTexture = canvasTexture
        self.backgroundTexture = backgroundTexture
        self.pixelSize = pixelSize
        self.presentTransform = presentTransform
        self.isViewportRerendered = isViewportRerendered
    }

    public var width: Int { Int(pixelSize.width) }
    public var height: Int { Int(pixelSize.height) }

    /// Reads the composited canvas back to a `CGImage`. macOS test hook only — the
    /// live view itself never reads the canvas back.
    ///
    /// - Note: this is the *art only* canvas (no paper/background). Use
    ///   `previewImage(renderer:transform:size:)` for what the view actually shows.
    ///
    /// - Important: internal, not public — `MetalRenderer` is an internal type.
    #if os(macOS)
    func makeCGImage(renderer: MetalRenderer) throws -> CGImage? {
        try renderer.readbackToCGImageSync(canvasTexture)
    }

    /// Runs the present pass offscreen and reads the result back: the exact image the
    /// live view draws for `transform`. Test/debug aid for `art2png --live-view`.
    ///
    /// - Parameter flipVertically: escape hatch for the canvas row order. See
    ///   `MetalRenderer_LivePresent.presentLiveCanvas`.
    func previewImage(renderer: MetalRenderer,
                      transform: LiveViewTransform = LiveViewTransform(),
                      size: CGSize,
                      flipVertically: Bool = false) throws -> CGImage? {
        let texture = try renderer.renderLivePreviewTexture(self, transform: transform,
                                                             size: size,
                                                             flipVertically: flipVertically)
        guard let texture = texture else { return nil }
        return try renderer.readbackToCGImageSync(texture)
    }
    #endif
}
#endif