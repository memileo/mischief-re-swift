//
//  LiveRenderCache.swift
//  ArtRenderLibrary
//
//  "Process once, re-rasterise per view change" cache for the live view.
//
//  Why this exists
//  --------------
//  The interactive view must re-render the document for the new view matrix — transforming
//  one fixed raster would just magnify it. Re-running the whole pipeline per frame is too
//  slow because most of it is view-independent: parsing, the action walk, paste/merge
//  replay and the recursive Catmull-Rom flattening.
//
//  What is cached
//  --------------
//  Per layer, per op, the **flattened segments produced at a reference transform** (the
//  100% camera). Per frame the camera is applied to those control points and radii — no
//  recursion, no re-parsing, no re-walking.
//
//  Why the re-mapping is faithful
//  -------------------------------
//  `buildOpFromStroke` applies `artToDevice ∘ penAffine` to a stroke's points, so the
//  delta between the reference and the current transform is
//
//      M = artToDevice_now ∘ artToDevice_ref⁻¹  =  camera
//
//  (the pen affine cancels). The camera is a *similarity*: translate + uniform scale +
//  rotate. Under a similarity:
//    - radii scale by the camera's uniform factor, and `buildOpFromStroke`'s radius is
//      exactly linear in the transform scale — so the mapped radius is exact,
//    - `segmentType` (straight / spline / soft envelope) is chosen from radius-relative
//      chord lengths and angles, which a similarity preserves,
//    - the kernel evaluates the SDF per destination pixel, so anti-aliasing is computed
//      at the new scale rather than magnified from the reference one.
//
//  What does *not* transfer: `flattenAndBuild` also uses absolute pixel thresholds
//  (`h_chord > 500`, markers at `10`, "dot" at `< 1`) that decide how finely the curve was
//  flattened. Zoomed far past the reference resolution the cached geometry is therefore
//  coarser than a fresh flatten would be — a curve-fidelity limit, not an AA or position
//  error. Build the cache with headroom if that becomes visible.
//
//  Pastes / merges
//  ---------------
//  A layer containing `paste_layer` / `merge_layer` actions is marked `needsRebuild` and
//  goes through the untouched `buildLayerOperations` + `renderSegmentGroups` path every
//  frame. Those actions carry selection transforms and replayed sub-layers whose cost is
//  dominated by that resolution step, so caching them is not worth the risk; the price is
//  that such documents re-render slower.
//

import Foundation
import ArtParser
#if os(Linux)
import CoreFoundation
import Silica
#elseif os(macOS)
import CoreGraphics
#endif

// NOTE: deliberately **not** wrapped in `#if canImport(Metal)` — nothing in this file
// touches Metal, so the cache and its re-mapping maths type-check (and unit-test) on
// Linux as well.

// MARK: - Cached geometry

/// One stroke, flattened at the reference transform.
public struct LiveCachedStroke {
    public var segments: [GPUSplineSegment]
    public var color: SIMD4<Float>
    public var isEraser: Bool
    public var isMarker: Bool
}

/// One cached op, in document space (nothing here depends on the current view).
public enum LiveCachedOp {
    case stroke(LiveCachedStroke)
    /// Selection rect + the transform that maps the destination into that selection
    /// frame (`m1` in `Renderer.buildLayerOperations`). Recomposed into a `CutMeta` per
    /// view change.
    case cut(rect: [Float], selectionFrame: CGAffineTransform)
}

/// A visible layer, ready to be re-rasterised for any view.
public struct LiveCachedLayer {
    public let layerIndex: Int
    public let opacity: Float
    /// Layer matrix → document space.
    public let layerTransform: CGAffineTransform
    public let ops: [LiveCachedOp]
    /// Contains paste/merge actions: rebuilt every frame instead of replayed from cache.
    public let needsRebuild: Bool
    public var cachedSegmentCount: Int {
        ops.reduce(0) { total, op in
            if case .stroke(let s) = op { return total + s.segments.count }
            return total
        }
    }
}

/// Everything the interactive view needs, built once per document.
public final class LiveRenderCache {
    /// Document units → canvas pixels at 100% (the reference transform's view part).
    public let baseTransform: CGAffineTransform
    public let layers: [LiveCachedLayer]
    public let segmentCount: Int
    /// Always true: an over-budget document returns nil instead of a partial cache, so
    /// callers only ever get a complete cache.
    public let withinBudget: Bool
    /// Layers that must be rebuilt per frame (paste/merge).
    public let rebuildingLayers: Int

    init(baseTransform: CGAffineTransform,
         layers: [LiveCachedLayer],
         segmentCount: Int,
         withinBudget: Bool) {
        self.baseTransform = baseTransform
        self.layers = layers
        self.segmentCount = segmentCount
        self.withinBudget = withinBudget
        self.rebuildingLayers = layers.filter { $0.needsRebuild }.count
    }
}

// MARK: - Small transform helpers

