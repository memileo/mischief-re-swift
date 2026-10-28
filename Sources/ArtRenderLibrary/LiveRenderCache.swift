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
//  Also in here
//  -------------
//  `LiveFrameTiming` — where an interactive frame's time went — and
//  `buildLiveRenderCacheGeometry`, the cache builder, both here so this feature stays in
//  files the library target already compiles (see the note below).
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
// touches Metal, so the cache, its builder, the frame timing and the re-mapping maths
// type-check (and unit-test) on Linux as well.

// MARK: - Cached geometry

/// One stroke, flattened at the reference transform.
public struct LiveCachedStroke {
    public var segments: [GPUSplineSegment]
    public var color: SIMD4<Float>
    public var isEraser: Bool
    public var isMarker: Bool
    /// Conservative bounds of the stroke's *ink* (control points expanded by the radii the
    /// kernel actually paints), in the same reference space as `segments`. Used to skip
    /// strokes that are off screen after the camera is applied.
    public var bounds: CGRect

    /// Ink bounds of a flattened stroke, padded generously: the padding only ever costs an
    /// extra stroke or two being rasterised, while a too-small box would clip ink.
    public static func referenceBounds(of segments: [GPUSplineSegment],
                                       isMarker: Bool) -> CGRect {
        guard let first = segments.first else { return .zero }
        var minX = min(first.p1.x, first.p2.x)
        var maxX = max(first.p1.x, first.p2.x)
        var minY = min(first.p1.y, first.p2.y)
        var maxY = max(first.p1.y, first.p2.y)
        for s in segments {
            minX = min(minX, min(s.p1.x, s.p2.x))
            maxX = max(maxX, max(s.p1.x, s.p2.x))
            minY = min(minY, min(s.p1.y, s.p2.y))
            maxY = max(maxY, max(s.p1.y, s.p2.y))
        }
        // The kernel sweeps a stroke's radius (plus, for markers, a soft envelope) around
        // every sample point; markers additionally get their radius applied twice.
        let radius = segments.reduce(Float(0)) { max($0, max($1.radius0, $1.radius1)) }
        let pad = radius * (isMarker ? 4 : 2) + 2
        return CGRect(x: CGFloat(minX) - CGFloat(pad),
                      y: CGFloat(minY) - CGFloat(pad),
                      width: CGFloat(maxX - minX) + 2 * CGFloat(pad),
                      height: CGFloat(maxY - minY) + 2 * CGFloat(pad))
    }
}

/// One mask of a cached paste, captured at the reference camera.
public struct LiveCachedPasteMask {
    /// Source device → selection frame (reference camera).
    public var inv: CGAffineTransform
    public var rect: SIMD4<Float>       // x, y, w, h in the selection frame
    public var erase: Bool
}

/// One paste/merge op captured at the reference camera.
///
/// The camera change is a similarity applied on the *outside* of every map, so each
/// field remaps with a single conjugation (see `deviceOps`):
///   - segments move by `camera` (radius scales with it),
///   - `invAffine` (dst → src) becomes `C ∘ D_ref ∘ C⁻¹`,
///   - `sourceToDestination` becomes `C ∘ D_ref ∘ C⁻¹`,
///   - a mask's `inv` (src → selection) becomes `inv_ref ∘ C⁻¹`.
public struct LiveCachedPaste {
    public var segments: [GPUSplineSegment]
    public var color: SIMD4<Float>
    public var isEraser: Bool
    public var isMarker: Bool
    public var invAffine: CGAffineTransform         // dst device → src device
    public var masks: [LiveCachedPasteMask]
    public var sourceToDestination: CGAffineTransform
    public var isMerge: Bool
    public var mergeID: UInt64
}

