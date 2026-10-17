// Requirements: macOS 12 compatibility - Swift 5.7, Metal 2
#if os(macOS)
import Metal
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Data Structures

/// Represents a single stamp for GPU processing
/// Mirrored in Metal shader for memory layout compatibility
//struct Stamp {
//    var center: SIMD2<Float>
//    var radius: Float
//    var opacity: Float // unused?
//    var rotation: Float // unused?
//    var noiseSeed: UInt32
//
//    init(center: SIMD2<Float>, radius: Float, opacity: Float, rotation: Float, noiseSeed: UInt32) {
//        self.center = center
//        self.radius = radius
//        self.opacity = opacity
//        self.rotation = rotation
//        self.noiseSeed = noiseSeed
//    }
//}

/// Parameters for the stamp kernel
struct Params {
    var textureWidth: UInt32
    var textureHeight: UInt32
    var tileSize: UInt32
    var tilesPerRow: UInt32
    var stampCount: UInt32
    var penColor: SIMD4<Float>
    var noiseScale: Float
    var isEraser: Bool
    var isMarker: Bool
}


/// Tile index structure for spatial indexing
struct TileIndex {
    var start: UInt32  // Start index into the stamps array
    var count: UInt32  // Number of stamps for this tile
}

// MARK: - Metal Renderer State
class MetalRenderer {
    // MARK: - Properties
    
    public let device: MTLDevice?
    public let commandQueue: MTLCommandQueue?
    internal var library: MTLLibrary?
    
    // Compute pipelines
    internal var clearPipeline: MTLComputePipelineState?
    internal var convertPipeline: MTLRenderPipelineState?
    internal var fxaaPipeline: MTLComputePipelineState?
    public var useFXAA: Bool = false    // ö
    internal var eraserPipeline: MTLComputePipelineState?
    
    // Pipelines for high-quality two-pass rendering
    internal var distanceFieldMaskPipeline: MTLComputePipelineState?
    internal var highQualityAntiAliasPipeline: MTLComputePipelineState?
    
    // Segment pipeline
    //    private var segmentSDFPipeline: MTLComputePipelineState?
    internal var segmentNoiseCompositePipeline: MTLComputePipelineState?
    internal var segmentAACompositePipeline: MTLComputePipelineState?
    // Live-view-only twins of the segment kernels (tile-range dispatch). Built in
    // prepareLiveCompositing; when absent the live view falls back to the static path.
    internal var liveSegmentAACompositePipeline: MTLComputePipelineState?
    internal var liveSegmentNoiseCompositePipeline: MTLComputePipelineState?
    // Per-tile live composite (one dispatch per layer; AA-only fast path).
    internal var livePerTileAACompositePipeline: MTLComputePipelineState?
    // Per-tile live composite for layers containing noise (AA + noise per stroke group).
    // Optional: noisy layers fall back to per-stroke when the installed metallib
    // predates this kernel.
    internal var livePerTileNoiseCompositePipeline: MTLComputePipelineState?
    // GPU tile-binning kernels (live view `bin` stage). All optional: a metallib that
    // predates them (or ART_LIVE_GPUBIN=0) silently uses the CPU binning instead.
    internal var liveBinTransformCountPipeline: MTLComputePipelineState?
    internal var liveBinScatterPipeline: MTLComputePipelineState?
    // Chunked sort: one thread sorts one 512-entry chunk in place, then pairwise merge
    // passes restore full order — bounded work per thread at any zoom (no per-tile sort).
    internal var liveBinChunkSortPipeline: MTLComputePipelineState?
    internal var liveBinMergePassPipeline: MTLComputePipelineState?
    /// Per-layer GPU-binning state, keyed by layer index. Entries are validated against
    /// the owning cache (`ObjectIdentifier`) + segment count and dropped wholesale when
    /// the document changes — reference-space geometry never crosses documents.
    internal var liveBinLayers: [Int: LiveBinRefLayer] = [:]
    internal var liveBinDocID: ObjectIdentifier?

/// One layer's GPU-binning state. Reference-space geometry is uploaded ONCE per
/// document/layer (it never changes across frames — only the camera does); frame buffers
/// are geometrically resized and reused, so steady-state frames allocate nothing.
internal final class LiveBinRefLayer {
    var docID: ObjectIdentifier
    var segCount: Int
    var strokeCount: Int
    // Static per document/layer (uploaded once):
    var refSegments: MTLBuffer       // N × GPUSplineSegment, reference space (.shared)
    var segStroke: MTLBuffer         // N × UInt32: global segIdx → stroke idx (.shared)
    var strokeColors: MTLBuffer      // S × SIMD4<Float> (.shared)
    var strokeFlags: MTLBuffer       // S × UInt32, bit0 = eraser, bit1 = hasNoise (.shared)
    var strokeVisible: MTLBuffer     // S × UInt8, rewritten per frame (.shared)
    var strokeBounds: [CGRect]       // S, CPU side for culling
    var strokeIsMarker: [Bool]       // S
    var strokeHasNoise: [Bool]       // S
    var strokeSegCounts: [Int]       // S, segments per stroke (timing counters)
    // Frame buffers (sized geometrically, reused across frames):
    var frameSegments: MTLBuffer?    // N × GPUSplineSegment, device space (.private)
    var ranges: MTLBuffer?           // N × int4 tile ranges (.private)
    // Counts/heads live in .private memory: the count/scatter atomics hammer them from
    // tens of thousands of threads, and atomics to .shared buffers cross the system
    // fabric (much slower under contention, exactly the clustered-artwork case). The
    // CPU only needs the counts back, so one small blit copies them to .shared staging.
    var counts: MTLBuffer?           // boxTiles × UInt32 atomics (.private)
    var countsStaging: MTLBuffer?    // boxTiles × UInt32 CPU readback (.shared)
    var heads: MTLBuffer?            // boxTiles × UInt32 scatter heads (.private)
    var starts: MTLBuffer?           // boxTiles × UInt32 prefix starts (.shared)
    var tileIndex: MTLBuffer?        // boxTiles × TileIndex, render + merge input (.shared)
    var tileList: MTLBuffer?         // incidences × UInt32 (.private)
    var tileScratch: MTLBuffer?      // incidences × UInt32, merge ping-pong (.private)
    var sortChunks: MTLBuffer?       // sort chunks × uint2 (start, len) (.shared)
    var sortUnits: MTLBuffer?        // merge units (6×uint32), ALL passes concatenated (.shared)
                                                   // (per-pass offsets — never rewritten during encoding)
    var binCheckStaging: MTLBuffer?  // tile-list readback scratch for ART_LIVE_BINCHECK=1 (.shared)
    var boxCap = 0                   // boxTiles currently allocated
    var tileListCap = 0              // incidences currently allocated
    var chunkCap = 0                 // sort chunks currently allocated
    var unitCap = 0                  // merge-unit slots currently allocated (all passes)

