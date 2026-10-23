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

    /// Per-frame CPU planning cost (`bin`) for one document, measured without Metal.
    ///
    /// `BINTIME` puts kaos at `bin 39` against `gpu 39` once allocation is reported
    /// separately, so the CPU half of a live frame now costs as much as the GPU half and
    /// almost all of it sits in the prefix that builds the tile plan. The tile *counts*
    /// come from the GPU on macOS; this test replicates them with the exact kernel formula
    /// (`liveBinRangeForSeg` + layer-box clamp) and times the stages the CPU owns, so the
    /// split can be found on Linux instead of by guessing from one aggregate number.
    ///
    ///     ART_LIVE_PROFILE_BIN=art/kaos.art swift test --filter testProfileBinPlan
    func testProfileBinPlan() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let spec = environment["ART_LIVE_PROFILE_BIN"] else {
            throw XCTSkip("set ART_LIVE_PROFILE_BIN=art/kaos.art to measure the bin plan")
        }
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ArtRenderLibraryTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let url = spec.hasPrefix("/") ? URL(fileURLWithPath: spec)
                                      : URL(fileURLWithPath: spec, relativeTo: repoRoot)
        let data = try Data(contentsOf: url)
        guard let art = ArtParser(data: [UInt8](data)) else {
            XCTFail("parse failed: \(url.path)")
            return
        }
        // `art2png` always renders the live view on a 1920×1080 canvas at scale 1, so at
        // zoom 1 the camera is the identity and `radiusFactor` is exactly 1 — the same
        // numbers the CLI run reports.
        let renderer = Renderer(canvasSize: CGSize(width: 1920, height: 1080), scale: 1.0)
        guard let cache = renderer.buildLiveRenderCacheGeometry(art: art),
              let position = cache.layers.firstIndex(where: { !$0.needsRebuild }) else {
            XCTFail("no cached layer in \(url.lastPathComponent)")
            return
        }
        let layer = cache.layers[position]
        let viewport = CGSize(width: 1920, height: 1080)
        let viewportRect = CGRect(origin: .zero, size: viewport)
        let camera = LiveViewTransform()
            .matrix(canvasPixelSize: viewport, viewportSize: viewport).affineTransform
        let ca = Float(camera.a), cb = Float(camera.b)
        let cc = Float(camera.c), cd = Float(camera.d)
        let ctx = Float(camera.tx), cty = Float(camera.ty)
        let radiusFactor = (sqrt(ca * ca + cc * cc) + sqrt(cb * cb + cd * cd)) / 2
        let tileSize = 16
        let (tilesX, tilesY) = GpuBinSpec.tileGrid(viewportWidth: 1920, viewportHeight: 1080,
                                                   tileSize: tileSize)
        let texW = Float(viewport.width), texH = Float(viewport.height)
        let invTile = Float(1.0 / Double(tileSize))

        // Reference data, built exactly like `ensureBinRefState`: blocks never span
        // strokes and carry their doc-space corner AABB + max radius.
        var strokes: [LiveCachedStroke] = []
        var blockFirst: [Int] = [], blockCount: [Int] = []
        var blockStroke: [Int32] = [], blockSegStart: [Int32] = []
        var blockRects: [SIMD4<Float>] = [], blockMaxRadius: [Float] = []
        var segTotal = 0
        for op in layer.ops {
            guard case .stroke(let s) = op else { continue }
            let sid = Int32(strokes.count)
            strokes.append(s)
            blockFirst.append(blockRects.count)
            var nBlocks = 0
            var bi = 0
            while bi < s.segments.count {
                var bx0 = Float.greatestFiniteMagnitude, bx1 = -Float.greatestFiniteMagnitude
                var by0 = Float.greatestFiniteMagnitude, by1 = -Float.greatestFiniteMagnitude
                var bR = Float(0)
                var n = 0
                while bi < s.segments.count && n < GpuBinSpec.pruneBlockSize {
                    let seg = s.segments[bi]
                    bx0 = min(bx0, min(min(seg.p0.x, seg.p1.x), min(seg.p2.x, seg.p3.x)))
                    bx1 = max(bx1, max(max(seg.p0.x, seg.p1.x), max(seg.p2.x, seg.p3.x)))
                    by0 = min(by0, min(min(seg.p0.y, seg.p1.y), min(seg.p2.y, seg.p3.y)))
                    by1 = max(by1, max(max(seg.p0.y, seg.p1.y), max(seg.p2.y, seg.p3.y)))
                    bR = max(bR, max(seg.radius0, seg.radius1))
                    bi += 1
                    n += 1
                }
                blockStroke.append(sid)
                blockSegStart.append(Int32(segTotal + bi - n))
                blockRects.append(SIMD4<Float>(bx0, by0, bx1, by1))
                blockMaxRadius.append(bR)
                nBlocks += 1
            }
            blockCount.append(nBlocks)
            segTotal += s.segments.count
        }

        // ── The cull: what `renderCachedLayerGPUThrowing` does before the GPU is touched.
        var vis: [Int] = []
        var box: (minX: Int, minY: Int, maxX: Int, maxY: Int)? = nil
        let cullMs = Self.measure {
            vis.removeAll(keepingCapacity: true)
            box = nil
            var sid = -1
            for s in strokes {
                sid += 1
                guard LiveRenderCache.intersects(s.bounds, camera: camera,
                                                 viewport: viewportRect) else { continue }
                vis.append(sid)
                let p0 = CGPoint(x: s.bounds.minX, y: s.bounds.minY).applying(camera)
                let p1 = CGPoint(x: s.bounds.maxX, y: s.bounds.minY).applying(camera)
                let p2 = CGPoint(x: s.bounds.maxX, y: s.bounds.maxY).applying(camera)
                let p3 = CGPoint(x: s.bounds.minX, y: s.bounds.maxY).applying(camera)
                let minX = Float(min(min(p0.x, p1.x), min(p2.x, p3.x)))
                let maxX = Float(max(max(p0.x, p1.x), max(p2.x, p3.x)))
                let minY = Float(min(min(p0.y, p1.y), min(p2.y, p3.y)))
                let maxY = Float(max(max(p0.y, p1.y), max(p2.y, p3.y)))
                guard let tb = GpuBinSpec.tileBoxForAABB(minX: minX, minY: minY,
                                                         maxX: maxX, maxY: maxY,
                                                         texW: texW, texH: texH,
                                                         tilesX: tilesX, tilesY: tilesY,
                                                         invTile: invTile) else { continue }
                box = GpuBinSpec.unionTileBox(box, with: tb)
            }
        }
        guard let b = box else {
            XCTFail("nothing visible")
            return
        }
        let boxW = b.maxX - b.minX + 1, boxH = b.maxY - b.minY + 1
        let boxTiles = boxW * boxH
        let visibleSet = Set(vis)

        // ── Tile counts. The GPU's fused transform+count dispatch does this on macOS; the
        // formula is copied from `liveBinRangeForSeg` + the layer-box clamp so the table
        // stages below see the real incidence totals.
        var counts = [UInt32](repeating: 0, count: boxTiles)
        for (sid, s) in strokes.enumerated() {
            let visible = visibleSet.contains(sid)
            for seg in s.segments {
                guard visible else { continue }
                let r0 = seg.radius0 * radiusFactor, r1 = seg.radius1 * radiusFactor
                let pad = 1.4 * max(r0, r1) + 1
                let x1 = ca * seg.p1.x + cc * seg.p1.y + ctx
                let y1 = cb * seg.p1.x + cd * seg.p1.y + cty
                let x2 = ca * seg.p2.x + cc * seg.p2.y + ctx
                let y2 = cb * seg.p2.x + cd * seg.p2.y + cty
                let minX = min(x1, x2) - pad, maxX = max(x1, x2) + pad
                let minY = min(y1, y2) - pad, maxY = max(y1, y2) + pad
                if maxX < 0 || minX > texW || maxY < 0 || minY > texH { continue }
                let loX = max(0, min(tilesX - 1, Int(minX * invTile)))
                let hiX = max(0, min(tilesX - 1, Int(maxX * invTile)))
                let loY = max(0, min(tilesY - 1, Int(minY * invTile)))
                let hiY = max(0, min(tilesY - 1, Int(maxY * invTile)))
                let cx0 = max(loX, b.minX), cx1 = min(hiX, b.maxX)
                let cy0 = max(loY, b.minY), cy1 = min(hiY, b.maxY)
                if cx0 > cx1 || cy0 > cy1 { continue }
                var ty = cy0
                while ty <= cy1 {
                    var t = (ty - b.minY) * boxW + (cx0 - b.minX)
                    for _ in cx0...cx1 { counts[t] += 1; t += 1 }
                    ty += 1
                }
            }
        }
        let total = counts.reduce(0) { $0 + Int($1) }

        // ── The stages `bin` actually owns.
        let combineMs = Self.measure { _ = GpuBinSpec.combine(counts: counts) }
        let (entries, starts, combinedTotal) = GpuBinSpec.combine(counts: counts)

        let tableMs = Self.measure {
            _ = GpuBinSpec.strokeBlockTable(
                visibleStrokes: vis,
                blockFirst: blockFirst, blockCount: blockCount,
                blockStroke: blockStroke, blockSegStart: blockSegStart,
                blockRects: blockRects, blockMaxRadius: blockMaxRadius,
                camera: (a: ca, b: cb, c: cc, d: cd, tx: ctx, ty: cty),
                radiusFactor: radiusFactor, tileCounts: counts,
                box: b, texW: Int(texW), texH: Int(texH),
                tilesX: tilesX, tilesY: tilesY, invTile: invTile)
        }
        let table = GpuBinSpec.strokeBlockTable(
            visibleStrokes: vis,
            blockFirst: blockFirst, blockCount: blockCount,
            blockStroke: blockStroke, blockSegStart: blockSegStart,
            blockRects: blockRects, blockMaxRadius: blockMaxRadius,
            camera: (a: ca, b: cb, c: cc, d: cd, tx: ctx, ty: cty),
            radiusFactor: radiusFactor, tileCounts: counts,
            box: b, texW: Int(texW), texH: Int(texH),
            tilesX: tilesX, tilesY: tilesY, invTile: invTile)

        let sortChunk = LiveConfig.sortChunkSize()
        let chunkMs = Self.measure {
            _ = GpuBinSpec.chunkTable(entries: entries, chunkSize: sortChunk)
        }
        let (sortChunks, _, mergePasses) = GpuBinSpec.chunkTable(entries: entries,
                                                                chunkSize: sortChunk)
        let mergeMs = Self.measure {
            _ = GpuBinSpec.mergePlan(entries: entries, mergePasses: mergePasses,
                                     chunkSize: sortChunk,
                                     unitSize: LiveConfig.mergeUnitSize())
        }

        // The four `memcpy`s into the shared buffers: entries (tile list) + starts +
        // sort chunks + the block table's header/entries.
        let dst = UnsafeMutableRawPointer.allocate(byteCount: 1 << 24, alignment: 64)
        defer { dst.deallocate() }
        let copyMs = Self.measure {
            entries.withUnsafeBytes { raw in
                if let src = raw.baseAddress { memcpy(dst, src, min(raw.count, 1 << 24)) }
            }
            starts.withUnsafeBytes { raw in
                if let src = raw.baseAddress { memcpy(dst, src, raw.count) }
            }
            sortChunks.withUnsafeBytes { raw in
                if let src = raw.baseAddress { memcpy(dst, src, min(raw.count, 1 << 24)) }
            }
            table.header.withUnsafeBytes { raw in
                if let src = raw.baseAddress { memcpy(dst, src, min(raw.count, 1 << 24)) }
            }
            table.entries.withUnsafeBytes { raw in
                if let src = raw.baseAddress { memcpy(dst, src, min(raw.count, 1 << 24)) }
            }
        }

        print("\n=== bin plan: \(url.lastPathComponent) (1920×1080, zoom 1) ===")
        print(String(format: "  strokes %d visible %d | segments %d | box %d×%d = %d tiles",
                     strokes.count, vis.count, segTotal, boxW, boxH, boxTiles))
        print(String(format: "  incidences %d (%d/tile max-ish) | chunks %d passes %d | blocks %d entries %d",
                     total, boxTiles > 0 ? total / boxTiles : 0,
                     sortChunks.count, mergePasses, table.totalBlocks, table.entries.count))
        print(String(format: "  cull        %7.2f ms", cullMs))
        print(String(format: "  combine     %7.2f ms", combineMs))
        print(String(format: "  blockTable  %7.2f ms", tableMs))
        print(String(format: "  chunkTable  %7.2f ms", chunkMs))
        print(String(format: "  mergePlan   %7.2f ms", mergeMs))
        print(String(format: "  memcpys     %7.2f ms", copyMs))
        print(String(format: "  SUM         %7.2f ms  (combined total %d)",
                     cullMs + combineMs + tableMs + chunkMs + mergeMs + copyMs, combinedTotal))
    }

    /// How much of the composite pass's SDF work is provably empty? The per-pixel prune
    /// skips a segment whose chord is farther than `padding1` from the pixel; every
    /// surviving (pixel, segment) pair runs an SDF. This probe walks the same pixel box
    /// the binner lists (`1.4·r + 1` around the chord) and counts survivors under
    ///
    ///   * the old rule: `reach + max(0.75, 0.375·rMax)`, folded into `padding1` and
    ///     scaled with the camera, and
    ///   * the new rule: `reach` in `padding1` (camera-scaled) plus a device-pixel margin
    ///     (`aaDeviceMargin` for clean strokes, `noiseDeviceMargin` for noisy ones),
    ///
    /// next to the exact ink cutoff, so the ratio predicts the SDF saving before a Mac run.
    ///
    ///     ART_LIVE_PROFILE_PRUNE=art/kaos.art swift test --filter testProfilePruneHeadroom
    ///     ART_LIVE_PROFILE_PRUNE_STRIDE=11   # sample fewer segments (default 7)
    func testProfilePruneHeadroom() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let spec = environment["ART_LIVE_PROFILE_PRUNE"] else {
            throw XCTSkip("set ART_LIVE_PROFILE_PRUNE=art/kaos.art to measure prune headroom")
        }
        let sampleStride = max(1, Int(environment["ART_LIVE_PROFILE_PRUNE_STRIDE"] ?? "") ?? 7)
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ArtRenderLibraryTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // repo root
        let url = spec.hasPrefix("/") ? URL(fileURLWithPath: spec)
                                      : URL(fileURLWithPath: spec, relativeTo: repoRoot)
        let data = try Data(contentsOf: url)
        guard let art = ArtParser(data: [UInt8](data)) else {
            XCTFail("parse failed: \(url.path)")
            return
        }
        // Same setup as `testProfileBinPlan`: the live view of a 1920×1080 canvas at zoom 1
        // has an identity camera, so `radiusFactor` is 1 and `padding1` is already in
        // device pixels.
        let renderer = Renderer(canvasSize: CGSize(width: 1920, height: 1080), scale: 1.0)
        guard let cache = renderer.buildLiveRenderCacheGeometry(art: art),
              let position = cache.layers.firstIndex(where: { !$0.needsRebuild }) else {
            XCTFail("no cached layer in \(url.lastPathComponent)")
            return
        }
        let layer = cache.layers[position]

        struct Bucket {
            var segments = 0, pixels = 0, old = 0, new = 0, ink = 0
        }
        var buckets: [String: Bucket] = [:]
        var strokes = 0, segments = 0, noisy = 0, sampled = 0
        var radiusHistogram = [Int](repeating: 0, count: 6)   // ≤1 ≤2 ≤4 ≤8 ≤16 >16
        var sumOld = 0.0, sumNew = 0.0, sumInk = 0.0
        let width = 1920, height = 1080

        for op in layer.ops {
            guard case .stroke(let s) = op else { continue }
            strokes += 1
            segments += s.segments.count
            for (i, seg) in s.segments.enumerated() {
                if seg.noiseSeed != 0 { noisy += 1 }
                let rMax = max(seg.radius0, seg.radius1)
                let rMin = min(seg.radius0, seg.radius1)
                let bucket = rMax <= 1 ? 0 : rMax <= 2 ? 1 : rMax <= 4 ? 2
                           : rMax <= 8 ? 3 : rMax <= 16 ? 4 : 5
                radiusHistogram[bucket] += 1
                guard i % sampleStride == 0 else { continue }
                sampled += 1

                // `radius` is the new shape-only reach (no margin) — exactly `padding1`
                // at radiusFactor 1.
                let reach = SegmentPrune.radius(
                    p0: seg.p0, p1: seg.p1, p2: seg.p2, p3: seg.p3,
                    radius0: seg.radius0, radius1: seg.radius1,
                    segmentType: seg.segmentType, isMarker: false)   // per-tile path: no markers
                let isNoisy = seg.noiseSeed != 0
                let oldMargin = max(0.75, 0.375 * rMax)
                let newMargin = isNoisy
                    ? SegmentPrune.noiseDeviceMargin(radius0: seg.radius0, radius1: seg.radius1)
                    : SegmentPrune.aaDeviceMargin
                let inkReach = isNoisy
                    ? reach - rMax + SegmentPrune.noiseReachFactor * max(rMin, 1)
                    : reach + SegmentPrune.aaCutoff
                let oldPrune = reach + oldMargin
                let newPrune = reach + newMargin

                // The binner's pixel box: pad = 1.4·rMax + 1 around the chord. Sample it
                // on a stride that keeps the work bounded for fat strokes.
                let pad = 1.4 * rMax + 1
                let minX = Int((min(seg.p1.x, seg.p2.x) - pad).rounded(.down))
                let maxX = Int((max(seg.p1.x, seg.p2.x) + pad).rounded(.up))
                let minY = Int((min(seg.p1.y, seg.p2.y) - pad).rounded(.down))
                let maxY = Int((max(seg.p1.y, seg.p2.y) + pad).rounded(.up))
                let area = max(1, (maxX - minX + 1) * (maxY - minY + 1))
                let pixelStride = max(1, Int((Double(area) / 4096.0).squareRoot().rounded(.up)))

                let key = "type\(seg.segmentType) \(isNoisy ? "noise" : "clean")"
                var b = buckets[key] ?? Bucket()
                b.segments += 1
                var y = minY
                while y <= maxY {
                    var x = minX
                    while x <= maxX {
                        if x >= 0 && x < width && y >= 0 && y < height {
                            let d2 = SegmentPrune.segmentDistanceSq(
                                ax: seg.p1.x, ay: seg.p1.y, bx: seg.p2.x, by: seg.p2.y,
                                px: Float(x) + 0.5, py: Float(y) + 0.5)
                            let d = d2.squareRoot()
                            b.pixels += 1
                            if d <= oldPrune { b.old += 1 }
                            if d <= newPrune { b.new += 1 }
                            if d <= inkReach { b.ink += 1 }
                        }
                        x += pixelStride
                    }
                    y += pixelStride
                }
                buckets[key] = b
                sumOld += Double(oldPrune)
                sumNew += Double(newPrune)
                sumInk += Double(inkReach)
            }
        }

        let names = ["≤1", "≤2", "≤4", "≤8", "≤16", ">16"]
        print("\n=== prune headroom: \(url.lastPathComponent) (sample 1/\(sampleStride)) ===")
        print(String(format: "  strokes %d | segments %d | noisy %d (%.1f%%) | sampled %d",
                     strokes, segments, noisy,
                     segments > 0 ? 100.0 * Double(noisy) / Double(segments) : 0, sampled))
        print("  rMax histogram: " + zip(names, radiusHistogram)
            .map { "\($0) \($1)" }.joined(separator: "  "))
        print("  bucket             segs    boxPx     old      new      ink   new/old")
        var totals = Bucket()
        for key in buckets.keys.sorted() {
            let b = buckets[key]!
            totals.segments += b.segments; totals.pixels += b.pixels
            totals.old += b.old; totals.new += b.new; totals.ink += b.ink
            print(String(format: "  %-14@ %7d %8d %7d %8d %8d   %5.2f%%",
                         key as NSString, b.segments, b.pixels, b.old, b.new, b.ink,
                         b.old > 0 ? 100.0 * Double(b.new) / Double(b.old) : 0))
        }
        print(String(format: "  %-14@ %7d %8d %7d %8d %8d   %5.2f%%",
                     "TOTAL" as NSString, totals.segments, totals.pixels,
                     totals.old, totals.new, totals.ink,
                     totals.old > 0 ? 100.0 * Double(totals.new) / Double(totals.old) : 0))
        let n = Double(max(1, sampled))
        print(String(format: "  mean prune radius: old %.2f px  new %.2f px  ink %.2f px  (sample is 1/%d of segments)",
                     sumOld / n, sumNew / n, sumInk / n, sampleStride))
    }

    /// Minimum of three runs: Swift on Linux pays lazy-page and allocator costs on the
    /// first pass, and the interactive frame sees the steady state.
    private static func measure(_ body: () -> Void) -> Double {
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<3 {
            let start = DispatchTime.now().uptimeNanoseconds
            body()
            best = min(best, ms(since: start))
        }
        return best
    }

    private static func ms(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0
    }
}