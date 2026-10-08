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

// MARK: - Canvas row order

/// Which way round the live canvas texture is presented.
///
/// Measured on macOS 14/15 (Apple silicon): presenting the canvas with **row 0 at the top**
/// of the drawable shows the document upside down — even though the *same* texture is
/// upright in the static CoreGraphics path, which draws it row 0-at-top inside a y-flipped
/// context. That asymmetry is not explained, so this is the single place that states which
/// way round the canvas goes; everything else defaults to it.
///
/// `Settings.mirrorLiveCanvas` (app) / `art2png --no-flip-y` mirror it back for a display
/// that behaves the other way round.
public enum LiveCanvasRowOrder {
    /// Mirror the canvas vertically when presenting it.
    public static let presentsMirrored = true
}

// MARK: - Transform

/// User-controlled view transform for the live preview. Value type: every gesture
/// produces a new value, so resets are trivially composable.
public struct LiveViewTransform: Equatable {
    /// Zoom clamps. 100% == the file's own view matrix (aspect fitted to the view).
    public static let zoomRange: ClosedRange<CGFloat> = 0.05...64

    /// Pan offset in view pixels (y down).
    public private(set) var pan: CGPoint = .zero
    /// 1.0 == "as the file shows it".
    public private(set) var zoom: CGFloat = 1
    /// Rotation in radians, around the view centre.
    public private(set) var rotation: CGFloat = 0

    public init() {}

    // MARK: Derived state

    public var zoomPercent: Double { Double(zoom * 100) }

    /// True when nothing is applied on top of the file's view matrix, i.e. a redraw
    /// request with this transform is a no-op.
    public var isNeutral: Bool {
        pan == .zero && zoom == 1 && rotation == 0
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

    // MARK: Resets

    /// Full reset: back to the view matrix stored in the file (zoom 100%, no pan,
    /// no rotation).
    @discardableResult
    public mutating func resetAll() -> LiveViewTransform {
        pan = .zero
        zoom = 1
        rotation = 0
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

    /// Reset the rotation component only.
    @discardableResult
    public mutating func resetRotation() -> LiveViewTransform {
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

        // Linear part: [a b; c d] = s·R  (R = rotation by `rotation`).
        let a =  cr, b = sr
        let c = -sr, d = cr

        // Translation so that the canvas centre lands on viewCentre + pan.
        let canvasCentre = CGPoint(x: cw / 2, y: ch / 2)
        let centreX = vw / 2, centreY = vh / 2
        let tx = centreX + pan.x - (a * canvasCentre.x + c * canvasCentre.y)
        let ty = centreY + pan.y - (b * canvasCentre.x + d * canvasCentre.y)

        return LiveViewMatrix(a: a, b: b, c: c, d: d, tx: tx, ty: ty)
    }

    /// Canvas pixels → Metal clip space.
    ///
    /// Composes `matrix(canvasPixelSize:viewportSize:)` with the view-pixels → NDC step
    /// (NDC is y-up, our pixels are y-down, so the document comes out upright):
    ///
    ///     ndc.x =  viewX / viewW * 2 - 1
    ///     ndc.y = 1 - viewY / viewH * 2
    public func clipMatrix(canvasPixelSize: CGSize, viewportSize: CGSize) -> LiveViewMatrix {
        let view = matrix(canvasPixelSize: canvasPixelSize, viewportSize: viewportSize)
        let sx = 2.0 / max(viewportSize.width, 1)
        let sy = -2.0 / max(viewportSize.height, 1)
        // [sx 0 -1; 0 sy 1] · view
        return LiveViewMatrix(a: sx * view.a, b: sy * view.b,
                              c: sx * view.c, d: sy * view.d,
                              tx: sx * view.tx - 1.0,
                              ty: sy * view.ty + 1.0)
    }
}