    init(docID: ObjectIdentifier, segCount: Int, strokeCount: Int,
         refSegments: MTLBuffer, segStroke: MTLBuffer,
         strokeColors: MTLBuffer, strokeFlags: MTLBuffer, strokeVisible: MTLBuffer,
         strokeBounds: [CGRect], strokeIsMarker: [Bool], strokeHasNoise: [Bool],
         strokeSegCounts: [Int]) {
        self.docID = docID
        self.segCount = segCount
        self.strokeCount = strokeCount
        self.refSegments = refSegments
        self.segStroke = segStroke
        self.strokeColors = strokeColors
        self.strokeFlags = strokeFlags
        self.strokeVisible = strokeVisible
        self.strokeBounds = strokeBounds
        self.strokeIsMarker = strokeIsMarker
        self.strokeHasNoise = strokeHasNoise
        self.strokeSegCounts = strokeSegCounts
    }
}

    internal var segmentPasteLayerAACompositePipeline: MTLComputePipelineState?
    internal var segmentPasteLayerNoiseCompositePipeline: MTLComputePipelineState?
    internal var segmentCutCompositePipeline: MTLComputePipelineState?
    internal var segmentBuffer: MTLBuffer?
    
    internal var mergeFlattenPipeline: MTLComputePipelineState?
    internal var mergeFragmentTexture: MTLTexture?
    internal var openMergeID: UInt64? = nil
    internal var openMergeOpacity: Float = 1.0
    
    // High-quality stamp pipeline
    internal var highQualityStampPipeline: MTLComputePipelineState?
    internal var highQualityStampWithNoisePipeline: MTLComputePipelineState?
    
    // Render pipeline for MSAA stamp rendering
    //    private var stampRenderPipeline: MTLRenderPipelineState? // unused?
    
    // Textures and buffers
    internal var noiseTexture: MTLTexture?
    internal var stampBuffer: MTLBuffer?
    //    private var tileIndexBuffer: MTLBuffer? // unused?
    internal var paramsBuffer: MTLBuffer?
    internal var pasteMetaBuffer: MTLBuffer?
    internal var pasteMaskBuffer: MTLBuffer?
    internal var cutMetaBuffer: MTLBuffer?
    
    // Intermediate textures for two-pass rendering
    internal var distanceFieldTexture: MTLTexture?
    internal var opacityFieldTexture: MTLTexture?
    
    // Store clear library separately
    //    private var clearLibrary: MTLLibrary? // unused?
    
    // MSAA textures
    //    private var msaaRenderTarget: MTLTexture? // unused?
    //    private var msaaResolveTexture: MTLTexture? // unused?
    
    // Storage texture
    //    private var metalStagingTexture: MTLTexture? = nil // unused?
    
    // GPU target (private storage) used by compute shaders
    private(set) var gpuRenderTarget: MTLTexture?
    
