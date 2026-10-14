import Foundation
import XCTest
#if os(Linux)
import Silica
#else
import CoreGraphics
#endif
@testable import ArtRenderLibrary

/// `SegmentBinner` is the (now shared) core of tile binning: pure integer logic, so it runs
/// on Linux. The box-local output is what the live kernel indexes; the whole-canvas call is
/// what the non-live path uses (box-local == absolute when origin is (0,0)).
final class SegmentBinnerTests: XCTestCase {

    func testUnionBoxNilWhenAllInvalid() {
        XCTAssertNil(SegmentBinner.unionBox([.empty, .empty]))
    }

    func testUnionBoxSpansValidRangesOnly() {
        let a = SegTileRange(minTX: 2, minTY: 4, maxTX: 3, maxTY: 5)   // valid
        let box = SegmentBinner.unionBox([.empty, a])
        XCTAssertEqual(box?.minX, 2)
        XCTAssertEqual(box?.minY, 4)
        XCTAssertEqual(box?.maxX, 3)
        XCTAssertEqual(box?.maxY, 5)
    }

    func testBinCountsAndScatter() {
        // a: tiles (0,0)-(1,1); b: tile (2,2). Union box (0,0)-(2,2) → 3×3.
        let a = SegTileRange(minTX: 0, minTY: 0, maxTX: 1, maxTY: 1)
        let b = SegTileRange(minTX: 2, minTY: 2, maxTX: 2, maxTY: 2)
        let box = (minX: Int32(0), minY: Int32(0), maxX: Int32(2), maxY: Int32(2))
        let r = SegmentBinner.bin([a, b], box: box)
        XCTAssertEqual(r.boxWidth, 3)
        XCTAssertEqual(r.boxHeight, 3)
        // counts, row-major y*3+x: a fills (0,0),(1,0),(0,1),(1,1); b fills (2,2).
        XCTAssertEqual(r.counts, [1, 1, 0, 1, 1, 0, 0, 0, 1])
        XCTAssertEqual(r.starts,  [0, 1, 2, 2, 3, 4, 4, 4, 4])
        XCTAssertEqual(r.tileList, [0, 0, 0, 0, 1])   // four a's, then the one b
    }

    func testBinIsBoxLocal() {
        // Everything shifted to tiles (2..3, 4..5): the box origin must be subtracted so the
        // result is indexed relative to the box, not the canvas.
        let a = SegTileRange(minTX: 2, minTY: 4, maxTX: 3, maxTY: 5)
        let union = SegmentBinner.unionBox([a])!
        XCTAssertEqual(union.minX, 2); XCTAssertEqual(union.minY, 4)
        let r = SegmentBinner.bin([a], box: union)
        XCTAssertEqual(r.minX, 2); XCTAssertEqual(r.minY, 4)
        XCTAssertEqual(r.boxWidth, 2); XCTAssertEqual(r.boxHeight, 2)
        XCTAssertEqual(r.counts, [1, 1, 1, 1])          // all four box tiles hold segment a
        XCTAssertEqual(Array(r.tileList), [0, 0, 0, 0])
    }

    func testWholeCanvasBoxIsAbsolute() {
        // With origin (0,0) and boxWidth == tilesPerRow, box-local indexing must equal the
        // old absolute indexing (this is what keeps the non-live path byte-identical).
        let a = SegTileRange(minTX: 1, minTY: 1, maxTX: 2, maxTY: 1)
        let box = (minX: Int32(0), minY: Int32(0), maxX: Int32(4), maxY: Int32(3))  // 5×4 canvas
        let r = SegmentBinner.bin([a], box: box)
        XCTAssertEqual(r.boxWidth, 5)
        // absolute indices (1,1)=6 and (2,1)=7 in row-major over 5 columns.
        XCTAssertEqual(r.counts[1 * 5 + 1], 1)
        XCTAssertEqual(r.counts[1 * 5 + 2], 1)
        XCTAssertEqual(r.starts[1 * 5 + 1], 0)
        XCTAssertEqual(r.starts[1 * 5 + 2], 1)
        XCTAssertEqual(Array(r.tileList), [0, 0])
    }
}

