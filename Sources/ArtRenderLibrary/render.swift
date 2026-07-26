import Foundation
#if os(Linux)
import Silica
import CoreFoundation
import Cairo
import JPEG
#elseif os(macOS)
import CoreGraphics
#endif

#if canImport(ImageIO)
import ImageIO
#endif

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

#if canImport(CoreText)
import CoreText
#endif

#if canImport(Metal)
import Metal
#endif

import ArtParser

// MARK: - Data Structures
public struct Point: Equatable  {
    var x: Float
    var y: Float
    var p: Float  // Changed from Int to Float
    public init(x: Float, y: Float, p: Float) {
        self.x = x
        self.y = y
        self.p = p
    }
}


#if canImport(Metal)
public struct GPUSplineSegment {
    public var p0: SIMD2<Float>    // CR Control Point 0 (Prev tangent)
    public var p1: SIMD2<Float>    // CR Control Point 1 (Segment start)
    public var p2: SIMD2<Float>    // CR Control Point 2 (Segment end)
    public var p3: SIMD2<Float>    // CR Control Point 3 (Next tangent)
    public var radius0: Float
    public var radius1: Float
    public var opacity0: Float
    public var opacity1: Float
    public var noiseSeed: UInt32
    public var segmentType: UInt32 // 0 = Straight, 1 = Shape-1, 2 = Shape-2
    public var padding1: UInt32
    public var padding2: UInt32
    
    public init(p0: SIMD2<Float>, p1: SIMD2<Float>, p2: SIMD2<Float>, p3: SIMD2<Float>,
                radius0: Float, radius1: Float,
                opacity0: Float, opacity1: Float,
                segmentType: UInt32, noiseSeed: UInt32) {
        self.p0 = p0
        self.p1 = p1
        self.p2 = p2
        self.p3 = p3
        self.radius0 = radius0
        self.radius1 = radius1
        self.opacity0 = opacity0
        self.opacity1 = opacity1
        self.segmentType = segmentType
        self.noiseSeed = noiseSeed
        self.padding1 = 0
        self.padding2 = 0
    }
}
#endif

struct PenInfo {
    var size: Float
    var sizeMin: Float
    var opacity: Float
    var opacityMin: Float
    var color: (r: Float, g: Float, b: Float)
    var isEraser: Bool
    var isMarker: Bool
    var penMatrixAffine: CGAffineTransform?
    var type: Int?
}

public struct ResampledPoint {
    public var location: CGPoint
    public var pressure: Float  // Changed from Int to Float
    
    public init(location: CGPoint, pressure: Float) {
        self.location = location
        self.pressure = pressure
    }
    
    // Backwards-compatible initializer
    public init(x: CGFloat, y: CGFloat, p: Float) {
        self.location = CGPoint(x: x, y: y)
        self.pressure = p
    }
    
    // computed shortcuts so existing code using .x/.y/.p still works
    public var x: CGFloat {
        get { return location.x }
        set { location.x = newValue }
    }
    public var y: CGFloat {
        get { return location.y }
        set { location.y = newValue }
    }
    public var p: Float {
        get { return pressure }
        set { pressure = newValue }
    }
}

extension Array where Element: Comparable {
    // First index where self[index] >= value
    func lowerBound(_ value: Element) -> Int {
        var low = 0
        var high = count
        while low < high {
            let mid = (low + high) / 2
            if self[mid] < value {
                low = mid + 1
            } else {
                high = mid
            }
        }
        return low
    }
}

// MARK: - Render Structures
private struct AlphaPlane {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    var data: UnsafeMutablePointer<UInt8>
    
    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.bytesPerRow = width
        self.data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
        self.data.initialize(repeating: 0, count: width * height)
    }
    
//    mutating func reset() { // unused?
//        data.assign(repeating: 0, count: width * height) // previously initialize
//    }
    
    func dealloc() { data.deallocate() }
    
//    @inline(__always)
//    func ptr(x: Int, y: Int) -> UnsafeMutablePointer<UInt8> { // unused?
//        data.advanced(by: y * bytesPerRow + x)
//    }
//
    // Max-blit an 8-bit tile into the plane at (dstX,dstY).
//    func maxBlit(tile: UnsafePointer<UInt8>, tileW: Int, tileH: Int, dstX: Int, dstY: Int) { // unused?
//        let startY = max(0, dstY)
//        let startX = max(0, dstX)
//        let endY = min(height, dstY + tileH)
//        let endX = min(width,  dstX + tileW)
//        if startX >= endX || startY >= endY { return }
//
//        let srcBase = tile
//
//        for y in startY..<endY {
//            let sy = y - dstY
//            let dstRow = data.advanced(by: y * bytesPerRow + startX)
//            let srcRow = srcBase.advanced(by: sy * tileW + (startX - dstX))
//
//            // Process 8 bytes at a time for better performance
//            var i = startX
//            while i + 8 <= endX {
//                // Process 8 bytes
//                for k in 0..<8 {
//                    let s = srcRow[i - startX + k]
//                    let d = dstRow[i - startX + k]
//                    dstRow[i - startX + k] = max(s, d)
//                }
//                i += 8
//            }
//
//            // Process remaining bytes
//            while i < endX {
//                let s = srcRow[i - startX]
//                let d = dstRow[i - startX]
//                dstRow[i - startX] = max(s, d)
//                i += 1
//            }
//        }
//    }
}

extension AlphaPlane {
    // Optimized max-blit using pointer arithmetic for better performance
    func maxBlitOptimized(tile: UnsafePointer<UInt8>, tileW: Int, tileH: Int, dstX: Int, dstY: Int) {
        let startY = max(0, dstY)
        let startX = max(0, dstX)
        let endY = min(height, dstY + tileH)
        let endX = min(width,  dstX + tileW)
        if startX >= endX || startY >= endY { return }
        
        let srcBase = tile
        let rowWidth = endX - startX
        
        var dstRowOffsets: [Int] = []
        var srcRowOffsets: [Int] = []
        dstRowOffsets.reserveCapacity(endY - startY)
        srcRowOffsets.reserveCapacity(endY - startY)
        
        for y in startY..<endY {
            let sy = y - dstY
            dstRowOffsets.append(y * bytesPerRow + startX)
            srcRowOffsets.append(sy * tileW + (startX - dstX))
        }
        
        for (rowIdx, dstOffset) in dstRowOffsets.enumerated() {
            let srcOffset = srcRowOffsets[rowIdx]
            let dstRow = data.advanced(by: dstOffset)
            let srcRow = srcBase.advanced(by: srcOffset)
            
            // Use memcpy for large contiguous blocks where possible
            if rowWidth >= 16 {
                // Process in chunks of 16 bytes
                var i = 0
                while i + 16 <= rowWidth {
                    // Load 16 bytes from source and destination
                    var srcBytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                   UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0, 0, 0,
                                                                                              0, 0, 0, 0, 0, 0, 0, 0)
                    var dstBytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                   UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0, 0, 0,
                                                                                              0, 0, 0, 0, 0, 0, 0, 0)
                    
                    // Copy bytes into tuples
                    withUnsafeMutablePointer(to: &srcBytes) { ptr in
                        let buffer = UnsafeMutableRawBufferPointer(start: ptr, count: 16)
                        buffer.copyMemory(from: UnsafeRawBufferPointer(start: srcRow.advanced(by: i), count: 16))
                    }
                    
                    withUnsafeMutablePointer(to: &dstBytes) { ptr in
                        let buffer = UnsafeMutableRawBufferPointer(start: ptr, count: 16)
                        buffer.copyMemory(from: UnsafeRawBufferPointer(start: dstRow.advanced(by: i), count: 16))
                    }
                    
                    // Calculate max for each byte
                    let result: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                                 UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (
                                    max(srcBytes.0, dstBytes.0),
                                    max(srcBytes.1, dstBytes.1),
                                    max(srcBytes.2, dstBytes.2),
                                    max(srcBytes.3, dstBytes.3),
                                    max(srcBytes.4, dstBytes.4),
                                    max(srcBytes.5, dstBytes.5),
                                    max(srcBytes.6, dstBytes.6),
                                    max(srcBytes.7, dstBytes.7),
                                    max(srcBytes.8, dstBytes.8),
                                    max(srcBytes.9, dstBytes.9),
                                    max(srcBytes.10, dstBytes.10),
                                    max(srcBytes.11, dstBytes.11),
                                    max(srcBytes.12, dstBytes.12),
                                    max(srcBytes.13, dstBytes.13),
                                    max(srcBytes.14, dstBytes.14),
                                    max(srcBytes.15, dstBytes.15)
                                 )
                    
                    // Copy result back
                    withUnsafePointer(to: result) { ptr in
                        let buffer = UnsafeRawBufferPointer(start: ptr, count: 16)
                        UnsafeMutableRawBufferPointer(start: dstRow.advanced(by: i), count: 16).copyMemory(from: buffer)
                    }
                    
                    i += 16
                }
                
                // Process remaining bytes
                while i < rowWidth {
                    dstRow[i] = max(srcRow[i], dstRow[i])
                    i += 1
                }
            } else {
                // For small rows, just process byte by byte
                for i in 0..<rowWidth {
                    dstRow[i] = max(srcRow[i], dstRow[i])
                }
            }
        }
    }
}

// MARK: - Cross-Platform Compatibility Helpers

#if os(Linux)
/// Silica-compatible equivalent of the CoreGraphics CGAffineTransformConcat function.
@inline(__always)
func CGAffineTransformConcat(_ t1: CGAffineTransform, _ t2: CGAffineTransform) -> CGAffineTransform {
    return CGAffineTransform(
        a: t1.a * t2.a + t1.b * t2.c,
        b: t1.a * t2.b + t1.b * t2.d,
        c: t1.c * t2.a + t1.d * t2.c,
        d: t1.c * t2.b + t1.d * t2.d,
        tx: t1.tx * t2.a + t1.ty * t2.c + t2.tx,
        ty: t1.tx * t2.b + t1.ty * t2.d + t2.ty
    )
}
#endif

#if os(Linux)
// MARK: - Missing Type Shims for Silica

public class CGDataProvider {
    public let data: Data
    public init(data: Data) { self.data = data }
}

public enum CGImageAlphaInfo: UInt32 {
    case none = 0
    case premultipliedLast = 1
    case premultipliedFirst = 2
    case last = 3
    case first = 4
}

public enum CGBlendMode {
    case normal
    case copy
    case clear
    case sourceOver
    case destinationOver
    case sourceIn
    case destinationIn
    case sourceOut
    case destinationOut
    case sourceAtop
    case destinationAtop
    case multiply
    case screen
    case overlay
    case darken
    case lighten
    case colorDodge
    case colorBurn
    case hardLight
    case softLight
    case difference
    case exclusion
}

public enum CGColorRenderingIntent {
    case defaultIntent
    case absoluteColorimetric
    case relativeColorimetric
    case perceptual
    case saturation
}

public class CGMutablePath {
    public init() {}
    public func move(to point: CGPoint) {}
    public func addLine(to point: CGPoint) {}
    public func addArc(center: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat, clockwise: Bool) {}
    public func closeSubpath() {}
    public var isEmpty: Bool { return true }
}
public typealias CGPath = CGMutablePath

public struct Stamp {
    public var center: SIMD2<Float>
    public var radius: Float
    public var opacity: Float
    public var rotation: Float
    public var noiseSeed: UInt32

    public init(center: SIMD2<Float>, radius: Float, opacity: Float, rotation: Float, noiseSeed: UInt32) {
        self.center = center
        self.radius = radius
        self.opacity = opacity
        self.rotation = rotation
        self.noiseSeed = noiseSeed
    }
}

// MARK: - CGColorSpace shim
public final class CGColorSpace {
    public static let sRGB = "sRGB"
    public static let linearGray = "linearGray"
    public let name: String
    public init?(name: String) { self.name = name }
}

// MARK: - CGColor compatibility
extension CGColor {
    public static func create(colorSpace: CGColorSpace, components: [CGFloat]) -> CGColor {
        if components.count >= 4 {
            return CGColor(red: components[0], green: components[1], blue: components[2], alpha: components[3])
        } else if components.count >= 3 {
            return CGColor(red: components[0], green: components[1], blue: components[2], alpha: 1.0)
        } else {
            return CGColor(red: 0, green: 0, blue: 0, alpha: 1.0)
        }
    }
}

// MARK: - CGBitmapInfo compatibility
extension CGBitmapInfo {
    public var rawValue: UInt32 {
        // Silica CGBitmapInfo may not store a raw value;
        // return a sensible default for premultiplied ARGB
        return CGImageAlphaInfo.premultipliedLast.rawValue
    }
}

// MARK: - CGContext extensions for Silica

extension CGContext {
    // Context metadata storage
    private static var _metadata: [ObjectIdentifier: (w: Int, h: Int, dataPtr: UnsafeMutableRawPointer?, bytesPerRow: Int, surface: AnyObject?)] = [:]
    private static let _metadataLock = NSLock()

    internal static func _registerMetadata(w: Int, h: Int, dataPtr: UnsafeMutableRawPointer? = nil, bytesPerRow: Int, surface: AnyObject? = nil, for ctx: CGContext) {
        _metadataLock.lock()
        _metadata[ObjectIdentifier(ctx)] = (w, h, dataPtr, bytesPerRow, surface)
        _metadataLock.unlock()
    }

    public var width: Int {
        CGContext._metadataLock.lock()
        defer { CGContext._metadataLock.unlock() }
        return CGContext._metadata[ObjectIdentifier(self)]?.w ?? 0
    }

    public var height: Int {
        CGContext._metadataLock.lock()
        defer { CGContext._metadataLock.unlock() }
        return CGContext._metadata[ObjectIdentifier(self)]?.h ?? 0
    }

    public var data: UnsafeMutableRawPointer? {
        CGContext._metadataLock.lock()
        defer { CGContext._metadataLock.unlock() }
        return CGContext._metadata[ObjectIdentifier(self)]?.dataPtr
    }

    public var bytesPerRow: Int {
        CGContext._metadataLock.lock()
        defer { CGContext._metadataLock.unlock() }
        return CGContext._metadata[ObjectIdentifier(self)]?.bytesPerRow ?? 0
    }

//     public func setFillColor(_ color: CGColor) {
//         self.fillColor = color
//     }

//     public func setFillColor(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
//         self.fillColor = CGColor(red: red, green: green, blue: blue, alpha: alpha)
//     }

//     public func setStrokeColor(_ color: CGColor) {
//         self.strokeColor = color
//     }

//     public func setLineWidth(_ width: CGFloat) {
//         self.lineWidth = width
//     }

//     public func setBlendMode(_ mode: CGBlendMode) {
//         // TODO: Map CGBlendMode to Cairo operators via Silica
//     }

//     public func setAlpha(_ alpha: CGFloat) {
//         self.alpha = alpha
//     }

//     public func fill(_ rect: CGRect) {
//         // TODO: Implement using Silica/Cairo path + fill
//     }

    public func stroke(_ rect: CGRect) {
        // TODO: Implement using Silica/Cairo path + stroke
        // Use strokePath() ?
    }

    public func strokeEllipse(in rect: CGRect) {
        // TODO: Implement using Silica/Cairo ellipse + stroke
    }

//     public func addEllipse(in rect: CGRect) {
//         // TODO: Implement using Silica/Cairo ellipse path
//     }

    public func rotate(by angle: CGFloat) {
        // TODO: Implement using Cairo rotate
    }

//     public func makeImage() -> CGImage? {
//         // TODO: Requires Silica to expose CGImage(surface:) as public
//         return nil
//     }

//     public func clip(to rect: CGRect, mask: CGImage) {
//         // TODO: Implement mask clipping using Cairo mask_surface
//         self.clip(to: rect)
//     }

//     public func fillPath(using rule: CGPathFillRule = .winding) {
//         // TODO: Implement fillPath using Silica/Cairo
//     }
}

// MARK: - CGAffineTransform extensions
extension CGAffineTransform {
    public init(translationX tx: CGFloat, y ty: CGFloat) {
        self = CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: tx, ty: ty)
    }

    public func scaledBy(x sx: CGFloat, y sy: CGFloat) -> CGAffineTransform {
        return CGAffineTransform(
            a: self.a * sx,
            b: self.b * sx,
            c: self.c * sy,
            d: self.d * sy,
            tx: self.tx * sx,
            ty: self.ty * sy
        )
    }
}

// MARK: - Linux bitmap context helper
func createLinuxBitmapContext(width: Int, height: Int) -> CGContext? {
    guard let surface = try? Cairo.Surface.Image(format: .argb32, width: Int(width), height: Int(height)) else {
        return nil
    } 
    surface.flush()
    
    var rawPtr: UnsafeMutableRawPointer? = nil
    _ = surface.withUnsafeMutableBytes { ptr in
        rawPtr = UnsafeMutableRawPointer(ptr)
    }
    
    guard let ctx = try? CGContext(surface: surface, size: CGSize(width: width, height: height)) else {
        return nil
    }
    CGContext._registerMetadata(w: width, h: height, dataPtr: rawPtr, bytesPerRow: Int(surface.stride), surface: surface, for: ctx)
    return ctx
}

func createLinuxBitmapContext(width: Int, height: Int, data: UnsafeMutableRawPointer, bytesPerRow: Int) -> CGContext? {
    guard let surface = try? Cairo.Surface.Image(
        mutableBytes: data.bindMemory(to: UInt8.self, capacity: bytesPerRow * height),
        format: .argb32,
        width: Int(width),
        height: Int(height),
        stride: Int(bytesPerRow)
    ) else {
        return nil
    }
    guard let ctx = try? CGContext(surface: surface, size: CGSize(width: width, height: height)) else {
        return nil
    }
    CGContext._registerMetadata(w: width, h: height, dataPtr: data, bytesPerRow: bytesPerRow, surface: surface, for: ctx)
    return ctx
}

extension Array: JPEG.Bytestream.Source where Element == UInt8 {
    /// Reads and removes the next byte from the stream
    public mutating func read() -> UInt8? {
        guard !self.isEmpty else { return nil }
        return self.removeFirst()
    }

