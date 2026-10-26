import XCTest
#if os(Linux)
import CoreFoundation
import Silica
#else
import CoreGraphics
#endif
@testable import ArtRenderLibrary

/// The interactive view re-rasterises cached geometry by applying the camera to it.
/// That mapping has to be exact, so it is pinned down here (it is plain maths, so it
/// runs on Linux too).
final class LiveRenderCacheTests: XCTestCase {

    private func segment(_ x: Float, _ y: Float,
                         r0: Float = 2, r1: Float = 3,
                         type: UInt32 = 1, seed: UInt32 = 0) -> GPUSplineSegment {
        GPUSplineSegment(p0: SIMD2<Float>(x - 1, y - 1), p1: SIMD2<Float>(x, y),
                         p2: SIMD2<Float>(x + 1, y), p3: SIMD2<Float>(x + 2, y + 2),
                         radius0: r0, radius1: r1,
                         opacity0: 0.5, opacity1: 0.75,
                         segmentType: type, noiseSeed: seed)
    }

    private func camera(scale: CGFloat = 1, rotate: CGFloat = 0,
                        translate: CGPoint = .zero) -> CGAffineTransform {
        // Same shape LiveViewTransform.matrix builds: s · R, then translate.
        let c = cos(rotate) * scale, s = sin(rotate) * scale
        return CGAffineTransform(a: c, b: s, c: -s, d: c, tx: translate.x, ty: translate.y)
    }

    // MARK: - Re-mapping

    func testIdentityCameraIsAnExactCopy() {
        let input = [segment(10, 20, r0: 1.5, r1: 2.5, type: 2, seed: 7)]
        let out = LiveRenderCache.remap(input, camera: .identity, radiusFactor: 1)

        XCTAssertEqual(out.count, 1)
        XCTAssertEqual(out[0].p1.x, input[0].p1.x)
        XCTAssertEqual(out[0].p1.y, input[0].p1.y)
        XCTAssertEqual(out[0].radius0, 1.5)
        XCTAssertEqual(out[0].radius1, 2.5)
    }

    func testScaleMovesPointsAndScalesRadii() {
        let input = [segment(10, 20, r0: 2, r1: 4)]
        let out = LiveRenderCache.remap(input, camera: camera(scale: 3), radiusFactor: 3)

        XCTAssertEqual(out[0].p1.x, 30, accuracy: 1e-4)
        XCTAssertEqual(out[0].p1.y, 60, accuracy: 1e-4)
        XCTAssertEqual(out[0].radius0, 6, accuracy: 1e-4)
        XCTAssertEqual(out[0].radius1, 12, accuracy: 1e-4)
    }

    func testTranslateIsAppliedToEveryControlPoint() {
        let input = [segment(0, 0)]
        let out = LiveRenderCache.remap(input, camera: camera(translate: CGPoint(x: 7, y: -3)),
                                        radiusFactor: 1)

        XCTAssertEqual(out[0].p0.x, 6, accuracy: 1e-4)     // (-1,-1) + (7,-3)
        XCTAssertEqual(out[0].p0.y, -4, accuracy: 1e-4)
        XCTAssertEqual(out[0].p3.x, 9, accuracy: 1e-4)     // (2,2) + (7,-3)
        XCTAssertEqual(out[0].p3.y, -1, accuracy: 1e-4)
    }

    /// Rotation + scale is a similarity, so `segmentType` (which is radius/chord relative)
    /// and the noise seed must survive untouched.
    func testRotationPreservesScaleInvariantFields() {
        let input = [segment(10, 0, type: 2, seed: 12345)]
        let out = LiveRenderCache.remap(input, camera: camera(scale: 2.5, rotate: .pi / 3),
                                        radiusFactor: 2.5)

        XCTAssertEqual(out[0].segmentType, 2)
        XCTAssertEqual(out[0].noiseSeed, 12345)
        XCTAssertEqual(out[0].opacity0, input[0].opacity0)
        XCTAssertEqual(out[0].opacity1, input[0].opacity1)
        // rotation by 60° + scale 2.5 of (10,0) about the origin
        XCTAssertEqual(out[0].p1.x, 12.5, accuracy: 1e-3)
        XCTAssertEqual(out[0].p1.y, 21.650254, accuracy: 1e-3)
        XCTAssertEqual(out[0].radius0, 5, accuracy: 1e-4)
    }

    func testRemapHandlesEmptyAndSingleControlPointSafely() {
        XCTAssertTrue(LiveRenderCache.remap([], camera: camera(scale: 2), radiusFactor: 2).isEmpty)
        let single = LiveRenderCache.remap([segment(1, 2)], camera: camera(scale: 0.5),
                                           radiusFactor: 0.5)
        XCTAssertEqual(single.count, 1)
        XCTAssertEqual(single[0].p1.x, 0.5, accuracy: 1e-5)
    }

