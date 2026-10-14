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
import Foundation
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
    var tileW: Float, tileH: Float          // paper tile size in *document* units
    var canvasW: Float, canvasH: Float
    // canvas pixels -> document units, so the paper is pinned to the document
    var m00: Float, m01: Float, m02: Float
    var m10: Float, m11: Float, m12: Float
}

// Must match `LiveStrokeParams` in segmentKernels.metal byte for byte. Scalars only: an
// SIMD4 penColor would land at a different offset than the shader's equivalent (see the
// note above LivePresentUniforms). `flags`: bit0 = isEraser, bit1 = isMarker.
struct LiveStrokeParams {
    var tileOriginX: UInt32
    var tileOriginY: UInt32
    var boxTilesPerRow: UInt32
    var tileSize: UInt32
    var textureWidth: UInt32
    var textureHeight: UInt32
    var stampCount: UInt32
    var penColorR: Float
    var penColorG: Float
    var penColorB: Float
    var penColorA: Float
    var noiseScale: Float
    var flags: UInt32
}

// Must match `PerTileParams` in segmentKernels.metal byte for byte (scalars only).
struct PerTileParams {
    var tileOriginX: UInt32
    var tileOriginY: UInt32
    var boxTilesPerRow: UInt32
    var tileSize: UInt32
}

// Must match `LiveBinTransformParams` in segmentKernels.metal field for field, in order.
// All 4-byte scalars: 4 uint + 10 float = stride 56 on both sides.
struct LiveBinTransformParams {
    var segCount: UInt32
    var tilesPerRow: UInt32
    var tilesPerCol: UInt32
    var tileSize: UInt32
    var texW: Float
    var texH: Float
    var invTile: Float
    var radiusFactor: Float
    var camA: Float
    var camB: Float
    var camC: Float
    var camD: Float
    var camTX: Float
    var camTY: Float
}

// Must match `LiveBinBoxParams` in segmentKernels.metal field for field, in order.
// uint + 4×int + uint = stride 24 on both sides.
struct LiveBinBoxParams {
    var segCount: UInt32
    var boxMinX: Int32
    var boxMinY: Int32
    var boxW: Int32
    var boxH: Int32
    var tilesPerRow: UInt32
}

// One layer's worth of per-tile data, as byte-slices into the single upload buffer.
private struct PerTilePlan {
    var empty = true
    var segOffset = 0, segCount = 0
    var strokeOfSegOffset = 0, strokeOfSegCount = 0
    var tileStartCountOffset = 0, tileBoxCount = 0
    var tileListOffset = 0, tileListCount = 0
    var strokeColorOffset = 0, strokeCount = 0
    var strokeFlagsOffset = 0
    var minTileX = 0, minTileY = 0, boxWidth = 0, boxHeight = 0
    // True when any stroke in the layer needs the noise composite. Selects the
    // noise-capable per-tile kernel; clean layers keep the AA kernel untouched.
    var containsNoise = false
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

        // Live-only segment kernels: a byte-for-byte copy of segment{AA,Noise}CompositeKernel
        // that dispatches each stroke over its own tile box (see encode(stroke:)). Built
        // here so a pre-existing metallib without them disables the live view cleanly
        // instead of mis-rendering.
        if let fn = library.makeFunction(name: "liveSegmentAACompositeKernel") {
            do {
                liveSegmentAACompositePipeline = try device.makeComputePipelineState(function: fn)
            } catch {
                failures.append("liveSegmentAACompositeKernel: \(error)")
                liveSegmentAACompositePipeline = nil
            }
        } else {
            failures.append("liveSegmentAACompositeKernel: not found in the metallib")
        }
        if let fn = library.makeFunction(name: "liveSegmentNoiseCompositeKernel") {
            do {
                liveSegmentNoiseCompositePipeline = try device.makeComputePipelineState(function: fn)
            } catch {
                failures.append("liveSegmentNoiseCompositeKernel: \(error)")
                liveSegmentNoiseCompositePipeline = nil
            }
        } else {
            failures.append("liveSegmentNoiseCompositeKernel: not found in the metallib")
        }

