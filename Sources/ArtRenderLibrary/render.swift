import Foundation
#if os(Linux)
import Silica
import CoreFoundation
import Cairo
import JPEG
#elseif os(macOS)
import CoreGraphics
import Accelerate
import CoreText
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

struct StrokeRecord {
    var points: [Point]
    var pen: PenInfo
    var penMatrixScale: CGFloat
    var penMatrixAffine: CGAffineTransform?
    var isPolyline: Bool
}

public struct PasteMask {
    public var inv0: SIMD4<Float>
    public var inv1: SIMD4<Float>
    public var rect: SIMD4<Float>
    public var flags: SIMD4<Float>       // x: 0 = keep, 1 = erase
    
    public init(inv: CGAffineTransform, rectXYWH: [Float], erase: Bool) {
        self.inv0 = SIMD4<Float>(Float(inv.a), Float(inv.c), Float(inv.tx), 0)
        self.inv1 = SIMD4<Float>(Float(inv.b), Float(inv.d), Float(inv.ty), 0)
        self.rect = SIMD4<Float>(rectXYWH[0], rectXYWH[1], rectXYWH[2], rectXYWH[3])
        self.flags = erase ? SIMD4<Float>(1, 0, 0, 0) : SIMD4<Float>(0, 0, 0, 0)
    }
}

public struct PasteLayerMeta {
    public var row0: SIMD4<Float>, row1: SIMD4<Float>
    public var edgeWidth: Float
    public var maskCount: UInt32
    public var pad0: UInt32, pad1: UInt32
    
    public init(invAffine: CGAffineTransform, edgeWidth: Float = 0.75, maskCount: UInt32) {
        self.row0 = SIMD4<Float>(Float(invAffine.a), Float(invAffine.c), Float(invAffine.tx), 0)
        self.row1 = SIMD4<Float>(Float(invAffine.b), Float(invAffine.d), Float(invAffine.ty), 0)
        self.edgeWidth = edgeWidth
        self.maskCount = maskCount
        self.pad0 = 0; self.pad1 = 0
    }
}   // MemoryLayout<PasteLayerMeta>.stride must print 48; PasteMask stride 64

public struct CutMeta {
    // Destination GPU/device -> selection frame.
    public var row0: SIMD4<Float>
    public var row1: SIMD4<Float>
    
    // Rectangle in selection-frame coordinates:
    // x, y, width, height.
    public var rect: SIMD4<Float>
    
    public var edgeWidth: Float
    public var padding0: UInt32
    public var padding1: UInt32
    public var padding2: UInt32
    
    public init(
        inverseAffine: CGAffineTransform,
        rect: [Float],
        edgeWidth: Float = 0.75
    ) {
        self.row0 = SIMD4<Float>(
            Float(inverseAffine.a),
            Float(inverseAffine.c),
            Float(inverseAffine.tx),
            0
        )
        
        self.row1 = SIMD4<Float>(
            Float(inverseAffine.b),
            Float(inverseAffine.d),
            Float(inverseAffine.ty),
            0
        )
        
        self.rect = SIMD4<Float>(
            rect[0],
            rect[1],
            rect[2],
            rect[3]
        )
        
        self.edgeWidth = edgeWidth
        self.padding0 = 0
        self.padding1 = 0
        self.padding2 = 0
    }
}


enum LayerOperation {
    case stroke(StrokeRecord)
    case cut(meta: CutMeta)
    case paste(
        segments: [GPUSplineSegment],
        color: SIMD4<Float>,
        isEraser: Bool,
        isMarker: Bool,
        meta: PasteLayerMeta,
        masks: [PasteMask],
        sourceToDestinationGPU: CGAffineTransform,
        isMerge: Bool,          // from ResolvedPasteRender.isMerge
        mergeID: UInt64)        // identifies ONE merge action's group batch
}

struct StrokeMask: Equatable {
    var m1: CGAffineTransform        // action-time view: canvas -> selection frame
    var rect: [Float]                // selection rect x,y,w,h
    var accRef: CGAffineTransform    // stroke's accumulated transform when recorded
    var erase: Bool                  // false = keep, true = erase
}

private struct ResolvedStroke {
    let stroke: StrokeRecord
    let accumulatedDeviceTransform: CGAffineTransform
    let sourceLayerIndex: Int
    let selectionRect: [Float]
    var masks: [StrokeMask] = []     // NEW — shape cases need no edits (default [])
}

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
    
//    public static var droppedPasteMaskCount = 0
    
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
        // Sanity check
