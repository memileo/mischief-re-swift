//
//  MetalRenderer_LiveCompositing.swift
//  ArtRenderLibrary
//
//  GPU-only compositing for the live view (interactive pan / zoom / rotate).
//
//  Everything the static paths do with CoreGraphics — `context.draw(layerImage…)`
//  per layer, the `destinationOver` paper/background fill, the `multiply` of the
//  background colour — is done here with Metal compute kernels:
//
//      layer ops ──► gpuRenderTarget (segment kernels, premultiplied)
//                 ──► liveCompositeLayerKernel ──► liveCanvasTexture
//      paper    ──► livePaperBackgroundKernel ──► liveBackgroundTexture
//
//  Only image *decoding* (the art file's embedded paper JPEG) happens on the CPU,
//  because that is what turns bytes into a texture.
//

#if os(macOS)
import Metal
import CoreGraphics
import ImageIO

// MARK: - Uniform structs (must match liveCompositeKernels.metal byte for byte)

struct LivePresentUniforms {
    var m00: Float, m10: Float        // image of canvas x
    var m01: Float, m11: Float        // image of canvas y
    var m02: Float, m12: Float        // translation
    var canvasW: Float, canvasH: Float
    var pad0: Float = 0, pad1: Float = 0
}

struct LivePaperParams {
    var paperR: Float, paperG: Float, paperB: Float
    var paperStrength: Float
    var bgR: Float, bgG: Float, bgB: Float
    var hasTexture: Float
    var tileW: Float, tileH: Float
    var canvasW: Float, canvasH: Float
}

extension MetalRenderer {
    
    // MARK: - Pipeline preparation
    
    /// Builds the live-view pipelines once. Returns false when the metallib is too
    /// old to contain the live kernels — the caller then falls back to the static
    /// render path instead of showing nothing.
    @discardableResult
    func prepareLiveCompositing() -> Bool {
        if liveCompositingPrepared { return true }
        
        guard let device = self.device, let library = self.library else {
            print("Live view: no Metal device / library")
            return false
        }
        
        // Compute kernels
        var failures: [String] = []
        if let fn = library.makeFunction(name: "liveCompositeLayerKernel") {
            do {
                liveCompositeLayerPipeline = try device.makeComputePipelineState(function: fn)
            } catch {
                failures.append("liveCompositeLayerKernel: \(error)")
                liveCompositeLayerPipeline = nil
            }
        } else {
            failures.append("liveCompositeLayerKernel: not found in the metallib")
        }
        if let fn = library.makeFunction(name: "livePaperBackgroundKernel") {
            do {
                livePaperBackgroundPipeline = try device.makeComputePipelineState(function: fn)
            } catch {
                failures.append("livePaperBackgroundKernel: \(error)")
                livePaperBackgroundPipeline = nil
            }
        } else {
            failures.append("livePaperBackgroundKernel: not found in the metallib")
        }
        
        // Present render pipeline (drawables are BGRA, offscreen readback is RGBA)
        if let vs = library.makeFunction(name: "livePresentVertexShader"),
           let fs = library.makeFunction(name: "livePresentFragmentShader") {
            do {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = vs
                desc.fragmentFunction = fs
                desc.colorAttachments[0].pixelFormat = .bgra8Unorm
                desc.colorAttachments[0].isBlendingEnabled = false
                livePresentPipeline = try device.makeRenderPipelineState(descriptor: desc)
            } catch {
                failures.append("livePresent (bgra8): \(error)")
                livePresentPipeline = nil
            }
            do {
                let desc = MTLRenderPipelineDescriptor()
                desc.vertexFunction = vs
                desc.fragmentFunction = fs
                desc.colorAttachments[0].pixelFormat = .rgba8Unorm
                desc.colorAttachments[0].isBlendingEnabled = false
                livePresentPipelineRGBA = try device.makeRenderPipelineState(descriptor: desc)
            } catch {
                failures.append("livePresent (rgba8): \(error)")
                livePresentPipelineRGBA = nil
            }
        } else {
            failures.append("livePresentVertexShader/livePresentFragmentShader: not found in the metallib")
        }
        
        guard liveCompositeLayerPipeline != nil,
              livePaperBackgroundPipeline != nil,
              livePresentPipeline != nil else {
            // Two very different causes: a metallib that predates the live kernels
            // (rebuild it), or a device that cannot build these pipelines. Print both
            // the failures and the likely remedy.
            print("Live view: could not prepare compositing — falling back to the static render path:")
            for failure in failures { print("  - \(failure)") }
            print("  If the functions are missing, rebuild with Scripts/build-metallib.sh")
            liveCompositingPrepared = false
            return false
        }
        
        // Per-frame uniform buffers: MTKView keeps several drawables in flight.
        if livePresentUniformsBuffers.isEmpty {
            livePresentUniformsBuffers = (0..<3).compactMap { _ in
                device.makeBuffer(length: MemoryLayout<LivePresentUniforms>.stride,
                                  options: .storageModeShared)
            }
        }
        if livePresentUniformsBuffers.isEmpty {
            print("Live view: could not allocate present uniform buffers")
            liveCompositingPrepared = false
            return false
        }
        
        // Mip-filtered sampler for the present pass (the shared `linearSampler` has
        // mipFilter == .notMipmapped, so canvas mips would never be sampled).
        if livePresentSampler == nil {
            let samplerDescriptor = MTLSamplerDescriptor()
            samplerDescriptor.minFilter = .linear
            samplerDescriptor.magFilter = .linear
            samplerDescriptor.mipFilter = .linear
            samplerDescriptor.sAddressMode = .clampToEdge
            samplerDescriptor.tAddressMode = .clampToEdge
            samplerDescriptor.rAddressMode = .clampToEdge
            samplerDescriptor.normalizedCoordinates = true
            livePresentSampler = device.makeSamplerState(descriptor: samplerDescriptor)
        }
        
        liveCompositingPrepared = true
        print("Live view: compositing pipelines ready")
        return true
    }
    