/// `SegmentPrune.radius` must never be smaller than the true ink extent (or a pixel would be
/// wrongly pruned) and stay tight. Pure maths, runs on Linux.
final class SegmentPruneTests: XCTestCase {
    fileprivate func f(_ v: Float) -> Double { Double(v) }

    func testStraightCapsuleIgnoresTangentHints() {
        let r = SegmentPrune.radius(p0: SIMD2(-100, 0), p1: SIMD2(0, 0),
                                    p2: SIMD2(100, 0), p3: SIMD2(200, 0),
                                    radius0: 5, radius1: 5, segmentType: 0, isMarker: false)
        XCTAssertEqual(f(r), 6.875, accuracy: 1e-4)
    }

    func testStraightCapsuleTinyRadiusUsesAbsoluteMarginFloor() {
        let r = SegmentPrune.radius(p0: SIMD2(0, 0), p1: SIMD2(0, 0),
                                    p2: SIMD2(50, 0), p3: SIMD2(50, 0),
                                    radius0: 0.5, radius1: 0.5, segmentType: 0, isMarker: false)
        XCTAssertEqual(f(r), 1.25, accuracy: 1e-4)
    }

    func testSplineRadiusIncludesControlPointBulge() {
        let r = SegmentPrune.radius(p0: SIMD2(0, 50), p1: SIMD2(0, 0),
                                    p2: SIMD2(100, 0), p3: SIMD2(100, 50),
                                    radius0: 3, radius1: 3, segmentType: 1, isMarker: false)
        XCTAssertEqual(f(r), 54.125, accuracy: 1e-3)
    }

    func testMarkerRadiusUsesLargerReach() {
        let r = SegmentPrune.radius(p0: SIMD2(0, 50), p1: SIMD2(0, 0),
                                    p2: SIMD2(100, 0), p3: SIMD2(100, 50),
                                    radius0: 3, radius1: 3, segmentType: 1, isMarker: true)
        XCTAssertEqual(f(r), 63.125, accuracy: 1e-3)
    }

    func testNeverPrunesPixelActuallyOnTheInk() {
        let radius = SegmentPrune.radius(p0: SIMD2(0, 0), p1: SIMD2(0, 0),
                                         p2: SIMD2(100, 0), p3: SIMD2(100, 0),
                                         radius0: 5, radius1: 5, segmentType: 0, isMarker: false)
        XCTAssertLessThan(5.0, Double(radius))            // on-ink edge pixel kept
        XCTAssertGreaterThan(20.0, Double(radius))        // far pixel pruned
    }

    /// Regression for the ellipses marker bug: polyline strokes emit straight (type-0)
    /// segments, and their prune radius must use the marker reach (4·r), not the plain
    /// capsule reach. `flattenPolyline` used to hardcode `isMarker: false`, so every
    /// straight marker segment was over-pruned → clipped thickness + aliased edges.
    func testPolylineMarkerSegmentsCarryMarkerPruneRadius() {
        func build(isMarker: Bool) -> [GPUSplineSegment] {
            var segs: [GPUSplineSegment] = []
            let span = CRPointSpan(p0: CGPoint(x: 0, y: 0), p1: CGPoint(x: 0, y: 0),
                                   p2: CGPoint(x: 100, y: 0), p3: CGPoint(x: 100, y: 0))
            let rSpan = CRScalarSpan(s0: 5, s1: 5, s2: 5, s3: 5)
            let oSpan = CRScalarSpan(s0: 1, s1: 1, s2: 1, s3: 1)
            flattenPolyline(span: span, rSpan: rSpan, oSpan: oSpan, seed: 0,
                            into: &segs, isMarker: isMarker)
            return segs
        }
        let plain = build(isMarker: false)
        let marker = build(isMarker: true)
        XCTAssertFalse(plain.isEmpty)
        XCTAssertEqual(plain.count, marker.count)
        for s in plain {
            XCTAssertEqual(s.segmentType, 0)
            XCTAssertEqual(Double(Float(bitPattern: s.padding1)), 6.875, accuracy: 1e-4)
        }
        for s in marker {
            XCTAssertEqual(s.segmentType, 0)
            // 4·5 + max(0.75, 0.375·5) = 21.875 — the chisel reach, not 6.875.
            XCTAssertEqual(Double(Float(bitPattern: s.padding1)), 21.875, accuracy: 1e-4)
        }
    }
}