    /// A camera is a similarity, so it must not change segment *lengths* relative to
    /// radii — that is the whole reason `segmentType` can be cached.
    func testSimilarityKeepsChordToRadiusRatio() {
        let input = [segment(0, 0, r0: 4, r1: 4)]
        func chord(_ s: GPUSplineSegment) -> Double {
            Double(hypot(s.p2.x - s.p1.x, s.p2.y - s.p1.y))
        }
        let before = chord(input[0]) / Double(input[0].radius1)
        for transform in [camera(scale: 0.37), camera(scale: 8, rotate: 1.1),
                          camera(scale: 1, rotate: -2.4)] {
            let factor = Double(sqrt(transform.a * transform.a + transform.c * transform.c))
            let out = LiveRenderCache.remap(input, camera: transform, radiusFactor: Float(factor))
            XCTAssertEqual(chord(out[0]) / Double(out[0].radius1), before, accuracy: 1e-3)
        }
    }

    // MARK: - Inversion helper

    func testInvertRoundTrip() {
        let t = CGAffineTransform(a: 1.5, b: 0.2, c: -0.1, d: 0.9, tx: 40, ty: -12)
        let inverse = invert(t)!
        let p = CGPoint(x: 123, y: 45)
        let round = p.applying(inverse).applying(t)
        XCTAssertEqual(round.x, p.x, accuracy: 1e-6)
        XCTAssertEqual(round.y, p.y, accuracy: 1e-6)
    }

    func testInvertRejectsDegenerateMatrices() {
        XCTAssertNil(invert(CGAffineTransform(a: 0, b: 0, c: 0, d: 0, tx: 5, ty: 5)))
    }

    // MARK: - Composition order
    //
    // `a.concatenating(b)` applies *a first*, then b. Every transform below therefore has to
    // be written "innermost first" — getting that backwards moved pasted content relative to
    // the rest of the document as soon as the camera changed.

    private func cache(base: CGAffineTransform,
                       layer: CGAffineTransform,
                       ops: [LiveCachedOp]) -> LiveRenderCache {
        LiveRenderCache(baseTransform: base,
                        layers: [LiveCachedLayer(layerIndex: 0, opacity: 1,
                                                 layerTransform: layer,
                                                 ops: ops,
                                                 needsRebuild: false)],
                        segmentCount: 0,
                        withinBudget: true)
    }

    private func stroke(_ x: Float, _ y: Float) -> LiveCachedOp {
        let segments = [segment(x, y)]
        return .stroke(LiveCachedStroke(
            segments: segments,
            color: SIMD4<Float>(0, 0, 0, 1),
            isEraser: false,
            isMarker: false,
            bounds: LiveCachedStroke.referenceBounds(of: segments, isMarker: false)))
    }