    // ── Live view (interactive pan / zoom / rotate preview) ──
    // See MetalRenderer_LiveCompositing.swift / MetalRenderer_LivePresent.swift.
    internal var liveCompositeLayerPipeline: MTLComputePipelineState?
    internal var livePaperBackgroundPipeline: MTLComputePipelineState?
    internal var livePresentPipeline: MTLRenderPipelineState?
    internal var livePresentPipelineRGBA: MTLRenderPipelineState?
    /// Canvas/background pairs, double buffered. The interactive path renders into
    /// `liveCanvasIndex` while the UI keeps presenting the *other* pair — otherwise the
    /// `clearTexture` at the top of every frame wipes the very texture that is on screen
    /// (which showed up as blinking between frames). `LiveRenderedCanvas` carries its own
    /// pair, so the present pass needs no knowledge of this.
    internal var liveCanvasTextures: [MTLTexture] = []   // premultiplied, optionally mipmapped
    internal var liveBackgroundTextures: [MTLTexture] = []
    internal var liveCanvasIndex = 0
    /// The pair currently being rendered into.
    internal var liveCanvasTexture: MTLTexture? { canvas(at: liveCanvasIndex) }
    internal var liveBackgroundTexture: MTLTexture? { background(at: liveCanvasIndex) }
    internal var livePaperTexture: MTLTexture?           // art's paper JPEG
    /// 1×1 stand-in bound when a document has no paper texture.
    internal static var placeholderTexture: MTLTexture?
    /// One buffer per in-flight frame: MTKView can have several drawables in flight, and
    /// they must not share the transform uniform.
    internal var livePresentUniformsBuffers: [MTLBuffer] = []
    internal var livePresentUniformsIndex = 0
    /// Linear sampling **with mips**, so zooming out below 1:1 does not alias.
    internal var livePresentSampler: MTLSamplerState?
    // Interactive (re-render) mode scratch space — see MetalRenderer_LiveCompositing.
    // Stored here because extensions cannot declare stored properties.
    internal var liveStaging: UnsafeMutableRawPointer?
    internal var liveStagingCapacity = 0
    internal var liveArena: MTLBuffer?
    internal var liveArenaCapacity = 0
    internal var liveStagingUsed = 0
    /// Set once the live pipelines exist. A stale metallib (missing the live
    /// kernels) leaves this false and callers fall back to the static path.
    internal var liveCompositingPrepared = false
    /// Stage timings of the interactive frame currently being built — see LiveFrameTiming.swift.
    internal var liveTiming = LiveFrameTiming()
    
    // CPU-readable staging texture (shared storage) used for readback after blit
    private(set) var stagingTexture: MTLTexture?
    
    // Samplers
    internal let linearSampler: MTLSamplerState?
    
    // Configuration
    internal var tileSize = 32  // Coarse tile size for spatial indexing (override via ART_TILE_SIZE for tuning)
    /// Tile size used by the *live* binning/dispatch only (default 16; see LiveConfig).
    /// The static path keeps using `tileSize` above, so changing the live default
    /// cannot regress the static renders.
    internal var liveTileSize = 16
    
    internal var tileIndicesBuffer: MTLBuffer?
    internal var tileListBuffer: MTLBuffer?
    
    //    public static var droppedPasteMaskCount = 0
    
    // NEW: Timing measurements for performance analysis
    //    private var timingMeasurements: [String: TimeInterval] = [:] // unused?
    
    // MARK: - Static Properties
    
    /// Check if Metal is supported on this device
    static var isSupported: Bool {
        return MTLCreateSystemDefaultDevice() != nil
    }
    
    static var useGPURendering = true
    
    // MARK: - Initialization
    