/// Regression: the per-pixel prune radius (`padding1`, a distance) must be rescaled with the
/// camera in `LiveRenderCache.remap`, exactly like the radii.
final class LiveRemapPruneScaleTests: XCTestCase {
    func testRemapScalesPruneRadiusAndRadii() {
        var seg = GPUSplineSegment(p0: SIMD2(0, 0), p1: SIMD2(0, 0),
                                   p2: SIMD2(100, 0), p3: SIMD2(100, 0),
                                   radius0: 5, radius1: 5,
                                   opacity0: 1, opacity1: 1, segmentType: 0, noiseSeed: 0)
        seg.padding1 = Float(10).bitPattern
        let out = LiveRenderCache.remap([seg],
                                        camera: CGAffineTransform(a: 2, b: 0, c: 0, d: 2, tx: 0, ty: 0),
                                        radiusFactor: 2.0)
        XCTAssertEqual(out[0].radius0, 10, accuracy: 1e-4)
        XCTAssertEqual(Float(bitPattern: out[0].padding1), 20, accuracy: 1e-4)
    }

    func testRemapLeavesPruneRadiusAtUnitScale() {
        var seg = GPUSplineSegment(p0: SIMD2(0, 0), p1: SIMD2(0, 0),
                                   p2: SIMD2(50, 0), p3: SIMD2(50, 0),
                                   radius0: 3, radius1: 3,
                                   opacity0: 1, opacity1: 1, segmentType: 1, noiseSeed: 0)
        seg.padding1 = Float(12.5).bitPattern
        let out = LiveRenderCache.remap([seg],
                                        camera: CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 7, ty: 9),
                                        radiusFactor: 1.0)
        XCTAssertEqual(Float(bitPattern: out[0].padding1), 12.5, accuracy: 1e-4)
    }
}

/// Marker binning padding must contain the chisel reach (4·r), or tiles get dropped and
/// markers clip. Pure maths, runs on Linux.
final class SegmentPaddingTests: XCTestCase {
    func testPlainPaddingCoversRadiusPlusAATail() {
        XCTAssertEqual(Double(SegmentPadding.pad(radiusMax: 5, isMarker: false)), 8.0, accuracy: 1e-6)
        XCTAssertEqual(Double(SegmentPadding.pad(radiusMax: 0, isMarker: false)), 1.0, accuracy: 1e-6)
    }

    func testMarkerPaddingCoversFourRadiiPlusMargin() {
        // r=20: old (1+2√2)·r+1 = 77.6 < needed 4·r+1.44 ≈ 81.4 → clipped. New: 82.
        XCTAssertEqual(Double(SegmentPadding.pad(radiusMax: 20, isMarker: true)), 82.0, accuracy: 1e-6)
        XCTAssertGreaterThanOrEqual(Double(SegmentPadding.pad(radiusMax: 20, isMarker: true)),
                                    Double(4 * 20 + 1.44))
        // Small markers: AA tail covered too.
        XCTAssertGreaterThanOrEqual(Double(SegmentPadding.pad(radiusMax: 1, isMarker: true)),
                                    Double(4 * 1 + 0.44))
    }
}

