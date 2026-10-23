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

/// A conservative upper bound on how far a segment's *shape* can sit from its chord
/// p1→p2, used by the live kernels to skip a candidate segment for a given pixel (see the
/// gate in `segmentKernels.metal`). A pixel whose distance to the chord exceeds
/// `radius + deviceMargin` cannot receive any coverage from the segment, so the expensive
/// SDF is skipped with identical output.
///
/// Bounds it relies on:
///   * a straight capsule (segmentType 0) draws only p1→p2 + radius, so its ink never
///     leaves the chord;
///   * a spline (type 1 / 2) evaluates the Catmull-Rom curve only at t ∈ [0, 1], and that
///     curve lies inside the convex hull of its cubic Bézier control points
///     B0 = p1, B1 = p1 + (p2-p0)/6, B2 = p2 - (p3-p1)/6, B3 = p2. B0 and B3 are the chord
///     ends, so `max(dist(B1), dist(B2))` bounds the curve's distance from the chord.
///     (Bounding the *Catmull-Rom* control points p0/p3 instead — the obvious choice, and
///     what this used to do — is ~6× looser, because a spline deviates from its chord by
///     about a sixth of the neighbour offsets, not by all of it. On `kaos` that loose
///     bound made the prune radius ~2× the ink and was ~60 % of all SDF evaluations.)
///   * a chisel marker sweeps a capsule reaching ~4·radius (3r along the 45° axis + r)
///     from the curve.
///
/// The stored value (`GPUSplineSegment.padding1`) is *shape only*: it lives in document
/// space and scales with the camera like the radii. The coverage margins are added by the
/// kernels in **device pixels**, because they describe the falloff in canvas space and do
/// not scale with the zoom — `aaDeviceMargin` for the AA kernels (coverage is exactly zero
/// past 0.44 px) and `noiseDeviceMargin` for the noise twins (their falloff reaches
/// 1.375·max(radius, 1) from the shape). Folding a scaled margin into `padding1` was both
/// too loose when zoomed in (kaos: 1.375·r vs the 1.0·r + 0.5 px the ink needs — over half
/// of every SDF evaluation was spent on provably empty pixels) and too tight when zoomed
/// out (the constant tail shrinks with the camera).
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

    /// Coverage of the AA kernels is exactly zero past this distance from the shape:
    /// `cov = 1 - smootherstep(-0.94, 0.94, sd + 0.5)` reaches 0 at `sd = 0.44`.
    public static let aaCutoff: Float = 0.44

    /// Device-space prune margin the AA kernels add to the stored shape reach
    /// (`aaCutoff` + slack for the prune test's own float rounding).
    public static let aaDeviceMargin: Float = 0.5

    /// The noise kernels' coverage reaches `noiseReachFactor · max(radius, 1)` from the
    /// shape: `nd = dist / (1.1·max(radius, 1))` and the airbrush falloff is zero at
    /// `nd = 1.25`. Mirror of the constant in `segmentKernels.metal`.
    public static let noiseReachFactor: Float = 1.375

    /// Device-space prune margin for the noise kernels (see `noiseReachFactor`). A thick
    /// stroke keeps the scaled falloff `0.375·rMax`; when the local radius drops below
    /// one pixel the kernel's `max(radius, 1)` floor reaches farther than that, up to
    /// `1.375 - r`. Tested against the kernel's coverage formula in
    /// `SegmentPruneTests`; keep in step with `segmentKernels.metal`.
    public static func noiseDeviceMargin(radius0: Float, radius1: Float) -> Float {
        let rMax = max(radius0, radius1)
        let rMin = min(radius0, radius1)
        var margin = max(aaDeviceMargin, (noiseReachFactor - 1.0) * rMax)
        if rMin < 1.0 { margin = max(margin, noiseReachFactor - rMin) }
        return margin
    }

    public static func radius(p0: SIMD2<Float>, p1: SIMD2<Float>, p2: SIMD2<Float>, p3: SIMD2<Float>,
                              radius0: Float, radius1: Float,
                              segmentType: UInt32, isMarker: Bool) -> Float {
        let rMax = max(radius0, radius1)
        let farOffChord: Float
        if segmentType == 0 {
            farOffChord = 0
        } else {
            // Cubic Bézier form of this Catmull-Rom span (B0 = p1, B3 = p2 are the chord
            // ends); the curve is inside hull(B0…B3), so the handles bound its deviation.
            let b1x = p1.x + (p2.x - p0.x) / 6, b1y = p1.y + (p2.y - p0.y) / 6
            let b2x = p2.x - (p3.x - p1.x) / 6, b2y = p2.y - (p3.y - p1.y) / 6
            let handleReach = max(
                segmentDistanceSq(ax: p1.x, ay: p1.y, bx: p2.x, by: p2.y, px: b1x, py: b1y).squareRoot(),
                segmentDistanceSq(ax: p1.x, ay: p1.y, bx: p2.x, by: p2.y, px: b2x, py: b2y).squareRoot())
            // The Catmull-Rom control hull also contains the span, but with non-uniform
            // point spacing its chord-distance bound can be *tighter* than the handles'
            // (a far-back p0 pushes B1 past the chord end), so take the smaller of the two
            // — both are valid bounds, and neither is ever looser than the old p0/p3 rule.
            let pointReach = max(
                segmentDistanceSq(ax: p1.x, ay: p1.y, bx: p2.x, by: p2.y, px: p0.x, py: p0.y).squareRoot(),
                segmentDistanceSq(ax: p1.x, ay: p1.y, bx: p2.x, by: p2.y, px: p3.x, py: p3.y).squareRoot())
            farOffChord = min(handleReach, pointReach)
        }
        let reach: Float = isMarker ? (4.0 * rMax) : rMax
        return farOffChord + reach
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

    /// Tile-list integrity check for the binned path (`ART_LIVE_BINCHECK=1`): forces
    /// the split-CB form and reads the tile list back after every stage (scatter,
    /// chunk sort, each merge pass), verifying every index is in bounds and every
    /// finished run is ascending. Prints the first offender per stage. Diagnostic
    /// only — slow (full readbacks), never on by default.
    public static func binCheckEnabled(environment: [String: String]? = nil) -> Bool {
        let env = environment ?? ProcessInfo.processInfo.environment
        return env["ART_LIVE_BINCHECK"] == "1"
    }

    /// Merge unit size for the GPU sort (`ART_LIVE_MERGE_UNIT`, clamped 16…4096,
    /// default `GpuBinSpec.mergeUnitSize`). Tuning knob: lower means more threads
    /// per merge pass and a shorter per-thread dependency chain (better for dense
    /// zoom-out tiles); higher means fewer units to build and upload per frame.
    public static func mergeUnitSize(environment: [String: String]? = nil) -> Int {
        let env = environment ?? ProcessInfo.processInfo.environment
        if let v = env["ART_LIVE_MERGE_UNIT"], let n = Int(v), n >= 16, n <= 4096 { return n }
        return GpuBinSpec.mergeUnitSize
    }

    /// Stroke-box pruning in the per-tile composite kernels (default on; set
    /// `ART_LIVE_STROKE_PRUNE=0` to A/B against the direct segment walk). Only dense
    /// tiles participate (see `GpuBinSpec.strokePruneMinTileEntries`), the table is
    /// dropped when it cannot pay for itself (see `strokeBlockTable`'s usability gate)
    /// and a dropped table keeps the exact behaviour, just with the plain segment walk.
    public static func strokePruneEnabled(environment: [String: String]? = nil) -> Bool {
        let env = environment ?? ProcessInfo.processInfo.environment
        return env["ART_LIVE_STROKE_PRUNE"] != "0"
    }

    /// Build the stroke-block table even when the usability gate says its block boxes are
    /// too coarse to skip anything (`ART_LIVE_STROKE_PRUNE=2`). Measurement knob only: the
    /// pixels are identical either way, so this A/Bs the table's GPU value against its CPU
    /// build cost (kaos zoom 1: ~39 ms of `bin` and a 36 MB upload for ~1.5M entries).
    public static func strokePruneForced(environment: [String: String]? = nil) -> Bool {
        let env = environment ?? ProcessInfo.processInfo.environment
        return env["ART_LIVE_STROKE_PRUNE"] == "2"
    }

    /// Sort chunk size override (`ART_LIVE_SORT_CHUNK`, clamped 64…1024, default 512).
    /// Smaller chunks give `liveBinChunkSortV3Kernel` more threads and shallower
    /// per-thread heaps; merge passes/units grow correspondingly (spec, CPU-only —
    /// the kernels are chunk-size-agnostic, so no rebuild of the metallib is needed
    /// to sweep this).
    public static func sortChunkSize(environment: [String: String]? = nil) -> Int {
        let env = environment ?? ProcessInfo.processInfo.environment
        guard let raw = env["ART_LIVE_SORT_CHUNK"], let v = Int(raw) else {
            return GpuBinSpec.sortChunkSize
        }
        return max(64, min(1024, v))
    }

    /// Segment-parallel splat composite for small-stamp views (default ON; set
    /// `ART_LIVE_SPLAT=0` for the per-pixel walk A/B). Only used when the view's
    /// `radiusFactor` and pixel budget admit it (see below) — otherwise the walk runs
    /// unchanged. Output is byte-identical by construction (see `SPLAT-DESIGN.md`).
    public static func splatEnabled(environment: [String: String]? = nil) -> Bool {
        let env = environment ?? ProcessInfo.processInfo.environment
        return env["ART_LIVE_SPLAT"] != "0"
    }

    /// Largest `radiusFactor` (camera scale) at which the splat path is exact. For
    /// `radiusFactor ≤ 1` the segment prune radius is ≤ the binning box pad, so the
    /// prune disk is a subset of the tile range and the splat's pixel set equals the
    /// walk's (`ART_LIVE_SPLAT_MAX_RF`, default 1.0, clamped 0…4).
    public static func splatMaxRadiusFactor(environment: [String: String]? = nil) -> Float {
        let env = environment ?? ProcessInfo.processInfo.environment
        guard let v = env["ART_LIVE_SPLAT_MAX_RF"], let f = Float(v) else { return 1.0 }
        return max(0, min(4, f))
    }

    /// Slots per pixel = visible strokes handled per splat batch
    /// (`ART_LIVE_SPLAT_BATCH`, clamped 8…512, default 128). Larger = fewer dispatches
    /// but a wider per-pixel composite loop; the total composite work (pixels × visible
    /// strokes) is independent of it.
    public static func splatBatchSlots(environment: [String: String]? = nil) -> Int {
        let env = environment ?? ProcessInfo.processInfo.environment
        guard let v = env["ART_LIVE_SPLAT_BATCH"], let n = Int(v) else { return 128 }
        return max(8, min(512, n))
    }

    /// Budget for the splat scratch (`ART_LIVE_SPLAT_SLOT_BUDGET`, in slots = pixels ×
    /// batch, default 16M = 64 MB of uint + 256 MB of float4 acc… the acc is sized by
    /// pixels only). Frames that would exceed it fall back to the walk, so deep zoom-in
    /// (huge boxes) never allocates a monster.
    public static func splatSlotBudget(environment: [String: String]? = nil) -> Int {
        let env = environment ?? ProcessInfo.processInfo.environment
        guard let v = env["ART_LIVE_SPLAT_SLOT_BUDGET"], let n = Int(v) else { return 16_000_000 }
        return max(65_536, n)
    }

    /// Weight of one splat slot read relative to one walk pixel evaluation
    /// (`ART_LIVE_SPLAT_COST`, default 2, clamped 0…16). 0 disables the cost model and
    /// leaves the plain radiusFactor/slot-budget gate in charge. See
    /// `GpuBinSpec.splatCheaperThanWalk`.
    public static func splatCostRatio(environment: [String: String]? = nil) -> Double {
        let env = environment ?? ProcessInfo.processInfo.environment
        guard let v = env["ART_LIVE_SPLAT_COST"], let f = Double(v) else {
            return GpuBinSpec.splatCostRatioDefault
        }
        return max(0, min(16, f))
    }

    /// Whether the live chunk sort uses the v4 threadgroup bitonic (default ON).
    /// `ART_LIVE_SORT_BITONIC=0` reverts to the v3 per-thread heapsort for A/B
    /// gates and regression comparisons; the merge passes are unchanged either
    /// way (same chunks, same unit table), so output bytes are identical.
    public static func sortBitonicEnabled(environment: [String: String]? = nil) -> Bool {
        let env = environment ?? ProcessInfo.processInfo.environment
        return env["ART_LIVE_SORT_BITONIC"] != "0"
    }

    /// Tile size for the *live* binning/dispatch. Resolution order:
    /// `ART_LIVE_TILE_SIZE` → `ART_TILE_SIZE` → 16 (the measured default).
    /// The static path keeps its own default (32); only the live path uses this.
    ///
    /// Must be a multiple of the 16×16 live threadgroup (16…64). The live composite
    /// dispatches `ceil(tileSize / 16)` whole threadgroups per tile, but every threadgroup
    /// is 16×16 pixels: with a tile smaller than the group (8) each group also covers the
    /// *next* tile, i.e. pixels outside the layer's tile box, and `localTile` then indexes
    /// past the per-tile tables (`Invalid device load executing kernel function
    /// "livePerTileAACompositeKernel"`, plus duplicated content next to the box). Values
    /// that are not a multiple of 16 are ignored (the renderer says so once at launch).
    public static func liveTileSize(environment: [String: String]? = nil) -> Int {
        let env = environment ?? ProcessInfo.processInfo.environment
        for key in ["ART_LIVE_TILE_SIZE", "ART_TILE_SIZE"] {
            if let v = env[key], let n = Int(v), n >= 16, n <= 64, n % 16 == 0 { return n }
        }
        return 16
    }

    /// Composite-kernel ablation mask (`ART_LIVE_ABLATE`, 0 = off, clamped 0…31).
    /// Debug only — the pixels it produces are wrong by construction. It exists to
    /// attribute the per-tile composite's frame time on GPUs with no per-line profiling
    /// (AMD): run the same view once per bit and compare `render+comp`. Implemented in
    /// `livePerTileAACompositeKernel`; noisy layers take the noise twin, which ignores
    /// the mask. Each bit is a dispatch-uniform branch, so 0 is the shipping kernel:
    ///   1  no SDF — isolates SDF + coverage
    ///   2  prune rejects everything — loop + tile-list/segment loads + block table only
    ///   4  no per-stroke blend/quantise
    ///   8  no pixel write
    ///   16 constant-address segment load (hoists the 64-byte fetch of the tile's segment)
    public static func ablate(environment: [String: String]? = nil) -> Int {
        let env = environment ?? ProcessInfo.processInfo.environment
        guard let v = env["ART_LIVE_ABLATE"], let n = Int(v) else { return 0 }
        return min(max(n, 0), 31)
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

/// One slice of a tile's list for the chunked GPU sort. Layout-identical to a Metal
/// `uint2`: (start, len) into the tile list, stride 8. The macOS side memcpys them.
public struct GpuBinChunk {
    public var start: UInt32
    public var len: UInt32
    public init(start: UInt32, len: UInt32) {
        self.start = start
        self.len = len
    }
}

/// One pairwise merge unit for the GPU sort. Layout-identical to a Metal `uint4`:
/// (aStart, aLen, bLen, dst) — B starts at aStart + aLen; bLen == 0 is a plain copy
/// carrying a finished run across the ping-pong. Stride 16.
public struct GpuBinMergePair {
    public var aStart: UInt32
    public var aLen: UInt32
    public var bLen: UInt32
    public var dst: UInt32
    public init(aStart: UInt32, aLen: UInt32, bLen: UInt32, dst: UInt32) {
        self.aStart = aStart
        self.aLen = aLen
        self.bLen = bLen
        self.dst = dst
    }
}

/// One thread's share of a merge pair for the GPU sort. Layout-identical to the
/// Metal `LiveBinMergeUnit`: the pair bounds (aStart, aLen, bLen, dst) plus the
/// output partition [dst+part, dst+part+partLen) this thread owns. Six UInt32,
/// stride 24. The kernel locates the partition's input split with a co-rank binary
/// search, then serial-merges only its partition — so per-thread work stays bounded
/// no matter how dense the tile (the old one-thread-per-pair tail did up to 65K
/// serial steps in a single thread, stalling zoomed-out frames).
/// One clickable stroke unit for the per-tile composite's box pruning. Layout-identical
/// to the Metal `LiveStrokeGroupBlock`: segStart + stroke ID plus the conservative half-open
/// device-space stamp box `[min, max)` (five 4-byte fields, stride 20). The composite
/// kernels consult it per stroke-group change; a pixel outside the box provably
/// stamps nothing for that stroke (the pad covers both the AA and the noise cutoff),
/// so skipping changes no output value — it only skips provably-zero work.
/// One sub-stroke block for the per-tile composite's box pruning. The block table
/// refines the earlier whole-stroke boxes: a "block" is `pruneBlockSize` consecutive
/// segments of one stroke (never crossing strokes), so a stroke packed with many
/// small segments can still skip far-away chunks segment-run by segment-run.
/// Layout-identical to the Metal `LiveStrokeGroupBlock`; four plain floats (no
/// vectors) so Metal's 4-byte alignment matches Swift byte-for-byte: eight u32/f32
/// fields, stride 24. The device box is half-open `[min, max)` and the pad (CPU:
/// 1.4·maxRadius·radiusFactor + 3.5 px over the transformed block AABB) covers every
/// stamp cutoff (AA cov > 0 needs chord distance < r(t)+0.44; noise cov > 0 needs
/// chord distance < 1.375·max(r,1); the stored prune gate only tightens) — a pixel
/// outside the box provably stamps nothing for the block's segments, so skipping
/// changes no output value, it only skips provably-zero work.
public struct GpuBinStrokeBlock {
    public var segStart: UInt32   // global index of the block's first segment
    public var strokeID: UInt32
    public var minX: Float
    public var minY: Float
    public var maxX: Float
    public var maxY: Float
    public init(segStart: UInt32, strokeID: UInt32,
                minX: Float, minY: Float, maxX: Float, maxY: Float) {
        self.segStart = segStart
        self.strokeID = strokeID
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }
}

public struct GpuBinMergeUnit {
    public var aStart: UInt32
    public var aLen: UInt32
    public var bLen: UInt32
    public var dst: UInt32
    public var part: UInt32
    public var partLen: UInt32
    public init(aStart: UInt32, aLen: UInt32, bLen: UInt32, dst: UInt32,
                part: UInt32, partLen: UInt32) {
        self.aStart = aStart
        self.aLen = aLen
        self.bLen = bLen
        self.dst = dst
        self.part = part
        self.partLen = partLen
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

    /// Splits every sortable tile slice (count >= 2) into fixed-size chunks for the
    /// GPU chunked sort: one thread sorts one chunk in place (`liveBinChunkSortV3Kernel`),
    /// then `mergePasses` pairwise merge passes (`liveBinMergePassV2Kernel`, runs doubling
    /// from one chunk) restore full ascending order. `mergePasses` is
    /// ceil(log2(maxChunks)) — 0 when every tile fits one chunk (the common case: no
    /// merge dispatches at all). Pure integer logic, runs on Linux.
    public static func chunkTable(entries: [GpuBinTileEntry],
                                  chunkSize: Int = sortChunkSize)
        -> (chunks: [GpuBinChunk], maxChunks: Int, mergePasses: Int) {
        var chunks: [GpuBinChunk] = []
        chunks.reserveCapacity(entries.count)
        var maxChunks = 0
        for e in entries {
            let n = Int(e.count)
            guard n >= 2 else { continue }
            let k = (n + chunkSize - 1) / chunkSize
            maxChunks = max(maxChunks, k)
            var o = 0
            while o < n {
                let len = min(chunkSize, n - o)
                chunks.append(GpuBinChunk(start: e.start + UInt32(o), len: UInt32(len)))
                o += len
            }
        }
        var passes = 0
        var k = maxChunks
        while k > 1 { k = (k + 1) / 2; passes += 1 }
        return (chunks, maxChunks, passes)
    }

    /// Pairwise merge units for one merge pass at `runSize` (runs of `runSize` merge
    /// into runs of `2 * runSize`). Covers every non-empty tile: multi-chunk slices
    /// get real merges, everything else plain copies (bLen == 0) that carry finished
    /// data across the tileList/scratch ping-pong — src and dst are never the same
    /// buffer, so an in-place merge (which clobbers unread input) cannot happen.
    /// Every emitted pair does at most `2 * runSize` sequential steps, so per-thread
    /// work stays bounded at any zoom. Pure integer logic, runs on Linux.
    public static func mergePairs(entries: [GpuBinTileEntry], runSize: Int) -> [GpuBinMergePair] {
        var pairs: [GpuBinMergePair] = []
        let twoS = runSize * 2
        for e in entries {
            let n = Int(e.count)
            guard n >= 1 else { continue }
            var o = 0
            while o < n {
                let aLen = min(runSize, n - o)
                let bLen = (n - o > runSize) ? min(runSize, n - o - runSize) : 0
                pairs.append(GpuBinMergePair(aStart: e.start + UInt32(o),
                                             aLen: UInt32(aLen), bLen: UInt32(bLen),
                                             dst: e.start + UInt32(o)))
                o += twoS
            }
        }
        return pairs
    }

    /// Merge plan for all `mergePasses` passes: per-pass thread-unit tables plus each
    /// pass's slot offset in one concatenated unit buffer (`offsets[p]` = total units
    /// of all earlier passes, `totalUnits` = grand total). Every pair's output range
    /// is split into units of at most `unitSize` entries, so no thread ever
    /// serial-merges more than one unit — the pairwise tail that stalled dense tiles
    /// is gone. The GPU needs every pass's units resident at dispatch time —
    /// rewriting one shared buffer per pass is a hazard (earlier dispatches in the
    /// same command buffer would read the LAST pass's data and silently mis-sort),
    /// so all passes are uploaded once up front and each dispatch binds its own
    /// offset. Pure integer logic, runs on Linux.
    public static func mergePlan(entries: [GpuBinTileEntry], mergePasses: Int,
                                 chunkSize: Int = sortChunkSize,
                                 unitSize: Int = mergeUnitSize)
        -> (units: [[GpuBinMergeUnit]], offsets: [Int], totalUnits: Int) {
        var units: [[GpuBinMergeUnit]] = []
        units.reserveCapacity(mergePasses)
        var offsets: [Int] = []
        offsets.reserveCapacity(mergePasses)
        var total = 0
        var runSize = chunkSize
        for _ in 0..<mergePasses {
            offsets.append(total)
            var passUnits: [GpuBinMergeUnit] = []
            for pr in mergePairs(entries: entries, runSize: runSize) {
                let len = Int(pr.aLen) + Int(pr.bLen)
                var part = 0
                while part < len {
                    let partLen = min(unitSize, len - part)
                    passUnits.append(GpuBinMergeUnit(aStart: pr.aStart, aLen: pr.aLen,
                                                     bLen: pr.bLen, dst: pr.dst,
                                                     part: UInt32(part),
                                                     partLen: UInt32(partLen)))
                    part += partLen
                }
            }
            units.append(passUnits)
            total += passUnits.count
            runSize *= 2
        }
        return (units, offsets, total)
    }

    /// Maximum output entries one merge thread owns. Bounds per-thread serial work
    /// at any zoom. Small on purpose: the two-finger merge's next load address
    /// depends on the previous compare, so per-thread work is a dependency chain —
    /// on dense zoom-out tiles 1024-entry units left only ~300 threads per pass,
    /// each stalling ~1K dependent memory steps (~2 ms per pass). 64-entry units
    /// give the same pass 16× the threads and a 16× shorter chain.
    public static let mergeUnitSize = 64

    /// Fixed sort work quantum (entries). Every GPU sort thread sorts at most this
    /// many entries, so per-thread nonlinear work is bounded no matter how far the
    /// user zooms out. Must match the `512` in `liveBinChunkSortV3Kernel` /
    /// `liveBinMergePassV2Kernel` (merge run sizes start at one chunk and double).
    public static let sortChunkSize = 512

    /// Prefix-sums per-tile counts into per-tile (start, count) entries plus the grand
    /// total (the tile-list size). `entries[t].start` is the tile's tile-list slice —
    /// the single source of truth the GPU scatter/chunk-sort/merge/render agree on.
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

    // MARK: Splat vs walk cost model

    /// Default weight of one splat slot operation relative to one walk pixel
    /// evaluation. Both paths are exact — this only picks the cheaper one per layer.
    ///
    /// The walk pays `entries × tileArea` pixel evaluations (that is exactly the `sdf`
    /// counter BINTIME reports). The splat replays every visible stroke for every box
    /// pixel, padded up to whole batches: `boxPixels × batches × batchSlots` slot reads.
    /// A slot read costs ~2× a walk evaluation — it runs the same SDF and then an atomic
    /// max, and at zoom-out the composite has only `boxPixels` threads, so it is
    /// latency- rather than throughput-bound. Measured on `complex.art` @ 0.3:
    /// walk 21.9M evaluations = 3.5 ms against splat 30.6M slots = 16.1 ms, so the walk
    /// wins by 4.6× — well past this 2× weight.
    public static let splatCostRatioDefault: Double = 2.0

    /// Work estimate for the per-tile walk, in pixel evaluations.
    public static func walkPixelOps(entries: Int, tileSize: Int) -> Double {
        guard entries > 0, tileSize > 0 else { return 0 }
        return Double(entries) * Double(tileSize * tileSize)
    }

    /// Work estimate for the splat composite, in slot reads (batches rounded up, exactly
    /// like the kernel loop).
    public static func splatSlotOps(boxPixels: Int, visibleStrokes: Int,
                                    batchSlots: Int) -> Double {
        guard boxPixels > 0, visibleStrokes > 0, batchSlots > 0 else { return 0 }
        let batches = (visibleStrokes + batchSlots - 1) / batchSlots
        return Double(boxPixels) * Double(batches * batchSlots)
    }

    /// True when the splat is predicted to be cheaper than the walk for this layer.
    /// `costRatio <= 0` accepts the splat whenever the eligibility gates allow it (the
    /// pre-model behaviour, `ART_LIVE_SPLAT_COST=0`).
    public static func splatCheaperThanWalk(entries: Int, tileSize: Int,
                                            boxPixels: Int, visibleStrokes: Int,
                                            batchSlots: Int, costRatio: Double) -> Bool {
        if costRatio <= 0 { return true }
        let walk = walkPixelOps(entries: entries, tileSize: tileSize)
        let splat = splatSlotOps(boxPixels: boxPixels, visibleStrokes: visibleStrokes,
                                 batchSlots: batchSlots)
        return walk > splat * costRatio
    }

    // MARK: Stroke-group table for composite box pruning

    /// Minimum entries a tile needs before the per-pixel composite kernel switches to
    /// the stroke-group box walk. Sparse tiles (the overwhelmingly common case at base
    /// zoom) walk segments directly — the table costs nothing and changes nothing.
    public static let strokePruneMinTileEntries = 64

    /// Upper bound on table entries accepted per frame. Beyond it the table is dropped
    /// for that frame (kernels fall back to the direct segment walk) instead of
    /// ballooning CPU plan time / upload traffic.
    public static let strokePruneBudget = 2_000_000

    /// Segments per pruning block: consecutive segments of one stroke become one
    /// table entry with a conservative box. 32 keeps table size modest (~31 entries
    /// per 1K entries) while cutting per-block walk cost; finer blocks mostly add
    /// upload bytes without improving skip rates.
    public static let pruneBlockSize = 32

    /// Builds the per-tile stroke-BLOCK table the composite kernels use to skip runs
    /// of segments whose padded device box misses the pixel — a much finer cut than
    /// the whole-stroke boxes: mega-strokes (tens of thousands of segments) skip
    /// per-block instead of never. Inputs:
    /// `visibleStrokes` = visible stroke indices in document order;
    /// `blockFirst`/`blockCount` = per stroke, its contiguous range within the flat
    /// block arrays; `blockStroke`/`blockSegStart`/`blockRects` = flat per-block data
    /// (rect = doc-space inclusive AABB covering the stroke's cached segment bounds);
    /// `blockMaxRadius` = per block, max(radius0, radius1) doc space (pads the block's
    /// box; tighter than a stroke-level pad on tapering strokes);
    /// `camera`/`radiusFactor` = the exact same transform formulas the fused kernel
    /// uses (device = (a·x + c·y + tx, b·x + d·y + ty), radius scaled by
    /// radiusFactor); `tileCounts` = per box-local tile entry count (density gate);
    /// `box` + tex dims = layer tile coordinates. Output: `header` (two UInt32 per
    /// box-local tile: [start, count) into `entries`) and per-tile flat block
    /// entries in ascending segStart order (blocks iterate stroke-then-block, both
    /// ascending, so per-tile appends need no sort; blocks never span strokes, so
    /// segment runs and stroke-completion boundaries both stay exact). A tile below
    /// the density gate gets no entries — the kernel walks its segments directly,
    /// exactly as before. A total above `budget`, or a table estimated to touch at least
    /// half as many (tile, block) pairs as the tile list has incidences, drops the table
    /// for this frame: at that density a box test per block cannot skip enough segments to
    /// pay for itself (kaos zoom 1: 1.50M entries vs 1.45M incidences).
    /// Pure float/int logic, runs on Linux; the Metal kernels mirror the walk.
    public static func strokeBlockTable(visibleStrokes: [Int],
                                        blockFirst: [Int], blockCount: [Int],
                                        blockStroke: [Int32], blockSegStart: [Int32],
                                        blockRects: [SIMD4<Float>],
                                        blockMaxRadius: [Float],
                                        camera: (a: Float, b: Float, c: Float,
                                                 d: Float, tx: Float, ty: Float),
                                        radiusFactor: Float,
                                        tileCounts: [UInt32],
                                        box: (minX: Int, minY: Int, maxX: Int, maxY: Int),
                                        texW: Int, texH: Int, tilesX: Int, tilesY: Int,
                                        invTile: Float,
                                        minEntries: Int = strokePruneMinTileEntries,
                                        budget: Int = strokePruneBudget,
                                        force: Bool = false)
        -> (header: [UInt32], entries: [GpuBinStrokeBlock], totalBlocks: Int,
            blockTileEstimate: Int) {
        let boxW = max(box.maxX - box.minX + 1, 0)
        let boxH = max(box.maxY - box.minY + 1, 0)
        let boxTiles = boxW * boxH
        var header = [UInt32](repeating: 0, count: boxTiles * 2)
        guard boxTiles > 0, tileCounts.count >= boxTiles else { return (header, [], 0, 0) }

        // One pass over visible strokes' blocks, caching each block's padded device
        // box + tile range (pass 1 counts appends, pass 2 fills). Blocks absent from
        // the output texture keep their cache slot with an empty range so per-stroke
        // block ranges stay contiguous.
        var devBoxes: [SIMD4<Float>] = []
        devBoxes.reserveCapacity(blockRects.count)
        var devRanges: [(minX: Int, minY: Int, maxX: Int, maxY: Int)] = []
        devRanges.reserveCapacity(blockRects.count)
        var perTile = [Int](repeating: 0, count: boxTiles)
        // Upper bound on the finished table's size, accumulated in this same pass (the
        // clamped area of every block's tile box). The usability gate below needs it
        // BEFORE the O(entries) work, which is the expensive part.
        var blockTileEstimate = 0

        for sid in visibleStrokes {
            guard sid >= 0, sid < blockCount.count, sid < blockFirst.count else { continue }
            var b = blockFirst[sid]
            let end = b + blockCount[sid]
            while b < end {
                defer { b += 1 }
                guard b < blockRects.count, b < blockStroke.count,
                      b < blockSegStart.count, b < blockMaxRadius.count else { break }
                let pad = 1.4 * blockMaxRadius[b] * radiusFactor + 3.5
                let r = blockRects[b]
                // Camera-apply the four doc corners (affine, row-major like CGAffineTransform.apply).
                let x0 = camera.a * r.x + camera.c * r.y + camera.tx
                let y0 = camera.b * r.x + camera.d * r.y + camera.ty
                let x1 = camera.a * r.z + camera.c * r.y + camera.tx
                let y1 = camera.b * r.z + camera.d * r.y + camera.ty
                let x2 = camera.a * r.x + camera.c * r.w + camera.tx
                let y2 = camera.b * r.x + camera.d * r.w + camera.ty
                let x3 = camera.a * r.z + camera.c * r.w + camera.tx
                let y3 = camera.b * r.z + camera.d * r.w + camera.ty
                let minX = min(min(x0, x1), min(x2, x3))
                let maxX = max(max(x0, x1), max(x2, x3))
                let minY = min(min(y0, y1), min(y2, y3))
                let maxY = max(max(y0, y1), max(y2, y3))
                let dv = SIMD4<Float>(minX - pad, minY - pad, maxX + 1 + pad, maxY + 1 + pad)
                // Tile range MUST be computed from the PADDED box, not the bare corner
                // AABB: `liveBinRangeForSeg` scatters each segment into tiles reached by
                // its endpoints expanded by 1.4·r·radiusFactor + 1 px, which can cross a
                // tile row/column beyond the block's bare rect. A block owning entries in
                // a tile that its table range misses would be absent from that tile's
                // table, desyncing the kernel's segStart cursor and applying the WRONG
                // block's box to segments (glitches). The pad (1.4·rmax·radiusFactor
                // + 3.5, corner set p0..p3 ⊇ the scatter's p1/p2, ceil ≥ floor) makes the
                // range a strict superset of every per-segment scatter range of the
                // block, restoring the invariant above.
                guard let tb = tileBoxForAABB(minX: minX - pad, minY: minY - pad,
                                              maxX: maxX + pad, maxY: maxY + pad,
                                              texW: Float(texW), texH: Float(texH),
                                              tilesX: tilesX, tilesY: tilesY,
                                              invTile: invTile) else {
                    devBoxes.append(dv)
                    devRanges.append((-1, -1, -2, -2))   // empty: off-texture, never appends
                    continue
                }
                devBoxes.append(dv)
                devRanges.append(tb)
                let loX = max(tb.minX, box.minX), hiX = min(tb.maxX, box.maxX)
                let loY = max(tb.minY, box.minY), hiY = min(tb.maxY, box.maxY)
                if loX <= hiX && loY <= hiY {
                    blockTileEstimate += (hiX - loX + 1) * (hiY - loY + 1)
                }
            }
        }

        // Usability gate. A block entry only pays for itself if a pixel rejects the block
        // and skips its segments; when the block boxes touch as many tiles as the tile list
        // has incidences, every pixel pays one box test per block AND still walks the same
        // segments — pure loss. Measured on kaos zoom 1 (long scribble strokes, so a
        // 32-segment AABB spans ~150 tiles): 1.50M block-tile entries against 1.45M
        // incidences, ~39 ms of CPU per frame to build, a 36 MB upload, and ~380M extra box
        // tests on the GPU. Requiring the table to at least halve the per-tile candidate
        // count still keeps it wherever it can prune (short strokes, large tiles), and a
        // dropped table changes no pixel — the kernels walk the tile list directly.
        //
        // `bound` is an upper bound on the entries (so declining early is always safe): no
        // block can own more entries than its box area, and none can own more than one per
        // dense tile. The second bound is what keeps sparse views from being rejected on a
        // box area that is mostly below the density gate.
        let incidences = tileCounts.reduce(0) { $0 + Int($1) }
        let denseTiles = tileCounts.reduce(0) { $0 + (Int($1) >= minEntries ? 1 : 0) }
        let bound = min(blockTileEstimate, devRanges.count * denseTiles)
        if !force && bound * 2 > incidences {
            return (header, [], 0, bound)
        }

        // Pass 2: per-tile participation counts (only dense tiles take part).
        for tb in devRanges where tb.minY < tb.maxY {
            let loX = max(tb.minX, box.minX), hiX = min(tb.maxX, box.maxX)
            let loY = max(tb.minY, box.minY), hiY = min(tb.maxY, box.maxY)
            if loX > hiX || loY > hiY { continue }
            var ly = loY
            while ly <= hiY {
                var t = (ly - box.minY) * boxW + (loX - box.minX)
                var lx = loX
                while lx <= hiX {
                    if Int(tileCounts[t]) >= minEntries { perTile[t] += 1 }
                    t += 1
                    lx += 1
                }
                ly += 1
            }
        }
        let total = perTile.reduce(0, +)
        if total > budget { return (header, [], 0, bound) }

        var start = 0
        for t in 0..<boxTiles {
            header[t * 2] = UInt32(start)
            header[t * 2 + 1] = UInt32(perTile[t])
            start += perTile[t]
        }
        var entries = [GpuBinStrokeBlock](
            repeating: GpuBinStrokeBlock(segStart: 0xFFFF_FFFF, strokeID: 0xFFFF_FFFF,
                                         minX: 0, minY: 0, maxX: 0, maxY: 0),
            count: total)
        var cursor = [Int](repeating: 0, count: boxTiles)
        var cacheIdx = 0
        for sid in visibleStrokes {
            guard sid >= 0, sid < blockCount.count, sid < blockFirst.count else { continue }
            var b = blockFirst[sid]
            let end = b + blockCount[sid]
            while b < end {
                defer { b += 1 }
                guard cacheIdx < devBoxes.count, cacheIdx < devRanges.count else { break }
                defer { cacheIdx += 1 }
                let tb = devRanges[cacheIdx]
                if tb.minY >= tb.maxY { continue }   // empty range
                let e = GpuBinStrokeBlock(
                    segStart: UInt32(max(0, Int(blockSegStart[b]))), strokeID: UInt32(sid),
                    minX: devBoxes[cacheIdx].x, minY: devBoxes[cacheIdx].y,
                    maxX: devBoxes[cacheIdx].z, maxY: devBoxes[cacheIdx].w)
                let loX = max(tb.minX, box.minX), hiX = min(tb.maxX, box.maxX)
                let loY = max(tb.minY, box.minY), hiY = min(tb.maxY, box.maxY)
                var ly = loY
                while ly <= hiY {
                    var lx = loX
                    while lx <= hiX {
                        let t = (ly - box.minY) * boxW + (lx - box.minX)
                        if Int(tileCounts[t]) >= minEntries {
                            entries[Int(header[t * 2]) + cursor[t]] = e
                            cursor[t] += 1
                        }
                        lx += 1
                    }
                    ly += 1
                }
            }
        }
        return (header, entries, total, bound)
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
