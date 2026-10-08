import XCTest
import ArtParser
@testable import ArtRenderLibrary

/// CPU-side cost profile of the live render path's geometry stages.
///
/// The interactive (re-render) path can only be fast if its per-frame work is cheap, and
/// that work — walking the actions once, flattening the strokes, and re-mapping the cached
/// geometry onto a new camera — is pure geometry, so it can be measured without a GPU. That
/// matters because the Metal half (`bin`'s tile indexing, the dispatches, the waits) can
/// only be measured on macOS, where `art2png --live-view` prints the breakdown from
/// `Renderer.lastLiveFrameTiming`.
///
/// Run it over the files in `art/`:
///
///     ART_LIVE_PROFILE=1 swift test --filter LiveProfileTests
///     ART_LIVE_PROFILE=1 ART_LIVE_PROFILE_LIMIT=20 swift test --filter LiveProfileTests
///
/// It is skipped unless `ART_LIVE_PROFILE` is set, so it never slows the normal test run.
final class LiveProfileTests: XCTestCase {

    func testProfileCacheAndRemap() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ART_LIVE_PROFILE"] != nil,
                          "set ART_LIVE_PROFILE=1 to run the live-path profile")

        let environment = ProcessInfo.processInfo.environment
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ArtRenderLibraryTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let artDir = repoRoot.appendingPathComponent("art")
        let files = try FileManager.default
            .contentsOfDirectory(at: artDir, includingPropertiesForKeys: [.fileSizeKey])
            .filter { $0.pathExtension == "art" }
            .sorted {
                let a = (try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let b = (try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                return a > b
            }
        let limit = Int(environment["ART_LIVE_PROFILE_LIMIT"] ?? "") ?? 6

        print("\n=== live path profile (fit camera, canvas 1.0) ===")
        for file in files.prefix(limit) {
            profile(url: file)
        }
    }

    private func profile(url: URL) {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let parseStart = DispatchTime.now().uptimeNanoseconds
        guard let data = try? Data(contentsOf: url),
              let art = ArtParser(data: [UInt8](data)) else {
            print("  \(url.lastPathComponent): PARSE FAILED")
            return
        }
        let parseMs = Self.ms(since: parseStart)

        // Same canvas the app and `art2png --viewport` use for the live view.
        let renderer = Renderer(canvasSize: CGSize(width: 1920, height: 1080), scale: 1.0)
        let buildStart = DispatchTime.now().uptimeNanoseconds
        let cache = renderer.buildLiveRenderCacheGeometry(art: art)
        let buildMs = Self.ms(since: buildStart)
        guard let cache else {
            print("  \(url.lastPathComponent): no cache")
            return
        }

        var strokes = 0
        var segments = 0
        var maxSegmentsPerStroke = 0
        for layer in cache.layers where !layer.needsRebuild {
            for op in layer.ops {
                if case .stroke(let stroke) = op {
                    strokes += 1
                    segments += stroke.segments.count
                    maxSegmentsPerStroke = max(maxSegmentsPerStroke, stroke.segments.count)
                }
            }
        }

        // Per-frame work: the camera applied to every cached stroke. Run a few times — the
        // first pass allocates, and the steady state is what a drag sees.
        let remapMs = (0..<3).map { _ -> Double in
            let start = DispatchTime.now().uptimeNanoseconds
            let camera = LiveViewTransform().matrix(
                canvasPixelSize: CGSize(width: 5120, height: 3584),
                viewportSize: CGSize(width: 1920, height: 1080)).affineTransform
            for position in 0..<cache.layers.count {
                _ = cache.deviceOps(forLayerAt: position, camera: camera)
            }
            return Self.ms(since: start)
        }

        print(String(format: "  %-44@ %7.1f KB  layers %3d  rebuild %d",
                     url.lastPathComponent as NSString,
                     Double(size) / 1024.0, cache.layers.count, cache.rebuildingLayers))
        print(String(format: "        parse %6.0f ms | cache build %7.0f ms | per frame (remap) %5.0f / %5.0f / %5.0f ms",
                     parseMs, buildMs, remapMs[0], remapMs[1], remapMs[2]))
        print(String(format: "        strokes %6d | segments %8d | max/stroke %6d",
                     strokes, segments, maxSegmentsPerStroke))
    }

    private static func ms(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
    }
}