        // Per-tile live composite (AA fast path). Optional on purpose: if it's missing
        // the live view silently uses the per-stroke path instead.
        if let fn = library.makeFunction(name: "livePerTileAACompositeKernel") {
            do {
                livePerTileAACompositePipeline = try device.makeComputePipelineState(function: fn)
            } catch {
                failures.append("livePerTileAACompositeKernel: \(error)")
                livePerTileAACompositePipeline = nil
            }
        }
        // Per-tile noise-capable composite (AA + noise per stroke group). Optional like
        // the AA one: noisy layers fall back to per-stroke when the metallib predates it.
        if let fn = library.makeFunction(name: "livePerTileNoiseCompositeKernel") {
            do {
                livePerTileNoiseCompositePipeline = try device.makeComputePipelineState(function: fn)
            } catch {
                failures.append("livePerTileNoiseCompositeKernel: \(error)")
                livePerTileNoiseCompositePipeline = nil
            }
        } else {
            // Not fatal: per-stroke stays exact for noisy layers.
            print("Live view: livePerTileNoiseCompositeKernel not in metallib — noisy layers use per-stroke")
        }
        // GPU tile-binning kernels (live view `bin` stage). All optional on purpose: a
        // metallib without them (or ART_LIVE_GPUBIN=0) silently uses the CPU binning.
        // Missing ones are NOT in `failures` — they must never fail the whole live view.
        let binKernels: [(String, (MTLComputePipelineState?) -> Void)] = [
            ("liveBinTransformCountKernel", { self.liveBinTransformCountPipeline = $0 }),
            ("liveBinScatterKernel", { self.liveBinScatterPipeline = $0 }),
            ("liveBinSortTilesKernel", { self.liveBinSortTilesPipeline = $0 }),
        ]
        for (name, assign) in binKernels {
            if let fn = library.makeFunction(name: name) {
                do {
                    assign(try device.makeComputePipelineState(function: fn))
                } catch {
                    print("Live view: \(name) pipeline failed (\(error)) — CPU binning for now")
                    assign(nil)
                }
            } else {
                print("Live view: \(name) not in metallib — CPU binning for now")
                assign(nil)
            }
        }
        if liveBinTransformCountPipeline != nil {
            print("Live view: GPU tile binning ready")
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
              liveSegmentAACompositePipeline != nil,
              liveSegmentNoiseCompositePipeline != nil,
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
    
    /// Canvas/background pair `index` (0 or 1).
    func canvas(at index: Int) -> MTLTexture? {
        liveCanvasTextures.indices.contains(index) ? liveCanvasTextures[index] : nil
    }

    func background(at index: Int) -> MTLTexture? {
        liveBackgroundTextures.indices.contains(index) ? liveBackgroundTextures[index] : nil
    }

    /// Starts a frame: picks the pair to render into — the one the UI is *not* showing.
    func beginLiveFrame() {
        let next = liveCanvasIndex
        // The installed canvas points at `liveCanvasIndex`; flip so the next frame writes
        // into the other pair. Two buffers are enough because a present pass is a single
        // draw and has long retired by the time the frame after next starts.
        liveCanvasIndex = liveCanvasTextures.isEmpty ? 0 : (next + 1) % liveCanvasTextures.count
    }

    /// (Re)creates the canvas + background textures for a `width` × `height` canvas.
    ///
    /// - Parameters:
    ///   - mipmapped: true for the single-raster mode (the canvas is then minified and
    ///     wants mips); false for the interactive mode, where the canvas matches the
    ///     viewport 1:1 and mips would cost a blit for nothing.
    ///   - resetPaper: drop the decoded paper texture (new document). A per-frame resize
    ///     must not force a re-decode.
    func makeLiveCanvasTextures(width: Int, height: Int,
                                mipmapped: Bool = true,
                                resetPaper: Bool = true) throws {
        guard let device = self.device else { throw MetalRendererError.deviceNotAvailable }
        guard width > 0, height > 0 else { throw MetalRendererError.textureCreationFailed }
        
        if resetPaper { livePaperTexture = nil }
        
        if let canvas = liveCanvasTexture,
           canvas.width == width, canvas.height == height,
           (canvas.mipmapLevelCount > 1) == mipmapped {
            return                                  // already the right size
        }
        
        let mipCount = mipmapped ? Self.mipLevelCount(width: width, height: height) : 1
        
        func makeTexture() -> MTLTexture? {
            let desc = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: mipCount > 1)
            desc.usage = [.shaderRead, .shaderWrite, .renderTarget]
            desc.storageMode = .private
            return device.makeTexture(descriptor: desc)
        }
        
        // Two pairs, so a frame can be rendered while the previous one is on screen.
        var canvases: [MTLTexture] = []
        var backgrounds: [MTLTexture] = []
        for _ in 0..<2 {
            guard let canvas = makeTexture(), let background = makeTexture() else {
                throw MetalRendererError.textureCreationFailed
            }
            canvases.append(canvas)
            backgrounds.append(background)
        }
        
        liveCanvasTextures = canvases
        liveBackgroundTextures = backgrounds
        liveCanvasIndex = 0
        print("Live view: canvas textures \(width)x\(height) x\(canvases.count)"
              + " (\(mipCount) mip level(s))")
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
    // MARK: - Interactive (cached) layer compositing
    
    // Scratch space for one interactive frame's geometry: a CPU staging buffer (reused
    // across frames) plus the Metal buffer it is copied into.
    //
    // Why an arena instead of the shared `segmentBuffer`/`tileIndicesBuffer` that the
    // static path reuses per stroke: that is safe there only because every stroke gets
    // its *own* command buffer followed by `waitUntilCompleted()`. Encoding a whole
    // layer into one command buffer means the CPU has finished writing every dispatch
    // before the GPU starts the first, so a shared buffer would be overwritten under the
    // GPU's feet. Here each dispatch binds its own `offset:` into one buffer instead.
    //
    // Reusing the arena across frames is safe because only one render is ever in flight
    // (the present pass commits without waiting, but it shares a single MTLCommandQueue
    // with the render, and Metal executes command buffers in commit order).
    private static let liveArenaAlignment = 256
    
    private static func alignUp(_ value: Int, _ alignment: Int) -> Int {
        (value + alignment - 1) / alignment * alignment
    }
    
    /// One stroke's slice of the arena.
    private struct LiveStrokeBin {
        var segmentOffset = 0, segmentCount = 0
        var tileIndexOffset = 0
        var tileListOffset = 0
        var color = SIMD4<Float>(0, 0, 0, 1)
        var isEraser = false
        var isMarker = false
        var hasNoise = false
        // Inclusive tile box this stroke covers (union of its per-segment ranges). The
        // live dispatch covers exactly this box instead of the whole canvas.
        var minTileX = 0, minTileY = 0, maxTileX = 0, maxTileY = 0
        // Tiles per row *inside* the box — the kernel's stride for box-local tile indexing.
        // Differs from the canvas tilesPerRow because the box spans only minTile…maxTile.
        var boxTilesPerRow = 0
    }
    
    /// The layer's ops in their original order — a `cut` erases what was drawn *below*
    /// it, so strokes and cuts must not be reordered.
    private enum LiveLayerStep {
        case stroke(Int)          // index into the bins array
        case cut(CutMeta)
    }
    
    /// Rasterises a **cached** layer for the current camera and stacks it onto the
    /// canvas.
    ///
    /// The whole layer is encoded into a *single* command buffer, so a frame costs one GPU
    /// round trip instead of one per stroke. Dispatches are still one per stroke, so
    /// overlapping strokes composite exactly like the static path (the kernel does not get
    /// to merge coverage across strokes).
    ///
    /// - Note: `layerOps` are `LiveDeviceOp`s (cache + camera already applied), in
    ///   document order.
    func renderCachedLayerIntoLiveCanvas(layerOps: [LiveDeviceOp],
                                         width: Int, height: Int,
                                         opacity: Float) throws {
        guard let compositePipeline = liveCompositeLayerPipeline else {
            throw MetalRendererError.pipelineMissing("liveCompositeLayerKernel")
        }
        guard !layerOps.isEmpty else { return }
        
        try ensureRenderTargets(width: width, height: height)
        try clearTexture(gpuRenderTarget!)
        
        guard let queue = commandQueue,
              let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalRendererError.textureCreationFailed
        }
        
        // ── 1+2. Tile-bin the layer into the staging arena, then encode it.
        //
        // The *per-tile* path composites the whole layer in ONE dispatch (one canvas write
        // per pixel + high occupancy — the memory fix) for layers without cuts/markers
        // (noise included via the noise-capable kernel). Anything else uses the proven
        // *per-stroke* path (one dispatch per stroke) — the only way cut/marker stay exact.
        var clock = DispatchTime.now().uptimeNanoseconds
        var perTilePlan: PerTilePlan?
        if Self.perTileEnabled, isPerTileEligible(layerOps) {
            let needsNoise = layerOps.contains {
                if case .stroke(let segs, _, _, _) = $0 { return segs.contains { $0.noiseSeed != 0 } }
                return false
            }
            let pipelineAvailable = needsNoise
                ? livePerTileNoiseCompositePipeline != nil
                : livePerTileAACompositePipeline != nil
            // A noisy layer without a decoded noise texture cannot use the per-tile noise
            // kernel (nothing to sample); per-stroke handles that case already.
            if pipelineAvailable, !(needsNoise && noiseTexture == nil) {
                perTilePlan = try buildPerTilePlan(layerOps: layerOps, width: width, height: height)
            }
        }
        if let plan = perTilePlan, plan.empty {
            perTilePlan = nil                  // nothing on-canvas → fall back to per-stroke
        }
        var steps: [LiveLayerStep] = []
        var bins: [LiveStrokeBin] = []
        if perTilePlan == nil {
            let (s, b) = try bin(layerOps: layerOps, width: width, height: height)
            steps = s
            bins = b
        }
        liveTiming.binMilliseconds += Self.milliseconds(since: clock)

        // One upload, then encode whichever plan we built.
        try uploadArena(byteCount: liveStagingUsed)
        clock = DispatchTime.now().uptimeNanoseconds
        if let plan = perTilePlan {
            try encodePerTile(plan: plan, encoder: encoder)
        } else {
            for step in steps {
                switch step {
                    case .stroke(let index):
                        try encode(stroke: bins[index], width: width, height: height, encoder: encoder)
                    case .cut(let meta):
                        try dispatchLiveCut(meta: meta, width: width, height: height, encoder: encoder)
                }
            }
        }
        liveTiming.encodeMilliseconds += Self.milliseconds(since: clock)
        
        // Stack the finished layer onto the canvas in the same command buffer.
        guard let canvas = liveCanvasTexture, let layer = gpuRenderTarget else {
            throw MetalRendererError.textureCreationFailed
        }
        var layerOpacity = opacity
        encoder.setComputePipelineState(compositePipeline)
        encoder.setTexture(layer, index: 0)
        encoder.setTexture(canvas, index: 1)
        encoder.setBytes(&layerOpacity, length: MemoryLayout<Float>.stride, index: 0)
        encoder.dispatchThreadgroups(Self.liveGroups(width: width, height: height),
                                     threadsPerThreadgroup: Self.liveThreads)
        encoder.endEncoding()
        
        clock = DispatchTime.now().uptimeNanoseconds
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        liveTiming.gpuMilliseconds += Self.milliseconds(since: clock)
        if let err = commandBuffer.error { throw err }
    }
    
    /// A layer is per-tile-able only if it has no cut ops and no marker strokes. Noise is
    /// allowed: layers containing noise use the noise-capable per-tile kernel, clean
    /// layers the AA one. Pure logic lives in `LivePerTileEligibility` (Linux-tested).
    private func isPerTileEligible(_ ops: [LiveDeviceOp]) -> Bool {
        LivePerTileEligibility.isEligible(ops)
    }