    init(device: MTLDevice? = nil, library: MTLLibrary? = nil) throws { // library param unused?
        self.device = device ?? MTLCreateSystemDefaultDevice()
        
        guard let device = self.device else {
            throw MetalRendererError.deviceNotAvailable
        }
        
        // Tile size is tunable at runtime (ART_TILE_SIZE) so values can be A/B measured
        // without recompiling. Caveat baked into the design: the frame's distance-field
        // evaluation count is ~tile-size-invariant (fewer segments per tile, but
        // proportionally more tiles), so a smaller tile mostly buys CPU bin time vs.
        // threadgroup launches — not fewer SDF evaluations. Measure before assuming <64 wins.
        if let override = ProcessInfo.processInfo.environment["ART_TILE_SIZE"],
           let value = Int(override), value >= 8 {
            self.tileSize = value
        }
        // Live tile size defaults to 16 (see LiveConfig.liveTileSize); ART_LIVE_TILE_SIZE
        // overrides, otherwise an explicit ART_TILE_SIZE is honoured, otherwise 16.
        self.liveTileSize = LiveConfig.liveTileSize()
        
        self.commandQueue = device.makeCommandQueue()
        
        // Create sampler FIRST before using it in pipeline creation
        let samplerDescriptor = MTLSamplerDescriptor()
        samplerDescriptor.minFilter = .linear
        samplerDescriptor.magFilter = .linear
        samplerDescriptor.mipFilter = .notMipmapped
        samplerDescriptor.sAddressMode = .clampToEdge
        samplerDescriptor.tAddressMode = .clampToEdge
        samplerDescriptor.rAddressMode = .clampToEdge
        samplerDescriptor.normalizedCoordinates = true
        
        self.linearSampler = device.makeSamplerState(descriptor: samplerDescriptor)
        
        // Now create pipelines after sampler is available
        do {
            print("Loading Pre-compiled Metal library...")
            
            // 1. Find the bundle
            let bundle = Bundle.module
            
            // 2. Locate the compiled binary
            // Adjust the subdirectory/path based on where you put it in Package.swift
            guard let libraryURL = bundle.url(forResource: "ArtRenderShaders", withExtension: "metallib") else {
                // Fallback to source compilation if binary missing (optional, for dev purposes)
                print("WARNING: Metallib not found, attempting fallback to source compilation")
                // You could keep your old string-based code here as a fallback if desired
                throw MetalRendererError.shaderFileNotFound("ArtRenderShaders.metallib")
            }
            
            // 3. Load the library directly from the binary file
            // This is instantaneous compared to source compilation
            let library = try device.makeLibrary(URL: libraryURL)
            
            print("Metal library loaded successfully from binary")
            
            // 4. Create pipelines using the loaded library
            
            // Create clear pipeline
            if let clearFn = library.makeFunction(name: "clearKernel") {
                print("Creating clear pipeline...")
                self.clearPipeline = try device.makeComputePipelineState(function: clearFn)
                print("Metal: clearKernel pipeline created successfully")
            } else {
                print("WARNING: clearKernel function not found in library")
                self.clearPipeline = nil
            }
            
            // Create convert pipeline
            do {
                guard let vs = library.makeFunction(name: "vs_passthrough") else {
                    print("WARNING: vs_passthrough function not found in library")
                    self.convertPipeline = nil
                    throw MetalRendererError.functionNotFound("vs_passthrough")
                }
                guard let fs = library.makeFunction(name: "fs_convert") else {
                    print("WARNING: fs_convert function not found in library")
                    self.convertPipeline = nil
                    throw MetalRendererError.functionNotFound("fs_convert")
                }
                
                print("Creating convert pipeline...")
                let desc = MTLRenderPipelineDescriptor()
                desc.colorAttachments[0].pixelFormat = .rgba8Unorm
                desc.vertexFunction = vs
                desc.fragmentFunction = fs
                self.convertPipeline = try device.makeRenderPipelineState(descriptor: desc)
                print("Metal: convert pipeline created successfully")
            } catch {
                print("Metal: failed to create convert pipeline: \(error)")
                self.convertPipeline = nil
            }
            
            // Create distance field mask pipeline
            if let distanceFieldMaskFn = library.makeFunction(name: "distanceFieldMaskKernel") {
                do {
                    self.distanceFieldMaskPipeline = try device.makeComputePipelineState(function: distanceFieldMaskFn)
                    print("Metal: distanceFieldMaskKernel pipeline created")
                } catch {
                    print("Metal: failed to create distanceFieldMask pipeline: \(error)")
                    self.distanceFieldMaskPipeline = nil
                }
            } else {
                print("Metal: distanceFieldMaskKernel not found in library")
            }
            
            //            // Segment distance field mask pipeline
            //            if let segmentSDFFn = library.makeFunction(name: "segmentSDFMaskKernel") {
            //                do {
            //                    self.segmentSDFPipeline = try device.makeComputePipelineState(function: segmentSDFFn)
            //                    print("Metal: segmentSDFMaskKernel pipeline created")
            //                } catch {
            //                    print("Metal: failed to create segmentSDFMaskPipeline: \(error)")
            //                    self.segmentSDFPipeline = nil
            //                }
            //            } else {
            //                print("Metal: segmentSDFMaskKernel not found in library")
            //            }
            
            // Segment noise pipeline
            if let segmentNoiseFn = library.makeFunction(name: "segmentNoiseCompositeKernel") {
                do {
                    self.segmentNoiseCompositePipeline = try device.makeComputePipelineState(function: segmentNoiseFn)
                    print("Metal: segmentNoiseCompositeKernel pipeline created")
                } catch {
                    print("Metal: failed to create segmentNoiseCompositePipeline: \(error)")
                }
            } else {
                print("Metal: segmentNoiseCompositeKernel not found in library")
            }
            
            // Semgent hard edge pipeline
            if let segmentAAFn = library.makeFunction(name: "segmentAACompositeKernel") {
                do {
                    self.segmentAACompositePipeline = try device.makeComputePipelineState(function: segmentAAFn)
                    print("Metal: segmentAACompositeCompositeKernel pipeline created")
                } catch {
                    print("Metal: failed to create segmentAACompositePipeline: \(error)")
                }
            } else {
                print("Metal: segmentAACompositeKernel not found in library")
            }
            
            
            // Create high-quality anti-alias pipeline
            if let highQualityAntiAliasFn = library.makeFunction(name: "highQualityAntiAliasKernel") {
                do {
                    self.highQualityAntiAliasPipeline = try device.makeComputePipelineState(function: highQualityAntiAliasFn)
                    print("Metal: highQualityAntiAliasKernel pipeline created")
                } catch {
                    print("Metal: failed to create highQualityAntiAlias pipeline: \(error)")
                    self.highQualityAntiAliasPipeline = nil
                }
            } else {
                print("Metal: highQualityAntiAliasKernel not found in library")
            }
            
            // Create high-quality stamp pipeline
            if let highQualityFn = library.makeFunction(name: "highQualityStampKernel") {
                do {
                    self.highQualityStampPipeline = try device.makeComputePipelineState(function: highQualityFn)
                    print("Metal: highQualityStampKernel pipeline created")
                } catch {
                    print("Metal: failed to create highQualityStamp pipeline: \(error)")
                    self.highQualityStampPipeline = nil
                }
            } else {
                print("Metal: highQualityStampKernel not found in library")
            }
            
            // Create high-quality stamp with noise pipeline
            if let highQualityNoiseFn = library.makeFunction(name: "highQualityStampWithNoiseKernel") {
                do {
                    self.highQualityStampWithNoisePipeline = try device.makeComputePipelineState(function: highQualityNoiseFn)
                    print("Metal: highQualityStampWithNoiseKernel pipeline created")
                } catch {
                    print("Metal: failed to create highQualityStampWithNoise pipeline: \(error)")
                    self.highQualityStampWithNoisePipeline = nil
                }
            } else {
                print("Metal: highQualityStampWithNoiseKernel not found in library")
            }
            
            // Create FXAA pipeline
            if let fxaaFn = library.makeFunction(name: "fxaaKernel") {
                do {
                    self.fxaaPipeline = try device.makeComputePipelineState(function: fxaaFn)
                    print("Metal: fxaaKernel pipeline created successfully")
                } catch {
                    print("Metal: failed to create fxaa pipeline: \(error)")
                    self.fxaaPipeline = nil
                }
            } else {
                print("Metal: fxaaKernel function not found in library")
            }
            
            if let eraserKernelFn = library.makeFunction(name: "eraserKernel") {
                do {
                    self.eraserPipeline = try device.makeComputePipelineState(function: eraserKernelFn)
                    print("Metal: eraserKernel pipeline created successfully")
                } catch {
                    print("Metal: failed to create eraser pipeline: \(error)")
                    self.eraserPipeline = nil
                }
            } else {
                print("Metal: eraserKernel not found in library")
            }
            
            if let segmentPasteLayerAACompositeKernelFn = library.makeFunction(name: "segmentPasteLayerAACompositeKernel") {
                do {
                    self.segmentPasteLayerAACompositePipeline = try device.makeComputePipelineState(function: segmentPasteLayerAACompositeKernelFn)
                    print("Metal: segmentPasteLayerAAComposite pipeline created successfully")
                } catch {
                    print("Metal: failed to create segmentPasteLayerAAComposite pipeline: \(error)")
                    self.segmentPasteLayerAACompositePipeline = nil
                }
            } else {
                print("Metal: segmentPasteLayerAACompositeKernel not found in library")
            }
            
            if let segmentPasteLayerNoiseCompositeKernelFn = library.makeFunction(name: "segmentPasteLayerNoiseCompositeKernel") {
                do {
                    self.segmentPasteLayerNoiseCompositePipeline = try device.makeComputePipelineState(function: segmentPasteLayerNoiseCompositeKernelFn)
                    print("Metal: segmentPasteLayerNoiseCompositeKernel pipeline created successfully")
                } catch {
                    print("Metal: failed to create segmentPasteLayerNoiseComposite pipeline: \(error)")
                    self.segmentPasteLayerNoiseCompositePipeline = nil
                }
            } else {
                print("Metal: segmentPasteLayerNoiseCompositeKernel not found in library")
            }
            
            if let segmentCutCompositeKernelFn = library.makeFunction(name: "segmentCutCompositeKernel") {
                do {
                    self.segmentCutCompositePipeline = try device.makeComputePipelineState(function: segmentCutCompositeKernelFn)
                    print("Metal: segmentCutCompositeKernel pipeline created successfully")
                } catch {
                    print("Metal: failed to create segmentCutComposite pipeline: \(error)")
                    self.segmentCutCompositePipeline = nil
                }
            } else {
                print("Metal: segmentCutCompositeKernel not found in library")
            }
            
            if let mergeFlattenCompositeKernelFn = library.makeFunction(name: "mergeFlattenCompositeKernel") {
                do {
                    self.mergeFlattenPipeline = try device.makeComputePipelineState(function: mergeFlattenCompositeKernelFn)
                    print("Metal: mergeFlattenPipeline created successfully")
                } catch {
                    print("Metal: failed to create mergeFlattenPipeline: \(error)")
                    self.mergeFlattenPipeline = nil
                }
            } else {
                print("Metal: mergeFlattenCompositeKernel not found in library")
            }
            
            // Store one of the libraries for later use
            self.library = library
            
        } catch {
            print("ERROR: Failed to create Metal library or pipelines: \(error)")
            // Clean up partial state and rethrow
            self.clearPipeline = nil
            self.convertPipeline = nil
            self.distanceFieldMaskPipeline = nil
            self.highQualityAntiAliasPipeline = nil
            self.highQualityStampPipeline = nil
            self.highQualityStampWithNoisePipeline = nil
            self.fxaaPipeline = nil
            self.library = nil
            self.eraserPipeline = nil
            self.segmentPasteLayerAACompositePipeline = nil
            self.segmentPasteLayerNoiseCompositePipeline = nil
            self.segmentCutCompositePipeline = nil
            self.mergeFlattenPipeline = nil
            throw error
        }
        
        // Initialize buffers
        self.stampBuffer = device.makeBuffer(
            length: MemoryLayout<Stamp>.stride * 4096,
            options: .storageModeShared
        )
        
        self.paramsBuffer = device.makeBuffer(
            length: MemoryLayout<Params>.stride,
            options: .storageModeShared
        )
        
        print("Metal renderer initialized successfully")
        print("Clear pipeline status: \(self.clearPipeline != nil)")
        print("Distance field mask pipeline status: \(self.distanceFieldMaskPipeline != nil)")
        print("High-quality anti-alias pipeline status: \(self.highQualityAntiAliasPipeline != nil)")
        print("High-quality stamp pipeline status: \(self.highQualityStampPipeline != nil)")
        print("High-quality stamp with noise pipeline status: \(self.highQualityStampWithNoisePipeline != nil)")
        print("FXAA pipeline status: \(self.fxaaPipeline != nil)")
        print("Eraser pipeline status: \(self.eraserPipeline != nil)")
        print("segmentPasteLayerAAComposite pipeline status: \(self.segmentPasteLayerAACompositePipeline != nil)")
        print("segmentPasteLayerNoiseComposite pipeline status: \(self.segmentPasteLayerNoiseCompositePipeline != nil)")
        print("segmentCutComposite pipeline status: \(self.segmentCutCompositePipeline != nil)")
        print("mergeFlattenPipeline status: \(self.mergeFlattenPipeline != nil)")
    }
}