    // MARK: - Canvas textures
    
    /// (Re)creates the canvas + background textures for a `width` × `height` document.
    ///
    /// Also drops the previous document's paper texture — a `Renderer` can be reused for
    /// a second document of the same size, and the stale paper would be tiled into it.
    func makeLiveCanvasTextures(width: Int, height: Int) throws {
        guard let device = self.device else { throw MetalRendererError.deviceNotAvailable }
        guard width > 0, height > 0 else { throw MetalRendererError.textureCreationFailed }
        
        livePaperTexture = nil
        
        if let canvas = liveCanvasTexture,
           canvas.width == width, canvas.height == height {
            return                                  // already the right size
        }
        
        let mipCount = Self.mipLevelCount(width: width, height: height)
        
        func makeTexture() -> MTLTexture? {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: mipCount > 1)
            desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
            desc.storageMode = .private
            return device.makeTexture(descriptor: desc)
        }
        
        guard let canvas = makeTexture(), let background = makeTexture() else {
            throw MetalRendererError.textureCreationFailed
        }
        
        liveCanvasTexture = canvas
        liveBackgroundTexture = background
        print("Live view: canvas textures \(width)x\(height) (\(mipCount) mip level(s))")
    }
    
    static func mipLevelCount(width: Int, height: Int) -> Int {
        var levels = 1
        var w = max(width, 1), h = max(height, 1)
        while w > 1 || h > 1 {
            w = max(w / 2, 1); h = max(h / 2, 1)
            levels += 1
        }
        return levels
    }
    
    // MARK: - Layer compositing
    
    /// Rasterises one layer's operations into `gpuRenderTarget` and stacks the result
    /// onto the canvas with `opacity`.
    ///
    /// - Note: `layerOps` must be the output of `Renderer.buildLayerOperations(...)`.
    func renderLayerIntoLiveCanvas(layerOps: [LayerOperation],
                                   width: Int, height: Int,
                                   artToDevice: CGAffineTransform,
                                   opacity: Float) throws {
        guard let pipeline = liveCompositeLayerPipeline else {
            throw MetalRendererError.pipelineMissing("liveCompositeLayerKernel")
        }
        
        // Rasterise the layer first: this (re)creates the scratch render target if the
        // canvas size changed, and it synchronises internally.
        try renderSegmentGroups(layerOps: layerOps,
                                width: width, height: height,
                                artToDevice: artToDevice,
                                flipTransform: nil)
        
        guard let canvas = liveCanvasTexture,
              let layer = gpuRenderTarget,
              let queue = commandQueue,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalRendererError.textureCreationFailed
        }
        
        var layerOpacity = opacity
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(layer, index: 0)
        encoder.setTexture(canvas, index: 1)
        encoder.setBytes(&layerOpacity, length: MemoryLayout<Float>.stride, index: 0)
        
        let threads = MTLSize(width: 8, height: 8, depth: 1)
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1),
            threadsPerThreadgroup: threads)
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let err = commandBuffer.error { throw err }
    }
    
    // MARK: - Paper / background
    
    /// Bakes paper colour + tiled paper texture + background multiply into the
    /// background texture. Mirrors `Renderer.render(art:)`'s background block.
    func renderLivePaperBackground(paperColor: (r: CGFloat, g: CGFloat, b: CGFloat),
                                   paperStrength: Float,
                                   backgroundColor: [UInt8],
                                   paperTextureData: [UInt8],
                                   paperScale: CGFloat,
                                   width: Int, height: Int) throws {
        guard let pipeline = livePaperBackgroundPipeline else {
            throw MetalRendererError.pipelineMissing("livePaperBackgroundKernel")
        }
        guard let target = liveBackgroundTexture,
              let queue = commandQueue,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalRendererError.textureCreationFailed
        }
        
        let hasTexture = livePaperTexture != nil
        var tileW: Float = 0, tileH: Float = 0
        
        if hasTexture, let paper = livePaperTexture {
            // Same tile size as the CoreGraphics path: image size × 0.666 × scale.
            tileW = Float(paper.width) * 0.666 * Float(paperScale)
            tileH = Float(paper.height) * 0.666 * Float(paperScale)
        } else if !paperTextureData.isEmpty {
            print("Live view: paper texture could not be decoded — using flat paper colour")
        }
        
        var params = LivePaperParams(
            paperR: Float(paperColor.r), paperG: Float(paperColor.g), paperB: Float(paperColor.b),
            paperStrength: paperStrength,
            bgR: Float(backgroundColor[0]) / 255.0,
            bgG: Float(backgroundColor[1]) / 255.0,
            bgB: Float(backgroundColor[2]) / 255.0,
            hasTexture: hasTexture ? 1 : 0,
            tileW: tileW, tileH: tileH,
            canvasW: Float(width), canvasH: Float(height))
        
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&params, length: MemoryLayout<LivePaperParams>.stride, index: 0)
        // The kernel always declares a paper texture at index 0; bind a 1×1 stand-in
        // when this document has none rather than leaving the slot empty.
        if let paper = livePaperTexture {
            encoder.setTexture(paper, index: 0)
        } else if let placeholder = Self.makePlaceholderTexture(device: device) {
            encoder.setTexture(placeholder, index: 0)
        }
        if let sampler = linearSampler { encoder.setSamplerState(sampler, index: 0) }
        encoder.setTexture(target, index: 1)
        
        encoder.dispatchThreadgroups(
            MTLSize(width: (width + 7) / 8, height: (height + 7) / 8, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 8, height: 8, depth: 1))
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let err = commandBuffer.error { throw err }
    }
    
    /// Decodes the art file's embedded paper JPEG into a texture (CPU decoding only —
    /// tiling and compositing happen in the shader).
    @discardableResult
    func uploadLivePaperTexture(data: [UInt8]) -> Bool {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(Data(data) as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let texture = Self.makeRGBA8Texture(from: image, device: device) else {
            return false
        }
        livePaperTexture = texture
        return true
    }
    
    /// Uploads any CGImage as an RGBA8 texture usable by the live kernels.
    private static func makeRGBA8Texture(from image: CGImage, device: MTLDevice?) -> MTLTexture? {
        guard let device = device else { return nil }
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        
        let bytesPerRow = w * 4
        var rgba = [UInt8](repeating: 0, count: bytesPerRow * h)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let ok = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress,
                  let ctx = CGContext(data: base,
                                      width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0,
                        withBytes: rgba, bytesPerRow: bytesPerRow)
        return texture
    }
    
    // MARK: - Mipmaps
    
    /// Generates mips for the finished canvas so zooming out below 1:1 does not alias.
    /// Requires `livePresentSampler` (mipFilter == .linear) to be used at present time.
    func generateLiveCanvasMipmaps() throws {
        guard let queue = commandQueue else { throw MetalRendererError.commandQueueMissing }
        let textures = [liveCanvasTexture, liveBackgroundTexture].compactMap { $0 }
        guard !textures.isEmpty else { return }
        guard let commandBuffer = queue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder() else { return }
        for texture in textures where texture.mipmapLevelCount > 1 {
            blit.generateMipmaps(for: texture)
        }
        blit.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let err = commandBuffer.error { throw err }
    }
    
    // MARK: - Accessors for the present pass
    
    /// 1×1 opaque white stand-in, so the paper kernel's texture slot is always bound.
    private static func makePlaceholderTexture(device: MTLDevice?) -> MTLTexture? {
        guard let device = device else { return nil }
        if let cached = placeholderTexture { return cached }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = [.shaderRead]
        desc.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        var white: UInt32 = 0xFFFFFFFF          // RGBA8, little endian
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                        withBytes: &white, bytesPerRow: MemoryLayout<UInt32>.size)
        placeholderTexture = texture
        return texture
    }
    
    var livePresentTextures: (canvas: MTLTexture, background: MTLTexture)? {
        guard let canvas = liveCanvasTexture, let background = liveBackgroundTexture else { return nil }
        return (canvas, background)
    }
}
#endif
