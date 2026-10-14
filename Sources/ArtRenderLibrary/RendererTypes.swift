import Foundation
#if os(Linux)
import CoreFoundation
import Silica
#endif


// MARK: - Stroke and Pen Types
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

struct StrokeRecord {
    var points: [Point]
    var pen: PenInfo
    var penMatrixScale: CGFloat
    var penMatrixAffine: CGAffineTransform?
    var isPolyline: Bool
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

struct StrokeMask: Equatable {
    var m1: CGAffineTransform        // action-time view: canvas -> selection frame
    var rect: [Float]                // selection rect x,y,w,h
    var accRef: CGAffineTransform    // stroke's accumulated transform when recorded
    var erase: Bool                  // false = keep, true = erase
}

internal struct ResolvedStroke {
    let stroke: StrokeRecord
    let accumulatedDeviceTransform: CGAffineTransform
    let sourceLayerIndex: Int
    let selectionRect: [Float]
    var masks: [StrokeMask] = []     // NEW — shape cases need no edits (default [])
}


// MARK: - Box-local tile binning (platform-independent; unit-tested on Linux)

/// One segment's canvas tile range, pre-clamped and transform-applied. `.empty` means
/// "off-canvas" (`minX > maxX`), and `isValid` distinguishes it.
public struct SegTileRange {
    public var minTX: Int32
    public var minTY: Int32
    public var maxTX: Int32
    public var maxTY: Int32
    public static let empty = SegTileRange(minTX: 1, minTY: 0, maxTX: 0, maxTY: 0)
    public var isValid: Bool { minTX <= maxTX && minTY <= maxTY }
}

/// Box-local bin output. `starts`/`counts` are indexed *relative to the box* (`y * boxWidth + x`),
/// so the render kernel subtracts the box origin. `tileList` buckets segment indices per
/// box-local tile (row-major). For the non-live path the box is the whole canvas, so
/// box-local == absolute and nothing changes there.
public struct TileBinningResult {
    public var minX: Int32
    public var minY: Int32
    public var boxWidth: Int
    public var boxHeight: Int
    public var starts: [UInt32]
    public var counts: [UInt32]
    public var tileList: [UInt32]
}

public enum SegmentBinner {
    /// Inclusive bounding box of all valid ranges, or nil when none are on-canvas.
    public static func unionBox(_ ranges: [SegTileRange])
        -> (minX: Int32, minY: Int32, maxX: Int32, maxY: Int32)?
    {
        var minX = Int32.max, minY = Int32.max, maxX = Int32.min, maxY = Int32.min
        for r in ranges where r.isValid {
            if r.minTX < minX { minX = r.minTX }
            if r.minTY < minY { minY = r.minTY }
            if r.maxTX > maxX { maxX = r.maxTX }
            if r.maxTY > maxY { maxY = r.maxTY }
        }
        if maxX == Int32.min { return nil }
        return (minX, minY, maxX, maxY)
    }

