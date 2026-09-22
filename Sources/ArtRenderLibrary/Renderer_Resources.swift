import Foundation
#if os(Linux)
import Silica
import CoreFoundation
//import Cairo
import JPEG
#elseif os(macOS)
import CoreGraphics
#endif

#if canImport(ImageIO)
import ImageIO
#endif

#if canImport(Metal)
import Metal
#endif

extension Renderer {
    // MARK: - Noise Resources
    
    internal func loadNoiseImage(named name: String) {
        print("DEBUG: Attempting to load noise image: \(name)")
        
        guard noiseImage == nil else {
            print("DEBUG: Noise image already loaded")
            return
        }
        
#if os(macOS)
        // Get the plugin's bundle
        let pluginBundle = Bundle(for: type(of: self))
        print("DEBUG: Plugin bundle path: \(pluginBundle.bundlePath)")
        
        // Find the ArtRenderLibrary bundle inside the plugin's resources
        guard let bundleURL = pluginBundle.url(forResource: "art2png_ArtRenderLibrary", withExtension: "bundle"),
              let resourceBundle = Bundle(url: bundleURL) else {
            print("DEBUG: Could not find ArtRenderLibrary bundle")
            return
        }
        
        print("DEBUG: Found resource bundle at: \(resourceBundle.bundlePath)")
        
        // Try loading from the resource bundle
        guard let url = resourceBundle.url(forResource: name, withExtension: nil) else {
            print("DEBUG: Could not find URL for resource: \(name)")
            print("DEBUG: Available resources in bundle: \(resourceBundle.urls(forResourcesWithExtension: nil, subdirectory: nil) ?? [])")
            return
        }
        
        print("DEBUG: Found URL: \(url)")
        
        // Load the image using ImageIO
#if canImport(ImageIO)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            print("DEBUG: Could not create image source from URL")
            return
        }
        
        guard let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            print("DEBUG: Could not create image from image source")
            return
        }
        
        noiseImage = img
        noiseImageSize = CGSize(width: img.width, height: img.height)
        print("DEBUG: Successfully loaded noise image: \(noiseImageSize)")
#else
        print("DEBUG: ImageIO not available on this platform")
        return
#endif
        
        // Create normalized version
        normalizeNoiseImage()
        
#elseif os(Linux)
        // On Linux, try loading from common filesystem paths
        let searchPaths = [
            "./\(name)",
            "./resources/\(name)",
            "./Textures/\(name)",
            "/usr/share/art2png/\(name)"
        ]
        
        for path in searchPaths {
            let filePath: String
            if name.hasSuffix(".png") || name.hasSuffix(".jpg") || name.hasSuffix(".jpeg") {
                filePath = path
            } else {
                filePath = path + ".png"
            }
            
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: filePath)) else {
                continue
            }
            
            if let img = Self.loadImageFromData(data) {
                noiseImage = img
                noiseImageSize = CGSize(width: img.width, height: img.height)
                print("DEBUG: Successfully loaded noise image from: \(filePath), size: \(noiseImageSize)")
                normalizeNoiseImage()
                return
            }
        }
        
        print("DEBUG: Could not load noise image from any path on Linux")
