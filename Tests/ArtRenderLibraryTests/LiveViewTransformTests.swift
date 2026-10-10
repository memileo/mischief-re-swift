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
/// Coordinates, all three of them, because getting one wrong is exactly the bug this file
/// exists to prevent:
///   * canvas pixels — y-**down**, row 0 is the document's *top* row (texture row order)
///   * screen pixels — y-**down** (AppKit mouse locations)
///   * view pixels / NDC — y-**up** (the drawable shows clip -1 at the top)
/// `LiveViewSpace` converts screen → view, and every gesture goes through it.
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

    func testClipMatrixFitsNDCWithViewYUp() {
        let clip = LiveViewTransform().clipMatrix(canvasPixelSize: canvas, viewportSize: viewport)
        // Canvas top-left → view (0, 100) → ndc (-1, 100/600*2 - 1)
        assertPoint(clip.applying(CGPoint(x: 0, y: 0)),
                    CGPoint(x: -1, y: 200.0 / 600.0 - 1))
        // Canvas bottom-right → view (800, 500) → ndc (1, 500/600*2 - 1)
        assertPoint(clip.applying(CGPoint(x: 2000, y: 1000)),
                    CGPoint(x: 1, y: 1000.0 / 600.0 - 1))
    }

    /// The whole chain, end to end: the art file's view matrix is the identity, so canvas
    /// row 0 is the document's top row, and from there
    ///
    ///     canvas row 0  →  clip y = +1  →  the top of the drawable
    ///     larger canvas y → smaller clip y
    ///
    /// while `matrix` (the space the gestures work in) keeps y growing downwards. Both
    /// halves are needed: a still frame looks fine even when they disagree, but panning then
    /// runs the wrong way and zoom-to-the-pointer anchors at the mirrored spot.
    func testPresentAndGestureOrientationAgree() {
        // Canvas filling the viewport exactly, so the mapping is not letterboxed.
        //
        // Confirmed on macOS: canvas row 0 is the document's *top* row and the drawable
        // shows clip -1 at the top, so row 0 must land at clip -1. The opposite sign, or a
        // mirror composed on top of this matrix, renders the document upside down.
        let exact = LiveViewTransform().clipMatrix(canvasPixelSize: viewport, viewportSize: viewport)
        XCTAssertEqual(exact.applying(CGPoint(x: 0, y: 0)).y, -1, accuracy: 1e-6,
                       "canvas row 0 must land at the top of the drawable")
        XCTAssertEqual(exact.applying(CGPoint(x: 0, y: viewport.height)).y, 1, accuracy: 1e-6)

        // That means view pixels grow *upward* towards the top of the screen, which is why
        // the gesture layer has to convert (LiveViewSpace) — see below.
        let clip = LiveViewTransform().clipMatrix(canvasPixelSize: canvas, viewportSize: viewport)
        let top = clip.applying(CGPoint(x: 0, y: 0))
        let bottom = clip.applying(CGPoint(x: 0, y: canvas.height))
        XCTAssertGreaterThan(bottom.y, top.y)
    }

    // MARK: - Screen ↔ view space

    /// A screen point maps into view space by mirroring about the viewport height — this is
    /// what keeps zoom-to-the-pointer on the pixel under the cursor.
    func testViewSpacePointMirrorsTheViewport() {
        let converted = LiveViewSpace.point(CGPoint(x: 100, y: 0), viewportHeight: 600)
        assertPoint(converted, CGPoint(x: 100, y: 600))
        let middle = LiveViewSpace.point(CGPoint(x: 10, y: 300), viewportHeight: 600)
        assertPoint(middle, CGPoint(x: 10, y: 300))
    }

    /// A screen movement only has its y negated. Combined with the clip matrix above this
    /// is what makes dragging down move content *down*.
    func testViewSpaceDeltaNegatesY() {
        assertPoint(LiveViewSpace.delta(CGPoint(x: 5, y: 7)), CGPoint(x: 5, y: -7))
        assertPoint(LiveViewSpace.delta(CGPoint(x: -3, y: -7)), CGPoint(x: -3, y: 7))
    }

    /// End to end: a drag of `d` screen pixels downwards must move the content `d` screen
    /// pixels down. Stated in view pixels (a pure translation, so it is exact at any zoom)
    /// and in clip space (where "down the screen" is a *decreasing* clip y).
    func testPanningDownOnScreenMovesContentDownTheScreen() {
        let drag: CGFloat = 12

        var panned = LiveViewTransform()
        panned.pan(by: LiveViewSpace.delta(CGPoint(x: 0, y: drag)))

        let point = CGPoint(x: 500, y: 300)
        let neutral = LiveViewTransform()
        let viewBefore = neutral.matrix(canvasPixelSize: canvas, viewportSize: viewport)
        let viewAfter = panned.matrix(canvasPixelSize: canvas, viewportSize: viewport)

        // In view space the content moved up by exactly the drag distance…
        let before = viewBefore.applying(point)
        let after = viewAfter.applying(point)
        assertPoint(after, CGPoint(x: before.x, y: before.y - drag),
                    "panning must be a pure translation of `drag` view pixels")

        // …and because the drawable shows clip -1 at the top, a smaller clip y *is* further
        // down the screen.
        let clipBefore = neutral.clipMatrix(canvasPixelSize: canvas, viewportSize: viewport)
        let clipAfter = panned.clipMatrix(canvasPixelSize: canvas, viewportSize: viewport)
        // (The clip matrix maps *canvas* -> NDC, so it takes the canvas point; the
        // view-space points above are what it feeds on internally.)
        let clipYBefore = clipBefore.applying(point).y
        let clipYAfter = clipAfter.applying(point).y
        XCTAssertLessThan(clipYAfter, clipYBefore, "content must move down the screen")
        XCTAssertEqual(clipYBefore - clipYAfter, 2.0 * Double(drag) / Double(viewport.height),
                       accuracy: 1e-9)
    }

    func testViewportCentreIsItsOwnMirror() {
        let centre = LiveViewSpace.centre(viewportSize: viewport)
        assertPoint(LiveViewSpace.point(centre, viewportHeight: viewport.height), centre)
    }

    // MARK: - Frame throttle

    func testFrameThrottleCapsRate() {
        let sixtyFps = LiveFrameThrottle(maxFPS: 60)
        XCTAssertEqual(sixtyFps.interval, 1.0 / 60.0, accuracy: 1e-9)
        // Right after a frame: wait out the rest of the interval.
        XCTAssertEqual(sixtyFps.waitTime(now: 10.000, lastFinished: 10.000),
                       1.0 / 60.0, accuracy: 1e-9)
        // Halfway through: half of it.
        XCTAssertEqual(sixtyFps.waitTime(now: 10.000 + 1.0 / 120.0,
                                         lastFinished: 10.000),
                       1.0 / 120.0, accuracy: 1e-9)
        // Longer than the interval: go now, never a negative wait.
        XCTAssertEqual(sixtyFps.waitTime(now: 11.0, lastFinished: 10.0), 0, accuracy: 1e-9)
    }

    func testFrameThrottleUncapped() {
        let uncapped = LiveFrameThrottle(maxFPS: 0)
        XCTAssertTrue(uncapped.isUncapped)
        XCTAssertEqual(uncapped.waitTime(now: 10.0, lastFinished: 10.0), 0)

        let negative = LiveFrameThrottle(maxFPS: -30)
        XCTAssertTrue(negative.isUncapped)
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