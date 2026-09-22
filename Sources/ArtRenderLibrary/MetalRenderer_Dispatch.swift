#if os(macOS)
import Metal
import CoreGraphics
//import ImageIO
//import UniformTypeIdentifiers

extension MetalRenderer {
    // MARK: - Stamp Dispatch
    internal func renderStampBatchWithBlending(stamps: [Stamp],
                                              target: MTLTexture,
                                              color: SIMD4<Float>,
                                              isEraser: Bool,
                                              isMarker: Bool) throws {
        guard MetalRenderer.useGPURendering else {
            throw MetalRendererError.rendererNotInitialized
        }
        
        guard let device = self.device else {
            throw MetalRendererError.deviceNotAvailable
        }
        guard let commandQueue = self.commandQueue else {
            throw MetalRendererError.commandQueueMissing
        }
        
        // Validate stamp data
        for s in stamps {
            if !s.center.x.isFinite || !s.center.y.isFinite || !s.radius.isFinite || s.radius <= 0 {
                throw MetalRendererError.invalidStampData
            }
        }
        
        // Ensure stampBuffer capacity
        let stampStride = MemoryLayout<Stamp>.stride
        let neededStampBytes = stampStride * stamps.count
        if stampBuffer == nil || stampBuffer!.length < neededStampBytes {
            stampBuffer = device.makeBuffer(length: neededStampBytes, options: .storageModeShared)
            if stampBuffer == nil {
                throw MetalRendererError.textureCreationFailed
            }
        }
        
        // Copy stamps into stampBuffer
        if let sb = stampBuffer {
            let dst = sb.contents().assumingMemoryBound(to: Stamp.self)
            dst.assign(from: stamps, count: stamps.count)
        } else {
            throw MetalRendererError.rendererNotInitialized
        }
        
        // Ensure paramsBuffer exists
        if paramsBuffer == nil {
            paramsBuffer = device.makeBuffer(length: MemoryLayout<Params>.stride, options: .storageModeShared)
            if paramsBuffer == nil { throw MetalRendererError.rendererNotInitialized }
        }
        
        // Build Params with isEraser flag - ensure color alpha is properly set
        let params = Params(
            textureWidth: UInt32(target.width),
            textureHeight: UInt32(target.height),
            tileSize: UInt32(tileSize),
            tilesPerRow: (UInt32(target.width) + UInt32(tileSize) - 1) / UInt32(tileSize),
            stampCount: UInt32(stamps.count),
            penColor: color,
            noiseScale: 0.4,
            isEraser: isEraser,
            isMarker: isMarker
        )
        
        // Debug: Print pen color alpha
        //        print("DEBUG: renderStampBatchWithBlending - penColor.a: \(params.penColor[3]), isEraser: \(isEraser)")
        
        // Upload params
        if let pb = paramsBuffer {
            let pptr = pb.contents().assumingMemoryBound(to: Params.self)
            pptr.pointee = params
        }
        
        // Create command buffer
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandBufferCreationFailed
        }
        
        // --- Select pencil/noise pipeline if any stamp has noiseSeed ---
        let hasNoise = stamps.contains { $0.noiseSeed != 0 }
        
        //        DEBUG
        //        print("hasNoise:", hasNoise)
        //        print("has noisePipeline:", self.highQualityStampWithNoisePipeline != nil)
        //        print("has noiseTexture:", self.noiseTexture != nil)
        
