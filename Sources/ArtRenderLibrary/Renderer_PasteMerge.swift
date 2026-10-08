import Foundation
#if os(Linux)
import Silica
import CoreFoundation
//import Cairo
//import JPEG
#elseif os(macOS)
import CoreGraphics
#endif

#if canImport(Metal)
import Metal
#endif

import ArtParser

extension Renderer {
    // MARK: - Paste and Merge Resolution
    /// Mirrors actionPasteLayerOps (GPU segment path) but yields point data.
    internal func resolvePasteRender(
        action: [String: Any],
        art: ArtParser,
        targetLayerIndex: Int,
        actionIndex: Int,
        dstPenAffine: CGAffineTransform,
        dstLayerMatrix: CGAffineTransform,
        baseTransform: CGAffineTransform
    ) -> ResolvedPasteRender? {
        guard let fromLayer = action["from_layer"] as? Int,
              fromLayer >= 0, fromLayer < art.layers.count,
              let selectionRect = parseFloatArray(action["selection_rect"]),
              selectionRect.count == 4,
              let m1raw = parseMatrixRobust(action["matrix_1"]),
              let m2raw = parseMatrixRobust(action["matrix_2"]) else { return nil }
        
        let matrix1 = transformFromMatrix(m1raw.map { $0.map { Float($0) } }, scale: 1.0)
        let matrix2 = transformFromMatrix(m2raw.map { $0.map { Float($0) } }, scale: 1.0)
        
        let B = baseTransform
        let Ldst = dstLayerMatrix                // was: layerMatrix(ofLayer: targetLayerIndex, in: art)
        
        // device px -> selection frame (m1 ∘ B⁻¹)
        let deviceToSelection = B.inverted().concatenating(matrix1)
        let pen: CGAffineTransform
        let selectionToDevice: CGAffineTransform
        
        if isIdentityTransform(matrix1) {
            pen = dstPenAffine
            selectionToDevice = matrix1.inverted().concatenating(pen).concatenating(Ldst).concatenating(B)
        } else if pasteFollowsCut(art: art, layerIndex: targetLayerIndex,
                                  pasteActionIndex: actionIndex, pasteRect: selectionRect) {
            pen = .identity
            selectionToDevice = matrix1.inverted().concatenating(B)
        } else {
            pen = dstPenAffine
            // Matches actionPasteLayerOps — the layer matrix MUST be included.
            // Dropping it strips the layer translation (rotationOnlyInverse-class bug).
            selectionToDevice = pen.concatenating(Ldst).concatenating(B)
        }
        
        // D = (B⁻¹ ∘ m1) ∘ m2 ∘ selectionToDevice — source device -> dest device
        let destMap = deviceToSelection.concatenating(matrix2).concatenating(selectionToDevice)
        guard abs(destMap.a * destMap.d - destMap.b * destMap.c) > 1e-9 else { return nil }
        
        let resolvedStrokes = buildStrokesForLayer(layerIndex: fromLayer, art: art, baseTransform: B, visited: [])
        let groups = buildPasteRenderGroups(
            resolvedStrokes: resolvedStrokes, art: art, baseTransform: B,
            outerRect: selectionRect, outerM1: matrix1, colorAlpha: 1.0)
        return ResolvedPasteRender(groups: groups, destMap: destMap)
    }
    
    /// Mirrors actionMergeLayerOps (GPU segment path) but yields point data.
    /// `matrix` is an action-time view snapshot and is deliberately not applied.
    internal func resolveMergeRender(
        action: [String: Any],
        art: ArtParser,
        targetLayerIndex: Int,
        baseTransform: CGAffineTransform
    ) -> ResolvedPasteRender? {
        guard let fromLayer = action["from_layer"] as? Int,
              fromLayer >= 0, fromLayer < art.layers.count,
              let _ = parseMatrixRobust(action["matrix"]) else { return nil }
        let B = baseTransform
        // Merge preserves canvas position: B ∘ Ldst ∘ B⁻¹
        let destMap = B.inverted()
            .concatenating(layerMatrix(ofLayer: targetLayerIndex, in: art))
            .concatenating(B)
        guard abs(destMap.a * destMap.d - destMap.b * destMap.c) > 1e-9 else { return nil }
        let opacitySrc = action["opacity_src"] as? Float ?? 1.0
        
        let resolvedStrokes = buildStrokesForLayer(layerIndex: fromLayer, art: art, baseTransform: B, visited: [])
        let groups = buildPasteRenderGroups(
            resolvedStrokes: resolvedStrokes, art: art, baseTransform: B,
            outerRect: nil, outerM1: nil, colorAlpha: opacitySrc)
        return ResolvedPasteRender(groups: groups, destMap: destMap, isMerge: true)
    }
    