    /// Reads and removes a specific number of bytes from the stream
    public mutating func read(count: Int) -> [UInt8]? {
        guard count > 0, self.count >= count else { return nil }

        let chunk = Array(self.prefix(count))
        self.removeFirst(count)
        return chunk
    }
}

#endif

// MARK: - Renderer Implementation
public final class Renderer {
    let scale: CGFloat
    let canvasSize: CGSize
    let forceCPU: Bool
    let useSegmentRendering: Bool
    
    private let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    
    #if canImport(Metal)
    private var layerTexture: MTLTexture?
//    private var layerContext: CGContext? // unused?
    
    private var metalRenderer: MetalRenderer?
//    private var metalTexture: MTLTexture? // unused?
//    private var metalContext: CGContext? // unused?
    #endif
    
    private var noiseContextPool: [CGContext] = []
    private let maxNoiseContextPoolSize = 5
    
    // GP Export state
    var gpExportMode = false
    var gpExportRadiusScale: CGFloat = 0.01
    var gpExportLayers: [GPExportLayer] = []
    var gpExportOutputPath: String?
    var gpExportResampleStep: CGFloat = 4.0
    var gpExportCatmullRom: Bool = false
    
    public init(canvasSize: CGSize, scale: CGFloat = 1.0, forceCPU: Bool = false, useSegmentRendering: Bool = true) {
        self.scale = scale
        self.canvasSize = canvasSize
        self.forceCPU = forceCPU
        self.useSegmentRendering = useSegmentRendering
        
        let possibleNames = [
            "noise",
            "noise.png",
            "Noise",
            "Noise.png",
            "Textures/noise",
            "Textures/noise.png"
        ]
        
        for name in possibleNames {
            loadNoiseImage(named: name)
            if noiseImage != nil {
                break
            }
        }
        
        if noiseImage == nil {
            print("WARNING: Could not load noise image from any of the attempted paths")
        }
        
        // Initialize Metal renderer if supported
        #if canImport(Metal)
        if MetalRenderer.isSupported {
            do {
                guard let device = MTLCreateSystemDefaultDevice() else {
                    print("Metal device not available, falling back to CPU rendering")
                    return
                }
                
                self.metalRenderer = try MetalRenderer(device: device)
                
                metalRenderer?.createRenderTargets(width: Int(canvasSize.width * scale), height: Int(canvasSize.height * scale))
                
                if let noise = normalizedNoiseImage ?? noiseImage {
                    metalRenderer?.uploadNoiseTexture(from: noise)
                }
                
                // Also create a temporary texture for layer rendering
                createLayerTexture()
                
            } catch {
                print("Failed to create MetalRenderer: \(error)")
                self.metalRenderer = nil
            }
        }
        
        
        
        if forceCPU {
            MetalRenderer.useGPURendering = false
        } else if metalRenderer != nil {
            MetalRenderer.useGPURendering = true
        } else {
            MetalRenderer.useGPURendering = false
        }
        
        // ö
//        if metalRenderer != nil {
//            MetalRenderer.useGPURendering = true
//        } else {
//            MetalRenderer.useGPURendering = false
//        }
//        MetalRenderer.useGPURendering = false
        #endif
    }
    
