import Foundation
import XCTest
#if os(Linux)
import Silica
#else
import CoreGraphics
#endif
@testable import ArtRenderLibrary

/// `TileUnion.boundingBox` is the whole CPU-side decision behind the live path's
/// "dispatch each stroke only over the tiles it covers" optimisation, and it is written
/// with no Metal/`TileIndex` dependency on purpose so it can be verified on Linux, where
/// the Metal kernels cannot run. The `#if os(macOS)` case additionally drives the *real*
/// binner (`MetalRenderer.buildSegmentTileIndices`) to prove the counts it produces feed
/// the same box.
final class TileUnionTests: XCTestCase {

    // MARK: - Pure helper (runs on Linux + macOS)

    func testAllZeroCountsReturnNil() {
        XCTAssertNil(TileUnion.boundingBox(counts: [UInt32](repeating: 0, count: 12), tilesPerRow: 4))
    }

    func testDegenerateInputsReturnNil() {
        XCTAssertNil(TileUnion.boundingBox(counts: [1, 0, 0, 1], tilesPerRow: 0))
        XCTAssertNil(TileUnion.boundingBox(counts: [], tilesPerRow: 4))
    }

    func testSingleNonEmptyTile() {
        // 4 columns; the only non-empty tile is (col 2, row 1) → index 1*4 + 2 = 6.
        var counts = [UInt32](repeating: 0, count: 12)
        counts[6] = 3
        let box = TileUnion.boundingBox(counts: counts, tilesPerRow: 4)
        XCTAssertEqual(box?.minX, 2)
        XCTAssertEqual(box?.maxX, 2)
        XCTAssertEqual(box?.minY, 1)
        XCTAssertEqual(box?.maxY, 1)
    }

    func testBoxSpansTheExtremes() {
        // 5 columns × 3 rows. Non-empty at the two opposite corners.
        var counts = [UInt32](repeating: 0, count: 15)
        counts[0] = 1            // (0,0)
        counts[14] = 1           // (4,2)
        let box = TileUnion.boundingBox(counts: counts, tilesPerRow: 5)
        XCTAssertEqual(box?.minX, 0)
        XCTAssertEqual(box?.maxX, 4)
        XCTAssertEqual(box?.minY, 0)
        XCTAssertEqual(box?.maxY, 2)
    }

    func testInteriorGapsStayInsideTheBox() {
        // The bounding box must cover the empty tiles *between* the ink, because the kernel
        // dispatches the whole box and relies on the per-tile count==0 early-out.
        var counts = [UInt32](repeating: 0, count: 15)
        counts[0] = 1     // (0,0)
        counts[4] = 1     // (4,0)
        counts[10] = 1    // (0,2)
        counts[14] = 1    // (4,2)
        let box = TileUnion.boundingBox(counts: counts, tilesPerRow: 5)
        XCTAssertEqual(box?.minX, 0)
        XCTAssertEqual(box?.maxX, 4)
        XCTAssertEqual(box?.minY, 0)
        XCTAssertEqual(box?.maxY, 2)
    }

    func testFullRowAndColumnClamp() {
        // Every tile non-empty → the box is the entire grid.
        let cols = 30, rows = 17      // 1920×1080 canvas at tileSize 64
        let counts = [UInt32](repeating: 1, count: cols * rows)
        let box = TileUnion.boundingBox(counts: counts, tilesPerRow: cols)
        XCTAssertEqual(box?.minX, 0)
        XCTAssertEqual(box?.minY, 0)
        XCTAssertEqual(box?.maxX, cols - 1)
        XCTAssertEqual(box?.maxY, rows - 1)
    }

    #if os(macOS)
    // MARK: - Real binner → box (macOS only: needs a MetalRenderer instance)

    /// `buildSegmentTileIndices` is pure CPU (no device use), but it lives on
    /// `MetalRenderer`, whose init needs a Device + the metallib. If neither is available
    /// we skip rather than fail — the pure-helper cases above already cover the maths.
    private func makeRendererOrSkip() throws -> MetalRenderer {
        do { return try MetalRenderer() }
        catch { throw XCTSkip("MetalRenderer unavailable in this environment: \(error)") }
    }

    func testBuildSegmentTileIndicesUnionMatchesManualRanges() throws {
        let renderer = try makeRendererOrSkip()
        let tileSize = 64
        let width = 1920, height = 1080
        let tilesPerRow = (width + tileSize - 1) / tileSize      // 30

        func seg(_ x1: Float, _ y1: Float, _ x2: Float, _ y2: Float, radius r: Float)
            -> GPUSplineSegment
        {
            GPUSplineSegment(p0: SIMD2(x1, y1), p1: SIMD2(x1, y1),
                             p2: SIMD2(x2, y2), p3: SIMD2(x2, y2),
                             radius0: r, radius1: r,
                             opacity0: 1, opacity1: 1,
                             segmentType: 0, noiseSeed: 0)
        }

        // Segment A: padded box x[92,128] y[92,118] → tiles x[1…2] y[1…1].
        // Segment B: padded box x[592,708] y[292,408] → tiles x[9…11] y[4…6].
        let (indices, _) = renderer.buildSegmentTileIndices(
            segments: [seg(100, 100, 120, 110, radius: 5),
                       seg(600, 300, 700, 400, radius: 5)],
            textureWidth: width, textureHeight: height, tileSize: tileSize)

        let box = TileUnion.boundingBox(counts: indices.map { $0.count }, tilesPerRow: tilesPerRow)
        XCTAssertEqual(box?.minX, 1)
        XCTAssertEqual(box?.minY, 1)
        XCTAssertEqual(box?.maxX, 11)
        XCTAssertEqual(box?.maxY, 6)
    }