    /// Mirrors assemblePasteOps' grouping and mask baking, but keeps point data.
    internal func buildPasteRenderGroups(
        resolvedStrokes: [ResolvedStroke],
        art: ArtParser,
        baseTransform: CGAffineTransform,
        outerRect: [Float]?,
        outerM1: CGAffineTransform?,
        colorAlpha: Float
    ) -> [PasteRenderGroup] {
        let Bi = baseTransform.inverted()
        var groups: [PasteRenderGroup] = []
        
        for resolved in resolvedStrokes {
            let lb = layerMatrix(ofLayer: resolved.sourceLayerIndex, in: art)
                .concatenating(baseTransform)
            let accNow = resolved.accumulatedDeviceTransform
            let color = SIMD4<Float>(Float(resolved.stroke.pen.color.r),
                                     Float(resolved.stroke.pen.color.g),
                                     Float(resolved.stroke.pen.color.b), colorAlpha)
            
            var maskEntries: [BakedMask] = []
            // Slot 0: outer keep — src device -> this paste's selection frame (B⁻¹ ∘ m1).
            if let outerRect = outerRect, let outerM1 = outerM1 {
                maskEntries.append(BakedMask(inv: Bi.concatenating(outerM1), rect: outerRect, erase: false))
            }
            // Replay masks: accNow⁻¹ -> accRef -> B⁻¹ -> m1 (same chain as the GPU path).
            for m in resolved.masks {
                maskEntries.append(BakedMask(
                    inv: accNow.inverted().concatenating(m.accRef).concatenating(Bi).concatenating(m.m1),
                    rect: m.rect, erase: m.erase))
            }
            
            if let idx = groups.firstIndex(where: {
                $0.color == color &&
                $0.isEraser == resolved.stroke.pen.isEraser &&
                $0.isMarker == resolved.stroke.pen.isMarker &&
                $0.lb == lb && $0.accNow == accNow && $0.maskEntries == maskEntries }) {
                groups[idx].strokes.append(resolved.stroke)
            } else {
                groups.append(PasteRenderGroup(
                    color: color,
                    isEraser: resolved.stroke.pen.isEraser,
                    isMarker: resolved.stroke.pen.isMarker,
                    strokes: [resolved.stroke],
                    lb: lb, accNow: accNow,
                    maskEntries: maskEntries))
            }
        }
        return groups
    }
    