        if hasNoise,
           let noisePipeline = self.highQualityStampWithNoisePipeline,
           let noiseTex = self.noiseTexture
        {
            // --- TILE INDEXING SETUP ---
            let (tileIndicesData, tileListData) = buildTileIndices(stamps: stamps,
                                                                   textureWidth: target.width,
                                                                   textureHeight: target.height,
                                                                   tileSize: tileSize) // Matches smin footprint
            
            // --- Handle Empty Scenes ---
            if tileListData.isEmpty {
                // Nothing to draw for this tile.
                // We can simply return here, or clear the texture if needed.
                // Since we are in a command buffer submission, usually we just
                // don't encode any commands if there's nothing to do.
                return
            }
            
            // Create buffers for the tile data
            guard let tileIndicesBuffer = device.makeBuffer(bytes: tileIndicesData,
                                                            length: MemoryLayout<TileIndex>.stride * tileIndicesData.count,
                                                            options: .storageModeShared),
                  let tileListBuffer = device.makeBuffer(bytes: tileListData,
                                                         length: MemoryLayout<UInt32>.stride * tileListData.count,
                                                         options: .storageModeShared) else {
                print("Noise strokes: Buffer allocation failed unexpectedly.")
                throw MetalRendererError.bufferCreationFailed
            }
            
            // Define thread groups once at the top level to ensure they are in scope
            let threadGroupSize = MTLSize(width: 8, height: 8, depth: 1)
            let threadGroupCount = MTLSize(
                width: (target.width + threadGroupSize.width - 1) / threadGroupSize.width,
                height: (target.height + threadGroupSize.height - 1) / threadGroupSize.height,
                depth: 1
            )
            
            // --- COMBINED PASS: Distance Field, Noise, and Composite ---
            guard let noiseEncoder = commandBuffer.makeComputeCommandEncoder() else {
                throw MetalRendererError.commandBufferCreationFailed
            }
            
            // Create a buffer for the pen color and isEraser flag (matching AA pattern)
            let paramsBufferSize = MemoryLayout<Params>.stride
            let paramsBufferForNoise = device.makeBuffer(length: paramsBufferSize, options: .storageModeShared)
            if let pb = paramsBufferForNoise {
                let pptr = pb.contents().assumingMemoryBound(to: Params.self)
                pptr.pointee = params
            }
            
            noiseEncoder.setComputePipelineState(noisePipeline)
            
            // Bind parameters, stamps, and tile lookup maps
            if let pb = paramsBufferForNoise { noiseEncoder.setBuffer(pb, offset: 0, index: 0) }
            if let sb = stampBuffer  { noiseEncoder.setBuffer(sb, offset: 0, index: 1) }
            noiseEncoder.setBuffer(tileIndicesBuffer, offset: 0, index: 2)
            noiseEncoder.setBuffer(tileListBuffer, offset: 0, index: 3)
            
            // Bind Textures: Target Canvas(0), Noise Palette(1)
            noiseEncoder.setTexture(target, index: 0)
            noiseEncoder.setTexture(noiseTex, index: 1)
            
            if let samp = self.linearSampler { noiseEncoder.setSamplerState(samp, index: 0) }
            
            noiseEncoder.dispatchThreadgroups(threadGroupCount, threadsPerThreadgroup: threadGroupSize)
            noiseEncoder.endEncoding()
        } else {
            // fall through to existing two-pass / single-pass code
            // (keep the rest of the function unchanged)
            // <existing two-pass / single-pass block continues here>
            // Use existing two-pass approach
            if let distanceFieldPipeline = self.distanceFieldMaskPipeline,
               let antiAliasPipeline = self.highQualityAntiAliasPipeline,
               let distanceFieldTexture = self.distanceFieldTexture,
               let opacityFieldTexture = self.opacityFieldTexture {
                
                // --- TILE INDEXING SETUP ---
                //                let tSize = 32 // Match params.tileSize
                let (tileIndicesData, tileListData) = buildTileIndices(stamps: stamps,
                                                                       textureWidth: target.width,
                                                                       textureHeight: target.height,
                                                                       tileSize: tileSize)
                
                // --- Handle Empty Scenes ---
                if tileListData.isEmpty {
                    // Nothing to draw for this tile.
                    // We can simply return here, or clear the texture if needed.
                    // Since we are in a command buffer submission, usually we just
                    // don't encode any commands if there's nothing to do.
                    return
                }
                
                // Create buffers for the tile data
                guard let tileIndicesBuffer = device.makeBuffer(bytes: tileIndicesData,
                                                                length: MemoryLayout<TileIndex>.stride * tileIndicesData.count,
                                                                options: .storageModeShared),
                      let tileListBuffer = device.makeBuffer(bytes: tileListData,
                                                             length: MemoryLayout<UInt32>.stride * tileListData.count,
                                                             options: .storageModeShared) else {
                    // Now this error block is only for legitimate allocation failures
                    print("distanceField strokes: Buffer allocation failed unexpectedly.")
                    throw MetalRendererError.bufferCreationFailed
                }
                // ---------------------------
                
                // First pass: create distance field and opacity field
                guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                    throw MetalRendererError.commandBufferCreationFailed
                }
                
                encoder.setComputePipelineState(distanceFieldPipeline)
                if let pb = paramsBuffer { encoder.setBuffer(pb, offset: 0, index: 0) }
                if let sb = stampBuffer  { encoder.setBuffer(sb, offset: 0, index: 1) }
                
                // Bind the new tile lookup buffers
                encoder.setBuffer(tileIndicesBuffer, offset: 0, index: 2)
                encoder.setBuffer(tileListBuffer, offset: 0, index: 3)
                
                encoder.setTexture(distanceFieldTexture, index: 0)
                encoder.setTexture(opacityFieldTexture, index: 1)
                
                let threadGroupSize = MTLSize(width: 8, height: 8, depth: 1)
                let threadGroupCount = MTLSize(
                    width: (target.width + threadGroupSize.width - 1) / threadGroupSize.width,
                    height: (target.height + threadGroupSize.height - 1) / threadGroupSize.height,
                    depth: 1
                )
                
                encoder.dispatchThreadgroups(threadGroupCount, threadsPerThreadgroup: threadGroupSize)
                encoder.endEncoding()
                
                // Second pass: apply high-quality anti-aliasing with blending
                guard let antiAliasEncoder = commandBuffer.makeComputeCommandEncoder() else {
                    throw MetalRendererError.commandBufferCreationFailed
                }
                
                // Create a buffer for the pen color and isEraser flag
                let paramsBufferSize = MemoryLayout<Params>.stride
                let paramsBufferForAntiAlias = device.makeBuffer(length: paramsBufferSize, options: .storageModeShared)
                if let pb = paramsBufferForAntiAlias {
                    let pptr = pb.contents().assumingMemoryBound(to: Params.self)
                    pptr.pointee = params
                }
                
                antiAliasEncoder.setComputePipelineState(antiAliasPipeline)
                antiAliasEncoder.setTexture(distanceFieldTexture, index: 0)
                antiAliasEncoder.setTexture(opacityFieldTexture, index: 1)
                antiAliasEncoder.setTexture(target, index: 2)
                if let pb = paramsBufferForAntiAlias { antiAliasEncoder.setBuffer(pb, offset: 0, index: 0) }
                
                let antiAliasThreadGroupSize = MTLSize(width: 8, height: 8, depth: 1)
                let antiAliasThreadGroupCount = MTLSize(
                    width: (target.width + antiAliasThreadGroupSize.width - 1) / antiAliasThreadGroupSize.width,
                    height: (target.height + antiAliasThreadGroupSize.height - 1) / antiAliasThreadGroupSize.height,
                    depth: 1
                )
                
                antiAliasEncoder.dispatchThreadgroups(antiAliasThreadGroupCount, threadsPerThreadgroup: antiAliasThreadGroupSize)
                antiAliasEncoder.endEncoding()
                
            } else {
                // Fall back to single-pass approach if two-pass isn't available
                guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
                    throw MetalRendererError.commandBufferCreationFailed
                }
                