    func testBuildSegmentTileIndicesUnionNilWhenFullyOffCanvas() throws {
        let renderer = try makeRendererOrSkip()
        let (indices, list) = renderer.buildSegmentTileIndices(
            segments: [GPUSplineSegment(p0: SIMD2(-500, -500), p1: SIMD2(-500, -500),
                                        p2: SIMD2(-400, -400), p3: SIMD2(-400, -400),
                                        radius0: 5, radius1: 5,
                                        opacity0: 1, opacity1: 1,
                                        segmentType: 0, noiseSeed: 0)],
            textureWidth: 1920, textureHeight: 1080, tileSize: 64)
        XCTAssertTrue(list.isEmpty)
        XCTAssertNil(TileUnion.boundingBox(counts: indices.map { $0.count }, tilesPerRow: 30))
    }
    #endif
}

/// `SegmentPrune.radius` is the bound the live kernels use to skip a segment per pixel;
/// it must never be smaller than the true ink extent (or a pixel would be wrongly pruned)
/// and should stay tight enough to be useful. Pure maths, so it runs on Linux too.
final class SegmentPruneTests: XCTestCase {

    private func f(_ v: Float) -> Double { Double(v) }

    func testStraightCapsuleIgnoresTangentHints() {
        // type 0 draws only p1→p2 + radius; p0/p3 are irrelevant, even for a polyline where
        // p0/p3 are extrapolated far beyond the chord.
        let r = SegmentPrune.radius(p0: SIMD2(-100, 0), p1: SIMD2(0, 0),
                                    p2: SIMD2(100, 0), p3: SIMD2(200, 0),
                                    radius0: 5, radius1: 5, segmentType: 0, isMarker: false)
        // offChord(0) + rMax(5) + margin(max(0.75, 0.375*5)=1.875) = 6.875
        XCTAssertEqual(f(r), 6.875, accuracy: 1e-4)
    }

    func testStraightCapsuleTinyRadiusUsesAbsoluteMarginFloor() {
        let r = SegmentPrune.radius(p0: SIMD2(0, 0), p1: SIMD2(0, 0),
                                    p2: SIMD2(50, 0), p3: SIMD2(50, 0),
                                    radius0: 0.5, radius1: 0.5, segmentType: 0, isMarker: false)
        // 0 + 0.5 + max(0.75, 0.1875)=0.75 → 1.25
        XCTAssertEqual(f(r), 1.25, accuracy: 1e-4)
    }

    func testSplineRadiusIncludesControlPointBulge() {
        let r = SegmentPrune.radius(p0: SIMD2(0, 50), p1: SIMD2(0, 0),
                                    p2: SIMD2(100, 0), p3: SIMD2(100, 50),
                                    radius0: 3, radius1: 3, segmentType: 1, isMarker: false)
        // offChord = max(distance p0..chord, p3..chord) = 50; reach 3; margin 1.125 → 54.125
        XCTAssertEqual(f(r), 54.125, accuracy: 1e-3)
    }

    func testMarkerRadiusUsesLargerReach() {
        let r = SegmentPrune.radius(p0: SIMD2(0, 50), p1: SIMD2(0, 0),
                                    p2: SIMD2(100, 0), p3: SIMD2(100, 50),
                                    radius0: 3, radius1: 3, segmentType: 1, isMarker: true)
        // 50 + 4*3 + 1.125 = 63.125
        XCTAssertEqual(f(r), 63.125, accuracy: 1e-3)
    }

    func testNeverPrunesPixelActuallyOnTheInk() {
        // For a straight capsule along y=0 at x∈[0,100], radius 5, the farthest ink is at
        // y=±5. The prune radius (6.875) must exceed the distance from any *in-boundary*
        // pixel to the chord, else we'd drop real coverage. Simulate the kernel's check.
        let radius = SegmentPrune.radius(p0: SIMD2(0, 0), p1: SIMD2(0, 0),
                                         p2: SIMD2(100, 0), p3: SIMD2(100, 0),
                                         radius0: 5, radius1: 5, segmentType: 0, isMarker: false)
        // A pixel sitting exactly on the outer edge of the ink (y=5) must NOT be pruned.
        XCTAssertLessThan(5.0, Double(radius))            // edge pixel kept
        // A pixel 20px away (well clear of the ink) IS pruned.
        XCTAssertGreaterThan(20.0, Double(radius))
    }
}

/// Regression: the per-pixel prune radius (`padding1`, a distance) must be rescaled with the
/// camera in `LiveRenderCache.remap`, exactly like the radii — it is baked in the segment's
/// own space and compared against canvas-space distances in the kernel. Without the rescale,
/// zooming in over-prunes (strokes clip, AA edges vanish) and zooming out under-prunes.
final class LiveRemapPruneScaleTests: XCTestCase {
    func testRemapScalesPruneRadiusAndRadii() {
        var seg = GPUSplineSegment(p0: SIMD2(0, 0), p1: SIMD2(0, 0),
                                   p2: SIMD2(100, 0), p3: SIMD2(100, 0),
                                   radius0: 5, radius1: 5,
                                   opacity0: 1, opacity1: 1, segmentType: 0, noiseSeed: 0)
        seg.padding1 = Float(10).bitPattern           // pretend prune radius 10 (document units)

        let out = LiveRenderCache.remap([seg],
                                        camera: CGAffineTransform(a: 2, b: 0, c: 0, d: 2, tx: 0, ty: 0),
                                        radiusFactor: 2.0)
        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].radius0, 10, accuracy: 1e-4)                 // 5 × 2
        XCTAssertEqual(Float(bitPattern: out[0].padding1), 20, accuracy: 1e-4) // 10 × 2
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
        XCTAssertEqual(Float(bitPattern: out[0].padding1), 12.5, accuracy: 1e-4)  // unchanged
    }
}