    // MARK: - GPU Paste Path
#if os(macOS)
    internal func renderPasteGroupsWithGPUStamps(
        resolved: ResolvedPasteRender,
        context: CGContext,
        metalRenderer: MetalRenderer
    ) -> Bool {
        let w = Int(canvasSize.width * scale)
        let h = Int(canvasSize.height * scale)
        let fullPx = CGRect(x: 0, y: 0, width: w, height: h)
        
        var fragment: CGContext? = nil
        if resolved.isMerge {
            fragment = TempContextPool.shared.acquire(size: canvasSize, scale: scale)
        }
        var fragDirty = CGRect.null // .null = nothing written; full rect = full canvas
        defer {
            if let frag = fragment {
                TempContextPool.shared.release(frag, dirtyPx: fragDirty.isNull ? CGRect.zero : fragDirty)
            }
        }
        let target = fragment ?? context
        
        for g in resolved.groups {
            var batches: [(stamps: [Stamp], color: SIMD4<Float>, isMarker: Bool)] = []
            for stroke in g.strokes {
                guard let batch = buildStampBatch(stroke: stroke, lb: g.lb, accNow: g.accNow, destMap: resolved.destMap) else { continue }
                batches.append((stamps: batch.stamps, color: g.color, isMarker: batch.isMarker))
            }
            guard !batches.isEmpty else { continue }
            
            let keepPairs = g.maskEntries.filter { !$0.erase }.map { ($0.inv, $0.rect) }
            let cropPx = keepCropPx(keeps: keepPairs, destMap: resolved.destMap, pxW: w, pxH: h)
            if cropPx == .zero { continue } // keep-intersection empty → group renders nothing; skip GPU work
            
            let groups = batches.map {
                (stamps: $0.stamps, color: $0.color, isEraser: false,
                 isMarker: g.isEraser ? false : $0.isMarker)
            }
            let image: CGImage
            do {
                guard let img = try metalRenderer.renderStrokesInOrderSync(strokeGroups: groups, width: w, height: h) else {
                    print("GPU stamp paste flush returned nil")
                    return false
                }
                image = img
            } catch {
                print("GPU stamp paste failed: \(error)")
                return false
            }
            
            var outImage = image
            let outCrop: CGRect? = cropPx // nil = full canvas
            if !g.maskEntries.isEmpty {
                let temp = TempContextPool.shared.acquire(size: canvasSize, scale: scale)
                defer { TempContextPool.shared.release(temp, dirtyPx: cropPx) }
                // Composite only the keep-bounded region; the rest stays zero, which is
                // exactly what the keep clears would produce there.
                if let c = cropPx, let sub = image.cropping(to: c) {
                    compositeImageCPU(image: sub, into: temp, offsetPx: c)
                } else {
                    compositeImageCPU(image: image, into: temp)
                }
                clearKeepMasksCPU(temp, keeps: keepPairs, destMap: resolved.destMap, boundsPx: cropPx)
                for m in g.maskEntries where m.erase {
                    eraseQuadPixelsCPU(temp, maskInv: m.inv, rect: m.rect, destMap: resolved.destMap)
                }
                guard let masked = temp.makeImage() else { return false }
                outImage = masked
            }
            
            let groupAlpha = resolved.isMerge ? CGFloat(1) : CGFloat(min(max(g.color.w, 0), 1))
            if let c = outCrop, let sub = outImage.cropping(to: c) {
                compositeImageCPU(image: sub, erase: g.isEraser, alpha: groupAlpha, into: target, offsetPx: c)
                fragDirty = fragDirty.union(c)
            } else {
                compositeImageCPU(image: outImage, erase: g.isEraser, alpha: groupAlpha, into: target)
                fragDirty = fullPx
            }
        }
        
        if let frag = fragment {
            if fragDirty.isNull { return true } // no group wrote to the fragment
            let mergeAlpha = CGFloat(min(max(resolved.groups.first?.color.w ?? 1, 0), 1))
            guard let image = frag.makeImage() else { return false }
            compositeImageCPU(image: image, alpha: mergeAlpha, into: context)
        }
        return true
    }
#endif
    
    // MARK: - CPU Paste Dispatch
    internal func renderPasteGroupsCPU(resolved: ResolvedPasteRender, context: CGContext) {
        // MERGE: composite the source layer as an isolated fragment — its erasers
        // erase only the merged layer's own content (reference: flatten the source,
        // then composite the result over the destination). PASTES stay flat.
        if resolved.isMerge {
            let mergeAlpha = CGFloat(min(max(resolved.groups.first?.color.w ?? 1, 0), 1))
            let fragment = createBitmapContext(size: canvasSize, scale: scale)
            Self.clearContext(fragment, rect: CGRect(x: 0, y: 0, width: fragment.width, height: fragment.height))
            for g in resolved.groups {
                renderPasteGroupCPU(g: g, resolved: resolved, target: fragment, groupAlpha: 1.0)
            }
            if let image = fragment.makeImage() {
                compositeImageCPU(image: image, alpha: mergeAlpha, into: context)
            }
            return
        }
        for g in resolved.groups {
            renderPasteGroupCPU(g: g, resolved: resolved, target: context,
                                groupAlpha: CGFloat(min(max(g.color.w, 0), 1)))
        }
    }
    