    /// Clear a CGContext rect in a cross-platform way.
    /// On macOS, uses the native `clear(_ rect:)`.
    /// On Linux/Silica, uses `.copy` blend mode + transparent fill.
    #if os(Linux)
    static func clearContext(_ context: CGContext, rect: CGRect) {
        context.saveGState()
        context.setBlendMode(.copy)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0))
        context.fill(rect)
        context.restoreGState()
    }
    #else
    static func clearContext(_ context: CGContext, rect: CGRect) {
        context.clear(rect)
    }
    #endif
    

    #if os(Linux)
    /// Load a CGImage from image data on Linux using Cairo and swift-jpeg.
    static func loadImageFromData(_ data: Data) -> CGImage? {
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
    static func createDataProvider(from data: Data) -> CGDataProvider? {
        return CGDataProvider(data: data)
    }
    #else
    static func createDataProvider(from data: Data) -> CGDataProvider? {
        return CGDataProvider(data: data as CFData)
    }
    #endif

    /// Cross-platform grayscale color space for mask images.
    #if os(Linux)
    static let maskColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    #else
    static let maskColorSpace = CGColorSpace(name: CGColorSpace.linearGray)!
    #endif
    
    // MARK: - Load noise texture
    private var noiseImage: CGImage? = nil
    private var normalizedNoiseImage: CGImage? = nil
    private var noiseImageSize: CGSize = .zero
    
    private func loadNoiseImage(named name: String) {
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
    
    // MARK: - Main Render Function
    public func render(art: ArtParser) -> CGImage? {
        // Create main bitmap context
        #if os(Linux)
        guard let context = createLinuxBitmapContext(
            width: Int(canvasSize.width * scale),
            height: Int(canvasSize.height * scale)
        ) else {
            print("Creating context failed.")
            return nil
        }
        #else
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil,
            width: Int(canvasSize.width * scale),
            height: Int(canvasSize.height * scale),
            bitsPerComponent: 8,
            bytesPerRow: Int(canvasSize.width * scale * 4),
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }
        #endif
        
        // Start with transparent context
        Self.clearContext(context, rect: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        
        // Get the view matrix from art file
        let viewMatrix = art.viewMatrix
        let baseTransform = transformFromMatrix(viewMatrix, scale: scale)
        
        // --- NEW: compute content bounds and fit-to-canvas transform ---
//        let contentBounds = calculateContentBounds(art: art) // returns art-space rect (may be 0..0 if none)
//        let deviceCanvasSize = CGSize(width: context.width, height: context.height) // in pixels
//
//        if contentBounds.width > 0 && contentBounds.height > 0 {
//            // leave a small margin
//            let margin: CGFloat = 40.0
//            let availW = CGFloat(deviceCanvasSize.width) - margin * 2.0
//            let availH = CGFloat(deviceCanvasSize.height) - margin * 2.0
//            let scaleFit = min(availW / contentBounds.width, availH / contentBounds.height)
//
//            // Translate art so contentBounds.origin -> (margin, margin), then scale
//            // We want artCoord -> device pixels: translate(-minX, -minY) then scale(scaleFit)
//            let translateToOrigin = CGAffineTransform(translationX: -contentBounds.origin.x, y: -contentBounds.origin.y)
//            let scaleTransform = CGAffineTransform(scaleX: scaleFit, y: scaleFit)
//            // Optionally center: compute extra offset to center the scaled content
//            let scaledSize = CGSize(width: contentBounds.width * scaleFit, height: contentBounds.height * scaleFit)
//            let centerOffsetX = (CGFloat(deviceCanvasSize.width) - scaledSize.width) * 0.5
//            let centerOffsetY = (CGFloat(deviceCanvasSize.height) - scaledSize.height) * 0.5
//            let centerTranslate = CGAffineTransform(translationX: centerOffsetX, y: centerOffsetY)
//
//            // Compose: center * scale * translate
//            let fitTransform = centerTranslate.concatenating(scaleTransform).concatenating(translateToOrigin)
//
//            // Replace baseTransform with baseTransform * fitTransform so file viewMatrix is applied first,
//            // then we map art-space to device-space.
//            baseTransform = baseTransform.concatenating(fitTransform)
//
//            NSLog("DEBUG: Applied fitTransform scale=\(scaleFit) centerOffset=(\(centerOffsetX),\(centerOffsetY))")
//        } else {
//            NSLog("DEBUG: contentBounds empty — using viewMatrix only")
//        }

//        NSLog("DEBUG: layerContext size = \(layerContext.width)x\(layerContext.height) ; stroke count = \(layerStrokes.count)")

        // Create a temporary context for layer rendering if not using Metal
//        var layerContext: CGContext?
//        if metalRenderer == nil {
//            let ctx = createBitmapContext(size: canvasSize, scale: scale)
//            ctx.clear(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
//            layerContext = ctx
//        }
        
        // Process layers in order
        for layerIndex in art.layerOrder {
            guard layerIndex < art.layers.count else {
                continue
            }
            let layer = art.layers[layerIndex]

            let visible = getVisibility(from: layer)
            if !visible {
                continue
            }

            let layerOpacity = layer["opacity"] as? Float ?? 1.0

            // Render the layer with proper isolation
            let layerImage = renderLayerIsolated(
                layer: layer,
                layerIndex: layerIndex,
                art: art,
                baseTransform: baseTransform,
                layerOpacity: layerOpacity
            )

            // Composite the layer onto the main context
            if let layerImage = layerImage, !gpExportMode {
                context.saveGState()

                // Apply layer opacity
                context.setAlpha(CGFloat(layerOpacity))

                // Draw the layer
                context.draw(layerImage, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))

                context.restoreGState()
            }
        }
        
        // Apply background after all layers are rendered
        context.saveGState()
        context.setBlendMode(.destinationOver)
        
        if !gpExportMode {
            // Get background color from art data
            let bgColor = art.backgroundColor
            let backgroundColor = (
                r: CGFloat(bgColor[0]) / 255.0,
                g: CGFloat(bgColor[1]) / 255.0,
                b: CGFloat(bgColor[2]) / 255.0
            )

            // Apply paper texture and background color logic
            if art.paperTextureId != 0 {
                let paperColor = getPaperColor(for: art.paperTextureId)
                let paperStrength = art.paperStrength

                // Create a temporary context for the paper texture compositing
                let paperContext = createBitmapContext(
                    size: CGSize(width: context.width, height: context.height),
                    scale: 1.0
                )

                if paperStrength > 0.0 {
                    // Composite tiled paper texture on top of paper color with paper strength alpha
                    renderPaperTexture(
                        textureData: art.paperTextureData,
                        paperColor: paperColor,
                        paperStrength: paperStrength,
                        backgroundColor: art.backgroundColor,
                        in: paperContext
                    )
                } else {
                    // Use paper color directly, skipping texture tiling
                    paperContext.setFillColor(createSRGBColor(r: paperColor.r, g: paperColor.g, b: paperColor.b))
                    paperContext.fill(CGRect(x: 0, y: 0, width: paperContext.width, height: paperContext.height))
                }

                // Apply background color multiplication (unless pure white)
                if backgroundColor.r != 1.0 || backgroundColor.g != 1.0 || backgroundColor.b != 1.0 {
                    paperContext.saveGState()
                    paperContext.setBlendMode(.multiply)
                    paperContext.setFillColor(createSRGBColor(r: backgroundColor.r, g: backgroundColor.g, b: backgroundColor.b))
                    paperContext.fill(CGRect(x: 0, y: 0, width: paperContext.width, height: paperContext.height))
                    paperContext.restoreGState()
                }

                // Draw the final paper with background to the main context
                if let finalPaperImage = paperContext.makeImage() {
                    context.draw(finalPaperImage, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
                }
            } else {
                // Use background color directly
                context.setFillColor(createSRGBColor(r: backgroundColor.r, g: backgroundColor.g, b: backgroundColor.b))
                context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            }
        }
        context.restoreGState()
        
        return context.makeImage()
    }
    
    // MARK: - Layer Rendering
    
    #if canImport(Metal)
    private func createLayerTexture() {
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
    
    // New renderLayerIsolated() Function
    private func renderLayerIsolated(
        layer: [String: Any],
        layerIndex: Int,
        art: ArtParser,
        baseTransform: CGAffineTransform,
        layerOpacity: Float
    ) -> CGImage? {
        
        guard let matrix = layer["matrix"] as? [[Float]] else {
            return nil
        }
        
        let layerTransform = transformFromMatrix(matrix)
        let artToDevice = CGAffineTransformConcat(layerTransform, baseTransform)
        
        // Create a temporary context for this layer
        let layerContext = createBitmapContext(size: canvasSize, scale: scale)
        Self.clearContext(layerContext, rect: CGRect(x: 0, y: 0, width: layerContext.width, height: layerContext.height))
        
        // Collect all strokes for this layer
        var layerStrokes: [StrokeRecord] = []
        var vectorActions: [([String: Any])] = []
        
        // Process actions for this layer
        var currentPen = defaultPenInfo()
        var penMatrixScale: CGFloat = 1.0
        
        for action in art.actions {
            guard let actionLayer = action["layer"] as? Int,
                  actionLayer == layerIndex,
                  let actionName = action["action_name"] as? String else {
                continue
            }
            
            switch actionName {
            case "pen_properties":
                // Tolerant numeric parser: handles Float, Double, Int
                func num(_ v: Any?) -> Float? {
                    switch v {
                    case let f as Float: return f
                    case let d as Double: return Float(d)
                    case let i as Int: return Float(i)
                    case let ui8 as UInt8: return Float(ui8)
                    case let ui16 as UInt16: return Float(ui16)
                    default: return nil
                    }
                }
                
                // Read common pen values (if present)
                if let v = num(action["size"]) { currentPen.size = v }
                if let v = num(action["size_min"]) { currentPen.sizeMin = v }
                if let v = num(action["sizeMin"]) { currentPen.sizeMin = v }        // accept alternate key
                if let v = num(action["opacity"]) { currentPen.opacity = v }
                
                // Raw "opacity_min" in the action may actually encode a subType for some pen types.
                // Read it as subType first (but keep it available).
                var rawSubType: Float? = nil
                if let v = num(action["opacity_min"]) { rawSubType = v }
                else if let v = num(action["subType"]) { rawSubType = v }
                else if let v = num(action["sub_type"]) { rawSubType = v }
                
                // Read 'type' if supplied (may be Int or numeric)
                var penTypeVal: Int? = nil
                if let tAny = action["type"] {
                    if let ti = tAny as? Int {
                        penTypeVal = ti
                    } else if let td = tAny as? Double {
                        penTypeVal = Int(td)
                    } else if let tf = tAny as? Float {
                        penTypeVal = Int(tf)
                    }
                }
                
                // Store the brush type in the PenInfo
                currentPen.type = penTypeVal
                
 /*
                                 | 'type': 1 - 'opacity_min': 1 | 'type': 0 - 'opacity_min': 0          | 'type': 1 - 'opacity_min': 1 |
                                 | ---------------------------- | --------------------------------------| ---------------------------- |
                                 | 'type': 2 - 'opacity_min': 1 | 'type': 0 - 'opacity_min': 0.80000... | 'type': 0 - 'opacity_min': 0 |
  
  Presets:
  | Noise                        | 'type': 1 - 'opacity_min': 1          | 'type': 1 - 'opacity_min': 1          | 'type': 1 - 'opacity_min': 1  |
  | ---------------------------- | ------------------------------------- | ------------------------------------- | ----------------------------- |
  | Noise                        | 'type': 1 - 'opacity_min': 1          | 'type': 1 - 'opacity_min': 1          | 'type': 1 - 'opacity_min': 1  |
  | ---------------------------- | ------------------------------------- | ------------------------------------- | ----------------------------- |
  | Solid                        | 'type': 0 - 'opacity_min': 0          | 'type': 0 - 'opacity_min': 0          | 'type': 0 - 'opacity_min': 0  |
  | ---------------------------- | ------------------------------------- | ------------------------------------- | ----------------------------- |
  | Solid with opacity dynamics  | 'type': 0 - 'opacity_min': 0.80000... | 'type': 0 - 'opacity_min': 0.80000... | 'type': 0 - 'opacity_min': 1  |
  | ---------------------------- | ------------------------------------- | ------------------------------------- | ----------------------------- |
  | Marker                       | 'type': 2 - 'opacity_min': 1          | 'type': 2 - 'opacity_min': 0          | 'type': 2 - 'opacity_min': 0  |

  Type 0: Solid
  Type 1: Noise
  Type 2: Marker    opacity_min 1: opacity dynamics   opacity_min 0: full opacity
  
*/
                
                // Determine derived opacityMin based on (type, subType) heuristics you provided.
                // Start from the explicit value if it really was intended as opacity_min; otherwise derive.
                var derivedOpacityMin: Float = currentPen.opacityMin // keep existing default
                
                if let type = penTypeVal {
                    // Map behaviors for types/subTypes (heuristics)
                    if type == 1 {
                        // pencil -> treat as type 2 round shape, full pressure range
                        derivedOpacityMin = 0.16 // 0.44
                    } else if type == 0 {
                        // solid
                        if let st = rawSubType {
                            // type 0 cases:
                            currentPen.isMarker = false
                            
                            if abs(st - 0.0) < 0.0001 {
                                // subtype == 0 -> fully opaque behavior (min == max)
                                derivedOpacityMin = currentPen.opacity
                            } else if st > 0.7 {
                                // subtype ~0.8 -> low but non-zero min opacity
                                derivedOpacityMin = 0.15   // chosen low constant (0.1-0.2 range)
                            } else {
                                // other subtype values -> keep whatever default is currently set
                                derivedOpacityMin = currentPen.opacityMin
                            }
                        } else {
                            // no subtype — keep current default
                            derivedOpacityMin = currentPen.opacityMin
                        }
                    } else if type == 2 {
                        // marker
                        // 45° pill shape ratio 1:4 diameter
                        currentPen.isMarker = true
                        
                        if let st = rawSubType {
                            if st == 1.0 {
                                // full pressure range (0..opacity)
                                derivedOpacityMin = 0.0
                            } else {
                                // max opacity (safe)
                                derivedOpacityMin = 1.0
                            }
                        } else {
                            // type 2, no subtype -> assume full pressure range
                            derivedOpacityMin = 0.0
                        }
                    } else {
                        // unknown types — leave as-is
                        derivedOpacityMin = currentPen.opacityMin
                    }
                }
//                else if let st = rawSubType {
//                    // No type provided but a raw subtype exists — apply some safe defaults:
//                    // Not sure this is ever the case, but ok
//                    if st > 0.7 {
//                        derivedOpacityMin = 0.15
//                    } else if abs(st - 0.33) < 0.08 {
//                        derivedOpacityMin = currentPen.opacityMin
//                    } else {
//                        derivedOpacityMin = currentPen.opacityMin
//                    }
//                }
                
                // Final clamp to [0,1]
                derivedOpacityMin = min(max(derivedOpacityMin, 0.0), 1.0)
                
                // Assign derived result back into pen snapshot
                currentPen.opacityMin = derivedOpacityMin
                
                print("stroke pen snapshot -> type=\(penTypeVal ?? -1), subType=\(rawSubType ?? -1), opacity=\(currentPen.opacity), opacityMin=\(currentPen.opacityMin)")
                
            case "pen_matrix":
                // Helper to coerce Any -> Double
                func toDouble(_ v: Any?) -> Double? {
                    switch v {
                    case let d as Double: return d
                    case let f as Float: return Double(f)
                    case let i as Int: return Double(i)
                    case let s as String: return Double(s)
                    default: return nil
                    }
                }
                
                // Read matrix as [[Any]] or [[Double]]
                var a: Double = 1.0, b: Double = 0.0, c: Double = 0.0, d: Double = 1.0
                var tx: Double = 0.0, ty: Double = 0.0
                var parsed = false
                
                if let matAny = action["matrix"] as? [[Any]] {
                    // Many files encode 4x4 row-major: mat[row][col]
                    if matAny.count >= 4 && matAny[3].count >= 2 {
                        // guess: layout like:
                        // [ [a, b, ...],
                        //   [c, d, ...],
                        //   [...],
                        //   [tx, ty, ..., 1] ]
                        if let aa = toDouble(matAny[0][0]) { a = aa }
                        if matAny[0].count > 1, let bb = toDouble(matAny[0][1]) { b = bb }
                        if matAny.count > 1 && matAny[1].count > 0, let cc = toDouble(matAny[1][0]) { c = cc }
                        if matAny.count > 1 && matAny[1].count > 1, let dd = toDouble(matAny[1][1]) { d = dd }
                        if let txx = toDouble(matAny[3][0]) { tx = txx }
                        if let tyy = toDouble(matAny[3][1]) { ty = tyy }
                        parsed = true
                    } else if matAny.count >= 2 && matAny[0].count >= 2 && matAny[1].count >= 2 {
                        // fallback: take top-left 2x2 and row 2 as translation
                        if let aa = toDouble(matAny[0][0]) { a = aa }
                        if let bb = toDouble(matAny[0][1]) { b = bb }
                        if let cc = toDouble(matAny[1][0]) { c = cc }
                        if let dd = toDouble(matAny[1][1]) { d = dd }
                        // translation not present — keep tx/ty = 0
                        parsed = true
                    }
                } else if let matDouble = action["matrix"] as? [[Double]] {
                    if matDouble.count >= 4 && matDouble[3].count >= 2 {
                        a = matDouble[0][0]; b = matDouble[0][1]
                        c = matDouble[1][0]; d = matDouble[1][1]
                        tx = matDouble[3][0]; ty = matDouble[3][1]
                        parsed = true
                    } else if matDouble.count >= 2 && matDouble[0].count >= 2 {
                        a = matDouble[0][0]; b = matDouble[0][1]
                        c = matDouble[1][0]; d = matDouble[1][1]
                        parsed = true
                    }
                }
                
                if parsed {
                    // Compose candidate CGAffineTransform.
                    // We use a layout where affine maps (x,y) -> (a*x + b*y + tx, c*x + d*y + ty)
                    let affine = CGAffineTransform(a: CGFloat(a), b: CGFloat(b), c: CGFloat(c), d: CGFloat(d), tx: CGFloat(tx), ty: CGFloat(ty))
                    
                    // Compute numeric scale from affine (average column vector length)
                    let sx = sqrt(a*a + c*c)
                    let sy = sqrt(b*b + d*d)
                    var computedScale = CGFloat((sx + sy) / 2.0)
                    if !computedScale.isFinite || computedScale <= 0.0 { computedScale = 1.0 }
                    
                    // Store into current pen snapshot
                    currentPen.penMatrixAffine = affine
                    penMatrixScale = computedScale
                    
                    print("Parsed pen_matrix: a=\(a) b=\(b) c=\(c) d=\(d) tx=\(tx) ty=\(ty) scale=\(computedScale)")
                } else {
                    print("Warning: couldn't parse pen_matrix action: \(action)")
                }
                
            case "is_eraser":
                if let isEraser = action["is_eraser"] as? Bool {
                    currentPen.isEraser = isEraser
                }
                
            case "pen_color":
                // keep your reverted logic here — accept different encodings robustly
                if let t = action["color"] as? (Int, Int, Int) {
                    currentPen.color = (r: Float(t.0)/255.0, g: Float(t.1)/255.0, b: Float(t.2)/255.0)
                } else if let arr = action["color"] as? [Any], arr.count >= 3 {
                    if let r = arr[0] as? Int, let g = arr[1] as? Int, let b = arr[2] as? Int {
                        currentPen.color = (r: Float(r)/255.0, g: Float(g)/255.0, b: Float(b)/255.0)
                    } else if let r = arr[0] as? UInt8, let g = arr[1] as? UInt8, let b = arr[2] as? UInt8 {
                        currentPen.color = (r: Float(r)/255.0, g: Float(g)/255.0, b: Float(b)/255.0)
                    } else if let rf = arr[0] as? Float, let gf = arr[1] as? Float, let bf = arr[2] as? Float {
                        currentPen.color = (r: rf, g: gf, b: bf)
                    } else if let rd = arr[0] as? Double, let gd = arr[1] as? Double, let bd = arr[2] as? Double {
                        currentPen.color = (r: Float(rd), g: Float(gd), b: Float(bd))
                    }
                }
                
            case "stroke":
                // Parse points and create stroke record
                if let pts = action["points"] as? [[String: Any]], !pts.isEmpty {
                    // Parse points
                    func toFloat(_ v: Any?) -> Float {
                        if let f = v as? Float { return f }
                        if let d = v as? Double { return Float(d) }
                        if let i = v as? Int { return Float(i) }
                        if let s = v as? String, let d = Double(s) { return Float(d) }
                        return 0.0
                    }
                    
                    func toInt(_ v: Any?) -> Int {
                        if let i = v as? Int { return i }
                        if let f = v as? Float { return Int(f) }
                        if let d = v as? Double { return Int(d) }
                        if let s = v as? String, let d = Int(s) { return d }
                        return 0
                    }
                    
                    let rawPoints: [Point] = pts.map { dict in
                        let x = toFloat(dict["x"])
                        let y = toFloat(dict["y"])
                        let p = toFloat(dict["p"])
//                        print("[P][raw point] x=\(x) y=\(y) p(raw)=\(p)")
                        return Point(x: x, y: y, p: p)
                    }
                    
                    // Create StrokeRecord
                    let rec = StrokeRecord(
                        points: rawPoints,
                        pen: currentPen,
                        penMatrixScale: penMatrixScale,
                        penMatrixAffine: currentPen.penMatrixAffine
                    )
//                    if let first = rawPoints.first, let last = rawPoints.last {
//                        print("[P][stroke record] points=\(rawPoints.count) p.first=\(first.p) p.last=\(last.p) pen.opacity=\(currentPen.opacity) pen.opacityMin=\(currentPen.opacityMin)")
//                    }
                    
                    layerStrokes.append(rec)
                }
                
            case "rect", "ellipse":
                vectorActions.append(action)
                
            default:
                break
            }
        }
        
        // ── GP Export: accumulate layer data, skip rasterization ──
        if gpExportMode {
            let layerName = layer["name"] as? String ?? "Layer \(layerIndex)"
            let layerVisible = (layer["visible"] as? Int ?? 1) != 0
            let exportLayer = exportGPLayer(
                layerStrokes: layerStrokes,
                artToDevice: artToDevice,
                canvasHeight: canvasSize.height * scale,
                layerName: layerName,
                layerOpacity: layerOpacity,
                layerVisible: layerVisible,
                resampleStep: gpExportResampleStep,
                catmullRom: gpExportCatmullRom
            )
            gpExportLayers.append(exportLayer)
            return nil
        }
        
        #if os(macOS)
        // Render all strokes for this layer with Metal if available
//        let useSegmentRendering: Bool = true
        print("useSegmentRendering: ", useSegmentRendering )
        if useSegmentRendering, let mr = self.metalRenderer, !layerStrokes.isEmpty, MetalRenderer.useGPURendering {
            do {
                var segmentGroups: [(segments: [GPUSplineSegment], color: SIMD4<Float>, isEraser: Bool, isMarker: Bool)] = []
                
                for stroke in layerStrokes {
                    guard stroke.points.count >= 1 else { continue }
                    let points = stroke.points.count == 1 ? [stroke.points[0], stroke.points[0]] : stroke.points
                    
                    // Calculate effective radius scale
                    var effectiveRadiusScale: CGFloat = stroke.penMatrixScale
                    if let affine = stroke.pen.penMatrixAffine {
                        let scaleX = sqrt(affine.a * affine.a + affine.c * affine.c)
                        let scaleY = sqrt(affine.b * affine.b + affine.d * affine.d)
                        effectiveRadiusScale = (scaleX + scaleY) / 2.0
                    }
                    let artToDeviceScaleX = sqrt(artToDevice.a * artToDevice.a + artToDevice.c * artToDevice.c)
                    let artToDeviceScaleY = sqrt(artToDevice.b * artToDevice.b + artToDevice.d * artToDevice.d)
                    let artToDeviceScale = (artToDeviceScaleX + artToDeviceScaleY) / 2.0
                    effectiveRadiusScale *= artToDeviceScale * 0.5
                    
                    let color = SIMD4<Float>(Float(stroke.pen.color.r), Float(stroke.pen.color.g), Float(stroke.pen.color.b), 1.0)
                    let flipTransform: CGAffineTransform? = verticalFlipTransform(canvasHeight: CGFloat(layerContext.height))
                    
                    var segmentsForStroke: [GPUSplineSegment] = []
                    
                    // 1. Apply transforms to raw points first
                    var transformedPoints: [(p: CGPoint, pressure: Float)] = []
                    for p in points {
                        var pt = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
                        if let affine = stroke.pen.penMatrixAffine { pt = pt.applying(affine) }
                        pt = pt.applying(artToDevice)
                        if let f = flipTransform { pt = pt.applying(f) }
                        transformedPoints.append((pt, p.p))
                    }
                    
                    // 2. Extract radii and opacities
                    var radii: [CGFloat] = []
                    var opacities: [CGFloat] = []
                    for tp in transformedPoints {
                        let (r, op) = pressureToRadiusOpacity(pressure: tp.pressure, pen: stroke.pen, radiusScale: effectiveRadiusScale, gamma: 1.0)
                        radii.append(r)
                        opacities.append(CGFloat(op))
                    }
                    
                    // 3. Mirror endpoints for Catmull-Rom
                    var pts  = transformedPoints.map { $0.p }
                    var rads = radii
                    var opas = opacities
                    
                    let firstPt = pts[0]
                    let secondPt = pts[1]
                    pts.insert(CGPoint(x: 2.0 * firstPt.x - secondPt.x, y: 2.0 * firstPt.y - secondPt.y), at: 0)
                    rads.insert(rads[0], at: 0)
                    opas.insert(opas[0], at: 0)
                    
                    let lastPt = pts[pts.count - 1]
                    let secondToLastPt = pts[pts.count - 2]
                    pts.append(CGPoint(x: 2.0 * lastPt.x - secondToLastPt.x, y: 2.0 * lastPt.y - secondToLastPt.y))
                    rads.append(rads[rads.count - 1])
                    opas.append(opas[opas.count - 1])
                    
                    // --- Dynamic Geometric Smoothing ---
                    // If points are closer together than the local radius, they represent a rapid spike.
                    // We average them with their neighbors to prevent rigid caps, mimicking stamp renderers.
//                    for _ in 0..<3 {
//                        var newRads = rads
//                        var newOpas = opas
//
//                        for i in 1..<(pts.count - 1) {
//                            let distPrev = hypot(pts[i].x - pts[i-1].x, pts[i].y - pts[i-1].y)
//                            let distNext = hypot(pts[i].x - pts[i+1].x, pts[i].y - pts[i+1].y)
//                            let localRadius = max(rads[i], 1.0)
//
//                            // If distance is smaller than 1.5x radius, apply smoothing
//                            if distPrev < (localRadius * 1.5) || distNext < (localRadius * 1.5) {
//                                let avgR = (rads[i-1] + rads[i+1]) * 0.5
//                                let avgO = (opas[i-1] + opas[i+1]) * 0.5
//                                // Blend 50% with the average of neighbors
//                                newRads[i] = (rads[i] + avgR) * 0.5
//                                newOpas[i] = (opas[i] + avgO) * 0.5
//                            }
//                        }
//                        rads = newRads
//                        opas = newOpas
//                    }
                    
                    
                    // 4. Flatten and build segments
                    let seed = stroke.pen.type == 1 ? arc4random() + 1 : 0
                    
                    // Pre-allocate memory to prevent array reallocation during recursion
                    segmentsForStroke.reserveCapacity((pts.count - 3) * 4)
                    
                    for i in 1..<(pts.count - 2) {
                        let pSpan = CRPointSpan(p0: pts[i-1], p1: pts[i], p2: pts[i+1], p3: pts[i+2])
                        let rSpan = CRScalarSpan(s0: rads[i-1], s1: rads[i], s2: rads[i+1], s3: rads[i+2])
                        let oSpan = CRScalarSpan(s0: opas[i-1], s1: opas[i], s2: opas[i+1], s3: opas[i+2])
                        flattenAndBuild(span: pSpan, rSpan: rSpan, oSpan: oSpan, seed: seed, depth: 0, into: &segmentsForStroke)
                    }
                    
                    segmentGroups.append((segments: segmentsForStroke, color: color, isEraser: stroke.pen.isEraser, isMarker: stroke.pen.isMarker))
                }
                
                let w = Int(self.canvasSize.width * self.scale)
                let h = Int(self.canvasSize.height * self.scale)
                
                // Execute the unified GPU segment path
                if let cgImage = try mr.renderSegmentGroupsInOrderSync(segmentGroups: segmentGroups, width: w, height: h) {
                    return cgImage
                }
                
                return nil
                
            } catch {
                print("Segment rendering failed: \(error)")
                return renderLayerWithCPU(
                    strokes: layerStrokes,
                    vectorActions: vectorActions,
                    artToDevice: artToDevice,
                    context: layerContext,
                    art: art
                )
            }
        } else if let mr = self.metalRenderer, !layerStrokes.isEmpty, /*let layerTexture = self.layerTexture,*/ MetalRenderer.useGPURendering {
            do {
                // Create an array to preserve stroke order
                var strokeGroups: [(stamps: [Stamp], color: SIMD4<Float>, isEraser: Bool, isMarker: Bool)] = []
                
//                NSLog("DEBUG: layerContext size = \(layerContext.width)x\(layerContext.height) ; stroke count = \(layerStrokes.count)")

                // Process each stroke in order
                for stroke in layerStrokes {
                    // Resample the stroke
//                    let useSplineGeometryForLayer = true
                    // Calculate the step in art space to maintain a consistent device-pixel density
                    let targetStepInDevicePx: CGFloat = stroke.pen.type == 1 ? 2.0 : 1.5
                    let artToDeviceScaleX = sqrt(artToDevice.a * artToDevice.a + artToDevice.c * artToDevice.c)
                    let artToDeviceScaleY = sqrt(artToDevice.b * artToDevice.b + artToDevice.d * artToDevice.d)
                    var avgArtToDeviceScale = (artToDeviceScaleX + artToDeviceScaleY) / 2.0
                    if avgArtToDeviceScale <= 0.0 { avgArtToDeviceScale = 1.0 } // Avoid division by zero or negative scale
                    
                    var totalArtToDeviceScale = avgArtToDeviceScale
                    if let affine = stroke.pen.penMatrixAffine {
                        let scaleY = sqrt(affine.b * affine.b + affine.d * affine.d)
                        let affineScale = scaleY
                        totalArtToDeviceScale *= affineScale / scale
                    }
                    // Safety clamp to prevent degenerate steps
                    //             totalArtToDeviceScale = max(totalArtToDeviceScale, 0.01)

                    let stampStepPx = targetStepInDevicePx / totalArtToDeviceScale
                    
//                    if let first = stroke.points.first, let last = stroke.points.last {
//                        print("[P][resample input] count=\(stroke.points.count) p.min=\(stroke.points.map{$0.p}.min() ?? -1) p.max=\(stroke.points.map{$0.p}.max() ?? -1)")
//                    }
                    
                    var resampledArt: [ResampledPoint] = []
                    
//                    if useSplineGeometryForLayer {
                        let splinePoints: [Point] = buildResampledStrokeWithSpline(stroke.points, stepPx: stampStepPx, samplesPerSegment: 6, gamma: 1.0)
                        resampledArt = splinePoints.map { p in
                            ResampledPoint(x: CGFloat(p.x), y: CGFloat(p.y), p: p.p)
                        }
//                        print("[P][spline out] count=\(splinePoints.count) p.min=\(splinePoints.map{$0.p}.min() ?? -1) p.max=\(splinePoints.map{$0.p}.max() ?? -1)")
//                    } else {
//                        resampledArt = linearResampleAlongSegments(stroke.points, stepPx: stampStepPx)
//
//                        print("[P][linear out] count=\(resampledArt.count) p.min=\(resampledArt.map{$0.p}.min() ?? -1) p.max=\(resampledArt.map{$0.p}.max() ?? -1)")
//
//                    }
                    
                    
                    if !resampledArt.isEmpty {
                        var resampledMutable = resampledArt
//                        print("[P][taper in] p=\(resampledMutable.map{$0.p})")
                        applyEndTaperToResampled(&resampledMutable, tailSamples: 4, ease: 1.8)
//                        print("[P][taper out] p=\(resampledMutable.map{$0.p})")
                        
                        // Apply transforms
//                        let mirrorViewVerticallyForLayer = true
//                        let flipTransform: CGAffineTransform? = mirrorViewVerticallyForLayer ? verticalFlipTransform(canvasHeight: CGFloat(layerContext.height)) : nil
//                         #if os(macOS)
                        let flipTransform: CGAffineTransform? = verticalFlipTransform(canvasHeight: CGFloat(layerContext.height))
//                         #endif
                        
                        var deviceResampled: [ResampledPoint] = []
                        deviceResampled.reserveCapacity(resampledMutable.count)
                        
                        for i in 0..<resampledMutable.count {
                            let rp = resampledMutable[i]
                            let pressure = rp.p
                            var pt = CGPoint(x: rp.x, y: rp.y)
                            
                            // Apply transforms
                            if let affine = stroke.pen.penMatrixAffine {
                                pt = pt.applying(affine)
                            }
                            pt = pt.applying(artToDevice)
                            if let f = flipTransform {
                                pt = pt.applying(f)
                            }
                            
                            deviceResampled.append(ResampledPoint(location: pt, pressure: pressure))
                        }
                        
                        // Calculate effective radius scale
                        var effectiveRadiusScale: CGFloat = stroke.penMatrixScale
                        
                        if let affine = stroke.pen.penMatrixAffine {
                            let scaleX = sqrt(affine.a * affine.a + affine.c * affine.c)
                            let scaleY = sqrt(affine.b * affine.b + affine.d * affine.d)
                            let affineScale = (scaleX + scaleY) / 2.0
                            effectiveRadiusScale = affineScale
                        }
                        
                        let artToDeviceScaleX = sqrt(artToDevice.a * artToDevice.a + artToDevice.c * artToDevice.c)
                        let artToDeviceScaleY = sqrt(artToDevice.b * artToDevice.b + artToDevice.d * artToDevice.d)
                        let artToDeviceScale = (artToDeviceScaleX + artToDeviceScaleY) / 2.0
                        
                        // Adjust for normalized pressure values
                        effectiveRadiusScale *= artToDeviceScale * 0.5
                        
                        // Get the color for this stroke
                        let color = SIMD4<Float>(Float(stroke.pen.color.r), Float(stroke.pen.color.g), Float(stroke.pen.color.b), 1.0)
                        
                        // Convert to stamps
                        var stampsForStroke: [Stamp] = []
                        for point in deviceResampled {
                            let (radius, opacity) = pressureToRadiusOpacity(
                                pressure: point.pressure,
                                pen: stroke.pen,
                                radiusScale: effectiveRadiusScale,
                                gamma: 1.0
                            )
                            
                            // Debug: Print opacity for solid strokes
//                            if stroke.pen.opacity >= 0.999 {
//                                print("DEBUG: Creating stamp for solid stroke - opacity: \(opacity)")
//                            }
                            
                            let stamp = Stamp(
                                center: SIMD2<Float>(Float(point.location.x), Float(point.location.y)),
                                radius: Float(radius),
                                opacity: opacity,
                                rotation: 0.0,
                                noiseSeed: stroke.pen.type == 1 ? arc4random() + 1 : 0
                            )

                            stampsForStroke.append(stamp)
                        }
                        
                        // Add to stroke groups in order, marking if it's an eraser
                        strokeGroups.append((stamps: stampsForStroke, color: color, isEraser: stroke.pen.isEraser, isMarker: stroke.pen.isMarker))
                    }
                }
                
                // Get canvas dimensions
                let w = Int(self.canvasSize.width * self.scale)
                let h = Int(self.canvasSize.height * self.scale)
                
                // Create a temporary context for compositing the results
                let tempContext = createBitmapContext(size: canvasSize, scale: scale)
                tempContext.clear(CGRect(x: 0, y: 0, width: tempContext.width, height: tempContext.height))
                
                // Render all strokes in order
                if let cgImage = try mr.renderStrokesInOrderSync(strokeGroups: strokeGroups, width: w, height: h) {
                    return cgImage
                }
                
                let allP = layerStrokes.flatMap { $0.points.map { $0.p } }
                print("[P][Layer.summary] strokes=\(layerStrokes.count) min=\(allP.min() ?? -1) max=\(allP.max() ?? -1)")

                
                // Return the composited result
                return tempContext.makeImage()
                
            } catch {
                print("Metal layer rendering failed: \(error)")
                // Fall back to CPU rendering for this layer
                return renderLayerWithCPU(
                    strokes: layerStrokes,
                    vectorActions: vectorActions,
                    artToDevice: artToDevice,
                    context: layerContext,
                    art: art
                )
            }
        } else {
            // No Metal renderer, no strokes, no layer texture, or GPU rendering disabled - use CPU rendering
            return renderLayerWithCPU(
                strokes: layerStrokes,
                vectorActions: vectorActions,
                artToDevice: artToDevice,
                context: layerContext,
                art: art
            )
        }
        #else
        return renderLayerWithCPU(
            strokes: layerStrokes,
            vectorActions: vectorActions,
            artToDevice: artToDevice,
            context: layerContext,
            art: art
        )
        #endif
    }
    
    // CPU Fallback Function
    private func renderLayerWithCPU(
        strokes: [StrokeRecord],
        vectorActions: [[String: Any]],
        artToDevice: CGAffineTransform,
        context: CGContext,
        art: ArtParser
    ) -> CGImage? {
        
//        NSLog("DEBUG: layerContext art = \(art) ; stroke count = \(strokes.count)")
        // Render all strokes with CPU
        for stroke in strokes {
            // Resample the stroke
//            let useSplineGeometryForLayer = true
            // Calculate the step in art space to maintain a consistent device-pixel density
            let targetStepInDevicePx: CGFloat = stroke.pen.type == 1 ? 2.0 : 1.5
            let artToDeviceScaleX = sqrt(artToDevice.a * artToDevice.a + artToDevice.c * artToDevice.c)
            let artToDeviceScaleY = sqrt(artToDevice.b * artToDevice.b + artToDevice.d * artToDevice.d)
            var avgArtToDeviceScale = (artToDeviceScaleX + artToDeviceScaleY) / 2.0
            if avgArtToDeviceScale <= 0.0 { avgArtToDeviceScale = 1.0 } // Avoid division by zero or negative scale
            
            var totalArtToDeviceScale = avgArtToDeviceScale
            if let affine = stroke.pen.penMatrixAffine {
                let scaleY = sqrt(affine.b * affine.b + affine.d * affine.d)
                let affineScale = scaleY
                totalArtToDeviceScale *= affineScale / scale
            }
            // Safety clamp to prevent degenerate steps
//             totalArtToDeviceScale = max(totalArtToDeviceScale, 0.01)

            let stampStepPx = targetStepInDevicePx / totalArtToDeviceScale
            
            var resampledArt: [ResampledPoint] = []
            
                let splinePoints: [Point] = buildResampledStrokeWithSpline(stroke.points, stepPx: stampStepPx, samplesPerSegment: 6, gamma: 1.0)
                resampledArt = splinePoints.map { p in
                    ResampledPoint(x: CGFloat(p.x), y: CGFloat(p.y), p: p.p)
                }
            
            if !resampledArt.isEmpty {
                var resampledMutable = resampledArt
                applyEndTaperToResampled(&resampledMutable, tailSamples: 4, ease: 1.8)
                
                // Apply transforms
                #if os(macOS)
                let flipTransform: CGAffineTransform? = verticalFlipTransform(canvasHeight: CGFloat(context.height))
                #else
                let flipTransform: CGAffineTransform? = nil
                #endif

                var deviceResampled: [ResampledPoint] = []
                deviceResampled.reserveCapacity(resampledMutable.count)
                
                for i in 0..<resampledMutable.count {
                    let rp = resampledMutable[i]
                    let pressure = rp.p
                    var pt = CGPoint(x: rp.x, y: rp.y)
                    
                    // Apply transforms
                    if let affine = stroke.pen.penMatrixAffine {
                        pt = pt.applying(affine)
                    }
                    pt = pt.applying(artToDevice)
                    if let f = flipTransform {
                        pt = pt.applying(f)
                    }
                    
                    deviceResampled.append(ResampledPoint(location: pt, pressure: pressure))
                }
                
                // Calculate effective radius scale
                var effectiveRadiusScale: CGFloat = stroke.penMatrixScale
                
                if let affine = stroke.pen.penMatrixAffine {
                    let scaleX = sqrt(affine.a * affine.a + affine.c * affine.c)
                    let scaleY = sqrt(affine.b * affine.b + affine.d * affine.d)
                    let affineScale = (scaleX + scaleY) / 2.0
                    effectiveRadiusScale = affineScale
                }
                
                let artToDeviceScaleX = sqrt(artToDevice.a * artToDevice.a + artToDevice.c * artToDevice.c)
                let artToDeviceScaleY = sqrt(artToDevice.b * artToDevice.b + artToDevice.d * artToDevice.d)
                let artToDeviceScale = (artToDeviceScaleX + artToDeviceScaleY) / 2.0
                
                // Adjust for normalized pressure values
                effectiveRadiusScale *= artToDeviceScale * 0.5
                                
                // Render the stroke
                renderStroke_drawDeviceResampled(
                    resampledPoints: deviceResampled,
                    pen: stroke.pen,
                    in: context,
                    radiusScale: effectiveRadiusScale
                )
            }
        }
        
        // Render vector actions
        for action in vectorActions {
            let actionName = action["action_name"] as? String ?? ""
            
            context.saveGState()
            context.concatenate(artToDevice)
            
            if actionName == "rect",
               let x = action["x"] as? Float,
               let y = action["y"] as? Float,
               let width = action["w"] as? Float,
               let height = action["h"] as? Float,
               let angle = action["angle"] as? Float {
                renderRect(x: CGFloat(x), y: CGFloat(y), width: CGFloat(width), height: CGFloat(height), angle: CGFloat(angle), pen: defaultPenInfo(), in: context)
            } else if actionName == "ellipse",
                      let cx = action["cx"] as? Float,
                      let cy = action["cy"] as? Float,
                      let rx = action["rx"] as? Float,
                      let ry = action["ry"] as? Float,
                      let angle = action["angle"] as? Float {
                renderEllipse(cx: CGFloat(cx), cy: CGFloat(cy), rx: CGFloat(rx), ry: CGFloat(ry), angle: CGFloat(angle), pen: defaultPenInfo(), in: context)
            }
            
            context.restoreGState()
        }
        
        // Render embedded images
        context.saveGState()
        
        // 1. Move the origin from the bottom-left to the center of the canvas
        context.translateBy(x: CGFloat(context.width) / 2.0,
                            y: CGFloat(context.height) / 2.0)
        
        // 2. Apply your art-to-device transform (it will now act relative to the center)
        context.concatenate(artToDevice)
        
        // 3. Draw the images
        renderEmbeddedImages(art: art, in: context)
        
        context.restoreGState()
        
        return context.makeImage()
    }
    
    // MARK: - Shape Rendering
    private func renderRect(x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat, angle: CGFloat, pen: PenInfo, in context: CGContext) {
        context.saveGState()
        
        // Move to center of rect
        context.translateBy(x: x + width/2, y: y + height/2)
        // Rotate
        context.rotate(by: angle)
        
        
        if pen.isEraser {
            context.setBlendMode(.destinationOut)
        }
        
        // Set stroke properties
        context.setStrokeColor(CGColor(red: CGFloat(pen.color.r), green: CGFloat(pen.color.g), blue: CGFloat(pen.color.b), alpha: CGFloat(pen.opacity)))
        context.setLineWidth(CGFloat(pen.size))
        
        // Draw rect outline (centered at origin)
        let rect = CGRect(x: -width/2, y: -height/2, width: width, height: height)
        context.stroke(rect)
        
        context.restoreGState()
    }
    
    private func renderEllipse(cx: CGFloat, cy: CGFloat, rx: CGFloat, ry: CGFloat, angle: CGFloat, pen: PenInfo, in context: CGContext) {
        context.saveGState()
        
        // Move to center of ellipse
        context.translateBy(x: cx, y: cy)
        // Rotate
        context.rotate(by: angle)
        // Scale to create ellipse from circle
        context.scaleBy(x: rx, y: ry)
        
        if pen.isEraser {
            context.setBlendMode(.destinationOut)
        }
        
        // Set stroke properties
        context.setStrokeColor(CGColor(red: CGFloat(pen.color.r), green: CGFloat(pen.color.g), blue: CGFloat(pen.color.b), alpha: CGFloat(pen.opacity)))
        context.setLineWidth(CGFloat(pen.size) / min(rx, ry))  // Adjust line width based on scale
        
        // Draw ellipse outline
        context.strokeEllipse(in: CGRect(x: -1, y: -1, width: 2, height: 2))
        
        context.restoreGState()
    }
    
    // MARK: - Embedded Image Rendering
        private func renderEmbeddedImages(art: ArtParser, in context: CGContext) {
        for imageInfo in art.images {

            guard imageInfo["textureId"] == nil || imageInfo["textureId"] as? Int == 0,
                  let rawData = imageInfo["raw"] as? [UInt8] else {
                print("continue")
                continue
            }
            print("wah!")
            let data = Data(rawData)
            
            // Create image from data (cross-platform)
            #if os(Linux)
            guard let cgImage = Self.loadImageFromData(data) else {
                continue
            }
            #else
            guard let imageProvider = Self.createDataProvider(from: data),
                  let cgImage = CGImage(
                    jpegDataProviderSource: imageProvider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent
                  ) ?? CGImage(
                    pngDataProviderSource: imageProvider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent
                  ) else {
                continue
            }
            #endif
            
            // Draw the image centered at (0,0) which is now the center of the screen
            let rect = CGRect(
                x: -CGFloat(cgImage.width) / 2.0,
                y: -CGFloat(cgImage.height) / 2.0,
                width: CGFloat(cgImage.width),
                height: CGFloat(cgImage.height)
            )
            
            context.draw(cgImage, in: rect)
            print("Image textureId: \(imageInfo["textureId"] ?? "nil")")
        }
    }
    
    // MARK: - Helper Functions
    
    // Convert a 4x4 matrix to a CGAffineTransform
    private func transformFromMatrix(_ m: [[Float]], scale: CGFloat = 1.0) -> CGAffineTransform {
        // Mischief 4x4: translation is in row 3, columns 0/1
        guard m.count >= 4 && m[0].count >= 4 else { return .identity }
        let a  = CGFloat(m[0][0]) * scale
        let b  = CGFloat(m[1][0]) * scale
        let c  = CGFloat(m[0][1]) * scale
        let d  = CGFloat(m[1][1]) * scale
        let tx = CGFloat(m[3][0]) * scale
        let ty = CGFloat(m[3][1]) * scale
        return CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }
    
    
    // Create a default pen info
    private func defaultPenInfo() -> PenInfo {
        return PenInfo(
            size: 5.0,
            sizeMin: 1.0,
            opacity: 1.0,
            opacityMin: 1.0,
            color: (r: 1.0, g: 0.0, b: 1.0),
            isEraser: false,
            isMarker: false,
            type: nil
        )
    }
    
    private func getVisibility(from layer: [String: Any]) -> Bool {
        if let visibleInt = layer["visible"] as? Int {
            return visibleInt != 0
        } else if let visibleBool = layer["visible"] as? Bool {
            return visibleBool
        }
        return true  // Default to visible
    }
    
//    private func calculateContentBounds(art: ArtParser) -> CGRect { // unused?
//        var minX: CGFloat = .greatestFiniteMagnitude
//        var minY: CGFloat = .greatestFiniteMagnitude
//        var maxX: CGFloat = -.greatestFiniteMagnitude
//        var maxY: CGFloat = -.greatestFiniteMagnitude
//
//        // Add margin for culling
//        let margin: CGFloat = 50.0
//
//        for action in art.actions {
//            guard let actionName = action["action_name"] as? String else { continue }
//
//            switch actionName {
//            case "stroke":
//                if let pointsArray = action["points"] as? [[String: Any]] {
//                    for pointDict in pointsArray {
//                        if let x = pointDict["x"] as? Float,
//                           let y = pointDict["y"] as? Float {
//                            minX = min(minX, CGFloat(x) - margin)
//                            minY = min(minY, CGFloat(y) - margin)
//                            maxX = max(maxX, CGFloat(x) + margin)
//                            maxY = max(maxY, CGFloat(y) + margin)
//                        }
//                    }
//                }
//
//            case "rect":
//                if let x = action["x"] as? Float,
//                   let y = action["y"] as? Float,
//                   let width = action["w"] as? Float,
//                   let height = action["h"] as? Float {
//                    minX = min(minX, CGFloat(x) - margin)
//                    minY = min(minY, CGFloat(y) - margin)
//                    maxX = max(maxX, CGFloat(x + width) + margin)
//                    maxY = max(maxY, CGFloat(y + height) + margin)
//                }
//
//            case "ellipse":
//                if let cx = action["cx"] as? Float,
//                   let cy = action["cy"] as? Float,
//                   let rx = action["rx"] as? Float,
//                   let ry = action["ry"] as? Float {
//                    minX = min(minX, CGFloat(cx - rx) - margin)
//                    minY = min(minY, CGFloat(cy - ry) - margin)
//                    maxX = max(maxX, CGFloat(cx + rx) + margin)
//                    maxY = max(maxY, CGFloat(cy + ry) + margin)
//                }
//
//            default:
//                break
//            }
//        }
//
//        // Return default bounds if no content found
//        if minX == .greatestFiniteMagnitude {
//            return CGRect(x: 0, y: 0, width: canvasSize.width, height: canvasSize.height)
//        }
//
//        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
//    }
    
    private func isStrokeVisible(_ strokePoints: [ResampledPoint], pen: PenInfo, minRadius: CGFloat = 0.5) -> Bool {
        guard !strokePoints.isEmpty else { return false }
        
        // Check if any point in the stroke has a radius large enough to be visible
        for point in strokePoints {
            let pressure = max(0.0, point.pressure) // Handle negative pressure
            let p = max(0.0, min(1.0, pressure)) // Pressure is already normalized
            
            // Calculate minimum possible radius for this point using the ACTUAL pen info
            let sizeMin = pen.sizeMin
            let sizeMax = pen.size
            let sizeRange = sizeMax - sizeMin
            let gamma: Float = 1.0
            let pg = powf(p, gamma)
            let minPossibleRadius = CGFloat(sizeMin + sizeRange * pg) * 0.5 // Apply a conservative radius scale
            
            if minPossibleRadius >= minRadius {
                return true
            }
        }
        
        return false
    }
    
    // MARK: - Tweak strokes
    
    // Detect a "dot" stroke: few points and small bounding box.
    // Returns true if stroke should be treated as a dot.
    private func isDotStroke(_ pts: [Point], maxPoints: Int = 4, maxDiameterPx: CGFloat = 6.0) -> Bool {
        if pts.count > maxPoints { return false }
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX: CGFloat = -CGFloat.greatestFiniteMagnitude, maxY: CGFloat = -CGFloat.greatestFiniteMagnitude
        for p in pts {
            minX = min(minX, CGFloat(p.x)); maxX = max(maxX, CGFloat(p.x))
            minY = min(minY, CGFloat(p.y)); maxY = max(maxY, CGFloat(p.y))
        }
        let dia = max(maxX - minX, maxY - minY)
        return dia <= maxDiameterPx
    }
    
    // Apply short linear taper on last `tailSamples` samples (multiplies pressure values).
    func applyEndTaperToResampled(_ resampled: inout [ResampledPoint], tailSamples: Int = 6, ease: Float = 2.0) {
        guard resampled.count > 2, tailSamples > 0 else { return }
        
        let taperPoint = resampled.count - 1
        let actualTail = min(tailSamples, resampled.count)
        
        for i in 0..<actualTail {
            let idx = taperPoint - i
            let t = Float(i) / Float(actualTail) // normalized [0, 1]
            let eased = 1.0 - pow(1.0 - t, ease) // ease-out: fast drop, gentle finish
            let orig = resampled[idx].pressure
            let newp = orig * eased  // Multiply float pressure directly
            resampled[idx].pressure = newp
        }
    }
    
    // MARK: - Radius smoothing
    
    func exponentialSmooth(_ arr: [Float], alpha: Float = 0.18) -> [Float] {
        guard !arr.isEmpty else { return [] }
        var out = [Float](repeating: 0.0, count: arr.count)
        out[0] = arr[0]
        for i in 1..<arr.count {
            out[i] = alpha * arr[i] + (1.0 - alpha) * out[i-1]
        }
        return out
    }
    
    func movingAverage(_ arr: [Int], window: Int = 5) -> [Int] {
        guard !arr.isEmpty else { return [] }
        let w = max(1, (window % 2 == 1) ? window : window + 1)
        var out = [Int](repeating: 0, count: arr.count)
        let half = w / 2
        for i in 0..<arr.count {
            var sum: Int = 0
            var cnt: Int = 0
            let start = max(0, i - half)
            let end = min(arr.count - 1, i + half)
            for j in start...end { sum += arr[j]; cnt += 1 }
            out[i] = sum / cnt
        }
        return out
    }
    
    
    // MARK: - Arc-length resampling & pressure mapping helpers
    
    // Linear interpolation helpers
    @inline(__always) func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { return a + (b - a) * t }
    @inline(__always) func lerpF(_ a: Int, _ b: Int, _ t: Float) -> Int { return a + Int((Float(b - a) * t)) }
    
    // Compute Euclidean distance between two points
    func dist(_ ax: CGFloat, _ ay: CGFloat, _ bx: CGFloat, _ by: CGFloat) -> CGFloat {
        let dx = bx - ax
        let dy = by - ay
        return sqrt(dx*dx + dy*dy)
    }
    
    // 1) Resample points along stroke by arc length. 'step' is distance in device pixels.
//    func resampleByArcLength(_ points: [Point], step: CGFloat) -> [Point] {
//        guard points.count > 1 else { return points }
//
//        // Build arrays of CGPoints and pressures
//        var pts: [CGPoint] = points.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
//        var press: [Int] = points.map { $0.p }
//
//        // cumulative lengths
//        var segLengths: [CGFloat] = []
//        segLengths.reserveCapacity(pts.count - 1)
//        var total: CGFloat = 0.0
//        for i in 0..<(pts.count - 1) {
//            let d = dist(pts[i].x, pts[i].y, pts[i+1].x, pts[i+1].y)
//            segLengths.append(d)
//            total += d
//        }
//        if total <= 0.0 { return points } // degenerate
//
//        // decide how many samples
//        let nSamples = max(1, Int(floor(total / step)))
//        var out: [Point] = []
//        out.reserveCapacity(nSamples + 1)
//
//        // target distances (0..total)
//        var target: CGFloat = 0.0
//        var segIndex = 0
//        var segStartAccum: CGFloat = 0.0
//
//        for _ in 0...nSamples {
//            // clamp target to total
//            let tgt = min(target, total)
//            // advance to correct segment
//            while segIndex < segLengths.count && segStartAccum + segLengths[segIndex] < tgt {
//                segStartAccum += segLengths[segIndex]
//                segIndex += 1
//            }
//            if segIndex >= segLengths.count {
//                // last point
//                let last = pts.last!
//                let lastP = press.last ?? 1023
//                out.append(Point(x: Float(last.x), y: Float(last.y), p: lastP))
//            } else {
//                // position within segment i
//                let segLen = segLengths[segIndex]
//                let local = segLen <= 0 ? 0.0 : (tgt - segStartAccum) / segLen
//                // interpolate position
//                let a = pts[segIndex]
//                let b = pts[segIndex + 1]
//                let x = lerp(a.x, b.x, local)
//                let y = lerp(a.y, b.y, local)
//                // interpolate pressure
//                let pa = press[segIndex]
//                let pb = press[segIndex + 1]
//                let p = lerpF(pa, pb, Float(local))
//                out.append(Point(x: Float(x), y: Float(y), p: p))
//            }
//            target += step
//        }
//
//        return out
//    }
    
    // 2) Simple smoothing (3-sample moving average)
    func smoothPressures(_ points: [Point]) -> [Point] { 
        guard points.count > 2 else { return points }
        var out = points
        for i in 0..<points.count {
            if i == 0 || i == points.count - 1 { continue }
            let p = (points[i-1].p + points[i].p + points[i+1].p) / 3
            out[i].p = p
        }
        return out
    }
    
    // 3) Map pressure -> effective radius & opacity (use in your render pipeline).
    // gamma: small curve to favor mid/high pressure (e.g. 0.9..1.2)
    // Optimized pressure to radius and opacity conversion
    func pressureToRadiusOpacity(pressure: Float, pen: PenInfo, radiusScale: CGFloat, gamma: Float = 1.0) -> (CGFloat, Float) {
        // Pressure is already a normalized float value (0.0 to 1.0)
        let p = max(0.0, min(1.0, pressure))
        let pg = powf(p, gamma)
        
        // Optimized radius calculation
        let sizeMin = pen.sizeMin
        let sizeMax = pen.size
        let sizeRange = sizeMax - sizeMin
        

        var radius = CGFloat(sizeMin + sizeRange * pg) * radiusScale
        
        
        // Ensure minimum visible radius with optimized threshold
        let minVisibleRadius: CGFloat = max(0.5, CGFloat(sizeMin) * 0.5)
        radius = max(radius, minVisibleRadius)
        
        // Optimized opacity calculation
        let opMin = pen.opacityMin
        let opMax = pen.opacity
        let opRange = opMax - opMin
        var opacity = opMin + opRange * p /* * pg */
        
        // Apply minimum visible opacity threshold
        let minVisibleOpacity: Float = 0.02
        opacity = max(opacity, minVisibleOpacity)
        
        // Clamp final values
        opacity = max(0.0, min(1.0, opacity))
        
        // Add debug print
//        print("[P][radius_opacity] pressure=\(pressure), radius=\(radius), opacity=\(opacity), pen.type=\(pen.type ?? -1)")
        
        return (radius, opacity)
    }

    
    // 4) Convenience wrapper: run the full pipeline
//    func buildResampledStroke(_ raw: [Point], stepPx: CGFloat, pen: PenInfo, radiusScale: CGFloat, gamma: Float = 1.0) -> [Point] { // unused?
//        if raw.count < 2 { return raw }
//
//        // Handle negative pressure values by clamping to 0
//        let clamped = raw.map { (pt) -> Point in
//            let p = max(0, pt.p)
//            return Point(x: pt.x, y: pt.y, p: p)
//        }
//
//        // Resample along arc length
//        let res = resampleByArcLength(clamped, step: stepPx)
//
//        // Smooth small spikes
//        //        let smooth = smoothPressures(res)
//        let smooth = res  // Skip smoothing
//
//        // Optionally apply gamma mapping to pressures and return modified points,
//        // or keep them as pressures and let the renderer call pressureToRadiusOpacity per point.
//        // Here we keep samples as points with p still valid (no gamma applied).
//        return smooth
//    }
    
    // MARK: - Segment stuff
    @inline(__always)
    func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
            let dx = a.x - b.x
            let dy = a.y - b.y
            // Replaces pow(dx*dx + dy*dy, 0.25). sqrt is drastically faster than pow.
            return sqrt(sqrt(dx * dx + dy * dy))
        }
        
        let d01 = max(dist(p0, p1), 1e-6)
        let d12 = max(dist(p1, p2), 1e-6)
        let d23 = max(dist(p2, p3), 1e-6)
        
        let t1 = d01
        let t2 = t1 + d12
        
        let u = t1 + t * d12
        
        // Precompute inverse distances to turn divisions into multiplications
        let inv_d01 = 1.0 / d01
        let inv_d23 = 1.0 / d23
        let inv_t2 = 1.0 / t2
        let inv_t3_t1 = 1.0 / (d12 + d23)
        
        let t_d12 = t * d12
        let one_minus_t = 1.0 - t
        let d12_1mt = d12 * one_minus_t
        
        // Algebraically simplified Barry-Goldman algorithm
        let A1x = (-t_d12 * p0.x + u * p1.x) * inv_d01
        let A1y = (-t_d12 * p0.y + u * p1.y) * inv_d01
        
        // A2 is just a simple LERP
        let A2x = p1.x + (p2.x - p1.x) * t
        let A2y = p1.y + (p2.y - p1.y) * t
        
        let A3x = ((d12_1mt + d23) * p2.x - d12_1mt * p3.x) * inv_d23
        let A3y = ((d12_1mt + d23) * p2.y - d12_1mt * p3.y) * inv_d23
        
        let B1x = (d12_1mt * A1x + u * A2x) * inv_t2
        let B1y = (d12_1mt * A1y + u * A2y) * inv_t2
        
        let B2x = ((d12_1mt + d23) * A2x + t_d12 * A3x) * inv_t3_t1
        let B2y = ((d12_1mt + d23) * A2y + t_d12 * A3y) * inv_t3_t1
        
        // C is just a simple LERP
        let Cx = B1x + (B2x - B1x) * t
        let Cy = B1y + (B2y - B1y) * t
        
        return CGPoint(x: Cx, y: Cy)
    }
    
//    @inline(__always)
//    func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat, alpha: CGFloat = 0.5) -> CGPoint {
//        // Centripetal Catmull-Rom (alpha = 0.5) prevents loops and overshoots on sharp corners
//        func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
//            let dx = a.x - b.x
//            let dy = a.y - b.y
//            return pow(dx * dx + dy * dy, alpha / 2.0)
//        }
//
//        let d01 = max(dist(p0, p1), 1e-6)
//        let d12 = max(dist(p1, p2), 1e-6)
//        let d23 = max(dist(p2, p3), 1e-6)
//
//        let t0: CGFloat = 0
//        let t1: CGFloat = t0 + d01
//        let t2: CGFloat = t1 + d12
//        let t3: CGFloat = t2 + d23
//
//        let u = t1 + t * (t2 - t1)
//
//        // Weights for A1
//        let w0 = (t1 - u) / (t1 - t0)
//        let w1 = (u - t0) / (t1 - t0)
//        let A1x = p0.x * w0 + p1.x * w1
//        let A1y = p0.y * w0 + p1.y * w1
//
//        // Weights for A2
//        let w2 = (t2 - u) / (t2 - t1)
//        let w3 = (u - t1) / (t2 - t1)
//        let A2x = p1.x * w2 + p2.x * w3
//        let A2y = p1.y * w2 + p2.y * w3
//
//        // Weights for A3
//        let w4 = (t3 - u) / (t3 - t2)
//        let w5 = (u - t2) / (t3 - t2)
//        let A3x = p2.x * w4 + p3.x * w5
//        let A3y = p2.y * w4 + p3.y * w5
//
//        // Weights for B1
//        let b1w0 = (t2 - u) / (t2 - t0)
//        let b1w1 = (u - t0) / (t2 - t0)
//        let B1x = A1x * b1w0 + A2x * b1w1
//        let B1y = A1y * b1w0 + A2y * b1w1
//
//        // Weights for B2
//        let b2w0 = (t3 - u) / (t3 - t1)
//        let b2w1 = (u - t1) / (t3 - t1)
//        let B2x = A2x * b2w0 + A3x * b2w1
//        let B2y = A2y * b2w0 + A3y * b2w1
//
//        // Weights for C
//        let cw0 = (t2 - u) / (t2 - t1)
//        let cw1 = (u - t1) / (t2 - t1)
//        let Cx = B1x * cw0 + B2x * cw1
//        let Cy = B1y * cw0 + B2y * cw1
//
//        return CGPoint(x: Cx, y: Cy)
//    }
#if canImport(Metal)
    struct CRPointSpan {
        let p0: CGPoint; let p1: CGPoint; let p2: CGPoint; let p3: CGPoint
    }
    
    struct CRScalarSpan {
        let s0: CGFloat; let s1: CGFloat; let s2: CGFloat; let s3: CGFloat
    }
    
    // Exact mathematical subdivision of a Catmull-Rom span (CGPoint)
    func subdivideCRPoint(_ span: CRPointSpan) -> (CRPointSpan, CRPointSpan) {
        let p0 = span.p0, p1 = span.p1, p2 = span.p2, p3 = span.p3

        // Convert CR to Bezier
        let b0 = p1
        let b1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6.0, y: p1.y + (p2.y - p0.y) / 6.0)
        let b2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6.0, y: p2.y - (p3.y - p1.y) / 6.0)
        let b3 = p2

        // De Casteljau split at t=0.5
        let m01 = CGPoint(x: (b0.x + b1.x) / 2.0, y: (b0.y + b1.y) / 2.0)
        let m12 = CGPoint(x: (b1.x + b2.x) / 2.0, y: (b1.y + b2.y) / 2.0)
        let m23 = CGPoint(x: (b2.x + b3.x) / 2.0, y: (b2.y + b3.y) / 2.0)
        let m012 = CGPoint(x: (m01.x + m12.x) / 2.0, y: (m01.y + m12.y) / 2.0)
        let m123 = CGPoint(x: (m12.x + m23.x) / 2.0, y: (m12.y + m23.y) / 2.0)
        let m = CGPoint(x: (m012.x + m123.x) / 2.0, y: (m012.y + m123.y) / 2.0)

        // Left Bezier: b0, m01, m012, m
        // Right Bezier: m, m123, m23, b3

        // Convert Left Bezier back to CR
        let l_p0 = CGPoint(x: 2.0 * b0.x - m01.x, y: 2.0 * b0.y - m01.y)
        let l_p1 = b0
        let l_p2 = m
        let l_p3 = CGPoint(x: m.x + 6.0 * (m.x - m012.x), y: m.y + 6.0 * (m.y - m012.y))
        let left = CRPointSpan(p0: l_p0, p1: l_p1, p2: l_p2, p3: l_p3)

        // Convert Right Bezier back to CR
        let r_p0 = CGPoint(x: m.x - 6.0 * (m123.x - m.x), y: m.y - 6.0 * (m123.y - m.y))
        let r_p1 = m
        let r_p2 = b3
        let r_p3 = CGPoint(x: 2.0 * b3.x - m23.x, y: 2.0 * b3.y - m23.y)
        let right = CRPointSpan(p0: r_p0, p1: r_p1, p2: r_p2, p3: r_p3)

        return (left, right)
    }
    
    // Exact mathematical subdivision of a Catmull-Rom span (CGFloat)
    func subdivideCRScalar(_ span: CRScalarSpan) -> (CRScalarSpan, CRScalarSpan) {
        let s0 = span.s0, s1 = span.s1, s2 = span.s2, s3 = span.s3

        let b0 = s1
        let b1 = s1 + (s2 - s0) / 6.0
        let b2 = s2 - (s3 - s1) / 6.0
        let b3 = s2

        let m01 = (b0 + b1) / 2.0
        let m12 = (b1 + b2) / 2.0
        let m23 = (b2 + b3) / 2.0
        let m012 = (m01 + m12) / 2.0
        let m123 = (m12 + m23) / 2.0
        let m = (m012 + m123) / 2.0

        let l_s0 = 2.0 * b0 - m01
        let l_s1 = b0
        let l_s2 = m
        let l_s3 = m + 6.0 * (m - m012)
        let left = CRScalarSpan(s0: l_s0, s1: l_s1, s2: l_s2, s3: l_s3)

        let r_s0 = m - 6.0 * (m123 - m)
        let r_s1 = m
        let r_s2 = b3
        let r_s3 = 2.0 * b3 - m23
        let right = CRScalarSpan(s0: r_s0, s1: r_s1, s2: r_s2, s3: r_s3)

        return (left, right)
    }
    
    struct FlatPoint {
        let p0: CGPoint // CR Prev
        let p1: CGPoint // CR Start
        let p2: CGPoint // CR End
        let p3: CGPoint // CR Next
        let r0: CGFloat
        let r1: CGFloat
        let r2: CGFloat
        let r3: CGFloat
        let o0: CGFloat
        let o1: CGFloat
        let o2: CGFloat
        let o3: CGFloat
    }
    
    @inline(__always)
    func isSafeAngle(_ v1: CGPoint, _ v2: CGPoint) -> Bool {
        let dot = v1.x * v2.x + v1.y * v2.y
        if dot <= 0 { return false }
        let len1Sq = v1.x * v1.x + v1.y * v1.y
        let len2Sq = v2.x * v2.x + v2.y * v2.y
        // cos(60) = 0.5. We want cos(angle) > 0.5
        // dot / (len1 * len2) > 0.5  =>  4 * dot^2 > len1Sq * len2Sq
        return 4.0 * dot * dot > len1Sq * len2Sq
    }
    
    @inline(__always)
    func isStraightAngle(_ v1: CGPoint, _ v2: CGPoint) -> Bool {
        let dot = v1.x * v2.x + v1.y * v2.y
        if dot <= 0 { return false }
        let len1Sq = v1.x * v1.x + v1.y * v1.y
        let len2Sq = v2.x * v2.x + v2.y * v2.y
        // cos(3 degrees) ~= 0.9986
        return dot * dot > len1Sq * len2Sq * 0.998
    }
    
    func flattenAndBuild(span: CRPointSpan, rSpan: CRScalarSpan, oSpan: CRScalarSpan, seed: UInt32, depth: Int = 0, into segments: inout [GPUSplineSegment]) {
        let p0 = span.p0, p1 = span.p1, p2 = span.p2, p3 = span.p3
        let r1 = rSpan.s1, r2 = rSpan.s2
        let o1 = oSpan.s1, o2 = oSpan.s2
        
        let dx = p2.x - p1.x
        let dy = p2.y - p1.y
        let h_chord = hypot(dx, dy)
        
        let v0 = CGPoint(x: p1.x - p0.x, y: p1.y - p0.y)
        let v1 = CGPoint(x: dx, y: dy)
        let v2 = CGPoint(x: p3.x - p2.x, y: p3.y - p2.y)
        
        var needsSubdivide = false
        if h_chord > 500.0 { needsSubdivide = true }
        if !isSafeAngle(v0, v1) || !isSafeAngle(v1, v2) { needsSubdivide = true }
        
        if !needsSubdivide || depth > 8 {
            let r_max = max(r1, r2)
            let shape2_max_len = 5.0 * max(0.0, (r_max - 0.82) * abs(r1 - r2))
            
            var segmentType: UInt32 = 0
            if h_chord <= shape2_max_len || h_chord < 1.0 {
                segmentType = 2
            } else if isStraightAngle(v0, v1) && isStraightAngle(v1, v2) {
                segmentType = 0
            } else {
                segmentType = 1
            }
            
            // Append the final GPU struct directly
            segments.append(GPUSplineSegment(
                p0: SIMD2<Float>(Float(p0.x), Float(p0.y)),
                p1: SIMD2<Float>(Float(p1.x), Float(p1.y)),
                p2: SIMD2<Float>(Float(p2.x), Float(p2.y)),
                p3: SIMD2<Float>(Float(p3.x), Float(p3.y)),
                radius0: Float(r1), radius1: Float(r2),
                opacity0: Float(o1), opacity1: Float(o2),
                segmentType: segmentType,
                noiseSeed: seed
            ))
            return
        }
        
        let (leftP, rightP) = subdivideCRPoint(span)
        let (leftR, rightR) = subdivideCRScalar(rSpan)
        let (leftO, rightO) = subdivideCRScalar(oSpan)
        
        flattenAndBuild(span: leftP, rSpan: leftR, oSpan: leftO, seed: seed, depth: depth + 1, into: &segments)
        flattenAndBuild(span: rightP, rSpan: rightR, oSpan: rightO, seed: seed, depth: depth + 1, into: &segments)
    }
