#if os(macOS)
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

extension MetalRenderer {
    // MARK: - Texture Conversion
    /// Render float source into an 8-bit texture (RGBA8Unorm) using the conversion pipeline, then return that texture.
    /// The returned texture can be created with .shared storage mode to allow getBytes() if you want to read it on CPU.
    func convertFloatTextureTo8bitSync(_ src: MTLTexture) throws -> MTLTexture {
        guard let device = self.device, let queue = self.commandQueue else {
            throw NSError(domain: "MetalRenderer", code: -1, userInfo: [NSLocalizedDescriptionKey: "Missing device or queue"])
        }
        
        // Ensure pipeline exists
        if self.convertPipeline == nil {
            let desc = MTLRenderPipelineDescriptor()
            desc.colorAttachments[0].pixelFormat = .rgba8Unorm
            
            guard let vs = self.library?.makeFunction(name: "vs_passthrough") else {
                throw NSError(domain: "MetalRenderer", code: -2, userInfo: [NSLocalizedDescriptionKey: "Failed to create vertex function"])
            }
            guard let fs = self.library?.makeFunction(name: "fs_convert") else {
                throw NSError(domain: "MetalRenderer", code: -3, userInfo: [NSLocalizedDescriptionKey: "Failed to create fragment function"])
            }
            
            desc.vertexFunction = vs
            desc.fragmentFunction = fs
            self.convertPipeline = try device.makeRenderPipelineState(descriptor: desc)
        }
        guard let pipeline = self.convertPipeline else {
            throw NSError(domain: "MetalRenderer", code: -4, userInfo: [NSLocalizedDescriptionKey: "Failed to create convert pipeline"])
        }
        
        // Create 8-bit texture
        let w = src.width
        let h = src.height
        let descTex = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: w, height: h, mipmapped: false)
        descTex.usage = [.renderTarget, .shaderRead, .shaderWrite]
        descTex.storageMode = .shared
        guard let dst = device.makeTexture(descriptor: descTex) else {
            throw NSError(domain: "MetalRenderer", code: -5, userInfo: [NSLocalizedDescriptionKey: "Failed to create destination texture"])
        }
        
        // Render pass
        guard let cmdBuf = queue.makeCommandBuffer() else {
            throw NSError(domain: "MetalRenderer", code: -6, userInfo: [NSLocalizedDescriptionKey: "Failed to create command buffer"])
        }
        
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = dst
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = MTLClearColorMake(0,0,0,0)
        
        guard let renc = cmdBuf.makeRenderCommandEncoder(descriptor: rpd) else {
            throw NSError(domain: "MetalRenderer", code: -7, userInfo: [NSLocalizedDescriptionKey: "Failed to create render encoder"])
        }
        
        renc.setRenderPipelineState(pipeline)
        renc.setFragmentTexture(src, index: 0)
        renc.setFragmentSamplerState(self.linearSampler, index: 0)
        
        // Draw fullscreen quad (4 vertices)
        renc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        renc.endEncoding()
        
        cmdBuf.commit()
        cmdBuf.waitUntilCompleted()
        