    /// One paste/merge group into `target` (the layer context, or a merge fragment).
    internal func renderPasteGroupCPU(g: PasteRenderGroup, resolved: ResolvedPasteRender,
                                      target: CGContext, groupAlpha: CGFloat) {
        if g.maskEntries.isEmpty && !g.isEraser && groupAlpha >= 1.0 {
            for stroke in g.strokes {
                drawStrokeOnCPU(stroke: stroke, lb: g.lb, accNow: g.accNow,
                                destMap: resolved.destMap, context: target)
            }
            return
        }
        let keeps = g.maskEntries.filter { !$0.erase }.map { ($0.inv, $0.rect) }
        let cropPx0 = keepCropPx(keeps: keeps, destMap: resolved.destMap,
                                 pxW: Int(canvasSize.width * scale), pxH: Int(canvasSize.height * scale))
        if cropPx0 == .zero { return } // nothing of this group can survive the keeps
        
        let temp = TempContextPool.shared.acquire(size: canvasSize, scale: scale)
        let cropPx: CGRect? = cropPx0
        defer { TempContextPool.shared.release(temp, dirtyPx: cropPx) }
        
        for stroke in g.strokes {
            var s = stroke
            if g.isEraser { s.pen.isEraser = false; s.pen.isMarker = false }
            drawStrokeOnCPU(stroke: s, lb: g.lb, accNow: g.accNow, destMap: resolved.destMap, context: temp)
        }
        clearKeepMasksCPU(temp, keeps: keeps, destMap: resolved.destMap)
        for m in g.maskEntries where m.erase {
            eraseQuadPixelsCPU(temp, maskInv: m.inv, rect: m.rect, destMap: resolved.destMap)
        }
        
        guard let image = temp.makeImage() else { return }
        if let c = cropPx, let sub = image.cropping(to: c) {
            compositeImageCPU(image: sub, erase: g.isEraser, alpha: groupAlpha,
                              into: target, offsetPx: c)
        } else {
            compositeImageCPU(image: image, erase: g.isEraser, alpha: groupAlpha, into: target)
        }
    }
    
    // MARK: - Layer Operation Assembly
    
    internal func actionPasteLayerOps(
        action: [String: Any],
        art: ArtParser,
        targetLayerIndex: Int,
        actionIndex: Int,
        dstPenAffine: CGAffineTransform,
        baseTransform: CGAffineTransform,
        flipTransform: CGAffineTransform?
    ) -> [LayerOperation] {
        
        // ── 1. Parse ──
        guard let fromLayer = action["from_layer"] as? Int,
              fromLayer >= 0, fromLayer < art.layers.count,
              let selectionRect = parseFloatArray(action["selection_rect"]),
              selectionRect.count == 4,
              let m1raw = parseMatrixRobust(action["matrix_1"]),
              let m2raw = parseMatrixRobust(action["matrix_2"]) else {
            return []
        }
        
        // matrix_1 = action-time view: canvas -> selection frame.
        // matrix_2 = free transform, authored in that same selection frame.
        let matrix1 = transformFromMatrix(m1raw.map { $0.map { Float($0) } }, scale: 1.0)
        let matrix2 = transformFromMatrix(m2raw.map { $0.map { Float($0) } }, scale: 1.0)
        
        let B    = baseTransform
        let Ldst = layerMatrix(ofLayer: targetLayerIndex, in: art)
        
        // ── 2. Device-space maps ──
        // device px -> selection frame  (validated:  m1 ∘ B⁻¹)
        let deviceToSelection = B.inverted().concatenating(matrix1)
        
        let pen: CGAffineTransform
        let selectionToDevice: CGAffineTransform
        
        if isIdentityTransform(matrix1) {
            pen = dstPenAffine                                    // validated m1 == I path — unchanged
            selectionToDevice = matrix1.inverted() // rotationOnlyInverse(matrix1)
                .concatenating(pen).concatenating(Ldst).concatenating(B)
        } else if pasteFollowsCut(art: art, layerIndex: targetLayerIndex,
                                  pasteActionIndex: actionIndex, pasteRect: selectionRect) {
            pen = .identity
            // Free transform: full conjugation through the action-time view.
            // rotOnlyInverse was only valid at zoom_1 == 1 (where it equals m1⁻¹).
            selectionToDevice = matrix1.inverted().concatenating(B)
        } else {
            pen = dstPenAffine                                    // new-layer paste: sel px ARE layer px,
            // NOTE: actionPasteLayerOps keeps Ldst in this branch — the GPU paste shader
            // compensates it. Point-level application must NOT include it (File1 case).
            selectionToDevice = pen.concatenating(Ldst).concatenating(B)  // pen applied in full
            
        }
        
        
        
        // Free transform acts in screen space -> conjugate into device space:
        //   D = (B ∘ Ldst ∘ m1⁻¹) ∘ m2 ∘ (m1 ∘ B⁻¹)
        let sourceToDestinationGPU = deviceToSelection
            .concatenating(matrix2)
            .concatenating(selectionToDevice)
        let destinationToSourceGPU = sourceToDestinationGPU.inverted()
        
        // ── 3. Diagnostics / guard ──
        let detD = sourceToDestinationGPU.a * sourceToDestinationGPU.d
        - sourceToDestinationGPU.b * sourceToDestinationGPU.c
        //        print("CUT/PASTE v7 dstLayer=\(targetLayerIndex) Ldst=\(Ldst)")
        //        print("CUT/PASTE v7 D=\(sourceToDestinationGPU) det=\(detD)")
        guard abs(detD) > 1e-9 else { return [] }
        
        
        // Diagnostic: where does the source layer's content actually sit in the file?
        //        let srcIndices = art.actions.enumerated().compactMap {
        //            ($0.element["layer"] as? Int) == fromLayer ? $0.offset : nil
        //        }
        //        print("CUT/PASTE v7 paste@idx=\(actionIndex) srcLayer=\(fromLayer) srcActionIdx=\(srcIndices)")
        
        let resolvedStrokes = buildStrokesForLayer(
            layerIndex: fromLayer,
            art: art,
            baseTransform: B,
            visited: [])
        
        
        //        print("CUT/PASTE v7 source strokes=\(resolvedStrokes.count)")
        
        
        //        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0),
        //                       CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map {
        //            CGPoint(x: CGFloat(selectionRect[0]) + $0.x * CGFloat(selectionRect[2]),
        //                    y: CGFloat(selectionRect[1]) + $0.y * CGFloat(selectionRect[3]))
        //            .applying(matrix2)
        //            .applying(selectionToDevice)
        //        }
        //        let minX = corners.map(\.x).min()!, maxX = corners.map(\.x).max()!
        //        let minY = corners.map(\.y).min()!, maxY = corners.map(\.y).max()!
        //        print("CUT/PASTE v10 predicted paste bbox: (\(minX), \(minY), \(maxX - minX), \(maxY - minY))")
        
        
        return assemblePasteOps(
            resolvedStrokes: resolvedStrokes,
            art: art,
            baseTransform: B,
            destinationToSourceGPU: destinationToSourceGPU,
            sourceToDestinationGPU: sourceToDestinationGPU,
            outerRect: selectionRect,
            outerM1: matrix1,
            colorAlpha: 1.0,
            flipTransform: flipTransform,
            isMerge: false,
            mergeID: 0)
    }
    
