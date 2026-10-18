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

    func testBinCheckDefaultsOff() {
        XCTAssertFalse(LiveConfig.binCheckEnabled(environment: [:]))
        XCTAssertTrue(LiveConfig.binCheckEnabled(environment: ["ART_LIVE_BINCHECK": "1"]))
        XCTAssertFalse(LiveConfig.binCheckEnabled(environment: ["ART_LIVE_BINCHECK": "0"]))
    }

    func testLiveTileSizeDefaultsSixteen() {
        XCTAssertEqual(LiveConfig.liveTileSize(environment: [:]), 16)
        XCTAssertEqual(LiveConfig.liveTileSize(environment: ["ART_TILE_SIZE": "32"]), 32)
        XCTAssertEqual(LiveConfig.liveTileSize(environment: ["ART_LIVE_TILE_SIZE": "32"]), 32)
        XCTAssertEqual(LiveConfig.liveTileSize(environment: ["ART_TILE_SIZE": "32",
                                                              "ART_LIVE_TILE_SIZE": "8"]), 8)
    }

    func testMergeUnitSizeDefaultsAndClamps() {
        XCTAssertEqual(LiveConfig.mergeUnitSize(environment: [:]),
                       GpuBinSpec.mergeUnitSize)
        XCTAssertEqual(GpuBinSpec.mergeUnitSize, 64)
        XCTAssertEqual(LiveConfig.mergeUnitSize(environment: ["ART_LIVE_MERGE_UNIT": "256"]), 256)
        XCTAssertEqual(LiveConfig.mergeUnitSize(environment: ["ART_LIVE_MERGE_UNIT": "16"]), 16)
        // Out-of-range or malformed values fall back to the default, never crash.
        XCTAssertEqual(LiveConfig.mergeUnitSize(environment: ["ART_LIVE_MERGE_UNIT": "0"]), 64)
        XCTAssertEqual(LiveConfig.mergeUnitSize(environment: ["ART_LIVE_MERGE_UNIT": "8192"]), 64)
        XCTAssertEqual(LiveConfig.mergeUnitSize(environment: ["ART_LIVE_MERGE_UNIT": "abc"]), 64)
    }

    func testStrokePruneDefaultsOn() {
        XCTAssertTrue(LiveConfig.strokePruneEnabled(environment: [:]))
        XCTAssertTrue(LiveConfig.strokePruneEnabled(environment: ["ART_LIVE_STROKE_PRUNE": "1"]))
        XCTAssertFalse(LiveConfig.strokePruneEnabled(environment: ["ART_LIVE_STROKE_PRUNE": "0"]))
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

    /// Swift mirror of `liveBinChunkSortV3Kernel`'s in-place heapsort
    /// (+ `liveBinSiftDown`), kept structurally identical so this test guards the
    /// algorithm the GPU runs on every chunk.
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
        // Reverse-sorted dense tile: the clustered worst case.
        var dense = Array((0 as UInt32..<5000).reversed())
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

    func testChunkTableBoundsWorkPerThread() {
        // Layout lock: the macOS side memcpys [GpuBinChunk] into the uint2 buffer the
        // chunk-sort kernel reads — same two-UInt32 layout, stride 8.
        XCTAssertEqual(MemoryLayout<GpuBinChunk>.stride, 8)
        XCTAssertEqual(MemoryLayout<GpuBinChunk>.size, 8)
        XCTAssertEqual(GpuBinSpec.sortChunkSize, 512)
        // Counts [600, 100, 0, 1, 2000]: tiles 1 and 3 need no merge, tile 0 needs
        // 2 chunks (1 pass), tile 4 needs 4 chunks (2 passes).
        let (entries, _, _) = GpuBinSpec.combine(counts: [600, 100, 0, 1, 2000])
        let (chunks, maxChunks, passes) = GpuBinSpec.chunkTable(entries: entries)
        XCTAssertEqual(chunks.count, 2 + 1 + 4)
        XCTAssertEqual(maxChunks, 4)
        XCTAssertEqual(passes, 2)
        // Chunks tile tile 0's slice [0, 600) then tile 1's [600, 700), etc.
        XCTAssertEqual(chunks[0].start, 0); XCTAssertEqual(chunks[0].len, 512)
        XCTAssertEqual(chunks[1].start, 512); XCTAssertEqual(chunks[1].len, 88)
        XCTAssertEqual(chunks[2].start, 600); XCTAssertEqual(chunks[2].len, 100)
        XCTAssertEqual(chunks[3].start, 701); XCTAssertEqual(chunks[3].len, 512)
        XCTAssertEqual(chunks[6].start, 701 + 512 * 3); XCTAssertEqual(chunks[6].len, 2000 - 512 * 3)
        for c in chunks { XCTAssertLessThanOrEqual(Int(c.len), GpuBinSpec.sortChunkSize) }
        // Nothing sortable → no chunks, no passes (sort dispatches skipped entirely).
        let (e2, _, _) = GpuBinSpec.combine(counts: [0, 1, 1, 0])
        let (ch2, mx2, p2) = GpuBinSpec.chunkTable(entries: e2)
        XCTAssertTrue(ch2.isEmpty); XCTAssertEqual(mx2, 0); XCTAssertEqual(p2, 0)
        // Exact multiple of the chunk size: no short tail, passes still ceil(log2).
        let (e3, _, _) = GpuBinSpec.combine(counts: [1024])
        let (ch3, mx3, p3) = GpuBinSpec.chunkTable(entries: e3)
        XCTAssertEqual(ch3.count, 2); XCTAssertEqual(mx3, 2); XCTAssertEqual(p3, 1)
        // Pass count is ceil(log2(maxChunks)): 3 chunks need 2 passes, 5 need 3.
        let (e4, _, _) = GpuBinSpec.combine(counts: [1536])
        XCTAssertEqual(GpuBinSpec.chunkTable(entries: e4).mergePasses, 2)
        let (e5, _, _) = GpuBinSpec.combine(counts: [2560])
        XCTAssertEqual(GpuBinSpec.chunkTable(entries: e5).mergePasses, 3)
    }

    func testMergePairsBoundWork() {
        // Layout lock: the macOS side memcpys [GpuBinMergePair] into the uint4 buffer
        // the merge kernel reads — four UInt32, stride 16.
        XCTAssertEqual(MemoryLayout<GpuBinMergePair>.stride, 16)
        XCTAssertEqual(MemoryLayout<GpuBinMergePair>.size, 16)
        // Starts: tile0 [0,600), tile1 [600,700), tile2 empty, tile3 [700,701),
        // tile4 [701,2701). Every non-empty tile gets pairs — real merges for
        // multi-chunk runs, plain copies (bLen == 0) carrying the rest across the
        // tileList/scratch ping-pong so src is never dst.
        let (entries, _, _) = GpuBinSpec.combine(counts: [600, 100, 0, 1, 2000])
        let p0 = GpuBinSpec.mergePairs(entries: entries, runSize: 512)
        XCTAssertEqual(p0.count, 5)
        XCTAssertEqual(p0[0].aStart, 0); XCTAssertEqual(p0[0].aLen, 512)
        XCTAssertEqual(p0[0].bLen, 88); XCTAssertEqual(p0[0].dst, 0)
        XCTAssertEqual(p0[1].aStart, 600); XCTAssertEqual(p0[1].aLen, 100)
        XCTAssertEqual(p0[1].bLen, 0); XCTAssertEqual(p0[1].dst, 600)
        XCTAssertEqual(p0[2].aStart, 700); XCTAssertEqual(p0[2].aLen, 1)
        XCTAssertEqual(p0[2].bLen, 0)
        XCTAssertEqual(p0[3].aStart, 701); XCTAssertEqual(p0[3].aLen, 512)
        XCTAssertEqual(p0[3].bLen, 512); XCTAssertEqual(p0[3].dst, 701)
        XCTAssertEqual(p0[4].aStart, 1725); XCTAssertEqual(p0[4].aLen, 512)
        XCTAssertEqual(p0[4].bLen, 464); XCTAssertEqual(p0[4].dst, 1725)
        for pr in p0 {
            XCTAssertLessThanOrEqual(Int(pr.aLen) + Int(pr.bLen), 2 * GpuBinSpec.sortChunkSize)
        }
        // Next pass doubles the runs; the odd tail becomes a copy pair.
        let p1 = GpuBinSpec.mergePairs(entries: entries, runSize: 1024)
        XCTAssertEqual(p1.count, 4)   // tile0/1/3 copies + tile4's one full merge
        XCTAssertEqual(p1[0].aStart, 0); XCTAssertEqual(p1[0].aLen, 600)
        XCTAssertEqual(p1[0].bLen, 0); XCTAssertEqual(p1[0].dst, 0)
        XCTAssertEqual(p1[3].aStart, 701); XCTAssertEqual(p1[3].aLen, 1024)
        XCTAssertEqual(p1[3].bLen, 976); XCTAssertEqual(p1[3].dst, 701)
        // All empty → no pairs at any run size.
        let (e2, _, _) = GpuBinSpec.combine(counts: [0, 0, 0])
        XCTAssertTrue(GpuBinSpec.mergePairs(entries: e2, runSize: 512).isEmpty)
    }

    func testMergePlanOffsetsPackAllPasses() {
        // Locks the GPU upload contract: every pass's units concatenated in one
        // buffer, offsets[p] = units of all earlier passes. The kernel binds its
        // pass at offsets[pass] — a wrong offset reads another pass's data and
        // silently mis-sorts (the per-pass rewrite hazard this replaced).
        XCTAssertEqual(MemoryLayout<GpuBinMergeUnit>.stride, 24)
        XCTAssertEqual(MemoryLayout<GpuBinMergeUnit>.size, 24)
        let (entries, _, _) = GpuBinSpec.combine(counts: [600, 100, 0, 1, 2000])
        let (_, _, passes) = GpuBinSpec.chunkTable(entries: entries)
        XCTAssertGreaterThan(passes, 0)
        let plan = GpuBinSpec.mergePlan(entries: entries, mergePasses: passes)
        XCTAssertEqual(plan.units.count, passes)
        XCTAssertEqual(plan.offsets.count, passes)
        XCTAssertEqual(plan.offsets[0], 0)
        var running = 0
        for p in 0..<passes {
            XCTAssertEqual(plan.offsets[p], running)
            XCTAssertFalse(plan.units[p].isEmpty)
            for u in plan.units[p] {
                // Every unit inside its pair, covering [dst, dst+aLen+bLen) exactly
                // once across the pair's units; each unit bounded by mergeUnitSize.
                XCTAssertLessThanOrEqual(Int(u.partLen), GpuBinSpec.mergeUnitSize)
                XCTAssertGreaterThan(Int(u.partLen), 0)
                XCTAssertLessThanOrEqual(Int(u.part) + Int(u.partLen),
                                         Int(u.aLen) + Int(u.bLen))
            }
            // Units of each pair tile its output range without gaps or overlaps.
            var byPair: [[GpuBinMergeUnit]] = []
            var cur: [GpuBinMergeUnit] = []
            var curKey = -1
            for u in plan.units[p] {
                let key = Int(u.aStart) * 1_000_000_007 + Int(u.dst)
                if key != curKey { if !cur.isEmpty { byPair.append(cur) }; cur = []; curKey = key }
                cur.append(u)
            }
            if !cur.isEmpty { byPair.append(cur) }
            for group in byPair {
                let total = Int(group[0].aLen) + Int(group[0].bLen)
                var covered = 0
                for u in group {
                    XCTAssertEqual(Int(u.part), covered)
                    covered += Int(u.partLen)
                }
                XCTAssertEqual(covered, total)
            }
            running += plan.units[p].count
        }
        XCTAssertEqual(plan.totalUnits, running)
        // A pair at or under one unit stays a single unit (common case: no extra
        // threads for small tiles); a larger pair splits into bounded units.
        let (e2, _, _) = GpuBinSpec.combine(counts: [600])
        let small = GpuBinSpec.mergePlan(entries: e2, mergePasses: 1)
        let unitLen = GpuBinSpec.mergeUnitSize
        XCTAssertEqual(small.units.count, 1)
        XCTAssertEqual(small.units[0].count, (600 + unitLen - 1) / unitLen)
        XCTAssertEqual(small.units[0][0].part, 0)
        var smallCovered = 0
        for u in small.units[0] {
            XCTAssertLessThanOrEqual(Int(u.partLen), unitLen)
            smallCovered += Int(u.partLen)
        }
        XCTAssertEqual(smallCovered, 600)
        let (e3, _, _) = GpuBinSpec.combine(counts: [40])
        let tiny = GpuBinSpec.mergePlan(entries: e3, mergePasses: 1)
        XCTAssertEqual(tiny.units[0].count, 1)
        XCTAssertEqual(tiny.units[0][0].partLen, 40)
        // Zero passes → empty plan (chunk sort only, render reads the tile list).
        let empty = GpuBinSpec.mergePlan(entries: entries, mergePasses: 0)
        XCTAssertTrue(empty.units.isEmpty)
        XCTAssertTrue(empty.offsets.isEmpty)
        XCTAssertEqual(empty.totalUnits, 0)
    }

    /// Swift mirror of `liveBinMergePassV3Kernel`'s per-unit work, kept
    /// structurally identical (co-rank binary search, then a bounded serial merge)
    /// so the end-to-end test guards the algorithm the GPU runs on every unit.
    func testStrokeGroupTableStrideLock() {
        // Layout lock: macOS memcpys [GpuBinStrokeGroup] into the uint+4-float table
        // the composite kernels read (uint + 4 × float, stride 20).
        XCTAssertEqual(MemoryLayout<GpuBinStrokeGroup>.stride, 20)
        XCTAssertEqual(MemoryLayout<GpuBinStrokeGroup>.size, 20)
    }

    func testStrokeGroupTableOrderingGatingAndBudget() {
        // Doc-ascending strokes 3, 7, 9 over a 2×2 layer box; only tile (1,1) is dense.
        let ids: [UInt32] = [3, 7, 9]
        let boxes: [SIMD4<Float>] = [
            SIMD4<Float>(-10, -10, 10, 10),
            SIMD4<Float>(0, 0, 200, 200),
            SIMD4<Float>(150, 150, 260, 260),
        ]
        let tileBoxes: [(minX: Int, minY: Int, maxX: Int, maxY: Int)] = [
            (0, 0, 0, 0),   // stroke 3: only the sparse tile (0,0) → never in the table
            (0, 0, 1, 1),   // stroke 7: covers everything, dense tile included
            (1, 1, 1, 1),   // stroke 9: dense tile only
        ]
        let counts: [UInt32] = [10, 10, 10, 128]   // only local tile 3 = (1,1) is dense
        let table = GpuBinSpec.strokeGroupTable(
            strokeIDs: ids, strokeBoxes: boxes, strokeTileBoxes: tileBoxes,
            tileCounts: counts, box: (0, 0, 1, 1))
        XCTAssertEqual(table.totalGroups, 2)
        // Sparse tiles carry no groups; the dense tile carries two in doc order.
        for t in 0..<3 {
            XCTAssertEqual(table.header[t * 2 + 1], 0, "tile \(t)")
        }
        XCTAssertEqual(table.header[3 * 2], 0)
        XCTAssertEqual(table.header[3 * 2 + 1], 2)
        XCTAssertEqual(table.entries.count, 2)
        XCTAssertEqual(table.entries[0].strokeID, 7)
        XCTAssertEqual(table.entries[1].strokeID, 9)
        // The kernel's monotone cursor against this table: known ids hit their box,
        // absent ids (gap below/between/above) resolve to "no skip".
        func lookup(id: UInt32) -> SIMD4<Float>? {
            var cursor = 0
            let start = Int(table.header[3 * 2]), count = Int(table.header[3 * 2 + 1])
            var hit: SIMD4<Float>? = nil
            while cursor < count {
                let e = table.entries[start + cursor]
                if e.strokeID < id { cursor += 1; continue }
                if e.strokeID == id { hit = SIMD4<Float>(e.minX, e.minY, e.maxX, e.maxY) }
                break
            }
            return hit
        }
        XCTAssertEqual(lookup(id: 7), boxes[1])
        XCTAssertEqual(lookup(id: 9), boxes[2])
        XCTAssertNil(lookup(id: 6))
        XCTAssertNil(lookup(id: 8))
        XCTAssertNil(lookup(id: 12))
        // Density gate: same inputs with the dense tile lowered below the threshold
        // drop the whole table (no dense tiles → empty header, direct walk).
        let sparse = GpuBinSpec.strokeGroupTable(
            strokeIDs: ids, strokeBoxes: boxes, strokeTileBoxes: tileBoxes,
            tileCounts: [10, 10, 10,
                         UInt32(GpuBinSpec.strokePruneMinTileEntries - 1)],
            box: (0, 0, 1, 1))
        XCTAssertEqual(sparse.totalGroups, 0)
        XCTAssertEqual(sparse.entries.count, 0)
        XCTAssertTrue(sparse.header.allSatisfy { $0 == 0 })
        // Budget: exceed it → table dropped, header stays zero (kernels fall back).
        let countsHuge: [UInt32] = [10, 10, 10, 128]
        let idsHuge: [UInt32] = [0, 1, 2, 3]
        let boxesHuge = [SIMD4<Float>](repeating: SIMD4<Float>(0, 0, 1, 1), count: 4)
        let tilesHuge = [(1, 1, 1, 1), (1, 1, 1, 1), (1, 1, 1, 1), (1, 1, 1, 1)] as
            [(minX: Int, minY: Int, maxX: Int, maxY: Int)]
        let dropped = GpuBinSpec.strokeGroupTable(
            strokeIDs: idsHuge, strokeBoxes: boxesHuge, strokeTileBoxes: tilesHuge,
            tileCounts: countsHuge, box: (0, 0, 1, 1), budget: 3)
        XCTAssertEqual(dropped.totalGroups, 0)
        XCTAssertTrue(dropped.header.allSatisfy { $0 == 0 })
    }

    private func coRankMergeUnit(src: [UInt32], dst: inout [UInt32], u: GpuBinMergeUnit) {
        let aStart = Int(u.aStart), aLen = Int(u.aLen), bLen = Int(u.bLen)
        let bStart = aStart + aLen
        let part = Int(u.part), partLen = Int(u.partLen)
        var lo = part > bLen ? part - bLen : 0
        var hi = part < aLen ? part : aLen
        while lo < hi {
            let ia = (lo + hi) / 2
            let ib = part - ia
            let tooSmall = ib > 0 && ia < aLen && src[aStart + ia] < src[bStart + ib - 1]
            if tooSmall { lo = ia + 1 } else { hi = ia }
        }
        var ia = lo, ib = part - lo
        var d = Int(u.dst) + part
        let end = d + partLen
        while d < end {
            let takeA = ib >= bLen || (ia < aLen && src[aStart + ia] <= src[bStart + ib])
            if takeA { dst[d] = src[aStart + ia]; ia += 1 }
            else { dst[d] = src[bStart + ib]; ib += 1 }
            d += 1
        }
    }

    func testCoRankUnitsReassembleSortedRuns() {
        // Fuzz the split logic independent of any tile layout: random sorted runs at
        // awkward sizes (empty B, odd tails, duplicates, size-1 runs), every
        // partition boundary, small unit sizes to force many splits. Each unit's
        // output slice must equal the corresponding slice of the true merge.
        var rng: UInt64 = 0x51ab3f29
        func next(_ lo: Int, _ hi: Int) -> Int {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            return lo + Int(rng % UInt64(max(hi - lo, 1)))
        }
        for _ in 0..<200 {
            let aLen = next(0, 40), bLen = next(0, 40)
            var a = (0..<aLen).map { _ in UInt32(next(0, 50)) }.sorted()
            var b = (0..<bLen).map { _ in UInt32(next(0, 50)) }.sorted()
            // Lay out as one pair: A @ 0, B @ aLen, dst @ 0.
            let src = a + b
            var expect = src
            // True merge for reference.
            var merged: [UInt32] = []
            var ia = 0, ib = 0
            while ia < aLen && ib < bLen {
                if a[ia] <= b[ib] { merged.append(a[ia]); ia += 1 }
                else { merged.append(b[ib]); ib += 1 }
            }
            merged.append(contentsOf: a[ia...]) 
            merged.append(contentsOf: b[ib...])
            let total = aLen + bLen
            guard total > 0 else { continue }
            for unitSize in [1, 2, 3, 7, 64, 1024] {
                var dst = [UInt32](repeating: .max, count: total)
                var part = 0
                while part < total {
                    let partLen = min(unitSize, total - part)
                    let u = GpuBinMergeUnit(aStart: 0, aLen: UInt32(aLen),
                                            bLen: UInt32(bLen), dst: 0,
                                            part: UInt32(part), partLen: UInt32(partLen))
                    coRankMergeUnit(src: src, dst: &dst, u: u)
                    part += partLen
                }
                XCTAssertEqual(dst, merged,
                               "aLen \(aLen) bLen \(bLen) unit \(unitSize)")
            }
        }
    }

    func testChunkSortMergeMatchesSorted() {
        // Locks the GPU chunked-sort contract end to end, using the REAL specs: chunk
        // heapsort + per-pass pair tables with strict buffer alternation (render
        // reads whichever buffer the ping-pong leaves full) must reproduce the exact
        // ascending tile lists — including the dense single-tile worst case that
        // stalled every per-thread sort tried so far (~2600 entries in one tile).
        func run(tileCounts: [Int], order: [UInt32]) -> Bool {
            let counts = tileCounts.map { UInt32($0) }
            let (entries, _, total) = GpuBinSpec.combine(counts: counts)
            guard total == order.count else { return false }
            // Unordered scatter input (reversed per tile — atomic scatter is arbitrary).
            var a = [UInt32](repeating: 0, count: total)
            var cursor = 0
            for (t, n) in tileCounts.enumerated() {
                let rev = Array(order[cursor..<cursor + n].reversed())
                a.replaceSubrange(Int(entries[t].start)..<Int(entries[t].start) + n, with: rev)
                cursor += n
            }
            // Chunk heapsort in place (mirror of liveBinChunkSortV3Kernel).
            let (chunks, _, passes) = GpuBinSpec.chunkTable(entries: entries)
            for c in chunks {
                var slice = Array(a[Int(c.start)..<Int(c.start) + Int(c.len)])
                heapSort(&slice)
                a.replaceSubrange(Int(c.start)..<Int(c.start) + Int(c.len), with: slice)
            }
            // Merge passes over the REAL plan (mirror of liveBinMergePassV3Kernel's
            // src != dst contract): each pass reads one buffer and writes the other,
            // then they swap. Uses mergePlan — the exact function the renderer
            // uploads — so this test guards the shipped tables, not a re-derivation.
            // Each unit co-rank-merges only its own partition.
            var cur = a, nxt = [UInt32](repeating: 0, count: total)
            let plan = GpuBinSpec.mergePlan(entries: entries, mergePasses: passes)
            for uns in plan.units {
                for u in uns {
                    coRankMergeUnit(src: cur, dst: &nxt, u: u)
                }
                swap(&cur, &nxt)
            }
            // Render reads whichever buffer the ping-pong leaves full.
            let final = cur
            // Every tile ascending and equal to the stably scattered reference.
            cursor = 0
            for (t, n) in tileCounts.enumerated() {
                let ref = Array(order[cursor..<cursor + n]).sorted()
                let got = Array(final[Int(entries[t].start)..<Int(entries[t].start) + n])
                if got != ref { return false }
                cursor += n
            }
            return true
        }
        // Dense single tile (zoomed-out worst case), multi-tile mixed, sparse.
        XCTAssertTrue(run(tileCounts: [5000], order: Array(0 as UInt32..<5000)))
        var rng: UInt64 = 0x9e3779b9
        var seen = Set<UInt32>(); var uniq: [UInt32] = []
        while uniq.count < 5000 {
            rng = rng &* 6364136223846793005 &+ 1442695040888963407
            let v = UInt32(truncatingIfNeeded: rng >> 33)
            if seen.insert(v).inserted { uniq.append(v) }
        }
        XCTAssertTrue(run(tileCounts: [2600, 1300, 700, 300, 100], order: uniq))
        XCTAssertTrue(run(tileCounts: [1, 0, 2, 511, 513], order: Array(0 as UInt32..<1027)))
        XCTAssertTrue(run(tileCounts: [0, 0, 0], order: []))
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
