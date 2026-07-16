import Foundation
import CoreGraphics
import Metal
import AppKit
import ArtParser
import ArtRenderLibrary

class Renderer {
    private let device: MTLDevice?
    private let commandQueue: MTLCommandQueue?
    private let canvasSize: CGSize
    private let scale: CGFloat
    private let forceCPU: Bool
    private var artRenderer: ArtRenderLibrary.Renderer?
    
    init(canvasSize: CGSize, scale: CGFloat, forceCPU: Bool = true) {
        self.canvasSize = canvasSize
        self.scale = scale
        self.forceCPU = forceCPU
        self.device = MTLCreateSystemDefaultDevice()
        self.commandQueue = device?.makeCommandQueue()
        
        // Initialize the ArtRenderLibrary renderer
        self.artRenderer = ArtRenderLibrary.Renderer(canvasSize: canvasSize, scale: scale, forceCPU: forceCPU)
    }
    
    func render(art: ArtParser) -> CGImage? {
        NSLog("Renderer: Starting render process")
        
        // Use the ArtRenderLibrary renderer for actual rendering
        guard let renderer = artRenderer else {
            NSLog("Renderer: Failed to initialize ArtRenderLibrary renderer")
            return nil
        }
        
        // Let the ArtRenderLibrary renderer handle the rendering
        let image = renderer.render(art: art)
        
        if image != nil {
            NSLog("Renderer: Successfully rendered image")
        } else {
            NSLog("Renderer: Failed to render image")
        }
        
        return image
    }
    
    // Keep the old methods as fallbacks if needed
//    private func renderWithMetal(device: MTLDevice, commandQueue: MTLCommandQueue, art: ArtParser) -> CGImage? {
//        NSLog("Renderer: Using Metal fallback")
//
//        // Create a Metal texture to render to
//        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
//            pixelFormat: .bgra8Unorm,
//            width: Int(canvasSize.width),
//            height: Int(canvasSize.height),
//            mipmapped: false
//        )
//        textureDescriptor.usage = [.renderTarget, .shaderRead]
//
//        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
//            NSLog("Renderer: Failed to create Metal texture")
//            return nil
//        }
//
//        // Create a render pass descriptor
//        let renderPassDescriptor = MTLRenderPassDescriptor()
//        renderPassDescriptor.colorAttachments[0].texture = texture
//        renderPassDescriptor.colorAttachments[0].loadAction = .clear
//        renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
//        renderPassDescriptor.colorAttachments[0].storeAction = .store
//
//        // Create a command buffer
//        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
//            NSLog("Renderer: Failed to create command buffer")
//            return nil
//        }
//
//        // Create a render command encoder
//        guard let renderEncoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else {
//            NSLog("Renderer: Failed to create render encoder")
//            return nil
//        }
//
//        // Add your Metal rendering code here
//        // For now, we'll just end encoding without drawing anything
//        renderEncoder.endEncoding()
//
//        // Commit the command buffer
//        commandBuffer.commit()
//        commandBuffer.waitUntilCompleted()
//
//        // Create a Core Graphics image from the Metal texture
//        return createCGImage(from: texture)
//    }
//
//    private func renderWithCPU(art: ArtParser) -> CGImage? {
//        NSLog("Renderer: Using CPU fallback")
//
//        let w = Int(canvasSize.width)
//        let h = Int(canvasSize.height)
//        let colorSpace = CGColorSpaceCreateDeviceRGB()
//        guard let ctx = CGContext(data: nil, width: w, height: h,
//                                  bitsPerComponent: 8, bytesPerRow: w * 4,
//                                  space: colorSpace,
//                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
//            NSLog("Renderer: Failed to create CGContext")
//            return nil
//        }
//
//        // Setup coordinate system expected by art rasterizer:
//        ctx.setFillColor(NSColor.white.cgColor)
//        ctx.fill(CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
//
//        ctx.saveGState()
//
//        ctx.restoreGState()
//
//        return ctx.makeImage()
//    }
//
//    private func createCGImage(from texture: MTLTexture) -> CGImage? {
//        // Create a bitmap context
//        let colorSpace = CGColorSpaceCreateDeviceRGB()
//        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
//
//        let bytesPerPixel = 4
//        let bytesPerRow = bytesPerPixel * texture.width
//        let byteCount = bytesPerRow * texture.height
//
//        // Allocate memory for the bitmap
//        let data = UnsafeMutablePointer<UInt8>.allocate(capacity: byteCount)
//        defer { data.deallocate() }
//
//        guard let context = CGContext(data: data,
//                                      width: texture.width,
//                                      height: texture.height,
//                                      bitsPerComponent: 8,
//                                      bytesPerRow: bytesPerRow,
//                                      space: colorSpace,
//                                      bitmapInfo: bitmapInfo.rawValue) else {
//            NSLog("Renderer: Failed to create context for texture conversion")
//            return nil
//        }
//
//        // Get the texture's bytes
//        let region = MTLRegionMake2D(0, 0, texture.width, texture.height)
//        texture.getBytes(data, bytesPerRow: bytesPerRow, from: region, mipmapLevel: 0)
//
//        // Create a CGImage from the context
//        return context.makeImage()
//    }
}