    internal func actionMergeLayerOps(
        action: [String: Any],
        art: ArtParser,
        targetLayerIndex: Int,
        actionIndex: Int,
        baseTransform: CGAffineTransform,
        flipTransform: CGAffineTransform?
    ) -> [LayerOperation] {
        
        guard let fromLayer = action["from_layer"] as? Int,
              fromLayer >= 0, fromLayer < art.layers.count,
              let mRaw = parseMatrixRobust(action["matrix"]) else { return [] }
        
        let M = transformFromMatrix(mRaw.map { $0.map { Float($0) } }, scale: 1.0)
        // `matrix`+`zoom` is an action-time VIEW snapshot (same shape as matrix_1/zoom_1
        // in pastes), NOT a content transform. Merging preserves canvas position.
        print("MERGE v2 view-snapshot M (not applied)=\(M)")
        
        let B = baseTransform
        let opacitySrc = action["opacity_src"] as? Float ?? 1.0
        
        let sourceToDestinationGPU = baseTransform.inverted()
            .concatenating(layerMatrix(ofLayer: targetLayerIndex, in: art))
            .concatenating(baseTransform)          // B ∘ Ldst ∘ B⁻¹
        let destinationToSourceGPU = sourceToDestinationGPU.inverted()
        
        print("MERGE v1 dst=\(targetLayerIndex) src=\(fromLayer) M=\(M) opacity_src=\(opacitySrc)")
        
        guard abs(sourceToDestinationGPU.a * sourceToDestinationGPU.d
                  - sourceToDestinationGPU.b * sourceToDestinationGPU.c) > 1e-9 else { return [] }
        
        let resolvedStrokes = buildStrokesForLayer(
            layerIndex: fromLayer,
            art: art,
            baseTransform: B,
            visited: [])
        print("MERGE v1 source strokes=\(resolvedStrokes.count)")
        
        return assemblePasteOps(
            resolvedStrokes: resolvedStrokes,
            art: art,
            baseTransform: B,
            destinationToSourceGPU: destinationToSourceGPU,
            sourceToDestinationGPU: sourceToDestinationGPU,
            outerRect: nil,
            outerM1: nil,
            colorAlpha: opacitySrc,
            flipTransform: flipTransform,
            isMerge: true,
            mergeID: UInt64(bitPattern: Int64(actionIndex)))
    }
    
