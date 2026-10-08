//
//  LiveRenderedCanvas.swift
//  ArtRenderLibrary
//
//  The GPU-side result of a live-path render: a fully composited document that can be
//  re-presented any number of times with different pan / zoom / rotate values without
//  touching the CPU.
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

/// Immutable result of `Renderer.renderLive(art:)`.
///
/// Two textures, both the size of the rendered document:
/// - `canvasTexture`: premultiplied RGBA8, one layer composited on top of the next,
/// - `backgroundTexture`: opaque RGBA8 with paper colour + tiled paper texture +
///   the art file's background multiply, baked by `livePaperBackgroundKernel`.
///
/// Threading: instances are produced on the render queue and handed to the main
/// thread by replacing the reference; the textures themselves are immutable once
/// handed over.
public final class LiveRenderedCanvas {
    public let device: MTLDevice
    public let canvasTexture: MTLTexture
    public let backgroundTexture: MTLTexture
    /// Size of both textures, in pixels.
    public let pixelSize: CGSize

    init(device: MTLDevice,
         canvasTexture: MTLTexture,
         backgroundTexture: MTLTexture,
         pixelSize: CGSize) {
        self.device = device
        self.canvasTexture = canvasTexture
        self.backgroundTexture = backgroundTexture
        self.pixelSize = pixelSize
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
    /// live view draws for `transform`. Test/debug aid for `art2png --live`.
    func previewImage(renderer: MetalRenderer,
                      transform: LiveViewTransform = LiveViewTransform(),
                      size: CGSize) throws -> CGImage? {
        let texture = try renderer.renderLivePreviewTexture(self, transform: transform, size: size)
        guard let texture = texture else { return nil }
        return try renderer.readbackToCGImageSync(texture)
    }
    #endif
}
#endif