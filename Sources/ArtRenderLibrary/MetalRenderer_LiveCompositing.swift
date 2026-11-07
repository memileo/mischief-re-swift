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
    var boxTilesPerCol: UInt32
    var tileSize: UInt32
    var textureWidth: UInt32
    var textureHeight: UInt32
    var stampCount: UInt32
    var penColorR: Float
    var penColorG: Float
    var penColorB: Float
    var penColorA: Float
    var noiseScale: Float
    var noiseOffsetX: Float = 0
    var noiseOffsetY: Float = 0
    var flags: UInt32
}

// Must match `PerTileParams` in segmentKernels.metal byte for byte (scalars only).
struct PerTileParams {
    var tileOriginX: UInt32
    var tileOriginY: UInt32
    var boxTilesPerRow: UInt32
    var boxTilesPerCol: UInt32
    var tileSize: UInt32
    /// `ART_LIVE_ABLATE` mask — 0 in normal use (see `LiveConfig.ablate`).
    var ablate: UInt32
    /// Noise sampling offset so the grain follows the view (viewport pixels).
    var noiseOffsetX: Float = 0
    var noiseOffsetY: Float = 0
    /// bit0 = per-pixel stroke-saturation skip (`ART_LIVE_SATURATE=0` A/Bs it off).
    /// Exact by construction: a pixel's coverage for a stroke is a max over its segments
    /// of `cov · opacity`, and both factors are ≤ 1, so once the running max reaches 1 the
    /// rest of that stroke's segments cannot change it (see the kernel's `satCeil`).
    var flags: UInt32
    /// Tiles per row of the `tileStartCount` grid. Equal to `boxTilesPerRow` for a
    /// CPU-planned layer box and the pure GPU path; the layer's wider stride when a
    /// mixed layer renders one stroke run as a sub-box of its GPU-binned layer grid.
    var tileGridStride: UInt32
    /// Offset of this dispatch's box inside `tileStartCount`.
    var tileArrayBase: UInt32
    /// Inclusive reference-stroke range this dispatch may composite. `0…UInt32.max`
    /// (all strokes) for the CPU plan and the pure GPU path; a run's stroke range for the
    /// mixed GPU path, so the shared layer tile list serves every run in document order.
    var strokeLo: UInt32
    var strokeHi: UInt32
}

// Must match `LiveBinTransformParams` in segmentKernels.metal field for field, in order.
// All 4-byte scalars: 4 uint + 10 float + 1 uint = stride 60 on both sides.
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
    /// 1 = the layer composites through the noise-capable kernel, whose prune reach is
    /// `liveNoisePruneMargin` instead of the AA margin — the bin pad has to match it.
    var noiseLayer: UInt32
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

// Must match `LiveBinSortParams` in segmentKernels.metal field for field, in order.
// 2×uint = stride 8 on both sides. The chunk-sort dispatch uses `unitCount` as the
// chunk count (one threadgroup each); each merge dispatch reuses it as the pair
// count, with `runSize` doubling per pass from one sort chunk.
struct LiveBinSortParams {
    var unitCount: UInt32
    var runSize: UInt32
}