/// One cached op, in document space (nothing here depends on the current view).
public enum LiveCachedOp {
    case stroke(LiveCachedStroke)
    /// Selection rect + the transform that maps the destination into that selection
    /// frame (`m1` in `Renderer.buildLayerOperations`). Recomposed into a `CutMeta` per
    /// view change.
    case cut(rect: [Float], selectionFrame: CGAffineTransform)
    /// A paste/merge, its flattened source geometry captured at the reference camera.
    case paste(LiveCachedPaste)
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
    /// Per-stroke reference-space ink bounds / marker flags, flat and in stroke order, and
    /// whether any cut op is present. Derived here so the per-frame cull can walk two
    /// plain arrays: iterating `ops` instead means pattern-matching an enum whose `.stroke`
    /// payload carries a segment array, and scanning it twice (cut test + cull) cost
    /// ~1.0 ms per frame on kaos' 2214 strokes. Exact by construction — same `bounds`.
    public let strokeBounds: [CGRect]
    public let strokeIsMarker: [Bool]
    public let hasCut: Bool
    public let hasPaste: Bool

    init(layerIndex: Int, opacity: Float, layerTransform: CGAffineTransform,
         ops: [LiveCachedOp], needsRebuild: Bool) {
        self.layerIndex = layerIndex
        self.opacity = opacity
        self.layerTransform = layerTransform
        self.ops = ops
        self.needsRebuild = needsRebuild
        var bounds: [CGRect] = []
        var markers: [Bool] = []
        var cut = false
        var paste = false
        bounds.reserveCapacity(ops.count)
        markers.reserveCapacity(ops.count)
        for op in ops {
            switch op {
                case .stroke(let s):
                    bounds.append(s.bounds)
                    markers.append(s.isMarker)
                case .cut:
                    cut = true
                case .paste:
                    paste = true
            }
        }
        self.strokeBounds = bounds
        self.strokeIsMarker = markers
        self.hasCut = cut
        self.hasPaste = paste
    }