    /// Builds the whole layer's per-tile structure into `liveStaging`: one flat, document-
    /// (stroke-)ordered segment array, a per-segment stroke index, per-stroke colour + flags,
    /// and a box-local tile → segment list (built by the shared `SegmentBinner`, so each
    /// tile's list is already ascending = document order — which is what makes per-stroke
    /// grouping correct). Sets `liveStagingUsed` and the debug counters; the returned plan's
    /// offsets are what `encodePerTile` binds.
    private func buildPerTilePlan(layerOps: [LiveDeviceOp],
                                  width: Int, height: Int) throws -> PerTilePlan {
        var segments: [GPUSplineSegment] = []
        var strokeOfSegment: [UInt32] = []
        var strokeColors: [SIMD4<Float>] = []
        var strokeFlags: [UInt32] = []
        let liveTile = liveTileSize
        for op in layerOps {
            if case .stroke(let segs, let color, let isEraser, _) = op {
                let strokeIndex = UInt32(strokeColors.count)
                strokeColors.append(color)
                let hasNoise = segs.contains { $0.noiseSeed != 0 }
                strokeFlags.append(LivePerTileEligibility.strokeFlags(isEraser: isEraser,
                                                                      hasNoise: hasNoise))
                segments.append(contentsOf: segs)
                strokeOfSegment.append(contentsOf: Array(repeating: strokeIndex, count: segs.count))
            }
        }

        var plan = PerTilePlan()
        plan.strokeCount = strokeColors.count
        plan.segCount = segments.count
        plan.strokeOfSegCount = strokeOfSegment.count
        plan.containsNoise = strokeFlags.contains { ($0 & 0x2) != 0 }

        let boxed = buildSegmentTileIndicesBoxed(segments: segments,
                                                 textureWidth: width, textureHeight: height,
                                                 tileSize: liveTile, isMarker: false, transform: nil)
        plan.tileListCount = boxed.tileList.count
        plan.tileBoxCount = boxed.tileIndices.count
        plan.minTileX = boxed.minTileX
        plan.minTileY = boxed.minTileY
        plan.boxWidth = boxed.boxWidth
        plan.boxHeight = boxed.boxHeight

        if boxed.tileList.isEmpty {
            plan.empty = true
            liveStagingUsed = 0
            return plan
        }
        plan.empty = false

        if liveStagingUsed > 0, staging(needed: liveStagingUsed) == nil {
            throw MetalRendererError.bufferCreationFailed
        }
        var cursor = 0
        func place(_ byteCount: Int) -> Int {
            cursor = Self.alignUp(cursor, Self.liveArenaAlignment)
            let offset = cursor
            cursor += byteCount
            return offset
        }
        plan.segOffset = place(MemoryLayout<GPUSplineSegment>.stride * segments.count)
        plan.strokeOfSegOffset = place(MemoryLayout<UInt32>.stride * strokeOfSegment.count)
        plan.tileStartCountOffset = place(MemoryLayout<TileIndex>.stride * boxed.tileIndices.count)
        plan.tileListOffset = place(MemoryLayout<UInt32>.stride * boxed.tileList.count)
        plan.strokeColorOffset = place(MemoryLayout<SIMD4<Float>>.stride * strokeColors.count)
        plan.strokeFlagsOffset = place(MemoryLayout<UInt32>.stride * strokeFlags.count)

        guard let base = staging(needed: cursor) else { throw MetalRendererError.bufferCreationFailed }
        func write<T>(_ array: [T], at offset: Int) {
            array.withUnsafeBytes { raw in
                if let src = raw.baseAddress {
                    (base + offset).copyMemory(from: src, byteCount: raw.count)
                }
            }
        }
        write(segments, at: plan.segOffset)
        write(strokeOfSegment, at: plan.strokeOfSegOffset)
        write(boxed.tileIndices, at: plan.tileStartCountOffset)
        write(boxed.tileList, at: plan.tileListOffset)
        write(strokeColors, at: plan.strokeColorOffset)
        write(strokeFlags, at: plan.strokeFlagsOffset)
        liveStagingUsed = Self.alignUp(cursor, Self.liveArenaAlignment)

        // Debug counters.
        liveTiming.dispatchedTiles += boxed.boxWidth * boxed.boxHeight
        liveTiming.inkedTiles += boxed.tileIndices.reduce(0) { $0 + ($1.count > 0 ? 1 : 0) }
        liveTiming.sdfEvaluations += boxed.tileList.count * (liveTile * liveTile)
        liveTiming.strokes += strokeColors.count
        liveTiming.segments += segments.count
        return plan
    }

    /// Binds the per-tile plan and dispatches ONE compute over the layer's tile box.
    private func encodePerTile(plan: PerTilePlan, encoder: MTLComputeCommandEncoder) throws {
        guard let arena = liveArena else { throw MetalRendererError.bufferCreationFailed }
        try encodePerTileBuffers(segBuffer: arena, segOffset: plan.segOffset,
                                 strokeOfSegBuffer: arena, strokeOfSegOffset: plan.strokeOfSegOffset,
                                 tileStartCountBuffer: arena, tileStartCountOffset: plan.tileStartCountOffset,
                                 tileListBuffer: arena, tileListOffset: plan.tileListOffset,
                                 strokeColorBuffer: arena, strokeColorOffset: plan.strokeColorOffset,
                                 strokeFlagsBuffer: arena, strokeFlagsOffset: plan.strokeFlagsOffset,
                                 boxMinX: plan.minTileX, boxMinY: plan.minTileY,
                                 boxWidth: plan.boxWidth, boxHeight: plan.boxHeight,
                                 containsNoise: plan.containsNoise,
                                 encoder: encoder)
    }

    /// Per-tile render shared by the CPU plan (arena slices) and the GPU binning path
    /// (dedicated buffers at offset 0). Buffer contents and box semantics are identical —
    /// only the backing store differs.
    private func encodePerTileBuffers(segBuffer: MTLBuffer, segOffset: Int,
                                      strokeOfSegBuffer: MTLBuffer, strokeOfSegOffset: Int,
                                      tileStartCountBuffer: MTLBuffer, tileStartCountOffset: Int,
                                      tileListBuffer: MTLBuffer, tileListOffset: Int,
                                      strokeColorBuffer: MTLBuffer, strokeColorOffset: Int,
                                      strokeFlagsBuffer: MTLBuffer, strokeFlagsOffset: Int,
                                      boxMinX: Int, boxMinY: Int,
                                      boxWidth: Int, boxHeight: Int,
                                      containsNoise: Bool,
                                      encoder: MTLComputeCommandEncoder) throws {
        let liveTile = liveTileSize
        guard liveTile > 0, boxWidth > 0, boxHeight > 0 else {
            throw MetalRendererError.invalidTileData
        }
        var params = PerTileParams(tileOriginX: UInt32(boxMinX),
                                   tileOriginY: UInt32(boxMinY),
                                   boxTilesPerRow: UInt32(boxWidth),
                                   tileSize: UInt32(liveTile))
        if containsNoise {
            guard let pipeline = livePerTileNoiseCompositePipeline else {
                throw MetalRendererError.pipelineMissing("livePerTileNoiseCompositeKernel")
            }
            guard let noise = noiseTexture else {
                throw MetalRendererError.pipelineMissing("livePerTileNoiseCompositeKernel(noiseTexture)")
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setBytes(&params, length: MemoryLayout<PerTileParams>.stride, index: 0)
            encoder.setBuffer(segBuffer, offset: segOffset, index: 1)
            encoder.setBuffer(strokeOfSegBuffer, offset: strokeOfSegOffset, index: 2)
            encoder.setBuffer(tileStartCountBuffer, offset: tileStartCountOffset, index: 3)
            encoder.setBuffer(tileListBuffer, offset: tileListOffset, index: 4)
            encoder.setBuffer(strokeColorBuffer, offset: strokeColorOffset, index: 5)
            encoder.setBuffer(strokeFlagsBuffer, offset: strokeFlagsOffset, index: 6)
            encoder.setTexture(gpuRenderTarget, index: 0)
            encoder.setTexture(noise, index: 1)
            if let sampler = linearSampler { encoder.setSamplerState(sampler, index: 0) }
        } else {
            guard let pipeline = livePerTileAACompositePipeline else {
                throw MetalRendererError.pipelineMissing("livePerTileAACompositeKernel")
            }
            encoder.setComputePipelineState(pipeline)
            encoder.setBytes(&params, length: MemoryLayout<PerTileParams>.stride, index: 0)
            encoder.setBuffer(segBuffer, offset: segOffset, index: 1)
            encoder.setBuffer(strokeOfSegBuffer, offset: strokeOfSegOffset, index: 2)
            encoder.setBuffer(tileStartCountBuffer, offset: tileStartCountOffset, index: 3)
            encoder.setBuffer(tileListBuffer, offset: tileListOffset, index: 4)
            encoder.setBuffer(strokeColorBuffer, offset: strokeColorOffset, index: 5)
            encoder.setBuffer(strokeFlagsBuffer, offset: strokeFlagsOffset, index: 6)
            encoder.setTexture(gpuRenderTarget, index: 0)
        }
        let groupsPerTileX = (liveTile + Int(Self.liveThreads.width) - 1) / Int(Self.liveThreads.width)
        let groupsPerTileY = (liveTile + Int(Self.liveThreads.height) - 1) / Int(Self.liveThreads.height)
        let groups = MTLSize(width: boxWidth * groupsPerTileX,
                             height: boxHeight * groupsPerTileY,
                             depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: Self.liveThreads)
    }

    static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
    }