// Must match `LiveSplatParams` in segmentKernels.metal field for field, in order.
// 8×uint + 4×int = stride 48 on both sides.
struct LiveSplatParams {
    var segCount: UInt32
    var slotsPerPixel: UInt32
    var batchStart: UInt32
    var batchCount: UInt32
    var tileSize: UInt32
    var boxTilesPerRow: UInt32
    var boxTilesPerCol: UInt32
    var flags: UInt32
    var noiseOffsetX: Float = 0
    var noiseOffsetY: Float = 0
    var originPxX: Int32
    var originPxY: Int32
    var boxPixW: Int32
    var boxPixH: Int32
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
            ("liveBinChunkSortV3Kernel", { self.liveBinChunkSortPipeline = $0 }),
            ("liveBinChunkSortV4Kernel", { self.liveBinChunkSortBitonicPipeline = $0 }),
            ("liveBinMergePassV3Kernel", { self.liveBinMergePassPipeline = $0 }),
            ("liveBinCopyKernel", { self.liveBinCopyPipeline = $0 }),
            // Segment-parallel splat composite (small-stamp regime). All optional:
            // a metallib without them (or ART_LIVE_SPLAT=0) falls back to the walk.
            ("liveSplatKernel", { self.liveSplatPipeline = $0 }),
            ("liveSplatCompositeKernel", { self.liveSplatCompositePipeline = $0 }),
            ("liveSplatWriteKernel", { self.liveSplatWritePipeline = $0 }),
        ]
        for (name, assign) in binKernels {
            if let fn = library.makeFunction(name: name) {
                do {
                    assign(try device.makeComputePipelineState(function: fn))
                } catch {
                    print("Live view: \(name) pipeline failed (\(error)) — feature disabled")
                    assign(nil)
                }
            } else {
                print("Live view: \(name) not in metallib — feature disabled")
                assign(nil)
            }
        }
        // A stale metallib is the one failure that used to be silent: the kernels simply
        // never ran and every measurement looked like the walk. Say so unambiguously.
        if liveSplatPipeline == nil || liveSplatCompositePipeline == nil || liveSplatWritePipeline == nil {
            print("Live view: SPLAT kernels missing from the installed metallib — the splat path is OFF."
                  + " Rebuild it: Scripts/build-metallib.sh")
        }
        if liveBinChunkSortBitonicPipeline == nil {
            print("Live view: liveBinChunkSortV4Kernel missing — chunk sort falls back to the V3 heapsort.")
        }
        if liveBinTransformCountPipeline != nil,
           liveBinScatterPipeline != nil,
           liveBinChunkSortPipeline != nil,
           liveBinMergePassPipeline != nil,
           liveBinCopyPipeline != nil {
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

    /// One paste/merge op's slice of the arena, plus its destination tile box.
    private struct LivePasteBin {
        var segmentOffset = 0, segmentCount = 0
        var tileIndexOffset = 0, tileBoxCount = 0
        var tileListOffset = 0, tileListCount = 0
        var maskOffset = 0, maskCount = 0
        var color = SIMD4<Float>(0, 0, 0, 1)
        var isEraser = false
        var isMarker = false
        var hasNoise = false
        var isMerge = false
        var mergeID: UInt64 = 0
        var meta = PasteLayerMeta(invAffine: .identity, maskCount: 0)
        var minTileX = 0, minTileY = 0, boxWidth = 0, boxHeight = 0
    }

    /// One maximal run of stroke ops (a mixed layer's strokes between cuts/pastes), with
    /// the reference stroke ids it covers. `box*` is filled by `prepareMixedGPUBin` and is
    /// the tile box this run dispatches over inside the layer's GPU-binned tile grid.
    private struct MixedStrokeRun {
        var strokeIDs: [Int] = []
        var opStart = 0, opEnd = 0
        var hasNoise = false, hasMarker = false
        var boxMinX = 0, boxMinY = 0, boxWidth = 0, boxHeight = 0
        var boxValid = false
        /// The per-tile kernels can render this run when the chisel marker SDF and the
        /// noise composite don't collide (same rule as `LivePerTileEligibility`).
        var perTileEligible: Bool { !(hasMarker && hasNoise) }
    }

    /// A mixed layer's GPU binning state for one frame: the whole layer is transformed,
    /// counted, scattered and sorted once; each stroke run then renders its own sub-box of
    /// that tile grid, restricted to its reference-stroke range (see `PerTileParams`).
    private struct MixedGPUBin {
        var ref: LiveBinRefLayer
        var runs: [MixedStrokeRun]
        var bp: LiveBinBoxParams
        var total: Int
        var boxTiles: Int
        var boxMinX = 0, boxMinY = 0, boxWidth = 0, boxHeight = 0
        var tileList: MTLBuffer
        var tileScratch: MTLBuffer
        /// The shared sort plan; `finalTileList` is where it leaves the ordered list.
        var sortPlan: LiveBinSortPlan
    }

    /// A mixed layer's work in document order. Stroke runs and pastes are indices into
    /// the caller's arrays; cuts carry their metadata.
    private enum LiveMixedWork {
        case run(Int)
        case cut(CutMeta)
        case paste(Int)
    }

    /// A stroke run's CPU fallback plan when GPU binning is unavailable.
    private enum MixedCPURun {
        case perTile(PerTilePlan)
        case strokes([Int])
        case empty
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
        // per pixel + high occupancy — the memory fix) for layers without cuts (noise
        // included via the noise-capable kernel, markers via the AA kernel's bit2 chisel
        // branch). Anything else uses the proven *per-stroke* path (one dispatch per
        // stroke) — the only way cuts stay exact, and the fallback for a layer that holds
        // both a marker and a noisy segment (the noise kernel has no marker SDF).
        var clock = DispatchTime.now().uptimeNanoseconds
        liveStagingUsed = 0                    // planning appends from here
        var perTilePlan: PerTilePlan?
        if Self.perTileEnabled, isPerTileEligible(layerOps) {
            let force = LiveConfig.forcedCompositeKernel()
            let rawNeedsNoise = layerOps.contains {
                if case .stroke(let segs, _, _, _, _) = $0 { return segs.contains { $0.noiseSeed != 0 } }
                return false
            }
            let needsNoise = force.applied(to: rawNeedsNoise)
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
    
    /// Rasterises a cached layer that mixes strokes with cuts and/or pastes.
    ///
    /// Everything is encoded into **one** command buffer, in document order: maximal runs
    /// of strokes render through the GPU-binned per-tile path (or the CPU plan / per-stroke
    /// fallback), cuts erase in place, pastes dispatch only their destination tile box, and
    /// merge groups render into the shared fragment texture and flatten once. The layer is
    /// stacked onto the canvas at the end, so a frame costs a single GPU round trip even
    /// for documents with thousands of cut/paste actions.
    ///
    /// The GPU path bins the layer's strokes **once** (transform + count + scatter + sort)
    /// and then renders each stroke run as a sub-box of that tile grid, filtered to the
    /// run's reference-stroke range. That keeps the cuts/pastes interleaved while removing
    /// the per-run CPU binning (`doodle` spends ~13 ms there, 8 runs around 7 merges).
    func renderCachedLayerMixedIntoLiveCanvas(layerOps: [LiveDeviceOp],
                                              cache: LiveRenderCache,
                                              position: Int,
                                              camera: CGAffineTransform,
                                              viewport: CGRect,
                                              width: Int, height: Int,
                                              opacity: Float) throws {
        guard let compositePipeline = liveCompositeLayerPipeline else {
            throw MetalRendererError.pipelineMissing("liveCompositeLayerKernel")
        }
        guard !layerOps.isEmpty else { return }
        try ensureRenderTargets(width: width, height: height)
        guard let target = gpuRenderTarget else {
            throw MetalRendererError.textureCreationFailed
        }

        var clock = DispatchTime.now().uptimeNanoseconds
        liveStagingUsed = 0
        var work: [LiveMixedWork] = []
        var runs: [MixedStrokeRun] = []
        var pastes: [LivePasteBin] = []
        work.reserveCapacity(layerOps.count)

        // ── 1. Split into runs / cuts / pastes, planning the pastes into the arena.
        var index = 0
        while index < layerOps.count {
            switch layerOps[index] {
                case .stroke:
                    // Maximal stroke run: one per-tile dispatch instead of one per stroke.
                    var end = index
                    var run = MixedStrokeRun()
                    run.opStart = index
                    while end < layerOps.count,
                          case .stroke(let segs, _, _, let marker, let strokeID) = layerOps[end] {
                        run.strokeIDs.append(strokeID)
                        if marker { run.hasMarker = true }
                        if !run.hasNoise { run.hasNoise = segs.contains { $0.noiseSeed != 0 } }
                        end += 1
                    }
                    run.opEnd = end
                    runs.append(run)
                    work.append(.run(runs.count - 1))
                    index = end

                case .cut(let meta):
                    work.append(.cut(meta))
                    index += 1

                case .paste(let segments, let color, let isEraser, let isMarker,
                            let meta, let masks, let sourceToDestination,
                            let isMerge, let mergeID):
                    // A paste group is keyed by colour / eraser / marker / transform /
                    // masks, so it can hold both clean and noisy strokes. A bin picks
                    // ONE coverage model for the whole batch (`bin.hasNoise`), so a
                    // single noisy stroke would drag every clean stroke of the group
                    // onto the noise kernel (the paste is a max over the batch's
                    // segments, so a mixed batch also paints the wrong softness).
                    // Mirror the static dispatcher's split: one batch per class, clean
                    // first — same segments, same order, same pixels.
                    let hasNoisy = segments.contains { $0.noiseSeed != 0 }
                    let hasClean = segments.contains { $0.noiseSeed == 0 }
                    let batches: [[GPUSplineSegment]] = (hasNoisy && hasClean)
                        ? [segments.filter { $0.noiseSeed == 0 },
                           segments.filter { $0.noiseSeed != 0 }]
                        : [segments]
                    for batch in batches {
                        if let bin = try plan(paste: batch, color: color,
                                              isEraser: isEraser, isMarker: isMarker,
                                              meta: meta, masks: masks,
                                              sourceToDestination: sourceToDestination,
                                              isMerge: isMerge, mergeID: mergeID,
                                              width: width, height: height) {
                            work.append(.paste(pastes.count))
                            pastes.append(bin)
                        }
                    }
                    index += 1
            }
        }

        // ── 2. GPU bin the whole layer's strokes once, when every run can render through
        // the same per-tile kernels. Otherwise every run keeps its own CPU plan.
        let force = LiveConfig.forcedCompositeKernel()
        let gpuEligible = Self.perTileEnabled && runs.allSatisfy { run in
            guard run.perTileEligible else { return false }
            let needsNoise = force.applied(to: run.hasNoise)
            return needsNoise
                ? (livePerTileNoiseCompositePipeline != nil && noiseTexture != nil)
                : livePerTileAACompositePipeline != nil
        }
        var gpuBin: MixedGPUBin?
        if gpuEligible {
            // Any allocation/encoding failure falls back to the CPU plan below; a frame
            // must never fail just because the GPU bin could not be prepared.
            gpuBin = try? prepareMixedGPUBin(cache: cache, position: position,
                                             camera: camera, runs: runs,
                                             width: width, height: height)
            if let bin = gpuBin { runs = bin.runs }
        }

        var cpuRuns: [MixedCPURun] = []
        var bins: [LiveStrokeBin] = []
        if gpuBin == nil {
            cpuRuns.reserveCapacity(runs.count)
            for run in runs {
                let runOps = Array(layerOps[run.opStart..<run.opEnd])
                var handled = false
                if Self.perTileEnabled, isPerTileEligible(runOps) {
                    let needsNoise = force.applied(to: run.hasNoise)
                    let pipelineAvailable = needsNoise
                        ? livePerTileNoiseCompositePipeline != nil
                        : livePerTileAACompositePipeline != nil
                    if pipelineAvailable, !(needsNoise && noiseTexture == nil) {
                        let plan = try buildPerTilePlan(layerOps: runOps,
                                                        width: width, height: height)
                        cpuRuns.append(plan.empty ? .empty : .perTile(plan))
                        handled = true
                    }
                }
                if !handled {
                    let (runSteps, runBins) = try bin(layerOps: runOps,
                                                      width: width, height: height)
                    let base = bins.count
                    bins.append(contentsOf: runBins)
                    var strokeBins: [Int] = []
                    for step in runSteps {
                        if case .stroke(let i) = step { strokeBins.append(base + i) }
                    }
                    cpuRuns.append(strokeBins.isEmpty ? .empty : .strokes(strokeBins))
                }
            }
        }
        liveTiming.binMilliseconds += Self.milliseconds(since: clock)

        try uploadArena(byteCount: liveStagingUsed)

        guard let queue = commandQueue,
              let commandBuffer = queue.makeCommandBuffer() else {
            throw MetalRendererError.textureCreationFailed
        }

        // ── 3. Encode: clear, then the GPU bin's scatter/sort when present, then the
        // document-ordered work list. The scatter heads need a blit fill before the
        // compute pass, so that encoder comes first on the command buffer.
        if let bin = gpuBin, let heads = bin.ref.heads {
            guard let fill = commandBuffer.makeBlitCommandEncoder() else {
                throw MetalRendererError.textureCreationFailed
            }
            fill.fill(buffer: heads,
                      range: 0..<(bin.boxTiles * MemoryLayout<UInt32>.size), value: 0)
            fill.endEncoding()
        }
        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalRendererError.textureCreationFailed
        }
        clock = DispatchTime.now().uptimeNanoseconds

        encodeClear(target, encoder: encoder)
        if let bin = gpuBin {
            encodeBinScatter(ref: bin.ref, bp: bin.bp, tileList: bin.tileList,
                             encoder: encoder)
            try encodeBinOrder(bin.sortPlan, ref: bin.ref, total: bin.total,
                               tileList: bin.tileList, tileScratch: bin.tileScratch,
                               encoder: encoder)
        }

        var openMergeID: UInt64?
        var openMergeOpacity: Float = 1

        func flushOpenMerge() throws {
            guard openMergeID != nil else { return }
            openMergeID = nil
            try encodeMergeFlush(opacity: openMergeOpacity, encoder: encoder)
        }

        func encodePaste(_ i: Int) throws {
            let paste = pastes[i]
            if paste.isMerge {
                if let open = openMergeID, open != paste.mergeID {
                    try flushOpenMerge()
                }
                if openMergeID == nil {
                    guard let fragment = mergeFragmentTexture else {
                        throw MetalRendererError.textureCreationFailed
                    }
                    encodeClear(fragment, encoder: encoder)
                    openMergeID = paste.mergeID
                    openMergeOpacity = paste.color.w
                }
                guard let fragment = mergeFragmentTexture else {
                    throw MetalRendererError.textureCreationFailed
                }
                try encode(paste: paste, width: width, height: height,
                           target: fragment, alphaOverride: 1.0, encoder: encoder)
            } else {
                try flushOpenMerge()
                try encode(paste: paste, width: width, height: height,
                           target: target, alphaOverride: nil, encoder: encoder)
            }
        }

        for item in work {
            switch item {
                case .run(let i):
                    try flushOpenMerge()
                    if let bin = gpuBin {
                        try encodeGPURun(runs[i], bin: bin, encoder: encoder)
                    } else {
                        switch cpuRuns[i] {
                            case .perTile(let plan):
                                try encodePerTile(plan: plan, encoder: encoder)
                            case .strokes(let strokeBins):
                                for b in strokeBins {
                                    try encode(stroke: bins[b], width: width, height: height,
                                               encoder: encoder)
                                }
                            case .empty:
                                break
                        }
                    }

                case .cut(let meta):
                    try flushOpenMerge()
                    try dispatchLiveCut(meta: meta, width: width, height: height,
                                        encoder: encoder)

                case .paste(let i):
                    try encodePaste(i)
            }
        }
        try flushOpenMerge()
        liveTiming.encodeMilliseconds += Self.milliseconds(since: clock)

        // Stack the finished layer onto the canvas in the same command buffer.
        guard let canvas = liveCanvasTexture else {
            throw MetalRendererError.textureCreationFailed
        }
        var layerOpacity = opacity
        encoder.setComputePipelineState(compositePipeline)
        encoder.setTexture(target, index: 0)
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

    // MARK: - Bin sort plan (shared: pure GPU path + mixed layers)

    /// Everything a tile list needs after the scatter: the sortable slices, the merge
    /// units for every pass, and which ping-pong buffer the sorted data ends up in.
    ///
    /// The pure GPU path and the mixed-layer path count, prefix and scatter incidences
    /// identically; this is the shared tail, so both build one of these and encode it with
    /// `encodeBinOrder`, instead of each carrying its own copy of the sort plumbing.
    private struct LiveBinSortPlan {
        var chunks: [GpuBinChunk]
        var passUnits: [[GpuBinMergeUnit]]
        var passOffsets: [Int]
        var mergePasses: Int
        var chunkSize: Int
        /// The buffer holding the fully sorted list once every pass has run.
        var finalTileList: MTLBuffer

        /// No slice holds two entries, so the scattered list is already ascending.
        var isTrivial: Bool { chunks.isEmpty && mergePasses == 0 }
    }

    /// Builds the plan and uploads its tables into the layer's persistent buffers
    /// (`ref.sortChunks` / `ref.sortUnits`). Returns nil when a table cannot be allocated
    /// — the caller then falls back to the CPU plan. `allocMilliseconds` is the slice
    /// spent in `makeBuffer`, which the pure path reports separately from table building.
    private func makeBinSortPlan(device: MTLDevice, ref: LiveBinRefLayer,
                                 entries: [GpuBinTileEntry],
                                 tileList: MTLBuffer, tileScratch: MTLBuffer)
        -> (plan: LiveBinSortPlan, allocMilliseconds: Double)? {
        var alloc = 0.0
        let sortChunk = LiveConfig.sortChunkSize()
        let (chunks, _, mergePasses) = GpuBinSpec.chunkTable(entries: entries,
                                                             chunkSize: sortChunk)
        if ref.chunkCap < chunks.count {
            let start = DispatchTime.now().uptimeNanoseconds
            let cap = max(chunks.count, max(ref.chunkCap * 2, 1))
            guard let buf = device.makeBuffer(length: cap * MemoryLayout<GpuBinChunk>.stride,
                                              options: .storageModeShared) else { return nil }
            ref.sortChunks = buf
            ref.chunkCap = cap
            alloc += Self.milliseconds(since: start)
        }
        chunks.withUnsafeBytes { raw in
            if let src = raw.baseAddress, let dst = ref.sortChunks?.contents() {
                memcpy(dst, src, raw.count)
            }
        }
        // All passes live concatenated in ONE unit buffer: a dispatch reads its buffer at
        // execution time, so rewriting one shared table per pass would make every pass see
        // the last pass's data. Each dispatch binds its own offset instead.
        let (passUnits, passOffsets, totalUnits) =
            GpuBinSpec.mergePlan(entries: entries, mergePasses: mergePasses,
                                 chunkSize: sortChunk,
                                 unitSize: LiveConfig.mergeUnitSize())
        if totalUnits > 0 {
            if ref.unitCap < totalUnits {
                let start = DispatchTime.now().uptimeNanoseconds
                let cap = max(totalUnits, max(ref.unitCap * 2, 1))
                guard let buf = device.makeBuffer(
                    length: cap * MemoryLayout<GpuBinMergeUnit>.stride,
                    options: .storageModeShared) else { return nil }
                ref.sortUnits = buf
                ref.unitCap = cap
                alloc += Self.milliseconds(since: start)
            }
            guard let unitBuf = ref.sortUnits else { return nil }
            let unitBase = unitBuf.contents()
            for (pass, uns) in passUnits.enumerated() {
                uns.withUnsafeBytes { raw in
                    if let src = raw.baseAddress {
                        memcpy(unitBase.advanced(by: passOffsets[pass]
                                                    * MemoryLayout<GpuBinMergeUnit>.stride),
                               src, raw.count)
                    }
                }
            }
        }
        // Pass 0 moves tileList→scratch, pass 1 back, and so on.
        let finalTileList: MTLBuffer = (mergePasses == 0 || mergePasses % 2 == 0)
            ? tileList : tileScratch
        return (LiveBinSortPlan(chunks: chunks, passUnits: passUnits,
                                passOffsets: passOffsets, mergePasses: mergePasses,
                                chunkSize: sortChunk, finalTileList: finalTileList),
                alloc)
    }

    /// Scatters every visible segment's tile incidences into the tile list (unordered; the
    /// chunk sort + merges follow). `bp` carries the segment count, the tile box and the
    /// grid dimensions.
    private func encodeBinScatter(ref: LiveBinRefLayer, bp: LiveBinBoxParams,
                                  tileList: MTLBuffer, encoder: MTLComputeCommandEncoder) {
        guard let scatterPipe = liveBinScatterPipeline,
              let ranges = ref.ranges, let starts = ref.starts,
              let heads = ref.heads else { return }
        var params = bp
        encoder.setComputePipelineState(scatterPipe)
        encoder.setBytes(&params, length: MemoryLayout<LiveBinBoxParams>.stride, index: 0)
        encoder.setBuffer(ranges, offset: 0, index: 1)
        encoder.setBuffer(starts, offset: 0, index: 2)
        encoder.setBuffer(heads, offset: 0, index: 3)
        encoder.setBuffer(tileList, offset: 0, index: 4)
        let groups = MTLSize(width: (ref.segCount + 255) / 256, height: 1, depth: 1)
        encoder.dispatchThreadgroups(groups,
                                     threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }

    /// One chunk sort: a 128-lane threadgroup per sortable slice (bitonic network over
    /// threadgroup memory), or the per-thread heapsort under `ART_LIVE_SORT_BITONIC=0`.
    private func encodeBinChunkSort(_ plan: LiveBinSortPlan, ref: LiveBinRefLayer,
                                    tileList: MTLBuffer,
                                    encoder: MTLComputeCommandEncoder) throws {
        guard !plan.chunks.isEmpty else { return }
        guard let chunkBuf = ref.sortChunks else {
            throw MetalRendererError.bufferCreationFailed
        }
        var sp = LiveBinSortParams(unitCount: UInt32(plan.chunks.count),
                                   runSize: UInt32(plan.chunkSize))
        encoder.setBytes(&sp, length: MemoryLayout<LiveBinSortParams>.stride, index: 0)
        encoder.setBuffer(chunkBuf, offset: 0, index: 1)
        encoder.setBuffer(tileList, offset: 0, index: 2)
        if LiveConfig.sortBitonicEnabled(), let bitonicPipe = liveBinChunkSortBitonicPipeline {
            // One 128-lane group per chunk, cooperating over threadgroup memory (the
            // kernel pads ONLY in shared memory; the dispatch and its `tid.x >> 7`
            // decoding must agree).
            encoder.setComputePipelineState(bitonicPipe)
            encoder.dispatchThreadgroups(MTLSize(width: plan.chunks.count, height: 1, depth: 1),
                                         threadsPerThreadgroup: MTLSize(width: 128, height: 1, depth: 1))
        } else if let chunkPipe = liveBinChunkSortPipeline {
            encoder.setComputePipelineState(chunkPipe)
            encoder.dispatchThreadgroups(
                MTLSize(width: (plan.chunks.count + 255) / 256, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        }
    }

    /// One merge pass: copy the whole list into the pass's destination, then merge the
    /// runs that need it over their own (disjoint) ranges. The copy carries every tile
    /// that needs no merge across the ping-pong, so the list is complete after the pass;
    /// a merged range simply overwrites the copy of itself. This is why the merge units
    /// hold only real merges — the copies are one coalesced dispatch, not one per tile.
    private func encodeBinMergePass(_ plan: LiveBinSortPlan, ref: LiveBinRefLayer,
                                    pass: Int, total: Int,
                                    tileList: MTLBuffer, tileScratch: MTLBuffer,
                                    encoder: MTLComputeCommandEncoder) throws {
        // Strict tileList/scratch alternation — src is never dst, so a merge can never
        // clobber its own unread input.
        let srcBuf: MTLBuffer = (pass % 2 == 1) ? tileScratch : tileList
        let dstBuf: MTLBuffer = (pass % 2 == 1) ? tileList : tileScratch
        if total > 0, let copyPipe = liveBinCopyPipeline {
            var count = UInt32(total)
            encoder.setComputePipelineState(copyPipe)
            encoder.setBuffer(srcBuf, offset: 0, index: 0)
            encoder.setBuffer(dstBuf, offset: 0, index: 1)
            encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 2)
            encoder.dispatchThreadgroups(
                MTLSize(width: (total + 255) / 256, height: 1, depth: 1),
                threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
        }
        let uns = plan.passUnits[pass]
        guard !uns.isEmpty else { return }
        guard let mergePipe = liveBinMergePassPipeline,
              let unitBuf = ref.sortUnits else {
            throw MetalRendererError.bufferCreationFailed
        }
        var mp = LiveBinSortParams(unitCount: UInt32(uns.count),
                                   runSize: UInt32(plan.chunkSize << pass))
        encoder.setComputePipelineState(mergePipe)
        encoder.setBytes(&mp, length: MemoryLayout<LiveBinSortParams>.stride, index: 0)
        encoder.setBuffer(unitBuf,
                          offset: plan.passOffsets[pass] * MemoryLayout<GpuBinMergeUnit>.stride,
                          index: 1)
        encoder.setBuffer(srcBuf, offset: 0, index: 2)
        encoder.setBuffer(dstBuf, offset: 0, index: 3)
        encoder.dispatchThreadgroups(
            MTLSize(width: (uns.count + 255) / 256, height: 1, depth: 1),
            threadsPerThreadgroup: MTLSize(width: 256, height: 1, depth: 1))
    }

    /// Chunk sort + every merge pass, in order, into `encoder`.
    private func encodeBinOrder(_ plan: LiveBinSortPlan, ref: LiveBinRefLayer,
                                total: Int, tileList: MTLBuffer, tileScratch: MTLBuffer,
                                encoder: MTLComputeCommandEncoder) throws {
        guard !plan.isTrivial else { return }
        try encodeBinChunkSort(plan, ref: ref, tileList: tileList, encoder: encoder)
        for pass in plan.passUnits.indices {
            try encodeBinMergePass(plan, ref: ref, pass: pass, total: total,
                                   tileList: tileList, tileScratch: tileScratch,
                                   encoder: encoder)
        }
    }

    // MARK: - Mixed-layer GPU binning

    /// GPU-bins every stroke of a mixed layer once for this camera. The result feeds one
    /// per-tile dispatch per stroke run: each run's box is a sub-rectangle of this layer
    /// grid and its dispatch is filtered to the run's reference-stroke range.
    ///
    /// Returns nil when the layer cannot be binned this frame (no Metal pipelines, no
    /// on-canvas strokes, allocation failure) — the caller then falls back to the CPU plan.
    private func prepareMixedGPUBin(cache: LiveRenderCache, position: Int,
                                    camera: CGAffineTransform,
                                    runs: [MixedStrokeRun],
                                    width: Int, height: Int) throws -> MixedGPUBin? {
        guard LiveConfig.gpuBinEnabled() else { return nil }
        guard let fusedPipe = liveBinTransformCountPipeline,
              liveBinScatterPipeline != nil,
              liveBinMergePassPipeline != nil,
              liveBinCopyPipeline != nil,
              liveBinChunkSortBitonicPipeline != nil || liveBinChunkSortPipeline != nil
        else { return nil }
        guard position < cache.layers.count, let device = device, let queue = commandQueue else {
            return nil
        }
        let layer = cache.layers[position]
        guard !layer.needsRebuild else { return nil }
        let liveTile = liveTileSize
        guard liveTile >= 8, width > 0, height > 0, !runs.isEmpty else { return nil }

        let (tilesX, tilesY) = GpuBinSpec.tileGrid(viewportWidth: width, viewportHeight: height,
                                                   tileSize: liveTile)
        let texW = Float(width), texH = Float(height)
        let invTile = 1.0 / Float(liveTile)

        // Reference geometry is uploaded once per document/layer; the per-frame cull and
        // boxes below only touch the CPU-side bounds.
        let ref = try ensureBinRefState(device: device, docID: ObjectIdentifier(cache),
                                        layer: layer)
        guard ref.segCount > 0, ref.strokeCount > 0 else { return nil }

        let mA = Double(camera.a), mB = Double(camera.b)
        let mC = Double(camera.c), mD = Double(camera.d)
        let mTX = Double(camera.tx), mTY = Double(camera.ty)
        var visBytes = [UInt8](repeating: 0, count: ref.strokeCount)
        var outRuns = runs
        var inkMinX = Double.greatestFiniteMagnitude, inkMaxX = -Double.greatestFiniteMagnitude
        var inkMinY = Double.greatestFiniteMagnitude, inkMaxY = -Double.greatestFiniteMagnitude
        var anyBox = false

        for ri in runs.indices {
            var rMinX = Double.greatestFiniteMagnitude, rMaxX = -Double.greatestFiniteMagnitude
            var rMinY = Double.greatestFiniteMagnitude, rMaxY = -Double.greatestFiniteMagnitude
            for id in runs[ri].strokeIDs where id >= 0 && id < ref.strokeCount {
                visBytes[id] = 1
                let bounds = ref.strokeBounds[id]
                let ax0 = Double(bounds.minX) * mA, ax1 = Double(bounds.maxX) * mA
                let cy0 = Double(bounds.minY) * mC, cy1 = Double(bounds.maxY) * mC
                let bx0 = Double(bounds.minX) * mB, bx1 = Double(bounds.maxX) * mB
                let dy0 = Double(bounds.minY) * mD, dy1 = Double(bounds.maxY) * mD
                let x00 = ax0 + cy0 + mTX, x10 = ax1 + cy0 + mTX
                let x11 = ax1 + cy1 + mTX, x01 = ax0 + cy1 + mTX
                let y00 = bx0 + dy0 + mTY, y10 = bx1 + dy0 + mTY
                let y11 = bx1 + dy1 + mTY, y01 = bx0 + dy1 + mTY
                rMinX = min(rMinX, min(min(x00, x10), min(x11, x01)))
                rMaxX = max(rMaxX, max(max(x00, x10), max(x11, x01)))
                rMinY = min(rMinY, min(min(y00, y10), min(y11, y01)))
                rMaxY = max(rMaxY, max(max(y00, y10), max(y11, y01)))
            }
            guard rMinX <= rMaxX, rMinY <= rMaxY,
                  let box = GpuBinSpec.tileBoxForAABB(minX: Float(rMinX), minY: Float(rMinY),
                                                      maxX: Float(rMaxX), maxY: Float(rMaxY),
                                                      texW: texW, texH: texH,
                                                      tilesX: tilesX, tilesY: tilesY,
                                                      invTile: invTile)
            else { continue }
            outRuns[ri].boxMinX = box.minX
            outRuns[ri].boxMinY = box.minY
            outRuns[ri].boxWidth = box.maxX - box.minX + 1
            outRuns[ri].boxHeight = box.maxY - box.minY + 1
            outRuns[ri].boxValid = true
            anyBox = true
            inkMinX = min(inkMinX, rMinX); inkMaxX = max(inkMaxX, rMaxX)
            inkMinY = min(inkMinY, rMinY); inkMaxY = max(inkMaxY, rMaxY)
        }
        guard anyBox,
              let layerBox = GpuBinSpec.tileBoxForAABB(minX: Float(inkMinX), minY: Float(inkMinY),
                                                        maxX: Float(inkMaxX), maxY: Float(inkMaxY),
                                                        texW: texW, texH: texH,
                                                        tilesX: tilesX, tilesY: tilesY,
                                                        invTile: invTile)
        else { return nil }
        let boxW = layerBox.maxX - layerBox.minX + 1
        let boxH = layerBox.maxY - layerBox.minY + 1
        let boxTiles = boxW * boxH
        guard boxTiles > 0 else { return nil }

        visBytes.withUnsafeBytes { raw in
            if let src = raw.baseAddress { memcpy(ref.strokeVisible.contents(), src, raw.count) }
        }

        let force = LiveConfig.forcedCompositeKernel()
        var rawNeedsNoise = false
        for run in runs where run.hasNoise { rawNeedsNoise = true; break }
        let needsNoise = force.applied(to: rawNeedsNoise)
        if needsNoise && noiseTexture == nil { return nil }

        let cpuStart = DispatchTime.now().uptimeNanoseconds
        try ensureBinFrameBuffers(device: device, ref: ref, boxTiles: boxTiles)
        guard let frameSegs = ref.frameSegments, let ranges = ref.ranges,
              let counts = ref.counts, let countsStaging = ref.countsStaging,
              let startsBuf = ref.starts,
              let tileIndexBuf = ref.tileIndex else { return nil }

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
            camTX: Float(camera.tx), camTY: Float(camera.ty),
            noiseLayer: force.isForced ? 1 : 0)
        var bp = LiveBinBoxParams(
            segCount: UInt32(ref.segCount),
            boxMinX: Int32(layerBox.minX), boxMinY: Int32(layerBox.minY),
            boxW: Int32(boxW), boxH: Int32(boxH),
            tilesPerRow: UInt32(tilesX))

        // ── CB1: blit-zero counts, fused transform + count, copy counts back for the CPU
        // prefix. The transform is the only GPU stage whose wait is inside `bin` prep; it
        // is reported as GPU time like the pure path.
        let binThreads = MTLSize(width: 256, height: 1, depth: 1)
        func binGroups(_ n: Int) -> MTLSize {
            MTLSize(width: (n + 255) / 256, height: 1, depth: 1)
        }
        let countBytes = boxTiles * MemoryLayout<UInt32>.size
        guard let cb1 = queue.makeCommandBuffer(),
              let zeroEnc = cb1.makeBlitCommandEncoder() else { return nil }
        zeroEnc.fill(buffer: counts, range: 0..<countBytes, value: 0)
        zeroEnc.endEncoding()
        guard let enc1 = cb1.makeComputeCommandEncoder() else { return nil }
        enc1.setComputePipelineState(fusedPipe)
        enc1.setBytes(&tp, length: MemoryLayout<LiveBinTransformParams>.stride, index: 0)
        enc1.setBuffer(ref.refSegments, offset: 0, index: 1)
        enc1.setBuffer(ref.segStroke, offset: 0, index: 2)
        enc1.setBuffer(ref.strokeVisible, offset: 0, index: 3)
        enc1.setBuffer(frameSegs, offset: 0, index: 4)
        enc1.setBuffer(ranges, offset: 0, index: 5)
        enc1.setBytes(&bp, length: MemoryLayout<LiveBinBoxParams>.stride, index: 6)
        enc1.setBuffer(counts, offset: 0, index: 7)
        enc1.setBuffer(ref.strokeFlags, offset: 0, index: 8)
        enc1.dispatchThreadgroups(binGroups(ref.segCount), threadsPerThreadgroup: binThreads)
        enc1.endEncoding()
        guard let copyEnc = cb1.makeBlitCommandEncoder() else { return nil }
        copyEnc.copy(from: counts, sourceOffset: 0, to: countsStaging, destinationOffset: 0,
                     size: countBytes)
        copyEnc.endEncoding()
        let gpuStart = DispatchTime.now().uptimeNanoseconds
        cb1.commit()
        cb1.waitUntilCompleted()
        if let err = cb1.error { throw err }
        let gpuMillis = Self.milliseconds(since: gpuStart)

        // ── CPU prefix over the tile counts.
        var countsArr = [UInt32](repeating: 0, count: boxTiles)
        countsArr.withUnsafeMutableBytes { raw in
            if let dst = raw.baseAddress { memcpy(dst, countsStaging.contents(), countBytes) }
        }
        let (entries, starts, total) = GpuBinSpec.combine(counts: countsArr)
        liveTiming.inkedTiles += countsArr.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
        liveTiming.gpuMilliseconds += gpuMillis
        guard total > 0 else {
            liveTiming.binMilliseconds += max(0, Self.milliseconds(since: cpuStart) - gpuMillis)
            return nil
        }

        // ── Sort plan + per-frame buffers (same plan as the pure GPU path).
        if ref.tileListCap < total {
            let cap = max(total, ref.tileListCap * 2)
            guard let buf = device.makeBuffer(length: cap * MemoryLayout<UInt32>.size,
                                              options: .storageModePrivate),
                  let scratch = device.makeBuffer(length: cap * MemoryLayout<UInt32>.size,
                                                  options: .storageModePrivate) else {
                return nil
            }
            ref.tileList = buf
            ref.tileScratch = scratch
            ref.tileListCap = cap
        }
        guard let tileList = ref.tileList, let tileScratch = ref.tileScratch else { return nil }

        guard let made = makeBinSortPlan(device: device, ref: ref, entries: entries,
                                         tileList: tileList, tileScratch: tileScratch) else {
            return nil
        }
        entries.withUnsafeBytes { raw in
            if let src = raw.baseAddress {
                memcpy(tileIndexBuf.contents(), src, raw.count)
            }
        }
        starts.withUnsafeBytes { raw in
            if let src = raw.baseAddress {
                memcpy(startsBuf.contents(), src, raw.count)
            }
        }

        liveTiming.binMilliseconds += max(0, Self.milliseconds(since: cpuStart) - gpuMillis)
        // Debug counters: the dispatches cover each visible run's own box.
        var dispatchedTiles = 0
        var strokeCount = 0
        var segmentCount = 0
        for run in outRuns where run.boxValid {
            dispatchedTiles += run.boxWidth * run.boxHeight
            for id in run.strokeIDs where id >= 0 && id < ref.strokeCount {
                strokeCount += 1
                segmentCount += ref.strokeSegCounts[id]
            }
        }
        liveTiming.dispatchedTiles += dispatchedTiles
        liveTiming.sdfEvaluations += total * (liveTile * liveTile)
        liveTiming.strokes += strokeCount
        liveTiming.segments += segmentCount
        return MixedGPUBin(ref: ref, runs: outRuns, bp: bp, total: total,
                           boxTiles: boxTiles,
                           boxMinX: layerBox.minX, boxMinY: layerBox.minY,
                           boxWidth: boxW, boxHeight: boxH,
                           tileList: tileList, tileScratch: tileScratch,
                           sortPlan: made.plan)
    }

    /// One stroke run of a GPU-binned mixed layer: its own tile box, its reference-stroke
    /// range, and the AA or noise per-tile kernel.
    private func encodeGPURun(_ run: MixedStrokeRun, bin: MixedGPUBin,
                              encoder: MTLComputeCommandEncoder) throws {
        guard run.boxValid, let frameSegs = bin.ref.frameSegments,
              let tileIndex = bin.ref.tileIndex,
              let first = run.strokeIDs.first, let last = run.strokeIDs.last else { return }
        guard let device = device,
              ensureEmptyGroupBuffers(device: device, tileCount: bin.boxTiles),
              let emptyHeader = liveEmptyGroupHeader,
              let emptyGroups = liveEmptyStrokeGroups else {
            throw MetalRendererError.bufferCreationFailed
        }
        let base = (run.boxMinY - bin.boxMinY) * bin.boxWidth
                 + (run.boxMinX - bin.boxMinX)
        try encodePerTileBuffers(segBuffer: frameSegs, segOffset: 0,
                                 strokeOfSegBuffer: bin.ref.segStroke, strokeOfSegOffset: 0,
                                 tileStartCountBuffer: tileIndex, tileStartCountOffset: 0,
                                 tileListBuffer: bin.sortPlan.finalTileList, tileListOffset: 0,
                                 strokeColorBuffer: bin.ref.strokeColors, strokeColorOffset: 0,
                                 strokeFlagsBuffer: bin.ref.strokeFlags, strokeFlagsOffset: 0,
                                 groupHeaderBuffer: emptyHeader,
                                 strokeGroupsBuffer: emptyGroups,
                                 boxMinX: run.boxMinX, boxMinY: run.boxMinY,
                                 boxWidth: run.boxWidth, boxHeight: run.boxHeight,
                                 containsNoise: LiveConfig.forcedCompositeKernel().applied(to: run.hasNoise),
                                 tileGridStride: bin.boxWidth,
                                 tileArrayBase: base,
                                 strokeLo: first, strokeHi: last,
                                 encoder: encoder)
    }

    /// Stages one paste op into the arena and bins it into its destination tile box.
    /// Returns nil when nothing lands on the canvas.
    private func plan(paste segments: [GPUSplineSegment],
                      color: SIMD4<Float>, isEraser: Bool, isMarker: Bool,
                      meta: PasteLayerMeta, masks: [PasteMask],
                      sourceToDestination: CGAffineTransform,
                      isMerge: Bool, mergeID: UInt64,
                      width: Int, height: Int) throws -> LivePasteBin? {
        guard !segments.isEmpty else { return nil }
        let boxed = buildSegmentTileIndicesBoxed(segments: segments,
                                                 textureWidth: width, textureHeight: height,
                                                 tileSize: tileSize,
                                                 isMarker: isMarker,
                                                 transform: sourceToDestination)
        guard !boxed.tileList.isEmpty else { return nil }

        var bin = LivePasteBin()
        bin.segmentCount = segments.count
        bin.color = color
        bin.isEraser = isEraser
        bin.isMarker = isMarker
        bin.hasNoise = segments.contains { $0.noiseSeed != 0 }
        bin.isMerge = isMerge
        bin.mergeID = mergeID
        bin.meta = meta
        bin.minTileX = boxed.minTileX
        bin.minTileY = boxed.minTileY
        bin.boxWidth = boxed.boxWidth
        bin.boxHeight = boxed.boxHeight
        bin.tileBoxCount = boxed.tileIndices.count
        bin.tileListCount = boxed.tileList.count
        bin.maskCount = masks.count

        func place(_ byteCount: Int) -> Int {
            liveStagingUsed = Self.alignUp(liveStagingUsed, Self.liveArenaAlignment)
            let offset = liveStagingUsed
            liveStagingUsed += byteCount
            return offset
        }
        bin.segmentOffset = place(MemoryLayout<GPUSplineSegment>.stride * segments.count)
        bin.tileIndexOffset = place(MemoryLayout<TileIndex>.stride * boxed.tileIndices.count)
        bin.tileListOffset = place(MemoryLayout<UInt32>.stride * boxed.tileList.count)
        // The kernel only dereferences `maskCount` slots; bind one zeroed stand-in
        // when there are none (mirrors the static path's max(1, count) buffer).
        bin.maskOffset = place(MemoryLayout<PasteMask>.stride * max(masks.count, 1))

        guard let base = staging(needed: liveStagingUsed) else {
            throw MetalRendererError.bufferCreationFailed
        }
        func write<T>(_ array: [T], at offset: Int) {
            array.withUnsafeBytes { raw in
                if let src = raw.baseAddress {
                    (base + offset).copyMemory(from: src, byteCount: raw.count)
                }
            }
        }
        write(segments, at: bin.segmentOffset)
        write(boxed.tileIndices, at: bin.tileIndexOffset)
        write(boxed.tileList, at: bin.tileListOffset)
        write(masks, at: bin.maskOffset)

        liveTiming.dispatchedTiles += boxed.boxWidth * boxed.boxHeight
        liveTiming.inkedTiles += boxed.tileIndices.reduce(0) { $0 + ($1.count > 0 ? 1 : 0) }
        liveTiming.sdfEvaluations += boxed.tileList.count * (tileSize * tileSize)
        liveTiming.segments += segments.count
        return bin
    }

    /// Clears `texture` inside the caller's encoder (same kernel/thread shape as
    /// `clearTexture`, no separate command buffer or wait).
    private func encodeClear(_ texture: MTLTexture, encoder: MTLComputeCommandEncoder) {
        guard let clearPipeline else { return }
        encoder.setComputePipelineState(clearPipeline)
        encoder.setTexture(texture, index: 0)
        let tg = MTLSize(width: 8, height: 8, depth: 1)
        encoder.dispatchThreadgroups(
            MTLSize(width: (texture.width + 7) / 8, height: (texture.height + 7) / 8, depth: 1),
            threadsPerThreadgroup: tg)
    }

    /// Composites the open merge fragment over the layer target, in-encoder.
    private func encodeMergeFlush(opacity: Float, encoder: MTLComputeCommandEncoder) throws {
        guard let fragment = mergeFragmentTexture,
              let target = gpuRenderTarget,
              let pipeline = mergeFlattenPipeline else { return }
        var alpha = opacity
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(fragment, index: 0)
        encoder.setTexture(target, index: 1)
        encoder.setBytes(&alpha, length: MemoryLayout<Float>.stride, index: 0)
        let tg = MTLSize(width: 8, height: 8, depth: 1)
        encoder.dispatchThreadgroups(
            MTLSize(width: (target.width + 7) / 8, height: (target.height + 7) / 8, depth: 1),
            threadsPerThreadgroup: tg)
    }

    /// Encodes one boxed paste dispatch.
    private func encode(paste bin: LivePasteBin, width: Int, height: Int,
                        target: MTLTexture, alphaOverride: Float?,
                        encoder: MTLComputeCommandEncoder) throws {
        guard let arena = liveArena else { throw MetalRendererError.bufferCreationFailed }

        var params = Params(
            textureWidth: UInt32(width),
            textureHeight: UInt32(height),
            tileSize: UInt32(tileSize),
            tilesPerRow: (UInt32(width) + UInt32(tileSize) - 1) / UInt32(tileSize),
            stampCount: UInt32(bin.segmentCount),
            penColor: bin.color,
            noiseScale: 0.4,
            noiseOffsetX: Float(self.liveNoiseOffset.x),
            noiseOffsetY: Float(self.liveNoiseOffset.y),
            isEraser: bin.isEraser,
            isMarker: bin.isMarker,
            debugSegmentColors: LiveConfig.debugSegmentColors())
        if let alphaOverride { params.penColor.w = alphaOverride }

        if bin.hasNoise, let pipeline = segmentPasteLayerNoiseCompositePipeline,
           let noise = noiseTexture {
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(noise, index: 1)
            if let sampler = linearSampler { encoder.setSamplerState(sampler, index: 0) }
        } else if let pipeline = segmentPasteLayerAACompositePipeline {
            encoder.setComputePipelineState(pipeline)
        } else {
            throw MetalRendererError.pipelineMissing("segmentPasteLayerAACompositeKernel")
        }

        var meta = bin.meta
        var box = PasteBoxParams(originTileX: UInt32(bin.minTileX),
                                 originTileY: UInt32(bin.minTileY),
                                 boxTilesPerRow: UInt32(bin.boxWidth))
        encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
        encoder.setBuffer(arena, offset: bin.segmentOffset, index: 1)
        encoder.setBuffer(arena, offset: bin.tileIndexOffset, index: 2)
        encoder.setBuffer(arena, offset: bin.tileListOffset, index: 3)
        encoder.setBytes(&meta, length: MemoryLayout<PasteLayerMeta>.stride, index: 4)
        encoder.setBuffer(arena, offset: bin.maskOffset, index: 5)
        encoder.setBytes(&box, length: MemoryLayout<PasteBoxParams>.stride, index: 6)
        encoder.setTexture(target, index: 0)

        let tg = MTLSize(width: 8, height: 8, depth: 1)
        encoder.dispatchThreadgroups(
            MTLSize(width: (bin.boxWidth * tileSize + 7) / 8,
                    height: (bin.boxHeight * tileSize + 7) / 8,
                    depth: 1),
            threadsPerThreadgroup: tg)
    }

    /// A layer is per-tile-able unless it has cut ops (ordering) or a marker stroke together
    /// with a noisy segment (the noise-capable per-tile kernel has no chisel SDF). Noise
    /// alone is allowed: such layers use the noise per-tile kernel, clean ones the AA one.
    /// Pure logic lives in `LivePerTileEligibility` (Linux-tested).
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
        var segmentIsMarker: [Bool] = []
        var strokeColors: [SIMD4<Float>] = []
        var strokeFlags: [UInt32] = []
        let liveTile = liveTileSize
        let force = LiveConfig.forcedCompositeKernel()
        for op in layerOps {
            if case .stroke(let segs, let color, let isEraser, let isMarker, _) = op {
                let strokeIndex = UInt32(strokeColors.count)
                strokeColors.append(color)
                let rawHasNoise = segs.contains { $0.noiseSeed != 0 }
                // Forced noise renders clean strokes through the noise coverage too, so
                // both per-tile kernels see the same geometry. Forced AA needs no flag
                // change (the AA kernel ignores bit1).
                let hasNoise = force == .noise ? true : rawHasNoise
                strokeFlags.append(LivePerTileEligibility.strokeFlags(isEraser: isEraser,
                                                                      hasNoise: hasNoise,
                                                                      isMarker: isMarker))
                segments.append(contentsOf: segs)
                strokeOfSegment.append(contentsOf: Array(repeating: strokeIndex, count: segs.count))
                segmentIsMarker.append(contentsOf: Array(repeating: isMarker, count: segs.count))
            }
        }

        var plan = PerTilePlan()
        plan.strokeCount = strokeColors.count
        plan.segCount = segments.count
        plan.strokeOfSegCount = strokeOfSegment.count
        let rawNeedsNoise = layerOps.contains {
            if case .stroke(let segs, _, _, _, _) = $0 { return segs.contains { $0.noiseSeed != 0 } }
            return false
        }
        plan.containsNoise = force.applied(to: rawNeedsNoise)

        let boxed = buildSegmentTileIndicesBoxed(segments: segments,
                                                 textureWidth: width, textureHeight: height,
                                                 tileSize: liveTile, isMarker: false,
                                                 markerFlags: segmentIsMarker,
                                                 transform: nil,
                                                 forceNoiseMargin: force.isForced)
        plan.tileListCount = boxed.tileList.count
        plan.tileBoxCount = boxed.tileIndices.count
        plan.minTileX = boxed.minTileX
        plan.minTileY = boxed.minTileY
        plan.boxWidth = boxed.boxWidth
        plan.boxHeight = boxed.boxHeight

        if boxed.tileList.isEmpty {
            plan.empty = true
            return plan
        }
        plan.empty = false

        if liveStagingUsed > 0, staging(needed: liveStagingUsed) == nil {
            throw MetalRendererError.bufferCreationFailed
        }
        // Append to the arena: a mixed layer plans several stroke runs into one buffer.
        var cursor = liveStagingUsed
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
    /// Count-0 stand-in group buffers for dispatches without a stroke-group table.
    /// The composite kernels index the header by box-local tile UNCONDITIONALLY
    /// (`strokeGroupTiles[localTile]`, even with count 0), so the stand-in header must
    /// cover the caller's whole tile grid — grown on demand and memset (Metal buffer
    /// contents are not guaranteed zeroed).
    private func ensureEmptyGroupBuffers(device: MTLDevice, tileCount: Int) -> Bool {
        let tiles = max(tileCount, 1)
        if liveEmptyGroupHeader == nil || liveEmptyGroupHeaderCap < tiles {
            let cap = max(tiles, liveEmptyGroupHeaderCap * 2, 64)
            guard let hd = device.makeBuffer(
                length: cap * 2 * MemoryLayout<UInt32>.size,
                options: .storageModeShared) else {
                return false
            }
            memset(hd.contents(), 0, hd.length)
            liveEmptyGroupHeader = hd
            liveEmptyGroupHeaderCap = cap
        }
        if liveEmptyStrokeGroups == nil {
            // The entries stand-in is never dereferenced while counts are 0 (the
            // cursor loop short-circuits on the count), so one zeroed slot suffices.
            guard let gr = device.makeBuffer(length: MemoryLayout<GpuBinStrokeBlock>.stride,
                                             options: .storageModeShared) else {
                return false
            }
            memset(gr.contents(), 0, gr.length)
            liveEmptyStrokeGroups = gr
        }
        return true
    }

    private func encodePerTile(plan: PerTilePlan, encoder: MTLComputeCommandEncoder) throws {
        guard let arena = liveArena else { throw MetalRendererError.bufferCreationFailed }
        // The static plan path has no stroke-group table: bind the count-0 stand-in so
        // the kernels keep their exact pre-table behaviour.
        guard let device = device,
              ensureEmptyGroupBuffers(device: device, tileCount: plan.boxWidth * plan.boxHeight),
              let emptyHeader = liveEmptyGroupHeader,
              let emptyGroups = liveEmptyStrokeGroups else {
            throw MetalRendererError.bufferCreationFailed
        }
        try encodePerTileBuffers(segBuffer: arena, segOffset: plan.segOffset,
                                 strokeOfSegBuffer: arena, strokeOfSegOffset: plan.strokeOfSegOffset,
                                 tileStartCountBuffer: arena, tileStartCountOffset: plan.tileStartCountOffset,
                                 tileListBuffer: arena, tileListOffset: plan.tileListOffset,
                                 strokeColorBuffer: arena, strokeColorOffset: plan.strokeColorOffset,
                                 strokeFlagsBuffer: arena, strokeFlagsOffset: plan.strokeFlagsOffset,
                                 groupHeaderBuffer: emptyHeader,
                                 strokeGroupsBuffer: emptyGroups,
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
                                      groupHeaderBuffer: MTLBuffer,
                                      strokeGroupsBuffer: MTLBuffer,
                                      boxMinX: Int, boxMinY: Int,
                                      boxWidth: Int, boxHeight: Int,
                                      containsNoise: Bool,
                                      tileGridStride: Int? = nil,
                                      tileArrayBase: Int = 0,
                                      strokeLo: Int = 0,
                                      strokeHi: Int = Int(UInt32.max),
                                      encoder: MTLComputeCommandEncoder) throws {
        let liveTile = liveTileSize
        guard liveTile > 0, boxWidth > 0, boxHeight > 0 else {
            throw MetalRendererError.invalidTileData
        }
        var params = PerTileParams(tileOriginX: UInt32(boxMinX),
                                   tileOriginY: UInt32(boxMinY),
                                   boxTilesPerRow: UInt32(boxWidth),
                                   boxTilesPerCol: UInt32(boxHeight),
                                   tileSize: UInt32(liveTile),
                                   ablate: UInt32(LiveConfig.ablate()),
                                   flags: (LiveConfig.saturationSkipEnabled() ? 1 : 0)
                                        | (LiveConfig.debugSegmentColors() ? 2 : 0),
                                   tileGridStride: UInt32(tileGridStride ?? boxWidth),
                                   tileArrayBase: UInt32(tileArrayBase),
                                   strokeLo: UInt32(strokeLo),
                                   strokeHi: UInt32(strokeHi))
        params.noiseOffsetX = Float(self.liveNoiseOffset.x)
        params.noiseOffsetY = Float(self.liveNoiseOffset.y)
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
            // Stroke-group table (pruning): header tile → [start, count) into `groups`
            // (count 0 = no table for this dispatch → direct segment walk, exact).
            encoder.setBuffer(groupHeaderBuffer, offset: 0, index: 7)
            encoder.setBuffer(strokeGroupsBuffer, offset: 0, index: 8)
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
            // Stroke-group table (pruning): header tile → [start, count) into `groups`
            // (count 0 = no table for this dispatch → direct segment walk, exact).
            encoder.setBuffer(groupHeaderBuffer, offset: 0, index: 7)
            encoder.setBuffer(strokeGroupsBuffer, offset: 0, index: 8)
            encoder.setTexture(gpuRenderTarget, index: 0)
        }
        let threadDim = perTileThreads
        let groupsPerTileX = (liveTile + Int(threadDim.width) - 1) / Int(threadDim.width)
        let groupsPerTileY = (liveTile + Int(threadDim.height) - 1) / Int(threadDim.height)
        let groups = MTLSize(width: boxWidth * groupsPerTileX,
                             height: boxHeight * groupsPerTileY,
                             depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadDim)
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
        guard let compositePipeline = liveCompositeLayerPipeline else { return false }
        // One binning path for every zoom level: fused transform+count (segment-parallel),
        // atomic scatter (segment-parallel), chunked sort + merge passes (bounded work per
        // thread — no per-tile sort to go latency-bound when zoomed out). A metallib
        // predating any of them (or ART_LIVE_GPUBIN=0) falls back to CPU below.
        guard let fusedPipe = liveBinTransformCountPipeline,
              liveBinScatterPipeline != nil,
              liveBinMergePassPipeline != nil,
              liveBinCopyPipeline != nil,
              liveBinChunkSortBitonicPipeline != nil || liveBinChunkSortPipeline != nil
        else { return false }
        guard position < cache.layers.count, let device = device, let queue = commandQueue else {
            return false
        }
        let layer = cache.layers[position]
        guard !layer.needsRebuild else { return false }
        // Any cut op forces the CPU path: cut metas are remapped per frame on the CPU and
        // must interleave with strokes in document order. Precomputed at cache build.
        guard !layer.hasCut else { return false }
        // Pastes need the mixed path too (order + masks); the GPU binner only knows
        // plain strokes.
        guard !layer.hasPaste else { return false }
        let liveTile = liveTileSize
        guard liveTile >= 8, width > 0, height > 0 else { return false }
        let (tilesX, tilesY) = GpuBinSpec.tileGrid(viewportWidth: width, viewportHeight: height,
                                                   tileSize: liveTile)
        let texW = Float(width), texH = Float(height)
        let invTile = 1.0 / Float(liveTile)

        // Cull strokes on the CPU via reference bounds (4-point transform each — the same
        // test `deviceOps` applies) and accumulate the layer tile box.
        // A *visible* marker forces the CPU/per-stroke path only when the layer also has a
        // noisy stroke (the noise kernel owns the whole layer then and has no marker SDF).
        // Same radius factor formula as `deviceOps` — passed in, never recomputed on GPU.
        // Computed before the cull loop (the stroke boxes padding needs it too).
        let scaleX = sqrt(camera.a * camera.a + camera.c * camera.c)
        let scaleY = sqrt(camera.b * camera.b + camera.d * camera.d)
        let radiusFactor = Float((scaleX + scaleY) / 2.0)
        // Reference state (uploaded once per document/layer; a fresh process pays the
        // whole cache upload here, so it must NOT sit inside the `bin` timing window
        // — otherwise CLI one-shot runs report a too-slow steady-state bin cost).
        let ref = try ensureBinRefState(device: device, docID: ObjectIdentifier(cache),
                                        layer: layer)
        var cpuStart = DispatchTime.now().uptimeNanoseconds
        // Per-stage CPU attribution, computed only under ART_LIVE_BINTIME (the totals are
        // always accumulated; this only splits the `bin` window into its parts so a Mac
        // run can say which one to attack).
        let cpuStageTiming = LiveConfig.binStageTimingEnabled()
        var tCull = 0.0, tPrep = 0.0, tPrefix = 0.0, tTable = 0.0, tPlan = 0.0
        var visStrokeIDs: [Int] = []
        let strokeBounds = layer.strokeBounds
        let strokeIsMarker = layer.strokeIsMarker
        visStrokeIDs.reserveCapacity(strokeBounds.count)
        var hasVisibleMarker = false
        // Cull + layer box in one corner pass. This used to call `LiveRenderCache.intersects`
        // (four `CGPoint.applying` C calls) and then transform the same four corners again
        // for the tile AABB — ~1.0 ms per frame on kaos' 2214 strokes. The math below is
        // exactly CGAffineTransform's (`x·a + y·c + tx`, `x·b + y·d + ty`), so the test and
        // the resulting tile box are identical, including the strict inequalities.
        //
        // The box is the tile AABB of the *union* of the visible strokes' ink boxes, not a
        // per-stroke union of tile boxes: floor/ceil are monotone, so for any tile size
        // `⋃_i box_i == box(⋃_i aabb_i)` — the same tiles from one `floor`/`ceil` pair for
        // the whole layer instead of one per stroke.
        let viewportEmpty = viewport.isEmpty
        let vMinX = Double(viewport.minX), vMaxX = Double(viewport.maxX)
        let vMinY = Double(viewport.minY), vMaxY = Double(viewport.maxY)
        let mA = Double(camera.a), mB = Double(camera.b)
        let mC = Double(camera.c), mD = Double(camera.d)
        let mTX = Double(camera.tx), mTY = Double(camera.ty)
        var inkMinX = Double.greatestFiniteMagnitude, inkMaxX = -Double.greatestFiniteMagnitude
        var inkMinY = Double.greatestFiniteMagnitude, inkMaxY = -Double.greatestFiniteMagnitude
        for strokeID in strokeBounds.indices {
            let bounds = strokeBounds[strokeID]
            let ax0 = Double(bounds.minX) * mA, ax1 = Double(bounds.maxX) * mA
            let cy0 = Double(bounds.minY) * mC, cy1 = Double(bounds.maxY) * mC
            let bx0 = Double(bounds.minX) * mB, bx1 = Double(bounds.maxX) * mB
            let dy0 = Double(bounds.minY) * mD, dy1 = Double(bounds.maxY) * mD
            let x00 = ax0 + cy0 + mTX, x10 = ax1 + cy0 + mTX
            let x11 = ax1 + cy1 + mTX, x01 = ax0 + cy1 + mTX
            let y00 = bx0 + dy0 + mTY, y10 = bx1 + dy0 + mTY
            let y11 = bx1 + dy1 + mTY, y01 = bx0 + dy1 + mTY
            let minX = min(min(x00, x10), min(x11, x01))
            let maxX = max(max(x00, x10), max(x11, x01))
            let minY = min(min(y00, y10), min(y11, y01))
            let maxY = max(max(y00, y10), max(y11, y01))
            // Empty boxes are visible unconditionally — the contract `intersects` had.
            let visible = bounds.isEmpty || viewportEmpty
                || (maxX >= vMinX && minX <= vMaxX && maxY >= vMinY && minY <= vMaxY)
            guard visible else { continue }
            if strokeIsMarker[strokeID] { hasVisibleMarker = true }
            visStrokeIDs.append(strokeID)
            inkMinX = min(inkMinX, minX); inkMaxX = max(inkMaxX, maxX)
            inkMinY = min(inkMinY, minY); inkMaxY = max(inkMaxY, maxY)
        }
        let layerBox = GpuBinSpec.tileBoxForAABB(minX: Float(inkMinX), minY: Float(inkMinY),
                                                 maxX: Float(inkMaxX), maxY: Float(inkMaxY),
                                                 texW: texW, texH: texH,
                                                 tilesX: tilesX, tilesY: tilesY,
                                                 invTile: invTile)
        if !visStrokeIDs.isEmpty && layerBox == nil { return false }
        if visStrokeIDs.isEmpty {
            liveTiming.culledStrokes += cache.strokeCount(at: position)
            liveTiming.binMilliseconds += Self.milliseconds(since: cpuStart)
            return true     // nothing rasterised; compositing emptiness is identity
        }
        guard let box = layerBox else { return false }
        let boxW = box.maxX - box.minX + 1, boxH = box.maxY - box.minY + 1
        let boxTiles = boxW * boxH
        guard boxTiles > 0 else { return false }
        let cullMilliseconds = Self.milliseconds(since: cpuStart)
        liveTiming.binMilliseconds += cullMilliseconds
        if cpuStageTiming { tCull = cullMilliseconds }

        // Reference state is ensured above the timing window; here only per-frame data
        // prep follows.
        let force = LiveConfig.forcedCompositeKernel()
        var rawNeedsNoise = false
        for id in visStrokeIDs where ref.strokeHasNoise[id] { rawNeedsNoise = true; break }
        let needsNoise = force.applied(to: rawNeedsNoise)
        // A marker needs the chisel SDF, which only the AA per-tile kernel implements; the
        // noise twin has no marker branch, so both together stay on the CPU/per-stroke path.
        if hasVisibleMarker && needsNoise { return false }
        if needsNoise && noiseTexture == nil { return false }
        if needsNoise && livePerTileNoiseCompositePipeline == nil { return false }
        if !needsNoise && livePerTileAACompositePipeline == nil { return false }
        // Frame buffers are sized once (the segment arena alone is ~20 MB on a big
        // document): cold-start allocation, kept out of `bin` and reported as `alloc`.
        let aFrame = DispatchTime.now().uptimeNanoseconds
        try ensureBinFrameBuffers(device: device, ref: ref, boxTiles: boxTiles)
        liveTiming.allocMilliseconds += Self.milliseconds(since: aFrame)
        cpuStart = DispatchTime.now().uptimeNanoseconds
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

        // Same radius factor formula as `deviceOps` — computed above the cull loop
        // (reused by the stroke-box padding and the GPU transform params below).
        var tp = LiveBinTransformParams(
            segCount: UInt32(ref.segCount),
            tilesPerRow: UInt32(tilesX), tilesPerCol: UInt32(tilesY),
            tileSize: UInt32(liveTile),
            texW: texW, texH: texH, invTile: invTile, radiusFactor: radiusFactor,
            camA: Float(camera.a), camB: Float(camera.b),
            camC: Float(camera.c), camD: Float(camera.d),
            camTX: Float(camera.tx), camTY: Float(camera.ty),
            noiseLayer: force.isForced ? 1 : 0)
        var bp = LiveBinBoxParams(
            segCount: UInt32(ref.segCount),
            boxMinX: Int32(box.minX), boxMinY: Int32(box.minY),
            boxW: Int32(boxW), boxH: Int32(boxH),
            tilesPerRow: UInt32(tilesX))
        let prepMilliseconds = Self.milliseconds(since: cpuStart)
        if cpuStageTiming { tPrep = prepMilliseconds }
        liveTiming.binMilliseconds += prepMilliseconds

        try ensureRenderTargets(width: width, height: height)
        try clearTexture(gpuRenderTarget!)

        // ── CB1: blit-zero counts, fused transform+count, copy counts to staging for
        // the CPU prefix. Encoders in one command buffer retire in order. One wait;
        // captured for BINTIME.
        let binThreads = MTLSize(width: 256, height: 1, depth: 1)
        func binGroups(_ n: Int) -> MTLSize {
            MTLSize(width: (n + 255) / 256, height: 1, depth: 1)
        }
        let countBytes = boxTiles * MemoryLayout<UInt32>.size
        var clock = DispatchTime.now().uptimeNanoseconds
        var tXform = 0.0
        guard let cb1 = queue.makeCommandBuffer(),
              let zeroEnc = cb1.makeBlitCommandEncoder() else { return false }
        zeroEnc.fill(buffer: counts, range: 0..<countBytes, value: 0)
        zeroEnc.endEncoding()
        guard let enc1 = cb1.makeComputeCommandEncoder() else { return false }
        enc1.setComputePipelineState(fusedPipe)
        enc1.setBytes(&tp, length: MemoryLayout<LiveBinTransformParams>.stride, index: 0)
        enc1.setBuffer(ref.refSegments, offset: 0, index: 1)
        enc1.setBuffer(ref.segStroke, offset: 0, index: 2)
        enc1.setBuffer(ref.strokeVisible, offset: 0, index: 3)
        enc1.setBuffer(frameSegs, offset: 0, index: 4)
        enc1.setBuffer(ranges, offset: 0, index: 5)
        enc1.setBytes(&bp, length: MemoryLayout<LiveBinBoxParams>.stride, index: 6)
        enc1.setBuffer(counts, offset: 0, index: 7)
        // Per-stroke flags (bit2 = marker) so a chisel stroke's tile range gets the 4·r
        // pad instead of the 1.4·r one — the same pad `SegmentPadding` uses on the CPU.
        enc1.setBuffer(ref.strokeFlags, offset: 0, index: 8)
        enc1.dispatchThreadgroups(binGroups(ref.segCount), threadsPerThreadgroup: binThreads)
        enc1.endEncoding()
        guard let copyEnc = cb1.makeBlitCommandEncoder() else { return false }
        copyEnc.copy(from: counts, sourceOffset: 0,
                     to: staging, destinationOffset: 0, size: countBytes)
        copyEnc.endEncoding()
        clock = DispatchTime.now().uptimeNanoseconds
        cb1.commit()
        cb1.waitUntilCompleted()
        tXform = Self.milliseconds(since: clock)
        liveTiming.gpuMilliseconds += tXform
        if let err = cb1.error { throw err }

        // ── CPU prefix over the tile counts (one tile grid, trivial) → tile table.
        let prefixStart = DispatchTime.now().uptimeNanoseconds
        // Cold-start Metal buffer growth is not per-frame CPU planning: accumulate it in
        // `alloc` and subtract it from `bin`, so a one-shot CLI run cannot report the
        // first frame's allocations as steady-state bin cost (warm frames allocate
        // nothing). The splat tail is GPU time and is subtracted from `bin` the same way
        // (it is already inside `gpu`).
        var allocWindow = 0.0
        var countsArr = [UInt32](repeating: 0, count: boxTiles)
        countsArr.withUnsafeMutableBytes { raw in
            if let dst = raw.baseAddress {
                memcpy(dst, staging.contents(), countBytes)
            }
        }
        let (entries, starts, total) = GpuBinSpec.combine(counts: countsArr)
        liveTiming.inkedTiles += countsArr.reduce(0) { $0 + ($1 > 0 ? 1 : 0) }
        var cpuMark = DispatchTime.now().uptimeNanoseconds
        if cpuStageTiming { tPrefix = Self.milliseconds(since: prefixStart) }
        if total == 0 {
            // Visible strokes, but none reaches a tile (all ranges empty): mirrors the CPU
            // path's per-stroke culling. Compositing the cleared target is identity.
            liveTiming.culledStrokes += visStrokeIDs.count
            liveTiming.binMilliseconds += Self.milliseconds(since: prefixStart)
            return true
        }

        // ── Splat fast path (small-stamp views): a segment-parallel composite that
        // replaces the whole scatter/sort/tile-walk tail. Exact by construction — for
        // radiusFactor ≤ 1 each segment's prune disk is a subset of its binning box, so
        // iterating the disk covers precisely the walk's contributing set; the per-
        // (pixel, stroke) atomicMax plus the in-order per-batch replay reproduce the
        // walk bit-for-bit. See SPLAT-DESIGN.md for the proof and the ordering.
        let splatBatch = LiveConfig.splatBatchSlots()
        let splatBoxPixW = boxW * liveTile
        let splatBoxPixH = boxH * liveTile
        let splatPixels = splatBoxPixW * splatBoxPixH
        // Cost model, not just eligibility: both paths are exact, but they are only
        // both *fast* in different regimes. The walk costs Σ(segment, tile) × tileArea
        // (the `sdf` counter); the splat costs boxPixels × visibleStrokes slot reads
        // (~2× more expensive each). At moderate zoom the box is still large while the
        // walk is already cheap, so the splat must lose there — measured:
        // complex.art @ 0.3 went 3.5 ms (walk) → 16.1 ms (splat) before this gate.
        let splatCost = LiveConfig.splatCostRatio()
        // The splat kernel stamps the plain capsule/spline coverage; a chisel marker needs
        // the marker SDF, which only the walk implements. Rare, so the walk stays exact.
        let splatHasMarker = visStrokeIDs.contains {
            $0 >= 0 && $0 < ref.strokeIsMarker.count && ref.strokeIsMarker[$0]
        }
        let splatFits = !splatHasMarker
            && !force.isForced
            // The splat keeps one colour per stroke; debug mode needs one per segment.
            && !LiveConfig.debugSegmentColors()
            && LiveConfig.splatEnabled()
            && radiusFactor <= LiveConfig.splatMaxRadiusFactor()
            && splatPixels * splatBatch <= LiveConfig.splatSlotBudget()
        let splatWins = splatFits && GpuBinSpec.splatCheaperThanWalk(
            entries: total, tileSize: liveTile,
            boxPixels: splatPixels, visibleStrokes: visStrokeIDs.count,
            batchSlots: splatBatch, costRatio: splatCost)
        if LiveConfig.binStageTimingEnabled() && splatFits && !splatWins {
            print(String(format: "livebin layer %d: splat declined — walk %.1fM px-ops vs splat %.1fM slots ×%.1f; using the walk",
                         position,
                         GpuBinSpec.walkPixelOps(entries: total, tileSize: liveTile) / 1e6,
                         GpuBinSpec.splatSlotOps(boxPixels: splatPixels,
                                                 visibleStrokes: visStrokeIDs.count,
                                                 batchSlots: splatBatch) / 1e6,
                         splatCost))
        }
        var splatBuffered = false
        if splatWins, liveSplatPipeline != nil, liveSplatCompositePipeline != nil,
           liveSplatWritePipeline != nil, gpuRenderTarget != nil, liveCanvasTexture != nil {
            let aSplat = DispatchTime.now().uptimeNanoseconds
            splatBuffered = ensureSplatBuffers(device: device, ref: ref, pixels: splatPixels,
                                               slots: splatPixels * splatBatch)
            allocWindow += Self.milliseconds(since: aSplat)
        }
        if splatWins, splatBuffered,
           let splatPipe = liveSplatPipeline,
           let splatCompPipe = liveSplatCompositePipeline,
           let splatWritePipe = liveSplatWritePipeline,
           let layerTex = gpuRenderTarget,
           let canvas = liveCanvasTexture,
           let noiseBind = splatNoiseBinding(),
           let splatMax = ref.splatMax, let splatAcc = ref.splatAcc,
           let visOrd = ref.visOrd, let visIDs = ref.visStrokeIDsBuf {
            // Per-frame uploads: per-stroke visible ordinal, and ordinal → stroke id.
            let ordBytes = ref.strokeCount * MemoryLayout<UInt32>.size
            var ords = [UInt32](repeating: 0xFFFF_FFFF, count: ref.strokeCount)
            for (o, id) in visStrokeIDs.enumerated() { ords[id] = UInt32(o) }
            if ordBytes > 0 {
                ords.withUnsafeBytes { raw in
                    if let src = raw.baseAddress { memcpy(visOrd.contents(), src, ordBytes) }
                }
            }
            var ids = visStrokeIDs.map { UInt32($0) }
            if ids.isEmpty { ids = [0] }
            ids.withUnsafeBytes { raw in
                if let src = raw.baseAddress { memcpy(visIDs.contents(), src, raw.count) }
            }
            var sp = LiveSplatParams(
                segCount: UInt32(ref.segCount), slotsPerPixel: UInt32(splatBatch),
                batchStart: 0, batchCount: 0, tileSize: UInt32(liveTile),
                boxTilesPerRow: UInt32(boxW), boxTilesPerCol: UInt32(boxH),
                flags: needsNoise ? 1 : 0,
                noiseOffsetX: Float(self.liveNoiseOffset.x),
                noiseOffsetY: Float(self.liveNoiseOffset.y),
                originPxX: Int32(box.minX * liveTile), originPxY: Int32(box.minY * liveTile),
                boxPixW: Int32(splatBoxPixW), boxPixH: Int32(splatBoxPixH))
            let visCount = visStrokeIDs.count
            let splatBatches = (visCount + splatBatch - 1) / splatBatch
            let splatThreads = MTLSize(width: 16, height: 16, depth: 1)
            let splatGroups = MTLSize(width: (splatBoxPixW + 15) / 16,
                                      height: (splatBoxPixH + 15) / 16, depth: 1)
            let slotBytes = splatPixels * splatBatch * MemoryLayout<UInt32>.size
            let accBytes = splatPixels * MemoryLayout<SIMD4<Float>>.stride
            let splatStart = DispatchTime.now().uptimeNanoseconds
            guard let cbSplat = queue.makeCommandBuffer(),
                  let splatFill = cbSplat.makeBlitCommandEncoder() else { return false }
            // One clear for the whole frame: the composite kernel zeroes each slot it
            // consumes, so every later batch starts clean without another fill.
            splatFill.fill(buffer: splatMax, range: 0..<slotBytes, value: 0)
            splatFill.fill(buffer: splatAcc, range: 0..<accBytes, value: 0)
            splatFill.endEncoding()
            guard let splatEnc = cbSplat.makeComputeCommandEncoder() else { return false }
            for b in 0..<splatBatches {
                sp.batchStart = UInt32(b * splatBatch)
                sp.batchCount = UInt32(min(splatBatch, visCount - b * splatBatch))
                splatEnc.setComputePipelineState(splatPipe)
                splatEnc.setBytes(&sp, length: MemoryLayout<LiveSplatParams>.stride, index: 0)
                splatEnc.setBuffer(frameSegs, offset: 0, index: 1)
                splatEnc.setBuffer(ref.segStroke, offset: 0, index: 2)
                splatEnc.setBuffer(ref.strokeFlags, offset: 0, index: 3)
                splatEnc.setBuffer(visOrd, offset: 0, index: 4)
                splatEnc.setBuffer(ranges, offset: 0, index: 5)
                splatEnc.setBuffer(splatMax, offset: 0, index: 6)
                splatEnc.dispatchThreadgroups(binGroups(ref.segCount),
                                              threadsPerThreadgroup: binThreads)

                splatEnc.setComputePipelineState(splatCompPipe)
                splatEnc.setBytes(&sp, length: MemoryLayout<LiveSplatParams>.stride, index: 0)
                splatEnc.setBuffer(splatMax, offset: 0, index: 1)
                splatEnc.setBuffer(visIDs, offset: 0, index: 2)
                splatEnc.setBuffer(ref.strokeColors, offset: 0, index: 3)
                splatEnc.setBuffer(ref.strokeFlags, offset: 0, index: 4)
                splatEnc.setBuffer(splatAcc, offset: 0, index: 5)
                splatEnc.setTexture(noiseBind, index: 0)
                if let sampler = linearSampler { splatEnc.setSamplerState(sampler, index: 0) }
                splatEnc.dispatchThreadgroups(splatGroups, threadsPerThreadgroup: splatThreads)
            }
            splatEnc.setComputePipelineState(splatWritePipe)
            splatEnc.setBytes(&sp, length: MemoryLayout<LiveSplatParams>.stride, index: 0)
            splatEnc.setBuffer(splatAcc, offset: 0, index: 1)
            splatEnc.setTexture(layerTex, index: 0)
            splatEnc.dispatchThreadgroups(splatGroups, threadsPerThreadgroup: splatThreads)
            // Stack the finished layer onto the canvas with the layer opacity — the same
            // `liveCompositeLayerKernel` dispatch `encodeTail` ends with. The splat only
            // fills the layer texture; without this the layer never reaches the canvas and
            // every splat-rendered layer vanishes from the frame.
            splatEnc.setComputePipelineState(compositePipeline)
            splatEnc.setTexture(layerTex, index: 0)
            splatEnc.setTexture(canvas, index: 1)
            var splatOpacity = opacity
            splatEnc.setBytes(&splatOpacity, length: MemoryLayout<Float>.stride, index: 0)
            splatEnc.dispatchThreadgroups(Self.liveGroups(width: width, height: height),
                                          threadsPerThreadgroup: Self.liveThreads)
            splatEnc.endEncoding()
            cbSplat.commit()
            cbSplat.waitUntilCompleted()
            if let err = cbSplat.error { throw err }
            let tRenderSplat = Self.milliseconds(since: splatStart)
            liveTiming.gpuMilliseconds += tRenderSplat
            liveTiming.allocMilliseconds += allocWindow
            liveTiming.binMilliseconds += max(0, Self.milliseconds(since: prefixStart)
                                                 - tRenderSplat - allocWindow)
            if LiveConfig.binStageTimingEnabled() {
                print(String(format: "livebin layer %d: segs %d tiles %d chunks 0 passes 0 — xform %.2f scatter 0.00 sort 0.00 render+comp %.2f ms [splat %d×%d]",
                             position, ref.segCount, boxTiles, tXform, tRenderSplat,
                             splatBatches, splatBatch))
            }
            liveTiming.dispatchedTiles += boxTiles
            liveTiming.strokes += visCount
            var splatSegTotal = 0
            for id in visStrokeIDs { splatSegTotal += ref.strokeSegCounts[id] }
            liveTiming.segments += splatSegTotal
            return true
        }

        // ── Stroke-block table (composite box pruning): per dense tile, blocks of
        // `pruneBlockSize` consecutive segments in document order with their padded
        // device boxes, so the composite kernels can skip whole segment runs whose
        // box misses a pixel (refines the earlier whole-stroke boxes: mega-strokes
        // skip per block too). Dense tiles only, and **off by default** since Round 12:
        // once the tile list is staged in threadgroup memory the per-entry prune is
        // cheaper than the block cursor, and this build costs 2–3 ms of `bin` on the
        // Mac. `ART_LIVE_STROKE_PRUNE=1` re-enables it (gate applies), `=2` forces it
        // past the gate; every mode is pixel-identical.
        var groupHeaderBuf: MTLBuffer
        var groupEntryBuf: MTLBuffer
        let aGroups = DispatchTime.now().uptimeNanoseconds
        let groupsReady = ensureEmptyGroupBuffers(device: device, tileCount: boxTiles)
        allocWindow += Self.milliseconds(since: aGroups)
        guard groupsReady else { return false }
        let aTable = DispatchTime.now().uptimeNanoseconds
        if LiveConfig.strokePruneEnabled() {
            let table = GpuBinSpec.strokeBlockTable(
                visibleStrokes: visStrokeIDs,
                blockFirst: ref.strokeBlockFirst, blockCount: ref.strokeBlockCount,
                blockStroke: ref.blockStroke, blockSegStart: ref.blockSegStart,
                blockRects: ref.blockRects,
                blockMaxRadius: ref.blockMaxRadius,
                blockIsMarker: ref.blockIsMarker,
                camera: (a: Float(camera.a), b: Float(camera.b),
                         c: Float(camera.c), d: Float(camera.d),
                         tx: Float(camera.tx), ty: Float(camera.ty)),
                radiusFactor: radiusFactor,
                tileCounts: countsArr,
                box: (box.minX, box.minY, box.maxX, box.maxY),
                texW: Int(texW), texH: Int(texH), tilesX: tilesX, tilesY: tilesY,
                invTile: invTile,
                force: LiveConfig.strokePruneForced())
            if table.totalBlocks > 0 {
                if ref.groupHeaderCap < boxTiles {
                    let aHdr = DispatchTime.now().uptimeNanoseconds
                    let capT = max(boxTiles, ref.groupHeaderCap * 2, 64)
                    guard let buf = device.makeBuffer(
                        length: capT * 2 * MemoryLayout<UInt32>.size,
                        options: .storageModeShared) else { return false }
                    ref.groupHeader = buf
                    ref.groupHeaderCap = capT
                    allocWindow += Self.milliseconds(since: aHdr)
                }
                if ref.groupCap < table.entries.count {
                    let aEnt = DispatchTime.now().uptimeNanoseconds
                    let capG = max(table.entries.count, ref.groupCap * 2, 64)
                    guard let buf = device.makeBuffer(
                        length: capG * MemoryLayout<GpuBinStrokeBlock>.stride,
                        options: .storageModeShared) else { return false }
                    ref.strokeGroups = buf
                    ref.groupCap = capG
                    allocWindow += Self.milliseconds(since: aEnt)
                }
                guard let hd = ref.groupHeader, let gr = ref.strokeGroups,
                      hd.length >= boxTiles * 2 * MemoryLayout<UInt32>.size,
                      gr.length >= table.entries.count * MemoryLayout<GpuBinStrokeBlock>.stride
                else { return false }
                table.header.withUnsafeBytes { raw in
                    if let src = raw.baseAddress {
                        memcpy(hd.contents(), src, table.header.count * MemoryLayout<UInt32>.size)
                    }
                }
                table.entries.withUnsafeBytes { raw in
                    if let src = raw.baseAddress {
                        memcpy(gr.contents(), src, raw.count)
                    }
                }
                groupHeaderBuf = hd
                groupEntryBuf = gr
            } else {
                // No dense tiles, or a table that could not pay for itself (see the
                // usability gate in `strokeBlockTable`): an empty header makes the kernels
                // walk segments directly (identical output, no per-block box tests). The
                // default configuration is this path, so it only reports when the table
                // was actually asked for.
                if LiveConfig.binStageTimingEnabled() && LiveConfig.strokePruneEnabled() {
                    let incidences = countsArr.reduce(0) { $0 + Int($1) }
                    print("livebin layer \(position): prune table skipped — "
                          + "block-tile bound ≥ \(table.blockTileEstimate) vs \(incidences) "
                          + "incidences; walking the tile list")
                }
                groupHeaderBuf = liveEmptyGroupHeader!
                groupEntryBuf = liveEmptyStrokeGroups!
            }
        } else {
            groupHeaderBuf = liveEmptyGroupHeader!
            groupEntryBuf = liveEmptyStrokeGroups!
        }
        if cpuStageTiming {
            tTable = Self.milliseconds(since: aTable)
            cpuMark = DispatchTime.now().uptimeNanoseconds
        }
        if ref.tileListCap < total {
            let aTile = DispatchTime.now().uptimeNanoseconds
            let cap = max(total, ref.tileListCap * 2)
            guard let buf = device.makeBuffer(length: cap * MemoryLayout<UInt32>.size,
                                              options: .storageModePrivate),
                  let scratch = device.makeBuffer(length: cap * MemoryLayout<UInt32>.size,
                                                  options: .storageModePrivate) else {
                return false
            }
            ref.tileList = buf
            ref.tileScratch = scratch
            ref.tileListCap = cap
            allocWindow += Self.milliseconds(since: aTile)
        }
        guard let tileList = ref.tileList, let tileScratch = ref.tileScratch else { return false }
        // Chunked sort plan (pure integer work on the counts we already have): split
        // every sortable slice into fixed chunks, plus the merge units for the passes
        // that actually merge. Shared with the mixed-layer path (`makeBinSortPlan`).
        guard let made = makeBinSortPlan(device: device, ref: ref, entries: entries,
                                         tileList: tileList, tileScratch: tileScratch) else {
            return false
        }
        let sortPlan = made.plan
        allocWindow += made.allocMilliseconds
        let finalTileList = sortPlan.finalTileList
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
        if cpuStageTiming {
            tPlan = Self.milliseconds(since: cpuMark)
            print(String(format: "livebin layer %d: cpu cull %.2f prep %.2f counts %.2f "
                          + "table %.2f plan+upload %.2f ms | alloc %.2f",
                          position, tCull, tPrep, tPrefix, tTable, tPlan, allocWindow))
        }
        liveTiming.allocMilliseconds += allocWindow
        liveTiming.binMilliseconds += max(0, Self.milliseconds(since: prefixStart) - allocWindow)

        // ── CB2: scatter + chunked sort + merge passes, then per-tile render +
        // layer composite. ART_LIVE_BINTIME=1 splits stages into one command buffer
        // each for attribution; steady state stays single-CB to save round trips.
        guard let canvas = liveCanvasTexture, let layerTex = gpuRenderTarget else { return false }
        let stageTiming = LiveConfig.binStageTimingEnabled()
        var tScatter = 0.0, tSort = 0.0, tRender = 0.0
        func sync(_ cb: MTLCommandBuffer) throws -> Double {
            let t = DispatchTime.now().uptimeNanoseconds
            cb.commit()
            cb.waitUntilCompleted()
            if let err = cb.error { throw err }
            return Self.milliseconds(since: t)
        }
        // Shared bin body, split for BINTIME attribution: unordered scatter, then
        // chunk sort + merge passes restore ascending order. Both halves are the same
        // encoders the mixed-layer path uses (`encodeBinScatter` / `encodeBinOrder`).
        func encodeScatter(_ encoder: MTLComputeCommandEncoder) {
            encodeBinScatter(ref: ref, bp: bp, tileList: tileList, encoder: encoder)
        }
        func encodeChunkSort(_ encoder: MTLComputeCommandEncoder) throws {
            try encodeBinChunkSort(sortPlan, ref: ref, tileList: tileList, encoder: encoder)
        }
        func encodeMergePass(_ encoder: MTLComputeCommandEncoder, pass: Int) throws {
            try encodeBinMergePass(sortPlan, ref: ref, pass: pass, total: total,
                                   tileList: tileList, tileScratch: tileScratch,
                                   encoder: encoder)
        }
        func encodeOrder(_ encoder: MTLComputeCommandEncoder) throws {
            try encodeBinOrder(sortPlan, ref: ref, total: total,
                               tileList: tileList, tileScratch: tileScratch,
                               encoder: encoder)
        }
        // Shared tail: per-tile render + layer composite onto `encoder`.
        func encodeTail(_ encoder: MTLComputeCommandEncoder) throws {
            let renderStart = DispatchTime.now().uptimeNanoseconds
            try encodePerTileBuffers(segBuffer: frameSegs, segOffset: 0,
                                     strokeOfSegBuffer: ref.segStroke, strokeOfSegOffset: 0,
                                     tileStartCountBuffer: tileIndexBuf, tileStartCountOffset: 0,
                                     tileListBuffer: finalTileList, tileListOffset: 0,
                                     strokeColorBuffer: ref.strokeColors, strokeColorOffset: 0,
                                     strokeFlagsBuffer: ref.strokeFlags, strokeFlagsOffset: 0,
                                     groupHeaderBuffer: groupHeaderBuf,
                                     strokeGroupsBuffer: groupEntryBuf,
                                     boxMinX: box.minX, boxMinY: box.minY,
                                     boxWidth: boxW, boxHeight: boxH,
                                     containsNoise: needsNoise,
                                     encoder: encoder)
            liveTiming.encodeMilliseconds += Self.milliseconds(since: renderStart)
            var layerOpacity = opacity
            encoder.setComputePipelineState(compositePipeline)
            encoder.setTexture(layerTex, index: 0)
            encoder.setTexture(canvas, index: 1)
            encoder.setBytes(&layerOpacity, length: MemoryLayout<Float>.stride, index: 0)
            encoder.dispatchThreadgroups(Self.liveGroups(width: width, height: height),
                                         threadsPerThreadgroup: Self.liveThreads)
        }
        // ART_LIVE_BINCHECK=1: force the split-CB form and read the tile list back
        // after every stage (scatter, chunk sort, each merge pass), verifying every
        // index is in bounds and every finished run is ascending. Prints the first
        // offender per stage — one run attributes the corruption to its stage.
        // Diagnostic only (full readbacks); steady state stays single-CB.
        let binCheck = LiveConfig.binCheckEnabled()
        func readbackTileList(_ src: MTLBuffer) -> [UInt32]? {
            guard total > 0 else { return [] }
            let bytes = total * MemoryLayout<UInt32>.size
            if ref.binCheckStaging == nil || ref.binCheckStaging!.length < bytes {
                guard let buf = device.makeBuffer(length: bytes,
                                                  options: .storageModeShared) else { return nil }
                ref.binCheckStaging = buf
            }
            guard let staging = ref.binCheckStaging,
                  let cb = queue.makeCommandBuffer(),
                  let blit = cb.makeBlitCommandEncoder() else { return nil }
            blit.copy(from: src, sourceOffset: 0, to: staging, destinationOffset: 0,
                      size: bytes)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            if cb.error != nil { return nil }
            var arr = [UInt32](repeating: 0, count: total)
            arr.withUnsafeMutableBytes { raw in
                if let dst = raw.baseAddress { memcpy(dst, staging.contents(), bytes) }
            }
            return arr
        }
        func tileOfSlot(_ s: Int) -> Int? {
            for (t, e) in entries.enumerated()
                where s >= Int(e.start) && s < Int(e.start) + Int(e.count) { return t }
            return nil
        }
        func checkBounds(_ arr: [UInt32], stage: String) {
            for (s, v) in arr.enumerated() where Int(v) >= ref.segCount {
                let where_ = tileOfSlot(s).map { "tile \($0)" } ?? "no tile (gap past total?)"
                print("livebin-check layer \(position) \(stage): OOB value \(v) at slot " +
                      "\(s) (\(where_), segs \(ref.segCount))")
                return
            }
            print("livebin-check layer \(position) \(stage): bounds OK " +
                  "(\(arr.count) slots, segs \(ref.segCount))")
        }
        func checkRuns(_ arr: [UInt32], stage: String, runs: [(start: Int, len: Int)]) {
            for r in runs where r.len >= 2 {
                var prev = arr[r.start]
                for k in 1..<r.len {
                    let v = arr[r.start + k]
                    if v < prev {
                        let where_ = tileOfSlot(r.start).map { "tile \($0)" } ?? "?"
                        print("livebin-check layer \(position) \(stage): run not ascending " +
                              "at slot \(r.start + k) (\(where_): ... \(prev) > \(v) ...)")
                        return
                    }
                    prev = v
                }
            }
            print("livebin-check layer \(position) \(stage): order OK (\(runs.count) runs)")
        }
        if stageTiming || binCheck {
            guard let cbH = queue.makeCommandBuffer(),
                  let fillH = cbH.makeBlitCommandEncoder(),
                  let cbS = queue.makeCommandBuffer(),
                  let encS = cbS.makeComputeCommandEncoder() else { return false }
            fillH.fill(buffer: heads, range: 0..<countBytes, value: 0)
            fillH.endEncoding()
            _ = try sync(cbH)
            encodeScatter(encS)
            encS.endEncoding()
            tScatter = try sync(cbS)
            if binCheck, let scattered = readbackTileList(tileList) {
                checkBounds(scattered, stage: "scatter")
            }
            guard let cbC = queue.makeCommandBuffer(),
                  let encC = cbC.makeComputeCommandEncoder() else { return false }
            try encodeChunkSort(encC)
            encC.endEncoding()
            tSort = try sync(cbC)
            if binCheck, let sorted = readbackTileList(tileList) {
                checkBounds(sorted, stage: "chunksort")
                checkRuns(sorted, stage: "chunksort",
                          runs: sortPlan.chunks.map { (Int($0.start), Int($0.len)) })
            }
            for pass in sortPlan.passUnits.indices {
                guard let cbM = queue.makeCommandBuffer(),
                      let encM = cbM.makeComputeCommandEncoder() else { return false }
                try encodeMergePass(encM, pass: pass)
                encM.endEncoding()
                tSort += try sync(cbM)
                if binCheck {
                    // Pass p writes (p odd ? tileList : scratch) — read back the output.
                    let outBuf: MTLBuffer = (pass % 2 == 1) ? tileList : tileScratch
                    if let merged = readbackTileList(outBuf) {
                        checkBounds(merged, stage: "merge\(pass)")
                        checkRuns(merged, stage: "merge\(pass)",
                                  runs: sortPlan.passUnits[pass].map {
                                    (Int($0.dst) + Int($0.part), Int($0.partLen)) })
                    }
                }
            }
            guard let cbR = queue.makeCommandBuffer(),
                  let encR = cbR.makeComputeCommandEncoder() else { return false }
            try encodeTail(encR)
            encR.endEncoding()
            tRender = try sync(cbR)
            liveTiming.gpuMilliseconds += tScatter + tSort + tRender
            if stageTiming {
                print(String(format: "livebin layer %d: segs %d entries %d tiles %d chunks %d passes %d %@ — xform %.2f scatter %.2f sort %.2f render+comp %.2f ms",
                             position, ref.segCount, total, boxTiles, sortPlan.chunks.count,
                             sortPlan.mergePasses, needsNoise ? "noise" : "aa",
                             tXform, tScatter, tSort, tRender))
            }
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
        encodeScatter(enc2)
        try encodeOrder(enc2)
        try encodeTail(enc2)
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
           ref.docID == docID, ref.segCount == layer.strokeSegmentCount {
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
        var maxRadii: [Float] = []
        // Prune blocks: per stroke, `pruneBlockSize` consecutive segments share one
        // doc-space running AABB. Blocks never span strokes.
        var blockFirst: [Int] = []
        var blockCount: [Int] = []
        var bStroke: [Int32] = []
        var bSegStart: [Int32] = []
        var bRects: [SIMD4<Float>] = []
        var bMaxR: [Float] = []
        var bMarker: [Bool] = []
        segments.reserveCapacity(layer.strokeSegmentCount)
        let force = LiveConfig.forcedCompositeKernel()
        for op in layer.ops {
            guard case .stroke(let s) = op else { continue }
            let sid = UInt32(colors.count)
            colors.append(s.color)
            let rawHasNoise = s.segments.contains { $0.noiseSeed != 0 }
            // Forced noise must render clean strokes through the noise coverage, so its
            // per-stroke flag has to say noisy. Forced AA leaves the flag alone (the AA
            // kernel ignores it).
            let hasNoise = force == .noise ? true : rawHasNoise
            flags.append(LivePerTileEligibility.strokeFlags(isEraser: s.isEraser,
                                                            hasNoise: hasNoise,
                                                            isMarker: s.isMarker))
            bounds.append(s.bounds)
            markers.append(s.isMarker)
            noisy.append(hasNoise)
            segCounts.append(s.segments.count)
            segments.append(contentsOf: s.segments)
            segStroke.append(contentsOf: Array(repeating: sid, count: s.segments.count))
            // Radius scaling uses one factor per frame (same formula `deviceOps` and the
            // fused transform kernel apply), so the per-stroke max doc radius is what the
            // physics-derived device extent needs.
            maxRadii.append(s.segments.reduce(Float(0)) {
                max(max($0, $1.radius0), $1.radius1) })
            // Prune blocks: `pruneBlockSize` consecutive segments of the stroke share
            // one running doc-space AABB over their control points; the block's own
            // max-radius pad is added at table-build time (tighter than a stroke-level
            // pad on tapering strokes). Blocks never span strokes.
            blockFirst.append(bRects.count)
            var nBlocks = 0
            var bi = 0
            while bi < s.segments.count {
                let segStart = segments.count - s.segments.count + bi
                var bx0 = Float.greatestFiniteMagnitude, bx1 = -Float.greatestFiniteMagnitude
                var by0 = Float.greatestFiniteMagnitude, by1 = -Float.greatestFiniteMagnitude
                var bR = Float(0)
                var n = 0
                while bi < s.segments.count && n < GpuBinSpec.pruneBlockSize {
                    let seg = s.segments[bi]
                    let x0 = min(min(seg.p0.x, seg.p1.x), min(seg.p2.x, seg.p3.x))
                    let x1 = max(max(seg.p0.x, seg.p1.x), max(seg.p2.x, seg.p3.x))
                    let y0 = min(min(seg.p0.y, seg.p1.y), min(seg.p2.y, seg.p3.y))
                    let y1 = max(max(seg.p0.y, seg.p1.y), max(seg.p2.y, seg.p3.y))
                    bx0 = min(bx0, x0); bx1 = max(bx1, x1)
                    by0 = min(by0, y0); by1 = max(by1, y1)
                    bR = max(bR, max(seg.radius0, seg.radius1))
                    bi += 1
                    n += 1
                }
                bStroke.append(Int32(sid))
                bSegStart.append(Int32(segStart))
                bRects.append(SIMD4<Float>(bx0, by0, bx1, by1))
                bMaxR.append(bR)
                bMarker.append(s.isMarker)
                nBlocks += 1
            }
            blockCount.append(nBlocks)
        }
        guard !segments.isEmpty else { throw MetalRendererError.bufferCreationFailed }
        // Reference geometry is read by the GPU every frame (the transform kernel reads
        // the whole segment array), so it must live in VRAM: a `.shared` buffer is
        // system memory on a discrete GPU and every per-frame read crosses the bus.
        // Upload through a one-time `.shared` staging copy + blit into `.private` —
        // measured at 4.4 ms/frame for kaos' 20 MB segment array when left `.shared`.
        func upload<T>(_ array: [T], _ stride: Int) throws -> MTLBuffer {
            let bytes = max(stride * array.count, 1)
            guard let dst = device.makeBuffer(length: bytes, options: .storageModePrivate),
                  let src = device.makeBuffer(length: bytes, options: .storageModeShared),
                  let cb = commandQueue?.makeCommandBuffer() else {
                throw MetalRendererError.bufferCreationFailed
            }
            array.withUnsafeBytes { raw in
                if let p = raw.baseAddress {
                    memcpy(src.contents(), p, min(raw.count, bytes))
                }
            }
            guard let blit = cb.makeBlitCommandEncoder() else {
                throw MetalRendererError.bufferCreationFailed
            }
            blit.copy(from: src, sourceOffset: 0, to: dst, destinationOffset: 0, size: bytes)
            blit.endEncoding()
            cb.commit()
            cb.waitUntilCompleted()
            if let err = cb.error { throw err }
            return dst
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
            strokeSegCounts: segCounts, strokeMaxRadius: maxRadii,
            strokeBlockFirst: blockFirst, strokeBlockCount: blockCount,
            blockStroke: bStroke, blockSegStart: bSegStart, blockRects: bRects,
            blockMaxRadius: bMaxR, blockIsMarker: bMarker)
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

    /// Sizes the splat path's per-layer scratch (geometric reuse; grown, never shrunk).
    /// `slots` = box pixels × batch; `pixels` = box pixel count. The caller has already
    /// checked the slot budget, so a failure here is a genuine allocation failure.
    private func ensureSplatBuffers(device: MTLDevice, ref: LiveBinRefLayer,
                                    pixels: Int, slots: Int) -> Bool {
        guard pixels > 0, slots > 0 else { return false }
        if ref.splatMax == nil || ref.splatMaxCap < slots {
            let cap = max(slots, ref.splatMaxCap * 2, 1024)
            guard let buf = device.makeBuffer(length: cap * MemoryLayout<UInt32>.size,
                                              options: .storageModePrivate) else { return false }
            ref.splatMax = buf
            ref.splatMaxCap = cap
        }
        if ref.splatAcc == nil || ref.splatAccCap < pixels {
            let cap = max(pixels, ref.splatAccCap * 2, 256)
            guard let buf = device.makeBuffer(length: cap * MemoryLayout<SIMD4<Float>>.stride,
                                              options: .storageModePrivate) else { return false }
            ref.splatAcc = buf
            ref.splatAccCap = cap
        }
        let ordBytes = max(ref.strokeCount, 1) * MemoryLayout<UInt32>.size
        if ref.visOrd == nil || ref.visOrd!.length < ordBytes {
            guard let buf = device.makeBuffer(length: ordBytes,
                                              options: .storageModeShared) else { return false }
            ref.visOrd = buf
        }
        if ref.visStrokeIDsBuf == nil || ref.visStrokeIDsBuf!.length < ordBytes {
            guard let buf = device.makeBuffer(length: ordBytes,
                                              options: .storageModeShared) else { return false }
            ref.visStrokeIDsBuf = buf
        }
        return true
    }

    /// Valid texture for the splat composite's noise slot: the real noise texture when
    /// the document has one, otherwise a 1×1 stand-in (never sampled — the kernel's
    /// noise flag is 0 — but a valid object must be bound).
    private func splatNoiseBinding() -> MTLTexture? {
        if let n = noiseTexture { return n }
        if let d = liveSplatDummyTexture { return d }
        guard let device = device else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm,
                                                            width: 1, height: 1,
                                                            mipmapped: false)
        desc.usage = .shaderRead
        desc.storageMode = .shared
        guard let d = device.makeTexture(descriptor: desc) else { return nil }
        liveSplatDummyTexture = d
        return d
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

    /// Threads per group for the per-tile kernels: one thread per tile pixel, capped at
    /// 16×16. With a 16×16 tile (the default) this is one group per tile; with an 8×8
    /// tile it is an 8×8 group, so the group's staged tile list and its barrier cover
    /// exactly its tile. Larger tiles use several 16×16 groups per tile.
    var perTileThreads: MTLSize {
        let d = min(liveTileSize, Int(Self.liveThreads.width))
        return MTLSize(width: d, height: d, depth: 1)
    }

    /// Threadgroups needed for `width` × `height` pixels at `liveThreads`.
    static func liveGroups(width: Int, height: Int) -> MTLSize {
        MTLSize(width: (width + Int(liveThreads.width) - 1) / Int(liveThreads.width),
                height: (height + Int(liveThreads.height) - 1) / Int(liveThreads.height),
                depth: 1)
    }
    
    /// Bins every stroke into `liveStaging` and returns the ordered op list.
    private func bin(layerOps: [LiveDeviceOp],
                     width: Int, height: Int) throws -> ([LiveLayerStep], [LiveStrokeBin]) {
        // Append to the arena so a mixed layer can run several stroke runs.
        var cursor = liveStagingUsed
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
                case .paste:
                    // Pastes are planned by the mixed renderer; this path never gets them.
                    continue
                case .stroke(let segments, let color, let isEraser, let isMarker, _):
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
            boxTilesPerCol: UInt32(bin.maxTileY - bin.minTileY + 1),
            tileSize: UInt32(liveTile),
            textureWidth: UInt32(width), textureHeight: UInt32(height),
            stampCount: UInt32(bin.segmentCount),
            penColorR: bin.color.x, penColorG: bin.color.y,
            penColorB: bin.color.z, penColorA: bin.color.w,
            noiseScale: 0.4,
            noiseOffsetX: Float(self.liveNoiseOffset.x),
            noiseOffsetY: Float(self.liveNoiseOffset.y),
            flags: flags)
        
        encoder.setComputePipelineState(pipeline)
        encoder.setBytes(&params, length: MemoryLayout<LiveStrokeParams>.stride, index: 0)
        encoder.setBuffer(arena, offset: bin.segmentOffset, index: 1)
        encoder.setBuffer(arena, offset: bin.tileIndexOffset, index: 2)
        encoder.setBuffer(arena, offset: bin.tileListOffset, index: 3)
        encoder.setTexture(gpuRenderTarget, index: 0)
        // Dispatch only the stroke's tile box: ceil(tileSize / threadDim) threadgroups per
        // tile, over [minTile…maxTile]. A single-tile stroke yields 1 (never 0).
        let threadDim = perTileThreads
        let groupsPerTileX = (liveTile + Int(threadDim.width) - 1) / Int(threadDim.width)
        let groupsPerTileY = (liveTile + Int(threadDim.height) - 1) / Int(threadDim.height)
        let groups = MTLSize(width: (bin.maxTileX - bin.minTileX + 1) * groupsPerTileX,
                             height: (bin.maxTileY - bin.minTileY + 1) * groupsPerTileY,
                             depth: 1)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threadDim)
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
