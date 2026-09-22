import Foundation
#if os(Linux)
//import Silica
import CoreFoundation
//import Cairo
//import JPEG
#elseif os(macOS)
import CoreGraphics
#endif

import ArtParser

extension Renderer {
    // MARK: - Replay Context
    internal final class ReplayContext {
        struct Key: Hashable {
            let layerIndex: Int
            let visited: Set<Int>
        }
        
        unowned let renderer: Renderer
        let art: ArtParser
        let baseTransform: CGAffineTransform
        let baseTransformInv: CGAffineTransform
        let actionsByLayer: [Int: [Int]]
        /// action index -> does this paste follow a same-rect cut on its layer
        let followsCutByAction: [Int: Bool]
        /// action index -> view matrix of the next paste_layer after it (parseable matrix_1 only)
        let nextPasteViewAfter: [CGAffineTransform?]
        var replayCache: [Key: [ResolvedStroke]] = [:]
        private var layerMatrixCache: [Int: CGAffineTransform] = [:]
        
        init(renderer: Renderer, art: ArtParser, baseTransform: CGAffineTransform) {
            self.renderer = renderer
            self.art = art
            self.baseTransform = baseTransform
            self.baseTransformInv = baseTransform.inverted()
            
            var byLayer: [Int: [Int]] = [:]
            var fc = [Int: Bool]()
            var pendingCuts: [Int: [[Float]]] = [:]
            for (idx, a) in art.actions.enumerated() {
                guard let l = a["layer"] as? Int else { continue }
                switch a["action_name"] as? String {
                    case "cut":
                        if let r = renderer.parseFloatArray(a["selection_rect"]), r.count == 4 {
                            pendingCuts[l, default: []].append(r)
                        }
                    case "paste_layer":
                        var follows = false
                        if let rect = renderer.parseFloatArray(a["selection_rect"]), rect.count == 4 {
                            for r in pendingCuts[l] ?? [] {
                                if abs(r[0]-rect[0]) < 0.01, abs(r[1]-rect[1]) < 0.01,
                                   abs(r[2]-rect[2]) < 0.01, abs(r[3]-rect[3]) < 0.01 {
                                    follows = true
                                    break
                                }
                            }
                        }
                        fc[idx] = follows
                        pendingCuts[l] = nil   // paste_layer restarts the cycle
                    default:
                        break
                }
                if let l = a["layer"] as? Int {
                    byLayer[l, default: []].append(idx)
                }
            }
            self.followsCutByAction = fc
            self.actionsByLayer = byLayer
            
            var after = [CGAffineTransform?](repeating: nil, count: art.actions.count)
            var scan: CGAffineTransform? = nil
            for i in stride(from: art.actions.count - 1, through: 0, by: -1) {
                after[i] = scan
                if art.actions[i]["action_name"] as? String == "paste_layer",
                   let raw = renderer.parseMatrixRobust(art.actions[i]["matrix_1"]) {
                    scan = renderer.transformFromMatrix(raw.map { $0.map { Float($0) } }, scale: 1.0)
                }
            }
            self.nextPasteViewAfter = after
        }
        
        func layerMatrix(ofLayer i: Int) -> CGAffineTransform {
            if let m = layerMatrixCache[i] { return m }
            let m = renderer.layerMatrix(ofLayer: i, in: art)
            layerMatrixCache[i] = m
            return m
        }
    }
    
    // Renderer stored properties. CGAffineTransform isn't Hashable, hence the wrapper.
    internal struct ReplayCtxKey: Hashable {
        let a, b, c, d, tx, ty: CGFloat
        init(_ t: CGAffineTransform) {
            (a, b, c, d, tx, ty) = (t.a, t.b, t.c, t.d, t.tx, t.ty)
        }
    }
    
    //internal var replayContextPool: [ReplayCtxKey: ReplayContext] = [:] // defined on Renderer class already?
    
    /// Call as the FIRST line of render(art:). Validity relies on `art`
    /// being immutable during the pass; this resets state between passes.
    internal func invalidateReplayCaches() {
        replayContextPool.removeAll()
    }
    
    // MARK: - Layer Replay
    internal func buildStrokesForLayer(
        layerIndex: Int,
        art: ArtParser,
        baseTransform: CGAffineTransform,
        visited: Set<Int> = []
    ) -> [ResolvedStroke] {
        let key = ReplayCtxKey(baseTransform)
        let context: ReplayContext
        if let pooled = replayContextPool[key] {
            context = pooled
        } else {
            context = ReplayContext(renderer: self, art: art, baseTransform: baseTransform)
            replayContextPool[key] = context
        }
        return buildStrokesForLayer(layerIndex: layerIndex, context: context, visited: visited)
    }
    