#endif
//    func flattenSpan(span: CRPointSpan, rSpan: CRScalarSpan, oSpan: CRScalarSpan, depth: Int = 0, into points: inout [FlatPoint]) {
//        let p0 = span.p0, p1 = span.p1, p2 = span.p2, p3 = span.p3
//
//        let dx = p2.x - p1.x
//        let dy = p2.y - p1.y
//        let h_chord = hypot(dx, dy)
//
//        let v0 = CGPoint(x: p1.x - p0.x, y: p1.y - p0.y)
//        let v1 = CGPoint(x: dx, y: dy)
//        let v2 = CGPoint(x: p3.x - p2.x, y: p3.y - p2.y)
//
//        var needsSubdivide = false
//        if h_chord > 500.0 { needsSubdivide = true }
//        if !isSafeAngle(v0, v1) || !isSafeAngle(v1, v2) { needsSubdivide = true }
//
//        if !needsSubdivide || depth > 8 {
//            points.append(FlatPoint(
//                p0: p0, p1: p1, p2: p2, p3: p3,
//                r0: rSpan.s0, r1: rSpan.s1, r2: rSpan.s2, r3: rSpan.s3,
//                o0: oSpan.s0, o1: oSpan.s1, o2: oSpan.s2, o3: oSpan.s3
//            ))
//            return
//        }
//
//        let (leftP, rightP) = subdivideCRPoint(span)
//        let (leftR, rightR) = subdivideCRScalar(rSpan)
//        let (leftO, rightO) = subdivideCRScalar(oSpan)
//
//        flattenSpan(span: leftP, rSpan: leftR, oSpan: leftO, depth: depth + 1, into: &points)
//        flattenSpan(span: rightP, rSpan: rightR, oSpan: rightO, depth: depth + 1, into: &points)
//    }
//
//    func buildBentSegmentsFromFlat(points: [FlatPoint], seed: UInt32) -> [GPUSplineSegment] {
//        var segments: [GPUSplineSegment] = []
//        if points.isEmpty { return segments }
//
//        for pt in points {
//            let v0 = CGPoint(x: pt.p1.x - pt.p0.x, y: pt.p1.y - pt.p0.y)
//            let v1 = CGPoint(x: pt.p2.x - pt.p1.x, y: pt.p2.y - pt.p1.y)
//            let v2 = CGPoint(x: pt.p3.x - pt.p2.x, y: pt.p3.y - pt.p2.y)
//
//            let h_chord = hypot(v1.x, v1.y)
//            let r_max = max(pt.r1, pt.r2)
//            let shape2_max_len = 5.0 * max(0.0, r_max - 0.82 * abs(pt.r1 - pt.r2))
//
//            var segmentType: UInt32 = 0
//            if h_chord <= shape2_max_len || h_chord < 1.0 {
//                // Very short stroke. Favor Shape-2.
//                segmentType = 2
//            } else if isStraightAngle(v0, v1) && isStraightAngle(v1, v2) {
//                // Near straight. Favor Straight Capsule.
//                segmentType = 0
//            } else {
//                // Bent and long enough. Shape-1.
//                segmentType = 1
//            }
//
//            // segmentType = 1 // Uncomment to force test Shape-1
//
//            segments.append(GPUSplineSegment(
//                p0: SIMD2<Float>(Float(pt.p0.x), Float(pt.p0.y)),
//                p1: SIMD2<Float>(Float(pt.p1.x), Float(pt.p1.y)),
//                p2: SIMD2<Float>(Float(pt.p2.x), Float(pt.p2.y)),
//                p3: SIMD2<Float>(Float(pt.p3.x), Float(pt.p3.y)),
//                radius0: Float(pt.r1), radius1: Float(pt.r2),
//                opacity0: Float(pt.o1), opacity1: Float(pt.o2),
//                segmentType: segmentType,
//                noiseSeed: seed
//            ))
//        }
//        return segments
//    }


    
    // MARK: - Spline first, then uniform-distance resample + pressure interpolation -
    // --- Catmull-Rom spline + arc-length resample + pressure interpolation ---
    // Assumes Point { x: Float, y: Float, p: Int }
    
    // Cubic Catmull-Rom spline interpolation (uniform)
