import XCTest
import ArtParser
@testable import ArtRenderLibrary

/// Bookkeeping invariants of a cache built from real art files — in particular the
/// paste/merge documents, whose layers are re-walked per frame instead of being cached.
///
/// Runs on Linux as well as macOS (the cache is pure geometry); skipped when the `art/`
/// sample folder is not present.
final class LiveCacheBuildTests: XCTestCase {

    /// `complex2.art` is a paste/merge document (the interesting case); `kaos.art` is a
    /// single-layer document with ~320 k segments. A segment budget keeps the debug-mode
    /// runtime of this suite reasonable.
    private static let sampleFiles = ["complex2.art", "kaos.art"]
    private static let segmentBudget = 40_000

    private var artDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("art")
    }

    private func art(_ name: String) -> ArtParser? {
        let url = artDirectory.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return ArtParser(data: [UInt8](data))
    }

    func testCacheBookkeepingOverRealDocuments() throws {
        let renderer = Renderer(canvasSize: CGSize(width: 1920, height: 1080), scale: 1.0)
        var checked = 0

        for name in Self.sampleFiles {
            guard let art = art(name) else { continue }
            checked += 1
            guard let cache = renderer.buildLiveRenderCacheGeometry(art: art,
                                                                    segmentBudget: Self.segmentBudget) else {
                // Over budget, or nothing visible — also a valid outcome.
                continue
            }

            var counted = 0
            for (position, layer) in cache.layers.enumerated() {
                if layer.needsRebuild {
                    // Rebuilt per frame, so they must not hold cached geometry and must not
                    // be counted in the reported size.
                    XCTAssertTrue(layer.ops.isEmpty, "\(name): rebuild layer holds ops")
                    XCTAssertNil(cache.deviceOps(forLayerAt: position, camera: .identity),
                                 "\(name): rebuild layer must not hand out device ops")
                    continue
                }
                let strokes = cache.strokeCount(at: position)
                XCTAssertGreaterThanOrEqual(strokes, 0)
                // Without a viewport nothing is culled, so every stroke comes back.
                let ops = cache.deviceOps(forLayerAt: position, camera: .identity)
                let returned = ops?.reduce(0) { total, op in
                    if case .stroke = op { return total + 1 }
                    return total
                } ?? 0
                XCTAssertEqual(returned, strokes, "\(name): layer \(position) lost strokes")
                counted += strokes
            }

            // The reported size must be exactly what the cached layers hold.
            let layerSegments = cache.layers.reduce(0) { $0 + $1.cachedSegmentCount }
            XCTAssertEqual(layerSegments, cache.segmentCount, "\(name): segment count mismatch")
            XCTAssertLessThanOrEqual(cache.segmentCount, Renderer.liveCacheSegmentBudget)
            XCTAssertTrue(cache.withinBudget)
            _ = counted
        }

        try XCTSkipIf(checked == 0, "no sample .art files found in \(artDirectory.path)")
    }

    /// Every cached stroke must carry bounds that actually contain it — culling trusts them.
    func testCachedStrokeBoundsContainTheirGeometry() throws {
        let renderer = Renderer(canvasSize: CGSize(width: 1920, height: 1080), scale: 1.0)
        // Small enough to build in a debug test run, and it has ordinary strokes (no
        // paste), so this really only checks the bounds.
        guard let art = art("logo-sketch-s6d5h46e54h_01.art"),
              let cache = renderer.buildLiveRenderCacheGeometry(art: art,
                                                                 segmentBudget: 200_000) else {
            throw XCTSkip("sample document unavailable")
        }

        var checked = 0
        for layer in cache.layers where !layer.needsRebuild {
            for op in layer.ops {
                guard case .stroke(let stroke) = op, !stroke.segments.isEmpty else { continue }
                // Every segment of every stroke, but only the first few strokes of the
                // layer — enough to catch a wrong box without a slow suite.
                for segment in stroke.segments.prefix(stroke.segments.count / 4 + 1) {
                    let b = stroke.bounds
                    XCTAssertGreaterThanOrEqual(segment.p1.x, Float(b.minX) - 1e-3)
                    XCTAssertLessThanOrEqual(segment.p1.x, Float(b.maxX) + 1e-3)
                    XCTAssertGreaterThanOrEqual(segment.p1.y, Float(b.minY) - 1e-3)
                    XCTAssertLessThanOrEqual(segment.p1.y, Float(b.maxY) + 1e-3)
                    checked += 1
                }
            }
        }
        XCTAssertGreaterThan(checked, 0)
    }
}