    internal func buildStrokesForLayer(
        layerIndex: Int,
        context: ReplayContext,
        visited: Set<Int>
    ) -> [ResolvedStroke] {
        let art = context.art
        guard layerIndex >= 0, layerIndex < art.layers.count else { return [] }
        if visited.contains(layerIndex) { return [] }
        
        let cacheKey = ReplayContext.Key(layerIndex: layerIndex, visited: visited)
        if let cached = context.replayCache[cacheKey] { return cached }
        
        var resolvedStrokes: [ResolvedStroke] = []
        var currentPen = defaultPenInfo()
        var penMatrixScale: CGFloat = 1.0
        var shapeStrokes: [StrokeRecord] = []
        
        for actionIdx in context.actionsByLayer[layerIndex] ?? [] {
            let action = art.actions[actionIdx]
            guard let actionName = action["action_name"] as? String else { continue }
            
            switch actionName {
                case "pen_properties":
                    actionPenProperties(action: action, currentPen: &currentPen)
                    
                case "pen_matrix":
                    actionPenMatrix(action: action, currentPen: &currentPen,
                                    penMatrixScale: &penMatrixScale)
                    
                case "is_eraser":
                    actionIsEraser(action: action, currentPen: &currentPen)
                    
                case "pen_color":
                    actionPenColor(action: action, currentPen: &currentPen)
                    
                case "stroke", "polyline", "rect", "ellipse":
                    shapeStrokes.removeAll(keepingCapacity: true)
                    switch actionName {
                        case "stroke":
                            actionStroke(action: action, currentPen: currentPen,
                                         penMatrixScale: penMatrixScale, layerStrokes: &shapeStrokes)
                        case "polyline":
                            actionPolyline(action: action, currentPen: currentPen,
                                           penMatrixScale: penMatrixScale, layerStrokes: &shapeStrokes)
                        case "rect":
                            actionRect(action: action, currentPen: currentPen,
                                       penMatrixScale: penMatrixScale, layerStrokes: &shapeStrokes)
                        default:
                            actionEllipse(action: action, currentPen: currentPen,
                                          penMatrixScale: penMatrixScale, layerStrokes: &shapeStrokes)
                    }
                    resolvedStrokes.reserveCapacity(resolvedStrokes.count + shapeStrokes.count)
                    for stroke in shapeStrokes {
                        resolvedStrokes.append(ResolvedStroke(
                            stroke: stroke,
                            accumulatedDeviceTransform: .identity,
                            sourceLayerIndex: layerIndex,
                            selectionRect: []))
                    }
                    
                case "cut":
                    guard let rect = parseFloatArray(action["selection_rect"]),
                          rect.count == 4 else { continue }
                    let m1cut: CGAffineTransform
                    if let own = parseMatrixRobust(action["matrix_1"]) {
                        m1cut = transformFromMatrix(own.map { $0.map { Float($0) } }, scale: 1.0)
                    } else if let next = context.nextPasteViewAfter[actionIdx] {
                        m1cut = next
                    } else {
                        m1cut = .identity
                    }
                    for i in resolvedStrokes.indices {
                        resolvedStrokes[i].masks.append(StrokeMask(
                            m1: m1cut, rect: rect,
                            accRef: resolvedStrokes[i].accumulatedDeviceTransform,
                            erase: true))
                    }
                    
                case "paste_layer":
                    guard let fromLayer = action["from_layer"] as? Int,
                          fromLayer >= 0, fromLayer < art.layers.count,
                          let selectionRect = parseFloatArray(action["selection_rect"]),
                          selectionRect.count == 4,
                          let m1raw = parseMatrixRobust(action["matrix_1"]),
                          let m2raw = parseMatrixRobust(action["matrix_2"]) else { continue }
                    
                    let matrix1 = transformFromMatrix(m1raw.map { $0.map { Float($0) } }, scale: 1.0)
                    let matrix2 = transformFromMatrix(m2raw.map { $0.map { Float($0) } }, scale: 1.0)
                    let dstLayerMatrix = context.layerMatrix(ofLayer: layerIndex)
                    
                    let followsCut = context.followsCutByAction[actionIdx] ?? false
                    let pen: CGAffineTransform
                    let sel2Dev: CGAffineTransform
                    if isIdentityTransform(matrix1) {
                        pen = currentPen.penMatrixAffine ?? .identity
                        sel2Dev = matrix1.inverted().concatenating(pen)
                            .concatenating(dstLayerMatrix)
                    } else if followsCut {
                        pen = .identity
                        sel2Dev = matrix1.inverted()
                    } else {
                        pen = currentPen.penMatrixAffine ?? .identity
                        sel2Dev = pen.concatenating(dstLayerMatrix)
                    }
                    let pasteDeviceMap = context.baseTransformInv
                        .concatenating(matrix1).concatenating(matrix2)
                        .concatenating(sel2Dev).concatenating(context.baseTransform)
                    
                    // Clipboard semantics: the ENTIRE source layer is the paste source.
                    let sourceStrokes = buildStrokesForLayer(
                        layerIndex: fromLayer,
                        context: context,
                        visited: visited.union([layerIndex]))
                    
                    resolvedStrokes.reserveCapacity(resolvedStrokes.count + sourceStrokes.count)
                    for resolved in sourceStrokes {
                        var masks = resolved.masks
                        // Keep-mask for THIS paste's selection, recorded pre-move.
                        masks.append(StrokeMask(
                            m1: matrix1, rect: selectionRect,
                            accRef: resolved.accumulatedDeviceTransform,
                            erase: false))
                        resolvedStrokes.append(ResolvedStroke(
                            stroke: resolved.stroke,
                            accumulatedDeviceTransform:
                                resolved.accumulatedDeviceTransform.concatenating(pasteDeviceMap),
                            sourceLayerIndex: resolved.sourceLayerIndex,
                            selectionRect: selectionRect,
                            masks: masks))
                    }
                    
                case "merge_layer":
                    guard let fromLayer = action["from_layer"] as? Int,
                          fromLayer >= 0, fromLayer < art.layers.count else { continue }
                    
                    let sourceStrokes = buildStrokesForLayer(
                        layerIndex: fromLayer,
                        context: context,
                        visited: visited.union([layerIndex]))
                    
                    let mergeDeviceMap = context.baseTransformInv
                        .concatenating(context.layerMatrix(ofLayer: layerIndex))
                        .concatenating(context.baseTransform)
                    
                    resolvedStrokes.reserveCapacity(resolvedStrokes.count + sourceStrokes.count)
                    for resolved in sourceStrokes {
                        resolvedStrokes.append(ResolvedStroke(
                            stroke: resolved.stroke,
                            accumulatedDeviceTransform:
                                resolved.accumulatedDeviceTransform.concatenating(mergeDeviceMap),
                            sourceLayerIndex: resolved.sourceLayerIndex,
                            selectionRect: [],
                            masks: resolved.masks))
                    }
                    
                default:
                    break
            }
        }
        
        context.replayCache[cacheKey] = resolvedStrokes
        return resolvedStrokes
    }
    
