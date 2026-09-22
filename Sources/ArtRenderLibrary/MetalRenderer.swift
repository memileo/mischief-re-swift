// Requirements: macOS 12 compatibility - Swift 5.7, Metal 2
#if os(macOS)
import Metal
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
    
    // CPU-readable staging texture (shared storage) used for readback after blit
    private(set) var stagingTexture: MTLTexture?
    
    // Samplers
    internal let linearSampler: MTLSamplerState?
    
    // Configuration
    internal let tileSize = 64  // Coarse tile size for spatial indexing
    
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
        
        try flushMergeFragment()                           // before readback
        
        let staging8bit = try convertFloatTextureTo8bitSync(gpuRenderTarget!)
        return try readbackToCGImageSync(staging8bit)
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
        stagingDesc.storageMode = .shared
        
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
        }
    }
}
#endif