    // MARK: - GPU tile binning

    /// Renders a cached layer through the GPU-binned per-tile path: reference segments are
    /// transformed + binned on the GPU, so the per-frame CPU work is culling, a tile-count
    /// prefix sum, and a few KB of uploads instead of ~20 MB of geometry + binning loops.
    ///
    /// - Returns: true when the layer was handled (rendered, or fully culled and counted).
    ///   false means "run the CPU path instead" — ineligible content, flag off, stale
    ///   metallib, or any allocation/encoding failure. Never throws outward, so a fallback
    ///   always exists and wrong pixels are impossible by construction (only exactness
    ///   bugs could slip through, which is what the pixel-identity gate is for).
    func renderCachedLayerGPU(cache: LiveRenderCache, position: Int,
                              camera: CGAffineTransform, viewport: CGRect,
                              width: Int, height: Int, opacity: Float) -> Bool {
        do {
            return try renderCachedLayerGPUThrowing(cache: cache, position: position,
                                                    camera: camera, viewport: viewport,
                                                    width: width, height: height, opacity: opacity)
        } catch {
            return false
        }
    }

    private func renderCachedLayerGPUThrowing(cache: LiveRenderCache, position: Int,
                                              camera: CGAffineTransform, viewport: CGRect,
                                              width: Int, height: Int,
                                              opacity: Float) throws -> Bool {
        guard LiveConfig.gpuBinEnabled() else { return false }
        guard let transformPipe = liveBinTransformCountPipeline,
              let scatterPipe = liveBinScatterPipeline,
              let sortPipe = liveBinSortTilesPipeline,
              let compositePipeline = liveCompositeLayerPipeline else { return false }
        guard position < cache.layers.count, let device = device, let queue = commandQueue else {
            return false
        }
        let layer = cache.layers[position]
        guard !layer.needsRebuild else { return false }
        // Any cut op forces the CPU path: cut metas are remapped per frame on the CPU and
        // must interleave with strokes in document order.
        for op in layer.ops {
            if case .cut = op { return false }
        }

        let liveTile = liveTileSize
        guard liveTile >= 8, width > 0, height > 0 else { return false }
        let (tilesX, tilesY) = GpuBinSpec.tileGrid(viewportWidth: width, viewportHeight: height,
                                                   tileSize: liveTile)
        let texW = Float(width), texH = Float(height)
        let invTile = 1.0 / Float(liveTile)

        // Cull strokes on the CPU via reference bounds (4-point transform each — the same
        // test `deviceOps` applies) and accumulate the layer tile box. Markers among the
        // *visible* strokes force the CPU path, exactly like the CPU eligibility check on
        // the post-cull op list.
        let cpuStart = DispatchTime.now().uptimeNanoseconds
        var visStrokeIDs: [Int] = []
        visStrokeIDs.reserveCapacity(layer.ops.count)
        var layerBox: (minX: Int, minY: Int, maxX: Int, maxY: Int)? = nil
        var strokeID = -1
        for op in layer.ops {
            guard case .stroke(let s) = op else { continue }
            strokeID += 1
            guard LiveRenderCache.intersects(s.bounds, camera: camera, viewport: viewport) else {
                continue
            }
            if s.isMarker { return false }
            visStrokeIDs.append(strokeID)
            // Transformed-bounds AABB (mirrors `intersects`' corner mapping).
            let p0 = CGPoint(x: s.bounds.minX, y: s.bounds.minY).applying(camera)
            let p1 = CGPoint(x: s.bounds.maxX, y: s.bounds.minY).applying(camera)
            let p2 = CGPoint(x: s.bounds.maxX, y: s.bounds.maxY).applying(camera)
            let p3 = CGPoint(x: s.bounds.minX, y: s.bounds.maxY).applying(camera)
            let minX = Float(min(min(p0.x, p1.x), min(p2.x, p3.x)))
            let maxX = Float(max(max(p0.x, p1.x), max(p2.x, p3.x)))
            let minY = Float(min(min(p0.y, p1.y), min(p2.y, p3.y)))
            let maxY = Float(max(max(p0.y, p1.y), max(p2.y, p3.y)))
            guard let tb = GpuBinSpec.tileBoxForAABB(minX: minX, minY: minY, maxX: maxX, maxY: maxY,
                                                     texW: texW, texH: texH,
                                                     tilesX: tilesX, tilesY: tilesY,
                                                     invTile: invTile) else {
                return false    // inconsistent with the cull above — stay exact via CPU
            }
            layerBox = GpuBinSpec.unionTileBox(layerBox, with: tb)
        }
        if visStrokeIDs.isEmpty {
            liveTiming.culledStrokes += cache.strokeCount(at: position)
            liveTiming.binMilliseconds += Self.milliseconds(since: cpuStart)
            return true     // nothing rasterised; compositing emptiness is identity
        }
        guard let box = layerBox else { return false }
        let boxW = box.maxX - box.minX + 1, boxH = box.maxY - box.minY + 1
        let boxTiles = boxW * boxH
        guard boxTiles > 0 else { return false }

        // Reference state (uploaded once per document/layer).
        let ref = try ensureBinRefState(device: device, docID: ObjectIdentifier(cache),
                                        layer: layer)
        var needsNoise = false
        for id in visStrokeIDs where ref.strokeHasNoise[id] { needsNoise = true; break }
        if needsNoise && noiseTexture == nil { return false }
        if needsNoise && livePerTileNoiseCompositePipeline == nil { return false }
        if !needsNoise && livePerTileAACompositePipeline == nil { return false }
        try ensureBinFrameBuffers(device: device, ref: ref, boxTiles: boxTiles)
        guard let frameSegs = ref.frameSegments, let ranges = ref.ranges,
              let counts = ref.counts, let staging = ref.countsStaging,
              let heads = ref.heads, let startsBuf = ref.starts,
              let tileIndexBuf = ref.tileIndex else {
            return false
        }

        // Visible-stroke bytes (shared buffer, CPU-written). Counts/heads are .private
        // and zeroed on the GPU (blit fill) inside the command buffers below.
        var visBytes = [UInt8](repeating: 0, count: ref.strokeCount)
        for id in visStrokeIDs { visBytes[id] = 1 }
        visBytes.withUnsafeBytes { raw in
            if let src = raw.baseAddress { memcpy(ref.strokeVisible.contents(), src, raw.count) }
        }

        // Same radius factor formula as `deviceOps` — passed in, never recomputed on GPU.
        let scaleX = sqrt(camera.a * camera.a + camera.c * camera.c)
        let scaleY = sqrt(camera.b * camera.b + camera.d * camera.d)
        let radiusFactor = Float((scaleX + scaleY) / 2.0)
        var tp = LiveBinTransformParams(
            segCount: UInt32(ref.segCount),
            tilesPerRow: UInt32(tilesX), tilesPerCol: UInt32(tilesY),
            tileSize: UInt32(liveTile),
            texW: texW, texH: texH, invTile: invTile, radiusFactor: radiusFactor,
            camA: Float(camera.a), camB: Float(camera.b),
            camC: Float(camera.c), camD: Float(camera.d),
            camTX: Float(camera.tx), camTY: Float(camera.ty))
        var bp = LiveBinBoxParams(
            segCount: UInt32(ref.segCount),
            boxMinX: Int32(box.minX), boxMinY: Int32(box.minY),
            boxW: Int32(boxW), boxH: Int32(boxH),
            tilesPerRow: UInt32(tilesX))
        liveTiming.binMilliseconds += Self.milliseconds(since: cpuStart)

        try ensureRenderTargets(width: width, height: height)
        try clearTexture(gpuRenderTarget!)

        // ── CB1: zero counts, fused transform+count, copy counts to staging for the
        // CPU prefix. Encoders in one command buffer retire in order. One wait; GPU time.
        let binThreads = MTLSize(width: 256, height: 1, depth: 1)
        func binGroups(_ n: Int) -> MTLSize {
            MTLSize(width: (n + 255) / 256, height: 1, depth: 1)
        }
        let countBytes = boxTiles * MemoryLayout<UInt32>.size
        var clock = DispatchTime.now().uptimeNanoseconds
        guard let cb1 = queue.makeCommandBuffer(),
              let zeroEnc = cb1.makeBlitCommandEncoder() else { return false }
        zeroEnc.fill(buffer: counts, range: 0..<countBytes, value: 0)
        zeroEnc.endEncoding()
        guard let enc1 = cb1.makeComputeCommandEncoder() else { return false }
        enc1.setComputePipelineState(transformPipe)
        enc1.setBytes(&tp, length: MemoryLayout<LiveBinTransformParams>.stride, index: 0)
        enc1.setBuffer(ref.refSegments, offset: 0, index: 1)
        enc1.setBuffer(ref.segStroke, offset: 0, index: 2)
        enc1.setBuffer(ref.strokeVisible, offset: 0, index: 3)
        enc1.setBuffer(frameSegs, offset: 0, index: 4)
        enc1.setBuffer(ranges, offset: 0, index: 5)
        enc1.setBytes(&bp, length: MemoryLayout<LiveBinBoxParams>.stride, index: 6)
        enc1.setBuffer(counts, offset: 0, index: 7)
        enc1.dispatchThreadgroups(binGroups(ref.segCount), threadsPerThreadgroup: binThreads)
        enc1.endEncoding()
        guard let copyEnc = cb1.makeBlitCommandEncoder() else { return false }
        copyEnc.copy(from: counts, sourceOffset: 0,
                     to: staging, destinationOffset: 0, size: countBytes)
        copyEnc.endEncoding()
        clock = DispatchTime.now().uptimeNanoseconds
        cb1.commit()
        cb1.waitUntilCompleted()
        liveTiming.gpuMilliseconds += Self.milliseconds(since: clock)
        if let err = cb1.error { throw err }

        // ── CPU prefix over the tile counts (one tile grid, trivial) → tile table.
        let prefixStart = DispatchTime.now().uptimeNanoseconds
        var countsArr = [UInt32](repeating: 0, count: boxTiles)
        countsArr.withUnsafeMutableBytes { raw in
            if let dst = raw.baseAddress {
                memcpy(dst, staging.contents(), countBytes)
            }
        }
        let (entries, starts, total) = GpuBinSpec.combine(counts: countsArr)
        liveTiming.inkedTiles += countsArr.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
        if total == 0 {
            // Visible strokes, but none reaches a tile (all ranges empty): mirrors the CPU
            // path's per-stroke culling. Compositing the cleared target is identity.
            liveTiming.culledStrokes += visStrokeIDs.count
            liveTiming.binMilliseconds += Self.milliseconds(since: prefixStart)
            return true
        }
        if ref.tileListCap < total {
            let cap = max(total, ref.tileListCap * 2)
            guard let buf = device.makeBuffer(length: cap * MemoryLayout<UInt32>.size,
                                              options: .storageModePrivate) else {
                return false
            }
            ref.tileList = buf
            ref.tileListCap = cap
        }
        guard let tileList = ref.tileList else { return false }
        entries.withUnsafeBytes { raw in
            if let src = raw.baseAddress {
                memcpy(tileIndexBuf.contents(), src, raw.count)   // GpuBinTileEntry == TileIndex
            }
        }
        starts.withUnsafeBytes { raw in
            if let src = raw.baseAddress {
                memcpy(startsBuf.contents(), src, raw.count)
            }
        }
        // Scatter heads are per-tile bump counters starting at 0: the kernel writes
        // slot `starts[t] + bump(heads[t])`, so seeding heads with starts would add
        // the base twice and store past the tile list (GPU validation fault + hangs).
        // Heads are .private — zeroed by blit fill in CB2 below, not by CPU memset.
        liveTiming.binMilliseconds += Self.milliseconds(since: prefixStart)

        // ── CB2: scatter + sort + per-tile render + layer composite, one encoder so all
        // dispatches retire in order with coherent memory (same pattern as the CPU path).
        // With ART_LIVE_BINTIME=1 each stage gets its own command buffer + wait so the
        // log shows exactly which bin stage costs what (diagnostic only — steady state
        // keeps the single-CB form to avoid extra round trips).
        let stageTiming = LiveConfig.binStageTimingEnabled()
        var tScatter = 0.0, tSort = 0.0, tRender = 0.0
        func sync(_ cb: MTLCommandBuffer) throws -> Double {
            let t = DispatchTime.now().uptimeNanoseconds
            cb.commit()
            cb.waitUntilCompleted()
            if let err = cb.error { throw err }
            return Self.milliseconds(since: t)
        }
        if stageTiming {
            guard let cbH = queue.makeCommandBuffer(),
                  let fillH = cbH.makeBlitCommandEncoder(),
                  let cbS = queue.makeCommandBuffer(),
                  let encS = cbS.makeComputeCommandEncoder(),
                  let cbO = queue.makeCommandBuffer(),
                  let encO = cbO.makeComputeCommandEncoder(),
                  let cbR = queue.makeCommandBuffer(),
                  let encR = cbR.makeComputeCommandEncoder() else { return false }
            fillH.fill(buffer: heads, range: 0..<countBytes, value: 0)
            fillH.endEncoding()
            _ = try sync(cbH)
            encS.setComputePipelineState(scatterPipe)
            encS.setBytes(&bp, length: MemoryLayout<LiveBinBoxParams>.stride, index: 0)
            encS.setBuffer(ranges, offset: 0, index: 1)
            encS.setBuffer(startsBuf, offset: 0, index: 2)
            encS.setBuffer(heads, offset: 0, index: 3)
            encS.setBuffer(tileList, offset: 0, index: 4)
            encS.dispatchThreadgroups(binGroups(ref.segCount), threadsPerThreadgroup: binThreads)
            encS.endEncoding()
            tScatter = try sync(cbS)
            encO.setComputePipelineState(sortPipe)
            encO.setBytes(&bp, length: MemoryLayout<LiveBinBoxParams>.stride, index: 0)
            encO.setBuffer(tileIndexBuf, offset: 0, index: 1)
            encO.setBuffer(tileList, offset: 0, index: 2)
            encO.dispatchThreadgroups(binGroups(boxTiles), threadsPerThreadgroup: binThreads)
            encO.endEncoding()
            tSort = try sync(cbO)
            let renderStart = DispatchTime.now().uptimeNanoseconds
            try encodePerTileBuffers(segBuffer: frameSegs, segOffset: 0,
                                     strokeOfSegBuffer: ref.segStroke, strokeOfSegOffset: 0,
                                     tileStartCountBuffer: tileIndexBuf, tileStartCountOffset: 0,
                                     tileListBuffer: tileList, tileListOffset: 0,
                                     strokeColorBuffer: ref.strokeColors, strokeColorOffset: 0,
                                     strokeFlagsBuffer: ref.strokeFlags, strokeFlagsOffset: 0,
                                     boxMinX: box.minX, boxMinY: box.minY,
                                     boxWidth: boxW, boxHeight: boxH,
                                     containsNoise: needsNoise,
                                     encoder: encR)
            liveTiming.encodeMilliseconds += Self.milliseconds(since: renderStart)
            guard let canvas = liveCanvasTexture, let layerTex = gpuRenderTarget else { return false }
            var layerOpacity = opacity
            encR.setComputePipelineState(compositePipeline)
            encR.setTexture(layerTex, index: 0)
            encR.setTexture(canvas, index: 1)
            encR.setBytes(&layerOpacity, length: MemoryLayout<Float>.stride, index: 0)
            encR.dispatchThreadgroups(Self.liveGroups(width: width, height: height),
                                      threadsPerThreadgroup: Self.liveThreads)
            encR.endEncoding()
            tRender = try sync(cbR)
            liveTiming.gpuMilliseconds += tScatter + tSort + tRender
            print(String(format: "livebin layer %d: segs %d tiles %d — scatter %.2f sort %.2f render+comp %.2f ms",
                         position, ref.segCount, boxTiles, tScatter, tSort, tRender))
            liveTiming.dispatchedTiles += boxTiles
            liveTiming.sdfEvaluations += total * (liveTile * liveTile)
            liveTiming.strokes += visStrokeIDs.count
            var segTotal = 0
            for id in visStrokeIDs { segTotal += ref.strokeSegCounts[id] }
            liveTiming.segments += segTotal
            return true
        }
        clock = DispatchTime.now().uptimeNanoseconds
        guard let cb2 = queue.makeCommandBuffer(),
              let fill2 = cb2.makeBlitCommandEncoder() else { return false }
        fill2.fill(buffer: heads, range: 0..<countBytes, value: 0)
        fill2.endEncoding()
        guard let enc2 = cb2.makeComputeCommandEncoder() else { return false }
        enc2.setComputePipelineState(scatterPipe)
        enc2.setBytes(&bp, length: MemoryLayout<LiveBinBoxParams>.stride, index: 0)
        enc2.setBuffer(ranges, offset: 0, index: 1)
        enc2.setBuffer(startsBuf, offset: 0, index: 2)
        enc2.setBuffer(heads, offset: 0, index: 3)
        enc2.setBuffer(tileList, offset: 0, index: 4)
        enc2.dispatchThreadgroups(binGroups(ref.segCount), threadsPerThreadgroup: binThreads)
        enc2.setComputePipelineState(sortPipe)
        enc2.setBytes(&bp, length: MemoryLayout<LiveBinBoxParams>.stride, index: 0)
        enc2.setBuffer(tileIndexBuf, offset: 0, index: 1)
        enc2.setBuffer(tileList, offset: 0, index: 2)
        enc2.dispatchThreadgroups(binGroups(boxTiles), threadsPerThreadgroup: binThreads)
        let renderStart = DispatchTime.now().uptimeNanoseconds
        try encodePerTileBuffers(segBuffer: frameSegs, segOffset: 0,
                                 strokeOfSegBuffer: ref.segStroke, strokeOfSegOffset: 0,
                                 tileStartCountBuffer: tileIndexBuf, tileStartCountOffset: 0,
                                 tileListBuffer: tileList, tileListOffset: 0,
                                 strokeColorBuffer: ref.strokeColors, strokeColorOffset: 0,
                                 strokeFlagsBuffer: ref.strokeFlags, strokeFlagsOffset: 0,
                                 boxMinX: box.minX, boxMinY: box.minY,
                                 boxWidth: boxW, boxHeight: boxH,
                                 containsNoise: needsNoise,
                                 encoder: enc2)
        liveTiming.encodeMilliseconds += Self.milliseconds(since: renderStart)
        guard let canvas = liveCanvasTexture, let layerTex = gpuRenderTarget else { return false }
        var layerOpacity = opacity
        enc2.setComputePipelineState(compositePipeline)
        enc2.setTexture(layerTex, index: 0)
        enc2.setTexture(canvas, index: 1)
        enc2.setBytes(&layerOpacity, length: MemoryLayout<Float>.stride, index: 0)
        enc2.dispatchThreadgroups(Self.liveGroups(width: width, height: height),
                                  threadsPerThreadgroup: Self.liveThreads)
        enc2.endEncoding()
        clock = DispatchTime.now().uptimeNanoseconds
        cb2.commit()
        cb2.waitUntilCompleted()
        liveTiming.gpuMilliseconds += Self.milliseconds(since: clock)
        if let err = cb2.error { throw err }

        liveTiming.dispatchedTiles += boxTiles
        liveTiming.sdfEvaluations += total * (liveTile * liveTile)
        liveTiming.strokes += visStrokeIDs.count
        var segTotal = 0
        for id in visStrokeIDs { segTotal += ref.strokeSegCounts[id] }
        liveTiming.segments += segTotal
        return true
    }