/// Live defaults: per-tile on unless explicitly disabled, live tile size 16 unless
/// overridden. Pure environment functions, runs on Linux.
final class LiveConfigTests: XCTestCase {
    func testPerTileDefaultsOn() {
        XCTAssertTrue(LiveConfig.perTileEnabled(environment: [:]))
        XCTAssertTrue(LiveConfig.perTileEnabled(environment: ["ART_LIVE_PERTILE": "1"]))
        XCTAssertFalse(LiveConfig.perTileEnabled(environment: ["ART_LIVE_PERTILE": "0"]))
    }

    func testGpuBinDefaultsOn() {
        XCTAssertTrue(LiveConfig.gpuBinEnabled(environment: [:]))
        XCTAssertTrue(LiveConfig.gpuBinEnabled(environment: ["ART_LIVE_GPUBIN": "1"]))
        XCTAssertFalse(LiveConfig.gpuBinEnabled(environment: ["ART_LIVE_GPUBIN": "0"]))
    }

    func testBinStageTimingDefaultsOff() {
        XCTAssertFalse(LiveConfig.binStageTimingEnabled(environment: [:]))
        XCTAssertTrue(LiveConfig.binStageTimingEnabled(environment: ["ART_LIVE_BINTIME": "1"]))
        XCTAssertFalse(LiveConfig.binStageTimingEnabled(environment: ["ART_LIVE_BINTIME": "0"]))
    }

    func testGatherBudgetDefaultsAndParses() {
        XCTAssertEqual(LiveConfig.gatherBudget(environment: [:]), 256_000_000)
        XCTAssertEqual(LiveConfig.gatherBudget(environment: ["ART_LIVE_GATHER": "0"]), 0)
        XCTAssertEqual(LiveConfig.gatherBudget(environment: ["ART_LIVE_GATHER": "1000"]), 1000)
        // Garbage falls back to the default rather than disabling a path silently.
        XCTAssertEqual(LiveConfig.gatherBudget(environment: ["ART_LIVE_GATHER": "nope"]), 256_000_000)
    }

    func testLiveTileSizeDefaultsSixteen() {
        XCTAssertEqual(LiveConfig.liveTileSize(environment: [:]), 16)
        XCTAssertEqual(LiveConfig.liveTileSize(environment: ["ART_TILE_SIZE": "32"]), 32)
        XCTAssertEqual(LiveConfig.liveTileSize(environment: ["ART_LIVE_TILE_SIZE": "32"]), 32)
        XCTAssertEqual(LiveConfig.liveTileSize(environment: ["ART_TILE_SIZE": "32",
                                                              "ART_LIVE_TILE_SIZE": "8"]), 8)
    }
}

/// GPU binning spec: grid sizing, conservative layer-box math, count prefixing.
/// Pure integer/float logic, runs on Linux. The Metal kernels mirror this exactly.
final class GpuBinSpecTests: XCTestCase {
    func testTileGridRoundsUp() {
        XCTAssertEqual(GpuBinSpec.tileGrid(viewportWidth: 1920, viewportHeight: 1080, tileSize: 16).tilesX, 120)
        XCTAssertEqual(GpuBinSpec.tileGrid(viewportWidth: 1920, viewportHeight: 1080, tileSize: 16).tilesY, 68)
        XCTAssertEqual(GpuBinSpec.tileGrid(viewportWidth: 64, viewportHeight: 64, tileSize: 16).tilesX, 4)
    }