    /// Initial action-time layer matrix: a layer with any layer_matrix action is
    /// action-driven from identity; a layer with none keeps its saved matrix.
    internal func initialActionLayerMatrix(layerIndex: Int, art: ArtParser) -> CGAffineTransform {
        let hasLayerMatrixAction = art.actions.contains { a in
            (a["layer"] as? Int) == layerIndex && (a["action_name"] as? String) == "layer_matrix"
        }
        return hasLayerMatrixAction ? .identity : layerMatrix(ofLayer: layerIndex, in: art)
    }
    
    internal func layerMatrix(ofLayer i: Int, in art: ArtParser) -> CGAffineTransform {
        guard i >= 0, i < art.layers.count,
              let raw = parseMatrixRobust(art.layers[i]["matrix"]) else { return .identity }
        return transformFromMatrix(raw.map { $0.map { Float($0) } }, scale: 1.0)
    }
    
    // MARK: - Action-Time Transform Resolution
    /// Cut rect corners in device y-down space (frame math + y conversion).
    internal func cutRectDeviceCorners(action: [String: Any], art: ArtParser,
                                       actionIndex: Int, baseTransform: CGAffineTransform) -> [CGPoint]? {
        guard let rect = parseFloatArray(action["selection_rect"]), rect.count == 4 else { return nil }
        let m1: CGAffineTransform
        if let own = parseMatrixRobust(action["matrix_1"]) {
            m1 = transformFromMatrix(own.map { $0.map { Float($0) } }, scale: 1.0)
        } else if let next = nextPasteViewMatrix(in: art.actions, after: actionIndex) {
            m1 = next
        } else {
            m1 = .identity
            print("CUT: no matrix_1 (own or following paste) — rect used as device px")
        }
        let deviceToFrame = baseTransform.inverted().concatenating(m1)
        let det = deviceToFrame.a * deviceToFrame.d - deviceToFrame.b * deviceToFrame.c
        guard abs(det) > 1e-12 else { return nil }
        let frameToDevice = deviceToFrame.inverted()
        
        let rectYFlip = verticalFlipTransform(canvasHeight: canvasSize.height * scale)
        let x = CGFloat(rect[0]), y = CGFloat(rect[1]), w = CGFloat(rect[2]), h = CGFloat(rect[3])
        
#if os(Linux)
        if gpExportMode {
            return [
                CGPoint(x: x, y: y), CGPoint(x: x + w, y: y),
                CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)
            ].map { $0.applying(frameToDevice).applying(rectYFlip) }
        } else {
            return [
                CGPoint(x: x, y: y), CGPoint(x: x + w, y: y),
                CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)
            ].map { $0.applying(frameToDevice) }
        }