    /// liveBase = camera ∘ base, i.e. document px land where the camera puts them.
    func testLiveBaseAppliesTheBaseFirst() {
        let base = CGAffineTransform(a: 2, b: 0, c: 0, d: 2, tx: 10, ty: 20)
        let camera = camera(scale: 3, rotate: .pi / 5, translate: CGPoint(x: -4, y: 9))
        let cache = self.cache(base: base, layer: .identity, ops: [])

        let expected = CGPoint(x: 5, y: 5).applying(base).applying(camera)
        let actual = CGPoint(x: 5, y: 5).applying(cache.liveBaseTransform(camera: camera))
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-6)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-6)
    }

    /// A rebuilt (paste) layer: layer first, then base, then camera — the same order the
    /// static path uses for `artToDevice`.
    func testArtToDeviceAppliesLayerBaseCamera() {
        let layer = CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 100, ty: 0)
        let base = CGAffineTransform(a: 1, b: 0.3, c: 0, d: 1, tx: 0, ty: 50)
        let cam = camera(scale: 2, rotate: 0.7, translate: CGPoint(x: 3, y: -3))
        let cache = self.cache(base: base, layer: layer, ops: [])

        let expected = CGPoint(x: 1, y: 2).applying(layer).applying(base).applying(cam)
        let actual = CGPoint(x: 1, y: 2).applying(cache.artToDevice(layerAt: 0, camera: cam)!)
        XCTAssertEqual(actual.x, expected.x, accuracy: 1e-6)
        XCTAssertEqual(actual.y, expected.y, accuracy: 1e-6)
    }

    /// A cut's `inverseAffine` maps **device** pixels into the selection frame — the same
    /// thing the static path stores (`base⁻¹ ∘ m1`, `Renderer.swift`). A canvas point
    /// pushed through the live base and then through the cut has to land exactly where the
    /// selection frame puts it, at any camera.
    func testCutRecomposesAgainstAnyCamera() {
        let base = CGAffineTransform(a: 1.5, b: 0.1, c: -0.2, d: 0.9, tx: 30, ty: -8)
        let selectionFrame = CGAffineTransform(a: 0.8, b: 0.4, c: -0.1, d: 1.2, tx: 7, ty: 11)
        for cam in [camera(scale: 1),
                    camera(scale: 2.7, rotate: -0.9, translate: CGPoint(x: 12, y: 34)),
                    camera(scale: 0.31, rotate: 2.2)] {
            let cache = self.cache(base: base, layer: .identity,
                                   ops: [.cut(rect: [0, 0, 40, 40], selectionFrame: selectionFrame)])
            guard let ops = cache.deviceOps(forLayerAt: 0, camera: cam),
                  case .cut(let meta)? = ops.first else {
                return XCTFail("expected a cut op")
            }
            let liveBase = cache.liveBaseTransform(camera: cam)
            for p in [CGPoint(x: 5, y: 5), CGPoint(x: -3, y: 17)] {
                let mapped = p.applying(liveBase).applying(meta.inverseAffine)
                let expected = p.applying(selectionFrame)
                XCTAssertEqual(mapped.x, expected.x, accuracy: 1e-4)
                XCTAssertEqual(mapped.y, expected.y, accuracy: 1e-4)
            }
        }
    }

    // MARK: - Off-screen culling

    func testCullingDropsStrokesOutsideTheViewport() {
        let cache = self.cache(base: .identity, layer: .identity,
                               ops: [stroke(50, 50), stroke(5_000, 5_000)])
        let cam = camera(scale: 2, rotate: 0.3, translate: CGPoint(x: 10, y: 10))

        XCTAssertEqual(cache.deviceOps(forLayerAt: 0, camera: cam)?.count, 2)
        let culled = cache.deviceOps(forLayerAt: 0, camera: cam,
                                     viewport: CGRect(x: 0, y: 0, width: 800, height: 600))
        XCTAssertEqual(culled?.count, 1)
        XCTAssertEqual(cache.strokeCount(at: 0), 2)
    }

    func testCullingKeepsStrokesThatTouchTheViewport() {
        let cache = self.cache(base: .identity, layer: .identity,
                               ops: [stroke(0, 0), stroke(-400, -400), stroke(400, 400)])
        // 1:1 camera, so the stroke 400 px off to the top left is off the view while the
        // two inside stay.
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)
        XCTAssertEqual(cache.deviceOps(forLayerAt: 0, camera: .identity, viewport: viewport)?.count, 2)
        // Zoomed out far enough to contain the far corner.
        let zoomedOut = CGRect(x: -1_000, y: -1_000, width: 3_000, height: 3_000)
        XCTAssertEqual(cache.deviceOps(forLayerAt: 0, camera: .identity, viewport: zoomedOut)?.count, 3)
    }

    /// Culling is decided on the *camera-transformed* box: a quarter turn swings the far
    /// stroke into the view, which an axis-aligned test on the untransformed box would miss.
    func testCullingAccountsForRotation() {
        let cache = self.cache(base: .identity, layer: .identity, ops: [stroke(1_000, 0)])
        let viewport = CGRect(x: 0, y: 0, width: 800, height: 600)
        // (1000, 0) → rotated a quarter turn clockwise → (0, -1000) → then down 1000 px.
        let cam = camera(rotate: -.pi / 2, translate: CGPoint(x: 0, y: 1_000))
        XCTAssertEqual(cache.deviceOps(forLayerAt: 0, camera: .identity, viewport: viewport)?.count, 0)
        XCTAssertEqual(cache.deviceOps(forLayerAt: 0, camera: cam, viewport: viewport)?.count, 1)
    }

    /// `referenceBounds` has to contain the ink it is culled against, markers included.
    func testReferenceBoundsCoversTheStroke() {
        let segments = [segment(100, 200, r0: 4, r1: 9)]
        let bounds = LiveCachedStroke.referenceBounds(of: segments, isMarker: false)
        XCTAssertLessThanOrEqual(bounds.minX, 99)
        XCTAssertLessThanOrEqual(bounds.minY, 199)
        XCTAssertGreaterThanOrEqual(bounds.maxX, 102)
        XCTAssertGreaterThanOrEqual(bounds.maxY, 202)

        let marker = LiveCachedStroke.referenceBounds(of: segments, isMarker: true)
        XCTAssertGreaterThan(marker.width, bounds.width)
        XCTAssertGreaterThan(marker.height, bounds.height)
    }
}