    /// Bin every valid segment into the given tile box, prefix-summing and scattering only
    /// within that box (the whole point: a stroke's box is far smaller than the canvas, so
    /// this is much cheaper than the old whole-canvas pass). The box MUST contain every
    /// valid range — i.e. come from `unionBox`, or be the whole canvas.
    public static func bin(_ ranges: [SegTileRange],
                           box: (minX: Int32, minY: Int32, maxX: Int32, maxY: Int32))
        -> TileBinningResult
    {
        let boxW = Int(box.maxX) - Int(box.minX) + 1
        let boxH = Int(box.maxY) - Int(box.minY) + 1
        guard boxW > 0, boxH > 0 else {
            return TileBinningResult(minX: box.minX, minY: box.minY, boxWidth: 0, boxHeight: 0,
                                     starts: [], counts: [], tileList: [])
        }
        let originX = Int(box.minX), originY = Int(box.minY)
        let tileCount = boxW * boxH

        // Pass 1: per-tile overlap counts within the box.
        var counts = [UInt32](repeating: 0, count: tileCount)
        for r in ranges where r.isValid {
            let spanX = Int(r.maxTX) - Int(r.minTX)
            var rowBase = (Int(r.minTY) - originY) * boxW + (Int(r.minTX) - originX)
            for _ in Int(r.minTY)...Int(r.maxTY) {
                var idx = rowBase
                for _ in 0...spanX { counts[idx] += 1; idx += 1 }
                rowBase += boxW
            }
        }

        // Prefix sum → per-tile start offsets.
        var starts = [UInt32](repeating: 0, count: tileCount)
        var running: UInt32 = 0
        for i in 0..<tileCount { starts[i] = running; running += counts[i] }

        // Pass 2: scatter each segment's index into its tiles.
        var tileList = [UInt32](repeating: 0, count: Int(running))
        var heads = starts
        for (i, r) in ranges.enumerated() where r.isValid {
            let spanX = Int(r.maxTX) - Int(r.minTX)
            let segIdx = UInt32(i)
            var rowBase = (Int(r.minTY) - originY) * boxW + (Int(r.minTX) - originX)
            for _ in Int(r.minTY)...Int(r.maxTY) {
                var idx = rowBase
                for _ in 0...spanX { tileList[Int(heads[idx])] = segIdx; heads[idx] += 1; idx += 1 }
                rowBase += boxW
            }
        }
        return TileBinningResult(minX: box.minX, minY: box.minY, boxWidth: boxW, boxHeight: boxH,
                                 starts: starts, counts: counts, tileList: tileList)
    }
}

// MARK: - Per-segment prune radius (platform-independent; unit-tested on Linux)

/// A conservative upper bound on how far a segment's ink can sit from its chord p1→p2,
/// used by the live kernels to skip a candidate segment for a given pixel (see the gate in
/// `segmentKernels.metal`). A pixel whose distance to the chord exceeds this radius cannot
/// receive any coverage from the segment, so the expensive SDF is skipped with identical
/// output.
///
/// Bounds it relies on:
///   * a straight capsule (segmentType 0) draws only p1→p2 + radius, so its ink never
///     leaves the chord;
///   * a spline (type 1 / 2) sweeps the Catmull-Rom curve, which stays inside the convex
///     hull of the four control points; the hull's farthest point from the chord p1→p2 is
///     p0 or p3 (p1, p2 are on the chord);
///   * a chisel marker sweeps a capsule reaching ~4·radius (3r along the 45° axis + r).
/// The margin is at least 0.75 px (the AA kernel's coverage is 0 past ~0.44 px) and at
/// least 0.375·rMax (the noise kernel's coverage tail) — the larger of the two keeps the
/// single stored value valid for both kernels.
public enum SegmentPrune {
    /// Squared distance from point (px,py) to segment a–b.
    static func segmentDistanceSq(ax: Float, ay: Float, bx: Float, by: Float,
                                  px: Float, py: Float) -> Float {
        let ex = bx - ax, ey = by - ay
        let denom = ex * ex + ey * ey
        var t: Float = 0
        if denom > 1e-12 {
            let u = ((px - ax) * ex + (py - ay) * ey) / denom
            t = u < 0 ? 0 : (u > 1 ? 1 : u)
        }
        let cx = ax + ex * t, cy = ay + ey * t
        let dx = px - cx, dy = py - cy
        return dx * dx + dy * dy
    }

    public static func radius(p0: SIMD2<Float>, p1: SIMD2<Float>, p2: SIMD2<Float>, p3: SIMD2<Float>,
                              radius0: Float, radius1: Float,
                              segmentType: UInt32, isMarker: Bool) -> Float {
        let rMax = max(radius0, radius1)
        let farOffChord: Float
        if segmentType == 0 {
            farOffChord = 0
        } else {
            farOffChord = max(
                segmentDistanceSq(ax: p1.x, ay: p1.y, bx: p2.x, by: p2.y, px: p0.x, py: p0.y).squareRoot(),
                segmentDistanceSq(ax: p1.x, ay: p1.y, bx: p2.x, by: p2.y, px: p3.x, py: p3.y).squareRoot())
        }
        let reach: Float = isMarker ? (4.0 * rMax) : rMax
        let margin: Float = max(0.75, 0.375 * rMax)
        return farOffChord + reach + margin
    }
}

// MARK: - Tile-bin padding (platform-independent; unit-tested on Linux)

/// Conservative per-segment tile-bin padding: how far a segment's ink can reach from
/// its chord p1→p2, expanded to whole tiles. Must contain the kernel's paint, or tiles
/// get dropped and strokes clip.
///
/// * plain strokes sweep radius r → 1.4·r + 1 (matches the historic binning constant;
///   covers r + the 0.44 px AA tail + tile rounding).
/// * markers sweep a 45° chisel reaching 4·r from the chord (3r along the axis + r
///   capsule radius) → 4·r + 2 (the +2 covers the AA tail + tile rounding). The old
///   constant (1 + 2·√2 ≈ 3.83)·r + 1 clipped large markers by ~0.17·r per side — the
///   "clipped thickness + aliased edges" bug.
public enum SegmentPadding {
    public static func pad(radiusMax: Float, isMarker: Bool) -> Float {
        if isMarker {
            return 4.0 * radiusMax + 2.0
        } else {
            return 1.4 * radiusMax + 1.0
        }
    }
}

// MARK: - Live-view defaults (platform-independent; unit-tested on Linux)

/// Default configuration for the interactive live path. Pure functions of the
/// environment so they can be pinned by Linux tests; the Metal renderers call through.
public enum LiveConfig {
    /// Per-tile composite (one dispatch per layer) is the default; set
    /// `ART_LIVE_PERTILE=0` to force the per-stroke path for A/B comparison.
    public static func perTileEnabled(environment: [String: String]? = nil) -> Bool {
        let env = environment ?? ProcessInfo.processInfo.environment
        return env["ART_LIVE_PERTILE"] != "0"
    }