extension MetalRenderer {
    // MARK: - Render Entry Points
    func renderStrokesInOrderSync(strokeGroups: [(stamps: [Stamp], color: SIMD4<Float>, isEraser: Bool, isMarker: Bool)],
                                  width: Int,
                                  height: Int) throws -> CGImage? {
        // Ensure render targets exist
        try ensureRenderTargets(width: width, height: height)
        
        // Use the regular render target
        guard let target = gpuRenderTarget else {
            throw MetalRendererError.textureCreationFailed
        }
        
        // Clear texture only once at the beginning
        try clearTexture(target)
        
        // Process each stroke group in order
        for (stamps, color, isEraser, isMarker) in strokeGroups {
            if !stamps.isEmpty {
                try renderStampBatchWithBlending(stamps: stamps,
                                                 target: target,
                                                 color: color,
                                                 isEraser: isEraser,
                                                 isMarker: isMarker)
            }
        }
        
        // Apply FXAA if enabled
        if useFXAA {
            applyFXAAAndFinish()
        }
        
        // Convert to 8-bit and read back
        let staging8bit = try convertFloatTextureTo8bitSync(target)
        let result = try readbackToCGImageSync(staging8bit)
        
        return result
    }
    
    /// Renders segment groups sequentially, applies FXAA, and reads back the final CGImage.
    func renderSegmentGroupsInOrderSync(
        layerOps: [LayerOperation],
        width: Int, height: Int,
        artToDevice: CGAffineTransform,
        flipTransform: CGAffineTransform? = nil
    ) throws -> CGImage? {
        
        try renderSegmentGroups(
            layerOps: layerOps,
            width: width, height: height,
            artToDevice: artToDevice,
            flipTransform: flipTransform)
        
        let staging8bit = try convertFloatTextureTo8bitSync(gpuRenderTarget!)
        return try readbackToCGImageSync(staging8bit)
    }
    