    public var cachedSegmentCount: Int {
        ops.reduce(0) { total, op in
            switch op {
                case .stroke(let s): return total + s.segments.count
                case .paste(let p): return total + p.segments.count
                case .cut: return total
            }
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

// MARK: - Frame timing

/// Where the time of one interactive (cached) live frame went.
///
/// The interactive path re-rasterises the visible document whenever the view matrix
/// changes, so when it is slow there are three very different suspects:
///
///   - `bin`     CPU: re-mapping the cached geometry onto the camera + tile binning
///   - `encode`  CPU: writing the Metal dispatches
///   - `gpu`     GPU: the dispatches themselves, up to `waitUntilCompleted`
///
/// Measured unconditionally (a few `DispatchTime.now()` calls) and published as
/// `Renderer.lastLiveFrameTiming`, so `art2png --live-view` can print it and the Quick Look
/// extension can log a breakdown only for frames that were actually slow.
public struct LiveFrameTiming {
    /// Cached layers rasterised this frame (the fast path).
    public var cachedLayers = 0
    /// Paste/merge layers re-walked this frame (the slow, uncached path).
    public var rebuiltLayers = 0
    /// Strokes handed to the GPU (after off-screen culling).
    public var strokes = 0
    /// Strokes the cache had but that were culled because they are off screen.
    public var culledStrokes = 0
    /// Segments handed to the GPU.
    public var segments = 0

    // Debug / analysis counters for the per-stroke tile-box dispatch (filled in `bin`).
    /// Tiles inside the strokes' bounding boxes (dispatched; ×threadgroups per tile = tg count).
    public var dispatchedTiles = 0
    /// Tiles that actually contain a segment (the real work).
    public var inkedTiles = 0
    /// Distance-field lookups the kernels will perform this frame (segment incidences × tile px).
    public var sdfEvaluations = 0

    /// Per-frame CPU planning (cull + tile table + sort plan + uploads). Excludes buffer
    /// allocation, which is a cold-start cost and used to hide inside this number.
    public var binMilliseconds = 0.0
    /// Metal buffer allocation / growth. Only the first frames pay it; reported separately
    /// so a one-shot `art2png --live-view` run cannot be mistaken for steady state.
    public var allocMilliseconds = 0.0
    public var encodeMilliseconds = 0.0
    /// Time spent inside `waitUntilCompleted`, i.e. GPU execution (plus any stall).
    public var gpuMilliseconds = 0.0
    /// Paper/background pass (its own command buffer + wait).
    public var paperMilliseconds = 0.0
    /// Whole `renderLive(cache:…)` call.
    public var totalMilliseconds = 0.0

    public var summary: String {
        String(format: "%.0f ms total (bin %.0f, alloc %.0f, encode %.0f, gpu %.0f, paper %.0f) — "
                       + "%d strokes / %d segments, %d layers cached, %d rebuilt, %d culled "
                       + "| %d box tiles, %d ink tiles, %lld sdf",
               totalMilliseconds, binMilliseconds, allocMilliseconds, encodeMilliseconds,
               gpuMilliseconds, paperMilliseconds, strokes, segments, cachedLayers,
               rebuiltLayers, culledStrokes, dispatchedTiles, inkedTiles, sdfEvaluations)
    }
}

extension Renderer {
    /// Prints the per-stage breakdown after every interactive render. `art2png --live-view`
    /// turns this on.
    public static var livePathTiming = false
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
    case paste(segments: [GPUSplineSegment], color: SIMD4<Float>,
               isEraser: Bool, isMarker: Bool,
               meta: PasteLayerMeta, masks: [PasteMask],
               sourceToDestinationGPU: CGAffineTransform,
               isMerge: Bool, mergeID: UInt64)
}

/// Per-tile eligibility (pure; unit-tested on Linux). The per-tile kernels implement the
/// plain AA composite and the noise composite, both grouped by stroke with per-stroke
/// 8-bit quantisation — so any layer without cuts is eligible, noise and markers included.
/// The one exception: markers need the chisel SDF, which only the **AA** per-tile kernel
/// implements. `needsNoise` picks the noise kernel for the whole layer, so a layer that
/// holds both a marker and a noisy segment stays on the per-stroke path (still exact, one
/// dispatch per stroke). Cuts erase below them, so ordering forces the per-stroke path.
public enum LivePerTileEligibility {
    public static func isEligible(_ ops: [LiveDeviceOp]) -> Bool {
        var hasMarker = false
        var hasNoise = false
        for op in ops {
            switch op {
            case .cut, .paste:
                return false
            case .stroke(let segments, _, _, let isMarker):
                if isMarker { hasMarker = true }
                if !hasNoise { hasNoise = segments.contains { $0.noiseSeed != 0 } }
            }
        }
        return !(hasMarker && hasNoise)
    }

    /// Per-stroke flags, shared by the binning and composite kernels:
    /// bit0 = eraser, bit1 = hasNoise, bit2 = isMarker. Pure helper so the bit layout is
    /// pinned by tests.
    public static func strokeFlags(isEraser: Bool, hasNoise: Bool,
                                   isMarker: Bool = false) -> UInt32 {
        (isEraser ? 1 : 0) | (hasNoise ? 2 : 0) | (isMarker ? 4 : 0)
    }
}

extension Renderer {
    /// Above this many cached segments the interactive mode is abandoned in favour of the
    /// single-raster fallback. ~1.5 M segments ≈ 84 MB of geometry, i.e. a document far
    /// bigger than anything a preview needs.
    public static let liveCacheSegmentBudget = 1_500_000
}

// MARK: - Re-mapping

extension LiveRenderCache {
    /// Applies the camera to one layer's cached ops.
    ///
    /// - Parameters:
    ///   - camera: the document-space camera, i.e. canvas px (at 100%) → view px.
    ///   - viewport: the region being rasterised in view px. Strokes whose bounds miss it
    ///     after the camera is applied are skipped: their ink would land outside every
    ///     pixel of the target, so compositing them cannot change a single output pixel.
    ///     nil disables the test (used by the cache report).
    /// - Returns: nil for a `needsRebuild` layer (those are re-walked per frame instead).
    public func deviceOps(forLayerAt index: Int,
                          camera: CGAffineTransform,
                          viewport: CGRect? = nil) -> [LiveDeviceOp]? {
        guard index < layers.count else { return nil }
        let layer = layers[index]
        guard !layer.needsRebuild else { return nil }
        
        // Uniform scale of the similarity transform; radii multiply by this.
        let scaleX = sqrt(camera.a * camera.a + camera.c * camera.c)
        let scaleY = sqrt(camera.b * camera.b + camera.d * camera.d)
        let radiusFactor = Float((scaleX + scaleY) / 2.0)
        
        var ops: [LiveDeviceOp] = []
        ops.reserveCapacity(layer.ops.count)
        let cameraInverse = invert(camera)
        
        for cached in layer.ops {
            switch cached {
                case .stroke(let stroke):
                    if let viewport,
                       !Self.intersects(stroke.bounds, camera: camera, viewport: viewport) {
                        continue
                    }
                    ops.append(.stroke(segments: Self.remap(stroke.segments,
                                                            camera: camera,
                                                            radiusFactor: radiusFactor),
                                        color: stroke.color,
                                        isEraser: stroke.isEraser,
                                        isMarker: stroke.isMarker))
                case .cut(let rect, let selectionFrame):
                    // `buildLayerOperations` builds cuts against the *base* transform
                    // (no layer matrix), so the live version uses camera ∘ base.
                    let liveBase = liveBaseTransform(camera: camera)
                    guard let inverse = invert(liveBase) else { continue }
                    // dest device → selection frame = m1 after liveBase⁻¹. With
                    // `a.concatenating(b)` applying a first, that is
                    // `inverse.concatenating(selectionFrame)` (the old order put the
                    // camera on the wrong side and was only correct when it was identity).
                    ops.append(.cut(meta: CutMeta(inverseAffine: inverse.concatenating(selectionFrame),
                                                  rect: rect, edgeWidth: 0.75)))
                case .paste(let paste):
                    // Every paste map is `B ∘ (content) ∘ B⁻¹`, and B_now = C ∘ B_ref,
                    // so the camera conjugates through unchanged. The segments simply
                    // move by C (radii included), and each mask map loses one C⁻¹ on
                    // the output side because `B_now⁻¹ = B_ref⁻¹ ∘ C⁻¹`.
                    guard let cameraInverse else { return nil }
                    let masks: [PasteMask] = paste.masks.map { mask in
                        PasteMask(inv: cameraInverse.concatenating(mask.inv),
                                  rectXYWH: [mask.rect.x, mask.rect.y,
                                             mask.rect.z, mask.rect.w],
                                  erase: mask.erase)
                    }
                    let invAffine = cameraInverse
                        .concatenating(paste.invAffine)
                        .concatenating(camera)
                    let srcToDst = cameraInverse
                        .concatenating(paste.sourceToDestination)
                        .concatenating(camera)
                    ops.append(.paste(
                        segments: Self.remap(paste.segments,
                                             camera: camera,
                                             radiusFactor: radiusFactor),
                        color: paste.color,
                        isEraser: paste.isEraser,
                        isMarker: paste.isMarker,
                        meta: PasteLayerMeta(invAffine: invAffine, edgeWidth: 0.75,
                                             maskCount: UInt32(masks.count)),
                        masks: masks,
                        sourceToDestinationGPU: srcToDst,
                        isMerge: paste.isMerge,
                        mergeID: paste.mergeID))
            }
        }
        return ops
    }

    /// Does a stroke's ink land inside `viewport` once `camera` is applied?
    ///
    /// The camera can rotate, so the box is mapped through its four corners rather than by
    /// scaling the extents.
    static func intersects(_ bounds: CGRect,
                           camera: CGAffineTransform,
                           viewport: CGRect) -> Bool {
        guard !bounds.isEmpty, !viewport.isEmpty else { return true }
        let p0 = CGPoint(x: bounds.minX, y: bounds.minY).applying(camera)
        let p1 = CGPoint(x: bounds.maxX, y: bounds.minY).applying(camera)
        let p2 = CGPoint(x: bounds.maxX, y: bounds.maxY).applying(camera)
        let p3 = CGPoint(x: bounds.minX, y: bounds.maxY).applying(camera)
        let minX = min(min(p0.x, p1.x), min(p2.x, p3.x))
        let maxX = max(max(p0.x, p1.x), max(p2.x, p3.x))
        let minY = min(min(p0.y, p1.y), min(p2.y, p3.y))
        let maxY = max(max(p0.y, p1.y), max(p2.y, p3.y))
        return maxX >= viewport.minX && minX <= viewport.maxX
            && maxY >= viewport.minY && minY <= viewport.maxY
    }
    
    /// art → device for a rebuilt (paste/merge) layer: layer first, then base, then the
    /// camera.
    ///
    /// - Note on composition order: `a.concatenating(b)` applies **a first**, then `b`
    ///   (it is `b ∘ a`) — same convention in CoreGraphics and Silica.
    public func artToDevice(layerAt index: Int, camera: CGAffineTransform) -> CGAffineTransform? {
        guard index < layers.count else { return nil }
        return layers[index].layerTransform
            .concatenating(baseTransform)
            .concatenating(camera)
    }

    /// camera ∘ baseTransform — the transform cuts (and the paper) are expressed in.
    public func liveBaseTransform(camera: CGAffineTransform) -> CGAffineTransform {
        baseTransform.concatenating(camera)
    }

    /// How many strokes layer `index` holds (for the "everything was culled" report).
    public func strokeCount(at index: Int) -> Int {
        guard index < layers.count else { return 0 }
        // Precomputed at cache build; the reduce over `ops` ran every frame just to
        // report the culled count.
        return layers[index].strokeBounds.count
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
                // `padding1` holds the segment's shape reach from its chord (a distance, in
                // the segment's own space at flatten time). Distances scale with the camera,
                // so it must be rescaled into canvas space here just like the radii —
                // otherwise the kernel compares a document-space radius against
                // canvas-space distances: too small when zoomed in (over-prune → strokes
                // clip, lose their AA falloff) and too big when zoomed out (under-prune →
                // full SDF cost). The coverage margin the kernels add is a device-pixel
                // constant and deliberately *not* scaled. 0 = unset, stays 0.
                s.padding1 = (Float(bitPattern: s.padding1) * radiusFactor).bitPattern
            }
            out.append(s)
        }
        return out
    }
}

// MARK: - Building the cache

extension Renderer {

