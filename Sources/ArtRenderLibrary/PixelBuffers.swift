import Foundation
#if os(Linux)
import Silica
//import CoreFoundation
//import Cairo
//import JPEG
#elseif os(macOS)
import CoreGraphics
#endif


// MARK: - Dirty Rectangles
internal struct DirtyRect {
    var x0: Int, y0: Int, x1: Int, y1: Int   // x1/y1 exclusive
    
    var isEmpty: Bool { x0 >= x1 || y0 >= y1 }
    
    static var null: DirtyRect { DirtyRect(x0: Int.max, y0: Int.max, x1: Int.min, y1: Int.min) }
    
    mutating func formUnion(_ other: DirtyRect) {
        if other.isEmpty { return }
        if isEmpty { self = other; return }
        x0 = min(x0, other.x0); y0 = min(y0, other.y0)
        x1 = max(x1, other.x1); y1 = max(y1, other.y1)
    }
    
    /// Rect in CG user space (y-up). Plane rows are top-down, so the rect's
    /// origin y is canvasH - y1, NOT y0.
    func cgRect(canvasHeight: Int) -> CGRect {
#if os(Linux)
        CGRect(x: CGFloat(x0), y: CGFloat(y0),
               width: CGFloat(x1 - x0), height: CGFloat(y1 - y0))
#else
        CGRect(x: CGFloat(x0), y: CGFloat(canvasHeight - y1),
               width: CGFloat(x1 - x0), height: CGFloat(y1 - y0))
#endif
    }
    
}

// MARK: - Alpha Plane
internal final class AlphaPlane {
    let width: Int
    let height: Int
    let bytesPerRow: Int
    let data: UnsafeMutablePointer<UInt8>
    /// Region written during last use; zeroed on next acquire.
    var stale: DirtyRect = .null
    
    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        self.bytesPerRow = width
        self.data = UnsafeMutablePointer<UInt8>.allocate(capacity: width * height)
    }
    
    deinit { data.deallocate() }
}

extension AlphaPlane {
    /// Max-blits `tile` at (dstX, dstY), clipped to plane bounds.
    /// Returns the rect actually written, or nil if fully clipped.
    @discardableResult
    func maxBlitOptimized(tile: UnsafePointer<UInt8>, tileW: Int, tileH: Int,
                          dstX: Int, dstY: Int) -> DirtyRect? {
        let x0 = max(0, dstX)
        let y0 = max(0, dstY)
        let x1 = min(width,  dstX + tileW)
        let y1 = min(height, dstY + tileH)
        if x0 >= x1 || y0 >= y1 { return nil }
        
        let rowBytes = x1 - x0
        var srcRow = UnsafeRawPointer(tile) + (y0 - dstY) * tileW + (x0 - dstX)
        var dstRow = UnsafeMutableRawPointer(data) + y0 * bytesPerRow + x0
        
        for _ in y0..<y1 {
            var i = 0
            while i + 64 <= rowBytes {
                let s: SIMD64<UInt8> = srcRow.loadUnaligned(fromByteOffset: i, as: SIMD64<UInt8>.self)
                let d: SIMD64<UInt8> = dstRow.loadUnaligned(fromByteOffset: i, as: SIMD64<UInt8>.self)
                dstRow.storeBytes(of: d.replacing(with: s, where: s .> d),
                                  toByteOffset: i, as: SIMD64<UInt8>.self)
                i += 64
            }
            let s8 = srcRow.assumingMemoryBound(to: UInt8.self)
            let d8 = dstRow.assumingMemoryBound(to: UInt8.self)
            while i < rowBytes {
                let s = s8[i], d = d8[i]
                d8[i] = s > d ? s : d
                i += 1
            }
            srcRow += tileW
            dstRow += bytesPerRow
        }
        return DirtyRect(x0: x0, y0: y0, x1: x1, y1: y1)
    }
}

// MARK: - Alpha Plane Pool
internal enum AlphaPlanePool {
    private static let lock = NSLock()
    private static var cached: AlphaPlane?
    private static let maxCachedBytes = 64 << 20
    
    /// Contract: the returned plane is ALL ZERO. Never returns stale pixels.
    static func acquire(width: Int, height: Int) -> AlphaPlane {
        lock.lock()
        let pooled = cached
        cached = nil
        lock.unlock()
        
        guard let p = pooled, p.width == width, p.height == height else {
            let plane = AlphaPlane(width: width, height: height)
            plane.data.initialize(repeating: 0, count: width * height)
            return plane
        }
        
        let s = p.stale
        if !s.isEmpty {
            for y in s.y0..<s.y1 {
                memset(p.data + y * p.bytesPerRow + s.x0, 0, s.x1 - s.x0)
            }
        }
        p.stale = .null
        return p
    }
    
    /// `dirty` must cover every byte written since acquire
    /// (union of maxBlitOptimized return values).
    static func recycle(_ plane: AlphaPlane, dirty: DirtyRect) {
        plane.stale = dirty
        lock.lock()
        if cached == nil, plane.width * plane.height <= maxCachedBytes {
            cached = plane
        }
        lock.unlock()
    }
}

extension Renderer {
    // MARK: - Temporary Bitmap Context Pool
    internal final class TempContextPool {
        static let shared = TempContextPool()
        private var freeCtx: [CGContext] = []
        private var stale: [CGContext: CGRect] = [:] // top-left px rect drawn since release
        
        func acquire(size: CGSize, scale: CGFloat) -> CGContext {
            if let c = freeCtx.popLast() {
                if let d = stale.removeValue(forKey: c) { zeroPixels(c, d) }
                return c
            }
            let ctx = createBitmapContext(size: size, scale: scale)
            memset(ctx.data!, 0, ctx.bytesPerRow * ctx.height) // first-touch, paid once per pool slot
            return ctx
        }
        
        func release(_ ctx: CGContext, dirtyPx: CGRect?) {
            let full = CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height)
            stale[ctx] = dirtyPx ?? full
            freeCtx.append(ctx)
        }
        
        private func zeroPixels(_ ctx: CGContext, _ r: CGRect) {
            guard let base = ctx.data else { return }
            let x0 = max(0, Int(r.minX.rounded(.down)))
            let x1 = min(ctx.width, Int(r.maxX.rounded(.up)))
            let y0 = max(0, Int(r.minY.rounded(.down)))
            let y1 = min(ctx.height, Int(r.maxY.rounded(.up)))
            for y in y0..<y1 {
                memset(base.advanced(by: y * ctx.bytesPerRow + x0 * 4), 0, (x1 - x0) * 4)
            }
        }
    }
    
    
    // MARK: - Tile Buffers
    // Reusable tile buffer to avoid per-dab allocations
    internal struct TileBuffer {
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
    internal final class TileBufferPool {
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
}