    /// GPU tile binning (transform + tile ranges + counts on the GPU, scatter + sort on
    /// the GPU, tiny prefix on the CPU) is the default; set `ART_LIVE_GPUBIN=0` to force
    /// the CPU binning path for A/B comparison. Missing pipelines also fall back to CPU
    /// automatically — never to wrong pixels.
    public static func gpuBinEnabled(environment: [String: String]? = nil) -> Bool {
        let env = environment ?? ProcessInfo.processInfo.environment
        return env["ART_LIVE_GPUBIN"] != "0"
    }

    /// Per-stage GPU timing for the binned path (`ART_LIVE_BINTIME=1`): splits CB2 into
    /// one command buffer per stage so the log shows scatter/sort/render costs
    /// separately. Diagnostic only — steady state keeps the single-CB form.
    public static func binStageTimingEnabled(environment: [String: String]? = nil) -> Bool {
        let env = environment ?? ProcessInfo.processInfo.environment
        return env["ART_LIVE_BINTIME"] == "1"
    }

    /// Gather-path budget: layers with boxTiles × segCount at or below this use the
    /// contention-free gather binning; above it the scatter+sort path runs.
    /// `ART_LIVE_GATHER=0` forces scatter everywhere; a positive number sets a custom
    /// budget (default 256M — comfortably between a clustered layer at ~64M and kaos
    /// at ~2.5B). Pure environment function, runs on Linux.
    public static func gatherBudget(environment: [String: String]? = nil) -> Int64 {
        let env = environment ?? ProcessInfo.processInfo.environment
        guard let raw = env["ART_LIVE_GATHER"], let v = Int64(raw), v >= 0 else {
            return 256_000_000
        }
        return v
    }

    /// Tile size for the *live* binning/dispatch. Resolution order:
    /// `ART_LIVE_TILE_SIZE` → `ART_TILE_SIZE` → 16 (the measured default).
    /// The static path keeps its own default (32); only the live path uses this.
    public static func liveTileSize(environment: [String: String]? = nil) -> Int {
        let env = environment ?? ProcessInfo.processInfo.environment
        if let v = env["ART_LIVE_TILE_SIZE"], let n = Int(v), n >= 8 { return n }
        if let v = env["ART_TILE_SIZE"], let n = Int(v), n >= 8 { return n }
        return 16
    }
}

// MARK: - GPU tile binning spec (platform-independent; unit-tested on Linux)
//
// Contract between the CPU plan builder and the `liveBin*` Metal kernels
// (`ArtQuickLook/ArtRenderShaders/segmentKernels.metal`). The kernels mirror this maths
// exactly (same float op order, same truncation-toward-zero int conversion, same clamps),
// so GPU-built tile structures agree with the CPU-built ones up to the conservative
// padding slop — which can only add empty tiles, never drop inked ones.
//
// Layout note: `GpuBinTileEntry` is layout-identical to the Metal/Swift `TileIndex`
// `{start, count}` pair (two UInt32, stride 8). The macOS side memcpys between them.

/// One tile's slice of the tile list. Layout-identical to `TileIndex`.
public struct GpuBinTileEntry {
    public var start: UInt32
    public var count: UInt32
    public init(start: UInt32, count: UInt32) {
        self.start = start
        self.count = count
    }
}

public enum GpuBinSpec {
    /// Tile grid dimensions for a viewport. Mirrors `(w + tile - 1) / tile` on both sides.
    public static func tileGrid(viewportWidth: Int, viewportHeight: Int,
                                tileSize: Int) -> (tilesX: Int, tilesY: Int) {
        ((viewportWidth + tileSize - 1) / tileSize,
         (viewportHeight + tileSize - 1) / tileSize)
    }