    func testTileBoxForAABBCoversAndClamps() {
        // AABB [10,50]² at 16px tiles → tiles 0..4 (floor/ceil), no clamping needed.
        let box = GpuBinSpec.tileBoxForAABB(minX: 10, minY: 10, maxX: 50, maxY: 50,
                                            texW: 1920, texH: 1080,
                                            tilesX: 120, tilesY: 68, invTile: 1.0 / 16.0)!
        XCTAssertEqual(box.minX, 0); XCTAssertEqual(box.maxX, 4)
        XCTAssertEqual(box.minY, 0); XCTAssertEqual(box.maxY, 4)
        // Off-canvas → nil (same strict inequalities as the per-segment cull).
        XCTAssertNil(GpuBinSpec.tileBoxForAABB(minX: -50, minY: 10, maxX: -1, maxY: 50,
                                               texW: 1920, texH: 1080,
                                               tilesX: 120, tilesY: 68, invTile: 1.0 / 16.0))
        // Partially off-canvas clamps to the grid instead of going negative/past the edge.
        let clamped = GpuBinSpec.tileBoxForAABB(minX: -30, minY: 1000, maxX: 2000, maxY: 2000,
                                                texW: 1920, texH: 1080,
                                                tilesX: 120, tilesY: 68, invTile: 1.0 / 16.0)!
        XCTAssertEqual(clamped.minX, 0); XCTAssertEqual(clamped.maxX, 119)
        XCTAssertEqual(clamped.minY, 62); XCTAssertEqual(clamped.maxY, 67)
    }

    func testTileBoxIsSupersetOfTruncatedSegmentRange() {
        // The per-segment path converts with truncation-toward-zero; the layer box uses
        // floor/ceil, so it must contain the truncated range even for negative coords
        // (where truncation shrinks toward zero and would otherwise drop a tile).
        let inv: Float = 1.0 / 16.0
        let segMinX: Float = -20, segMaxX: Float = -1
        let truncA = max(0, Int(segMinX * inv)), truncB = min(119, Int(segMaxX * inv))
        let box = GpuBinSpec.tileBoxForAABB(minX: -25, minY: 0, maxX: 5, maxY: 16,
                                            texW: 1920, texH: 1080,
                                            tilesX: 120, tilesY: 68, invTile: inv)!
        XCTAssertLessThanOrEqual(box.minX, truncA)
        XCTAssertGreaterThanOrEqual(box.maxX, truncB)
    }

    func testUnionTileBoxGrows() {
        let u = GpuBinSpec.unionTileBox(nil, with: (2, 4, 3, 5))
        XCTAssertEqual(u.minX, 2); XCTAssertEqual(u.maxY, 5)
        let u2 = GpuBinSpec.unionTileBox(u, with: (0, 0, 1, 1))
        XCTAssertEqual(u2.minX, 0); XCTAssertEqual(u2.maxX, 3)
        XCTAssertEqual(u2.minY, 0); XCTAssertEqual(u2.maxY, 5)
    }

    func testCombinePrefixSums() {
        let (entries, starts, total) = GpuBinSpec.combine(counts: [1, 0, 3, 2])
        XCTAssertEqual(starts, [0, 1, 1, 4])
        XCTAssertEqual(entries.map(\.start), [0, 1, 1, 4])
        XCTAssertEqual(entries.map(\.count), [1, 0, 3, 2])
        XCTAssertEqual(total, 6)
        // Empty + all-zero layers stay well-formed (zero-size tile list, no traps).
        let (e2, s2, t2) = GpuBinSpec.combine(counts: [])
        XCTAssertTrue(e2.isEmpty); XCTAssertTrue(s2.isEmpty); XCTAssertEqual(t2, 0)
        let (_, _, t3) = GpuBinSpec.combine(counts: [UInt32](repeating: 0, count: 100))
        XCTAssertEqual(t3, 0)
    }

    func testTileEntryMatchesTileIndexLayout() {
        // The macOS side memcpys [GpuBinTileEntry] into the TileIndex buffer the render
        // kernels read — same two-UInt32 layout, stride 8.
        XCTAssertEqual(MemoryLayout<GpuBinTileEntry>.stride, 8)
        XCTAssertEqual(MemoryLayout<GpuBinTileEntry>.size, 8)
    }