    /// Uploads a layer's reference-space geometry once (validated by cache identity +
    /// segment count); later frames reuse it untouched.
    private func ensureBinRefState(device: MTLDevice, docID: ObjectIdentifier,
                                   layer: LiveCachedLayer) throws -> LiveBinRefLayer {
        if liveBinDocID != docID { liveBinLayers.removeAll(); liveBinDocID = docID }
        if let ref = liveBinLayers[layer.layerIndex],
           ref.docID == docID, ref.segCount == layer.cachedSegmentCount {
            return ref
        }
        var segments: [GPUSplineSegment] = []
        var segStroke: [UInt32] = []
        var colors: [SIMD4<Float>] = []
        var flags: [UInt32] = []
        var bounds: [CGRect] = []
        var markers: [Bool] = []
        var noisy: [Bool] = []
        var segCounts: [Int] = []
        segments.reserveCapacity(layer.cachedSegmentCount)
        for op in layer.ops {
            guard case .stroke(let s) = op else { continue }
            let sid = UInt32(colors.count)
            colors.append(s.color)
            let hasNoise = s.segments.contains { $0.noiseSeed != 0 }
            flags.append(LivePerTileEligibility.strokeFlags(isEraser: s.isEraser,
                                                            hasNoise: hasNoise))
            bounds.append(s.bounds)
            markers.append(s.isMarker)
            noisy.append(hasNoise)
            segCounts.append(s.segments.count)
            segments.append(contentsOf: s.segments)
            segStroke.append(contentsOf: Array(repeating: sid, count: s.segments.count))
        }
        guard !segments.isEmpty else { throw MetalRendererError.bufferCreationFailed }
        func upload<T>(_ array: [T], _ stride: Int) throws -> MTLBuffer {
            guard let buf = device.makeBuffer(length: max(stride * array.count, 1),
                                              options: .storageModeShared) else {
                throw MetalRendererError.bufferCreationFailed
            }
            array.withUnsafeBytes { raw in
                if let src = raw.baseAddress { memcpy(buf.contents(), src, raw.count) }
            }
            return buf
        }
        guard let visible = device.makeBuffer(length: max(colors.count, 1),
                                              options: .storageModeShared) else {
            throw MetalRendererError.bufferCreationFailed
        }
        memset(visible.contents(), 0, max(colors.count, 1))
        let ref = LiveBinRefLayer(
            docID: docID, segCount: segments.count, strokeCount: colors.count,
            refSegments: try upload(segments, MemoryLayout<GPUSplineSegment>.stride),
            segStroke: try upload(segStroke, MemoryLayout<UInt32>.stride),
            strokeColors: try upload(colors, MemoryLayout<SIMD4<Float>>.stride),
            strokeFlags: try upload(flags, MemoryLayout<UInt32>.stride),
            strokeVisible: visible,
            strokeBounds: bounds, strokeIsMarker: markers, strokeHasNoise: noisy,
            strokeSegCounts: segCounts)
        liveBinLayers[layer.layerIndex] = ref
        return ref
    }