/// `CGAffineTransform.inverted()` returns an optional value on CoreGraphics but a plain
/// value on Silica, so the inversion is spelled out here once.
@inline(__always)
func invert(_ t: CGAffineTransform) -> CGAffineTransform? {
    let det = t.a * t.d - t.b * t.c
    guard det != 0, det.isFinite else { return nil }
    let ia = t.d / det, ib = -t.b / det
    let ic = -t.c / det, id = t.a / det
    return CGAffineTransform(a: ia, b: ib, c: ic, d: id,
                             tx: -(ia * t.tx + ic * t.ty),
                             ty: -(ib * t.tx + id * t.ty))
}

// MARK: - Per-frame ops

/// A cached op with the camera applied — what the GPU actually rasterises.
public enum LiveDeviceOp {
    case stroke(segments: [GPUSplineSegment], color: SIMD4<Float>, isEraser: Bool, isMarker: Bool)
    case cut(meta: CutMeta)
}

// MARK: - Re-mapping

extension LiveRenderCache {
    /// Applies the camera to one layer's cached ops.
    ///
    /// - Parameters:
    ///   - camera: the document-space camera, i.e. canvas px (at 100%) → view px.
    /// - Returns: nil for a `needsRebuild` layer (those are re-walked per frame instead).
    public func deviceOps(forLayerAt index: Int, camera: CGAffineTransform) -> [LiveDeviceOp]? {
        guard index < layers.count else { return nil }
        let layer = layers[index]
        guard !layer.needsRebuild else { return nil }
        
        // Uniform scale of the similarity transform; radii multiply by this.
        let scaleX = sqrt(camera.a * camera.a + camera.c * camera.c)
        let scaleY = sqrt(camera.b * camera.b + camera.d * camera.d)
        let radiusFactor = Float((scaleX + scaleY) / 2.0)
        
        var ops: [LiveDeviceOp] = []
        ops.reserveCapacity(layer.ops.count)
        
        for cached in layer.ops {
            switch cached {
                case .stroke(let stroke):
                    ops.append(.stroke(segments: Self.remap(stroke.segments,
                                                            camera: camera,
                                                            radiusFactor: radiusFactor),
                                        color: stroke.color,
                                        isEraser: stroke.isEraser,
                                        isMarker: stroke.isMarker))
                case .cut(let rect, let selectionFrame):
                    // `buildLayerOperations` builds cuts against the *base* transform
                    // (no layer matrix), so the live version uses camera ∘ base.
                    let liveBase = camera.concatenating(baseTransform)
                    guard let inverse = invert(liveBase) else { continue }
                    ops.append(.cut(meta: CutMeta(inverseAffine: inverse.concatenating(selectionFrame),
                                                  rect: rect, edgeWidth: 0.75)))
            }
        }
        return ops
    }
    
    /// Transform of `liveBase` for a rebuilt layer: camera ∘ base ∘ layer.
    public func artToDevice(layerAt index: Int, camera: CGAffineTransform) -> CGAffineTransform? {
        guard index < layers.count else { return nil }
        return camera
            .concatenating(baseTransform)
            .concatenating(layers[index].layerTransform)
    }
    
    /// camera ∘ baseTransform — the transform cuts (and the paper) are expressed in.
    public func liveBaseTransform(camera: CGAffineTransform) -> CGAffineTransform {
        camera.concatenating(baseTransform)
    }
    
    /// Applies a similarity transform to a flattened segment list.
    ///
    /// Control points move, radii scale; `segmentType`, opacity and the noise seed are
    /// scale-invariant under a similarity and are copied through untouched.
    static func remap(_ segments: [GPUSplineSegment],
                      camera: CGAffineTransform,
                      radiusFactor: Float) -> [GPUSplineSegment] {
        guard !segments.isEmpty else { return [] }
        let a = Float(camera.a), b = Float(camera.b)
        let c = Float(camera.c), d = Float(camera.d)
        let tx = Float(camera.tx), ty = Float(camera.ty)
        let identityLike = (a == 1 && b == 0 && c == 0 && d == 1 && tx == 0 && ty == 0)
        let noRadiusChange = (radiusFactor == 1)
        
        var out = [GPUSplineSegment]()
        out.reserveCapacity(segments.count)
        for var s in segments {
            if !identityLike {
                let p0 = SIMD2<Float>(a * s.p0.x + c * s.p0.y + tx, b * s.p0.x + d * s.p0.y + ty)
                let p1 = SIMD2<Float>(a * s.p1.x + c * s.p1.y + tx, b * s.p1.x + d * s.p1.y + ty)
                let p2 = SIMD2<Float>(a * s.p2.x + c * s.p2.y + tx, b * s.p2.x + d * s.p2.y + ty)
                let p3 = SIMD2<Float>(a * s.p3.x + c * s.p3.y + tx, b * s.p3.x + d * s.p3.y + ty)
                s.p0 = p0; s.p1 = p1; s.p2 = p2; s.p3 = p3
            }
            if !noRadiusChange {
                s.radius0 *= radiusFactor
                s.radius1 *= radiusFactor
            }
            out.append(s)
        }
        return out
    }
}