                encoder.setComputePipelineState(highQualityStampPipeline!)
                if let pb = paramsBuffer { encoder.setBuffer(pb, offset: 0, index: 0) }
                if let sb = stampBuffer { encoder.setBuffer(sb, offset: 0, index: 1) }
                encoder.setTexture(target, index: 0)
                
                let threadGroupSize = MTLSize(width: 8, height: 8, depth: 1)
                let threadGroupCount = MTLSize(
                    width: (target.width + threadGroupSize.width - 1) / threadGroupSize.width,
                    height: (target.height + threadGroupSize.height - 1) / threadGroupSize.height,
                    depth: 1
                )
                
                encoder.dispatchThreadgroups(threadGroupCount, threadsPerThreadgroup: threadGroupSize)
                encoder.endEncoding()
            }
        }
        
        // Copy to staging texture if it exists
        if let staging = self.stagingTexture {
            if let blit = commandBuffer.makeBlitCommandEncoder() {
                let origin = MTLOrigin(x: 0, y: 0, z: 0)
                let size = MTLSize(width: target.width, height: target.height, depth: 1)
                blit.copy(from: target,
                          sourceSlice: 0, sourceLevel: 0,
                          sourceOrigin: origin, sourceSize: size,
                          to: staging,
                          destinationSlice: 0, destinationLevel: 0,
                          destinationOrigin: origin)
                blit.endEncoding()
            }
        }
        
        // --- START TIMER ---
        //        let startTime = DispatchTime.now()
        
        // Commit and wait for completion
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        //        let endTime = DispatchTime.now()
        // --- END TIMER ---
        
        //        let nanoseconds = endTime.uptimeNanoseconds - startTime.uptimeNanoseconds
        //        let timeInterval = Double(nanoseconds) / 1_000_000 // Convert to milliseconds
        
        //        print("GPU Render Time: \(String(format: "%.3f", timeInterval)) ms")
        
        if let err = commandBuffer.error {
            print("renderStampBatchWithBlending: command buffer error: \(err)")
            throw err
        }
    }
    
    internal func dispatchStrokeToGPU(segments: [GPUSplineSegment], color: SIMD4<Float>, isEraser: Bool, isMarker: Bool, width: Int, height: Int) {
        if segments.isEmpty { return }
        
        guard let commandBuffer = commandQueue?.makeCommandBuffer() else { return }
        
        let neededBytes = MemoryLayout<GPUSplineSegment>.stride * segments.count
        if segmentBuffer == nil || segmentBuffer!.length < neededBytes {
            segmentBuffer = device?.makeBuffer(length: neededBytes, options: .storageModeShared)
        }
        if let sb = segmentBuffer {
            let dst = sb.contents().assumingMemoryBound(to: GPUSplineSegment.self)
            dst.assign(from: segments, count: segments.count)
        }
        
        if paramsBuffer == nil {
            paramsBuffer = device?.makeBuffer(length: MemoryLayout<Params>.stride, options: .storageModeShared)
        }
        let params = Params(
            textureWidth: UInt32(width), textureHeight: UInt32(height),
            tileSize: UInt32(tileSize),
            tilesPerRow: (UInt32(width) + UInt32(tileSize) - 1) / UInt32(tileSize),
            stampCount: UInt32(segments.count),
            penColor: color, noiseScale: 0.4,
            isEraser: isEraser, isMarker: isMarker
        )
        if let pb = paramsBuffer {
            let pptr = pb.contents().assumingMemoryBound(to: Params.self)
            pptr.pointee = params
        }
        
        let (tileIndicesData, tileListData) = buildSegmentTileIndices(
            segments: segments,
            textureWidth: width,
            textureHeight: height,
            tileSize: tileSize,
            isMarker: isMarker,
            transform: nil
        )
        
        if tileListData.isEmpty { return }
        
        let indicesBytes = MemoryLayout<TileIndex>.stride * tileIndicesData.count
        let listBytes = MemoryLayout<UInt32>.stride * tileListData.count
        
        if tileIndicesBuffer == nil || tileIndicesBuffer!.length < indicesBytes {
            tileIndicesBuffer = device?.makeBuffer(length: indicesBytes, options: .storageModeShared)
        }
        if tileListBuffer == nil || tileListBuffer!.length < listBytes {
            tileListBuffer = device?.makeBuffer(length: listBytes, options: .storageModeShared)
        }
        
        guard let tib = tileIndicesBuffer, let tlb = tileListBuffer else { return }
        
        memset(tib.contents(), 0, tib.length)
        memset(tlb.contents(), 0, tlb.length)
        memcpy(tib.contents(), tileIndicesData, indicesBytes)
        memcpy(tlb.contents(), tileListData, listBytes)
        
        let hasNoise = segments.contains { $0.noiseSeed != 0 }
        
        if let encoder = commandBuffer.makeComputeCommandEncoder() {
            if hasNoise, let p = self.segmentNoiseCompositePipeline, let noiseTex = self.noiseTexture {
                encoder.setComputePipelineState(p)
                encoder.setTexture(noiseTex, index: 1)
                if let s = self.linearSampler { encoder.setSamplerState(s, index: 0) }
            } else if let p = self.segmentAACompositePipeline {
                encoder.setComputePipelineState(p)
            }
            
            encoder.setBuffer(paramsBuffer, offset: 0, index: 0)
            encoder.setBuffer(segmentBuffer, offset: 0, index: 1)
            encoder.setBuffer(tileIndicesBuffer, offset: 0, index: 2)
            encoder.setBuffer(tileListBuffer, offset: 0, index: 3)
            encoder.setTexture(gpuRenderTarget, index: 0)
            
            let threadGroupSize = MTLSize(width: 8, height: 8, depth: 1)
            let threadGroupCount = MTLSize(
                width: (width + threadGroupSize.width - 1) / threadGroupSize.width,
                height: (height + threadGroupSize.height - 1) / threadGroupSize.height,
                depth: 1
            )
            encoder.dispatchThreadgroups(threadGroupCount, threadsPerThreadgroup: threadGroupSize)
            encoder.endEncoding()
        }
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
    // MARK: - Segment Dispatch
    internal func dispatchPasteToGPU(
        segments: [GPUSplineSegment],
        color: SIMD4<Float>,
        isEraser: Bool,
        isMarker: Bool,
        meta: PasteLayerMeta,
        masks: [PasteMask],
        sourceToDestinationGPU: CGAffineTransform,
        width: Int,
        height: Int,
        target overrideTarget: MTLTexture? = nil   // Task 1: nil → gpuRenderTarget
    ) {
        guard !segments.isEmpty else { return }
        
        // ---- Task 2 fix: one dispatch = one shader. Never let a noise segment
        // drag clean strokes onto the noise kernel (or vice versa).
        let hasNoisy = segments.contains { $0.noiseSeed != 0 }
        let hasClean = segments.contains { $0.noiseSeed == 0 }
        if hasNoisy && hasClean {
            let clean = segments.filter { $0.noiseSeed == 0 }
            let noisy = segments.filter { $0.noiseSeed != 0 }
            
            //            print("PASTE mixed noise batch — splitting: clean=\(clean.count) noisy=\(noisy.count) eraser=\(isEraser)")
            
            dispatchPasteToGPU(segments: clean, color: color, isEraser: isEraser,
                               isMarker: isMarker, meta: meta, masks: masks,
                               sourceToDestinationGPU: sourceToDestinationGPU,
                               width: width, height: height, target: overrideTarget)
            dispatchPasteToGPU(segments: noisy, color: color, isEraser: isEraser,
                               isMarker: isMarker, meta: meta, masks: masks,
                               sourceToDestinationGPU: sourceToDestinationGPU,
                               width: width, height: height, target: overrideTarget)
            return
        }
        
        guard let commandBuffer = commandQueue?.makeCommandBuffer() else { return }
        guard let renderTarget = overrideTarget ?? gpuRenderTarget else { return }
        
        let neededBytes =
        MemoryLayout<GPUSplineSegment>.stride * segments.count
        
        if segmentBuffer == nil ||
            segmentBuffer!.length < neededBytes {
            segmentBuffer = device?.makeBuffer(
                length: neededBytes,
                options: .storageModeShared
            )
        }
        
        guard let sb = segmentBuffer else { return }
        
        let dst =
        sb.contents()
            .assumingMemoryBound(to: GPUSplineSegment.self)
        
        dst.assign(
            from: segments,
            count: segments.count
        )
        
        if paramsBuffer == nil {
            paramsBuffer = device?.makeBuffer(
                length: MemoryLayout<Params>.stride,
                options: .storageModeShared
            )
        }
        
        guard let pb = paramsBuffer else { return }
        
        pb.contents()
            .assumingMemoryBound(to: Params.self)
            .pointee = Params(
                textureWidth: UInt32(width),
                textureHeight: UInt32(height),
                tileSize: UInt32(tileSize),
                tilesPerRow:
                    (UInt32(width) + UInt32(tileSize) - 1)
                / UInt32(tileSize),
                stampCount: UInt32(segments.count),
                penColor: color,
                noiseScale: 0.4,
                isEraser: isEraser,
                isMarker: isMarker
            )
        
        if pasteMetaBuffer == nil ||
            pasteMetaBuffer!.length <
            MemoryLayout<PasteLayerMeta>.stride {
            pasteMetaBuffer = device?.makeBuffer(
                length: MemoryLayout<PasteLayerMeta>.stride,
                options: .storageModeShared
            )
        }
        
        guard let mb = pasteMetaBuffer else { return }
        
        mb.contents()
            .assumingMemoryBound(to: PasteLayerMeta.self)
            .pointee = meta
        
        let (tileIndicesData, tileListData) = buildSegmentTileIndices(
            segments: segments,
            textureWidth: width,
            textureHeight: height,
            tileSize: tileSize,
            isMarker: isMarker,
            transform: sourceToDestinationGPU)
        
        //        if tileListData.isEmpty {
        //            return
        //        }
        if tileListData.isEmpty {
            print("PASTE dropped: empty tile list (segments=\(segments.count), binning=\(sourceToDestinationGPU))")
            return
        }
        
        let indicesBytes =
        MemoryLayout<TileIndex>.stride *
        tileIndicesData.count
        
        let listBytes =
        MemoryLayout<UInt32>.stride *
        tileListData.count
        
        if tileIndicesBuffer == nil ||
            tileIndicesBuffer!.length < indicesBytes {
            tileIndicesBuffer = device?.makeBuffer(
                length: indicesBytes,
                options: .storageModeShared
            )
        }
        
        if tileListBuffer == nil ||
            tileListBuffer!.length < listBytes {
            tileListBuffer = device?.makeBuffer(
                length: listBytes,
                options: .storageModeShared
            )
        }
        
        guard let tib = tileIndicesBuffer, let tlb = tileListBuffer else { return }
        
        // Hardening (same guard the stroke path already has): these buffers are
        // reused across dispatches; a smaller paste after a larger dispatch must
        // not leave stale tileList/tileIndices tails that tiles can read.
        memset(tib.contents(), 0, tib.length)
        memset(tlb.contents(), 0, tlb.length)
        
        // Shared mask buffer, re-uploaded per dispatch. Safe because every
        // dispatch waits until completed before the next one starts.
        let maskBytes = max(1, masks.count) * MemoryLayout<PasteMask>.stride
        if pasteMaskBuffer == nil || pasteMaskBuffer!.length < maskBytes {
            pasteMaskBuffer = device?.makeBuffer(length: maskBytes, options: .storageModeShared)
        }
        if let mb = pasteMaskBuffer, !masks.isEmpty {
            masks.withUnsafeBytes { raw in
                _ = memcpy(mb.contents(), raw.baseAddress, masks.count * MemoryLayout<PasteMask>.stride)
            }
        }
        
        memcpy(
            tib.contents(),
            tileIndicesData,
            indicesBytes
        )
        
        memcpy(
            tlb.contents(),
            tileListData,
            listBytes
        )
        
        let hasNoise = segments.contains { $0.noiseSeed != 0 }   // homogeneous now
        
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        
        if hasNoise, let p = segmentPasteLayerNoiseCompositePipeline,
           let noiseTex = noiseTexture {
            encoder.setComputePipelineState(p)
            encoder.setTexture(noiseTex, index: 1)
            if let sampler = linearSampler { encoder.setSamplerState(sampler, index: 0) }
        } else if let p = segmentPasteLayerAACompositePipeline {
            encoder.setComputePipelineState(p)
        }
        
        encoder.setBuffer(paramsBuffer, offset: 0, index: 0)
        encoder.setBuffer(segmentBuffer, offset: 0, index: 1)
        encoder.setBuffer(tileIndicesBuffer, offset: 0, index: 2)
        encoder.setBuffer(tileListBuffer, offset: 0, index: 3)
        encoder.setBuffer(pasteMetaBuffer, offset: 0, index: 4)
        encoder.setBuffer(pasteMaskBuffer, offset: 0, index: 5)
        encoder.setTexture(renderTarget, index: 0)
        
        let tg = MTLSize(width: 8, height: 8, depth: 1)
        
        let groups = MTLSize(
            width: (width + 7) / 8,
            height: (height + 7) / 8,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(
            groups,
            threadsPerThreadgroup: tg
        )
        
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
    
    internal func dispatchCutToGPU(
        meta: CutMeta,
        width: Int,
        height: Int
    ) {
        guard let commandBuffer =
                commandQueue?.makeCommandBuffer() else {
            return
        }
        
        if cutMetaBuffer == nil ||
            cutMetaBuffer!.length <
            MemoryLayout<CutMeta>.stride {
            cutMetaBuffer = device?.makeBuffer(
                length: MemoryLayout<CutMeta>.stride,
                options: .storageModeShared
            )
        }
        
        guard let buffer = cutMetaBuffer else {
            return
        }
        
        buffer.contents()
            .assumingMemoryBound(to: CutMeta.self)
            .pointee = meta
        
        guard let encoder =
                commandBuffer.makeComputeCommandEncoder(),
              let pipeline = segmentCutCompositePipeline else {
            return
        }
        
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(buffer, offset: 0, index: 0)
        encoder.setTexture(gpuRenderTarget, index: 0)
        
        let tg = MTLSize(width: 8, height: 8, depth: 1)
        
        encoder.dispatchThreadgroups(
            MTLSize(
                width: (width + 7) / 8,
                height: (height + 7) / 8,
                depth: 1
            ),
            threadsPerThreadgroup: tg
        )
        
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
    
    // MARK: - Spatial Indexing
    /// Build tile-based spatial index for stamps
    private func buildTileIndices(stamps: [Stamp], textureWidth: Int, textureHeight: Int, tileSize: Int) -> (tileIndicesData: [TileIndex], tileListData: [UInt32]) {
        let tilesX = (textureWidth + tileSize - 1) / tileSize
        let tilesY = (textureHeight + tileSize - 1) / tileSize
        let totalTiles = tilesX * tilesY
        
        // Track counts per tile
        var tileCounts = [Int](repeating: 0, count: totalTiles)
        
        // Pre-calculate bounding boxes to avoid repeating math in both passes
        struct StampBB {
            let index: UInt32
            let minTileX, maxTileX, minTileY, maxTileY: Int
        }
        
        var activeStamps = [StampBB]()
        activeStamps.reserveCapacity(stamps.count)
        
        // --- PASS 1: Count overlaps ---
        for (i, s) in stamps.enumerated() {
            let r = s.radius
            let minX = Int(floor(s.center.x - r))
            let maxX = Int(ceil(s.center.x + r))
            let minY = Int(floor(s.center.y - r))
            let maxY = Int(ceil(s.center.y + r))
            
            if maxX < 0 || minX >= textureWidth || maxY < 0 || minY >= textureHeight { continue }
            
            let startTileX = max(0, minX) / tileSize
            let endTileX = min(textureWidth - 1, maxX) / tileSize
            let startTileY = max(0, minY) / tileSize
            let endTileY = min(textureHeight - 1, maxY) / tileSize
            
            activeStamps.append(StampBB(index: UInt32(i), minTileX: startTileX, maxTileX: endTileX, minTileY: startTileY, maxTileY: endTileY))
            
            for ty in startTileY...endTileY {
                let rowOffset = ty * tilesX
                for tx in startTileX...endTileX {
                    tileCounts[rowOffset + tx] += 1
                }
            }
        }
        
        // --- COMPUTE OFFSETS ---
        // Calculate total size and allocation offsets for a single flat array
        var tileOffsets = [Int](repeating: 0, count: totalTiles)
        var totalElements = 0
        for i in 0..<totalTiles {
            tileOffsets[i] = totalElements
            totalElements += tileCounts[i]
        }
        
        // Allocate the single flat array for all buckets
        var flatTileList = [UInt32](repeating: 0, count: totalElements)
        
        // Working offsets array because we will increment it as we populate
        var currentOffsets = tileOffsets
        
        // --- PASS 2: Populate flat array ---
        for bb in activeStamps {
            for ty in bb.minTileY...bb.maxTileY {
                let rowOffset = ty * tilesX
                for tx in bb.minTileX...bb.maxTileX {
                    let tileIdx = rowOffset + tx
                    let targetOffset = currentOffsets[tileIdx]
                    flatTileList[targetOffset] = bb.index
                    currentOffsets[tileIdx] += 1
                }
            }
        }
        
        // --- GENERATE OUTPUT ---
        var tileIndicesData = [TileIndex]()
        tileIndicesData.reserveCapacity(totalTiles)
        
        for i in 0..<totalTiles {
            tileIndicesData.append(TileIndex(start: UInt32(tileOffsets[i]), count: UInt32(tileCounts[i])))
        }
        
        return (tileIndicesData, flatTileList)
    }
    
    func buildSegmentTileIndices(
        segments: [GPUSplineSegment],
        textureWidth: Int,
        textureHeight: Int,
        tileSize: Int,
        isMarker: Bool = false,
        transform: CGAffineTransform? = nil
    ) -> ([TileIndex], [UInt32]) {
        let tilesPerRow = (textureWidth + tileSize - 1) / tileSize
        let tilesPerCol = (textureHeight + tileSize - 1) / tileSize
        let numTiles = tilesPerRow * tilesPerCol
        let fTexW = Float(textureWidth)
        let fTexH = Float(textureHeight)
        let invTileSize = 1.0 / Float(tileSize)
        let paddingScale: Float = isMarker ? (1.0 + 2.0 * sqrt(2.0)) : 1.4
        let t = transform ?? .identity
        let hasTransform = transform != nil
        
        // Per-segment tile ranges, computed once (bbox + transform application
        // shared by both passes).
        struct TileRange { var minTX: Int32; var maxTX: Int32; var minTY: Int32; var maxTY: Int32 }
        var ranges = [TileRange](repeating: TileRange(minTX: 1, maxTX: 0, minTY: 0, maxTY: 0),
                                 count: segments.count)
        
        segments.withUnsafeBufferPointer { segs in
            ranges.withUnsafeMutableBufferPointer { rp in
                for i in segs.indices {
                    let seg = segs[i]
                    let padding = (max(seg.radius0, seg.radius1) * paddingScale) + 1.0
                    
                    var minX = min(seg.p1.x, seg.p2.x) - padding
                    var maxX = max(seg.p1.x, seg.p2.x) + padding
                    var minY = min(seg.p1.y, seg.p2.y) - padding
                    var maxY = max(seg.p1.y, seg.p2.y) + padding
                    
                    if hasTransform {
                        let c1 = CGPoint(x: CGFloat(minX), y: CGFloat(minY)).applying(t)
                        let c2 = CGPoint(x: CGFloat(maxX), y: CGFloat(minY)).applying(t)
                        let c3 = CGPoint(x: CGFloat(minX), y: CGFloat(maxY)).applying(t)
                        let c4 = CGPoint(x: CGFloat(maxX), y: CGFloat(maxY)).applying(t)
                        minX = Float(min(c1.x, c2.x, c3.x, c4.x))
                        maxX = Float(max(c1.x, c2.x, c3.x, c4.x))
                        minY = Float(min(c1.y, c2.y, c3.y, c4.y))
                        maxY = Float(max(c1.y, c2.y, c3.y, c4.y))
                    }
                    
                    if maxX < 0.0 || minX > fTexW || maxY < 0.0 || minY > fTexH { continue }
                    
                    let minTileX = max(0, Int(minX * invTileSize))
                    let maxTileX = min(tilesPerRow - 1, Int(maxX * invTileSize))
                    let minTileY = max(0, Int(minY * invTileSize))
                    let maxTileY = min(tilesPerCol - 1, Int(maxY * invTileSize))
                    guard minTileX <= maxTileX && minTileY <= maxTileY else { continue }
                    rp[i] = TileRange(minTX: Int32(minTileX), maxTX: Int32(maxTileX),
                                      minTY: Int32(minTileY), maxTY: Int32(maxTileY))
                }
            }
        }
        
        var tileIndices = [TileIndex](repeating: TileIndex(start: 0, count: 0), count: numTiles)
        
        // --- PASS 1: count overlaps per tile (into .count) ---
        tileIndices.withUnsafeMutableBufferPointer { tp in
            ranges.withUnsafeBufferPointer { rp in
                for r in rp {
                    if r.minTX > r.maxTX { continue }
                    var rowBase = Int(r.minTY) * tilesPerRow + Int(r.minTX)
                    for _ in r.minTY...r.maxTY {
                        var idx = rowBase
                        for _ in r.minTX...r.maxTX {
                            tp[idx].count += 1
                            idx += 1
                        }
                        rowBase += tilesPerRow
                    }
                }
            }
        }
        
        // --- PREFIX SUM (into .start; .count keeps the per-tile count) ---
        var currentStart: UInt32 = 0
        for i in 0..<numTiles {
            tileIndices[i].start = currentStart
            currentStart += tileIndices[i].count
        }
        
        // --- PASS 2: populate; write heads start at each tile's .start ---
        var tileList = [UInt32](repeating: 0, count: Int(currentStart))
        var writeHeads = tileIndices.map { $0.start }
        
        tileList.withUnsafeMutableBufferPointer { lp in
            writeHeads.withUnsafeMutableBufferPointer { wp in
                ranges.withUnsafeBufferPointer { rp in
                    for (i, r) in rp.enumerated() {
                        if r.minTX > r.maxTX { continue }
                        let segIdx = UInt32(i)
                        var rowBase = Int(r.minTY) * tilesPerRow + Int(r.minTX)
                        for _ in r.minTY...r.maxTY {
                            var idx = rowBase
                            for _ in r.minTX...r.maxTX {
                                let pos = wp[idx]
                                lp[Int(pos)] = segIdx
                                wp[idx] = pos + 1
                                idx += 1
                            }
                            rowBase += tilesPerRow
                        }
                    }
                }
            }
        }
        
        return (tileIndices, tileList)
    }
}
#endif