        if let err = cmdBuf.error { throw err }
        return dst
    }
    
    /// Read texture to CGImage synchronously with optimized buffer pool
    func readbackToCGImageSync(_ texture: MTLTexture) throws -> CGImage? {
        guard let device = self.device, let queue = self.commandQueue else {
            throw MetalRendererError.deviceNotAvailable
        }
        
        let width = texture.width
        let height = texture.height
        
        // Ensure we're working with rgba8Unorm format
        guard texture.pixelFormat == .rgba8Unorm else {
            print("Error: Texture format must be rgba8Unorm for proper alpha handling")
            throw MetalRendererError.textureCreationFailed
        }
        
        let bytesPerPixel = 4
        let alignment = 256
        let bytesPerRow = ((width * bytesPerPixel + alignment - 1) / alignment) * alignment
        let bufferSize = bytesPerRow * height
        
        // Create staging buffer
        guard let stagingBuffer = device.makeBuffer(length: bufferSize, options: .storageModeShared) else {
            throw MetalRendererError.bufferCreationFailed
        }
        
        // Create command buffer
        guard let commandBuffer = queue.makeCommandBuffer() else {
            throw MetalRendererError.commandBufferCreationFailed
        }
        
        // Create blit command encoder
        guard let blitEncoder = commandBuffer.makeBlitCommandEncoder() else {
            throw MetalRendererError.commandBufferCreationFailed
        }
        
        // Copy texture to buffer
        let origin = MTLOrigin(x: 0, y: 0, z: 0)
        let size = MTLSize(width: width, height: height, depth: 1)
        
        blitEncoder.copy(from: texture,
                         sourceSlice: 0, sourceLevel: 0,
                         sourceOrigin: origin, sourceSize: size,
                         to: stagingBuffer,
                         destinationOffset: 0,
                         destinationBytesPerRow: bytesPerRow,
                         destinationBytesPerImage: bufferSize)
        
        blitEncoder.endEncoding()
        
        // Commit and wait for completion
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        if let error = commandBuffer.error {
            print("Metal command buffer error: \(error)")
            throw error
        }
        
        // Create CGImage with proper alpha info
        return createCGImageWithProperAlpha(
            data: Data(bytes: stagingBuffer.contents(), count: bufferSize),
            width: width,
            height: height,
            bytesPerRow: bytesPerRow
        )
    }
    
    private func createCGImageWithProperAlpha(data: Data, width: Int, height: Int, bytesPerRow: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: data as CFData) else {
            print("Failed to create CGDataProvider")
            return nil
        }
        
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        
        // Use premultiplied last alpha info for CoreGraphics compatibility
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        
        guard let cgImage = CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ) else {
            print("Failed to create CGImage")
            return nil
        }
        
        return cgImage
    }
    
    // MARK: - Noise Texture Upload
    @discardableResult
    func uploadNoiseTexture(from cgImage: CGImage) -> Bool {
        guard let device = self.device else {
            print("uploadNoiseTexture: no Metal device")
            return false
        }
        
        let w = cgImage.width
        let h = cgImage.height
        if w == 0 || h == 0 {
            print("uploadNoiseTexture: image has zero size")
            return false
        }
        
        // Prefer single-channel r8Unorm if your shader only samples .r, otherwise use rgba8Unorm.
        // Here I'll upload as rgba8Unorm for maximum compatibility; you can switch to r8Unorm if desired.
        let pixelFormat: MTLPixelFormat = .rgba8Unorm
        let bytesPerPixel = 4
        let bytesPerRow = w * bytesPerPixel
        let dataSize = bytesPerRow * h
        
        // Safely obtain raw image bytes from CGImage
        guard cgImage.dataProvider != nil
                //              let cfData = provider.data,
                //              let srcPtr = CFDataGetBytePtr(cfData)
        else {
            // If CGImage doesn't already have a backing buffer in a compatible format,
            // create a CGContext and draw into it (safe path).
            print("uploadNoiseTexture: CGImage has no direct pixel buffer, creating CGContext fallback")
            
            var raw = [UInt8](repeating: 0, count: dataSize)
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) else {
                print("uploadNoiseTexture: failed to create sRGB color space")
                return false
            }
            
            guard let ctx = CGContext(data: &raw,
                                      width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else {
                print("uploadNoiseTexture: failed to create CGContext fallback")
                return false
            }
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            // Create texture and upload raw buffer
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: w, height: h, mipmapped: false)
            desc.usage = [.shaderRead]
            desc.storageMode = .shared
            guard let tex = device.makeTexture(descriptor: desc) else {
                print("uploadNoiseTexture: failed to create texture (fallback)")
                return false
            }
            tex.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: raw, bytesPerRow: bytesPerRow)
            self.noiseTexture = tex
            print("uploadNoiseTexture: uploaded fallback rgba8 texture \(w)x\(h)")
            return true
        }
        
        // If we have direct image bytes, we may need to convert them to RGBA premultiplied last.
        // Many CGImages are in various pixel formats — we'll copy into a temporary RGBA8 buffer using CGContext to ensure consistent layout.
        
        // Create a destination buffer and a CGContext to copy/normalize pixel layout reliably.
        var rgba = [UInt8](repeating: 0, count: dataSize)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: &rgba,
                                  width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                  space: colorSpace,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else {
            print("uploadNoiseTexture: failed to create CGContext for normalization")
            return false
        }
        let drawRect = CGRect(x: 0, y: 0, width: w, height: h)
        ctx.draw(cgImage, in: drawRect)
        
        // Create Metal texture descriptor
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: pixelFormat, width: w, height: h, mipmapped: false)
        desc.usage = [.shaderRead]
        // Use .shared for safety when writing from CPU; on macOS .managed is also possible but .shared works cross-platform.
        desc.storageMode = .shared
        
        guard let texture = device.makeTexture(descriptor: desc) else {
            print("uploadNoiseTexture: failed to create Metal texture")
            return false
        }
        
        // Upload buffer to texture synchronously (safe)
        texture.replace(region: MTLRegionMake2D(0, 0, w, h), mipmapLevel: 0, withBytes: rgba, bytesPerRow: bytesPerRow)
        
        self.noiseTexture = texture
        print("uploadNoiseTexture: noise texture uploaded \(w)x\(h), pixelFormat=\(pixelFormat)")
        return true
    }
    
    // MARK: - Debug Readback
    func readTextureRegion(_ texture: MTLTexture, region: MTLRegion) throws -> [Float] {
        // 1. Throw instead of returning nil
        guard texture.pixelFormat == .rgba32Float else {
            throw MetalRendererError.invalidTextureFormat
        }
        
        let width = region.size.width
        let height = region.size.height
        let originX = region.origin.x
        let originY = region.origin.y
        
        // 2. Validate region with throws
        if originX < 0 || originY < 0 || width <= 0 || height <= 0 ||
            originX + width > texture.width || originY + height > texture.height {
            throw MetalRendererError.invalidTextureRegion
        }
        
        let bytesPerRow = width * 4 * MemoryLayout<Float>.size
        var buffer = [Float](repeating: 0.0, count: Int(width * height * 4))
        
        // 3. Use 'try' with the rethrowing closure
        try buffer.withUnsafeMutableBytes { ptr in
            guard let baseAddress = ptr.baseAddress else {
                throw MetalRendererError.bufferAccessFailed
            }
            
            texture.getBytes(baseAddress,
                             bytesPerRow: bytesPerRow,
                             from: region,
                             mipmapLevel: 0)
        }
        
        return buffer
    }
    
    public func debugPrintPixel(from texture: MTLTexture, x: Int, y: Int, label: String = "") {
        print("=== Reading pixel at (\(x), \(y)) with label '\(label)' ===")
        
        // 1. Basic validation
        guard x >= 0, y >= 0, x < texture.width, y < texture.height else {
            print("ERROR: Coordinates (\(x), \(y)) out of bounds. Texture size: \(texture.width)x\(texture.height)")
            return
        }
        
        print("Texture Pixel Format: \(texture.pixelFormat)")
        
        let region = MTLRegionMake2D(x, y, 1, 1)
        
        // 2. Handle Float Textures
        if texture.pixelFormat == .rgba32Float {
            // Allocate a mutable buffer for 4 floats (R, G, B, A)
            var pixelBuffer = [Float](repeating: 0, count: 4)
            
            // Get the mutable raw pointer
            pixelBuffer.withUnsafeMutableBytes { rawBufferPointer in
                if let baseAddress = rawBufferPointer.baseAddress {
                    texture.getBytes(baseAddress,
                                     bytesPerRow: 4 * MemoryLayout<Float>.stride,
                                     from: region,
                                     mipmapLevel: 0)
                }
            }
            
            let prefix = label.isEmpty ? "GPU pixel(\(x),\(y))" : "GPU pixel(\(x),\(y))[\(label)]"
            print(String(format: "\(prefix) [float4] = (%.4f, %.4f, %.4f, %.4f)",
                         pixelBuffer[0], pixelBuffer[1], pixelBuffer[2], pixelBuffer[3]))
            
        }
        // 3. Handle 8-bit Textures
        else if texture.pixelFormat == .bgra8Unorm || texture.pixelFormat == .rgba8Unorm {
            
            // Allocate a mutable buffer for 4 bytes (R, G, B, A)
            var pixelBuffer = [UInt8](repeating: 0, count: 4)
            
            pixelBuffer.withUnsafeMutableBytes { rawBufferPointer in
                if let baseAddress = rawBufferPointer.baseAddress {
                    texture.getBytes(baseAddress,
                                     bytesPerRow: 4 * MemoryLayout<UInt8>.stride,
                                     from: region,
                                     mipmapLevel: 0)
                }
            }
            
            // If format is BGRA, the array is [B, G, R, A]. We want to print R, G, B, A.
            // Pixel 0 = B, Pixel 1 = G, Pixel 2 = R, Pixel 3 = A
            let b = Float(pixelBuffer[0]) / 255.0
            let g = Float(pixelBuffer[1]) / 255.0
            let r = Float(pixelBuffer[2]) / 255.0
            let a = Float(pixelBuffer[3]) / 255.0
            
            let prefix = label.isEmpty ? "GPU pixel(\(x),\(y))" : "GPU pixel(\(x),\(y))[\(label)]"
            print(String(format: "\(prefix) [8-bit] = (%.4f, %.4f, %.4f, %.4f)", r, g, b, a))
        }
        else {
            print("ERROR: Unsupported pixel format \(texture.pixelFormat) for debug read.")
        }
        
        print("=== End pixel read ===")
    }
    
    internal func debugPrintPixelZero(from texture: MTLTexture) {
        debugPrintPixel(from: texture, x: 0, y: 0)
    }
}
#endif
