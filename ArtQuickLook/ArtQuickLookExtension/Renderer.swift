import Foundation
import CoreGraphics
//import Metal
import AppKit
import ArtParser
import ArtRenderLibrary

class Renderer {
//    private let device: MTLDevice?
//    private let commandQueue: MTLCommandQueue?
    private let canvasSize: CGSize
    private let scale: CGFloat
    private let forceCPU: Bool
    private let useSegmentRendering: Bool
    private var artRenderer: ArtRenderLibrary.Renderer?
    
    init(canvasSize: CGSize, scale: CGFloat, forceCPU: Bool = false, useSegmentRendering: Bool = true) {
        self.canvasSize = canvasSize
        self.scale = scale
        self.forceCPU = forceCPU
        self.useSegmentRendering = useSegmentRendering
//        self.device = MTLCreateSystemDefaultDevice()
//        self.commandQueue = device?.makeCommandQueue()
        
        // Initialize the ArtRenderLibrary renderer
        self.artRenderer = ArtRenderLibrary.Renderer(canvasSize: canvasSize, scale: scale, forceCPU: forceCPU, useSegmentRendering: useSegmentRendering)
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
}
