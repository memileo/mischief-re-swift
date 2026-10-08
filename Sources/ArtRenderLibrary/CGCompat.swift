#if os(Linux)
import Foundation
import CoreFoundation
import Silica
import Cairo
import JPEG

// MARK: - CoreGraphics Type Shims
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

public final class CGColorSpace {
    public static let sRGB = "sRGB"
    public static let linearGray = "linearGray"
    public let name: String
    public init?(name: String) { self.name = name }
}

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

// MARK: - CGContext Extensions (metadata, pixels, drawing)

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
    
    public func stroke(_ rect: CGRect) {
        // TODO: Implement using Silica/Cairo path + stroke
        // Use strokePath() ?
    }
    public func rotate(by angle: CGFloat) {
        // TODO: Implement using Cairo rotate
    }
}


// MARK: - Color & Bitmap Info Extensions
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

extension CGBitmapInfo {
    public var rawValue: UInt32 {
        // Silica CGBitmapInfo may not store a raw value;
        // return a sensible default for premultiplied ARGB
        return CGImageAlphaInfo.premultipliedLast.rawValue
    }
}

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

// MARK: - Bitmap Context Factories
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

// MARK: - JPEG Bytestream Bridge
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