#endif
    }
    
    private func normalizeNoiseImage() {
        guard let noise = noiseImage else {
            print("DEBUG: No noise image to normalize")
            return
        }
        
        let width = noise.width
        let height = noise.height
        
        print("DEBUG: Normalizing noise image: \(width)x\(height)")
        
        // Create a bitmap context for processing
#if os(Linux)
        guard let context = createLinuxBitmapContext(width: width, height: height) else {
            print("DEBUG: Failed to create context for normalization")
            return
        }
        let bytesPerRow = context.bytesPerRow
#else
        let bitsPerComponent = 8
        let bytesPerRow = width * 4
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        
        guard let context = CGContext(data: nil,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: bitsPerComponent,
                                      bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            print("DEBUG: Failed to create context for normalization")
            return
        }
#endif
        
        // Draw the original image
        context.draw(noise, in: CGRect(x: 0, y: 0, width: width, height: height))
        
        // Get the pixel data
        guard let rawData = context.data else {
            print("DEBUG: Failed to get pixel data")
            return
        }
        
        let pixels = rawData.assumingMemoryBound(to: UInt8.self)
        
        // First pass: find min and max values
        var minRed: UInt8 = 255
        var maxRed: UInt8 = 0
        
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * 4)
                let r = pixels[offset]
                
                if r < minRed { minRed = r }
                if r > maxRed { maxRed = r }
            }
        }
        
        print("DEBUG: Noise normalization - minRed: \(minRed), maxRed: \(maxRed)")
        
        // Second pass: normalize and enhance
        let range = maxRed - minRed
        for y in 0..<height {
            for x in 0..<width {
                let offset = (y * bytesPerRow) + (x * 4)
                let r = pixels[offset]
                
                // Normalize to [0, 255]
                var normalized: UInt8
                if range > 0 {
                    normalized = UInt8(((Int(r) - Int(minRed)) * 255) / Int(range))
                } else {
                    normalized = 128
                }
                
                // Enhance contrast with power curve
                let enhanced = pow(Float(normalized) / 255.0, 0.5) * 255.0
                pixels[offset] = UInt8(enhanced)
                pixels[offset + 1] = UInt8(enhanced)
                pixels[offset + 2] = UInt8(enhanced)
            }
        }
        
        // Create the normalized image
        normalizedNoiseImage = context.makeImage()
        print("DEBUG: Created normalized noise image")
    }
    
    private func getOrCreateNoiseContext(width: Int, height: Int) -> CGContext? {
        // Check if we have a suitable context in the pool
        for i in 0..<noiseContextPool.count {
            let ctx = noiseContextPool[i]
            if ctx.width == width && ctx.height == height {
                return noiseContextPool.remove(at: i)
            }
        }
        
        // Create a new context
        // Use sRGB instead of CGColorSpaceCreateDeviceRGB() for Silica compatibility
        let bitsPerComponent = 8
        let bytesPerRow = width * 4
        let bufSize = height * bytesPerRow
        guard let ctxData = malloc(bufSize) else { return nil }
        
#if os(Linux)
        guard let cgCtx = createLinuxBitmapContext(width: width, height: height, data: ctxData, bytesPerRow: bytesPerRow) else {
            free(ctxData)
            return nil
        }
#else
        guard let cgCtx = CGContext(
            data: ctxData,
            width: width,
            height: height,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            free(ctxData)
            return nil
        }
#endif
        
        return cgCtx
    }
    
    private func returnNoiseContextToPool(_ context: CGContext) {
        if noiseContextPool.count < maxNoiseContextPoolSize {
            // Clear the context before returning to pool (cross-platform)
            Self.clearContext(context, rect: CGRect(x: 0, y: 0, width: context.width, height: context.height))
            noiseContextPool.append(context)
        }
        // If pool is full, the context will be deallocated when it goes out of scope
    }
    
    internal func makeNoiseTileInto(center: CGPoint, radius: CGFloat,
                                    rotation: CGFloat, offset: CGPoint,
                                    canvasW: Int, canvasH: Int,
                                    tileOrigin: inout CGPoint,
                                    buf: inout TileBuffer) -> (UnsafeMutablePointer<UInt8>?, Int, Int)
    {
        // Use normalized noise image if available, otherwise fall back to original
        guard let noise = normalizedNoiseImage ?? noiseImage else {
            return (nil, 0, 0)
        }
        
        let pad: CGFloat = 2
        
        let minX = floor(center.x - radius - pad)
        let minY = floor(center.y - radius - pad)
        let maxX = ceil(center.x + radius + pad)
        let maxY = ceil(center.y + radius + pad)
        let tileW = max(1, Int(maxX - minX))
        let tileH = max(1, Int(maxY - minY))
        
        if tileW <= 0 || tileH <= 0 { return (nil, 0, 0) }
        
        tileOrigin.x = minX
        tileOrigin.y = minY
        
        let dstX = Int(tileOrigin.x)
        let dstY = Int(tileOrigin.y)
        if dstX >= canvasW || dstY >= canvasH || dstX + tileW <= 0 || dstY + tileH <= 0 {
            return (nil, 0, 0)
        }
        
        guard let cgCtx = getOrCreateNoiseContext(width: tileW, height: tileH) else {
            return (nil, 0, 0)
        }
        
        // Clear context with a neutral gray (cross-platform)
        Self.clearContext(cgCtx, rect: CGRect(x: 0, y: 0, width: tileW, height: tileH))
        cgCtx.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
        cgCtx.fill(CGRect(x: 0, y: 0, width: tileW, height: tileH))
        
        cgCtx.saveGState()
        
        cgCtx.translateBy(x: CGFloat(tileW)/2.0, y: CGFloat(tileH)/2.0)
        cgCtx.rotate(by: rotation)
        cgCtx.translateBy(x: -CGFloat(tileW)/2.0, y: -CGFloat(tileH)/2.0)
        
        let imgW = noise.width
        let imgH = noise.height
        
        let textureScale: CGFloat = 0.6
        
        let destW = CGFloat(imgW) * textureScale
        let destH = CGFloat(imgH) * textureScale
        
        let offsetX = offset.x
        let offsetY = offset.y
        
        let destRect = CGRect(x: offsetX, y: offsetY, width: destW, height: destH)
        
        // Cross-platform tiled drawing
        Self.drawImageTiled(noise, in: destRect, context: cgCtx)
        
        cgCtx.restoreGState()
        
        // Extract RED channel as alpha values
        let dstPtr = buf.allocTile(width: tileW, height: tileH)
        
        guard let ctxData = cgCtx.data else {
            returnNoiseContextToPool(cgCtx)
            return (nil, 0, 0)
        }
        
        let srcPtr = ctxData.assumingMemoryBound(to: UInt8.self)
        let bytesPerRow = cgCtx.bytesPerRow
        
        for row in 0..<tileH {
            let srcRow = srcPtr.advanced(by: row * bytesPerRow)
            let dstRow = dstPtr.advanced(by: row * tileW)
            for col in 0..<tileW {
                let r = srcRow[col * 4 + 0]
                dstRow[col] = r
            }
        }
        
        returnNoiseContextToPool(cgCtx)
        
        return (dstPtr, tileW, tileH)
    }
    
    // MARK: - Paper and Background
    internal func getPaperColor(for paperTextureId: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        switch paperTextureId {
            case 1: return (243/255.0, 243/255.0, 243/255.0)
            case 2: return (205/255.0, 202/255.0, 183/255.0)
            case 3: return (247/255.0, 247/255.0, 247/255.0)
            case 4: return (203/255.0, 197/255.0, 185/255.0)
            case 5: return (128/255.0, 124/255.0, 120/255.0)
            case 6: return (192/255.0, 180/255.0, 154/255.0)
            case 7: return (230/255.0, 230/255.0, 230/255.0)
            case 8: return (243/255.0, 243/255.0, 242/255.0)
            case 9: return (242/255.0, 242/255.0, 241/255.0)
            case 10: return (250/255.0, 246/255.0, 221/255.0)
            case 11: return (232/255.0, 232/255.0, 232/255.0)
            case 12: return (232/255.0, 231/255.0, 226/255.0)
            case 13: return (188/255.0, 193/255.0, 197/255.0)
            case 14: return (231/255.0, 227/255.0, 203/255.0)
            case 15: return (190/255.0, 196/255.0, 150/255.0)
            case 16: return (179/255.0, 202/255.0, 215/255.0)
            case 17: return (128/255.0, 128/255.0, 149/255.0)
            case 18: return (131/255.0, 131/255.0, 131/255.0)
            case 19: return (174/255.0, 174/255.0, 183/255.0)
            default: return (1.0, 1.0, 1.0) // Default to white
        }
    }
    
    internal func createSRGBColor(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1.0) -> CGColor {
#if os(Linux)
        return CGColor(red: r, green: g, blue: b, alpha: a)
#else
        return CGColor(colorSpace: sRGBColorSpace, components: [r, g, b, a])!
#endif
    }
    
    static func drawImageTiled(_ image: CGImage, in rect: CGRect, context: CGContext, scale: CGFloat = 1.0) {
#if os(macOS)
        //        context.saveGState()
        let scaledRect = CGRect(
            x: rect.origin.x,
            y: rect.origin.y,
            width: CGFloat(image.width) * scale,
            height: CGFloat(image.height) * scale
        )
        context.draw(image, in: scaledRect, byTiling: true)
        //        context.restoreGState()
#else
        // On Linux, we calculate the scaled tile size manually.
        let imgW = CGFloat(image.width) * scale
        let imgH = CGFloat(image.height) * scale
        
        guard imgW > 0 && imgH > 0 else { return }
        
        var y = rect.origin.y
        while y < rect.origin.y + rect.height {
            var x = rect.origin.x
            while x < rect.origin.x + rect.width {
                // Draw the image into the smaller (scaled) rectangle.
                // Cairo/CoreGraphics will automatically scale the image pixels to fit this rect.
                context.draw(image, in: CGRect(x: x, y: y, width: imgW, height: imgH))
                x += imgW
            }
            y += imgH
        }
#endif
    }
    
    internal func renderPaperTexture(
        textureData: [UInt8],
        paperColor: (r: CGFloat, g: CGFloat, b: CGFloat),
        paperStrength: Float,
        backgroundColor: [UInt8],
        in context: CGContext
    ) {
        let data = Data(textureData)
        
#if os(Linux)
        guard let textureImage = Self.loadImageFromData(data) else {
            context.setFillColor(createSRGBColor(r: paperColor.r, g: paperColor.g, b: paperColor.b))
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            return
        }
#else
        guard let imageProvider = Self.createDataProvider(from: data),
              let textureImage = CGImage(
                jpegDataProviderSource: imageProvider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
              ) else {
            context.setFillColor(createSRGBColor(r: paperColor.r, g: paperColor.g, b:   paperColor.b))
            context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            return
        }
#endif
        
        // Fill with paper color first
        context.setFillColor(createSRGBColor(r: paperColor.r, g: paperColor.g, b: paperColor.b))
        context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
        
        // Apply the texture with tiling
        context.saveGState()
        context.setAlpha(CGFloat(paperStrength))
        
        // Use the full page size for the destination rect
        let textureRect = CGRect(x: 0, y: 0, width: context.width, height: context.height)
        
        // Pass the 0.67 multiplier to the scale parameter
        Self.drawImageTiled(textureImage, in: textureRect, context: context, scale: 0.666 * scale)
        
        context.restoreGState()
    }
    
    // MARK: - Image Helpers
