// Requirements: macOS 12 compatibility - Swift 5.7, Metal 2
#if os(macOS)
import Metal
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

// MARK: - Data Structures

/// Represents a single stamp for GPU processing
/// Mirrored in Metal shader for memory layout compatibility
struct Stamp {
    var center: SIMD2<Float>
    var radius: Float
    var opacity: Float
    var rotation: Float
    var noiseSeed: UInt32
    
    init(center: SIMD2<Float>, radius: Float, opacity: Float, rotation: Float, noiseSeed: UInt32) {
        self.center = center
        self.radius = radius
        self.opacity = opacity
        self.rotation = rotation
        self.noiseSeed = noiseSeed
    }
}

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

// MARK: - Metal Renderer Implementation

/// Metal-accelerated renderer for stamp-based brush strokes
class MetalRenderer {
    // MARK: - Properties
    
    public let device: MTLDevice?
    public let commandQueue: MTLCommandQueue?
    private var library: MTLLibrary?
    
    // Compute pipelines
    private var clearPipeline: MTLComputePipelineState?
    private var convertPipeline: MTLRenderPipelineState?
    private var fxaaPipeline: MTLComputePipelineState?
    public var useFXAA: Bool = false    // ö
    private var eraserPipeline: MTLComputePipelineState?
    
    // Pipelines for high-quality two-pass rendering
    private var distanceFieldMaskPipeline: MTLComputePipelineState?
    private var highQualityAntiAliasPipeline: MTLComputePipelineState?
    
    // Segment pipeline
    private var segmentSDFPipeline: MTLComputePipelineState?
    private var segmentNoiseCompositePipeline: MTLComputePipelineState?
    private var segmentAACompositePipeline: MTLComputePipelineState?
    private var segmentBuffer: MTLBuffer?
    
    // High-quality stamp pipeline
    private var highQualityStampPipeline: MTLComputePipelineState?
    private var highQualityStampWithNoisePipeline: MTLComputePipelineState?
    
    // Render pipeline for MSAA stamp rendering
//    private var stampRenderPipeline: MTLRenderPipelineState? // unused?
    
    // Textures and buffers
    private var noiseTexture: MTLTexture?
    private var stampBuffer: MTLBuffer?
//    private var tileIndexBuffer: MTLBuffer? // unused?
    private var paramsBuffer: MTLBuffer?
    
    // Intermediate textures for two-pass rendering
    private var distanceFieldTexture: MTLTexture?
    private var opacityFieldTexture: MTLTexture?
    
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
    private let linearSampler: MTLSamplerState?
    
    // Configuration
    private let tileSize = 64  // Coarse tile size for spatial indexing
    
    private var tileIndicesBuffer: MTLBuffer?
    private var tileListBuffer: MTLBuffer?
    
    // NEW: Timing measurements for performance analysis
//    private var timingMeasurements: [String: TimeInterval] = [:] // unused?
    
    // MARK: - Static Properties
    
    /// Check if Metal is supported on this device
    static var isSupported: Bool {
        return MTLCreateSystemDefaultDevice() != nil
    }
    
    static var useGPURendering = true
    
    // MARK: - Initialization
    
    init(device: MTLDevice? = nil, library: MTLLibrary? = nil) throws {
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
            
            // Segment distance field mask pipeline
            if let segmentSDFFn = library.makeFunction(name: "segmentSDFMaskKernel") {
                do {
                    self.segmentSDFPipeline = try device.makeComputePipelineState(function: segmentSDFFn)
                    print("Metal: segmentSDFMaskKernel pipeline created")
                } catch {
                    print("Metal: failed to create segmentSDFMaskPipeline: \(error)")
                    self.segmentSDFPipeline = nil
                }
            } else {
                print("Metal: segmentSDFMaskKernel not found in library")
            }
            
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
    }
    // MARK: - SwiftPM Helper Methods
    
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
        
        self.gpuRenderTarget = device.makeTexture(descriptor: gpuDesc)
        self.stagingTexture = device.makeTexture(descriptor: stagingDesc)
        self.distanceFieldTexture = device.makeTexture(descriptor: distanceFieldDesc)
        self.opacityFieldTexture = device.makeTexture(descriptor: opacityFieldDesc)
        
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
    }

    /// Upload noise atlas from bundle resource