    /// Rasterises the layer operations into `gpuRenderTarget` and stops there.
    ///
    /// This is `renderSegmentGroupsInOrderSync` without the 8-bit conversion and the
    /// CPU readback: the live view composites the result on the GPU instead. Callers
    /// must consume/replace `gpuRenderTarget` before issuing the next layer.
    func renderSegmentGroups(
        layerOps: [LayerOperation],
        width: Int, height: Int,
        artToDevice: CGAffineTransform,
        flipTransform: CGAffineTransform? = nil
    ) throws {
        
        try ensureRenderTargets(width: width, height: height)
        guard gpuRenderTarget != nil else {
            throw MetalRendererError.textureCreationFailed
        }
        
        try clearTexture(gpuRenderTarget!)
        openMergeID = nil
        
        for op in layerOps {
            switch op {
                    
                case .stroke(let stroke):
                    try flushMergeFragment()               // strokes hit accumulated target
                    guard let strokeOp = buildOpFromStroke(
                        stroke, artToDevice: artToDevice,
                        flipTransform: flipTransform) else { continue }
                    dispatchStrokeToGPU(
                        segments: strokeOp.segments,
                        color: strokeOp.color,
                        isEraser: strokeOp.isEraser,
                        isMarker: strokeOp.isMarker,
                        width: width, height: height)
                    
                case .cut(let meta):
                    try flushMergeFragment()
                    dispatchCutToGPU(meta: meta, width: width, height: height)
                    
                case .paste(let segments, let color, let isEraser, let isMarker,
                            let meta, let masks, let srcToDst,
                            let isMerge, let mergeID):
                    if isMerge {
                        if let open = openMergeID, open != mergeID {
                            try flushMergeFragment()       // adjacent, different merge
                        }
                        if openMergeID == nil {
                            guard let frag = mergeFragmentTexture else {
                                throw MetalRendererError.textureCreationFailed
                            }
                            try clearTexture(frag)
                            openMergeID = mergeID
                            openMergeOpacity = color.w     // = opacity_src (uniform per merge)
                        }
                        var fullColor = color
                        fullColor.w = 1.0                  // full strength inside the fragment
                        dispatchPasteToGPU(
                            segments: segments, color: fullColor,
                            isEraser: isEraser, isMarker: isMarker,
                            meta: meta, masks: masks,
                            sourceToDestinationGPU: srcToDst,
                            width: width, height: height,
                            target: mergeFragmentTexture)
                    } else {
                        try flushMergeFragment()
                        dispatchPasteToGPU(
                            segments: segments, color: color,
                            isEraser: isEraser, isMarker: isMarker,
                            meta: meta, masks: masks,
                            sourceToDestinationGPU: srcToDst,
                            width: width, height: height)  // nil target → gpuRenderTarget
                    }
            }
        }
        
        try flushMergeFragment()                           // before the caller consumes it
    }
    
    // MARK: - Render Target Lifecycle
    func createRenderTargets(width: Int, height: Int) {
        guard let device = self.device else {
            print("createRenderTargets: device not available")
            return
        }
        
        print("Creating render targets: \(width)x\(height)")
        
        // Use rgba8Unorm format for better alpha handling and CoreGraphics compatibility
        let gpuDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,  // Changed from rgba32Float
            width: width,
            height: height,
            mipmapped: false
        )
        gpuDesc.usage = [.shaderWrite, .shaderRead, .renderTarget]
        gpuDesc.storageMode = .private
        
