//
//  Renderer_Live.swift
//  ArtRenderLibrary
//
//  GPU-only render path behind the live Metal view.
//
//  `render(art:)` produces a single CGImage and composites layers + paper with
//  CoreGraphics. `renderLive(art:)` produces two GPU textures instead and does all of
//  that compositing in Metal, so the result can be re-presented with any
//  pan / zoom / rotate without touching the CPU again.
//
//  The art file's own view matrix is baked into the canvas, exactly like in
//  `render(art:)` — that is what makes "reset the view" mean "back to what the file
//  asked for".
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

import ArtParser

extension Renderer {
    
    /// Renders `art` into a GPU canvas for the interactive live view.
    ///
    /// Returns nil when Metal is unavailable or anything fails; callers are expected
    /// to fall back to `render(art:)` in that case.
    public func renderLive(art: ArtParser) -> LiveRenderedCanvas? {
        guard let mr = metalRenderer, MetalRenderer.useGPURendering else {
            print("Live view: no Metal renderer available")
            return nil
        }
        guard mr.prepareLiveCompositing() else { return nil }
        
        let width = Int(canvasSize.width * scale)
        let height = Int(canvasSize.height * scale)
        guard width > 0, height > 0 else { return nil }
        
        // The file's view matrix, scaled into device pixels — identical to render(art:).
        let baseTransform = transformFromMatrix(art.viewMatrix, scale: scale)
        
        do {
            try mr.makeLiveCanvasTextures(width: width, height: height)
            if let canvasTexture = mr.liveCanvasTexture {
                try mr.clearTexture(canvasTexture)          // start from transparent
            }
            
            invalidateReplayCaches()
            
            // ── Layers, in stack order: rasterise into the scratch target, then
            //    stack onto the canvas with the layer's opacity.
            for layerIndex in art.layerOrder {
                guard layerIndex < art.layers.count else { continue }
                let layer = art.layers[layerIndex]
                guard getVisibility(from: layer) else { continue }
                guard let layerMatrix = layer["matrix"] as? [[Float]] else { continue }
                
                let layerOpacity = layer["opacity"] as? Float ?? 1.0
                let operations = buildLayerOperations(
                    art: art,
                    layerIndex: layerIndex,
                    baseTransform: baseTransform,
                    flipTransform: nil)
                guard !operations.isEmpty else { continue }
                
                let artToDevice = CGAffineTransformConcat(toDirectCGTransform(layerMatrix),
                                                          baseTransform)
                try mr.renderLayerIntoLiveCanvas(layerOps: operations,
                                                  width: width, height: height,
                                                  artToDevice: artToDevice,
                                                  opacity: layerOpacity)
            }
            
            // ── Paper / background, baked in one compute pass.
            if art.paperTextureId != 0 {
                _ = mr.uploadLivePaperTexture(data: art.paperTextureData)
            }
            try mr.renderLivePaperBackground(
                paperColor: getPaperColor(for: art.paperTextureId),
                paperStrength: art.paperStrength,
                backgroundColor: art.backgroundColor,
                paperTextureData: art.paperTextureData,
                paperScale: scale,
                width: width, height: height)
            
            try mr.generateLiveCanvasMipmaps()
            
            guard let device = mr.device,
                  let canvasTexture = mr.liveCanvasTexture,
                  let backgroundTexture = mr.liveBackgroundTexture else {
                return nil
            }
            
            return LiveRenderedCanvas(device: device,
                                      canvasTexture: canvasTexture,
                                      backgroundTexture: backgroundTexture,
                                      pixelSize: CGSize(width: width, height: height))
        } catch {
            print("Live view: render failed — \(error)")
            return nil
        }
    }
    
    /// Reads a live canvas back to a `CGImage` (test/debug aid: lets `art2png --live`
    /// dump the composited art exactly as the live view builds it).
    public func liveCanvasImage(_ canvas: LiveRenderedCanvas) -> CGImage? {
        guard let mr = metalRenderer else { return nil }
        return try? canvas.makeCGImage(renderer: mr)
    }
    
    /// Renders what the live view would show for `transform`, offscreen, as a `CGImage`.
    /// With the neutral transform this is the document fitted to `size`.
    public func livePreviewImage(_ canvas: LiveRenderedCanvas,
                                 transform: LiveViewTransform = LiveViewTransform(),
                                 size: CGSize) -> CGImage? {
        guard let mr = metalRenderer else { return nil }
        return try? canvas.previewImage(renderer: mr, transform: transform, size: size)
    }
    
    /// Draws a live canvas into `drawable` through the given view transform. Safe to
    /// call from the UI thread while the renderer is idle.
    public func presentLiveCanvas(_ canvas: LiveRenderedCanvas,
                                  to drawable: MTLDrawable,
                                  transform: LiveViewTransform,
                                  clearColor: MTLClearColor = MTLClearColorMake(0, 0, 0, 1)) {
        guard let mr = metalRenderer else { return }
        do {
            try mr.presentLiveCanvas(canvas, to: drawable, transform: transform, clearColor: clearColor)
        } catch {
            print("Live view: present failed — \(error)")
        }
    }
}
#endif