    /// Sizes the layer's frame buffers (geometric reuse — steady-state frames allocate
    /// nothing). Counts/heads/starts/tileIndex track the tile box; frame segments and
    /// ranges track the segment count.
    private func ensureBinFrameBuffers(device: MTLDevice, ref: LiveBinRefLayer,
                                       boxTiles: Int) throws {
        func shared(_ bytes: Int) throws -> MTLBuffer {
            guard let buf = device.makeBuffer(length: max(bytes, 1),
                                              options: .storageModeShared) else {
                throw MetalRendererError.bufferCreationFailed
            }
            return buf
        }
        let segBytes = ref.segCount * MemoryLayout<GPUSplineSegment>.stride
        if ref.frameSegments == nil || ref.frameSegments!.length < segBytes {
            ref.frameSegments = device.makeBuffer(length: segBytes, options: .storageModePrivate)
            guard ref.frameSegments != nil else { throw MetalRendererError.bufferCreationFailed }
        }
        let rangeBytes = ref.segCount * 16
        if ref.ranges == nil || ref.ranges!.length < rangeBytes {
            ref.ranges = device.makeBuffer(length: rangeBytes, options: .storageModePrivate)
            guard ref.ranges != nil else { throw MetalRendererError.bufferCreationFailed }
        }
        if ref.boxCap < boxTiles {
            func priv(_ bytes: Int) throws -> MTLBuffer {
                guard let buf = device.makeBuffer(length: max(bytes, 1),
                                                  options: .storageModePrivate) else {
                    throw MetalRendererError.bufferCreationFailed
                }
                return buf
            }
            ref.counts = try priv(boxTiles * MemoryLayout<UInt32>.size)
            ref.countsStaging = try shared(boxTiles * MemoryLayout<UInt32>.size)
            ref.heads = try priv(boxTiles * MemoryLayout<UInt32>.size)
            ref.starts = try shared(boxTiles * MemoryLayout<UInt32>.size)
            ref.tileIndex = try shared(boxTiles * 8)
            ref.boxCap = boxTiles
        }
    }

