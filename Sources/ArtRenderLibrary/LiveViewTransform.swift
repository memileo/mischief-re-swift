//
//  LiveViewTransform.swift
//  ArtRenderLibrary
//
//  Pan / zoom / rotate state for the live Metal view, plus the anchor-preserving
//  gesture math and the reset operations.
//
//  The live view renders the document once into a canvas texture (the art file's own
//  view matrix is already baked into that canvas). Everything the user does is a
//  *view* transform on top of it:
//
//      viewPos = viewCentre + R(rotation) · (zoom · fit · (canvasPos - canvasCentre)) + pan
//
//  `zoom == 1`, `pan == 0`, `rotation == 0` is therefore exactly "what the file's
//  view matrix says", which is what `resetAll()` restores.
//
//  Coordinates: view pixels are AppKit-style (origin top-left, y down), matching
//  NSEvent locations and the canvas texture row order.
//

import Foundation
#if os(Linux)
import CoreFoundation
import Silica
#elseif os(macOS)
import CoreGraphics
#endif

// MARK: - Matrix

/// A plain 2×3 affine matrix with Quartz/CoreGraphics conventions:
/// `x' = a·x + c·y + tx`, `y' = b·x + d·y + ty`.
///
/// Deliberately hand-rolled (instead of leaning on CGAffineTransform's rotation /
/// concatenation API) so the file compiles unchanged on Linux (Silica).
public struct LiveViewMatrix: Equatable {
    public var a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat

    public static let identity = LiveViewMatrix(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public init(a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat) {
        self.a = a; self.b = b; self.c = c; self.d = d; self.tx = tx; self.ty = ty
    }

    public func applying(_ p: CGPoint) -> CGPoint {
        CGPoint(x: a * p.x + c * p.y + tx,
                y: b * p.x + d * p.y + ty)
    }

    /// Inverse mapping (view point → input point). Returns nil for a degenerate matrix.
    public func inverted() -> LiveViewMatrix? {
        let det = a * d - b * c
        guard det != 0, det.isFinite else { return nil }
        let ia =  d / det
        let ib = -b / det
        let ic = -c / det
        let id =  a / det
        return LiveViewMatrix(a: ia, b: ib, c: ic, d: id,
                              tx: -(ia * tx + ic * ty),
                              ty: -(ib * tx + id * ty))
    }

    /// `self` then `other`, i.e. apply `self` first.
    public func concatenated(with other: LiveViewMatrix) -> LiveViewMatrix {
        LiveViewMatrix(a: other.a * a + other.c * b,
                       b: other.b * a + other.d * b,
                       c: other.a * c + other.c * d,
                       d: other.b * c + other.d * d,
                       tx: other.a * tx + other.c * ty + other.tx,
                       ty: other.b * tx + other.d * ty + other.ty)
    }

    /// Column-major 3×3 as the Metal shader expects it:
    /// `col0 = (a, b, 0)`, `col1 = (c, d, 0)`, `col2 = (tx, ty, 1)`.
    public var metalColumns: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) {
        (SIMD3(Float(a), Float(b), 0),
         SIMD3(Float(c), Float(d), 0),
         SIMD3(Float(tx), Float(ty), 1))
    }

    public var affineTransform: CGAffineTransform {
        CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }
}

// MARK: - Screen ↔ view space

/// The live view's coordinate conversions, in one tested place.
///
/// `clipMatrix` maps canvas pixels to the drawable with `ndc.y = viewY / viewH * 2 - 1`,
/// and the drawable shows clip `-1` at the top — so **view pixels are y-up** while AppKit
/// reports mouse locations y-down. The gestures therefore convert at the boundary:
///
///   - an *anchor* (a point on screen) is mirrored about the viewport height,
///   - a *delta* (a movement) only has its y negated.
///
/// Rotation needs no sign flip: the same mirror that makes view space y-up also makes a
/// positive rotation appear clockwise on screen, so dragging right still rotates clockwise.
public enum LiveViewSpace {
    /// Screen point (y-down, view pixels) → this transform's view space (y-up).
    public static func point(_ screenPoint: CGPoint, viewportHeight: CGFloat) -> CGPoint {
        CGPoint(x: screenPoint.x, y: viewportHeight - screenPoint.y)
    }

    /// Screen movement (y-down) → view-space movement (y-up).
    public static func delta(_ screenDelta: CGPoint) -> CGPoint {
        CGPoint(x: screenDelta.x, y: -screenDelta.y)
    }

    /// Viewport centre — its own mirror, so it is the same point in both spaces, but
    /// routing it through here keeps the call sites honest.
    public static func centre(viewportSize: CGSize) -> CGPoint {
        CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
    }

