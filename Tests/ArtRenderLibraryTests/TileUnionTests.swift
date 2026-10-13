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