#if os(Linux)
    /// Load a CGImage from image data on Linux using Cairo and swift-jpeg.
    internal static func loadImageFromData(_ data: Data) -> CGImage? {
        // Try PNG
        if let surface = try? Cairo.Surface.Image(png: data) {
            return CGImage(surface: surface)
        }
        
        // Try JPEG
        // Convert data to a byte array to be used as the stream source
        var bytes = [UInt8](data)
        
        // Pass the array directly as the stream source
        if let image: JPEG.Data.Rectangular<JPEG.Common> = try? .decompress(stream: &bytes) {
            let rgb = image.unpack(as: JPEG.RGB.self)
            let width = image.size.x
            let height = image.size.y
            
            // Convert RGB to ARGB (add alpha channel)
            var argbPixels: [UInt8] = []
            argbPixels.reserveCapacity(width * height * 4)
            for pixel in rgb {
                argbPixels.append(contentsOf: [pixel.r, pixel.g, pixel.b, 0xFF])
            }
            
            // Use bufferPointer to match Cairo's UnsafeMutablePointer<UInt8>
            let surface = argbPixels.withUnsafeMutableBufferPointer { bufferPointer -> Cairo.Surface.Image? in
                guard let baseAddress = bufferPointer.baseAddress else { return nil }
                return try? Cairo.Surface.Image(
                    mutableBytes: baseAddress,
                    format: .argb32,
                    width: width,
                    height: height,
                    stride: width * 4
                )
            }
            
            if let surface = surface {
                return CGImage(surface: surface)
            }
        }
        
        return nil
    }