        // CPU-readable staging texture with proper format
        let stagingDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,  // Changed from rgba32Float
            width: width,
            height: height,
            mipmapped: false
        )
        stagingDesc.usage = [.shaderRead, .shaderWrite]
        stagingDesc.storageMode = .managed
//        stagingDesc.cpuCacheMode = .writeCombined
        
        // Create distance field texture - keep as float for precision
        let distanceFieldDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        distanceFieldDesc.usage = [.shaderRead, .shaderWrite]
        distanceFieldDesc.storageMode = .private
        
        // Create opacity field texture - keep as float for precision
        let opacityFieldDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba32Float,
            width: width,
            height: height,
            mipmapped: false
        )
        opacityFieldDesc.usage = [.shaderRead, .shaderWrite]
        opacityFieldDesc.storageMode = .private
        
        let mergeFragmentDesc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        mergeFragmentDesc.usage = [.shaderWrite, .shaderRead, .renderTarget]
        mergeFragmentDesc.storageMode = .private
        
        self.gpuRenderTarget = device.makeTexture(descriptor: gpuDesc)
        self.stagingTexture = device.makeTexture(descriptor: stagingDesc)
        self.distanceFieldTexture = device.makeTexture(descriptor: distanceFieldDesc)
        self.opacityFieldTexture = device.makeTexture(descriptor: opacityFieldDesc)
        self.mergeFragmentTexture = device.makeTexture(descriptor: mergeFragmentDesc)
        
        if let gpu = self.gpuRenderTarget {
            print("DEBUG: gpuRenderTarget created: \(gpu.width)x\(gpu.height), format=\(gpu.pixelFormat.rawValue)")
        } else {
            print("DEBUG: gpuRenderTarget creation failed")
        }
        
        if let staging = self.stagingTexture {
            print("DEBUG: stagingTexture created: \(staging.width)x\(staging.height), format=\(staging.pixelFormat.rawValue)")
        } else {
            print("DEBUG: stagingTexture creation failed")
        }
        
        if let distanceField = self.distanceFieldTexture {
            print("DEBUG: distanceFieldTexture created: \(distanceField.width)x\(distanceField.height), format=\(distanceField.pixelFormat.rawValue)")
        } else {
            print("DEBUG: distanceFieldTexture creation failed")
        }
        
        if let opacityField = self.opacityFieldTexture {
            print("DEBUG: opacityFieldTexture created: \(opacityField.width)x\(opacityField.height), format=\(opacityField.pixelFormat.rawValue)")
        } else {
            print("DEBUG: opacityFieldTexture creation failed")
        }
        
        if let mergeFragment = self.mergeFragmentTexture {
            print("DEBUG: mergeFragmentTexture created: \(mergeFragment.width)x\(mergeFragment.height), format=\(mergeFragment.pixelFormat.rawValue)")
        } else {
            print("DEBUG: mergeFragmentTexture creation failed")
        }
    }
    
    /// Ensure render targets exist for the specified dimensions
    func ensureRenderTargets(width: Int, height: Int) throws {
        guard device != nil else {
            throw MetalRendererError.deviceNotAvailable
        }
        
        // Check if we need to recreate textures
        let recreate = gpuRenderTarget == nil ||
        stagingTexture == nil ||
        distanceFieldTexture == nil ||
        opacityFieldTexture == nil ||
        gpuRenderTarget?.width != width ||
        gpuRenderTarget?.height != height
        
        if recreate {
            print("Creating render targets: \(width)x\(height)")
            
            // Call the updated createRenderTargets function
            createRenderTargets(width: width, height: height)
            
            if gpuRenderTarget == nil || stagingTexture == nil ||
                distanceFieldTexture == nil || opacityFieldTexture == nil {
                throw MetalRendererError.textureCreationFailed
            }
            
            print("Created render targets successfully")
            
            if let rt = gpuRenderTarget,
               mergeFragmentTexture == nil ||
                mergeFragmentTexture!.width != width ||
                mergeFragmentTexture!.height != height ||
                mergeFragmentTexture!.pixelFormat != rt.pixelFormat {
                let d = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: rt.pixelFormat,
                    width: width, height: height, mipmapped: false)
                d.usage = [.shaderRead, .shaderWrite]      // required for read_write kernels
                d.storageMode = rt.storageMode
                mergeFragmentTexture = device?.makeTexture(descriptor: d)
                openMergeID = nil
            }
            if mergeFragmentTexture == nil {
                throw MetalRendererError.textureCreationFailed
            }
        }
    }
    
    /// Clear texture to transparent - works with both regular and MSAA textures
    func clearTexture(_ texture: MTLTexture) throws {
        guard let clearPipeline = clearPipeline,
              let commandQueue = commandQueue else {
            print("Warning: No clear pipeline available, skipping texture clear")
            return
        }
        
        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            throw MetalRendererError.commandBufferCreationFailed
        }
        
        guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
            throw MetalRendererError.commandBufferCreationFailed
        }
        
        computeEncoder.setComputePipelineState(clearPipeline)
        computeEncoder.setTexture(texture, index: 0)
        
        let threadGroupSize = MTLSize(width: 8, height: 8, depth: 1)
        let threadGroupCount = MTLSize(
            width: (texture.width + threadGroupSize.width - 1) / threadGroupSize.width,
            height: (texture.height + threadGroupSize.height - 1) / threadGroupSize.height,
            depth: 1
        )
        
        computeEncoder.dispatchThreadgroups(threadGroupCount, threadsPerThreadgroup: threadGroupSize)
        computeEncoder.endEncoding()
        
        commandBuffer.commit()
        
        if let err = commandBuffer.error {
            print("Metal command buffer error: \(err)")
        }
    }
    
    private func flushMergeFragment() throws {
        guard openMergeID != nil else { return }
        openMergeID = nil
        guard let frag = mergeFragmentTexture,
              let target = gpuRenderTarget,
              let pipeline = mergeFlattenPipeline,
              let cb = commandQueue?.makeCommandBuffer(),
              let enc = cb.makeComputeCommandEncoder() else { return }
        
        var opacity = openMergeOpacity
        enc.setComputePipelineState(pipeline)
        enc.setTexture(frag, index: 0)
        enc.setTexture(target, index: 1)
        enc.setBytes(&opacity, length: MemoryLayout<Float>.stride, index: 0)
        
        let tg = MTLSize(width: 8, height: 8, depth: 1)
        let groups = MTLSize(width: (target.width + 7) / 8,
                             height: (target.height + 7) / 8, depth: 1)
        enc.dispatchThreadgroups(groups, threadsPerThreadgroup: tg)
        enc.endEncoding()
        cb.commit()
        cb.waitUntilCompleted()
        if let err = cb.error { throw err }
    }
    
    /// Run FXAA compute pass reading from gpuRenderTarget (float RGBA) and writing into stagingTexture.
    /// This is synchronous (waitUntilCompleted) convenience; you can call commandBuffer.commit() yourself if you prefer async.
    func applyFXAAAndFinish() {
        guard useFXAA else { return }
        //        guard let device = self.device,
        guard let queue = self.commandQueue,
              let fxaa = self.fxaaPipeline,
              let src = self.gpuRenderTarget,
              let dst = self.stagingTexture else {
            return
        }
        
        guard let commandBuffer = queue.makeCommandBuffer(),
              let encoder = commandBuffer.makeComputeCommandEncoder() else { return }
        
        encoder.setComputePipelineState(fxaa)
        encoder.setTexture(src, index: 0)
        encoder.setTexture(dst, index: 1)
        
        if let samp = self.linearSampler {
            encoder.setSamplerState(samp, index: 0)
        }
        
        let w = fxaa.threadExecutionWidth
        let h = max(1, fxaa.maxTotalThreadsPerThreadgroup / w)
        let threadsPerThreadgroup = MTLSize(width: w, height: h, depth: 1)
        let threadgroups = MTLSize(
            width: (src.width + threadsPerThreadgroup.width - 1) / threadsPerThreadgroup.width,
            height: (src.height + threadsPerThreadgroup.height - 1) / threadsPerThreadgroup.height,
            depth: 1
        )
        
        encoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
    }
}
    