    /// Threads per threadgroup for the live passes: one thread per pixel, but 32×32 of
    /// them instead of 8×8.
    ///
    /// The segment kernels derive their tile from `thread_position_in_grid`, so the thread
    /// shape is free — and it is worth choosing well: a live frame dispatches *once per
    /// stroke*, and each launch covers the whole canvas, so the launch overhead of the
    /// (mostly empty) tiles dominates. 32×32 = 1024 threads is the hardware maximum, which
    /// makes it 16× fewer threadgroup launches for identical work.
    /// Threads per threadgroup for the live passes. Thread-per-pixel, so the shape is free
    /// *and it's an occupancy knob*: the kernels are memory-latency bound (Instruments
    /// shows ~80% SIMD-group memory stall), and smaller groups let more of them be resident
    /// at once, which is what hides that latency. 16×16 ≈ 256 threads is fewer registers
    /// per group than 32×32 and roughly quadruples the number of resident groups;
    /// `groupsPerTile` in `encode(stroke:)` scales with this automatically. (8×8 if you
    /// want to push occupancy further.) Output is unaffected — only dispatch granularity.
    /// Per-tile composite (one compute dispatch per layer → one canvas write per pixel,
    /// high occupancy) is the DEFAULT; set `ART_LIVE_PERTILE=0` to force the per-stroke
    /// path for A/B comparison. Falls back to per-stroke for any layer with cut ops or
    /// marker strokes, for noisy layers when the noise kernel/texture is unavailable, or
    /// if the kernel isn't in the installed metallib. Live tile size defaults to 16
    /// (`ART_LIVE_TILE_SIZE` → `ART_TILE_SIZE` → 16); the static path keeps its own size.
    static var perTileEnabled: Bool { LiveConfig.perTileEnabled() }

    static let liveThreads = MTLSize(width: 16, height: 16, depth: 1)

    /// Threadgroups needed for `width` × `height` pixels at `liveThreads`.
    static func liveGroups(width: Int, height: Int) -> MTLSize {
        MTLSize(width: (width + Int(liveThreads.width) - 1) / Int(liveThreads.width),
                height: (height + Int(liveThreads.height) - 1) / Int(liveThreads.height),
                depth: 1)
    }
    
    /// Bins every stroke into `liveStaging` and returns the ordered op list.
    private func bin(layerOps: [LiveDeviceOp],
                     width: Int, height: Int) throws -> ([LiveLayerStep], [LiveStrokeBin]) {
        var cursor = 0
        var bins: [LiveStrokeBin] = []
        var steps: [LiveLayerStep] = []
        steps.reserveCapacity(layerOps.count)

        // Last frame's footprint is a very good guess for this one (same document, a
        // similar camera), so ask for it up front — that is what keeps a steady-state
        // frame allocation-free.
        if liveStagingUsed > 0, staging(needed: liveStagingUsed) == nil {
            throw MetalRendererError.bufferCreationFailed
        }

        for op in layerOps {
            switch op {
                case .cut(let meta):
                    steps.append(.cut(meta))
                case .stroke(let segments, let color, let isEraser, let isMarker):
                    guard !segments.isEmpty else { continue }
                    liveTiming.strokes += 1
                    liveTiming.segments += segments.count
                    let liveTile = liveTileSize
                    let boxed = buildSegmentTileIndicesBoxed(
                        segments: segments,
                        textureWidth: width,
                        textureHeight: height,
                        tileSize: liveTile,
                        isMarker: isMarker,
                        transform: nil)
                    // Nothing of this stroke lands on-canvas, so nothing is lost by
                    // skipping it entirely (the same test the segment binner applies).
                    if boxed.tileList.isEmpty {
                        liveTiming.culledStrokes += 1
                        liveTiming.strokes -= 1
                        liveTiming.segments -= segments.count
                        continue
                    }
                    // Box-local tile structures for the arena — the whole canvas is never
                    // materialised, only this stroke's tile box.
                    let tileIndicesData = boxed.tileIndices
                    let tileListData = boxed.tileList

                    var bin = LiveStrokeBin()
                    bin.segmentCount = segments.count
                    bin.color = color
                    bin.isEraser = isEraser
                    bin.isMarker = isMarker
                    bin.hasNoise = segments.contains { $0.noiseSeed != 0 }
                    bin.minTileX = boxed.minTileX
                    bin.minTileY = boxed.minTileY
                    bin.maxTileX = boxed.minTileX + boxed.boxWidth - 1
                    bin.maxTileY = boxed.minTileY + boxed.boxHeight - 1
                    bin.boxTilesPerRow = boxed.boxWidth

                    // Debug counters (pure CPU arithmetic, no GPU sync): dispatched tiles =
                    // the stroke's box; ink tiles = tiles that actually hold a segment; sdf
                    // evaluations = candidate distance-field lookups the kernel is asked to do.
                    liveTiming.dispatchedTiles += boxed.boxWidth * boxed.boxHeight
                    liveTiming.inkedTiles += tileIndicesData.reduce(0) { $0 + ($1.count > 0 ? 1 : 0) }
                    liveTiming.sdfEvaluations += tileListData.count * (liveTile * liveTile)
                    
                    // Layout: segments, tile indices, tile list — each 256-aligned so it
                    // can be bound as an MTLBuffer offset.
                    cursor = Self.alignUp(cursor, Self.liveArenaAlignment)
                    bin.segmentOffset = cursor
                    cursor += MemoryLayout<GPUSplineSegment>.stride * segments.count
                    cursor = Self.alignUp(cursor, Self.liveArenaAlignment)
                    bin.tileIndexOffset = cursor
                    cursor += MemoryLayout<TileIndex>.stride * tileIndicesData.count
                    cursor = Self.alignUp(cursor, Self.liveArenaAlignment)
                    bin.tileListOffset = cursor
                    cursor += MemoryLayout<UInt32>.stride * tileListData.count
                    
                    guard let base = staging(needed: cursor) else {
                        throw MetalRendererError.bufferCreationFailed
                    }
                    segments.withUnsafeBytes { raw in
                        if let src = raw.baseAddress {
                            (base + bin.segmentOffset).copyMemory(
                                from: src,
                                byteCount: MemoryLayout<GPUSplineSegment>.stride * segments.count)
                        }
                    }
                    tileIndicesData.withUnsafeBytes { raw in
                        if let src = raw.baseAddress {
                            (base + bin.tileIndexOffset).copyMemory(
                                from: src,
                                byteCount: MemoryLayout<TileIndex>.stride * tileIndicesData.count)
                        }
                    }
                    tileListData.withUnsafeBytes { raw in
                        if let src = raw.baseAddress {
                            (base + bin.tileListOffset).copyMemory(
                                from: src,
                                byteCount: MemoryLayout<UInt32>.stride * tileListData.count)
                        }
                    }
                    
                    steps.append(.stroke(bins.count))
                    bins.append(bin)
            }
        }
        
        liveStagingUsed = Self.alignUp(cursor, Self.liveArenaAlignment)
        return (steps, bins)
    }
    