    internal func assemblePasteOps(
        resolvedStrokes: [ResolvedStroke],
        art: ArtParser,
        baseTransform: CGAffineTransform,
        destinationToSourceGPU: CGAffineTransform,
        sourceToDestinationGPU: CGAffineTransform,
        outerRect: [Float]?,
        outerM1: CGAffineTransform?,
        colorAlpha: Float,
        flipTransform: CGAffineTransform?,
        isMerge: Bool,
        mergeID: UInt64
    ) -> [LayerOperation] {
        
        struct Group {
            var color: SIMD4<Float>
            var isEraser: Bool
            var isMarker: Bool
            var strokeToDevice: CGAffineTransform
            var accNow: CGAffineTransform
            var masks: [StrokeMask]
            var strokes: [StrokeRecord]
        }
        
        var groups: [Group] = []
        for resolved in resolvedStrokes {
            let strokeToDevice = layerMatrix(ofLayer: resolved.sourceLayerIndex, in: art)
                .concatenating(baseTransform)
                .concatenating(resolved.accumulatedDeviceTransform)
            let color = SIMD4<Float>(Float(resolved.stroke.pen.color.r),
                                     Float(resolved.stroke.pen.color.g),
                                     Float(resolved.stroke.pen.color.b), colorAlpha)
            if let idx = groups.firstIndex(where: {
                $0.color == color &&
                $0.isEraser == resolved.stroke.pen.isEraser &&
                $0.isMarker == resolved.stroke.pen.isMarker &&
                $0.strokeToDevice == strokeToDevice &&
                $0.masks == resolved.masks }) {
                groups[idx].strokes.append(resolved.stroke)
            } else {
                groups.append(Group(color: color,
                                    isEraser: resolved.stroke.pen.isEraser,
                                    isMarker: resolved.stroke.pen.isMarker,
                                    strokeToDevice: strokeToDevice,
                                    accNow: resolved.accumulatedDeviceTransform,
                                    masks: resolved.masks,
                                    strokes: [resolved.stroke]))
            }
        }
        
        var ops: [LayerOperation] = []
        for g in groups {
            var segments: [GPUSplineSegment] = []
            for stroke in g.strokes {
                guard let op = buildOpFromStroke(stroke,
                                                 artToDevice: g.strokeToDevice,
                                                 flipTransform: flipTransform) else { continue }
                segments.append(contentsOf: op.segments)
            }
            guard !segments.isEmpty else { continue }
            
            let Bi = baseTransform.inverted()
            var metaMasks: [PasteMask] = []
            
            // Slot 0: outer keep — src device -> this paste's selection frame (B⁻¹ ∘ m1).
            if let outerRect = outerRect, let outerM1 = outerM1 {
                metaMasks.append(PasteMask(inv: Bi.concatenating(outerM1),
                                           rectXYWH: outerRect, erase: false))
            }
            // Masks recorded during the replay (nested selections + cut erases).
            // Map: src device -> that mask's selection frame
            //      = accNow⁻¹ -> accRef -> B⁻¹ -> m1   (receiver-first chain below)
            for m in g.masks {
                let map = g.accNow.inverted()
                    .concatenating(m.accRef)
                    .concatenating(Bi)
                    .concatenating(m.m1)
                metaMasks.append(PasteMask(inv: map, rectXYWH: m.rect, erase: m.erase))
            }
            
            let meta = PasteLayerMeta(invAffine: destinationToSourceGPU,
                                      edgeWidth: 0.75, maskCount: UInt32(metaMasks.count))
            //            print("CUT/PASTE op: segments=\(segments.count) masks=\(metaMasks.count) " +
            //                  "(erase=\(metaMasks.filter { $0.flags.x > 0.5 }.count))")
            ops.append(.paste(
                segments: segments,
                color: g.color,
                isEraser: g.isEraser,
                isMarker: g.isMarker,
                meta: meta,
                masks: metaMasks,
                sourceToDestinationGPU: sourceToDestinationGPU,
                isMerge: isMerge,
                mergeID: mergeID))
        }
        return ops
    }
}