//    @inline(__always)
//    func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
//        let t2 = t*t
//        let t3 = t2*t
//        let f1 = -0.5*t3 + t2 - 0.5*t
//        let f2 =  1.5*t3 - 2.5*t2 + 1.0
//        let f3 = -1.5*t3 + 2.0*t2 + 0.5*t
//        let f4 =  0.5*t3 - 0.5*t2
//        let x = p0.x*f1 + p1.x*f2 + p2.x*f3 + p3.x*f4
//        let y = p0.y*f1 + p1.y*f2 + p2.y*f3 + p3.y*f4
//        return CGPoint(x: x, y: y)
//    }
    
    
    // Build dense sampled polyline from Catmull-Rom segments and sample pressures along the same param t
    func buildSplineSamples(_ pts: [Point], samplesPerSegment: Int)
    -> (positions: [CGPoint], pressures: [Float])
    {
        // Not enough points → return as-is
        guard pts.count >= 2 else {
            return (
                pts.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) },
                pts.map { Float($0.p) }
            )
        }
        
        // Convert once
        let gpts: [CGPoint] = pts.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
        let pressures: [Float] = pts.map { $0.p }
        
        // Special-case a line with 2 points (no valid CR spline)
        if gpts.count == 2 {
            var pos: [CGPoint] = []
            var press: [Float] = []
            pos.reserveCapacity(samplesPerSegment + 1)
            press.reserveCapacity(samplesPerSegment + 1)
            
            for i in 0...samplesPerSegment {
                let t = CGFloat(i) / CGFloat(samplesPerSegment)
                pos.append(CGPoint(
                    x: lerp(gpts[0].x, gpts[1].x, t),
                    y: lerp(gpts[0].y, gpts[1].y, t)
                ))
                
                let p = pressures[0] + (pressures[1] - pressures[0]) * Float(t)
                press.append(p)
            }
            
            return (pos, press)
        }
        
        // Pad ends for standard Catmull-Rom
        var ext: [CGPoint] = []
        ext.reserveCapacity(gpts.count + 2)
        ext.append(gpts.first!)        // p0 duplicated
        ext.append(contentsOf: gpts)   // p1..pn
        ext.append(gpts.last!)         // p{n+1} duplicated
        
        var outPos: [CGPoint] = []
        var outP: [Float] = []
        outPos.reserveCapacity((gpts.count - 1) * samplesPerSegment + 1)
        outP.reserveCapacity((gpts.count - 1) * samplesPerSegment + 1)
        
        // For each segment between original points
        for i in 0..<(gpts.count - 1) {
            let p0 = ext[i]
            let p1 = ext[i + 1]
            let p2 = ext[i + 2]
            let p3 = ext[i + 3]
            
            let pr1 = pressures[i]
            let pr2 = pressures[i + 1]
            
            for s in 0...samplesPerSegment {
                let t = CGFloat(s) / CGFloat(samplesPerSegment)
                
                // Catmull-Rom for positions
                outPos.append(catmullRom(p0, p1, p2, p3, t))
                
                // Linear for pressures (same as before)
                outP.append(pr1 + (pr2 - pr1) * Float(t))
            }
        }
        
        return (outPos, outP)
    }

    
    // Compute arc-length table for a polyline
    func buildArcLengthTable(_ poly: [CGPoint]) -> (segLens: [CGFloat], cumulative: [CGFloat], total: CGFloat) {
        let n = poly.count
        if n < 2 { return ([], [0.0], 0.0) }
        
        var segLens: [CGFloat] = []
        var cumulative: [CGFloat] = [0.0]
        segLens.reserveCapacity(n - 1)
        cumulative.reserveCapacity(n)
        
        var total: CGFloat = 0.0
        for i in 0..<(n - 1) {
            let d = dist(poly[i].x, poly[i].y, poly[i + 1].x, poly[i + 1].y)
            segLens.append(d)
            total += d
            cumulative.append(total)
        }
        return (segLens, cumulative, total)
    }
    
    // Sample position+pressure at a target distance along the sampled spline polyline
    func sampleAtDistance(
        poly: [CGPoint],
        pressures: [Float],
        segLens: [CGFloat],
        cumulative: [CGFloat],
        total: CGFloat,
        target: CGFloat
    ) -> Point {
        let tgt = min(max(target, 0.0), total)
        
        // cumulative[0] is 0, so segment index is lowerBound - 1
        let idx = max(cumulative.lowerBound(tgt) - 1, 0)
        
        if idx >= segLens.count {
            return Point(x: Float(poly.last!.x), y: Float(poly.last!.y), p: pressures.last!)
        }
        
        let segStart = cumulative[idx]
        let segLen = segLens[idx]
        let localT: CGFloat = segLen > 0 ? (tgt - segStart) / segLen : 0.0
        
        let a = poly[idx]
        let b = poly[idx + 1]
        let x = a.x + localT * (b.x - a.x)
        let y = a.y + localT * (b.y - a.y)
        
        // Interpolate pressure
        let pa = pressures[idx]
        let pb = pressures[idx + 1]
        let p = Float(CGFloat(pa) + (CGFloat(pb) - CGFloat(pa)) * localT)
        
        return Point(x: Float(x), y: Float(y), p: p)
    }
    
    // Full pipeline: spline -> dense samples -> arc-length table -> uniform sampling
    // Optimized resampling with early rejection and bounds checking
    func buildResampledStrokeWithSpline(_ raw: [Point], stepPx: CGFloat, samplesPerSegment: Int = 6, gamma: Float = 1.0) -> [Point] {
        guard raw.count > 1 else { return raw }
        
        // Add debug print for input pressure range
//        let inputPressureRange = (raw.map { $0.p }.min() ?? 0, raw.map { $0.p }.max() ?? 0)
//        print("[P][spline_input] count=\(raw.count), p.min=\(inputPressureRange.0), p.max=\(inputPressureRange.1)")
        
        // Performance monitoring
        let monitor = PerformanceMonitor.shared
        monitor.startTimer("resampling")
        
        // Early rejection: calculate stroke bounds first
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        
        for point in raw {
            minX = min(minX, CGFloat(point.x))
            minY = min(minY, CGFloat(point.y))
            maxX = max(maxX, CGFloat(point.x))
            maxY = max(maxY, CGFloat(point.y))
        }
        
        let strokeBounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        
        // Skip if stroke is too small to be visible
        if strokeBounds.width < 0.5 && strokeBounds.height < 0.5 {
//            monitor.endTimer("resampling")
            return raw.count > 0 ? [raw[0]] : []
        }
        
        // Handle negative pressure values by clamping to 0
        let clamped = raw.map { (pt) -> Point in
            let p = max(0.0, pt.p)  // Now working with Float
            return Point(x: pt.x, y: pt.y, p: p)
        }
        
        // Early rejection for degenerate strokes
        let (poly, pressures) = buildSplineSamples(clamped, samplesPerSegment: samplesPerSegment)
        guard poly.count > 1 else {
//            monitor.endTimer("resampling")
            return clamped
        }
        
        let (segLens, cumulative, total) = buildArcLengthTable(poly)
        guard total > 0.0 else {
//            monitor.endTimer("resampling")
            return clamped
        }
        
        // Ensure minimum step size to prevent too dense sampling
        let adjustedStep = max(stepPx, 0.5)

        // Pressure-adaptive step scaling: smaller pressure = denser sampling
        let minStepFactor: CGFloat = 0.01   // At p=0, use 1% of base step
        let maxStepFactor: CGFloat = 1.2   // At p=1, use 120% of base step

        // Conservative estimate since step size varies
        let estimatedSamples = max(1, Int(ceil(total / (adjustedStep * minStepFactor))))
        var out: [Point] = []
        out.reserveCapacity(min(estimatedSamples + 2, 10000))

        var target: CGFloat = 0.0
        var lastPoint: Point? = nil
        var consecutiveSkips = 0
        let maxConsecutiveSkips = 2
        let maxIterations = estimatedSamples * 2

        for _ in 0..<maxIterations {
            guard target <= total else { break }

            let p = sampleAtDistance(poly: poly, pressures: pressures, segLens: segLens, cumulative: cumulative, total: total, target: target)

            // Skip points that are too close to the previous one
            if let last = lastPoint {
                let dx = p.x - last.x
                let dy = p.y - last.y
                let distance = sqrtf(dx*dx + dy*dy)
                let adaptiveThreshold = max(Float(adjustedStep * minStepFactor) * 0.15, 0.3)

                if distance < adaptiveThreshold && consecutiveSkips < maxConsecutiveSkips {
                    consecutiveSkips += 1
                    target += adjustedStep * minStepFactor * 0.5
                    continue
                }
                consecutiveSkips = 0
            }

            out.append(p)
            lastPoint = p

            // Pressure-adaptive step: lower pressure -> smaller step -> denser sampling
            let normalizedP = min(max(CGFloat(p.p), 0.0), 1.0)
            let stepFactor = minStepFactor + (maxStepFactor - minStepFactor) * pow(normalizedP, CGFloat(gamma))
            target += adjustedStep * stepFactor
        }
        
        // Ensure we always have at least the first and last points
        if out.isEmpty && !clamped.isEmpty {
            out.append(clamped[0])
        }
        
        if let lastOriginal = clamped.last, (out.isEmpty || out.last! != lastOriginal) {
            out.append(lastOriginal)
        }
        
//        monitor.endTimer("resampling")
//        monitor.incrementCounter("strokes_resampled")
        
        // Add debug print for output pressure range
//        let outputPressureRange = (out.map { $0.p }.min() ?? 0, out.map { $0.p }.max() ?? 0)
//        print("[P][spline_output] count=\(out.count), p.min=\(outputPressureRange.0), p.max=\(outputPressureRange.1)")
        
        return out
    }
    
    func interpolatePressuresOntoResampled(rawPoints: [Point], rawPressures: [Double], resampled: [ResampledPoint]) -> [Float] {
        let n = rawPoints.count
        guard n > 0 else { return resampled.map { _ in 0.0 } }
        // build raw cumulative distances
        var rawCum = [Double](repeating: 0.0, count: n)
        for i in 1..<n {
            let dx = Double(rawPoints[i].x - rawPoints[i-1].x)
            let dy = Double(rawPoints[i].y - rawPoints[i-1].y)
            rawCum[i] = rawCum[i-1] + sqrt(dx*dx + dy*dy)
        }
        let totalRaw = rawCum.last ?? 1.0
        // sample helper
        func samplePressureAt(length L: Double) -> Double {
            if L <= 0 { return rawPressures.first ?? 0.0 }
            if L >= totalRaw { return rawPressures.last ?? 0.0 }
            var idx = 0
            while idx + 1 < n && rawCum[idx+1] < L { idx += 1 }
            let den = rawCum[idx+1] - rawCum[idx]
            if den == 0 { return rawPressures[idx] }
            let t = (L - rawCum[idx]) / den
            return rawPressures[idx] * (1.0 - t) + rawPressures[idx+1] * t
        }
        // build resampled cumulative distances
        var resCum = [Double](repeating: 0.0, count: resampled.count)
        for i in 1..<resampled.count {
            let dx = Double(resampled[i].x - resampled[i-1].x)
            let dy = Double(resampled[i].y - resampled[i-1].y)
            resCum[i] = resCum[i-1] + sqrt(dx*dx + dy*dy)
        }
        let totalRes = resCum.last ?? 1.0
        var out: [Float] = []
        for i in 0..<resampled.count {
            let frac = (totalRes > 0) ? (resCum[i] / totalRes) : 0.0
            let Lraw = frac * totalRaw
            let p = samplePressureAt(length: Lraw)
            out.append(Float(p))
        }
        return out
    }
    
    // MARK: - Background/Paper
    
    private func getPaperColor(for paperTextureId: Int) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
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
    
    private func createSRGBColor(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1.0) -> CGColor {
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

    private func renderPaperTexture(
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
    
    private func multiplyColors(
        color1: (r: Float, g: Float, b: Float),
        color2: (r: Float, g: Float, b: Float)
    ) -> (r: Float, g: Float, b: Float) {
        return (
            r: color1.r * color2.r,
            g: color1.g * color2.g,
            b: color1.b * color2.b
        )
    }
    
    
    // MARK: - DEBUG TESTS
    
    class PerformanceMonitor {
        static let shared = PerformanceMonitor()
        
        private var timers: [String: TimeInterval] = [:]
        private var counters: [String: Int] = [:]
        private let lock = NSLock()
        
        private init() {}
        
        func startTimer(_ name: String) {
            lock.lock()
            defer { lock.unlock() }
            timers[name] = CFAbsoluteTimeGetCurrent()
        }
        
        func endTimer(_ name: String) -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            
            guard let startTime = timers[name] else { return 0 }
            let endTime = CFAbsoluteTimeGetCurrent()
            let duration = endTime - startTime
            timers.removeValue(forKey: name)
            
            // Log slow operations (> 16ms)
            if duration > 0.016 {
                print("⚠︎ Performance: \(name) took \(String(format: "%.2f", duration * 1000))ms")
            }
            
            return duration
        }
        
        func incrementCounter(_ name: String) {
            lock.lock()
            defer { lock.unlock() }
            counters[name, default: 0] += 1
        }
        
//        func getCounter(_ name: String) -> Int { // unused?
//            lock.lock()
//            defer { lock.unlock() }
//            return counters[name, default: 0]
//        }
        
//        func printStats() { // unused?
//            lock.lock()
//            defer { lock.unlock() }
//
//            print("=== Performance Stats ===")
//            for (name, count) in counters {
//                print("Counter: \(name) = \(count)")
//            }
//            print("========================")
//        }
        
//        func reset() { // unused?
//            lock.lock()
//            defer { lock.unlock() }
//
//            timers.removeAll()
//            counters.removeAll()
//        }
    }
    
    
    // Build a variable-width polygon (no stamps). Good debug to check geometry vs stamping.
    func buildStrokeOutlinePath(points: [Point], radii: [CGFloat]) -> CGPath {
        let path = CGMutablePath()
        guard points.count >= 2, points.count == radii.count else { return path }
        let pts = points.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
        var left: [CGPoint] = []
        var right: [CGPoint] = []
        left.reserveCapacity(pts.count); right.reserveCapacity(pts.count)
        
        for i in 0..<pts.count {
            let p = pts[i]
            let prev = (i == 0) ? pts[i] : pts[i-1]
            let next = (i == pts.count - 1) ? pts[i] : pts[i+1]
            var tx = next.x - prev.x, ty = next.y - prev.y
            let mag = sqrt(tx*tx + ty*ty)
            if mag > 1e-6 { tx /= mag; ty /= mag } else { tx = 1.0; ty = 0.0 }
            let nx = -ty, ny = tx
            let r = radii[i]
            left.append(CGPoint(x: p.x + nx*r, y: p.y + ny*r))
            right.append(CGPoint(x: p.x - nx*r, y: p.y - ny*r))
        }
        
        // forward left side
        path.move(to: left[0])
        for p in left { path.addLine(to: p) }
        
        // end cap: arc from left[last] to right[last]
        let lastIdx = pts.count - 1
        let lastCenter = pts[lastIdx]
        let lastR = radii[lastIdx]
        let startAngleEndCap = atan2(left[lastIdx].y - lastCenter.y, left[lastIdx].x - lastCenter.x)
        let endAngleEndCap = atan2(right[lastIdx].y - lastCenter.y, right[lastIdx].x - lastCenter.x)
        path.addArc(center: lastCenter, radius: lastR, startAngle: startAngleEndCap, endAngle: endAngleEndCap, clockwise: false)
        
        // right side back
        for i in stride(from: lastIdx, through: 0, by: -1) { path.addLine(to: right[i]) }
        
        // start cap
        let startCenter = pts[0]
        let startR = radii[0]
        let startAngleStartCap = atan2(right[0].y - startCenter.y, right[0].x - startCenter.x)
        let endAngleStartCap = atan2(left[0].y - startCenter.y, left[0].x - startCenter.x)
        path.addArc(center: startCenter, radius: startR, startAngle: startAngleStartCap, endAngle: endAngleStartCap, clockwise: false)
        
        path.closeSubpath()
        return path
    }
    
    
    private func renderStroke_drawDeviceResampled(
        resampledPoints: [ResampledPoint],
        pen: PenInfo,
        in context: CGContext,
        radiusScale: CGFloat
    ) {
        let inputPressureRange = (resampledPoints.map { $0.pressure }.min() ?? 0, resampledPoints.map { $0.pressure }.max() ?? 0)
        print("[P][draw_stroke] count=\(resampledPoints.count), p.min=\(inputPressureRange.0), p.max=\(inputPressureRange.1)")
        
        guard resampledPoints.count > 0 else { return }
        
        var stamps: [Stamp] = []
        stamps.reserveCapacity(resampledPoints.count)
        for point in resampledPoints {
            let (radius, opacity) = pressureToRadiusOpacity(
                pressure: point.pressure,
                pen: pen,
                radiusScale: radiusScale,
                gamma: 1.0
            )
            
            let stamp = Stamp(
                center: SIMD2<Float>(Float(point.location.x), Float(point.location.y)),
                radius: Float(radius),
                opacity: opacity,
                rotation: 0.0,
                noiseSeed: arc4random()
            )
            stamps.append(stamp)
        }
        
        // Try GPU path (Apple platforms only) // unused? renderStroke_drawDeviceResampled() only called from renderLayerWithCPU
//        #if canImport(Metal)
//        if let mr = self.metalRenderer, MetalRenderer.useGPURendering {
//            let color = SIMD4<Float>(Float(pen.color.r), Float(pen.color.g), Float(pen.color.b), 1.0)
//            
//            do {
//                let w = Int(self.canvasSize.width * self.scale)
//                let h = Int(self.canvasSize.height * self.scale)
//                
//                if let cgImage = try mr.renderStrokesSync(stamps: stamps, width: w, height: h, color: color) {
//                    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: self.canvasSize.width * self.scale, height: self.canvasSize.height * self.scale))
//                    return
//                } else {
//                    print("renderStroke_drawDeviceResampled: renderStrokesSync returned nil. Falling back to CPU.")
//                }
//            } catch {
//                print("renderStroke_drawDeviceResampled: metal rendering failed with error: \(error). Falling back to CPU.")
//            }
//        }
//        #endif
        
        // Fallback to CPU implementation (always available)
        renderStroke_drawDeviceResampled_CPU(
            resampledPoints: resampledPoints,
            pen: pen,
            in: context,
            radiusScale: radiusScale
        )
    }
    
    
    private func renderStroke_drawDeviceResampled_CPU(
        resampledPoints: [ResampledPoint],
        pen: PenInfo,
        in context: CGContext,
        radiusScale: CGFloat
    ) {
        // Performance monitoring
        let monitor = PerformanceMonitor.shared
        monitor.startTimer("stroke_rendering")
        
        // Early rejection for empty strokes
        guard resampledPoints.count > 0 else { return }
        
        // Check if we should use tile-based rendering (for texture brushes)
        let useTileRendering = pen.type == 1 // Only use tile rendering for pencil/texture brushes
        
        if useTileRendering {
            // Use existing tile-based rendering for texture brushes
            renderStrokeWithTiles(
                resampledPoints: resampledPoints,
                pen: pen,
                in: context,
                radiusScale: radiusScale
            )
        } else {
            // Use new bitmap-based rendering for non-texture brushes
            renderStrokeWithBitmapCircles(
                deviceResampled: resampledPoints,
                pen: pen,
                in: context,
                radiusScale: radiusScale
            )
        }
        
//        monitor.endTimer("stroke_rendering")
//        monitor.incrementCounter("strokes_rendered")
    }
    
    private func renderStrokeWithBitmapCircles(
        deviceResampled: [ResampledPoint],
        pen: PenInfo,
        in context: CGContext,
        radiusScale: CGFloat
    ) {
        guard !deviceResampled.isEmpty else { return }
        
        // Add debug print for input pressure range
        let inputPressureRange = (deviceResampled.map { $0.pressure }.min() ?? 0, deviceResampled.map { $0.pressure }.max() ?? 0)
        print("[P][bitmap_circles] count=\(deviceResampled.count), p.min=\(inputPressureRange.0), p.max=\(inputPressureRange.1)")
        
        let canvasW = context.width
        let canvasH = context.height
        
        // Create a single alpha plane for the entire stroke
        let plane = AlphaPlane(width: canvasW, height: canvasH)
        defer { plane.dealloc() }
        
        // Use a single tile buffer for all circles
        let bufferPool = TileBufferPool.shared
        var tileBuf = bufferPool.getBuffer()
        defer { bufferPool.returnBuffer(tileBuf) }
        
        // Pre-filter visible points to avoid processing invisible ones
        var visiblePoints: [(location: CGPoint, radius: CGFloat, opacity: Float)] = []
        visiblePoints.reserveCapacity(deviceResampled.count)
        
        for point in deviceResampled {
            let pressure = point.pressure
            let (radius, opacity) = pressureToRadiusOpacity(
                pressure: pressure,
                pen: pen,
                radiusScale: radiusScale,
                gamma: 1.1
            )
            
            // Skip invisible points
            if radius < 0.5 || opacity < 0.01 {
                continue
            }
            
            visiblePoints.append((point.location, radius, opacity))
        }
        
        // Early rejection if no visible points
        if visiblePoints.isEmpty {
            return
        }
        
        // Then process only the visible points
        for (location, radius, opacity) in visiblePoints {
            // Create a tile for this circle
            var tileOrigin = CGPoint.zero
            let (tilePtr, tileW, tileH) = makeCircleTileInto(
                center: location,
                radius: radius,
                opacity: opacity,
                canvasW: canvasW,
                canvasH: canvasH,
                tileOrigin: &tileOrigin,
                buf: &tileBuf
            )
            
            // Blit the tile to the alpha plane
            if let tilePtr = tilePtr, tileW > 0, tileH > 0 {
                plane.maxBlitOptimized(tile: tilePtr, tileW: tileW, tileH: tileH, dstX: Int(tileOrigin.x), dstY: Int(tileOrigin.y))
            }
        }
        
        // Render the alpha plane to the context
        if let mask = makeMaskFromAlphaPlane(plane: plane) {
            context.saveGState()

            if pen.isEraser {
                context.setBlendMode(.destinationOut)
                context.clip(to: CGRect(x: 0, y: 0, width: canvasW, height: canvasH), mask: mask)
                context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
            } else {
                context.setBlendMode(.normal)
                context.clip(to: CGRect(x: 0, y: 0, width: canvasW, height: canvasH), mask: mask)
                context.setFillColor(red: CGFloat(pen.color.r), green: CGFloat(pen.color.g), blue: CGFloat(pen.color.b), alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
            }

            context.restoreGState()
        }
    }
    
    // Helper method to render a group of circles with the same opacity
    private func renderCircleGroup(
        _ circles: [(center: CGPoint, radius: CGFloat)],
        opacity: Float,
        in context: CGContext
    ) {
        guard !circles.isEmpty else { return }
        
        // Set alpha for this group
        context.setAlpha(CGFloat(opacity))
        
        // --- SIMPLER APPROACH ---
        // Add ellipses directly to the context's path
        for circle in circles {
            context.addEllipse(
                in: CGRect(
                    x: circle.center.x - circle.radius,
                    y: circle.center.y - circle.radius,
                    width: circle.radius * 2,
                    height: circle.radius * 2
                )
            )
        }
        
        // Fill the path that was built directly on the context
        context.fillPath(using: .winding)
    }
    
    // Fallback method for tile-based rendering (texture brushes)
    private func renderStrokeWithTiles(
        resampledPoints: [ResampledPoint],
        pen: PenInfo,
        in context: CGContext,
        radiusScale: CGFloat
    ) {
        // Early rejection for strokes that are too small to be visible
        if !isStrokeVisible(resampledPoints, pen: pen) {
            return
        }
        
        let canvasW = context.width
        let canvasH = context.height
        
        // Use object pool for tile buffers
        let bufferPool = TileBufferPool.shared
        let plane = AlphaPlane(width: canvasW, height: canvasH)
        defer { plane.dealloc() }
        
        var circleTileBuf = bufferPool.getBuffer()
        defer { bufferPool.returnBuffer(circleTileBuf) }
        
        // disable-noise
//        var noiseTileBuf = bufferPool.getBuffer()
//        defer { bufferPool.returnBuffer(noiseTileBuf) }
        
        // Pre-calculate which points are visible to avoid processing invisible ones
        var visiblePoints: [(index: Int, radius: CGFloat, opacity: Float)] = []
        visiblePoints.reserveCapacity(resampledPoints.count)
        
        for i in 0..<resampledPoints.count {
            let pressure = max(0, resampledPoints[i].pressure) // Handle negative pressure
            let (r, a) = pressureToRadiusOpacity(pressure: pressure, pen: pen, radiusScale: radiusScale, gamma: 1.0)
            
            // Skip invisible points
            if r < 0.5 || a < 0.01 {
                continue
            }
            
            visiblePoints.append((i, r, a))
        }
        
        // Early rejection if no visible points
        if visiblePoints.isEmpty {
            return
        }
        
        let isPencilType1 = pen.type == 1
        
        for (index, r, a) in visiblePoints {
            let p = resampledPoints[index].location
            
            var tileOrigin = CGPoint.zero
            var tileBufPtr: UnsafeMutablePointer<UInt8>?
            var tileW: Int = 0
            var tileH: Int = 0
            
            if isPencilType1 {
                // Pencil brush with texture
                // disable-noise
//                var seed: UInt64 = 0
//                var rotation: CGFloat = 0
//                var offset: CGPoint = .zero
//
//                // Generate unique seed for rotation and offset
//                seed = UInt64(abs(p.x.hashValue ^ p.y.hashValue ^ index.hashValue ^ Int.random(in: 0..<Int.max)))
//                rotation = (Double(seed % 360) / 180.0) * Double.pi
//                offset = CGPoint(
//                    x: CGFloat(seed >> 16).truncatingRemainder(dividingBy: noiseImageSize.width),
//                    y: CGFloat(seed >> 32).truncatingRemainder(dividingBy: noiseImageSize.height)
//                )
                
                // Create circle tile
                var circleOrigin = CGPoint.zero
                let (circleBuf, circleW, circleH) = makeFalloffCircleTileInto(
                    center: p,
                    radius: r,
                    opacity: a,
                    canvasW: canvasW,
                    canvasH: canvasH,
                    tileOrigin: &circleOrigin,
                    buf: &circleTileBuf
                )
                
                if let circleBuf = circleBuf {
                    // Create noise tile
                    // Current noise on CPU rendering is slow and sometimes broken, disable for now
                    // disable-noise
//                    var noiseOrigin = CGPoint.zero
//                    let (noiseBuf, noiseW, noiseH) = makeNoiseTileInto(
//                        center: p,
//                        radius: r,
//                        rotation: rotation,
//                        offset: offset,
//                        canvasW: canvasW,
//                        canvasH: canvasH,
//                        tileOrigin: &noiseOrigin,
//                        buf: &noiseTileBuf
//                    )
//
//                    if let noiseBuf = noiseBuf, circleW == noiseW, circleH == noiseH {
//                        // Combine tiles
//                        let combinedPixelCount: Int = circleW * circleH
//                        let combinedBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: combinedPixelCount)
//                        defer { combinedBuf.deallocate() }
//
//                        multiplyAlphaTiles(
//                            circlePtr: circleBuf,
//                            noisePtr: noiseBuf,
//                            outPtr: combinedBuf,
//                            w: circleW,
//                            h: circleH
//                        )
//
//                        tileBufPtr = combinedBuf
//                        tileW = circleW
//                        tileH = circleH
//                        tileOrigin = circleOrigin
//                    } else {
                        tileBufPtr = circleBuf
                        tileW = circleW
                        tileH = circleH
                        tileOrigin = circleOrigin
//                    }
                }
            } else {
                // Non-pencil brush
                let (circleBuf, circleW, circleH) = makeCircleTileInto(
                    center: p,
                    radius: r,
                    opacity: a,
                    canvasW: canvasW,
                    canvasH: canvasH,
                    tileOrigin: &tileOrigin,
                    buf: &circleTileBuf
                )
                
                tileBufPtr = circleBuf
                tileW = circleW
                tileH = circleH
            }
            
            // Blit the tile
            if let tileBuf = tileBufPtr, tileW > 0, tileH > 0 {
                plane.maxBlitOptimized(tile: tileBuf, tileW: tileW, tileH: tileH, dstX: Int(tileOrigin.x), dstY: Int(tileOrigin.y))
            }
        }
        
        // Render the alpha plane
        if let mask = makeMaskFromAlphaPlane(plane: plane) {
            context.saveGState()
            
            if pen.isEraser {
                context.setBlendMode(.destinationOut)
                context.clip(to: CGRect(x: 0, y: 0, width: canvasW, height: canvasH), mask: mask)
                context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
            } else {
                context.setBlendMode(.normal)
                context.clip(to: CGRect(x: 0, y: 0, width: canvasW, height: canvasH), mask: mask)
                context.setFillColor(red: CGFloat(pen.color.r), green: CGFloat(pen.color.g), blue: CGFloat(pen.color.b), alpha: 1)
                context.fill(CGRect(x: 0, y: 0, width: canvasW, height: canvasH))
            }
            
            context.restoreGState()
        }
    }
    
//    func cleanup() {
//        // Clear the noise context pool
//        for context in noiseContextPool {
//            // The context will be deallocated when it goes out of scope
//        }
//        noiseContextPool.removeAll()
//
//        // Clear the tile buffer pool
//        TileBufferPool.shared.clear()
//    }
    
    
    private func makeMaskFromAlphaPlane(plane: AlphaPlane) -> CGImage? {
        #if os(Linux)
        // On Linux, we create a Swift Data copy of the alpha plane.
        // The CGImage initializer will handle copying this into a Cairo Surface.
        let planeData = Data(bytes: plane.data, count: plane.width * plane.height)

        return CGImage(alphaData: planeData,
                       width: plane.width,
                       height: plane.height,
                       bytesPerRow: plane.width)
        #else
        // CoreGraphics implementation for macOS/iOS (keep existing)
        guard let provider = CGDataProvider(data: CFDataCreate(nil, plane.data, plane.width * plane.height)) else { return nil }
        return CGImage(
            width: plane.width,
            height: plane.height,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: plane.bytesPerRow,
            space: Self.maskColorSpace,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent
        )
        #endif
    }
    
    func calculateOpacityFromPressure(pen: PenInfo, pressure: Float) -> Float {
        // Handle negative pressure values by clamping to 0
        let clampedPressure = max(0.0, pressure)
        
        // Pressure is already normalized to 0-1 range
        let p = max(0.0, min(1.0, clampedPressure))
        let pressureRange = pen.opacity - pen.opacityMin
        var opacity = pen.opacityMin + p * pressureRange
        
        // Minimum visible threshold to avoid invisible dabs
        let minVisibleOpacity: Float = 0.03
        opacity = max(opacity, minVisibleOpacity)
        
        // Clamp final
        return max(0.0, min(1.0, opacity))
    }
    
    // Reusable tile buffer to avoid per-dab allocations
    struct TileBuffer {
        var ptr: UnsafeMutablePointer<UInt8>?
        var capacity: Int = 0
        mutating func ensureCapacity(_ needed: Int) {
            if needed <= capacity { return }
            ptr?.deallocate()
            ptr = UnsafeMutablePointer<UInt8>.allocate(capacity: needed)
            capacity = needed
        }
        mutating func zero(count: Int) {
            guard let p = ptr else { return }
            p.initialize(repeating: 0, count: min(count, capacity))
        }
        
        mutating func dealloc() {
            ptr?.deallocate()
            ptr = nil
            capacity = 0
        }
        
        // Add this method
        mutating func allocTile(width: Int, height: Int) -> UnsafeMutablePointer<UInt8> {
            let needed = width * height
            ensureCapacity(needed)
            zero(count: needed)
            return ptr!
        }
    }
    
    // Object pool for frequently allocated TileBuffer objects
    class TileBufferPool {
        static let shared = TileBufferPool()
        
        private var pool: [TileBuffer] = []
        private let lock = NSLock()
        private let maxPoolSize = 10
        
        private init() {}
        
        func getBuffer() -> TileBuffer {
            lock.lock()
            defer { lock.unlock() }
            
            if var buffer = pool.popLast() {
                buffer.zero(count: buffer.capacity)
                return buffer
            }
            
            return TileBuffer()
        }
        
        func returnBuffer(_ buffer: TileBuffer) {
            lock.lock()
            defer { lock.unlock() }
            
            if pool.count < maxPoolSize {
                pool.append(buffer)
            } else {
                var bufferToDealloc = buffer
                bufferToDealloc.dealloc()
            }
        }
        
        func clear() {
            lock.lock()
            defer { lock.unlock() }
            
            for buffer in pool {
                var bufferToDealloc = buffer
                bufferToDealloc.dealloc()
            }
            pool.removeAll()
        }
    }
    
    // Build a circle tile into a reusable buffer. Returns (buf,w,h) and sets tileOrigin.
    private func makeCircleTileInto(
        center: CGPoint,
        radius: CGFloat,
        opacity: Float,
        canvasW: Int,
        canvasH: Int,
        tileOrigin: inout CGPoint,
        buf: inout TileBuffer
    ) -> (UnsafeMutablePointer<UInt8>?, Int, Int) {
        let pad: CGFloat = 2
        let minX = floor(center.x - radius - pad)
        let minY = floor(center.y - radius - pad)
        let maxX = ceil(center.x + radius + pad)
        let maxY = ceil(center.y + radius + pad)
        let w = max(1, Int(maxX - minX))
        let h = max(1, Int(maxY - minY))
        
        // Skip if fully off-canvas
        if Int(maxX) <= 0 || Int(maxY) <= 0 || Int(minX) >= canvasW || Int(minY) >= canvasH {
            return (nil, 0, 0)
        }
        
        // Safety cap (defensive)
        if w > 8192 || h > 8192 { return (nil, 0, 0) }
        
        buf.ensureCapacity(w * h)
        buf.zero(count: w * h)
        tileOrigin = CGPoint(x: minX, y: minY)
        
        let cx = Float(center.x - minX)
        let cy = Float(center.y - minY)
        let r = Float(radius)
        let alpha = UInt8(max(0, min(1, opacity)) * 255)
        
        guard let out = buf.ptr else { return (nil, 0, 0) }
        
        // Pre-calculate constants
        let innerRadius = r - 0.75
        let outerRadius = r + 0.75
        let radiusRange = outerRadius - innerRadius
        
        for j in 0..<h {
            let y = Float(j) + 0.5
            let dy = y - cy
            let dySquared = dy * dy
            
            let row = out.advanced(by: j * w)
            
            // Process pixels in this row
            for i in 0..<w {
                let x = Float(i) + 0.5
                let dx = x - cx
                let dxSquared = dx * dx
                
                // Calculate distance
                let distanceSquared = dxSquared + dySquared
                let distance = sqrtf(distanceSquared)
                
                // Calculate coverage using pre-calculated values
                var coverage: Float
                
                if distance <= innerRadius {
                    coverage = 1.0
                } else if distance >= outerRadius {
                    coverage = 0.0
                } else {
                    // Smoothstep for anti-aliasing
                    let t = (distance - innerRadius) / radiusRange
                    let tSquared = t * t
                    coverage = 1.0 - tSquared * (3.0 - 2.0 * t)
                }
                
                let v = UInt8(min(255, Int(Float(alpha) * coverage + 0.5)))
                if v > row[i] { row[i] = v }
            }
        }
        
        return (buf.ptr, w, h)
    }
    
    // Create a separate function for pencil brushes with alpha falloff
    private func makeFalloffCircleTileInto(
        center: CGPoint,
        radius: CGFloat,
        opacity: Float,
        canvasW: Int,
        canvasH: Int,
        tileOrigin: inout CGPoint,
        buf: inout TileBuffer
    ) -> (UnsafeMutablePointer<UInt8>?, Int, Int) {
        print("[P][falloff_tile] radius=\(radius), opacity=\(opacity)")
        print("DEBUG: makeFalloffCircleTileInto - center: \(center), radius: \(radius), opacity: \(opacity)")
        
        let pad: CGFloat = 2
        let minX = floor(center.x - radius - pad)
        let minY = floor(center.y - radius - pad)
        let maxX = ceil(center.x + radius + pad)
        let maxY = ceil(center.y + radius + pad)
        let w = max(1, Int(maxX - minX))
        let h = max(1, Int(maxY - minY))
        
        print("DEBUG: makeFalloffCircleTileInto - tile bounds: \(w)x\(h)")
        
        // Skip if fully off-canvas
        if Int(maxX) <= 0 || Int(maxY) <= 0 || Int(minX) >= canvasW || Int(minY) >= canvasH {
            print("DEBUG: makeFalloffCircleTileInto - tile off canvas")
            return (nil, 0, 0)
        }
        
        // Safety cap (defensive)
        if w > 8192 || h > 8192 {
            print("DEBUG: makeFalloffCircleTileInto - tile too large")
            return (nil, 0, 0)
        }
        
        buf.ensureCapacity(w * h)
        buf.zero(count: w * h)
        tileOrigin = CGPoint(x: minX, y: minY)
        
        let cx = Float(center.x - minX)
        let cy = Float(center.y - minY)
        let r = Float(radius)
        let alpha = UInt8(max(0, min(1, opacity)) * 255)
        
        print("DEBUG: makeFalloffCircleTileInto - center in tile: (\(cx), \(cy)), radius: \(r), alpha: \(alpha)")
        
        guard let out = buf.ptr else {
            print("DEBUG: makeFalloffCircleTileInto - no buffer pointer")
            return (nil, 0, 0)
        }
        
        var nonZeroCount = 0
        var maxAlpha: UInt8 = 0
        var zeroCount = 0
        
        for j in 0..<h {
            let y = Float(j) + 0.5
            let row = out.advanced(by: j * w)
            for i in 0..<w {
                let x = Float(i) + 0.5
                let dx = x - cx
                let dy = y - cy
                let distance = sqrtf(dx*dx + dy*dy)
                
                // More gradual falloff curve - shift center to have less opaque center
                let normalizedDistance = distance / r
                var coverage: Float
                
                if normalizedDistance <= 0.2 {
                    // Only inner 20% has full opacity (reduced from 50%)
                    coverage = 1.0
                } else if normalizedDistance >= 1.0 {
                    // Beyond radius has no coverage
                    coverage = 0.0
                } else {
                    // More gradual falloff in the outer 80% (increased from 50%)
                    let t = (normalizedDistance - 0.2) / 0.8  // Normalize to [0, 1]
                    
                    // Use a smoother curve for the falloff - shifted S-curve
                    // This gives more gradual falloff and less opaque center
                    let sCurve = t * t * (2.8 - 1.4 * t)  // Standard smoothstep
                    
                    // Apply a power curve to make it even more gradual
                    let gradual = powf(sCurve, 0.7)  // Less than 1 makes it more gradual
                    
                    coverage = 1.0 - gradual
                }
                
                if coverage <= 0 {
                    row[i] = 0  // Explicitly set to 0 for transparency
                    zeroCount += 1
                    continue
                }
                
                let v = UInt8(min(255, Int(Float(alpha) * coverage + 0.5)))
                row[i] = v
                if v > 0 { nonZeroCount += 1 }
                if v > maxAlpha { maxAlpha = v }
            }
        }
        
        print("DEBUG: makeFalloffCircleTileInto - nonZeroCount: \(nonZeroCount), maxAlpha: \(maxAlpha), zeroCount: \(zeroCount)")
        
        return (buf.ptr, w, h)
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
    
    private func makeNoiseTileInto(center: CGPoint, radius: CGFloat,
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
    
    // TODO: Composit noise per stroke instead. Per dab is too slow on cpu.
    private func multiplyAlphaTiles(circlePtr: UnsafePointer<UInt8>, noisePtr: UnsafePointer<UInt8>,
                                    outPtr: UnsafeMutablePointer<UInt8>, w: Int, h: Int) {
        print("[P][multiply_tiles] w=\(w), h=\(h)")
//        print("DEBUG: multiplyAlphaTiles - multiplying \(w)x\(h) tiles")
        
        var nonZeroCount = 0
        var maxResult: UInt8 = 0
        var maskedCount = 0
        var circleZeroCount = 0
        
        // Debug: Check first few values in each tile
        print("DEBUG: First 5 circle values: \(circlePtr[0]), \(circlePtr[1]), \(circlePtr[2]), \(circlePtr[3]), \(circlePtr[4])")
        print("DEBUG: First 5 noise values: \(noisePtr[0]), \(noisePtr[1]), \(noisePtr[2]), \(noisePtr[3]), \(noisePtr[4])")
        
        for i in 0..<(w*h) {
            let ca = Int(circlePtr[i])  // Circle alpha (shape with falloff)
            let ng = Int(noisePtr[i])   // Noise grayscale (texture)
            
            var v: UInt8
            
            if ca == 0 {
                // If circle alpha is 0, result should be 0 (completely transparent)
                v = 0
                maskedCount += 1
                circleZeroCount += 1
            } else {
                // Normalize values to [0, 1] range
                let dab = Float(ca) / 255.0
                let tex = Float(ng) / 255.0
                
                // MSL logic
                let inverted:Float = 1.0 - dab
                let noiseAdd:Float = (dab * 0.94) + tex
                let result:Float = 1.0 - max(0.0, min(1.0, (inverted / noiseAdd)))
                
                // Convert back to [0, 255] range
                v = UInt8(result * 255.0 + 0.5)
            }
            
            outPtr[i] = v
            if v > 0 { nonZeroCount += 1 }
            if v > maxResult { maxResult = v }
        }
        
        print("DEBUG: multiplyAlphaTiles - nonZeroCount: \(nonZeroCount), maxResult: \(maxResult), maskedCount: \(maskedCount), circleZeroCount: \(circleZeroCount)")
    }
    
    
    // Keep only segments whose bounding box intersects the canvas (with margin).
    private func cullDevicePolyline(
        points: [CGPoint],
        pressures: [Int],
        canvasW: Int,
        canvasH: Int,
        margin: CGFloat = 64
    ) -> ([CGPoint], [Int]) {
        guard points.count == pressures.count, points.count >= 2 else { return ([], []) }
        let canvasRect = CGRect(x: -margin, y: -margin, width: CGFloat(canvasW) + 2*margin, height: CGFloat(canvasH) + 2*margin)
        var keptPts: [CGPoint] = []
        var keptPrs: [Int] = []
        func push(_ p: CGPoint, _ pr: Int) {
            if keptPts.isEmpty || keptPts.last! != p {
                keptPts.append(p)
                keptPrs.append(pr)
            }
        }
        // Always start with the first point if it's even remotely near
        if canvasRect.contains(points[0]) {
            push(points[0], pressures[0])
        }
        for i in 0..<(points.count - 1) {
            let p0 = points[i], p1 = points[i + 1]
            let pr0 = pressures[i], pr1 = pressures[i + 1]
            let segMinX = min(p0.x, p1.x), segMaxX = max(p0.x, p1.x)
            let segMinY = min(p0.y, p1.y), segMaxY = max(p0.y, p1.y)
            let segRect = CGRect(x: segMinX, y: segMinY, width: segMaxX - segMinX, height: segMaxY - segMinY)
            if segRect.intersects(canvasRect) {
                // Keep both ends of the segment
                push(p0, pr0)
                push(p1, pr1)
            }
        }
        // If nothing intersects, return empty
        if keptPts.count < 2 { return ([], []) }
        return (keptPts, keptPrs)
    }
    
    func linearResampleAlongSegments(_ raw: [Point], stepPx: CGFloat) -> [ResampledPoint] {
        guard raw.count > 0 else { return [] }
        var out: [ResampledPoint] = []
        for i in 0..<(raw.count - 1) {
            let a = raw[i], b = raw[i+1]
            let ax = CGFloat(a.x), ay = CGFloat(a.y)
            let bx = CGFloat(b.x), by = CGFloat(b.y)
            let dx = bx - ax, dy = by - ay
            let segLen = hypot(dx, dy)
            if segLen <= 0.0001 {
                out.append(ResampledPoint(x: ax, y: ay, p: a.p))
                continue
            }
            let steps = max(1, Int(ceil(segLen / stepPx)))
            for s in 0...steps {
                let t = CGFloat(s) / CGFloat(steps)
                let x = ax + dx * t
                let y = ay + dy * t
                let interpP = a.p + Float(b.p - a.p) * Float(t)  // Interpolate float pressure
                out.append(ResampledPoint(x: x, y: y, p: interpP))
            }
        }
        if let last = raw.last {
            out.append(ResampledPoint(x: CGFloat(last.x), y: CGFloat(last.y), p: last.p))
        }
        return out
    }
    
    func penAffineScale(_ affine: CGAffineTransform) -> CGFloat {
        let a = affine.a, b = affine.b, c = affine.c, d = affine.d
        let sx = sqrt(Double(a*a + c*c))
        let sy = sqrt(Double(b*b + d*d))
        if sx.isFinite && sy.isFinite {
            return CGFloat((sx + sy) / 2.0)
        } else {
            return 1.0
        }
    }
    
    func verticalFlipTransform(canvasHeight: CGFloat) -> CGAffineTransform {
        // Translate down by canvasHeight, then scale Y by -1 to flip vertically.
        // Equivalent to: translate(0, canvasHeight) * scale(1, -1)
        #if os(Linux)
        return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: canvasHeight)
        #else
        return CGAffineTransform(translationX: 0, y: canvasHeight).scaledBy(x: 1.0, y: -1.0)
        #endif
    }
    
}

// MARK: - Test Function with Background Applied AFTER Strokes. Remove?
extension Renderer {
    private static func saveCGImageAsPNG(_ image: CGImage, to path: String) {
        #if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            print("Failed to create image destination")
            return
        }
        
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            print("Failed to finalize image destination")
        }
        #elseif canImport(ImageIO)
        // ImageIO available but UTType not (older macOS)
        let url = URL(fileURLWithPath: path)
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
            print("Failed to create image destination")
            return
        }
        
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            print("Failed to finalize image destination")
        }
        #elseif os(Linux)
        // Linux fallback: write raw RGBA data as PPM (simple format) or use Cairo directly
        // For a proper PNG, integrate with a Linux PNG library or Silica's export capabilities
        print("WARNING: PNG export not yet implemented for Linux. Path: \(path)")
        // TODO: Implement PNG export on Linux using Cairo's cairo_surface_write_to_png
        // or a cross-platform Swift PNG library
        #endif
    }
}

// MARK: - Helper function to create bitmap context
func createBitmapContext(size: CGSize, scale: CGFloat) -> CGContext {
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

// Add the StrokeRecord struct that's used in the new functions
struct StrokeRecord {
    var points: [Point]
    var pen: PenInfo
    var penMatrixScale: CGFloat
    var penMatrixAffine: CGAffineTransform?
}