    /// Radius of the rotation dead zone ("hub") in view pixels. Shared by every
    /// live view so the gesture and its visual ring agree.
    public static let minRotateRadius: CGFloat = 32
}

/// Rate limiter for the interactive path, shared by the Quick Look preview and the app's
/// document windows: a request that arrives before the next slot waits instead of
/// rendering a frame the display cannot show.
public struct LiveFrameThrottle {
    /// 0 means uncapped.
    public let interval: TimeInterval

    public init(maxFPS: Double) {
        interval = maxFPS > 0 ? 1.0 / maxFPS : 0
    }

    public var isUncapped: Bool { interval <= 0 }

    /// How long `now` must wait before the next render may start, given that the previous
    /// one started at `lastStarted`. 0 means "go now".
    ///
    /// Pacing is start-to-start, not finish-to-start. Timing the gap from the *end* of the
    /// previous render adds the render time on top of the interval: a 10 ms frame on a
    /// 60 fps cap then waited another 16.7 ms after finishing, i.e. a 26.7 ms cycle (37 fps)
    /// with a visible idle gap between every pair of frames — the stutter a cap is supposed
    /// to prevent. Start-to-start keeps a steady 60 Hz cadence whenever a frame fits.
    public func waitTime(now: TimeInterval, lastStarted: TimeInterval) -> TimeInterval {
        guard !isUncapped else { return 0 }
        let remaining = interval - (now - lastStarted)
        return remaining > 0 ? remaining : 0
    }
}

// MARK: - Transform

/// User-controlled view transform for the live preview. Value type: every gesture
/// produces a new value, so resets are trivially composable.
public struct LiveViewTransform: Equatable {
    /// Zoom clamps. 100% == the file's own view matrix (aspect fitted to the view).
    public static let zoomRange: ClosedRange<CGFloat> = 0.001...4096

    /// Radius of the rotation dead zone ("hub") in view pixels.
    public static let minRotateRadius: CGFloat = LiveViewSpace.minRotateRadius

    /// Pan offset in view pixels (y down).
    public private(set) var pan: CGPoint = .zero
    /// 1.0 == "as the file shows it".
    public private(set) var zoom: CGFloat = 1
    /// Rotation in radians, around the view centre.
    public private(set) var rotation: CGFloat = 0
    /// Mirror the canvas horizontally.
    public private(set) var flipHorizontal: Bool = false
    /// Mirror the canvas vertically.
    public private(set) var flipVertical: Bool = false

    public init() {}

    // MARK: Derived state

    public var zoomPercent: Double { Double(zoom * 100) }

    /// True when nothing is applied on top of the file's view matrix, i.e. a redraw
    /// request with this transform is a no-op.
    public var isNeutral: Bool {
        pan == .zero && zoom == 1 && rotation == 0 && !flipHorizontal && !flipVertical
    }

    // MARK: - Flip aliases (kept for callers/tests that use other names)

    public var flippedHorizontally: Bool {
        get { flipHorizontal }
        set { flipHorizontal = newValue }
    }
    public var flippedVertically: Bool {
        get { flipVertical }
        set { flipVertical = newValue }
    }
    public var flipH: Bool {
        get { flipHorizontal }
        set { flipHorizontal = newValue }
    }
    public var flipV: Bool {
        get { flipVertical }
        set { flipVertical = newValue }
    }

    // MARK: Gestures

    /// Translate the view by `delta` view pixels (y down).
    @discardableResult
    public mutating func pan(by delta: CGPoint) -> LiveViewTransform {
        pan = CGPoint(x: pan.x + delta.x, y: pan.y + delta.y)
        return self
    }