    /// Swift mirror of `liveBinSortTilesKernel`'s heapsort (+ `liveBinSiftDown`), kept
    /// structurally identical so this test guards the algorithm the GPU runs. The kernel
    /// must emit ascending document order for any tile density — clustered artwork packs
    /// thousands of entries per tile, where the old insertion sort went quadratic.
    private func heapSort(_ list: inout [UInt32]) {
        func siftDown(_ list: inout [UInt32], _ root: Int, _ v: UInt32, _ heapEnd: Int) {
            var root = root
            while true {
                let left = root * 2 + 1
                if left >= heapEnd { break }
                let right = left + 1
                let child = (right < heapEnd && list[right] > list[left]) ? right : left
                if list[child] <= v { break }
                list[root] = list[child]
                root = child
            }
            list[root] = v
        }
        let n = list.count
        guard n >= 2 else { return }
        var i = n / 2
        while i > 0 {
            i -= 1
            siftDown(&list, i, list[i], n)
        }
        var end = n
        while end > 1 {
            end -= 1
            let maxV = list[0]
            siftDown(&list, 0, list[end], end)
            list[end] = maxV
        }
    }

    func testHeapSortOrdersAllDensities() {
        // Reverse-sorted dense tile: the clustered worst case (insertion sort O(n²)).
        var denseArr = (0 as UInt32..<5000).reversed()
        var dense = Array(denseArr)
        heapSort(&dense)
        XCTAssertEqual(dense, Array(0 as UInt32..<5000))
        // Deterministic pseudo-random order, plus edge sizes.
        var rng: UInt64 = 0x12345679
        var random = (0..<3000).map { _ in
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return UInt32(truncatingIfNeeded: rng >> 33)
        }
        let expected = random.sorted()
        heapSort(&random)
        XCTAssertEqual(random, expected)
        var empty: [UInt32] = []
        heapSort(&empty)
        XCTAssertTrue(empty.isEmpty)
        var single: [UInt32] = [42]
        heapSort(&single)
        XCTAssertEqual(single, [42])
    }

    func testScatterProtocolStaysInBounds() {
        // Locks the CPU↔GPU scatter contract that `liveBinScatterKernel` implements:
        // heads are bump counters ZEROED before dispatch, slot = starts[t] + bump.
        // Simulates the scatter sequentially (order irrelevant — every slot must be
        // unique and within the tile list). The Oct-2026 double-base bug seeded heads
        // with starts, writing starts[t]+starts[t]+k past the allocation.
        let counts: [UInt32] = [1, 0, 3, 2, 5, 0, 1]
        let (_, starts, total) = GpuBinSpec.combine(counts: counts)
        var heads = [UInt32](repeating: 0, count: counts.count)   // zeroed, as shipped
        var maxSlot = -1
        var slots = Set<Int>()
        for t in 0..<counts.count {
            for _ in 0..<counts[t] {
                let pos = Int(heads[t]); heads[t] += 1
                let slot = Int(starts[t]) + pos
                XCTAssertLessThan(slot, total, "tile \(t) scatters past the tile list")
                slots.insert(slot)
                maxSlot = max(maxSlot, slot)
            }
        }
        XCTAssertEqual(slots.count, total, "every incidence owns a unique slot")
        if total > 0 { XCTAssertEqual(maxSlot, total - 1) }
    }

    func testUseGatherSelectsClusteredPath() {
        let budget = LiveConfig.gatherBudget(environment: [:])
        // complex.art zoomed-out layer: 12 tiles × 31887 segs — gather territory.
        XCTAssertTrue(GpuBinSpec.useGather(boxTiles: 12, segCount: 31887, budget: budget))
        // complex.art zoom-1 layer: ~2000 tiles × 31887 segs ≈ 64M — gather.
        XCTAssertTrue(GpuBinSpec.useGather(boxTiles: 2000, segCount: 31887, budget: budget))
        // kaos.art: 7800 tiles × 321611 segs ≈ 2.5B — scatter (would be seconds).
        XCTAssertFalse(GpuBinSpec.useGather(boxTiles: 7800, segCount: 321611, budget: budget))
        // Boundary is inclusive; ART_LIVE_GATHER=0 forces scatter everywhere.
        XCTAssertTrue(GpuBinSpec.useGather(boxTiles: 4, segCount: 25, budget: 100))
        XCTAssertFalse(GpuBinSpec.useGather(boxTiles: 4, segCount: 26, budget: 100))
        XCTAssertFalse(GpuBinSpec.useGather(boxTiles: 7800, segCount: 321611,
                                            budget: LiveConfig.gatherBudget(
                                                environment: ["ART_LIVE_GATHER": "0"])))
        // Int64 product: kaos-scale must not overflow (Int32 would go negative and
        // wrongly select gather — the catastrophic direction).
        XCTAssertGreaterThan(Int64(7800) * Int64(321611), Int64(Int32.max))
    }