//        print("PasteLayerMeta stride:", MemoryLayout<PasteLayerMeta>.stride, "should be 48")
//        print("PasteMask stride:", MemoryLayout<PasteMask>.stride, "should be 64")
//        Self.droppedPasteMaskCount = 0
        
        // MAKE MAIN CONTEXT Y-DOWN
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -CGFloat(context.height))
        
        // Start with transparent context
        Self.clearContext(context, rect: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        
        // Get the view matrix from art file
        let viewMatrix = art.viewMatrix
        let baseTransform = transformFromMatrix(viewMatrix, scale: scale)
        // TEMPORARY, for diagnosis only:
//        let baseTransform = CGAffineTransform.identity
        print("actions per layer:",
              Dictionary(grouping: art.actions, by: { $0["layer"] as? Int ?? -1 })
            .mapValues(\.count))
        
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
                
                // MAKE PAPER CONTEXT Y-DOWN
                paperContext.scaleBy(x: 1, y: -1)
                paperContext.translateBy(x: 0, y: -CGFloat(paperContext.height))
                
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
        
//#if os(macOS)
////        Self.droppedPasteMaskCount = 25
//        if Self.droppedPasteMaskCount > 0 {
//            print("⚠ \(Self.droppedPasteMaskCount) paste mask(s) dropped — content may overflow its cut")
//            let text = "⚠ \(Self.droppedPasteMaskCount) paste mask(s) dropped — content may overflow its cut"
//            let font = CTFontCreateWithName("Helvetica Bold" as CFString, 28, nil)
//            let attrs: [CFString: Any] = [
//                kCTFontAttributeName: font,
//                kCTForegroundColorAttributeName: CGColor(srgbRed: 0.8, green: 0, blue: 0, alpha: 1),
//                kCTBaselineOffsetAttributeName: -8.0
//            ]
//            let attrStr = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
//            let line = CTLineCreateWithAttributedString(attrStr)
//
//            context.saveGState()
//            context.translateBy(x: 24, y: 24)
//            context.scaleBy(x: 1, y: -1)     // CoreText is y-up; main context is flipped y-down
//            CTLineDraw(line, context)
//            context.restoreGState()
//        }
//#endif
        
        
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
    
    private func renderLayerIsolated(
        layer: [String: Any],
        layerIndex: Int,
        art: ArtParser,
        baseTransform: CGAffineTransform,
        layerOpacity: Float
    ) -> CGImage? {
        
        guard let matrix = layer["matrix"] as? [[Float]] else { return nil }
        
        // 1. Pure Y-DOWN: Use toDirectCGTransform for everything
        let layerTransform = toDirectCGTransform(matrix)
        let artToDevice = CGAffineTransformConcat(layerTransform, baseTransform)
        
//        let viewMatrix = art.viewMatrix
//        let yDownBaseTransform = baseTransform // They are identical now
        
        let layerContext = createBitmapContext(size: canvasSize, scale: scale)
        Self.clearContext(layerContext, rect: CGRect(x: 0, y: 0, width: layerContext.width, height: layerContext.height))
        
        // 2. Pure Y-DOWN: flipTransform MUST be nil
        let flipTransform: CGAffineTransform? = nil
        
        var layerOps: [LayerOperation] = []
//        var pendingCutRect: [Float] = []
        
        var currentPen = defaultPenInfo()
        var penMatrixScale: CGFloat = 1.0
        
        for (actionIdx, action) in art.actions.enumerated() {
            guard let actionLayer = action["layer"] as? Int,
                  actionLayer == layerIndex,
                  let actionName = action["action_name"] as? String else {
                continue
            }
            
            switch actionName {
                case "pen_properties": actionPenProperties(action: action, currentPen: &currentPen)
                case "pen_matrix": actionPenMatrix(action: action, currentPen: &currentPen, penMatrixScale: &penMatrixScale)
                case "is_eraser": actionIsEraser(action: action, currentPen: &currentPen)
                case "pen_color": actionPenColor(action: action, currentPen: &currentPen)
                    
                case "stroke":
                    var tempStrokes: [StrokeRecord] = []
                    actionStroke(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                    layerOps.append(contentsOf: tempStrokes.map { .stroke($0) })
                    
                case "polyline":
                    var tempStrokes: [StrokeRecord] = []
                    actionPolyline(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                    layerOps.append(contentsOf: tempStrokes.map { .stroke($0) })
                    
                case "rect":
                    var tempStrokes: [StrokeRecord] = []
                    actionRect(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                    layerOps.append(contentsOf: tempStrokes.map { .stroke($0) })
                    
                case "ellipse":
                    var tempStrokes: [StrokeRecord] = []
                    actionEllipse(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                    layerOps.append(contentsOf: tempStrokes.map { .stroke($0) })
                    
                case "cut":
                    if let rect = parseFloatArray(action["selection_rect"]), rect.count == 4 {
                        let m1: CGAffineTransform
                        if let own = parseMatrixRobust(action["matrix_1"]) {
                            m1 = transformFromMatrix(own.map { $0.map { Float($0) } }, scale: 1.0)
                        } else if let next = nextPasteViewMatrix(in: art.actions, after: actionIdx) {
                            m1 = next
                        } else {
                            m1 = .identity  // fallback: treat rect as current device px
                            print("CUT: no matrix_1 (own or following paste) — rect used as device px")
                        }
                        layerOps.append(.cut(meta: CutMeta(
                            inverseAffine: baseTransform.inverted().concatenating(m1),
                            rect: rect, edgeWidth: 0.75)))
                    }
                    
                case "paste_layer":
                    layerOps.append(contentsOf: actionPasteLayerOps(
                        action: action,
                        art: art,
                        targetLayerIndex: layerIndex,
                        actionIndex: actionIdx,
                        dstPenAffine: currentPen.penMatrixAffine ?? .identity,
                        baseTransform: baseTransform,
                        yDownBaseTransform: baseTransform,
                        flipTransform: flipTransform))
                    
                case "merge_layer":
                    layerOps.append(contentsOf: actionMergeLayerOps(
                        action: action,
                        art: art,
                        targetLayerIndex: layerIndex,
                        actionIndex: actionIdx,
                        baseTransform: baseTransform,
                        flipTransform: nil))
                    
                default: break
            }
        }
        
        // ── GP Export: accumulate layer data, skip rasterization ──
        if gpExportMode {
            let layerName = layer["name"] as? String ?? "Layer \(layerIndex)"
            let layerVisible = (layer["visible"] as? Int ?? 1) != 0
            let exportCanvasHeight = canvasSize.height * scale
            
            // Everything drawn after a paste/merge is appended to that paste's GP
            // layer, so erasers erase the pasted content (and everything drawn on
            // that layer before them). The destination layer's own record holds
            // only what was drawn before the first paste. Cuts erase everything
            // below them at action time: the entry joins the pending stream (it
            // lands at its position in whichever record is active) and is
            // replicated into every lower record.
            var records: [GPExportLayer] = []
            var pendingItems: [GPExportItem] = []
            var writingIndex: Int? = nil      // record the pending stream flushes into (nil = new base record)
            
            
            // Erasers act on the flat composite: replicate an eraser entry into
            // lower records whose content it touches — earlier paste groups AND
            // earlier records. Bounds-checked so distant layers get nothing.
            func replicateEraserDown(_ s: GPExportStroke, from: Int = 0, below idx: Int) {
                let reach = strokeBounds([s], includeErasers: true)
                guard !reach.isNull else { return }
                for i in from..<idx where !recordBounds[i].isNull && recordBounds[i].intersects(reach) {
                    records[i].strokes.append(s)
                }
            }
            
            var recordBounds: [CGRect] = []    // content bounds per record, JSON space
            
            func flushPending() {
                let items = pendingItems
                pendingItems = []
                if let w = writingIndex {
                    guard !items.isEmpty else { return }
                    var appended = exportGPStrokes(
                        items: items, artToDevice: artToDevice, canvasHeight: exportCanvasHeight,
                        resampleStep: gpExportResampleStep, catmullRom: gpExportCatmullRom)
                    // in-position cut entries: keep only where there is content to erase
                    // (the paste layer's own strokes count — a cut over the island is real)
                    let contentBox = unionBounds(recordBounds[w], strokeBounds(appended))
                    appended = dropNoOpCutEntries(appended, contentBox: contentBox)
                    records[w].strokes.append(contentsOf: appended)
                    recordBounds[w] = unionBounds(recordBounds[w], strokeBounds(appended))
                    
                    // erasers drawn on the user-facing layer: reach down
                    for s in appended where s.is_eraser {
                        replicateEraserDown(s, below: w)
                    }
                } else {
                    guard items.contains(where: { item -> Bool in
                        if case .stroke = item { return true }
                        return false
                    }) else { return }
                    var layer = exportGPLayer(
                        items: items,
                        artToDevice: artToDevice,
                        canvasHeight: exportCanvasHeight,
                        layerName: layerName,
                        layerOpacity: layerOpacity,
                        layerVisible: layerVisible,
                        resampleStep: gpExportResampleStep,
                        catmullRom: gpExportCatmullRom)
                    layer.strokes = dropNoOpCutEntries(layer.strokes, contentBox: strokeBounds(layer.strokes))
                    records.append(layer)
                    recordBounds.append(strokeBounds(layer.strokes))
                    writingIndex = records.count - 1
                }
            }
            
            var currentPen = defaultPenInfo()
            var penMatrixScale: CGFloat = 1.0
            var actionLayerMatrix = initialActionLayerMatrix(layerIndex: layerIndex, art: art)
            
            for (actionIdx, action) in art.actions.enumerated() {
                guard let actionLayer = action["layer"] as? Int,
                      actionLayer == layerIndex,
                      let actionName = action["action_name"] as? String else { continue }
                
                switch actionName {
                    case "pen_properties":
                        actionPenProperties(action: action, currentPen: &currentPen)
                    case "pen_matrix":
                        actionPenMatrix(action: action, currentPen: &currentPen, penMatrixScale: &penMatrixScale)
                    case "is_eraser":
                        actionIsEraser(action: action, currentPen: &currentPen)
                    case "pen_color":
                        actionPenColor(action: action, currentPen: &currentPen)
                    case "layer_matrix":
                        if let mRaw = parseMatrixRobust(action["matrix"]) {
                            actionLayerMatrix = transformFromMatrix(mRaw.map { $0.map { Float($0) } }, scale: 1.0)
                        }
                        
                    case "stroke", "polyline", "rect", "ellipse":
                        var tempStrokes: [StrokeRecord] = []
                        switch actionName {
                            case "stroke":
                                actionStroke(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                            case "polyline":
                                actionPolyline(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                            case "rect":
                                actionRect(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                            default:
                                actionEllipse(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                        }
                        pendingItems.append(contentsOf: tempStrokes.map { GPExportItem.stroke($0) })
                        
                    case "cut":
                        guard let devCorners = cutRectDeviceCorners(
                            action: action, art: art, actionIndex: actionIdx, baseTransform: artToDevice) else { break }
                        // in-position entry: erases the active record's content drawn before it
                        pendingItems.append(.cut(corners: devCorners))
                        // geometric replication: the cut erases everything below it at
                        // action time — but only lower records whose CONTENT intersects
                        // the rect need the entry.
                        let cutEntry = GPExportStroke(
                            color: [0, 0, 0, 1], is_eraser: false, hardness: 1.0,
                            points: devCorners.map { GPExportPoint(x: Float($0.x), y: Float($0.y), radius: 1.0, opacity: 1.0) },
                            cut_rect: true)
                        var cbMinX = devCorners[0].x, cbMaxX = devCorners[0].x
                        var cbMinY = devCorners[0].y, cbMaxY = devCorners[0].y
                        for p in devCorners {
                            cbMinX = min(cbMinX, p.x); cbMaxX = max(cbMaxX, p.x)
                            cbMinY = min(cbMinY, p.y); cbMaxY = max(cbMaxY, p.y)
                        }
                        let cutBox = CGRect(x: cbMinX, y: cbMinY, width: cbMaxX - cbMinX, height: cbMaxY - cbMinY)
                        for i in 0..<(writingIndex ?? records.count) {
                            if !recordBounds[i].isNull && recordBounds[i].intersects(cutBox) {
                                records[i].strokes.append(cutEntry)
                            }
                        }
                        
                    case "paste_layer":
                        if let resolved = resolvePasteRender(
                            action: action, art: art, targetLayerIndex: layerIndex, actionIndex: actionIdx,
                            dstPenAffine: currentPen.penMatrixAffine ?? .identity,
                            dstLayerMatrix: actionLayerMatrix,
                            baseTransform: artToDevice) {
                            let groupLayers = exportPasteLayers(
                                resolved: resolved, actionIndex: actionIdx, isMerge: false,
                                destLayerName: layerName, destLayerOpacity: layerOpacity, colorAlpha: 1.0,
                                canvasHeight: exportCanvasHeight,
                                resampleStep: gpExportResampleStep, catmullRom: gpExportCatmullRom)
                            if !groupLayers.isEmpty {
                                flushPending()
                                let firstNew = records.count
                                records.append(contentsOf: groupLayers)
                                recordBounds.append(contentsOf: groupLayers.map { strokeBounds($0.strokes) })
                                // Pasted erasers act on the flat composite too: earlier
                                // groups of this paste (below their own layer in the
                                // stack) and everything under the paste. Their own
                                // group's content is already handled in-position.
                                for gi in groupLayers.indices {
                                    for s in groupLayers[gi].strokes where s.is_eraser {
                                        replicateEraserDown(s, below: firstNew + gi)
                                    }
                                }
                                writingIndex = records.count - 1
                            }
                        }
                        
                    case "merge_layer":
                        let opacitySrc = action["opacity_src"] as? Float ?? 1.0
                        if let resolved = resolveMergeRender(
                            action: action, art: art, targetLayerIndex: layerIndex, baseTransform: artToDevice) {
                            let groupLayers = exportPasteLayers(
                                resolved: resolved, actionIndex: actionIdx, isMerge: true,
                                destLayerName: layerName, destLayerOpacity: layerOpacity, colorAlpha: opacitySrc,
                                canvasHeight: exportCanvasHeight,
                                resampleStep: gpExportResampleStep, catmullRom: gpExportCatmullRom)
                            if !groupLayers.isEmpty {
                                flushPending()
                                let firstNew = records.count
                                records.append(contentsOf: groupLayers)
                                recordBounds.append(contentsOf: groupLayers.map { strokeBounds($0.strokes) })
                                // MERGE: erasers from the merged layer erase only that layer's
                                // own content — the sibling groups of this merge (from: firstNew).
                                // They must NOT reach the destination's records below.
                                for gi in groupLayers.indices {
                                    for s in groupLayers[gi].strokes where s.is_eraser {
                                        replicateEraserDown(s, from: firstNew, below: firstNew + gi)
                                    }
                                }
                                writingIndex = records.count - 1
                            }
                        }
                        
                    default: break
                }
            }
            
            flushPending()
            gpExportLayers.append(contentsOf: records)
            return nil
        }
        
#if os(macOS)
        // Render all strokes for this layer with Metal if available
        //        let useSegmentRendering: Bool = true
        print("useSegmentRendering: ", useSegmentRendering )
        if useSegmentRendering,
           let mr = self.metalRenderer,
           !layerOps.isEmpty,
           MetalRenderer.useGPURendering {
            
            do {
                let w = Int(self.canvasSize.width * self.scale)
                let h = Int(self.canvasSize.height * self.scale)
                
                if let image = try mr.renderSegmentGroupsInOrderSync(
                    layerOps: layerOps,
                    width: w,
                    height: h,
                    artToDevice: artToDevice,
                    flipTransform: flipTransform
                ) {
                    // 3. Pure Y-DOWN: Do NOT flip the image. Metal outputs Y-DOWN, CGContext expects Y-DOWN.
                    return image
                }
                return nil
                
            } catch {
                print("Segment rendering failed: \(error) \n Rendering on CPU.")
                return renderLayerWithCPU(
                    art: art,
                    layerIndex: layerIndex,
                    artToDevice: artToDevice,
                    context: layerContext
                )
            }
        } else if let mr = self.metalRenderer, !layerOps.isEmpty, MetalRenderer.useGPURendering {
            // ── GPU stamp path (re-enabled) ──
            // Resampled-stamp rendering (kept for its tapers). Cuts are CoreGraphics rect
            // erases on the compositing context; pastes/merges render as isolated GPU stamp
            // layers with the selection transforms baked into the point data, and their
            // masks are applied as CPU inside/outside erases.
            if let image = renderLayerWithGPUStamps(
                art: art,
                layerIndex: layerIndex,
                artToDevice: artToDevice,
                context: layerContext,
                metalRenderer: mr
            ) {
                return image
            }
            // Stamp path failed (layerContext may hold partial output) — CPU fallback on a fresh context
            let freshContext = createBitmapContext(size: canvasSize, scale: scale)
            Self.clearContext(freshContext, rect: CGRect(x: 0, y: 0, width: freshContext.width, height: freshContext.height))
            return renderLayerWithCPU(art: art, layerIndex: layerIndex, artToDevice: artToDevice, context: freshContext)
        }
#endif
        // ── CPU path (re-enabled) ──
        // Linux / no Metal renderer / GPU rendering disabled: action-order rendering with
        // CoreGraphics cut rectangles and isolated paste layers. Noise stays off.
        return renderLayerWithCPU(
            art: art,
            layerIndex: layerIndex,
            artToDevice: artToDevice,
            context: layerContext
        )
    }
   
    // CPU Fallback Function
    private func renderLayerWithCPU(
        art: ArtParser,
        layerIndex: Int,
        artToDevice: CGAffineTransform,
        context: CGContext
    ) -> CGImage? {
        
        var currentPen = defaultPenInfo()
        var penMatrixScale: CGFloat = 1.0
        var actionLayerMatrix = initialActionLayerMatrix(layerIndex: layerIndex, art: art)
        
        for (actionIdx, action) in art.actions.enumerated() {
            guard let actionLayer = action["layer"] as? Int,
                  actionLayer == layerIndex,
                  let actionName = action["action_name"] as? String else { continue }
            
            switch actionName {
                case "pen_properties":
                    actionPenProperties(action: action, currentPen: &currentPen)
                case "pen_matrix":
                    actionPenMatrix(action: action, currentPen: &currentPen, penMatrixScale: &penMatrixScale)
                case "is_eraser":
                    actionIsEraser(action: action, currentPen: &currentPen)
                case "pen_color":
                    actionPenColor(action: action, currentPen: &currentPen)
                    
                case "stroke", "polyline", "rect", "ellipse":
                    var tempStrokes: [StrokeRecord] = []
                    switch actionName {
                        case "stroke":
                            actionStroke(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                        case "polyline":
                            actionPolyline(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                        case "rect":
                            actionRect(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                        default:
                            actionEllipse(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                    }
                    for stroke in tempStrokes {
                        drawStrokeOnCPU(stroke: stroke, lb: artToDevice, accNow: .identity, destMap: .identity, context: context)
                    }
                    
                case "cut":
                    applyCutRectCPU(context: context, action: action, art: art, actionIndex: actionIdx, baseTransform: artToDevice)
                    
                case "paste_layer":
                    guard let resolved = resolvePasteRender(
                        action: action, art: art, targetLayerIndex: layerIndex, actionIndex: actionIdx,
                        dstPenAffine: currentPen.penMatrixAffine ?? .identity,
                        dstLayerMatrix: actionLayerMatrix,
                        baseTransform: artToDevice) else { continue }
                    renderPasteGroupsCPU(resolved: resolved, context: context)
                    
                case "merge_layer":
                    guard let resolved = resolveMergeRender(
                        action: action, art: art, targetLayerIndex: layerIndex,
                        baseTransform: artToDevice) else { continue }
                    renderPasteGroupsCPU(resolved: resolved, context: context)
                    
                case "layer_matrix":
                    if let mRaw = parseMatrixRobust(action["matrix"]) {
                        actionLayerMatrix = transformFromMatrix(mRaw.map { $0.map { Float($0) } }, scale: 1.0)
                    }
                    
                default: break
            }
        }
        
        // Render embedded images (unchanged — this code already draws in device coords)
        context.saveGState()
        context.translateBy(x: CGFloat(context.width) / 2.0, y: CGFloat(context.height) / 2.0)
        context.concatenate(artToDevice)
        renderEmbeddedImages(art: art, in: context)
        context.restoreGState()
        
        return context.makeImage()
    }
    
    private func drawStrokeOnCPU(
        stroke: StrokeRecord,
        lb: CGAffineTransform,
        accNow: CGAffineTransform,
        destMap: CGAffineTransform,
        context: CGContext
    ) {
        guard !stroke.points.isEmpty else { return }
        let (stampStepPx, effectiveRadiusScale) = strokeScaleParams(stroke: stroke, lb: lb, accNow: accNow, destMap: destMap)
        
        let splinePoints = buildResampledStrokeWithSpline(
            stroke.points, stepPx: stampStepPx, samplesPerSegment: 6, gamma: 1.0, isPolyline: stroke.isPolyline)
        var resampledArt: [ResampledPoint] = splinePoints.map {
            ResampledPoint(x: CGFloat($0.x), y: CGFloat($0.y), p: $0.p)
        }
        guard !resampledArt.isEmpty else { return }
        
        applyEndTaperToResampled(&resampledArt, tailSamples: 4, ease: 1.8)
        
        var deviceResampled: [ResampledPoint] = []
        deviceResampled.reserveCapacity(resampledArt.count)
        for rp in resampledArt {
            // Device y-down coords go into the context DIRECTLY (see compositeImageCPU note).
            let pt = devicePointForStroke(CGPoint(x: rp.x, y: rp.y), stroke: stroke,
                                          lb: lb, accNow: accNow, destMap: destMap)
            deviceResampled.append(ResampledPoint(location: pt, pressure: rp.pressure))
        }
        
        renderStroke_drawDeviceResampled(
            resampledPoints: deviceResampled, pen: stroke.pen, in: context, radiusScale: effectiveRadiusScale)
    }
    
    /// Full point transform: pen affine -> lb (Lsrc ∘ B) -> accNow -> destMap (D).
    /// Identical chain to the segment path's buildOpFromStroke + GPU D — no flips.
    private func devicePointForStroke(
        _ p: CGPoint,
        stroke: StrokeRecord,
        lb: CGAffineTransform,
        accNow: CGAffineTransform,
        destMap: CGAffineTransform
    ) -> CGPoint {
        var pt = p
        if let affine = stroke.pen.penMatrixAffine { pt = pt.applying(affine) }
        pt = pt.applying(lb)
        pt = pt.applying(accNow)
        pt = pt.applying(destMap)
        return pt
    }
    
    private func renderPasteGroupsCPU(resolved: ResolvedPasteRender, context: CGContext) {
        // MERGE: composite the source layer as an isolated fragment — its erasers
        // erase only the merged layer's own content (reference: flatten the source,
        // then composite the result over the destination). PASTES stay flat.
        if resolved.isMerge {
            let mergeAlpha = CGFloat(min(max(resolved.groups.first?.color.w ?? 1, 0), 1))
            let fragment = createBitmapContext(size: canvasSize, scale: scale)
            Self.clearContext(fragment, rect: CGRect(x: 0, y: 0, width: fragment.width, height: fragment.height))
            for g in resolved.groups {
                renderPasteGroupCPU(g: g, resolved: resolved, target: fragment, groupAlpha: 1.0)
            }
            if let image = fragment.makeImage() {
                compositeImageCPU(image: image, alpha: mergeAlpha, into: context)
            }
            return
        }
        for g in resolved.groups {
            renderPasteGroupCPU(g: g, resolved: resolved, target: context,
                                groupAlpha: CGFloat(min(max(g.color.w, 0), 1)))
        }
    }
    
    /// One paste/merge group into `target` (the layer context, or a merge fragment).
    private func renderPasteGroupCPU(g: PasteRenderGroup, resolved: ResolvedPasteRender,
                                     target: CGContext, groupAlpha: CGFloat) {
        if g.maskEntries.isEmpty && !g.isEraser && groupAlpha >= 1.0 {
            for stroke in g.strokes {
                drawStrokeOnCPU(stroke: stroke, lb: g.lb, accNow: g.accNow,
                                destMap: resolved.destMap, context: target)
            }
            return
        }
        let temp = createBitmapContext(size: canvasSize, scale: scale)
        Self.clearContext(temp, rect: CGRect(x: 0, y: 0, width: temp.width, height: temp.height))
        for stroke in g.strokes {
            var s = stroke
            if g.isEraser {
                // alpha coverage; composited with .destinationOut below
                s.pen.isEraser = false
                s.pen.isMarker = false
            }
            drawStrokeOnCPU(stroke: s, lb: g.lb, accNow: g.accNow, destMap: resolved.destMap, context: temp)
        }
        for m in g.maskEntries {
            applyPasteMaskCPU(context: temp, maskInv: m.inv, rect: m.rect, erase: m.erase, destMap: resolved.destMap)
        }
        guard let image = temp.makeImage() else { return }
        compositeImageCPU(image: image, erase: g.isEraser, alpha: groupAlpha, into: target)
    }
    
    /// Composites a layer-space CGImage into a (y-up) layer context with a RAW draw
    /// (pixel-exact copy; the y-down main context's raw draw fixes final orientation).
    private func compositeImageCPU(image: CGImage, erase: Bool = false, alpha: CGFloat = 1.0, into context: CGContext) {
        context.saveGState()
        if erase { context.setBlendMode(.destinationOut) }
        if alpha < 1.0 { context.setAlpha(alpha) }
        context.draw(image, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        context.restoreGState()
    }
    
    /// Cut rect corners in device y-down space (frame math + y conversion).
    func cutRectDeviceCorners(action: [String: Any], art: ArtParser,
                              actionIndex: Int, baseTransform: CGAffineTransform) -> [CGPoint]? {
        guard let rect = parseFloatArray(action["selection_rect"]), rect.count == 4 else { return nil }
        let m1: CGAffineTransform
        if let own = parseMatrixRobust(action["matrix_1"]) {
            m1 = transformFromMatrix(own.map { $0.map { Float($0) } }, scale: 1.0)
        } else if let next = nextPasteViewMatrix(in: art.actions, after: actionIndex) {
            m1 = next
        } else {
            m1 = .identity
            print("CUT: no matrix_1 (own or following paste) — rect used as device px")
        }
        let deviceToFrame = baseTransform.inverted().concatenating(m1)
        let det = deviceToFrame.a * deviceToFrame.d - deviceToFrame.b * deviceToFrame.c
        guard abs(det) > 1e-12 else { return nil }
        let frameToDevice = deviceToFrame.inverted()
        let rectYFlip = verticalFlipTransform(canvasHeight: canvasSize.height * scale)
        let x = CGFloat(rect[0]), y = CGFloat(rect[1]), w = CGFloat(rect[2]), h = CGFloat(rect[3])
        return [
            CGPoint(x: x, y: y), CGPoint(x: x + w, y: y),
            CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)
        ].map { $0.applying(frameToDevice).applying(rectYFlip) }
    }
    
    /// Paste-mask rect corners in device y-down space (frame math + y conversion + destMap).
    func maskRectDeviceCorners(maskInv: CGAffineTransform, rect: [Float],
                               destMap: CGAffineTransform) -> [CGPoint]? {
        guard rect.count == 4 else { return nil }
        let det = maskInv.a * maskInv.d - maskInv.b * maskInv.c
        guard abs(det) > 1e-12 else { return nil }
        let frameToSource = maskInv.inverted()
        let rectYFlip = verticalFlipTransform(canvasHeight: canvasSize.height * scale)
        let x = CGFloat(rect[0]), y = CGFloat(rect[1]), w = CGFloat(rect[2]), h = CGFloat(rect[3])
        return [
            CGPoint(x: x, y: y), CGPoint(x: x + w, y: y),
            CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)
        ].map { $0.applying(frameToSource).applying(destMap).applying(rectYFlip) }
    }
    
    private func applyCutRectCPU(context: CGContext, action: [String: Any], art: ArtParser,
                                 actionIndex: Int, baseTransform: CGAffineTransform) {
        guard let corners = cutRectDeviceCorners(action: action, art: art,
                                                 actionIndex: actionIndex, baseTransform: baseTransform) else { return }
        context.saveGState()
        context.setBlendMode(.clear)
        context.beginPath()
        context.addLines(between: corners)
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }
    
    private func applyPasteMaskCPU(context: CGContext, maskInv: CGAffineTransform, rect: [Float],
                                   erase: Bool, destMap: CGAffineTransform) {
        guard let corners = maskRectDeviceCorners(maskInv: maskInv, rect: rect, destMap: destMap) else { return }
        context.saveGState()
        context.setBlendMode(.clear)
        context.beginPath()
        if erase {
            context.addLines(between: corners)
            context.closePath()
            context.fillPath()
        } else {
            context.addRect(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            context.addLines(between: corners)
            context.closePath()
            context.fillPath(using: .evenOdd)
//            context.drawPath(using: .eoFill) // alternative
        }
        context.restoreGState()
    }
    
    /// Per-stroke export body. pointTransform is applied AFTER the pen affine
    /// (art -> device y-down). radiusScale/totalScale come fully computed from the
    /// caller (regular layers: averaged; pastes: widest-axis selection rule).
    func exportGPStroke(stroke: StrokeRecord,
                        pointTransform: CGAffineTransform,
                        flipTransform: CGAffineTransform,
                        radiusScale: CGFloat,
                        totalScale: CGFloat,
                        resampleStep: CGFloat,
                        pencilStep: CGFloat,
                        catmullRom: Bool) -> GPExportStroke? {
        guard !stroke.points.isEmpty else { return nil }
        var exportPoints: [GPExportPoint] = []
        
        if catmullRom {
            exportPoints.reserveCapacity(stroke.points.count)
            for point in stroke.points {
                let pressure = Float(max(0.0, point.p))
                var pt = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
                if let affine = stroke.pen.penMatrixAffine { pt = pt.applying(affine) }
                pt = pt.applying(pointTransform)
                pt = pt.applying(flipTransform)
                let (radius, opacity) = pressureToRadiusOpacity(
                    pressure: pressure, pen: stroke.pen, radiusScale: radiusScale, gamma: 1.0)
                exportPoints.append(GPExportPoint(x: Float(pt.x), y: Float(pt.y), radius: Float(radius), opacity: opacity))
            }
        } else {
            let targetStepInDevicePx: CGFloat = stroke.pen.type == 1 ? pencilStep : resampleStep
            let stampStepPx = targetStepInDevicePx / totalScale
            let splinePoints = buildResampledStrokeWithSpline(
                stroke.points, stepPx: stampStepPx, samplesPerSegment: 6, gamma: 1.0, isPolyline: stroke.isPolyline)
            let resampledArt: [ResampledPoint] = splinePoints.map {
                ResampledPoint(x: CGFloat($0.x), y: CGFloat($0.y), p: $0.p)
            }
            if resampledArt.isEmpty { return nil }
            // (end taper stays disabled for export, as before)
            exportPoints.reserveCapacity(resampledArt.count)
            for rp in resampledArt {
                var pt = CGPoint(x: rp.x, y: rp.y)
                if let affine = stroke.pen.penMatrixAffine { pt = pt.applying(affine) }
                pt = pt.applying(pointTransform)
                pt = pt.applying(flipTransform)
                let (radius, opacity) = pressureToRadiusOpacity(
                    pressure: rp.pressure, pen: stroke.pen, radiusScale: radiusScale, gamma: 1.0)
                exportPoints.append(GPExportPoint(x: Float(pt.x), y: Float(pt.y), radius: Float(radius), opacity: opacity))
            }
        }
        guard !exportPoints.isEmpty else { return nil }
        
        let hardness: Float
        if stroke.pen.type == 1 {
            hardness = 0.946
        } else if stroke.pen.opacityMin > 0.5 {
            hardness = 1.0
        } else {
            hardness = 1.0
        }
        let color: [Float] = [stroke.pen.color.r, stroke.pen.color.g, stroke.pen.color.b, 1.0]
        return GPExportStroke(color: color, is_eraser: stroke.pen.isEraser, hardness: hardness, points: exportPoints)
    }
    
    func cutRectStroke(exportCorners: [CGPoint]) -> GPExportStroke {
        GPExportStroke(color: [0, 0, 0, 1], is_eraser: false, hardness: 1.0,
                       points: exportCorners.map { GPExportPoint(x: Float($0.x), y: Float($0.y), radius: 1.0, opacity: 1.0) },
                       cut_rect: true)
    }
    
    /// One GP layer PER GROUP. A group's mask shapes (keep frames + erase quads)
    /// erase everything below them within their layer, so groups must not share
    /// one layer: masks scope to their own group in the source semantics (the
    /// renderers dispatch one masked paste per group). Stacking preserves group
    /// order; the LAST group's layer is the record subsequent content joins.
    private func exportPasteLayers(resolved: ResolvedPasteRender,
                           actionIndex: Int,
                           isMerge: Bool,
                           destLayerName: String,
                           destLayerOpacity: Float,
                           colorAlpha: Float,
                           canvasHeight: CGFloat,
                           resampleStep: CGFloat,
                           catmullRom: Bool) -> [GPExportLayer] {
        let pencilStep = resampleStep * 0.75
        let exportFlip = verticalFlipTransform(canvasHeight: canvasHeight)
        let baseName = "\(destLayerName) [\(isMerge ? "merge" : "paste") \(actionIndex)]"
        var layers: [GPExportLayer] = []
        
        for (gi, g) in resolved.groups.enumerated() {
            // pen affine -> lb -> accNow -> destMap, then the export flip
            let pointTransform = g.lb.concatenating(g.accNow).concatenating(resolved.destMap)
            
            let lbScaleX = sqrt(g.lb.a * g.lb.a + g.lb.c * g.lb.c)
            let lbScaleY = sqrt(g.lb.b * g.lb.b + g.lb.d * g.lb.d)
            var avgLbScale = (lbScaleX + lbScaleY) / 2.0
            if avgLbScale <= 0.0 { avgLbScale = 1.0 }
            let selectionScale = maxAxisScale(g.accNow) * maxAxisScale(resolved.destMap)
            
            var strokes: [GPExportStroke] = []
            var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
            var maxRadius: CGFloat = 0
            
            for stroke in g.strokes {
                guard !stroke.points.isEmpty else { continue }
                var effectiveRadiusScale: CGFloat = stroke.penMatrixScale
                if let affine = stroke.pen.penMatrixAffine {
                    let sx = sqrt(affine.a * affine.a + affine.c * affine.c)
                    let sy = sqrt(affine.b * affine.b + affine.d * affine.d)
                    effectiveRadiusScale = (sx + sy) / 2.0
                }
                effectiveRadiusScale *= avgLbScale * selectionScale * 0.5
                
                var totalScale = avgLbScale * selectionScale
                if let affine = stroke.pen.penMatrixAffine {
                    let affineScale = sqrt(affine.b * affine.b + affine.d * affine.d)
                    totalScale *= affineScale / scale
                }
                
                if let s = exportGPStroke(stroke: stroke, pointTransform: pointTransform,
                                          flipTransform: exportFlip, radiusScale: effectiveRadiusScale,
                                          totalScale: totalScale, resampleStep: resampleStep,
                                          pencilStep: pencilStep, catmullRom: catmullRom) {
                    strokes.append(s)
                    for p in s.points {
                        minX = min(minX, CGFloat(p.x)); maxX = max(maxX, CGFloat(p.x))
                        minY = min(minY, CGFloat(p.y)); maxY = max(maxY, CGFloat(p.y))
                        maxRadius = max(maxRadius, CGFloat(p.radius))
                    }
                }
            }
            
            // This group's OWN content bounds — the keep frame only has to
            // cover this group's strokes (not the running union).
            guard minX <= maxX, minY <= maxY else { continue }
            let pad = maxRadius + 16.0
            let layerBounds = CGRect(x: minX - pad, y: minY - pad,
                                     width: (maxX - minX) + 2.0 * pad,
                                     height: (maxY - minY) + 2.0 * pad)
            
            for m in g.maskEntries {
                guard let devCorners = maskRectDeviceCorners(maskInv: m.inv, rect: m.rect,
                                                             destMap: resolved.destMap) else { continue }
                let exportCorners = devCorners      // already in the JSON's y convention
                if m.erase {
                    // erase INSIDE the mask rect: the quad itself
                    strokes.append(cutRectStroke(exportCorners: exportCorners))
                } else {
                    // keep: erase OUTSIDE via the frame — this group's layer only
                    for shape in outsideKeepFrameShapes(keepQuad: exportCorners, bounds: layerBounds) {
                        strokes.append(cutRectStroke(exportCorners: shape))
                    }
                }
            }
            
            guard !strokes.isEmpty else { continue }
            layers.append(GPExportLayer(
                name: gi == 0 ? baseName : "\(baseName) #\(gi + 1)",
                opacity: destLayerOpacity * colorAlpha,
                visible: true,
                strokes: strokes))
        }
        return layers
    }

    
    
    /// "Erase outside the keep quad" as up to 4 shapes: the outside of a convex quad
    /// is the union of the four outside-edge half-planes; clip the bounds polygon
    /// against each. Axis-aligned quads yield plain rectangles.
    func outsideKeepFrameShapes(keepQuad: [CGPoint], bounds: CGRect) -> [[CGPoint]] {
        guard keepQuad.count == 4 else { return [] }
        let cx = (keepQuad[0].x + keepQuad[1].x + keepQuad[2].x + keepQuad[3].x) / 4.0
        let cy = (keepQuad[0].y + keepQuad[1].y + keepQuad[2].y + keepQuad[3].y) / 4.0
        var area: CGFloat = 0
        for i in 0..<4 {
            let a = keepQuad[i], b = keepQuad[(i + 1) % 4]
            area += a.x * b.y - b.x * a.y
        }
        let boundsCorners = [
            CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY)
        ]
        // Degenerate selection: keep nothing — erase the whole bounds.
        guard abs(area) > 1e-6 else { return [boundsCorners] }
        
        var shapes: [[CGPoint]] = []
        for i in 0..<4 {
            let p1 = keepQuad[i], p2 = keepQuad[(i + 1) % 4]
            let ex = p2.x - p1.x, ey = p2.y - p1.y
            func side(_ q: CGPoint) -> CGFloat { ex * (q.y - p1.y) - ey * (q.x - p1.x) }
            let centroidSide = side(CGPoint(x: cx, y: cy))
            guard abs(centroidSide) > 1e-9 else { continue }
            func isOutside(_ q: CGPoint) -> Bool { side(q) * centroidSide < 0 }   // boundary stays kept
            
            var clipped: [CGPoint] = []
            for j in 0..<boundsCorners.count {
                let cur = boundsCorners[j], nxt = boundsCorners[(j + 1) % boundsCorners.count]
                let curOut = isOutside(cur), nxtOut = isOutside(nxt)
                if nxtOut {
                    if !curOut { clipped.append(edgeLineIntersection(cur, nxt, p1: p1, ex: ex, ey: ey)) }
                    clipped.append(nxt)
                } else if curOut {
                    clipped.append(edgeLineIntersection(cur, nxt, p1: p1, ex: ex, ey: ey))
                }
            }
            if clipped.count >= 3 { shapes.append(clipped) }
        }
        return shapes
    }
    
    private func edgeLineIntersection(_ a: CGPoint, _ b: CGPoint, p1: CGPoint, ex: CGFloat, ey: CGFloat) -> CGPoint {
        let sa = ex * (a.y - p1.y) - ey * (a.x - p1.x)
        let sb = ex * (b.y - p1.y) - ey * (b.x - p1.x)
        let denom = sa - sb
        guard abs(denom) > 1e-12 else { return a }
        let t = sa / denom
        return CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))
    }
    
    /// Initial action-time layer matrix: a layer with any layer_matrix action is
    /// action-driven from identity; a layer with none keeps its saved matrix.
    private func initialActionLayerMatrix(layerIndex: Int, art: ArtParser) -> CGAffineTransform {
        let hasLayerMatrixAction = art.actions.contains { a in
            (a["layer"] as? Int) == layerIndex && (a["action_name"] as? String) == "layer_matrix"
        }
        return hasLayerMatrixAction ? .identity : layerMatrix(ofLayer: layerIndex, in: art)
    }
    
    /// Widest-axis scale of a transform — the "widest rectangle side" rule for
    /// non-uniform selection transforms: radius/pressure scale as if the transform
    /// were uniform by this factor (equals zoom_2/zoom_1 for uniform pastes).
    private func maxAxisScale(_ t: CGAffineTransform) -> CGFloat {
        let sx = sqrt(t.a * t.a + t.c * t.c)
        let sy = sqrt(t.b * t.b + t.d * t.d)
        return max(sx, sy)
    }
    
    /// Shared scale computation for the stamp/CPU point paths (existing idioms for
    /// pen affine + layer/view; selection transforms contribute their widest axis).
    private func strokeScaleParams(
        stroke: StrokeRecord,
        lb: CGAffineTransform,
        accNow: CGAffineTransform,
        destMap: CGAffineTransform
    ) -> (stepPx: CGFloat, radiusScale: CGFloat) {
        let targetStepInDevicePx: CGFloat = stroke.pen.type == 1 ? 2.0 : 1.5
        let lbScaleX = sqrt(lb.a * lb.a + lb.c * lb.c)
        let lbScaleY = sqrt(lb.b * lb.b + lb.d * lb.d)
        var avgLbScale = (lbScaleX + lbScaleY) / 2.0
        if avgLbScale <= 0.0 { avgLbScale = 1.0 }
        
        // SELECTION SCALE: widest axis (max, not averaged).
        // (zoom_2/zoom_1 equivalent for uniform m2 — swap in here if parsed instead)
        let selectionScale = maxAxisScale(accNow) * maxAxisScale(destMap)
        
        var totalScale = avgLbScale * selectionScale
        if let affine = stroke.pen.penMatrixAffine {
            let affineScale = sqrt(affine.b * affine.b + affine.d * affine.d)
            totalScale *= affineScale / scale
        }
        let stampStepPx = targetStepInDevicePx / totalScale
        
        var effectiveRadiusScale: CGFloat = stroke.penMatrixScale
        if let affine = stroke.pen.penMatrixAffine {
            let scaleX = sqrt(affine.a * affine.a + affine.c * affine.c)
            let scaleY = sqrt(affine.b * affine.b + affine.d * affine.d)
            effectiveRadiusScale = (scaleX + scaleY) / 2.0
        }
        effectiveRadiusScale *= avgLbScale * selectionScale * 0.5
        
        return (stampStepPx, effectiveRadiusScale)
    }

    
    private func buildStrokesForLayer(
        layerIndex: Int,
        art: ArtParser,
        baseTransform: CGAffineTransform,
        visited: Set<Int> = []
    ) -> [ResolvedStroke] {
        
        var resolvedStrokes: [ResolvedStroke] = []
        var currentPen = defaultPenInfo()
        var penMatrixScale: CGFloat = 1.0
        
        guard layerIndex >= 0, layerIndex < art.layers.count else { return [] }
        if visited.contains(layerIndex) {
//            print("REPLAY L\(layerIndex): cyclic reference \(visited) — skipped")
            return []
        }
        
        for (actionIdx, action) in art.actions.enumerated() {
                        
            guard let actionLayer = action["layer"] as? Int,
                  actionLayer == layerIndex,
                  let actionName = action["action_name"] as? String else { continue }
            
            switch actionName {
                    
                case "pen_properties":
                    actionPenProperties(action: action, currentPen: &currentPen)
                    
                case "pen_matrix":
                    actionPenMatrix(action: action, currentPen: &currentPen,
                                    penMatrixScale: &penMatrixScale)
                    
                case "is_eraser":
                    actionIsEraser(action: action, currentPen: &currentPen)
                    
                case "pen_color":
                    actionPenColor(action: action, currentPen: &currentPen)
                    
                case "stroke":
                    var strokes: [StrokeRecord] = []
                    actionStroke(action: action, currentPen: currentPen,
                                 penMatrixScale: penMatrixScale, layerStrokes: &strokes)
                    for stroke in strokes {
                        resolvedStrokes.append(ResolvedStroke(
                            stroke: stroke,
                            accumulatedDeviceTransform: .identity,
                            sourceLayerIndex: layerIndex,
                            selectionRect: []))
                    }
                    
                case "polyline":
                    var strokes: [StrokeRecord] = []
                    actionPolyline(action: action, currentPen: currentPen,
                                   penMatrixScale: penMatrixScale, layerStrokes: &strokes)
                    for stroke in strokes {
                        resolvedStrokes.append(ResolvedStroke(
                            stroke: stroke,
                            accumulatedDeviceTransform: .identity,
                            sourceLayerIndex: layerIndex,
                            selectionRect: []))
                    }
                    
                case "rect":
                    var strokes: [StrokeRecord] = []
                    actionRect(action: action, currentPen: currentPen,
                               penMatrixScale: penMatrixScale, layerStrokes: &strokes)
                    for stroke in strokes {
                        resolvedStrokes.append(ResolvedStroke(
                            stroke: stroke,
                            accumulatedDeviceTransform: .identity,
                            sourceLayerIndex: layerIndex,
                            selectionRect: []))
                    }
                    
                case "ellipse":
                    var strokes: [StrokeRecord] = []
                    actionEllipse(action: action, currentPen: currentPen,
                                  penMatrixScale: penMatrixScale, layerStrokes: &strokes)
                    for stroke in strokes {
                        resolvedStrokes.append(ResolvedStroke(
                            stroke: stroke,
                            accumulatedDeviceTransform: .identity,
                            sourceLayerIndex: layerIndex,
                            selectionRect: []))
                    }
                    
                case "cut":
                    guard let rect = parseFloatArray(action["selection_rect"]),
                          rect.count == 4 else { continue }
                    // Cuts carry no matrix of their own; borrow the action-time view
                    // from the next paste_layer in global order. A trailing cut (no
                    // following paste) falls back to identity — the rect is device px,
                    // the same convention as the destination-layer cut path. (Skipping
                    // these left trailing source-layer cuts with no effect on any
                    // paste of that layer.)
                    let m1cut: CGAffineTransform
                    if let own = parseMatrixRobust(action["matrix_1"]) {
                        m1cut = transformFromMatrix(own.map { $0.map { Float($0) } }, scale: 1.0)
                    } else if let next = nextPasteViewMatrix(in: art.actions, after: actionIdx) {
                        m1cut = next
                    } else {
                        m1cut = .identity
                    }
                    // Erases everything collected so far in this layer's replay.
                    for i in resolvedStrokes.indices {
                        resolvedStrokes[i].masks.append(StrokeMask(
                            m1: m1cut, rect: rect,
                            accRef: resolvedStrokes[i].accumulatedDeviceTransform,
                            erase: true))
                    }
                    
                case "paste_layer":
                    guard let fromLayer = action["from_layer"] as? Int,
                          fromLayer >= 0, fromLayer < art.layers.count,
                          let selectionRect = parseFloatArray(action["selection_rect"]),
                          selectionRect.count == 4,
                          let m1raw = parseMatrixRobust(action["matrix_1"]),
                          let m2raw = parseMatrixRobust(action["matrix_2"]) else { continue }
                    
                    let matrix1 = transformFromMatrix(m1raw.map { $0.map { Float($0) } }, scale: 1.0)
                    let matrix2 = transformFromMatrix(m2raw.map { $0.map { Float($0) } }, scale: 1.0)
                    let Bi = baseTransform.inverted()
                    
                    let pen: CGAffineTransform
                    let sel2Dev: CGAffineTransform
                    if isIdentityTransform(matrix1) {
                        pen = currentPen.penMatrixAffine ?? .identity
                        sel2Dev = matrix1.inverted().concatenating(pen) // rotationOnlyInverse(matrix1).concatenating(pen)
                            .concatenating(layerMatrix(ofLayer: layerIndex, in: art))
                    } else if pasteFollowsCut(art: art, layerIndex: layerIndex,
                                              pasteActionIndex: actionIdx, pasteRect: selectionRect) {
                        pen = .identity
                        sel2Dev = matrix1.inverted()
                    } else {
                        pen = currentPen.penMatrixAffine ?? .identity
                        sel2Dev = pen.concatenating(layerMatrix(ofLayer: layerIndex, in: art))
                    }
                    let pasteDeviceMap = Bi.concatenating(matrix1).concatenating(matrix2)
                        .concatenating(sel2Dev).concatenating(baseTransform)

                    
                    // Clipboard semantics: the ENTIRE source layer is the paste source.
                    let sourceStrokes = buildStrokesForLayer(
                        layerIndex: fromLayer,
                        art: art,
                        baseTransform: baseTransform,
                        visited: visited.union([layerIndex]))
                    
//                    print("REPLAY merge@\(actionIdx) L\(layerIndex)<-L\(fromLayer): \(sourceStrokes.count) strokes (full replay)")
                    
                    for resolved in sourceStrokes {
                        var masks = resolved.masks
                        // Keep-mask for THIS paste's selection, recorded pre-move.
                        masks.append(StrokeMask(
                            m1: matrix1, rect: selectionRect,
                            accRef: resolved.accumulatedDeviceTransform,
                            erase: false))
                        resolvedStrokes.append(ResolvedStroke(
                            stroke: resolved.stroke,
                            accumulatedDeviceTransform:
                                resolved.accumulatedDeviceTransform.concatenating(pasteDeviceMap),
                            sourceLayerIndex: resolved.sourceLayerIndex,
                            selectionRect: selectionRect,
                            masks: masks))
                    }
                    
                case "merge_layer":
                    guard let fromLayer = action["from_layer"] as? Int,
                          fromLayer >= 0, fromLayer < art.layers.count else { continue }
                    // NOTE: `matrix`+`zoom` is an action-time view snapshot (like
                    // matrix_1/zoom_1 in pastes) — deliberately NOT parsed or applied.
                    // Snapshot semantics: source layer as it exists AT the merge.
                    let sourceStrokes = buildStrokesForLayer(
                        layerIndex: fromLayer,
                        art: art,
                        baseTransform: baseTransform,
                        visited: visited.union([layerIndex]))
                    
//                    print("REPLAY merge@\(actionIdx) L\(layerIndex)<-L\(fromLayer): \(sourceStrokes.count) strokes (cutoff=\(actionIdx))")
                    
                    // Merge preserves canvas position: B ∘ Ldst ∘ B⁻¹
                    let mergeDeviceMap = baseTransform.inverted()
                        .concatenating(layerMatrix(ofLayer: layerIndex, in: art))
                        .concatenating(baseTransform)
                    
                    for resolved in sourceStrokes {
                        resolvedStrokes.append(ResolvedStroke(
                            stroke: resolved.stroke,
                            accumulatedDeviceTransform:
                                resolved.accumulatedDeviceTransform.concatenating(mergeDeviceMap),
                            sourceLayerIndex: resolved.sourceLayerIndex,
                            selectionRect: [],
                            masks: resolved.masks))
                    }
                    
                default: break
            }
        }
        
//        let bySrc = Dictionary(grouping: resolvedStrokes, by: { $0.sourceLayerIndex })
//            .map { "L\($0.key)=\($0.value.count)" }
//            .sorted().joined(separator: ", ")
//        print("REPLAY L\(layerIndex) done: \(resolvedStrokes.count) strokes {\(bySrc)}")
        return resolvedStrokes
    }

    
    private func parseMatrixRobust(_ v: Any?) -> [[Double]]? {
        if let m = v as? [[Double]] {
            return m
        }
        
        if let m = v as? [[Float]] {
            return m.map { row in
                row.map { Double($0) }
            }
        }
        
        if let mAny = v as? [[Any]] {
            var result: [[Double]] = []
            result.reserveCapacity(mAny.count)
            
            for row in mAny {
                var converted: [Double] = []
                converted.reserveCapacity(row.count)
                
                for item in row {
                    switch item {
                        case let d as Double:
                            converted.append(d)
                        case let f as Float:
                            converted.append(Double(f))
                        case let i as Int:
                            converted.append(Double(i))
                        case let i as Int32:
                            converted.append(Double(i))
                        case let i as Int64:
                            converted.append(Double(i))
                        case let s as String:
                            guard let d = Double(s) else {
                                return nil
                            }
                            converted.append(d)
                        default:
                            return nil
                    }
                }
                
                result.append(converted)
            }
            
            return result
        }
        
        // Some parser/debug paths expose the whole 4x4 matrix as a string.
        if let string = v as? String,
           let data = string.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let matrix = object as? [[Any]] {
            return parseMatrixRobust(matrix)
        }
        
        return nil
    }
    
    private func parseFloatArray(_ v: Any?) -> [Float]? {
        if let arr = v as? [Float] { return arr }
        if let arr = v as? [Double] { return arr.map { Float($0) } }
        if let arrAny = v as? [Any] {
            var res: [Float] = []
            for item in arrAny {
                if let f = item as? Float { res.append(f) }
                else if let d = item as? Double { res.append(Float(d)) }
                else if let i = item as? Int { res.append(Float(i)) }
                else if let s = item as? String, let d = Double(s) { res.append(Float(d)) }
                else { return nil }
            }
            return res
        }
        return nil
    }
    
    // A wrapper to use with your existing transformFromMatrix logic
//    private func transformFromAnyMatrix(_ v: Any?) -> CGAffineTransform {
//        guard let m = parseMatrixRobust(v),
//              m.count >= 4,
//              m[0].count >= 2,
//              m[1].count >= 2,
//              m[3].count >= 2 else {
//            return .identity
//        }
//
//        let a  = CGFloat(m[0][0])
//        let b  = -CGFloat(m[1][0])
//        let c  = -CGFloat(m[0][1])
//        let d  = CGFloat(m[1][1])
//        let tx = CGFloat(m[3][0])
//        let ty = CGFloat(m[3][1])
//
//        return CGAffineTransform(
//            a: a,
//            b: b,
//            c: c,
//            d: d,
//            tx: tx,
//            ty: ty
//        )
//    }
    
//    private func applyEraseRects(image: CGImage, rects: [(center: CGPoint, halfExtents: CGPoint)]) -> CGImage? {
//        let width = image.width
//        let height = image.height
//
//        guard let context = CGContext(
//            data: nil,
//            width: width,
//            height: height,
//            bitsPerComponent: 8,
//            bytesPerRow: 0,
//            space: CGColorSpaceCreateDeviceRGB(),
//            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
//        ) else { return nil }
//
//        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
//        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
//
//        context.setBlendMode(.destinationOut)
//        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
//
//        for rect in rects {
//            let flippedCenterY = CGFloat(height) - rect.center.y
//            let drawRect = CGRect(
//                x: rect.center.x - rect.halfExtents.x,
//                y: flippedCenterY - rect.halfExtents.y,
//                width: rect.halfExtents.x * 2,
//                height: rect.halfExtents.y * 2
//            )
//            context.fill(drawRect)
//        }
//
//        return context.makeImage()
//    }
    
    private func applyErasePolygons(image: CGImage, polygons: [[CGPoint]]) -> CGImage? {
        let w = image.width
        let h = image.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        
        let rect = CGRect(x: 0, y: 0, width: w, height: h)
        
        // MAKE CONTEXT Y-DOWN
//        context.scaleBy(x: 1, y: -1)
//        context.translateBy(x: 0, y: -CGFloat(h))
        
        // 1. Draw the image. It now aligns perfectly right-side up in memory.
        context.draw(image, in: rect)
        
        context.saveGState()
        context.setBlendMode(.destinationOut)
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        
        for polygon in polygons {
            if polygon.count > 2 {
                context.beginPath()
                // 2. Polygons are Y-down. Context is Y-down. Perfect alignment.
                context.addLines(between: polygon)
                context.closePath()
                context.fillPath()
            }
        }
        context.restoreGState()
        
        return context.makeImage()
    }
    
    /// AABB of a cut_rect entry's corner points (JSON space).
    private func cutEntryBox(_ s: GPExportStroke) -> CGRect {
        guard s.points.count >= 3 else { return .null }
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in s.points {
            minX = min(minX, CGFloat(p.x)); maxX = max(maxX, CGFloat(p.x))
            minY = min(minY, CGFloat(p.y)); maxY = max(maxY, CGFloat(p.y))
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    
    /// Drops cut_rect entries with nothing to erase on the record they're being
    /// written to (existing record content + this batch's strokes). contentBox is
    /// a superset of what any entry in the batch can reach, so this never drops
    /// an entry that would erase something — it only removes no-ops. Lower-record
    /// replication is gated separately (same criterion) and is unaffected.
    private func dropNoOpCutEntries(_ strokes: [GPExportStroke], contentBox: CGRect) -> [GPExportStroke] {
        guard strokes.contains(where: { $0.cut_rect == true }) else { return strokes }
        guard !contentBox.isNull else { return strokes.filter { $0.cut_rect != true } }
        return strokes.filter { s in
            guard s.cut_rect == true else { return true }
            let box = cutEntryBox(s)
            return !box.isNull && contentBox.intersects(box)
        }
    }
    
    /// JSON-space bounds of exported strokes (points ± radius). cut_rect entries
    /// are erase operators and erasers carry no content — both are excluded from
    /// CONTENT bounds; pass includeErasers: true to measure an eraser's reach.
    private func strokeBounds(_ strokes: [GPExportStroke], includeErasers: Bool = false) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for s in strokes {
            if s.cut_rect == true { continue }
            if s.is_eraser && !includeErasers { continue }
            for p in s.points {
                let r = CGFloat(p.radius)
                minX = min(minX, CGFloat(p.x) - r)
                maxX = max(maxX, CGFloat(p.x) + r)
                minY = min(minY, CGFloat(p.y) - r)
                maxY = max(maxY, CGFloat(p.y) + r)
            }
        }
        guard minX <= maxX, minY <= maxY else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    
    private func unionBounds(_ a: CGRect, _ b: CGRect) -> CGRect {
        if a.isNull { return b }
        if b.isNull { return a }
        return a.union(b)
    }
    
#if os(macOS)
    // MARK: - GPU stamp path (re-enabled)
    
    // Resampled-stamp GPU rendering via renderStrokesInOrderSync. Action order is
    // preserved by flushing GPU runs at every cut/paste boundary:
    //   - strokes     -> stamp batches in the current run (draw or erase kind)
    //   - erase runs  -> rendered as alpha coverage, composited with .destinationOut
    //                    so they erase everything composited below (incl. pasted content)
    //   - cut         -> flush + CoreGraphics rect erase on the layer context
    //   - paste/merge -> flush + isolated GPU layer per group + CPU mask erases
    // Returns nil on GPU failure; the caller falls back to the CPU path.
    private func renderLayerWithGPUStamps(
        art: ArtParser,
        layerIndex: Int,
        artToDevice: CGAffineTransform,
        context: CGContext,
        metalRenderer: MetalRenderer
    ) -> CGImage? {
        
        let w = Int(canvasSize.width * scale)
        let h = Int(canvasSize.height * scale)
        
        enum RunKind { case draw, erase }
        var run: (kind: RunKind, batches: [(stamps: [Stamp], color: SIMD4<Float>, isMarker: Bool)])? = nil
        
        func flushRun() -> Bool {
            guard let r = run, !r.batches.isEmpty else { run = nil; return true }
            run = nil
            let groups = r.batches.map {
                (stamps: $0.stamps, color: $0.color, isEraser: false,
                 isMarker: r.kind == .erase ? false : $0.isMarker)
            }
            let image: CGImage
            do {
                guard let img = try metalRenderer.renderStrokesInOrderSync(strokeGroups: groups, width: w, height: h) else {
                    print("GPU stamp flush returned nil (\(r.kind) run, \(r.batches.count) batch(es))")
                    return false
                }
                image = img
            } catch {
                print("GPU stamp flush failed: \(error)")
                return false
            }
            compositeImageCPU(image: image, erase: r.kind == .erase, into: context)
            return true
        }
        
        func appendRun(_ kind: RunKind,
                       _ batch: (stamps: [Stamp], color: SIMD4<Float>, isMarker: Bool)) -> Bool {
            if run?.kind != kind {
                if !flushRun() { return false }
                run = (kind: kind, batches: [])
            }
            run!.batches.append(batch)
            return true
        }
        
        var currentPen = defaultPenInfo()
        var penMatrixScale: CGFloat = 1.0
        var failed = false
        var actionLayerMatrix = initialActionLayerMatrix(layerIndex: layerIndex, art: art)
        
        for (actionIdx, action) in art.actions.enumerated() {
            guard let actionLayer = action["layer"] as? Int,
                  actionLayer == layerIndex,
                  let actionName = action["action_name"] as? String else { continue }
            
            switch actionName {
                case "pen_properties":
                    actionPenProperties(action: action, currentPen: &currentPen)
                case "pen_matrix":
                    actionPenMatrix(action: action, currentPen: &currentPen, penMatrixScale: &penMatrixScale)
                case "is_eraser":
                    actionIsEraser(action: action, currentPen: &currentPen)
                case "pen_color":
                    actionPenColor(action: action, currentPen: &currentPen)
                    
                case "stroke", "polyline", "rect", "ellipse":
                    var tempStrokes: [StrokeRecord] = []
                    switch actionName {
                        case "stroke":
                            actionStroke(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                        case "polyline":
                            actionPolyline(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                        case "rect":
                            actionRect(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                        default:
                            actionEllipse(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                    }
                    for stroke in tempStrokes {
                        guard let batch = buildStampBatch(stroke: stroke, lb: artToDevice, accNow: .identity, destMap: .identity) else { continue }
                        if !appendRun(stroke.pen.isEraser ? .erase : .draw,
                                      (stamps: batch.stamps, color: batch.color, isMarker: batch.isMarker)) {
                            failed = true
                            break
                        }
                    }
                    
                case "cut":
                    if !flushRun() { failed = true; break }
                    applyCutRectCPU(context: context, action: action, art: art, actionIndex: actionIdx,
                                    baseTransform: artToDevice)
                    
                    // flushRun() composite:
//                    compositeImageCPU(image: image, erase: r.kind == .erase, into: context)
                    

                    
                case "paste_layer":
                    if !flushRun() { failed = true; break }
                    if let resolved = resolvePasteRender(
                        action: action, art: art, targetLayerIndex: layerIndex, actionIndex: actionIdx,
                        dstPenAffine: currentPen.penMatrixAffine ?? .identity,
                        dstLayerMatrix: actionLayerMatrix,
                        baseTransform: artToDevice) {
                        if !renderPasteGroupsWithGPUStamps(resolved: resolved, context: context,
                                                           metalRenderer: metalRenderer) {
                            failed = true
                            break
                        }
                    }
                    
                case "merge_layer":
                    if !flushRun() { failed = true; break }
                    if let resolved = resolveMergeRender(
                        action: action, art: art, targetLayerIndex: layerIndex,
                        baseTransform: artToDevice) {
                        if !renderPasteGroupsWithGPUStamps(resolved: resolved, context: context,
                                                           metalRenderer: metalRenderer) {
                            failed = true
                            break
                        }
                    }
                    
                case "layer_matrix":
                    if let mRaw = parseMatrixRobust(action["matrix"]) {
                        actionLayerMatrix = transformFromMatrix(mRaw.map { $0.map { Float($0) } }, scale: 1.0)
                    }
                    
                default: break
            }
            if failed { break }
        }
        
        if !failed, !flushRun() { failed = true }
        if failed { return nil }
        
        // Render embedded images (same placement as the CPU path)
        context.saveGState()
        context.translateBy(x: CGFloat(context.width) / 2.0, y: CGFloat(context.height) / 2.0)
        context.concatenate(artToDevice)
        renderEmbeddedImages(art: art, in: context)
        context.restoreGState()
        
        return context.makeImage()
    }
    
    /// Builds the stamp batch for one stroke (the pipeline of the previously disabled
    /// stamp renderer, generalized with the selection transforms).
    private func buildStampBatch(
        stroke: StrokeRecord,
        lb: CGAffineTransform,
        accNow: CGAffineTransform,
        destMap: CGAffineTransform
    ) -> (stamps: [Stamp], color: SIMD4<Float>, isEraser: Bool, isMarker: Bool)? {
        
        guard !stroke.points.isEmpty else { return nil }
        let (stampStepPx, effectiveRadiusScale) = strokeScaleParams(stroke: stroke, lb: lb, accNow: accNow, destMap: destMap)
        
        let splinePoints = buildResampledStrokeWithSpline(
            stroke.points, stepPx: stampStepPx, samplesPerSegment: 6, gamma: 1.0, isPolyline: stroke.isPolyline)
        var resampled: [ResampledPoint] = splinePoints.map {
            ResampledPoint(x: CGFloat($0.x), y: CGFloat($0.y), p: $0.p)
        }
        guard !resampled.isEmpty else { return nil }
        applyEndTaperToResampled(&resampled, tailSamples: 4, ease: 1.8)
        
        let color = SIMD4<Float>(Float(stroke.pen.color.r), Float(stroke.pen.color.g), Float(stroke.pen.color.b), 1.0)
        
        var stamps: [Stamp] = []
        stamps.reserveCapacity(resampled.count)
        for rp in resampled {
            let pt = devicePointForStroke(CGPoint(x: rp.x, y: rp.y), stroke: stroke,
                                          lb: lb, accNow: accNow, destMap: destMap)
            let (radius, opacity) = pressureToRadiusOpacity(
                pressure: rp.pressure, pen: stroke.pen, radiusScale: effectiveRadiusScale, gamma: 1.0)
            stamps.append(Stamp(
                center: SIMD2<Float>(Float(pt.x), Float(pt.y)),
                radius: Float(radius),
                opacity: opacity,
                rotation: 0.0,
                noiseSeed: stroke.pen.type == 1 ? arc4random() + 1 : 0))
        }
        return (stamps: stamps, color: color, isEraser: stroke.pen.isEraser, isMarker: stroke.pen.isMarker)
    }
    
    private func renderPasteGroupsWithGPUStamps(
        resolved: ResolvedPasteRender,
        context: CGContext,
        metalRenderer: MetalRenderer
    ) -> Bool {
        let w = Int(canvasSize.width * scale)
        let h = Int(canvasSize.height * scale)
        
        // MERGE: render through an isolated fragment (see renderPasteGroupsCPU).
        // PASTES stay flat: eraser groups composite .destinationOut against the layer.
        var fragment: CGContext? = nil
        if resolved.isMerge {
            fragment = createBitmapContext(size: canvasSize, scale: scale)
            Self.clearContext(fragment!, rect: CGRect(x: 0, y: 0, width: fragment!.width, height: fragment!.height))
        }
        let target = fragment ?? context
        
        for g in resolved.groups {
            var batches: [(stamps: [Stamp], color: SIMD4<Float>, isMarker: Bool)] = []
            for stroke in g.strokes {
                guard let batch = buildStampBatch(stroke: stroke, lb: g.lb, accNow: g.accNow, destMap: resolved.destMap) else { continue }
                batches.append((stamps: batch.stamps, color: g.color, isMarker: batch.isMarker))
            }
            guard !batches.isEmpty else { continue }
            
            let groups = batches.map {
                (stamps: $0.stamps, color: $0.color, isEraser: false,
                 isMarker: g.isEraser ? false : $0.isMarker)
            }
            let image: CGImage
            do {
                guard let img = try metalRenderer.renderStrokesInOrderSync(strokeGroups: groups, width: w, height: h) else {
                    print("GPU stamp paste flush returned nil")
                    return false
                }
                image = img
            } catch {
                print("GPU stamp paste failed: \(error)")
                return false
            }
            
            var outImage = image
            if !g.maskEntries.isEmpty {
                let maskContext = createBitmapContext(size: canvasSize, scale: scale)
                Self.clearContext(maskContext, rect: CGRect(x: 0, y: 0, width: maskContext.width, height: maskContext.height))
                compositeImageCPU(image: image, into: maskContext)
                for m in g.maskEntries {
                    applyPasteMaskCPU(context: maskContext, maskInv: m.inv, rect: m.rect, erase: m.erase,
                                      destMap: resolved.destMap)
                }
                if let masked = maskContext.makeImage() { outImage = masked }
            }
            
            // full opacity inside a merge fragment — the fragment carries the merge
            // alpha when it lands on the layer; pastes keep the per-group alpha
            let groupAlpha = resolved.isMerge ? CGFloat(1) : CGFloat(min(max(g.color.w, 0), 1))
            compositeImageCPU(image: outImage, erase: g.isEraser, alpha: groupAlpha, into: target)
        }
        
        if let frag = fragment, let image = frag.makeImage() {
            let mergeAlpha = CGFloat(min(max(resolved.groups.first?.color.w ?? 1, 0), 1))
            compositeImageCPU(image: image, alpha: mergeAlpha, into: context)
        }
        return true
    }
#endif // os(macOS)

    
    // MARK: - Actions in actionName
    private func actionPenProperties(action: [String: Any], currentPen: inout PenInfo) {
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
        
    }
    
    private func actionPenMatrix(action: [String: Any], currentPen: inout PenInfo, penMatrixScale: inout CGFloat) {
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
        
    }
    
    private func actionIsEraser(action: [String: Any], currentPen: inout PenInfo) {
        if let isEraser = action["is_eraser"] as? Bool {
            currentPen.isEraser = isEraser
        }
    }
    
    private func actionPenColor(action: [String: Any], currentPen: inout PenInfo) {
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
    }
    
    private func actionStroke(action: [String: Any], currentPen: PenInfo, penMatrixScale: CGFloat, layerStrokes: inout [StrokeRecord]) {
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
                penMatrixAffine: currentPen.penMatrixAffine,
                isPolyline: false
            )
            //                    if let first = rawPoints.first, let last = rawPoints.last {
            //                        print("[P][stroke record] points=\(rawPoints.count) p.first=\(first.p) p.last=\(last.p) pen.opacity=\(currentPen.opacity) pen.opacityMin=\(currentPen.opacityMin)")
            //                    }
            
            layerStrokes.append(rec)
        }
    }
    
    private func actionPolyline(action: [String: Any], currentPen: PenInfo, penMatrixScale: CGFloat, layerStrokes: inout [StrokeRecord]) {
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
                penMatrixAffine: currentPen.penMatrixAffine,
                isPolyline: true
            )
            //                    print("POLYLINE")
            
            layerStrokes.append(rec)
        }
    }
    
    private func actionRect(action: [String: Any], currentPen: PenInfo, penMatrixScale: CGFloat, layerStrokes: inout [StrokeRecord]) {
        if let x = action["x"] as? Float,
           let y = action["y"] as? Float,
           let w = action["w"] as? Float,
           let h = action["h"] as? Float {
            let angle = action["angle"] as? Float ?? 0.0
            let cosA = cos(angle)
            let sinA = sin(angle)
            
            let halfW = w * 0.5
            let halfH = h * 0.5
            let localCorners: [(Float, Float)] = [
                (-halfW, -halfH),
                ( halfW, -halfH),
                ( halfW,  halfH),
                (-halfW,  halfH),
                (-halfW, -halfH)
            ]
            
            let pts: [Point] = localCorners.map { (dx, dy) in
                let rx = dx * cosA - dy * sinA
                let ry = dx * sinA + dy * cosA
                return Point(x: x + rx, y: y + ry, p: 1.0)
            }
            
            let rec = StrokeRecord(
                points: pts,
                pen: currentPen,
                penMatrixScale: penMatrixScale,
                penMatrixAffine: currentPen.penMatrixAffine,
                isPolyline: true
            )
            layerStrokes.append(rec)
        }
    }
    
    private func actionEllipse(action: [String: Any], currentPen: PenInfo, penMatrixScale: CGFloat, layerStrokes: inout [StrokeRecord]) {
        if let cx = action["cx"] as? Float,
           let cy = action["cy"] as? Float,
           let rx = action["rx"] as? Float,
           let ry = action["ry"] as? Float {
            let angle = action["angle"] as? Float ?? 0.0
            let cosA = cos(angle)
            let sinA = sin(angle)
            
            let tx = -rx / 2.0
            let ty = -ry / 2.0
            
            // Generate points directly on the true ellipse.
            let segments = 128 // 96
            let twoPi: Float = 2.0 * .pi
            
            var pts: [Point] = []
            pts.reserveCapacity(segments + 1)
            for i in 0..<segments {
                let t = Float(i) / Float(segments) * twoPi
                let ex = rx * cos(t)
                let ey = ry * sin(t)
                
                let ox = ex + tx
                let oy = ey + ty
                
                let rotX = ox * cosA - oy * sinA
                let rotY = ox * sinA + oy * cosA
                
                pts.append(Point(x: cx + rotX, y: cy + rotY, p: 1.0))
            }
            
            // Explicitly close the loop for the polyline renderer
            if let firstPt = pts.first {
                pts.append(firstPt)
            }
            
            // Render as a dense polyline
            let rec = StrokeRecord(
                points: pts,
                pen: currentPen,
                penMatrixScale: penMatrixScale,
                penMatrixAffine: currentPen.penMatrixAffine,
                isPolyline: true
            )
            layerStrokes.append(rec)
        }
    }
    
    
//    private func cutPolygon(
//        rect: [Float],
//        frameToDevice: CGAffineTransform
//    ) -> [CGPoint] {
//
//        guard rect.count == 4 else {
//            return []
//        }
//
//        let x = CGFloat(rect[0])
//        let y = CGFloat(rect[1])
//        let w = CGFloat(rect[2])
//        let h = CGFloat(rect[3])
//
//        let p1 = CGPoint(x: x,       y: y)
//        let p2 = CGPoint(x: x + w,   y: y)
//        let p3 = CGPoint(x: x + w,   y: y + h)
//        let p4 = CGPoint(x: x,       y: y + h)
//
//        return [p1, p2, p3, p4].map {
//            $0.applying(frameToDevice)
//        }
//    }
    
    private func actionPasteLayerOps(
        action: [String: Any],
        art: ArtParser,
        targetLayerIndex: Int,
        actionIndex: Int,
        dstPenAffine: CGAffineTransform,
        baseTransform: CGAffineTransform,
        yDownBaseTransform: CGAffineTransform,
        flipTransform: CGAffineTransform?
    ) -> [LayerOperation] {
        
        // ── 1. Parse ──
        guard let fromLayer = action["from_layer"] as? Int,
              fromLayer >= 0, fromLayer < art.layers.count,
              let selectionRect = parseFloatArray(action["selection_rect"]),
              selectionRect.count == 4,
              let m1raw = parseMatrixRobust(action["matrix_1"]),
              let m2raw = parseMatrixRobust(action["matrix_2"]) else {
            return []
        }
        
        // matrix_1 = action-time view: canvas -> selection frame.
        // matrix_2 = free transform, authored in that same selection frame.
        let matrix1 = transformFromMatrix(m1raw.map { $0.map { Float($0) } }, scale: 1.0)
        let matrix2 = transformFromMatrix(m2raw.map { $0.map { Float($0) } }, scale: 1.0)
        
        let B    = baseTransform
        let Ldst = layerMatrix(ofLayer: targetLayerIndex, in: art)
        
        // ── 2. Device-space maps ──
        // device px -> selection frame  (validated:  m1 ∘ B⁻¹)
        let deviceToSelection = B.inverted().concatenating(matrix1)
        
        let pen: CGAffineTransform
        let selectionToDevice: CGAffineTransform
        
        if isIdentityTransform(matrix1) {
            pen = dstPenAffine                                    // validated m1 == I path — unchanged
            selectionToDevice = matrix1.inverted() // rotationOnlyInverse(matrix1)
                .concatenating(pen).concatenating(Ldst).concatenating(B)
        } else if pasteFollowsCut(art: art, layerIndex: targetLayerIndex,
                                  pasteActionIndex: actionIndex, pasteRect: selectionRect) {
            pen = .identity
            // Free transform: full conjugation through the action-time view.
            // rotOnlyInverse was only valid at zoom_1 == 1 (where it equals m1⁻¹).
            selectionToDevice = matrix1.inverted().concatenating(B)
        } else {
            pen = dstPenAffine                                    // new-layer paste: sel px ARE layer px,
            // NOTE: actionPasteLayerOps keeps Ldst in this branch — the GPU paste shader
            // compensates it. Point-level application must NOT include it (File1 case).
            selectionToDevice = pen.concatenating(Ldst).concatenating(B)  // pen applied in full
            
        }


        
        // Free transform acts in screen space -> conjugate into device space:
        //   D = (B ∘ Ldst ∘ m1⁻¹) ∘ m2 ∘ (m1 ∘ B⁻¹)
        let sourceToDestinationGPU = deviceToSelection
            .concatenating(matrix2)
            .concatenating(selectionToDevice)
        let destinationToSourceGPU = sourceToDestinationGPU.inverted()
        
        // ── 3. Diagnostics / guard ──
        let detD = sourceToDestinationGPU.a * sourceToDestinationGPU.d
        - sourceToDestinationGPU.b * sourceToDestinationGPU.c
//        print("CUT/PASTE v7 dstLayer=\(targetLayerIndex) Ldst=\(Ldst)")
//        print("CUT/PASTE v7 D=\(sourceToDestinationGPU) det=\(detD)")
        guard abs(detD) > 1e-9 else { return [] }
        

        // Diagnostic: where does the source layer's content actually sit in the file?
//        let srcIndices = art.actions.enumerated().compactMap {
//            ($0.element["layer"] as? Int) == fromLayer ? $0.offset : nil
//        }
//        print("CUT/PASTE v7 paste@idx=\(actionIndex) srcLayer=\(fromLayer) srcActionIdx=\(srcIndices)")
        
        let resolvedStrokes = buildStrokesForLayer(
            layerIndex: fromLayer,
            art: art,
            baseTransform: B,
            visited: [])
        
        
//        print("CUT/PASTE v7 source strokes=\(resolvedStrokes.count)")
        
        
//        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
//                       CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map {
//            CGPoint(x: CGFloat(selectionRect[0]) + $0.x * CGFloat(selectionRect[2]),
//                    y: CGFloat(selectionRect[1]) + $0.y * CGFloat(selectionRect[3]))
//            .applying(matrix2)
//            .applying(selectionToDevice)
//        }
//        let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
//        let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
//        print("CUT/PASTE v10 predicted paste bbox: (\(minX), \(minY), \(maxX - minX), \(maxY - minY))")

        
        return assemblePasteOps(
            resolvedStrokes: resolvedStrokes,
            art: art,
            baseTransform: B,
            destinationToSourceGPU: destinationToSourceGPU,
            sourceToDestinationGPU: sourceToDestinationGPU,
            outerRect: selectionRect,
            outerM1: matrix1,
            colorAlpha: 1.0,
            flipTransform: flipTransform,
            isMerge: false,
            mergeID: 0)
    }
    
    private func assemblePasteOps(
        resolvedStrokes: [ResolvedStroke],
        art: ArtParser,
        baseTransform: CGAffineTransform,
        destinationToSourceGPU: CGAffineTransform,
        sourceToDestinationGPU: CGAffineTransform,
        outerRect: [Float]?,
        outerM1: CGAffineTransform?,
        colorAlpha: Float,
        flipTransform: CGAffineTransform?,
        isMerge: Bool,
        mergeID: UInt64
    ) -> [LayerOperation] {
        
        struct Group {
            var color: SIMD4<Float>
            var isEraser: Bool
            var isMarker: Bool
            var strokeToDevice: CGAffineTransform
            var accNow: CGAffineTransform
            var masks: [StrokeMask]
            var strokes: [StrokeRecord]
        }
        
        var groups: [Group] = []
        for resolved in resolvedStrokes {
            let strokeToDevice = layerMatrix(ofLayer: resolved.sourceLayerIndex, in: art)
                .concatenating(baseTransform)
                .concatenating(resolved.accumulatedDeviceTransform)
            let color = SIMD4<Float>(Float(resolved.stroke.pen.color.r),
                                     Float(resolved.stroke.pen.color.g),
                                     Float(resolved.stroke.pen.color.b), colorAlpha)
            if let idx = groups.firstIndex(where: {
                $0.color == color &&
                $0.isEraser == resolved.stroke.pen.isEraser &&
                $0.isMarker == resolved.stroke.pen.isMarker &&
                $0.strokeToDevice == strokeToDevice &&
                $0.masks == resolved.masks }) {
                groups[idx].strokes.append(resolved.stroke)
            } else {
                groups.append(Group(color: color,
                                    isEraser: resolved.stroke.pen.isEraser,
                                    isMarker: resolved.stroke.pen.isMarker,
                                    strokeToDevice: strokeToDevice,
                                    accNow: resolved.accumulatedDeviceTransform,
                                    masks: resolved.masks,
                                    strokes: [resolved.stroke]))
            }
        }
        
        var ops: [LayerOperation] = []
        for g in groups {
            var segments: [GPUSplineSegment] = []
            for stroke in g.strokes {
                guard let op = buildOpFromStroke(stroke,
                                                 artToDevice: g.strokeToDevice,
                                                 flipTransform: flipTransform) else { continue }
                segments.append(contentsOf: op.segments)
            }
            guard !segments.isEmpty else { continue }
            
            let Bi = baseTransform.inverted()
            var metaMasks: [PasteMask] = []
            
            // Slot 0: outer keep — src device -> this paste's selection frame (B⁻¹ ∘ m1).
            if let outerRect = outerRect, let outerM1 = outerM1 {
                metaMasks.append(PasteMask(inv: Bi.concatenating(outerM1),
                                           rectXYWH: outerRect, erase: false))
            }
            // Masks recorded during the replay (nested selections + cut erases).
            // Map: src device -> that mask's selection frame
            //      = accNow⁻¹ -> accRef -> B⁻¹ -> m1   (receiver-first chain below)
            for m in g.masks {
                let map = g.accNow.inverted()
                    .concatenating(m.accRef)
                    .concatenating(Bi)
                    .concatenating(m.m1)
                metaMasks.append(PasteMask(inv: map, rectXYWH: m.rect, erase: m.erase))
            }
            
            let meta = PasteLayerMeta(invAffine: destinationToSourceGPU,
                                      edgeWidth: 0.75, maskCount: UInt32(metaMasks.count))
//            print("CUT/PASTE op: segments=\(segments.count) masks=\(metaMasks.count) " +
//                  "(erase=\(metaMasks.filter { $0.flags.x > 0.5 }.count))")
            ops.append(.paste(
                segments: segments,
                color: g.color,
                isEraser: g.isEraser,
                isMarker: g.isMarker,
                meta: meta,
                masks: metaMasks,
                sourceToDestinationGPU: sourceToDestinationGPU,
                isMerge: isMerge,
                mergeID: mergeID))
        }
        return ops
    }
    
    private func layerMatrix(ofLayer i: Int, in art: ArtParser) -> CGAffineTransform {
        guard i >= 0, i < art.layers.count,
              let raw = parseMatrixRobust(art.layers[i]["matrix"]) else { return .identity }
        return transformFromMatrix(raw.map { $0.map { Float($0) } }, scale: 1.0)
    }
    
    private func actionMergeLayerOps(
        action: [String: Any],
        art: ArtParser,
        targetLayerIndex: Int,
        actionIndex: Int,
        baseTransform: CGAffineTransform,
        flipTransform: CGAffineTransform?
    ) -> [LayerOperation] {
        
        guard let fromLayer = action["from_layer"] as? Int,
              fromLayer >= 0, fromLayer < art.layers.count,
              let mRaw = parseMatrixRobust(action["matrix"]) else { return [] }
        
        let M = transformFromMatrix(mRaw.map { $0.map { Float($0) } }, scale: 1.0)
        // `matrix`+`zoom` is an action-time VIEW snapshot (same shape as matrix_1/zoom_1
        // in pastes), NOT a content transform. Merging preserves canvas position.
        print("MERGE v2 view-snapshot M (not applied)=\(M)")
        
        let B = baseTransform
        let opacitySrc = action["opacity_src"] as? Float ?? 1.0
        
        let sourceToDestinationGPU = baseTransform.inverted()
            .concatenating(layerMatrix(ofLayer: targetLayerIndex, in: art))
            .concatenating(baseTransform)          // B ∘ Ldst ∘ B⁻¹
        let destinationToSourceGPU = sourceToDestinationGPU.inverted()
        
        print("MERGE v1 dst=\(targetLayerIndex) src=\(fromLayer) M=\(M) opacity_src=\(opacitySrc)")
        
        guard abs(sourceToDestinationGPU.a * sourceToDestinationGPU.d
                  - sourceToDestinationGPU.b * sourceToDestinationGPU.c) > 1e-9 else { return [] }
        
        let resolvedStrokes = buildStrokesForLayer(
            layerIndex: fromLayer,
            art: art,
            baseTransform: B,
            visited: [])
        print("MERGE v1 source strokes=\(resolvedStrokes.count)")
        
        return assemblePasteOps(
            resolvedStrokes: resolvedStrokes,
            art: art,
            baseTransform: B,
            destinationToSourceGPU: destinationToSourceGPU,
            sourceToDestinationGPU: sourceToDestinationGPU,
            outerRect: nil,
            outerM1: nil,
            colorAlpha: opacitySrc,
            flipTransform: flipTransform,
            isMerge: true,
            mergeID: UInt64(bitPattern: Int64(actionIndex)))
    }
        
    /// Free-transform pastes restore a cut made on the SAME layer: the file records a
    /// `cut` with the same selection_rect shortly before the paste_layer. New-layer
    /// pastes have no cut — the app creates the layer and drops the clipboard in.
    private func pasteFollowsCut(art: ArtParser,
                                 layerIndex: Int,
                                 pasteActionIndex: Int,
                                 pasteRect: [Float]) -> Bool {
        var i = pasteActionIndex - 1
        while i >= 0 {
            let a = art.actions[i]
            if let l = a["layer"] as? Int, l == layerIndex,
               let name = a["action_name"] as? String {
                if name == "paste_layer" { return false }   // start of previous cycle
                if name == "cut",
                   let r = parseFloatArray(a["selection_rect"]), r.count == 4,
                   abs(r[0]-pasteRect[0]) < 0.01, abs(r[1]-pasteRect[1]) < 0.01,
                   abs(r[2]-pasteRect[2]) < 0.01, abs(r[3]-pasteRect[3]) < 0.01 {
                    return true
                }
            }
            i -= 1
        }
        return false
    }
        
    
//    private func extractRectParams(rect: [Float], artToDevice: CGAffineTransform, flip: CGAffineTransform) -> (center: SIMD4<Float>, axisX: SIMD4<Float>, axisY: SIMD4<Float>) {
//        let w = CGFloat(rect[2]) * 0.5
//        let h = CGFloat(rect[3]) * 0.5
//        let cx = CGFloat(rect[0] + rect[2] * 0.5)
//        let cy = CGFloat(rect[1] + rect[3] * 0.5)
//
//        // Transform center point to device space
//        let center = CGPoint(x: cx, y: cy).applying(artToDevice).applying(flip)
//
//        // Transform axes as vectors (scale/rotation only, no translation)
//        let axisXVec = CGPoint(x: w * artToDevice.a, y: w * artToDevice.b)
//        let axisYVec = CGPoint(x: h * artToDevice.c, y: h * artToDevice.d)
//
//        // Apply flip scale to vectors
//        let axisX = CGPoint(x: axisXVec.x * flip.a, y: axisXVec.y * flip.d)
//        let axisY = CGPoint(x: axisYVec.x * flip.a, y: axisYVec.y * flip.d)
//
//        return (SIMD4<Float>(Float(center.x), Float(center.y), 0, 0),
//                SIMD4<Float>(Float(axisX.x), Float(axisX.y), 0, 0),
//                SIMD4<Float>(Float(axisY.x), Float(axisY.y), 0, 0))
//    }
    
    private func nextPasteViewMatrix(in actions: [[String: Any]], after idx: Int) -> CGAffineTransform? {
        for j in (idx + 1)..<actions.count
        where actions[j]["action_name"] as? String == "paste_layer" {
            if let raw = parseMatrixRobust(actions[j]["matrix_1"]) {
                return transformFromMatrix(raw.map { $0.map { Float($0) } }, scale: 1.0)
            }
        }
        return nil
    }
    
    // MARK: - Paste/merge resolution for the stamp & CPU point paths
    
    private struct BakedMask: Equatable {
        var inv: CGAffineTransform     // source device -> selection frame
        var rect: [Float]
        var erase: Bool
    }
    
    private struct PasteRenderGroup {
        var color: SIMD4<Float>
        var isEraser: Bool
        var isMarker: Bool
        var strokes: [StrokeRecord]
        var lb: CGAffineTransform      // Lsrc ∘ B: art -> source device (layer + view)
        var accNow: CGAffineTransform  // accumulated selection transforms (device conjugation)
        var maskEntries: [BakedMask]
    }
    
    private struct ResolvedPasteRender {
        var groups: [PasteRenderGroup]
        var destMap: CGAffineTransform // D: source device -> destination device
        var isMerge: Bool = false   // merges composite as an isolated fragment;
                                    // their erasers scope to the merged layer's own content
    }
    
    /// Mirrors actionPasteLayerOps (GPU segment path) but yields point data.
    private func resolvePasteRender(
        action: [String: Any],
        art: ArtParser,
        targetLayerIndex: Int,
        actionIndex: Int,
        dstPenAffine: CGAffineTransform,
        dstLayerMatrix: CGAffineTransform,
        baseTransform: CGAffineTransform
    ) -> ResolvedPasteRender? {
        guard let fromLayer = action["from_layer"] as? Int,
              fromLayer >= 0, fromLayer < art.layers.count,
              let selectionRect = parseFloatArray(action["selection_rect"]),
              selectionRect.count == 4,
              let m1raw = parseMatrixRobust(action["matrix_1"]),
              let m2raw = parseMatrixRobust(action["matrix_2"]) else { return nil }
        
        let matrix1 = transformFromMatrix(m1raw.map { $0.map { Float($0) } }, scale: 1.0)
        let matrix2 = transformFromMatrix(m2raw.map { $0.map { Float($0) } }, scale: 1.0)
        
        let B = baseTransform
        let Ldst = dstLayerMatrix                // was: layerMatrix(ofLayer: targetLayerIndex, in: art)
        
        // device px -> selection frame (m1 ∘ B⁻¹)
        let deviceToSelection = B.inverted().concatenating(matrix1)
        let pen: CGAffineTransform
        let selectionToDevice: CGAffineTransform
        
        if isIdentityTransform(matrix1) {
            pen = dstPenAffine
            selectionToDevice = matrix1.inverted().concatenating(pen).concatenating(Ldst).concatenating(B)
        } else if pasteFollowsCut(art: art, layerIndex: targetLayerIndex,
                                  pasteActionIndex: actionIndex, pasteRect: selectionRect) {
            pen = .identity
            selectionToDevice = matrix1.inverted().concatenating(B)
        } else {
            pen = dstPenAffine
            // Matches actionPasteLayerOps — the layer matrix MUST be included.
            // Dropping it strips the layer translation (rotationOnlyInverse-class bug).
            selectionToDevice = pen.concatenating(Ldst).concatenating(B)
        }
        
        // D = (B⁻¹ ∘ m1) ∘ m2 ∘ selectionToDevice — source device -> dest device
        let destMap = deviceToSelection.concatenating(matrix2).concatenating(selectionToDevice)
        guard abs(destMap.a * destMap.d - destMap.b * destMap.c) > 1e-9 else { return nil }
        
        let resolvedStrokes = buildStrokesForLayer(layerIndex: fromLayer, art: art, baseTransform: B, visited: [])
        let groups = buildPasteRenderGroups(
            resolvedStrokes: resolvedStrokes, art: art, baseTransform: B,
            outerRect: selectionRect, outerM1: matrix1, colorAlpha: 1.0)
        return ResolvedPasteRender(groups: groups, destMap: destMap)
    }
    
    /// Mirrors actionMergeLayerOps (GPU segment path) but yields point data.
    /// `matrix` is an action-time view snapshot and is deliberately not applied.
    private func resolveMergeRender(
        action: [String: Any],
        art: ArtParser,
        targetLayerIndex: Int,
        baseTransform: CGAffineTransform
    ) -> ResolvedPasteRender? {
        guard let fromLayer = action["from_layer"] as? Int,
              fromLayer >= 0, fromLayer < art.layers.count,
              let _ = parseMatrixRobust(action["matrix"]) else { return nil }
        let B = baseTransform
        // Merge preserves canvas position: B ∘ Ldst ∘ B⁻¹
        let destMap = B.inverted()
            .concatenating(layerMatrix(ofLayer: targetLayerIndex, in: art))
            .concatenating(B)
        guard abs(destMap.a * destMap.d - destMap.b * destMap.c) > 1e-9 else { return nil }
        let opacitySrc = action["opacity_src"] as? Float ?? 1.0
        
        let resolvedStrokes = buildStrokesForLayer(layerIndex: fromLayer, art: art, baseTransform: B, visited: [])
        let groups = buildPasteRenderGroups(
            resolvedStrokes: resolvedStrokes, art: art, baseTransform: B,
            outerRect: nil, outerM1: nil, colorAlpha: opacitySrc)
        return ResolvedPasteRender(groups: groups, destMap: destMap, isMerge: true)
    }
    
    /// Mirrors assemblePasteOps' grouping and mask baking, but keeps point data.
    private func buildPasteRenderGroups(
        resolvedStrokes: [ResolvedStroke],
        art: ArtParser,
        baseTransform: CGAffineTransform,
        outerRect: [Float]?,
        outerM1: CGAffineTransform?,
        colorAlpha: Float
    ) -> [PasteRenderGroup] {
        let Bi = baseTransform.inverted()
        var groups: [PasteRenderGroup] = []
        
        for resolved in resolvedStrokes {
            let lb = layerMatrix(ofLayer: resolved.sourceLayerIndex, in: art)
                .concatenating(baseTransform)
            let accNow = resolved.accumulatedDeviceTransform
            let color = SIMD4<Float>(Float(resolved.stroke.pen.color.r),
                                     Float(resolved.stroke.pen.color.g),
                                     Float(resolved.stroke.pen.color.b), colorAlpha)
            
            var maskEntries: [BakedMask] = []
            // Slot 0: outer keep — src device -> this paste's selection frame (B⁻¹ ∘ m1).
            if let outerRect = outerRect, let outerM1 = outerM1 {
                maskEntries.append(BakedMask(inv: Bi.concatenating(outerM1), rect: outerRect, erase: false))
            }
            // Replay masks: accNow⁻¹ -> accRef -> B⁻¹ -> m1 (same chain as the GPU path).
            for m in resolved.masks {
                maskEntries.append(BakedMask(
                    inv: accNow.inverted().concatenating(m.accRef).concatenating(Bi).concatenating(m.m1),
                    rect: m.rect, erase: m.erase))
            }
            
            if let idx = groups.firstIndex(where: {
                $0.color == color &&
                $0.isEraser == resolved.stroke.pen.isEraser &&
                $0.isMarker == resolved.stroke.pen.isMarker &&
                $0.lb == lb && $0.accNow == accNow && $0.maskEntries == maskEntries }) {
                groups[idx].strokes.append(resolved.stroke)
            } else {
                groups.append(PasteRenderGroup(
                    color: color,
                    isEraser: resolved.stroke.pen.isEraser,
                    isMarker: resolved.stroke.pen.isMarker,
                    strokes: [resolved.stroke],
                    lb: lb, accNow: accNow,
                    maskEntries: maskEntries))
            }
        }
        return groups
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
        guard m.count >= 4, m[0].count >= 4 else { return .identity }
        return CGAffineTransform(
            a:  CGFloat(m[0][0]) * scale,
            b: -CGFloat(m[1][0]) * scale,
            c: -CGFloat(m[0][1]) * scale,
            d:  CGFloat(m[1][1]) * scale,
            tx: CGFloat(m[3][0]) * scale,
            ty: CGFloat(m[3][1]) * scale
        )
    }

    
    // Legacy alias so old call sites keep compiling
    private func toDirectCGTransform(_ m: [[Float]], scale: CGFloat = 1.0) -> CGAffineTransform {
        transformFromMatrix(m, scale: scale)
    }
    
    private func isIdentityTransform(_ t: CGAffineTransform) -> Bool {
        abs(t.a - 1) < 1e-6 && abs(t.d - 1) < 1e-6 &&
        abs(t.b) < 1e-6 && abs(t.c) < 1e-6 &&
        abs(t.tx) < 1e-6 && abs(t.ty) < 1e-6
    }
    
    /// m1⁻¹ with the zoom removed: keeps rotation + translation unwind, drops 1/scale.
    /// At zoom_1 = 1 this is exactly m1⁻¹ (all previously validated files are unaffected).
//    private func rotationOnlyInverse(_ m: CGAffineTransform) -> CGAffineTransform {
//        let s = sqrt(abs(m.a * m.d - m.b * m.c))   // m1's zoom (= zoom_1)
//        guard s > 1e-9 else { return .identity }
//        let inv = m.inverted()
//        return CGAffineTransform(a: inv.a * s, b: inv.b * s,
//                                 c: inv.c * s, d: inv.d * s,
//                                 tx: inv.tx * s, ty: inv.ty * s)
//    }
    
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
    func buildSplineSamples(_ pts: [Point], samplesPerSegment: Int, isPolyline: Bool)
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
        
        if isPolyline {
            return (gpts, pressures)
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
    func buildResampledStrokeWithSpline(_ raw: [Point], stepPx: CGFloat, samplesPerSegment: Int = 6, gamma: Float = 1.0, isPolyline: Bool) -> [Point] {
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
        let (poly, pressures) = buildSplineSamples(clamped, samplesPerSegment: samplesPerSegment, isPolyline: isPolyline)
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
    
    private func verticallyFlipRenderedImage(_ image: CGImage) -> CGImage? {
        let context = createBitmapContext(
            size: canvasSize,
            scale: scale
        )
        
        let rect = CGRect(
            x: 0,
            y: 0,
            width: context.width,
            height: context.height
        )
        
        context.saveGState()
        
        // Same convention used by the old GPU compositing path.
        context.scaleBy(x: 1, y: -1)
        context.translateBy(
            x: 0,
            y: -CGFloat(context.height)
        )
        
        context.draw(image, in: rect)
        
        context.restoreGState()
        
        return context.makeImage()
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

func buildOpFromStroke(
    _ stroke: StrokeRecord,
    artToDevice: CGAffineTransform,
    flipTransform: CGAffineTransform?
) -> (segments: [GPUSplineSegment], color: SIMD4<Float>, isEraser: Bool, isMarker: Bool, meta: PasteLayerMeta?, m2Transform: CGAffineTransform?)? {
    
    guard stroke.points.count >= 1 else { return nil }
    let points = stroke.points.count == 1 ? [stroke.points[0], stroke.points[0]] : stroke.points
    
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
    let flip = flipTransform ?? .identity
    
    var transformedPoints: [(p: CGPoint, pressure: Float)] = []
    for p in points {
        var pt = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
        if let affine = stroke.pen.penMatrixAffine { pt = pt.applying(affine) }
        pt = pt.applying(artToDevice)
        pt = pt.applying(flip)
        transformedPoints.append((pt, p.p))
    }
    
    var radii: [CGFloat] = []
    var opacities: [CGFloat] = []
    for tp in transformedPoints {
        let (r, op) = pressureToRadiusOpacity(pressure: tp.pressure, pen: stroke.pen, radiusScale: effectiveRadiusScale, gamma: 1.0)
        radii.append(r)
        opacities.append(CGFloat(op))
    }
    
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
    
    let seed = stroke.pen.type == 1 ? arc4random() + 1 : 0
    var segmentsForStroke: [GPUSplineSegment] = []
    segmentsForStroke.reserveCapacity((pts.count - 3) * 4)
    
    for i in 1..<(pts.count - 2) {
        let pSpan = CRPointSpan(p0: pts[i-1], p1: pts[i], p2: pts[i+1], p3: pts[i+2])
        let rSpan = CRScalarSpan(s0: rads[i-1], s1: rads[i], s2: rads[i+1], s3: rads[i+2])
        let oSpan = CRScalarSpan(s0: opas[i-1], s1: opas[i], s2: opas[i+1], s3: opas[i+2])
        flattenAndBuild(span: pSpan, rSpan: rSpan, oSpan: oSpan, seed: seed, depth: 0, into: &segmentsForStroke, isPolyline: stroke.isPolyline, isMarker: stroke.pen.isMarker)
    }
    
    return (segments: segmentsForStroke, color: color, isEraser: stroke.pen.isEraser, isMarker: stroke.pen.isMarker, meta: nil, m2Transform: nil)
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
    
    // Convert Left Bezier back to CR
    let l_p0 = CGPoint(x: m.x - 6.0 * (m01.x - b0.x), y: m.y - 6.0 * (m01.y - b0.y))
    let l_p1 = b0
    let l_p2 = m
    let l_p3 = CGPoint(x: b0.x + 6.0 * (m.x - m012.x), y: b0.y + 6.0 * (m.y - m012.y))
    let left = CRPointSpan(p0: l_p0, p1: l_p1, p2: l_p2, p3: l_p3)
    
    // Convert Right Bezier back to CR
    let r_p0 = CGPoint(x: b3.x - 6.0 * (m123.x - m.x), y: b3.y - 6.0 * (m123.y - m.y))
    let r_p1 = m
    let r_p2 = b3
    let r_p3 = CGPoint(x: m.x + 6.0 * (b3.x - m23.x), y: m.y + 6.0 * (b3.y - m23.y))
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
    
    let l_s0 = m - 6.0 * (m01 - b0)
    let l_s1 = b0
    let l_s2 = m
    let l_s3 = b0 + 6.0 * (m - m012)
    let left = CRScalarSpan(s0: l_s0, s1: l_s1, s2: l_s2, s3: l_s3)
    
    let r_s0 = b3 - 6.0 * (m123 - m)
    let r_s1 = m
    let r_s2 = b3
    let r_s3 = m + 6.0 * (b3 - m23)
    let right = CRScalarSpan(s0: r_s0, s1: r_s1, s2: r_s2, s3: r_s3)
    
    return (left, right)
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

func flattenAndBuild(span: CRPointSpan, rSpan: CRScalarSpan, oSpan: CRScalarSpan, seed: UInt32, depth: Int = 0, into segments: inout [GPUSplineSegment], isPolyline: Bool, isMarker: Bool) {
    
    if isPolyline {
        flattenPolyline(span: span, rSpan: rSpan, oSpan: oSpan, seed: seed, into: &segments)
        return
    }
    
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
    if isMarker && h_chord > 10.0 { needsSubdivide = true }
    if !isSafeAngle(v0, v1) || !isSafeAngle(v1, v2) { needsSubdivide = true }
    
    if !needsSubdivide || depth > 8 {
        let r_max = max(r1, r2)
        
        // Changed from 1.5 to 1.0 for more overlap.
        // This allows the shader to use a simple `min` instead of `smin`,
        let shape2_max_len = min(
            5.0 * max(0.0, (r_max - 0.82) * abs(r1 - r2)),
            1.0 * r_max
        )
        
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
    
    flattenAndBuild(span: leftP, rSpan: leftR, oSpan: leftO, seed: seed, depth: depth + 1, into: &segments, isPolyline: isPolyline, isMarker: isMarker)
    flattenAndBuild(span: rightP, rSpan: rightR, oSpan: rightO, seed: seed, depth: depth + 1, into: &segments, isPolyline: isPolyline, isMarker: isMarker)
}

func flattenPolyline(
    span: CRPointSpan,
    rSpan: CRScalarSpan,
    oSpan: CRScalarSpan,
    seed: UInt32,
    into segments: inout [GPUSplineSegment]
) {
    let p1 = span.p1, p2 = span.p2
    let dx = p2.x - p1.x, dy = p2.y - p1.y
    let len = hypot(dx, dy)
    
    // 1. Base target length on the maximum radius of this span
    let r_max = max(rSpan.s1, rSpan.s2)
    
    // 2. Determine how many radii long a segment should be.
    // Adjust this multiplier based on visual testing (e.g. 2.0 to 8.0).
    let radiusMultiplier: CGFloat = 0.5
    
    // We use max(..., 4.0) as a hard floor to prevent infinite subdivisions
    // or millions of segments if the radius is 0 or extremely small.
    let targetLen = max(4.0, r_max * radiusMultiplier)
    
    let n = max(1, Int((len / targetLen).rounded(.up)))
    let invN = 1.0 / CGFloat(n)
    
    // 3. Emit segments
    for i in 0..<n {
        let t0 = CGFloat(i) * invN
        let t1 = CGFloat(i + 1) * invN
        
        let a = CGPoint(x: p1.x + dx * t0, y: p1.y + dy * t0)
        let b = CGPoint(x: p1.x + dx * t1, y: p1.y + dy * t1)
        
        // Straight extrapolation for tangent hints
        let a0 = CGPoint(x: 2 * a.x - b.x, y: 2 * a.y - b.y)
        let b3 = CGPoint(x: 2 * b.x - a.x, y: 2 * b.y - a.y)
        
        // Linearly interpolate radius and opacity
        let r0 = rSpan.s1 + (rSpan.s2 - rSpan.s1) * t0
        let r1 = rSpan.s1 + (rSpan.s2 - rSpan.s1) * t1
        let o0 = oSpan.s1 + (oSpan.s2 - oSpan.s1) * t0
        let o1 = oSpan.s1 + (oSpan.s2 - oSpan.s1) * t1
        
        segments.append(GPUSplineSegment(
            p0: SIMD2<Float>(Float(a0.x), Float(a0.y)),
            p1: SIMD2<Float>(Float(a.x),  Float(a.y)),
            p2: SIMD2<Float>(Float(b.x),  Float(b.y)),
            p3: SIMD2<Float>(Float(b3.x), Float(b3.y)),
            radius0: Float(r0), radius1: Float(r1),
            opacity0: Float(o0), opacity1: Float(o1),
            segmentType: 0,
            noiseSeed: seed
        ))
    }
}
#endif