    /// CPU staging buffer, grown on demand (existing contents are preserved — strokes
    /// are written as they are binned, so a grow must not drop the earlier ones).
    ///
    /// - Important: growth is **geometric**, never exact-fit. `bin` asks for more room once
    ///   per stroke, so an exact-fit policy reallocated and copied the whole arena n times
    ///   on the first frame of an n-stroke document — and because a fresh raw block is a new
    ///   mmap, every one of those copies also faulted every page in again. For a ~20 MB
    ///   arena that turned the first frame into tens of seconds; with doubling plus the
    ///   previous frame's size as a hint it is a handful of allocations overall.
    private func staging(needed: Int) -> UnsafeMutableRawPointer? {
        if needed > liveStagingCapacity {
            let target = max(needed, liveStagingCapacity * 2)
            let capacity = Self.alignUp(target, Self.liveArenaAlignment)
            let grown = UnsafeMutableRawPointer.allocate(byteCount: capacity,
                                                         alignment: Self.liveArenaAlignment)
            if let old = liveStaging {
                memcpy(grown, old, liveStagingCapacity)
                old.deallocate()
            }
            liveStaging = grown
            liveStagingCapacity = capacity
        }
        return liveStaging
    }
    
    /// Copies the staging buffer into the GPU arena (once per layer).
    private func uploadArena(byteCount: Int) throws {
        guard byteCount > 0 else { return }
        guard let device = self.device, let base = liveStaging else { return }
        if liveArena == nil || liveArenaCapacity < byteCount {
            liveArena = device.makeBuffer(length: byteCount, options: .storageModeShared)
            liveArenaCapacity = byteCount
        }
        guard let arena = liveArena else { throw MetalRendererError.bufferCreationFailed }
        memcpy(arena.contents(), base, byteCount)
    }
    
    /// Encodes one stroke's dispatch, reading its data from the arena.
    private func encode(stroke bin: LiveStrokeBin,
                        width: Int, height: Int,
                        encoder: MTLComputeCommandEncoder) throws {
        guard let arena = liveArena else { throw MetalRendererError.bufferCreationFailed }
        
        // One dispatch = one kernel, so noise segments never share a dispatch with clean
        // ones (mirrors `MetalRenderer_Dispatch.dispatchStrokeToGPU`). The live twins take
        // the stroke's tile box (bin.min/maxTile) so the dispatch covers only the tiles the
        // stroke actually reaches — see `bin` and `liveSegment*CompositeKernel`.
        var pipeline: MTLComputePipelineState?
        if bin.hasNoise, let p = liveSegmentNoiseCompositePipeline, let noise = noiseTexture {
            pipeline = p
            encoder.setTexture(noise, index: 1)
            if let sampler = linearSampler { encoder.setSamplerState(sampler, index: 0) }
        } else {
            pipeline = liveSegmentAACompositePipeline
        }
        guard let pipeline = pipeline else {
            throw MetalRendererError.pipelineMissing("liveSegmentAACompositeKernel")
        }
        
        var flags: UInt32 = 0
        if bin.isEraser { flags |= 1 }
        if bin.isMarker { flags |= 2 }
        let liveTile = liveTileSize
        var params = LiveStrokeParams(
            tileOriginX: UInt32(bin.minTileX), tileOriginY: UInt32(bin.minTileY),
            boxTilesPerRow: UInt32(bin.boxTilesPerRow),
            tileSize: UInt32(liveTile),
            textureWidth: UInt32(width), textureHeight: UInt32(height),
            stampCount: UInt32(bin.segmentCount),
            penColorR: bin.color.x, penColorG: bin.color.y,
            penColorB: bin.color.z, penColorA: bin.color.w,
            noiseScale: 0.4,
            flags: flags)
        
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&params, length: MemoryLayout<LiveStrokeParams>.stride, index: 0)
        encoder.setBuffer(arena, offset: bin.segmentOffset, index: 1)
        encoder.setBuffer(arena, offset: bin.tileIndexOffset, index: 2)
        encoder.setBuffer(arena, offset: bin.tileListOffset, index: 3)
        encoder.setTexture(gpuRenderTarget, index: 0)
        // Dispatch only the stroke's tile box: ceil(tileSize / threadDim) threadgroups per
        // tile, over [minTile…maxTile]. A single-tile stroke yields 1 (never 0).
        let groupsPerTileX = (liveTile + Int(Self.liveThreads.width) - 1) / Int(Self.liveThreads.width)
        let groupsPerTileY = (liveTile + Int(Self.liveThreads.height) - 1) / Int(Self.liveThreads.height)
        let groups = MTLSize(width: (bin.maxTileX - bin.minTileX + 1) * groupsPerTileX,
                             height: (bin.maxTileY - bin.minTileY + 1) * groupsPerTileY,
                             depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: Self.liveThreads)
    }
    
    /// Cut dispatch into a caller-supplied encoder.
    private func dispatchLiveCut(meta: CutMeta,
                                 width: Int, height: Int,
                                 encoder: MTLComputeCommandEncoder) throws {
        guard let pipeline = segmentCutCompositePipeline else {
            throw MetalRendererError.pipelineMissing("segmentCutCompositeKernel")
        }
        // `setBytes` snapshots the value at encode time, which is why several cuts can
        // share one command buffer (unlike a shared MTLBuffer).
        var cutMeta = meta
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&cutMeta, length: MemoryLayout<CutMeta>.stride, index: 0)
        encoder.setTexture(gpuRenderTarget, index: 0)
        encoder.dispatchThreadgroups(Self.liveGroups(width: width, height: height),
                                     threadsPerThreadgroup: Self.liveThreads)
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
        
        encoder.dispatchThreadgroups(Self.liveGroups(width: width, height: height),
                                     threadsPerThreadgroup: Self.liveThreads)
        encoder.endEncoding()
        
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        if let err = commandBuffer.error { throw err }
    }
    
    // MARK: - Paper / background
    
    /// Bakes paper colour + tiled paper texture + background multiply into the
    /// background texture. Mirrors `Renderer.render(art:)`'s background block.
    ///
    /// - Parameters:
    ///   - documentFromCanvas: canvas pixels → canvas points (identity for the raster
    ///     path, `camera⁻¹ ∘ scale⁻¹` when the canvas *is* the viewport). The paper is
    ///     tiled in canvas space so it is anchored to the page, not to the glass.
    ///   - tileScale: extra multiplier on the tile size; pass the render `scale` for
    ///     the legacy (canvas-space) tiling, 1 for document-space tiling.
    func renderLivePaperBackground(paperColor: (r: CGFloat, g: CGFloat, b: CGFloat),
                                   paperStrength: Float,
                                   backgroundColor: [UInt8],
                                   paperTextureData: [UInt8],
                                   tileScale: CGFloat,
                                   documentFromCanvas: CGAffineTransform,
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
            // Same tile size as the CoreGraphics path: image size × 0.666 × tileScale.
            tileW = Float(paper.width) * 0.666 * Float(tileScale)
            tileH = Float(paper.height) * 0.666 * Float(tileScale)
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
            canvasW: Float(width), canvasH: Float(height),
            m00: Float(documentFromCanvas.a), m01: Float(documentFromCanvas.c), m02: Float(documentFromCanvas.tx),
            m10: Float(documentFromCanvas.b), m11: Float(documentFromCanvas.d), m12: Float(documentFromCanvas.ty))
        
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
        
        encoder.dispatchThreadgroups(Self.liveGroups(width: width, height: height),
                                     threadsPerThreadgroup: Self.liveThreads)
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
        desc.storageMode = .managed
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
        desc.storageMode = .managed
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        var white: UInt32 = 0xFFFFFFFF          // RGBA8, little endian
        texture.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
                        withBytes: &white, bytesPerRow: MemoryLayout<UInt32>.size)
        placeholderTexture = texture
        return texture
    }
    
    /// The pair being rendered into (not necessarily the one on screen).
    var livePresentTextures: (canvas: MTLTexture, background: MTLTexture)? {
        guard let canvas = liveCanvasTexture, let background = liveBackgroundTexture else { return nil }
        return (canvas, background)
    }
}
#endif