    func testGatherMatchesScatterLists() {
        // Locks the gather-path contract (`liveBinGatherCountKernel` +
        // `liveBinGatherFillKernel`): walking segments in order and testing range
        // membership must reproduce the exact ascending tile lists a stable
        // (CPU-style) scatter produces — including the empty-sentinel skip.
        // Ranges use absolute tile coords; (1,0,0,0) is the invalid sentinel.
        let ranges: [(Int, Int, Int, Int)] = [
            (0, 0, 2, 1), (1, 0, 0, 0), (1, 1, 3, 2), (0, 0, 0, 0),
            (2, 0, 2, 2), (1, 0, 0, 0), (0, 2, 3, 2),
        ]
        let boxW = 4, boxH = 3, boxTiles = boxW * boxH
        func covers(_ r: (Int, Int, Int, Int), _ tx: Int, _ ty: Int) -> Bool {
            r.0 <= tx && tx <= r.2 && r.1 <= ty && ty <= r.3
        }
        // Reference: stable scatter in segment order, then per-tile ascending.
        var refLists = [[Int]](repeating: [], count: boxTiles)
        for gid in 0..<ranges.count {
            let r = ranges[gid]
            guard r.0 <= r.2 && r.1 <= r.3 else { continue }   // sentinel skip
            for ty in r.1...r.3 {
                for tx in r.0...r.2 {
                    refLists[ty * boxW + tx].append(gid)
                }
            }
        }
        // Gather simulation: count pass, prefix (real combine), fill pass.
        var counts = [UInt32](repeating: 0, count: boxTiles)
        for t in 0..<boxTiles {
            let tx = t % boxW, ty = t / boxW
            var n: UInt32 = 0
            for gid in 0..<ranges.count {
                if covers(ranges[gid], tx, ty) { n += 1 }
            }
            counts[t] = n
        }
        let (entries, _, total) = GpuBinSpec.combine(counts: counts)
        var tileList = [Int](repeating: -1, count: total)
        for t in 0..<boxTiles {
            let tx = t % boxW, ty = t / boxW
            var dst = Int(entries[t].start)
            let end = dst + Int(entries[t].count)
            for gid in 0..<ranges.count where dst < end {
                if covers(ranges[gid], tx, ty) {
                    tileList[dst] = gid
                    dst += 1
                }
            }
            XCTAssertEqual(dst, end, "tile \(t) fill must exactly match its count")
        }
        // Sentinel segments (gid 1 and 5) appear nowhere; every tile ascending.
        XCTAssertFalse(tileList.contains(1))
        XCTAssertFalse(tileList.contains(5))
        for t in 0..<boxTiles {
            let slice = Array(tileList[Int(entries[t].start)..<Int(entries[t].start) + Int(entries[t].count)])
            XCTAssertEqual(slice, slice.sorted(), "tile \(t) must be ascending by construction")
            XCTAssertEqual(slice, refLists[t], "tile \(t) must match the stable scatter")
        }
    }
}
/// Per-tile eligibility: cuts and markers force per-stroke; noise is allowed (handled by
/// the noise-capable per-tile kernel). Pure, runs on Linux.
final class LivePerTileEligibilityTests: XCTestCase {
    private func stroke(noise: Bool = false, marker: Bool = false) -> LiveDeviceOp {
        let seg = GPUSplineSegment(p0: SIMD2(0, 0), p1: SIMD2(0, 0),
                                   p2: SIMD2(10, 0), p3: SIMD2(10, 0),
                                   radius0: 2, radius1: 2,
                                   opacity0: 1, opacity1: 1,
                                   segmentType: 0, noiseSeed: noise ? 7 : 0)
        return .stroke(segments: [seg], color: SIMD4<Float>(0, 0, 0, 1),
                       isEraser: false, isMarker: marker)
    }

