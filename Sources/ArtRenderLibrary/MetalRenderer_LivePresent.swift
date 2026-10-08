//
//  MetalRenderer_LivePresent.swift
//  ArtRenderLibrary
//
//  Draws a composited live canvas into a target through the user view transform.
//
//  The whole interaction model lives in the vertex shader: the canvas is a single
//  quad whose corners are pushed through a canvas-pixels → clip-space matrix, so
//  pan / zoom / rotate never re-renders anything.
//

#if os(macOS)
import Metal
import CoreGraphics
import QuartzCore // CAMetalDrawable lives in CoreAnimation/QuartzCore, no texture on MTLDrawable

extension MetalRenderer {
    
    // MARK: - Present to a drawable
    
    /// Presents `canvas` into `drawable` using `transform`.
    ///
    /// - Parameter flipVertically: canvas row-order escape hatch. `false` puts canvas
    ///   row 0 at the top of the screen, which is what the static path implies (the
    ///   y-down CoreGraphics context puts a CGImage's row 0 at the visual top). Flip it
    ///   if the document comes up mirrored. Only the present pass is affected — geometry
    ///   and compositing never care.
    /// - Returns: the command buffer, already committed (not waited on).
    @discardableResult
    func presentLiveCanvas(_ canvas: LiveRenderedCanvas,
                           to drawable: MTLDrawable,
                           transform: LiveViewTransform,
                           clearColor: MTLClearColor = MTLClearColorMake(0, 0, 0, 1),
                           flipVertically: Bool = false) throws -> MTLCommandBuffer? {
        guard let camDrawable = drawable as? CAMetalDrawable else {
            throw MetalRendererError.unsupportedDrawable
        }
        return try presentLiveCanvas(canvas,
                                     to: camDrawable.texture,
                                     pipeline: livePresentPipeline,
                                     transform: transform,
                                     clearColor: clearColor,
                                     flipVertically: flipVertically,
                                     waitForCompletion: false)
    }
    
    /// Shared present body. `pipeline` is chosen by the caller: drawables are
    /// `.bgra8Unorm`, offscreen readback targets are `.rgba8Unorm`.
    @discardableResult
    func presentLiveCanvas(_ canvas: LiveRenderedCanvas,
                           to target: MTLTexture,
                           pipeline: MTLRenderPipelineState?,
                           transform: LiveViewTransform,
                           clearColor: MTLClearColor = MTLClearColorMake(0, 0, 0, 1),
                           flipVertically: Bool = false,
                           waitForCompletion: Bool) throws -> MTLCommandBuffer? {
        guard let pipeline = pipeline,
              let queue = commandQueue,
              let commandBuffer = queue.makeCommandBuffer() else {
            throw MetalRendererError.rendererNotInitialized
        }
        
        // Bind the textures carried by `canvas` itself (not the renderer's current
        // ones): the canvas may have been handed to the UI thread already, and the
        // renderer may be busy on its own queue.
        let canvasTexture = canvas.canvasTexture
        let backgroundTexture = canvas.backgroundTexture
        
        let drawableSize = CGSize(width: target.width, height: target.height)
        let uniforms = Self.livePresentUniforms(transform: transform,
                                                canvasPixelSize: canvas.pixelSize,
                                                viewportSize: drawableSize,
                                                flipVertically: flipVertically)
        
        // A ring of uniform buffers: MTKView keeps several drawables in flight, and
        // frame N must not be shaded with frame N+1's transform.
        guard !livePresentUniformsBuffers.isEmpty else {
            throw MetalRendererError.bufferCreationFailed
        }
        livePresentUniformsIndex = (livePresentUniformsIndex + 1) % livePresentUniformsBuffers.count
        let buffer = livePresentUniformsBuffers[livePresentUniformsIndex]
        buffer.contents()
            .assumingMemoryBound(to: LivePresentUniforms.self)
            .pointee = uniforms
        
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = clearColor
        
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
            throw MetalRendererError.commandBufferCreationFailed
        }
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(canvasTexture, index: 0)
        encoder.setFragmentTexture(backgroundTexture, index: 1)
        if let sampler = livePresentSampler ?? linearSampler {
            encoder.setFragmentSamplerState(sampler, index: 0)
        }
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentBuffer(buffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        
        commandBuffer.commit()
        if waitForCompletion {
            commandBuffer.waitUntilCompleted()
            if let err = commandBuffer.error { throw err }
        }
        return commandBuffer
    }
    
    // MARK: - Present offscreen (test/debug aid)
    
    /// Runs the present pass into an offscreen RGBA texture and hands it back, so the
    /// exact image the live view shows can be read back to a `CGImage`
    /// (`art2png --live`).
    func renderLivePreviewTexture(_ canvas: LiveRenderedCanvas,
                                  transform: LiveViewTransform,
                                  size: CGSize,
                                  flipVertically: Bool = false) throws -> MTLTexture? {
        guard let device = self.device else { throw MetalRendererError.deviceNotAvailable }
        let width = max(Int(size.width), 1)
        let height = max(Int(size.height), 1)
        
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .shared
        guard let target = device.makeTexture(descriptor: desc) else {
            throw MetalRendererError.textureCreationFailed
        }
        
        try presentLiveCanvas(canvas,
                              to: target,
                              pipeline: livePresentPipelineRGBA,
                              transform: transform,
                              flipVertically: flipVertically,
                              waitForCompletion: true)
        return target
    }
    
    // MARK: - Uniforms

    /// Builds the canvas-pixels → clip-space matrix for the shader uniform struct.
    ///
    /// All of the maths lives in `LiveViewTransform.clipMatrix` (portable, unit tested);
    /// this only flattens it into the shader's scalar layout and applies the optional
    /// vertical flip of the canvas.
    static func livePresentUniforms(transform: LiveViewTransform,
                                   canvasPixelSize: CGSize,
                                   viewportSize: CGSize,
                                   flipVertically: Bool = false) -> LivePresentUniforms {
        var clip = transform.clipMatrix(canvasPixelSize: canvasPixelSize,
                                         viewportSize: viewportSize)
        if flipVertically {
            // Mirror inside the canvas: y → canvasHeight - y, composed after the view
            // transform so only the canvas's own row order changes.
            clip = clip.concatenated(with: LiveViewMatrix(a: 1, b: 0, c: 0, d: -1,
                                                           tx: 0, ty: canvasPixelSize.height))
        }
        return LivePresentUniforms(
            m00: Float(clip.a), m10: Float(clip.b),
            m01: Float(clip.c), m11: Float(clip.d),
            m02: Float(clip.tx), m12: Float(clip.ty),
            canvasW: Float(canvasPixelSize.width), canvasH: Float(canvasPixelSize.height))
    }
}
#endif
