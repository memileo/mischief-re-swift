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
}