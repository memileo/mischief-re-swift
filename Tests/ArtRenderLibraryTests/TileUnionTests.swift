import Foundation
import XCTest
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