    /// Recovers a `CGAffineTransform` from the two row vectors the GPU structs carry:
    /// row0 = (a, c, tx, _), row1 = (b, d, ty, _).
    static func affine(row0: SIMD4<Float>, row1: SIMD4<Float>) -> CGAffineTransform {
        CGAffineTransform(a: CGFloat(row0.x), b: CGFloat(row1.x),
                          c: CGFloat(row0.y), d: CGFloat(row1.y),
                          tx: CGFloat(row0.z), ty: CGFloat(row1.z))
    }

    /// Walks `art` once and caches every layer's flattened geometry at the reference
    /// transform.
    ///
    /// Layers with paste/merge actions are recorded but left empty (`needsRebuild`): their
    /// resolution cost belongs to those actions, and re-walking them per frame keeps that
    /// tricky code path untouched.
    ///
    /// - Parameters:
    ///   - scale: the renderer's render scale. `renderLive(cache:…)` derives its camera from
    ///     `canvasSize * Renderer.scale`, so any other value here would mis-register all
    ///     cached geometry.
    ///   - segmentBudget: give up (return nil) past this many cached segments; callers fall
    ///     back to the single-raster mode.
    /// - Returns: nil when the document does not fit the budget or has nothing to draw.
    @discardableResult
    public func buildLiveRenderCacheGeometry(art: ArtParser,
                                            scale: CGFloat? = nil,
                                            segmentBudget: Int = Renderer.liveCacheSegmentBudget) -> LiveRenderCache? {
        let scale = scale ?? self.scale
        let baseTransform = transformFromMatrix(art.viewMatrix, scale: scale)
        invalidateReplayCaches()

        var layers: [LiveCachedLayer] = []
        var segmentCount = 0
        var overBudget = false

        for layerIndex in art.layerOrder {
            guard layerIndex < art.layers.count, !overBudget else { continue }
            let layer = art.layers[layerIndex]
            guard getVisibility(from: layer),
                  let layerMatrix = layer["matrix"] as? [[Float]] else { continue }

            let layerTransform = toDirectCGTransform(layerMatrix)
            let referenceTransform = CGAffineTransformConcat(layerTransform, baseTransform)
            let operations = buildLayerOperations(art: art,
                                                  layerIndex: layerIndex,
                                                  baseTransform: baseTransform,
                                                  flipTransform: nil)
            guard !operations.isEmpty else { continue }

            var cached: [LiveCachedOp] = []

            for op in operations {
                switch op {
                    case .stroke(let stroke):
                        guard let built = buildOpFromStroke(stroke,
                                                             artToDevice: referenceTransform,
                                                             flipTransform: nil) else { continue }
                        segmentCount += built.segments.count
                        if segmentCount > segmentBudget { overBudget = true; break }
                        cached.append(.stroke(LiveCachedStroke(
                            segments: built.segments,
                            color: built.color,
                            isEraser: built.isEraser,
                            isMarker: built.isMarker,
                            bounds: LiveCachedStroke.referenceBounds(of: built.segments,
                                                                    isMarker: built.isMarker))))

                    case .cut(let meta):
                        // Recompose the cut against any camera. `selectionFrame` must be
                        // the map canvas coords → the rect's frame; the live side appends
                        // it after `liveBase⁻¹` (= camera⁻¹ ∘ B⁻¹). Both cut flavors satisfy
                        // that with `B` applied *before* `inverseAffine`
                        // (`a.concatenating(b)` applies a first):
                        //   own `matrix_1` cut: `inverseAffine = m1 ∘ B⁻¹` → `B · inverseAffine = m1`;
                        //   pen-frame cut:      `inverseAffine = pen⁻¹ ∘ B⁻¹` → `B · inverseAffine = pen⁻¹`.
                        cached.append(.cut(
                            rect: [meta.rect.x, meta.rect.y, meta.rect.z, meta.rect.w],
                            selectionFrame: baseTransform.concatenating(meta.inverseAffine)))

                    case .paste(let segments, let color, let isEraser, let isMarker,
                                let meta, let masks, let sourceToDestination,
                                let isMerge, let mergeID):
                        segmentCount += segments.count
                        if segmentCount > segmentBudget { overBudget = true; break }
                        let cachedMasks = masks.map {
                            LiveCachedPasteMask(inv: Self.affine(row0: $0.inv0, row1: $0.inv1),
                                                rect: $0.rect,
                                                erase: $0.flags.x > 0.5)
                        }
                        cached.append(.paste(LiveCachedPaste(
                            segments: segments,
                            color: color,
                            isEraser: isEraser,
                            isMarker: isMarker,
                            invAffine: Self.affine(row0: meta.row0, row1: meta.row1),
                            masks: cachedMasks,
                            sourceToDestination: sourceToDestination,
                            isMerge: isMerge,
                            mergeID: mergeID)))
                }
            }

            if overBudget { break }

            // A/B knob (see `LiveConfig.forceRebuildEnabled`): send layers back through the
            // per-frame walk, which is the reference the cached ops are verified against.
            var needsRebuild = false
            if LiveConfig.forceRebuildEnabled() {
                needsRebuild = !LiveConfig.forceRebuildPasteOnly()
                    || cached.contains { if case .paste = $0 { return true }; return false }
            }
            let storedOps = needsRebuild ? [] : cached

            layers.append(LiveCachedLayer(layerIndex: layerIndex,
                                          opacity: layer["opacity"] as? Float ?? 1.0,
                                          layerTransform: layerTransform,
                                          ops: storedOps,
                                          needsRebuild: needsRebuild))
        }

        guard !overBudget, !layers.isEmpty else { return nil }

        let rebuilding = layers.filter { $0.needsRebuild }.count
        print("Live view: cached \(segmentCount) segments across \(layers.count) layer(s)"
              + (rebuilding > 0 ? " (\(rebuilding) rebuilt per frame)" : ""))

        return LiveRenderCache(baseTransform: baseTransform,
                               layers: layers,
                               segmentCount: segmentCount,
                               withinBudget: true)
    }
}