    /// Tile AABB of a camera-transformed stroke-bounds AABB, clamped to the canvas grid.
    /// Uses floor/ceil (NOT truncation) so the result is a SUPERSET of the per-segment
    /// ranges the binning kernels compute — a shrunken box would drop ink, an extra empty
    /// tile row/column only costs a few no-op threadgroups. Returns nil when the AABB is
    /// strictly off-canvas (same strict inequalities as the per-segment cull).
    public static func tileBoxForAABB(minX: Float, minY: Float, maxX: Float, maxY: Float,
                                      texW: Float, texH: Float,
                                      tilesX: Int, tilesY: Int,
                                      invTile: Float)
        -> (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        if maxX < 0 || minX > texW || maxY < 0 || minY > texH { return nil }
        let a = max(0, min(tilesX - 1, Int(floor(minX * invTile))))
        let b = max(0, min(tilesX - 1, Int(ceil(maxX * invTile))))
        let c = max(0, min(tilesY - 1, Int(floor(minY * invTile))))
        let d = max(0, min(tilesY - 1, Int(ceil(maxY * invTile))))
        guard a <= b && c <= d else { return nil }
        return (a, c, b, d)
    }

    /// Merges a stroke tile box into the running layer box (absolute canvas tiles).
    public static func unionTileBox(_ acc: (minX: Int, minY: Int, maxX: Int, maxY: Int)?,
                                    with box: (minX: Int, minY: Int, maxX: Int, maxY: Int))
        -> (minX: Int, minY: Int, maxX: Int, maxY: Int) {
        guard let acc else { return box }
        return (min(acc.minX, box.minX), min(acc.minY, box.minY),
                max(acc.maxX, box.maxX), max(acc.maxY, box.maxY))
    }

    /// Gather-vs-scatter selection. The gather walk costs ~2 × boxTiles × segCount
    /// cheap range tests (count + fill passes) with zero atomics and no sort, while the
    /// scatter path costs ~incidences contended atomic adds plus a per-tile sort that
    /// goes latency-bound on dense tiles. At or below the budget gather wins
    /// (clustered / zoomed-out layers); above it scatter wins (large even spreads).
    /// Int64 product — boxTiles × segCount overflows 32 bits on kaos-scale documents.
    public static func useGather(boxTiles: Int, segCount: Int, budget: Int64) -> Bool {
        Int64(boxTiles) * Int64(segCount) <= budget
    }

    /// Prefix-sums per-tile counts into per-tile (start, count) entries plus the grand
    /// total (the tile-list size). `entries[t].start` is the tile's tile-list slice —
    /// the single source of truth the GPU scatter/sort/gather/render agree on.
    public static func combine(counts: [UInt32])
        -> (entries: [GpuBinTileEntry], starts: [UInt32], total: Int) {
        var entries = [GpuBinTileEntry]()
        entries.reserveCapacity(counts.count)
        var starts = [UInt32]()
        starts.reserveCapacity(counts.count)
        var running: UInt64 = 0
        for c in counts {
            precondition(running + UInt64(c) <= UInt64(UInt32.max),
                         "tile-list overflow: more incidences than UInt32 range")
            starts.append(UInt32(running))
            entries.append(GpuBinTileEntry(start: UInt32(running), count: c))
            running += UInt64(c)
        }
        return (entries, starts, Int(running))
    }
}

// MARK: - GPU and Layer Payloads
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

public extension CutMeta {
    /// Recovers the affine that was packed into `row0`/`row1` in `init`.
    /// Exact inverse of the packing: row0 = (a, c, tx, 0), row1 = (b, d, ty, 0).
    var inverseAffine: CGAffineTransform {
        CGAffineTransform(
            a:  CGFloat(row0.x),
            b:  CGFloat(row1.x),
            c:  CGFloat(row0.y),
            d:  CGFloat(row1.y),
            tx: CGFloat(row0.z),
            ty: CGFloat(row1.z)
        )
    }
}

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

// MARK: - Paste/Merge Render Types
internal struct BakedMask: Equatable {
    var inv: CGAffineTransform     // source device -> selection frame
    var rect: [Float]
    var erase: Bool
}

internal struct PasteRenderGroup {
    var color: SIMD4<Float>
    var isEraser: Bool
    var isMarker: Bool
    var strokes: [StrokeRecord]
    var lb: CGAffineTransform      // Lsrc ∘ B: art -> source device (layer + view)
    var accNow: CGAffineTransform  // accumulated selection transforms (device conjugation)
    var maskEntries: [BakedMask]
}

internal struct ResolvedPasteRender {
    var groups: [PasteRenderGroup]
    var destMap: CGAffineTransform // D: source device -> destination device
    var isMerge: Bool = false   // merges composite as an isolated fragment;
    // their erasers scope to the merged layer's own content
}

// MARK: - Small Generic Utilities
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
