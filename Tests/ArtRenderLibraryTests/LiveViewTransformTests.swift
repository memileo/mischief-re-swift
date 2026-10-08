import XCTest
#if os(Linux)
import CoreFoundation
import Silica
#else
import CoreGraphics
#endif
@testable import ArtRenderLibrary

/// The live view's transform maths is the one piece of the interactive preview that can
/// be verified without a GPU or a window, so it is pinned down here.
///
/// Coordinates: canvas/view pixels are y-down (AppKit + texture row order), NDC is y-up.
final class LiveViewTransformTests: XCTestCase {

    private let canvas = CGSize(width: 2000, height: 1000)
    private let viewport = CGSize(width: 800, height: 600)

    private let center = CGPoint(x: 400, y: 300)          // viewport centre
    private let canvasCenter = CGPoint(x: 1000, y: 500)   // canvas centre

    private func assertPoint(_ a: CGPoint, _ b: CGPoint,
                            accuracy: CGFloat = 1e-6,
                            _ message: String = "",
                            file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Double(a.x), Double(b.x), accuracy: Double(accuracy),
                       "x mismatch \(message)", file: file, line: line)
        XCTAssertEqual(Double(a.y), Double(b.y), accuracy: Double(accuracy),
                       "y mismatch \(message)", file: file, line: line)
    }

    // MARK: - Neutral state == the file's own view matrix

    func testNeutralCentresCanvasInViewport() {
        let t = LiveViewTransform()
        XCTAssertTrue(t.isNeutral)
        let m = t.matrix(canvasPixelSize: canvas, viewportSize: viewport)
        assertPoint(m.applying(canvasCenter), center, "canvas centre should land on the view centre")
    }

    func testNeutralAspectFitsCanvas() {
        // 2000x1000 into 800x600 → fit scale 0.4 → 800x400 band centred vertically.
        let m = LiveViewTransform().matrix(canvasPixelSize: canvas, viewportSize: viewport)
        assertPoint(m.applying(CGPoint(x: 0, y: 0)), CGPoint(x: 0, y: 100), "top-left")
        assertPoint(m.applying(CGPoint(x: 2000, y: 1000)), CGPoint(x: 800, y: 500), "bottom-right")
    }

    func testNeutralPortraitCanvasIsLimitedByHeight() {
        let portrait = CGSize(width: 1000, height: 2000)   // fit = 0.3 → 300x600 band
        let m = LiveViewTransform().matrix(canvasPixelSize: portrait, viewportSize: viewport)
        // canvas top-centre → view top-centre (x is the view centre: 400 - 150 + 150)
        assertPoint(m.applying(CGPoint(x: 500, y: 0)), CGPoint(x: 400, y: 0), "top edge")
        assertPoint(m.applying(CGPoint(x: 500, y: 2000)), CGPoint(x: 400, y: 600), "bottom edge")
        assertPoint(m.applying(CGPoint(x: 0, y: 1000)), CGPoint(x: 250, y: 300), "left edge")
        assertPoint(m.applying(CGPoint(x: 1000, y: 1000)), CGPoint(x: 550, y: 300), "right edge")
    }

    // MARK: - Clip space

    func testClipMatrixFlipsYAndFitsNDC() {
        let clip = LiveViewTransform().clipMatrix(canvasPixelSize: canvas, viewportSize: viewport)
        // canvas top-left → view (0, 100) → ndc (-1, 1 - 100/600*2)
        assertPoint(clip.applying(CGPoint(x: 0, y: 0)),
                    CGPoint(x: -1, y: 1 - 200.0 / 600.0))
        // canvas bottom-right → view (800, 500) → ndc (1, 1 - 500/600*2)
        assertPoint(clip.applying(CGPoint(x: 2000, y: 1000)),
                    CGPoint(x: 1, y: 1 - 1000.0 / 600.0))
    }

    // MARK: - Pan

    func testPanTranslatesByExactlyTheDelta() {
        var t = LiveViewTransform()
        t.pan(by: CGPoint(x: 37, y: -12))
        let m = t.matrix(canvasPixelSize: canvas, viewportSize: viewport)
        assertPoint(m.applying(canvasCenter), CGPoint(x: center.x + 37, y: center.y - 12))
    }

    // MARK: - Zoom

    func testZoomAnchorStaysPut() {
        var t = LiveViewTransform()
        t.pan(by: CGPoint(x: 40, y: 25))
        t.rotate(by: 0.4, anchor: CGPoint(x: 120, y: 80), viewportSize: viewport)

        let anchor = CGPoint(x: 210, y: 330)
        let canvasBefore = t.matrix(canvasPixelSize: canvas, viewportSize: viewport)
            .inverted()!.applying(anchor)

        for factor in [1.4, 0.3, 8.0] {
            t.zoom(by: CGFloat(factor), anchor: anchor, viewportSize: viewport)
            let m = t.matrix(canvasPixelSize: canvas, viewportSize: viewport)
            assertPoint(m.applying(canvasBefore), anchor, accuracy: 1e-4,
                        "canvas point should stay under the anchor after ×\(factor)")
        }
    }

    func testZoomDoublesTheScale() {
        var t = LiveViewTransform()
        t.zoom(by: 2, anchor: center, viewportSize: viewport)
        XCTAssertEqual(t.zoom, 2, accuracy: 1e-9)
        XCTAssertEqual(t.zoomPercent, 200, accuracy: 1e-9)
        // centred zoom keeps the canvas centre under the viewport centre
        let m = t.matrix(canvasPixelSize: canvas, viewportSize: viewport)
        assertPoint(m.applying(canvasCenter), center)
    }

    func testZoomIsClamped() {
        var t = LiveViewTransform()
        t.zoom(by: 10_000, anchor: center, viewportSize: viewport)
        XCTAssertEqual(t.zoom, LiveViewTransform.zoomRange.upperBound, accuracy: 1e-9)
        t.zoom(by: 0.000_0001, anchor: center, viewportSize: viewport)
        XCTAssertEqual(t.zoom, LiveViewTransform.zoomRange.lowerBound, accuracy: 1e-9)
        // a no-op multiplier must not move anything
        let before = t
        t.zoom(by: 1, anchor: center, viewportSize: viewport)
        XCTAssertEqual(t, before)
    }

    func testZoomIgnoresNonPositiveMultipliers() {
        var t = LiveViewTransform()
        t.zoom(by: 10, anchor: center, viewportSize: viewport)
        let before = t
        t.zoom(by: 0, anchor: center, viewportSize: viewport)
        t.zoom(by: -2, anchor: center, viewportSize: viewport)
        t.zoom(by: .nan, anchor: center, viewportSize: viewport)
        XCTAssertEqual(t, before)
    }

    // MARK: - Rotation

    func testRotateAnchorStaysPut() {
        var t = LiveViewTransform()
        t.pan(by: CGPoint(x: -60, y: 15))
        t.zoom(by: 1.7, anchor: CGPoint(x: 700, y: 100), viewportSize: viewport)

        let anchor = CGPoint(x: 130, y: 470)
        let canvasBefore = t.matrix(canvasPixelSize: canvas, viewportSize: viewport)
            .inverted()!.applying(anchor)

        for delta in [0.25, -0.9, 2.0] {
            t.rotate(by: CGFloat(delta), anchor: anchor, viewportSize: viewport)
            let m = t.matrix(canvasPixelSize: canvas, viewportSize: viewport)
            assertPoint(m.applying(canvasBefore), anchor, accuracy: 1e-4,
                        "canvas point should stay under the anchor after \(delta) rad")
        }
    }

    func testRotationAboutCentreDoesNotMoveTheCentre() {
        var t = LiveViewTransform()
        t.rotate(by: .pi / 3, anchor: center, viewportSize: viewport)
        let m = t.matrix(canvasPixelSize: canvas, viewportSize: viewport)
        assertPoint(m.applying(canvasCenter), center)
        XCTAssertEqual(t.rotation, Double.pi / 3, accuracy: 1e-9)
    }

    // MARK: - Resets

    func testFullResetReturnsToTheFilesViewMatrix() {
        var t = LiveViewTransform()
        t.pan(by: CGPoint(x: 300, y: -80))
        t.zoom(by: 4.2, anchor: center, viewportSize: viewport)
        t.rotate(by: 1.1, anchor: CGPoint(x: 10, y: 10), viewportSize: viewport)
        XCTAssertFalse(t.isNeutral)

        t.resetAll()
        XCTAssertTrue(t.isNeutral)
        XCTAssertEqual(t, LiveViewTransform())
    }

    func testPerModeResetsOnlyTouchTheirOwnComponent() {
        var t = LiveViewTransform()
        t.pan(by: CGPoint(x: 120, y: 60))
        t.zoom(by: 3, anchor: center, viewportSize: viewport)
        t.rotate(by: 0.5, anchor: center, viewportSize: viewport)

        t.resetPan()
        XCTAssertEqual(t.pan, .zero)
        XCTAssertEqual(t.zoom, 3, accuracy: 1e-9)
        XCTAssertEqual(t.rotation, 0.5, accuracy: 1e-9)

        t.resetZoom()
        XCTAssertEqual(t.zoom, 1, accuracy: 1e-9)
        XCTAssertEqual(t.rotation, 0.5, accuracy: 1e-9)

        t.rotate(by: 2, anchor: center, viewportSize: viewport)
        t.resetRotation()
        XCTAssertEqual(t.rotation, 0, accuracy: 1e-9)
        XCTAssertTrue(t.isNeutral)
    }

    // MARK: - Matrix helpers

    func testInvertRoundTrip() {
        var t = LiveViewTransform()
        t.pan(by: CGPoint(x: -19, y: 44))
        t.zoom(by: 2.5, anchor: CGPoint(x: 33, y: 77), viewportSize: viewport)
        t.rotate(by: 0.9, anchor: CGPoint(x: 5, y: 500), viewportSize: viewport)

        let m = t.matrix(canvasPixelSize: canvas, viewportSize: viewport)
        let inverse = m.inverted()!
        let point = CGPoint(x: 1234.5, y: 678.25)
        assertPoint(inverse.applying(m.applying(point)), point, accuracy: 1e-4)
    }

    func testDegenerateMatrixHasNoInverse() {
        XCTAssertNil(LiveViewMatrix(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0).inverted())
    }
}