//    func uploadNoiseAtlas(image: CGImage) throws {
//        guard let device = device else {
//            throw MetalRendererError.deviceNotAvailable
//        }
//
//        guard let texture = Self.createTexture(from: image, device: device) else {
//            throw MetalRendererError.textureCreationFailed
//        }
//
//        noiseTexture = texture
//    }
    
    /// Load noise image from SwiftPM bundle resources
    private static func loadNoiseImageFromBundle() -> CGImage? {
        let bundleURL = Bundle.module.bundleURL
        guard let bundle = Bundle(url: bundleURL) else {
            return nil
        }
        
        let possibleNames = [
            "noise",
            "noise.png",
            "Noise",
            "Noise.png"
        ]
        
        let possibleSubdirectories = [
            "",
            "Resources",
            "Shaders"
        ]
        
        for subdirectory in possibleSubdirectories {
            for name in possibleNames {
                if let url = bundle.url(forResource: name, withExtension: nil, subdirectory: subdirectory),
                   let dataProvider = CGDataProvider(url: url as CFURL),
                   let image = CGImage(
                    jpegDataProviderSource: dataProvider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent
                   ) ?? CGImage(
                    pngDataProviderSource: dataProvider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent
                   ) {
                    return image
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Public API
    
    /// Render a batch of stamps to target texture using mask-based approach
//    func stampBatchToTexture(stamps: [Stamp], target: MTLTexture, color: SIMD4<Float>) throws {
//        guard MetalRenderer.useGPURendering else {
//            throw MetalRendererError.rendererNotInitialized
//        }
//        guard stamps.count > 0 else { return }
//
//        guard let device = self.device else {
//            throw MetalRendererError.deviceNotAvailable
//        }
//        guard let commandQueue = self.commandQueue else {
//            throw MetalRendererError.commandQueueMissing
//        }
//
//        // Validate stamp data
//        for s in stamps {
//            if !s.center.x.isFinite || !s.center.y.isFinite || !s.radius.isFinite || s.radius <= 0 {
//                throw MetalRendererError.invalidStampData
//            }
//        }
//
//        // Ensure stampBuffer capacity
//        let stampStride = MemoryLayout<Stamp>.stride
//        let neededStampBytes = stampStride * stamps.count
//        if stampBuffer == nil || stampBuffer!.length < neededStampBytes {
//            stampBuffer = device.makeBuffer(length: neededStampBytes, options: .storageModeShared)
//            if stampBuffer == nil {
//                throw MetalRendererError.textureCreationFailed
//            }
//        }
//
//        // Copy stamps into stampBuffer
//        if let sb = stampBuffer {
//            let dst = sb.contents().assumingMemoryBound(to: Stamp.self)
//            dst.assign(from: stamps, count: stamps.count)
//        } else {
//            throw MetalRendererError.rendererNotInitialized
//        }
//
//        // Ensure paramsBuffer exists
//        if paramsBuffer == nil {
//            paramsBuffer = device.makeBuffer(length: MemoryLayout<Params>.stride, options: .storageModeShared)
//            if paramsBuffer == nil { throw MetalRendererError.rendererNotInitialized }
//        }
//
//        // Build Params
//        let params = Params(
//            textureWidth: UInt32(target.width),
//            textureHeight: UInt32(target.height),
//            tileSize: UInt32(32),
//            tilesPerRow: (UInt32(target.width) + UInt32(32) - 1) / UInt32(32),
//            stampCount: UInt32(stamps.count),
//            penColor: color,
//            noiseScale: 1.0,
//            isEraser: false
//        )
//
//        // Upload params
//        if let pb = paramsBuffer {
//            let pptr = pb.contents().assumingMemoryBound(to: Params.self)
//            pptr.pointee = params
//        }
//
//        // Create command buffer
//        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
//            throw MetalRendererError.commandBufferCreationFailed
//        }
//
//        // Determine whether any stamp has noise
//        var hasNoise = false
//        for s in stamps {
//            if s.noiseSeed != 0 { hasNoise = true; break }
//        }
//
//        // Choose rendering approach based on available pipelines and noise presence
//        // First check for noise pipeline if there's noise
//        if hasNoise, let pipeline = self.highQualityStampWithNoisePipeline, let noiseTex = self.noiseTexture {
//            // High-quality single-pass approach with noise
//            print("Using high-quality single-pass stamp rendering approach with noise")
//
//            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
//                throw MetalRendererError.commandBufferCreationFailed
//            }
//
//            // set paramsBuffer, stampBuffer as before
//            encoder.setComputePipelineState(pipeline)
//            if let pb = paramsBuffer { encoder.setBuffer(pb, offset: 0, index: 0) }
//            if let sb = stampBuffer { encoder.setBuffer(sb, offset: 0, index: 1) }
//            encoder.setTexture(target, index: 0)
//            encoder.setTexture(noiseTex, index: 1)
//            encoder.setSamplerState(self.linearSampler, index: 0)
//
//            let threadGroupSize = MTLSize(width: 8, height: 8, depth: 1)
//            let threadGroupCount = MTLSize(
//                width: (target.width + threadGroupSize.width - 1) / threadGroupSize.width,
//                height: (target.height + threadGroupSize.height - 1) / threadGroupSize.height,
//                depth: 1
//            )
//
//            encoder.dispatchThreadgroups(threadGroupCount, threadsPerThreadgroup: threadGroupSize)
//            encoder.endEncoding()
//
//        } else if let distanceFieldPipeline = self.distanceFieldMaskPipeline,
//                  let antiAliasPipeline = self.highQualityAntiAliasPipeline,
//                  let distanceFieldTexture = self.distanceFieldTexture,
//                  let opacityFieldTexture = self.opacityFieldTexture {
//
//            // High-quality two-pass approach using distance fields
//            print("Using high-quality two-pass stamp rendering approach with distance fields")
//
//            // First pass: create distance field and opacity field
//            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
//                throw MetalRendererError.commandBufferCreationFailed
//            }
//
//            encoder.setComputePipelineState(distanceFieldPipeline)
//            if let pb = paramsBuffer { encoder.setBuffer(pb, offset: 0, index: 0) }
//            if let sb = stampBuffer { encoder.setBuffer(sb, offset: 0, index: 1) }
//            encoder.setTexture(distanceFieldTexture, index: 0)
//            encoder.setTexture(opacityFieldTexture, index: 1)
//
//            let threadGroupSize = MTLSize(width: 8, height: 8, depth: 1)
//            let threadGroupCount = MTLSize(
//                width: (target.width + threadGroupSize.width - 1) / threadGroupSize.width,
//                height: (target.height + threadGroupSize.height - 1) / threadGroupSize.height,
//                depth: 1
//            )
//
//            encoder.dispatchThreadgroups(threadGroupCount, threadsPerThreadgroup: threadGroupSize)
//            encoder.endEncoding()
//
//            // Second pass: apply high-quality anti-aliasing
//            guard let colorEncoder = commandBuffer.makeComputeCommandEncoder() else {
//                throw MetalRendererError.commandBufferCreationFailed
//            }
//
//            // Create a buffer for the pen color
//            let colorBuffer = device.makeBuffer(length: MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared)
//            if let cb = colorBuffer {
//                let cptr = cb.contents().assumingMemoryBound(to: SIMD4<Float>.self)
//                cptr.pointee = color
//            }
//
//            colorEncoder.setComputePipelineState(antiAliasPipeline)
//            colorEncoder.setTexture(distanceFieldTexture, index: 0)
//            colorEncoder.setTexture(opacityFieldTexture, index: 1)
//            colorEncoder.setTexture(target, index: 2)
//            if let cb = colorBuffer { colorEncoder.setBuffer(cb, offset: 0, index: 0) }
//
//            let colorThreadGroupSize = MTLSize(width: 8, height: 8, depth: 1)
//            let colorThreadGroupCount = MTLSize(
//                width: (target.width + colorThreadGroupSize.width - 1) / colorThreadGroupSize.width,
//                height: (target.height + colorThreadGroupSize.height - 1) / colorThreadGroupSize.height,
//                depth: 1
//            )
//
//            colorEncoder.dispatchThreadgroups(colorThreadGroupCount, threadsPerThreadgroup: colorThreadGroupSize)
//            colorEncoder.endEncoding()
//
//        } else if let highQualityPipeline = self.highQualityStampPipeline {
//            // High-quality single-pass approach (no noise)
//            print("Using high-quality single-pass stamp rendering approach")
//
//            guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
//                throw MetalRendererError.commandBufferCreationFailed
//            }
//
//            encoder.setComputePipelineState(highQualityPipeline)
//            if let pb = paramsBuffer { encoder.setBuffer(pb, offset: 0, index: 0) }
//            if let sb = stampBuffer { encoder.setBuffer(sb, offset: 0, index: 1) }
//            encoder.setTexture(target, index: 0)
//
//            let threadGroupSize = MTLSize(width: 8, height: 8, depth: 1)
//            let threadGroupCount = MTLSize(
//                width: (target.width + threadGroupSize.width - 1) / threadGroupSize.width,
//                height: (target.height + threadGroupSize.height - 1) / threadGroupSize.height,
//                depth: 1
//            )
//
//            encoder.dispatchThreadgroups(threadGroupCount, threadsPerThreadgroup: threadGroupSize)
//            encoder.endEncoding()
//
//        } else {
//            throw MetalRendererError.pipelineMissing("stamp rendering")
//        }
//
//        // Copy to staging texture if it exists
//        if let staging = self.stagingTexture {
//            if let blit = commandBuffer.makeBlitCommandEncoder() {
//                let origin = MTLOrigin(x: 0, y: 0, z: 0)
//                let size = MTLSize(width: target.width, height: target.height, depth: 1)
//                blit.copy(from: target,
//                          sourceSlice: 0, sourceLevel: 0,
//                          sourceOrigin: origin, sourceSize: size,
//                          to: staging,
//                          destinationSlice: 0, destinationLevel: 0,
//                          destinationOrigin: origin)
//                blit.endEncoding()
//            }
//        }
//
//        // Commit and wait
//        commandBuffer.commit()
//        commandBuffer.waitUntilCompleted()
//
//        if let err = commandBuffer.error {
//            print("stampBatchToTexture: command buffer error: \(err)")
//            throw err
//        } else {
//            print("MetalRenderer: stampBatchToTexture with high-quality approach completed")
//        }
//    }
    
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
    
    /// Synchronously render strokes and return a CGImage // unused? metal path uses renderStrokesInOrderSync
//    func renderStrokesSync(stamps: [Stamp], width: Int, height: Int, color: SIMD4<Float>) throws -> CGImage? {
//        // Ensure render targets exist
//        try ensureRenderTargets(width: width, height: height)
//
//        // Use the regular render target
//        guard let target = gpuRenderTarget else {
//            throw MetalRendererError.textureCreationFailed
//        }
//
//        // Clear texture
//        try clearTexture(target)
//
//        // Render stamps with high-quality two-pass approach
//        try stampBatchToTexture(stamps: stamps, target: target, color: color)
//
//        // Apply FXAA if enabled
//        if useFXAA {
//            applyFXAAAndFinish()
//        }
//
//        // Convert to 8-bit and read back
//        let staging8bit = try convertFloatTextureTo8bitSync(target)
//        let result = try readbackToCGImageSync(staging8bit)
//
//        return result
//    }
        
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
    
    private func renderStampBatchWithBlending(stamps: [Stamp],
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

    
    /// Renders segment groups sequentially, applies FXAA, and reads back the final CGImage.
    func renderSegmentGroupsInOrderSync(
        segmentGroups: [(segments: [GPUSplineSegment], color: SIMD4<Float>, isEraser: Bool, isMarker: Bool)],
        width: Int,
        height: Int
    ) throws -> CGImage? {
        
        // Ensure render targets exist for the specified dimensions
        try ensureRenderTargets(width: width, height: height)
        
        // The target is your gpuRenderTarget
        guard let target = gpuRenderTarget else {
            throw MetalRendererError.textureCreationFailed
        }
        
        // Clear texture only once at the beginning
        try clearTexture(target)
        
        let segmentStride = MemoryLayout<GPUSplineSegment>.stride
        
        // Process each stroke group in order
        for (segments, color, isEraser, isMarker) in segmentGroups {
            if segments.isEmpty { continue }
            
            // Create a dedicated command buffer PER stroke group to prevent data races
            guard let commandBuffer = commandQueue?.makeCommandBuffer() else {
                throw MetalRendererError.commandBufferCreationFailed
            }
            
            // --- 1. Buffer Allocation & Upload ---
            let neededBytes = segmentStride * segments.count
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
                textureWidth: UInt32(width),
                textureHeight: UInt32(height),
                tileSize: UInt32(tileSize),
                tilesPerRow: (UInt32(width) + UInt32(tileSize) - 1) / UInt32(tileSize),
                stampCount: UInt32(segments.count),
                penColor: color,
                noiseScale: 0.4,
                isEraser: isEraser,
                isMarker: isMarker
            )
            if let pb = paramsBuffer {
                let pptr = pb.contents().assumingMemoryBound(to: Params.self)
                pptr.pointee = params
            }
            
            // --- 2. Tile Indexing ---
            let (tileIndicesData, tileListData) = buildSegmentTileIndices(
                segments: segments,
                textureWidth: width,
                textureHeight: height,
                tileSize: tileSize,
                isMarker: isMarker
            )
            
            if tileListData.isEmpty { continue }
            
            let indicesBytes = MemoryLayout<TileIndex>.stride * tileIndicesData.count
            let listBytes = MemoryLayout<UInt32>.stride * tileListData.count
            
            // Reuse tileIndicesBuffer if large enough, otherwise recreate
            if tileIndicesBuffer == nil || tileIndicesBuffer!.length < indicesBytes {
                tileIndicesBuffer = device?.makeBuffer(length: indicesBytes, options: .storageModeShared)
            }
            if tileListBuffer == nil || tileListBuffer!.length < listBytes {
                tileListBuffer = device?.makeBuffer(length: listBytes, options: .storageModeShared)
            }
            
            guard let tib = tileIndicesBuffer, let tlb = tileListBuffer else {
                throw MetalRendererError.bufferCreationFailed
            }
            
            // CRITICAL FIX: Zero out the buffers to prevent stale out-of-bounds reads!
            memset(tib.contents(), 0, tib.length)
            memset(tlb.contents(), 0, tlb.length)
            
            memcpy(tib.contents(), tileIndicesData, indicesBytes)
            memcpy(tlb.contents(), tileListData, listBytes)
            
            // --- 3. Composite Pass (SDF + AA or SDF + Noise merged) ---
            let hasNoise = segments.contains { $0.noiseSeed != 0 }
            
            if let encoder = commandBuffer.makeComputeCommandEncoder() {
                if hasNoise,
                   let noisePipeline = self.segmentNoiseCompositePipeline,
                   let noiseTex = self.noiseTexture {
                    
                    // Noise Path
                    encoder.setComputePipelineState(noisePipeline)
                    encoder.setBuffer(paramsBuffer, offset: 0, index: 0)
                    encoder.setBuffer(segmentBuffer, offset: 0, index: 1)
                    encoder.setBuffer(tileIndicesBuffer, offset: 0, index: 2)
                    encoder.setBuffer(tileListBuffer, offset: 0, index: 3)
                    
                    encoder.setTexture(target, index: 0)
                    encoder.setTexture(noiseTex, index: 1)
                    if let samp = self.linearSampler { encoder.setSamplerState(samp, index: 0) }
                    
                } else if let aaPipeline = self.segmentAACompositePipeline {
                    // Standard Hard Stroke AA Path
                    encoder.setComputePipelineState(aaPipeline)
                    encoder.setBuffer(paramsBuffer, offset: 0, index: 0)
                    encoder.setBuffer(segmentBuffer, offset: 0, index: 1)
                    encoder.setBuffer(tileIndicesBuffer, offset: 0, index: 2)
                    encoder.setBuffer(tileListBuffer, offset: 0, index: 3)
                    
                    encoder.setTexture(target, index: 0)
                }
                
                let threadGroupSize = MTLSize(width: 8, height: 8, depth: 1)
                let threadGroupCount = MTLSize(
                    width: (width + threadGroupSize.width - 1) / threadGroupSize.width,
                    height: (height + threadGroupSize.height - 1) / threadGroupSize.height,
                    depth: 1
                )
                encoder.dispatchThreadgroups(threadGroupCount, threadsPerThreadgroup: threadGroupSize)
                encoder.endEncoding()
            }
            
            // --- Commit and wait for THIS stroke group before proceeding to the next ---
            commandBuffer.commit()
            commandBuffer.waitUntilCompleted()
            
            if let err = commandBuffer.error {
                print("renderSegmentGroupsInOrderSync: command buffer error: \(err)")
                throw err
            }
        }
        
        // Apply FXAA if enabled
//        if useFXAA {
//            applyFXAAAndFinish()
//        }
        
        // Convert to 8-bit and read back
        let staging8bit = try convertFloatTextureTo8bitSync(target)
        let result = try readbackToCGImageSync(staging8bit)
        
        return result
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

    
    // MARK: - Private Methods
    
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
    /*
     ===============================================================================
     FUTURE REFERENCE: MOVING TO A METAL COMPUTE SHADER
     ===============================================================================
     If you switch to an interactive live view with real-time zooming and panning,
     this CPU approach will bottleneck your frame rate. To drop the time down to <1ms,
     handle this architecture entirely on the GPU.
     
     --- SWIFT SIDE ---
     1. Pass your `stamps` array buffer directly to a Metal Compute Pipeline.
     2. Pass an empty buffer for `tileCounts` (size: totalTiles * sizeof(atomic_uint)).
     3. Pass an empty buffer for `tileListData` (size: worst-case maximum size).
     
     
     --- METAL KERNEL SIDE (.metal) ---
     kernel void binStamps(device const Stamp* stamps       [[buffer(0)]],
     device atomic_uint* tileCounts   [[buffer(1)]],
     device uint* tileListData        [[buffer(2)]],
     device TileIndex* tileIndices    [[buffer(3)]],
     uint id                          [[thread_position_in_grid]])
     {
     // 1. Thread per stamp calculates its tile bounds (startTileX, endTileX, etc.)
     // 2. Loop through overlapping tiles:
     //    uint tileIdx = ty * tilesX + tx;
     // 3. Use atomic operations to safely write indices concurrently:
     //    uint internalOffset = atomic_fetch_add_explicit(&tileCounts[tileIdx], 1, memory_order_relaxed);
     // 4. Calculate final placement using global offsets or a separate prefix-sum kernel pass.
     }
     ===============================================================================
     */
    
    // New Tile Indexing for Segments
    func buildSegmentTileIndices(
        segments: [GPUSplineSegment],
        textureWidth: Int,
        textureHeight: Int,
        tileSize: Int,
        isMarker: Bool = false
    ) -> ([TileIndex], [UInt32]) {
        let tilesPerRow = (textureWidth + tileSize - 1) / tileSize
        let tilesPerCol = (textureHeight + tileSize - 1) / tileSize
        let numTiles = tilesPerRow * tilesPerCol
        
        var tileCounts = [UInt32](repeating: 0, count: numTiles)
        let invTileSize = 1.0 / Float(tileSize)
        
        // Marker capsule extends ±4r along the 45° axis from each spline point.
        // Projection onto x/y ≈ ±2√2·r, plus the radius itself for thickness.
        // Total padding ≈ (1 + 2√2) · maxRadius ≈ 3.83 · maxRadius.
        let paddingScale: Float = isMarker ? (1.0 + 2.0 * sqrt(2.0)) : 1.4 // extra padding for noise strokes 1.4 from 1.0, not sure if needed
        
        // --- PASS 1: Count overlaps per tile ---
        for seg in segments {
            let maxRadius = max(seg.radius0, seg.radius1)
            let padding = (maxRadius * paddingScale) + 1.0 // Added +1.0 for AA. Might not be needed
            
            let minX = min(seg.p1.x, seg.p2.x) - padding
            let maxX = max(seg.p1.x, seg.p2.x) + padding
            let minY = min(seg.p1.y, seg.p2.y) - padding
            let maxY = max(seg.p1.y, seg.p2.y) + padding
            
            if maxX < 0.0 || minX > Float(textureWidth) ||
                maxY < 0.0 || minY > Float(textureHeight) { continue }
            
            let minTileX = max(0, Int(minX * invTileSize))
            let maxTileX = min(tilesPerRow - 1, Int(maxX * invTileSize))
            let minTileY = max(0, Int(minY * invTileSize))
            let maxTileY = min(tilesPerCol - 1, Int(maxY * invTileSize))
            
            guard minTileX <= maxTileX && minTileY <= maxTileY else { continue }
            
            for ty in minTileY...maxTileY {
                for tx in minTileX...maxTileX {
                    tileCounts[ty * tilesPerRow + tx] += 1
                }
            }
        }
        
        // --- PREFIX SUM ---
        var tileIndices = [TileIndex](repeating: TileIndex(start: 0, count: 0),
                                      count: numTiles)
        var currentStart: UInt32 = 0
        for i in 0..<numTiles {
            tileIndices[i].start = currentStart
            currentStart += tileCounts[i]
        }
        
        // --- PASS 2: Populate ---
        var tileList = [UInt32](repeating: 0, count: Int(currentStart))
        var writeHeads = [UInt32](repeating: 0, count: numTiles)
        
        for (i, seg) in segments.enumerated() {
            let maxRadius = max(seg.radius0, seg.radius1)
            let padding = (maxRadius * paddingScale) + 1.0 // Added +1.0 for AA. Might not be needed
            
            let minX = min(seg.p1.x, seg.p2.x) - padding
            let maxX = max(seg.p1.x, seg.p2.x) + padding
            let minY = min(seg.p1.y, seg.p2.y) - padding
            let maxY = max(seg.p1.y, seg.p2.y) + padding
            
            if maxX < 0.0 || minX > Float(textureWidth) ||
                maxY < 0.0 || minY > Float(textureHeight) { continue }
            
            let minTileX = max(0, Int(minX * invTileSize))
            let maxTileX = min(tilesPerRow - 1, Int(maxX * invTileSize))
            let minTileY = max(0, Int(minY * invTileSize))
            let maxTileY = min(tilesPerCol - 1, Int(maxY * invTileSize))
            
            guard minTileX <= maxTileX && minTileY <= maxTileY else { continue }
            
            for ty in minTileY...maxTileY {
                for tx in minTileX...maxTileX {
                    let tileIdx = ty * tilesPerRow + tx
                    let writePos = Int(tileIndices[tileIdx].start + writeHeads[tileIdx])
                    tileList[writePos] = UInt32(i)
                    writeHeads[tileIdx] += 1
                }
            }
        }
        
        for i in 0..<numTiles {
            tileIndices[i].count = writeHeads[i]
        }
        
        return (tileIndices, tileList)
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
        }
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
    
    // MARK: - Static Helper Methods
    
    /// Create MTLTexture from CGImage
//    static func createTexture(from image: CGImage, device: MTLDevice) -> MTLTexture? { // unused?
//        let width = image.width
//        let height = image.height
//
//        // For noise texture, use r8Unorm format // Would using rgba8Unorm_srgb fix the gamma/washed out issue?
//        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
//            pixelFormat: .r8Unorm,
//            width: width,
//            height: height,
//            mipmapped: false
//        )
//
//        textureDescriptor.usage = [.shaderRead]
//        textureDescriptor.storageMode = .shared
//
//        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
//            return nil
//        }
//
//        let colorSpace = CGColorSpace(name: CGColorSpace.linearGray)!
//        let bytesPerRow = width
//        let bitmapInfo = CGImageAlphaInfo.none.rawValue
//
//        guard let context = CGContext(
//            data: nil,
//            width: width,
//            height: height,
//            bitsPerComponent: 8,
//            bytesPerRow: bytesPerRow,
//            space: colorSpace,
//            bitmapInfo: bitmapInfo
//        ) else {
//            return nil
//        }
//
//        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
//
//        guard let data = context.data else {
//            return nil
//        }
//
//        let region = MTLRegionMake2D(0, 0, width, height)
//        texture.replace(
//            region: region,
//            mipmapLevel: 0,
//            withBytes: data,
//            bytesPerRow: bytesPerRow
//        )
//
//        return texture
//    }
    

    
    // MARK: - DEBUG
    
//    private static func testMinimalLibrary(device: MTLDevice) throws -> MTLLibrary { // unused?
//        let minimalSource = """
//    #include <metal_stdlib>
//    using namespace metal;
//
//    kernel void testKernel(
//        texture2d<float, access::write> target [[texture(0)]],
//        uint2 gid [[thread_position_in_grid]]
//    ) {
//        target.write(float4(1.0, 0.0, 0.0, 1.0), gid);
//    }
//    """
//
//        print("Testing minimal Metal library with source length: \(minimalSource.count)")
//
//        do {
//            let library = try device.makeLibrary(source: minimalSource, options: nil)
//            print("Minimal library created successfully")
//            print("Available functions: \(library.functionNames)")
//            return library
//        } catch {
//            print("Failed to create minimal library: \(error)")
//            throw error
//        }
//    }
    
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

    
    private func debugPrintPixelZero(from texture: MTLTexture) {
        debugPrintPixel(from: texture, x: 0, y: 0)
    }
}

    // MARK: - Error Types

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