// MARK: - Metal Errors
enum MetalRendererError: Error, LocalizedError {
    case deviceNotAvailable
    case libraryCreationFailed
    case functionNotFound(String)
    case pipelineCreationFailed(Error)
    case samplerCreationFailed
    case textureCreationFailed
    case noiseTextureNotAvailable
    case gpuRenderingDisabled
    case commandBufferCreationFailed
    case computeEncoderCreationFailed
    case bufferCreationFailed
    case rendererNotInitialized
    case bundleNotFound
    case metalFileNotFound
    case metalCompilationFailed(Error)
    case invalidStampData
    case invalidTileData
    case commandQueueMissing
    case pipelineMissing(String)
    case invalidTextureFormat
    case invalidTextureRegion
    case bufferAccessFailed
    case shaderFileNotFound(String)
    case unsupportedDrawable
    
    var errorDescription: String? {
        switch self {
            case .deviceNotAvailable:
                return "Metal device not available"
            case .libraryCreationFailed:
                return "Failed to create Metal library"
            case .functionNotFound(let name):
                return "Function '\(name)' not found in Metal library"
            case .pipelineCreationFailed(let error):
                return "Failed to create compute pipeline: \(error.localizedDescription)"
            case .samplerCreationFailed:
                return "Failed to create sampler state"
            case .textureCreationFailed:
                return "Failed to create texture"
            case .noiseTextureNotAvailable:
                return "Noise texture not available"
            case .gpuRenderingDisabled:
                return "GPU rendering is disabled"
            case .commandBufferCreationFailed:
                return "Failed to create command buffer"
            case .computeEncoderCreationFailed:
                return "Failed to create compute encoder"
            case .bufferCreationFailed:
                return "Failed to create buffer"
            case .rendererNotInitialized:
                return "Metal renderer not properly initialized"
            case .bundleNotFound:
                return "SwiftPM bundle not found"
            case .metalFileNotFound:
                return "Metal shader file not found in bundle"
            case .metalCompilationFailed(let error):
                return "Metal shader compilation failed: \(error.localizedDescription)"
            case .invalidStampData:
                return "Invalid stamp data"
            case .invalidTileData:
                return "Invalid tile data"
            case .commandQueueMissing:
                return "Command queue missing"
            case .pipelineMissing(let name):
                return "'\(name)' pipeline not found"
            case .invalidTextureFormat:
                return "invalidTextureFormat"
            case .invalidTextureRegion:
                return "invalidTextureRegion"
            case .bufferAccessFailed:
                return "bufferAccessFailed"
            case .shaderFileNotFound(let name):
                return "⚠︎ \(name) not found."
            case .unsupportedDrawable:
                return "unsupportedDrawable"
        }
    }
}
#endif