    /// Multiply the zoom by `factor`, keeping the canvas point currently under
    /// `anchor` (view pixels) exactly where it is.
    @discardableResult
    public mutating func zoom(by factor: CGFloat, anchor: CGPoint, viewportSize: CGSize) -> LiveViewTransform {
        guard factor.isFinite, factor > 0 else { return self }
        let current = zoom
        let target = min(max(current * factor, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
        guard target != current else { return self }
        let ratio = target / current
        // The whole content transform scales by `ratio`, so the pan (which is applied in
        // view pixels *after* it) scales too:
        //     pan' = ratio · pan + (1 - ratio) · (anchor - centre)
        // which is what keeps the canvas point under `anchor` pinned there.
        let centre = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        pan = CGPoint(x: ratio * pan.x + (1 - ratio) * (anchor.x - centre.x),
                      y: ratio * pan.y + (1 - ratio) * (anchor.y - centre.y))
        zoom = target
        return self
    }

    /// Rotate by `delta` radians around `anchor` (view pixels).
    @discardableResult
    public mutating func rotate(by delta: CGFloat, anchor: CGPoint, viewportSize: CGSize) -> LiveViewTransform {
        guard delta.isFinite, delta != 0 else { return self }
        let centre = CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2)
        let rel = CGPoint(x: anchor.x - centre.x - pan.x,
                          y: anchor.y - centre.y - pan.y)
        let (s, c) = (sin(delta), cos(delta))
        // pan' = anchor - centre - Rot(delta)·(anchor - centre - pan)
        pan = CGPoint(x: anchor.x - centre.x - (c * rel.x - s * rel.y),
                      y: anchor.y - centre.y - (s * rel.x + c * rel.y))
        rotation += delta
        return self
    }

    // MARK: Flip
    //
    // The projection applies flip in view space (`F·s·R`, "last"), mirroring the image
    // around the viewport centre. Compensate `pan` on toggle so the canvas point under
    // the viewport centre stays pinned: with view-space flip, that is just negating the
    // flipped pan component.

    /// Toggle the horizontal flip, keeping the current view centre pinned.
    @discardableResult
    public mutating func flipHorizontally() -> LiveViewTransform {
        flipHorizontal.toggle()
        pan.x = -pan.x
        return self
    }

    /// Toggle the vertical flip, keeping the current view centre pinned.
    @discardableResult
    public mutating func flipVertically() -> LiveViewTransform {
        flipVertical.toggle()
        pan.y = -pan.y
        return self
    }

    /// Toggle horizontal flip (alias), keeping the current view centre pinned.
    @discardableResult
    public mutating func toggleFlipHorizontal() -> LiveViewTransform { flipHorizontally() }

    /// Toggle vertical flip (alias), keeping the current view centre pinned.
    @discardableResult
    public mutating func toggleFlipVertical() -> LiveViewTransform { flipVertically() }

    /// Toggle horizontal flip (alias), keeping the current view centre pinned.
    @discardableResult
    public mutating func toggleHorizontalFlip() -> LiveViewTransform { flipHorizontally() }

    /// Toggle vertical flip (alias), keeping the current view centre pinned.
    @discardableResult
    public mutating func toggleVerticalFlip() -> LiveViewTransform { flipVertically() }

    /// Set the flip state explicitly.
//    @discardableResult
//    public mutating func setFlip(horizontal: Bool? = nil, vertical: Bool? = nil) -> LiveViewTransform {
//        if let h = horizontal { flipHorizontal = h }
//        if let v = vertical { flipVertical = v }
//        return self
//    }

    /// Set the flip state explicitly (alias).
    // Unused?
//    @discardableResult
//    public mutating func setFlipped(horizontal: Bool? = nil, vertical: Bool? = nil) -> LiveViewTransform {
//        setFlip(horizontal: horizontal, vertical: vertical)
//    }

    // MARK: Resets

    /// Full reset: back to the view matrix stored in the file (zoom 100%, no pan,
    /// no rotation).
    @discardableResult
    public mutating func resetAll() -> LiveViewTransform {
        pan = .zero
        zoom = 1
        rotation = 0
        flipHorizontal = false
        flipVertical = false
        return self
    }

    /// Reset the pan component only.
    @discardableResult
    public mutating func resetPan() -> LiveViewTransform {
        pan = .zero
        return self
    }

    /// Reset the zoom component only.
    @discardableResult
    public mutating func resetZoom() -> LiveViewTransform {
        zoom = 1
        return self
    }

    /// Reset the zoom component only, keeping the canvas point currently under the
    /// view centre pinned so the artwork does not jump out of frame.
    @discardableResult
    public mutating func resetZoom(viewportSize: CGSize) -> LiveViewTransform {
        resetZoom(anchor: LiveViewSpace.centre(viewportSize: viewportSize),
                  viewportSize: viewportSize)
    }

    /// Reset the zoom component only, keeping the canvas point currently under
    /// `anchor` pinned so the artwork does not jump out of frame.
    @discardableResult
    public mutating func resetZoom(anchor: CGPoint, viewportSize: CGSize) -> LiveViewTransform {
        let current = zoom
        if current != 1 {
            zoom(by: 1 / current, anchor: anchor, viewportSize: viewportSize)
        }
        zoom = 1
        return self
    }

    /// Reset the rotation component only.
    @discardableResult
    public mutating func resetRotation() -> LiveViewTransform {
        rotation = 0
        return self
    }

    /// Reset the rotation component only, keeping the canvas point currently under
    /// the view centre pinned so the artwork does not jump out of frame.
    @discardableResult
    public mutating func resetRotation(viewportSize: CGSize) -> LiveViewTransform {
        resetRotation(anchor: LiveViewSpace.centre(viewportSize: viewportSize),
                      viewportSize: viewportSize)
    }

    /// Reset the rotation component only, keeping the canvas point currently under
    /// `anchor` pinned so the artwork does not jump out of frame.
    @discardableResult
    public mutating func resetRotation(anchor: CGPoint, viewportSize: CGSize) -> LiveViewTransform {
        if rotation != 0 {
            rotate(by: -rotation, anchor: anchor, viewportSize: viewportSize)
        }
        rotation = 0
        return self
    }

    // MARK: Projection

    /// Canvas pixels → view pixels.
    ///
    /// - Parameters:
    ///   - canvasPixelSize: size of the rendered canvas texture in pixels.
    ///   - viewportSize: size of the view's *pixel* bounds (drawable size).
    public func matrix(canvasPixelSize: CGSize, viewportSize: CGSize) -> LiveViewMatrix {
        let cw = max(canvasPixelSize.width, 1)
        let ch = max(canvasPixelSize.height, 1)
        let vw = max(viewportSize.width, 1)
        let vh = max(viewportSize.height, 1)

        // Aspect-fit the canvas into the viewport, then apply the user's zoom/rotation.
        let fit = min(vw / cw, vh / ch)
        let s = zoom * fit
        let (sr, cr) = (sin(rotation) * s, cos(rotation) * s)

        // Flip factors in canvas space: a horizontal flip mirrors the canvas x axis.
        let fx: CGFloat = flipHorizontal ? -1 : 1
        let fy: CGFloat = flipVertical ? -1 : 1

        // Linear part: [a b; c d] = s·R·F  (F = flip). flip applied last
        let a =  cr * fx, b = sr * fy
        let c = -sr * fx, d = cr * fy

        // Translation so that the canvas centre lands on viewCentre + pan.
        let canvasCentre = CGPoint(x: cw / 2, y: ch / 2)
        let centreX = vw / 2, centreY = vh / 2
        let tx = centreX + pan.x - (a * canvasCentre.x + c * canvasCentre.y)
        let ty = centreY + pan.y - (b * canvasCentre.x + d * canvasCentre.y)

        return LiveViewMatrix(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    /// Canvas pixels → Metal clip space.
///
/// Composes `matrix(canvasPixelSize:viewportSize:)` with the view-pixels → clip-space step.
///
///     ndc.x = viewX / viewW * 2 - 1
///     ndc.y = viewY / viewH * 2 - 1
///
/// **Conventions, all verified on macOS — do not "simplify" either half away.**
///
/// * Canvas row 0 is the document's *top* row. The art file's view matrix is the identity
///   for most documents, so canvas row index == document y, and the CPU path (which has no
///   context flip) matches the Mischief-exported references non-flipped.
/// * The drawable this presents into shows clip `-1` at the top, so canvas row 0 lands at
///   ndc -1 and the document comes out upright. That mapping is the one confirmed visually;
///   a mirror composed on top of it (take 4b) or the opposite sign (take 4c) both render
///   upside down.
/// * Because the drawable's axis is opposite to the canvas' own, *view* pixels are y-**up**
///   while AppKit hands out y-**down** points. That conversion is
///   `LiveViewTransform.viewSpacePoint(_:viewportHeight:)` / `viewSpaceDelta(_:)`, and every
///   gesture goes through it. Skipping it leaves a still frame looking correct while
///   vertical panning runs backwards and zoom-to-the-pointer anchors at the mirrored spot
///   (LIVE_VIEW.md §9.4/§9.6).
    public func clipMatrix(canvasPixelSize: CGSize, viewportSize: CGSize) -> LiveViewMatrix {
        let view = matrix(canvasPixelSize: canvasPixelSize, viewportSize: viewportSize)
        let sx = 2.0 / max(viewportSize.width, 1)
        let sy = 2.0 / max(viewportSize.height, 1)
        // [sx 0 -1; 0 sy -1] · view
        //
        // - Note the positive sy and the -1 offset: the drawable shows clip -1 at the top,
        //   which is what puts canvas row 0 (the document's top) at the top of the screen.
        //   `matrix` above is y-up in view pixels — see the orientation notes on this method.
        return LiveViewMatrix(a: sx * view.a, b: sy * view.b,
                              c: sx * view.c, d: sy * view.d,
                              tx: sx * view.tx - 1.0,
                              ty: sy * view.ty - 1.0)
    }
}