#else
        return [
            CGPoint(x: x, y: y), CGPoint(x: x + w, y: y),
            CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)
        ].map { $0.applying(frameToDevice).applying(rectYFlip) }
#endif
    }
    
    /// Paste-mask rect corners in device y-down space (frame math + y conversion + destMap).
    internal func maskRectDeviceCorners(maskInv: CGAffineTransform, rect: [Float],
                                        destMap: CGAffineTransform) -> [CGPoint]? {
        guard rect.count == 4 else { return nil }
        let det = maskInv.a * maskInv.d - maskInv.b * maskInv.c
        guard abs(det) > 1e-12 else { return nil }
        let frameToSource = maskInv.inverted()
        let rectYFlip = verticalFlipTransform(canvasHeight: canvasSize.height * scale)
        let x = CGFloat(rect[0]), y = CGFloat(rect[1]), w = CGFloat(rect[2]), h = CGFloat(rect[3])
#if os(Linux)
        if gpExportMode {
            return [
                CGPoint(x: x, y: y), CGPoint(x: x + w, y: y),
                CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)
            ].map { $0.applying(frameToSource).applying(destMap).applying(rectYFlip) }
        } else {
            return [
                CGPoint(x: x, y: y), CGPoint(x: x + w, y: y),
                CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)
            ].map { $0.applying(frameToSource).applying(destMap) }
        }
#else
        return [
            CGPoint(x: x, y: y), CGPoint(x: x + w, y: y),
            CGPoint(x: x + w, y: y + h), CGPoint(x: x, y: y + h)
        ].map { $0.applying(frameToSource).applying(destMap).applying(rectYFlip) }
#endif
    }
    
    /// Free-transform pastes restore a cut made on the SAME layer: the file records a
    /// `cut` with the same selection_rect shortly before the paste_layer. New-layer
    /// pastes have no cut — the app creates the layer and drops the clipboard in.
    internal func pasteFollowsCut(art: ArtParser,
                                  layerIndex: Int,
                                  pasteActionIndex: Int,
                                  pasteRect: [Float]) -> Bool {
        var i = pasteActionIndex - 1
        while i >= 0 {
            let a = art.actions[i]
            if let l = a["layer"] as? Int, l == layerIndex,
               let name = a["action_name"] as? String {
                if name == "paste_layer" { return false }   // start of previous cycle
                if name == "cut",
                   let r = parseFloatArray(a["selection_rect"]), r.count == 4,
                   abs(r[0]-pasteRect[0]) < 0.01, abs(r[1]-pasteRect[1]) < 0.01,
                   abs(r[2]-pasteRect[2]) < 0.01, abs(r[3]-pasteRect[3]) < 0.01 {
                    return true
                }
            }
            i -= 1
        }
        return false
    }
    
    internal func nextPasteViewMatrix(in actions: [[String: Any]], after idx: Int) -> CGAffineTransform? {
        for j in (idx + 1)..<actions.count
        where actions[j]["action_name"] as? String == "paste_layer" {
            if let raw = parseMatrixRobust(actions[j]["matrix_1"]) {
                return transformFromMatrix(raw.map { $0.map { Float($0) } }, scale: 1.0)
            }
        }
        return nil
    }
    
}