#endif
    
    /// Create a CGDataProvider from Data in a cross-platform way.
    /// macOS requires `data as CFData`; Silica takes `Data` directly.
#if os(Linux)
    internal static func createDataProvider(from data: Data) -> CGDataProvider? {
        return CGDataProvider(data: data)
    }
#else
    internal static func createDataProvider(from data: Data) -> CGDataProvider? {
        return CGDataProvider(data: data as CFData)
    }
#endif
    
    /// Clear a CGContext rect in a cross-platform way.
    /// On macOS, uses the native `clear(_ rect:)`.
    /// On Linux/Silica, uses `.copy` blend mode + transparent fill.
#if os(Linux)
    internal static func clearContext(_ context: CGContext, rect: CGRect) {
        context.saveGState()
        context.setBlendMode(.copy)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        context.fill(rect)
        context.restoreGState()
    }
#else
    internal static func clearContext(_ context: CGContext, rect: CGRect) {
        context.clear(rect)
    }
#endif
    
    /// Cross-platform grayscale color space for mask images.
#if os(Linux)
    internal static let maskColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
#else
    internal static let maskColorSpace = CGColorSpace(name: CGColorSpace.linearGray)!
#endif
    
#if canImport(Metal)
    internal func createLayerTexture() {
        guard let device = metalRenderer?.device else { return }
        
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, // Use .rgba8Unorm_srgb if you want sRGB
            width: Int(canvasSize.width * scale),
            height: Int(canvasSize.height * scale),
            mipmapped: false
        )
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        
        layerTexture = device.makeTexture(descriptor: textureDescriptor)
    }
#endif
    
}

internal func createBitmapContext(size: CGSize, scale: CGFloat) -> CGContext {
#if os(Linux)
    let w = Int(size.width * scale)
    let h = Int(size.height * scale)
    guard let ctx = createLinuxBitmapContext(width: w, height: h) else {
        fatalError("Failed to create bitmap context")
    }
    return ctx
#else
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    return CGContext(
        data: nil,
        width: Int(size.width * scale),
        height: Int(size.height * scale),
        bitsPerComponent: 8,
        bytesPerRow: Int(size.width * scale * 4),
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
    )!
#endif
}
