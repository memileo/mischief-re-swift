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

extension CGAffineTransform {
    /// No built-in check on CGAffineTransform: a transform is invertible
    /// exactly when its determinant is nonzero.
    var isInvertible: Bool {
        (a * d - b * c) != 0
    }
}

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
            mr.beginLiveFrame()
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
            
            // ── Paper / background, baked in one compute pass. Identity camera:
            //    canvas pixels *are* document-canvas pixels here.
            if art.paperTextureId != 0 {
                _ = mr.uploadLivePaperTexture(data: art.paperTextureData)
            }
            try mr.renderLivePaperBackground(
                paperColor: getPaperColor(for: art.paperTextureId),
                paperStrength: art.paperStrength,
                backgroundColor: art.backgroundColor,
                paperTextureData: art.paperTextureData,
                tileScale: scale,
                documentFromCanvas: .identity,
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
            try mr.presentLiveCanvas(canvas, to: drawable, transform: transform,
                                     clearColor: clearColor)
        } catch {
            print("Live view: present failed — \(error)")
        }
    }
    
    // MARK: - Interactive mode (re-render per view change)
    
    /// Builds the "process once" cache for `art`.
    ///
    /// Call this once per document (on the render queue). The returned cache can then be
    /// re-rasterised for any camera with `renderLive(cache:camera:viewport:)`.
    ///
    /// - Note: `scale` must be the renderer's own `scale`, because
    ///   `renderLive(cache:…)` derives the camera from `canvasSize * self.scale` — a
    ///   different value here would silently mis-register all cached geometry.
    public func buildLiveRenderCache(art: ArtParser,
                                     scale: CGFloat? = nil,
                                     segmentBudget: Int = Renderer.liveCacheSegmentBudget) -> LiveRenderCache? {
        guard let mr = metalRenderer, MetalRenderer.useGPURendering else { return nil }
        guard mr.prepareLiveCompositing() else { return nil }

        let started = DispatchTime.now().uptimeNanoseconds
        let cache = buildLiveRenderCacheGeometry(art: art, scale: scale,
                                                 segmentBudget: segmentBudget)
        if cache != nil {
            print(String(format: "Live view: cache built in %.0f ms",
                         Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000.0))
        }
        return cache
    }
    
    /// Re-rasterises the cached document for `camera` into a viewport-sized canvas.
    ///
    /// The canvas matches the viewport 1:1, so the result is presented with an identity
    /// transform — every pixel of it was rasterised at the current zoom, which is what
    /// makes zooming in show real detail instead of a magnified bitmap.
    public func renderLive(cache: LiveRenderCache,
                           art: ArtParser,
                           camera: LiveViewTransform,
                           viewport: CGSize,
                           clearPaper: Bool = false) -> LiveRenderedCanvas? {
        guard let mr = metalRenderer else { return nil }
        guard mr.prepareLiveCompositing() else { return nil }
        
        let width = max(Int(viewport.width.rounded()), 1)
        let height = max(Int(viewport.height.rounded()), 1)
        
        // Camera: canvas px (at 100%) → viewport px.
        let viewMatrix = camera.matrix(canvasPixelSize: CGSize(width: canvasSize.width * scale,
                                                              height: canvasSize.height * scale),
                                       viewportSize: viewport)
        let cameraTransform = viewMatrix.affineTransform
        // Offset stroke noise so it follows the view instead of staying pinned to
        // the screen. camera.pan is in view space (y up); the noise sampling grid
        // runs in viewport pixels (y down), so flip the y component.
        mr.liveNoiseOffset = CGPoint(x: camera.pan.x, y: -camera.pan.y)
        mr.liveTiming = LiveFrameTiming()
        let frameStart = DispatchTime.now().uptimeNanoseconds
        
        do {
            try mr.makeLiveCanvasTextures(width: width, height: height,
                                          mipmapped: false, resetPaper: clearPaper)
            // Render into the pair the UI is not presenting, so clearing this frame's
            // canvas cannot blank the frame still on screen (it used to: the canvas was
            // cleared in place and the next present showed an empty texture).
            mr.beginLiveFrame()
            if let canvasTexture = mr.liveCanvasTexture {
                try mr.clearTexture(canvasTexture)          // start from transparent
            }
            
            // ── Layers, in stack order.
            for (position, layer) in cache.layers.enumerated() {
                let artLayer = (layer.layerIndex < art.layers.count) ? art.layers[layer.layerIndex] : nil
                guard (artLayer?["visible"] as? Int ?? 1) != 0 else { continue }
                let layerOpacity = artLayer?["opacity"] as? Float ?? layer.opacity
                if layer.needsRebuild {
                    // Uncached path: full action walk + the untouched dispatch pipeline.
                    mr.liveTiming.rebuiltLayers += 1
                    let artToDevice = cache.artToDevice(layerAt: position, camera: cameraTransform)
                        ?? CGAffineTransformConcat(layer.layerTransform, cameraTransform)
                    let operations = buildLayerOperations(
                        art: art,
                        layerIndex: layer.layerIndex,
                        baseTransform: cache.liveBaseTransform(camera: cameraTransform),
                        flipTransform: nil)
                    guard !operations.isEmpty else { continue }
                    try mr.renderLayerIntoLiveCanvas(layerOps: operations,
                                                      width: width, height: height,
                                                      artToDevice: artToDevice,
                                                      opacity: layerOpacity)
                    continue
                }
                
                mr.liveTiming.cachedLayers += 1
                let strokesInLayer = cache.strokeCount(at: position)
                let viewportRect = CGRect(origin: .zero, size: CGSize(width: width, height: height))
                // GPU-binned per-tile path first: same pixels, ~bulk CPU work moved to GPU.
                // Returns false when ineligible (cuts; markers only together with noise)
                // or unavailable → CPU below.
                if mr.renderCachedLayerGPU(cache: cache, position: position,
                                           camera: cameraTransform, viewport: viewportRect,
                                           width: width, height: height,
                                           opacity: layerOpacity) {
                    continue
                }
                guard let deviceOps = cache.deviceOps(forLayerAt: position,
                                                      camera: cameraTransform,
                                                      viewport: viewportRect),
                      !deviceOps.isEmpty else {
                    // Everything in this layer is off screen.
                    mr.liveTiming.culledStrokes += strokesInLayer
                    continue
                }
                if layer.hasCut || layer.hasPaste {
                    try mr.renderCachedLayerMixedIntoLiveCanvas(layerOps: deviceOps,
                                                                cache: cache,
                                                                position: position,
                                                                camera: cameraTransform,
                                                                viewport: viewportRect,
                                                                width: width, height: height,
                                                                opacity: layerOpacity)
                } else {
                    try mr.renderCachedLayerIntoLiveCanvas(layerOps: deviceOps,
                                                           width: width, height: height,
                                                           opacity: layerOpacity)
                }
            }
            
            // ── Paper / background. Tiled in *canvas* space (like the CoreGraphics path):
            //   viewport px → canvas px via the inverse camera, then ÷ scale → canvas points,
            //   so the pattern is anchored to the canvas and pans/zooms with the view.
            if art.paperTextureId != 0, mr.livePaperTexture == nil {
                _ = mr.uploadLivePaperTexture(data: art.paperTextureData)
            }
            let documentUnits = scale != 0 ? 1 / scale : 1
            let documentFromCanvas: CGAffineTransform
            if cameraTransform.isInvertible {
                // viewport px → canvas px via the inverse camera, then ÷ scale → canvas
                // points (`a.concatenating(b)` applies a first). The ÷scale must come
                // *after* the camera inverse: `cameraTransform` works in reference
                // canvas pixels, and dividing before it would bake the raster scale
                // into the camera, making the paper shift `scale`-times per pan pixel.
                documentFromCanvas = cameraTransform.inverted()
                    .concatenating(CGAffineTransform(scaleX: documentUnits, y: documentUnits))
            } else {
                documentFromCanvas = .identity
            }
            let paperStart = DispatchTime.now().uptimeNanoseconds
            try mr.renderLivePaperBackground(
                paperColor: getPaperColor(for: art.paperTextureId),
                paperStrength: art.paperStrength,
                backgroundColor: art.backgroundColor,
                paperTextureData: art.paperTextureData,
                // Tile size is in canvas points here; the raster path passes `scale`
                // instead because it works directly in canvas pixels.
                tileScale: 1,
                documentFromCanvas: documentFromCanvas,
                width: width, height: height)
            mr.liveTiming.paperMilliseconds += MetalRenderer.milliseconds(since: paperStart)
            
            guard let device = mr.device,
                  let canvasTexture = mr.liveCanvasTexture,
                  let backgroundTexture = mr.liveBackgroundTexture else {
                return nil
            }
            
            mr.liveTiming.totalMilliseconds = MetalRenderer.milliseconds(since: frameStart)
            lastLiveFrameTiming = mr.liveTiming
            if Renderer.livePathTiming {
                print("Live view: \(mr.liveTiming.summary)")
            }
            
            return LiveRenderedCanvas(device: device,
                                      canvasTexture: canvasTexture,
                                      backgroundTexture: backgroundTexture,
                                      pixelSize: CGSize(width: width, height: height),
                                      presentTransform: LiveViewTransform(),
                                      isViewportRerendered: true)
        } catch {
            print("Live view: interactive render failed — \(error)")
            return nil
        }
    }
}
#endif