    func testCleanAndNoisyLayersAreEligible() {
        XCTAssertTrue(LivePerTileEligibility.isEligible([stroke()]))
        XCTAssertTrue(LivePerTileEligibility.isEligible([stroke(noise: true)]))
        XCTAssertTrue(LivePerTileEligibility.isEligible([stroke(), stroke(noise: true)]))
    }

    func testCutAndMarkerForcePerStroke() {
        let cut = LiveDeviceOp.cut(meta: CutMeta(inverseAffine: .identity,
                                                 rect: [0, 0, 10, 10]))
        XCTAssertFalse(LivePerTileEligibility.isEligible([stroke(), cut]))
        XCTAssertFalse(LivePerTileEligibility.isEligible([stroke(marker: true)]))
    }

    func testStrokeFlagsCarryNoiseBit() {
        XCTAssertEqual(LivePerTileEligibility.strokeFlags(isEraser: false, hasNoise: false), 0)
        XCTAssertEqual(LivePerTileEligibility.strokeFlags(isEraser: true, hasNoise: false), 1)
        XCTAssertEqual(LivePerTileEligibility.strokeFlags(isEraser: false, hasNoise: true), 2)
        XCTAssertEqual(LivePerTileEligibility.strokeFlags(isEraser: true, hasNoise: true), 3)
    }
}

/// macOS-only: drive the *real* boxed binner through a `MetalRenderer` and confirm the box
/// and incidence count match hand-computed tile ranges. (Skipped when no device is around.)
#if os(macOS)
extension SegmentBinnerTests {
    private func makeRendererOrSkip() throws -> MetalRenderer {
        do { return try MetalRenderer() }
        catch { throw XCTSkip("MetalRenderer unavailable in this environment: \(error)") }
    }

    func testBoxedBinnerMatchesManualTileRanges() throws {
        let renderer = try makeRendererOrSkip()
        func seg(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float, radius r: Float)
            -> GPUSplineSegment
        {
            GPUSplineSegment(p0: SIMD2(x1, y1), p1: SIMD2(x1, y1),
                             p2: SIMD2(x2, y2), p3: SIMD2(x2, y2),
                             radius0: r, radius1: r, opacity0: 1, opacity1: 1,
                             segmentType: 0, noiseSeed: 0)
        }
        // segA: x[92,128] y[92,118] → tiles x[1..2] y[1..1]; segB: x[592,708] y[292,408] →
        // tiles x[9..11] y[4..6]. Union (1,1)-(11,6).
        let result = renderer.buildSegmentTileIndicesBoxed(
            segments: [seg(100, 100, 120, 110, radius: 5), seg(600, 300, 700, 400, radius: 5)],
            textureWidth: 1920, textureHeight: 1080, tileSize: 64)
        XCTAssertEqual(result.minTileX, 1)
        XCTAssertEqual(result.minTileY, 1)
        XCTAssertEqual(result.boxWidth, 11)     // 11 - 1 + 1
        XCTAssertEqual(result.boxHeight, 6)     // 6 - 1 + 1
        // segA touches 2 tiles, segB touches 9 → 11 (segment, tile) incidences.
        XCTAssertEqual(result.tileList.count, 11)
        XCTAssertEqual(result.tileIndices.count, 11 * 6)
    }
}
#endif
