import Foundation
#if os(Linux)
import Silica
import CoreFoundation
//import Cairo
//import JPEG
#elseif os(macOS)
import CoreGraphics
#endif

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

#if canImport(Metal)
import Metal
#endif

import ArtParser

public final class Renderer {
    internal let scale: CGFloat
    let canvasSize: CGSize
    let forceCPU: Bool
    let useSegmentRendering: Bool
    
    internal let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    
#if canImport(Metal)
    internal var layerTexture: MTLTexture?
    
    internal var metalRenderer: MetalRenderer?
    
#endif
    
    internal var noiseContextPool: [CGContext] = []
    internal let maxNoiseContextPoolSize = 5
    
    internal var noiseImage: CGImage? = nil
    internal var normalizedNoiseImage: CGImage? = nil
    internal var noiseImageSize: CGSize = .zero
    
    // GP Export state
    var gpExportMode = false
    var gpExportRadiusScale: CGFloat = 0.01
    var gpExportLayers: [GPExportLayer] = []
    var gpExportOutputPath: String?
    var gpExportResampleStep: CGFloat = 4.0
    var gpExportCatmullRom: Bool = false
    
    var replayContextPool: [ReplayCtxKey: ReplayContext] = [:]
    
    // MARK: - Lifecycle
    public init(canvasSize: CGSize, scale: CGFloat = 1.0, forceCPU: Bool = false, useSegmentRendering: Bool = true) {
        self.scale = scale
        self.canvasSize = canvasSize
        self.forceCPU = forceCPU
        self.useSegmentRendering = useSegmentRendering
        
        let possibleNames = [
            "noise",
            "noise.png",
            "Noise",
            "Noise.png",
            "Textures/noise",
            "Textures/noise.png"
        ]
        
        for name in possibleNames {
            loadNoiseImage(named: name)
            if noiseImage != nil {
                break
            }
        }
        
        if noiseImage == nil {
            print("WARNING: Could not load noise image from any of the attempted paths")
        }
        
        // Initialize Metal renderer if supported
#if canImport(Metal)
        if MetalRenderer.isSupported {
            do {
                guard let device = MTLCreateSystemDefaultDevice() else {
                    print("Metal device not available, falling back to CPU rendering")
                    return
                }
                
                self.metalRenderer = try MetalRenderer(device: device)
                
                metalRenderer?.createRenderTargets(width: Int(canvasSize.width * scale), height: Int(canvasSize.height * scale))
                
                if let noise = normalizedNoiseImage ?? noiseImage {
                    metalRenderer?.uploadNoiseTexture(from: noise)
                }
                
                // Also create a temporary texture for layer rendering
                createLayerTexture()
                
            } catch {
                print("Failed to create MetalRenderer: \(error)")
                self.metalRenderer = nil
            }
        }
        
        
        
        if forceCPU {
            MetalRenderer.useGPURendering = false
        } else if metalRenderer != nil {
            MetalRenderer.useGPURendering = true
        } else {
            MetalRenderer.useGPURendering = false
        }
        
#endif
    }
    
    // MARK: - Main Render Function
    public func render(art: ArtParser) -> CGImage? {
        // Create main bitmap context
#if os(Linux)
        guard let context = createLinuxBitmapContext(
            width: Int(canvasSize.width * scale),
            height: Int(canvasSize.height * scale)
        ) else {
            print("Creating context failed.")
            return nil
        }
#else
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let context = CGContext(
            data: nil,
            width: Int(canvasSize.width * scale),
            height: Int(canvasSize.height * scale),
            bitsPerComponent: 8,
            bytesPerRow: Int(canvasSize.width * scale * 4),
            space: colorSpace,
            bitmapInfo: bitmapInfo.rawValue
        ) else {
            return nil
        }
#endif
        // Sanity check
        //        print("PasteLayerMeta stride:", MemoryLayout<PasteLayerMeta>.stride, "should be 48")
        //        print("PasteMask stride:", MemoryLayout<PasteMask>.stride, "should be 64")
        //        Self.droppedPasteMaskCount = 0
#if os(macOS)
        // MAKE MAIN CONTEXT Y-DOWN
        context.scaleBy(x: 1, y: -1)
        context.translateBy(x: 0, y: -CGFloat(context.height))
#endif
        // Start with transparent context
        Self.clearContext(context, rect: CGRect(x: 0, y: 0, width: context.width, height: context.height))
        
        // Get the view matrix from art file
        let viewMatrix = art.viewMatrix
        let baseTransform = transformFromMatrix(viewMatrix, scale: scale)
        // TEMPORARY, for diagnosis only:
        //        let baseTransform = CGAffineTransform.identity
        //        print("actions per layer:",
        //              Dictionary(grouping: art.actions, by: { $0["layer"] as? Int ?? -1 })
        //            .mapValues(\.count))
        
        invalidateReplayCaches()
        
        // Process layers in order
        for layerIndex in art.layerOrder {
            guard layerIndex < art.layers.count else {
                continue
            }
            let layer = art.layers[layerIndex]
            
            let visible = getVisibility(from: layer)
            if !visible {
                continue
            }
            
            let layerOpacity = layer["opacity"] as? Float ?? 1.0
            
            // Render the layer with proper isolation
            let layerImage = renderLayerIsolated(
                layer: layer,
                layerIndex: layerIndex,
                art: art,
                baseTransform: baseTransform,
                layerOpacity: layerOpacity
            )
            
            // Composite the layer onto the main context
            if let layerImage = layerImage, !gpExportMode {
                context.saveGState()
                
                // Apply layer opacity
                context.setAlpha(CGFloat(layerOpacity))
                
                // Draw the layer
                context.draw(layerImage, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
                
                context.restoreGState()
            }
        }
        
        // Apply background after all layers are rendered
        context.saveGState()
        context.setBlendMode(.destinationOver)
        
        if !gpExportMode {
            // Get background color from art data
            let bgColor = art.backgroundColor
            let backgroundColor = (
                r: CGFloat(bgColor[0]) / 255.0,
                g: CGFloat(bgColor[1]) / 255.0,
                b: CGFloat(bgColor[2]) / 255.0
            )
            
            // Apply paper texture and background color logic
            if art.paperTextureId != 0 {
                let paperColor = getPaperColor(for: art.paperTextureId)
                let paperStrength = art.paperStrength
                
                // Create a temporary context for the paper texture compositing
                let paperContext = createBitmapContext(
                    size: CGSize(width: context.width, height: context.height),
                    scale: 1.0
                )
                
                // MAKE PAPER CONTEXT Y-DOWN
                paperContext.scaleBy(x: 1, y: -1)
                paperContext.translateBy(x: 0, y: -CGFloat(paperContext.height))
                
                if paperStrength > 0.0 {
                    // Composite tiled paper texture on top of paper color with paper strength alpha
                    renderPaperTexture(
                        textureData: art.paperTextureData,
                        paperColor: paperColor,
                        paperStrength: paperStrength,
                        backgroundColor: art.backgroundColor,
                        in: paperContext
                    )
                } else {
                    // Use paper color directly, skipping texture tiling
                    paperContext.setFillColor(createSRGBColor(r: paperColor.r, g: paperColor.g, b: paperColor.b))
                    paperContext.fill(CGRect(x: 0, y: 0, width: paperContext.width, height: paperContext.height))
                }
                
                // Apply background color multiplication (unless pure white)
                if backgroundColor.r != 1.0 || backgroundColor.g != 1.0 || backgroundColor.b != 1.0 {
                    paperContext.saveGState()
                    paperContext.setBlendMode(.multiply)
                    paperContext.setFillColor(createSRGBColor(r: backgroundColor.r, g: backgroundColor.g, b: backgroundColor.b))
                    paperContext.fill(CGRect(x: 0, y: 0, width: paperContext.width, height: paperContext.height))
                    paperContext.restoreGState()
                }
                
                // Draw the final paper with background to the main context
                if let finalPaperImage = paperContext.makeImage() {
                    context.draw(finalPaperImage, in: CGRect(x: 0, y: 0, width: context.width, height: context.height))
                }
            } else {
                // Use background color directly
                context.setFillColor(createSRGBColor(r: backgroundColor.r, g: backgroundColor.g, b: backgroundColor.b))
                context.fill(CGRect(x: 0, y: 0, width: context.width, height: context.height))
            }
        }
        context.restoreGState()
        
        return context.makeImage()
    }
    
    private func renderEmbeddedImages(art: ArtParser, in context: CGContext) {
        for imageInfo in art.images {
            
            guard imageInfo["textureId"] == nil || imageInfo["textureId"] as? Int == 0,
                  let rawData = imageInfo["raw"] as? [UInt8] else {
                print("continue")
                continue
            }
            print("wah!")
            let data = Data(rawData)
            
            // Create image from data (cross-platform)
#if os(Linux)
            guard let cgImage = Self.loadImageFromData(data) else {
                continue
            }
#else
            guard let imageProvider = Self.createDataProvider(from: data),
                  let cgImage = CGImage(
                    jpegDataProviderSource: imageProvider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent
                  ) ?? CGImage(
                    pngDataProviderSource: imageProvider,
                    decode: nil,
                    shouldInterpolate: true,
                    intent: .defaultIntent
                  ) else {
                continue
            }
#endif
            
            // Draw the image centered at (0,0) which is now the center of the screen
            let rect = CGRect(
                x: -CGFloat(cgImage.width) / 2.0,
                y: -CGFloat(cgImage.height) / 2.0,
                width: CGFloat(cgImage.width),
                height: CGFloat(cgImage.height)
            )
            
            context.draw(cgImage, in: rect)
            print("Image textureId: \(imageInfo["textureId"] ?? "nil")")
        }
    }
    
    // MARK: - Layer Rendering Drivers
    internal func renderLayerIsolated(
        layer: [String: Any],
        layerIndex: Int,
        art: ArtParser,
        baseTransform: CGAffineTransform,
        layerOpacity: Float
    ) -> CGImage? {
        
        guard let matrix = layer["matrix"] as? [[Float]] else { return nil }
        
        // 1. Pure Y-DOWN: Use toDirectCGTransform for everything
        let layerTransform = toDirectCGTransform(matrix)
        let artToDevice = CGAffineTransformConcat(layerTransform, baseTransform)
        
        //        let viewMatrix = art.viewMatrix
        
        let layerContext = createBitmapContext(size: canvasSize, scale: scale)
        Self.clearContext(layerContext, rect: CGRect(x: 0, y: 0, width: layerContext.width, height: layerContext.height))
        
        // 2. Pure Y-DOWN: flipTransform MUST be nil
        let flipTransform: CGAffineTransform? = nil
        
        var layerOps: [LayerOperation] = []
        //        var pendingCutRect: [Float] = []
        
        var currentPen = defaultPenInfo()
        var penMatrixScale: CGFloat = 1.0
        
        for (actionIdx, action) in art.actions.enumerated() {
            guard let actionLayer = action["layer"] as? Int,
                  actionLayer == layerIndex,
                  let actionName = action["action_name"] as? String else {
                continue
            }
            
            switch actionName {
                case "pen_properties": actionPenProperties(action: action, currentPen: &currentPen)
                case "pen_matrix": actionPenMatrix(action: action, currentPen: &currentPen, penMatrixScale: &penMatrixScale)
                case "is_eraser": actionIsEraser(action: action, currentPen: &currentPen)
                case "pen_color": actionPenColor(action: action, currentPen: &currentPen)
                    
                case "stroke":
                    var tempStrokes: [StrokeRecord] = []
                    actionStroke(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                    layerOps.append(contentsOf: tempStrokes.map { .stroke($0) })
                    
                case "polyline":
                    var tempStrokes: [StrokeRecord] = []
                    actionPolyline(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                    layerOps.append(contentsOf: tempStrokes.map { .stroke($0) })
                    
                case "rect":
                    var tempStrokes: [StrokeRecord] = []
                    actionRect(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                    layerOps.append(contentsOf: tempStrokes.map { .stroke($0) })
                    
                case "ellipse":
                    var tempStrokes: [StrokeRecord] = []
                    actionEllipse(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                    layerOps.append(contentsOf: tempStrokes.map { .stroke($0) })
                    
                case "cut":
                    if let rect = parseFloatArray(action["selection_rect"]), rect.count == 4 {
                        let m1: CGAffineTransform
                        if let own = parseMatrixRobust(action["matrix_1"]) {
                            m1 = transformFromMatrix(own.map { $0.map { Float($0) } }, scale: 1.0)
                        } else if let next = nextPasteViewMatrix(in: art.actions, after: actionIdx) {
                            m1 = next
                        } else {
                            m1 = .identity  // fallback: treat rect as current device px
                            print("CUT: no matrix_1 (own or following paste) — rect used as device px")
                        }
                        layerOps.append(.cut(meta: CutMeta(
                            inverseAffine: baseTransform.inverted().concatenating(m1),
                            rect: rect, edgeWidth: 0.75)))
                    }
                    
                case "paste_layer":
                    layerOps.append(contentsOf: actionPasteLayerOps(
                        action: action,
                        art: art,
                        targetLayerIndex: layerIndex,
                        actionIndex: actionIdx,
                        dstPenAffine: currentPen.penMatrixAffine ?? .identity,
                        baseTransform: baseTransform,
                        flipTransform: flipTransform))
                    
                case "merge_layer":
                    layerOps.append(contentsOf: actionMergeLayerOps(
                        action: action,
                        art: art,
                        targetLayerIndex: layerIndex,
                        actionIndex: actionIdx,
                        baseTransform: baseTransform,
                        flipTransform: nil))
                    
                default: break
            }
        }
        
        // ── GP Export: accumulate layer data, skip rasterization ──
        if gpExportMode {
            let layerName = layer["name"] as? String ?? "Layer \(layerIndex)"
            let layerVisible = (layer["visible"] as? Int ?? 1) != 0
            let exportCanvasHeight = canvasSize.height * scale
            
            // Everything drawn after a paste/merge is appended to that paste's GP
            // layer, so erasers erase the pasted content (and everything drawn on
            // that layer before them). The destination layer's own record holds
            // only what was drawn before the first paste. Cuts erase everything
            // below them at action time: the entry joins the pending stream (it
            // lands at its position in whichever record is active) and is
            // replicated into every lower record.
            var records: [GPExportLayer] = []
            var pendingItems: [GPExportItem] = []
            var writingIndex: Int? = nil      // record the pending stream flushes into (nil = new base record)
            
            
            // Erasers act on the flat composite: replicate an eraser entry into
            // lower records whose content it touches — earlier paste groups AND
            // earlier records. Bounds-checked so distant layers get nothing.
            func replicateEraserDown(_ s: GPExportStroke, from: Int = 0, below idx: Int) {
                let reach = strokeBounds([s], includeErasers: true)
                guard !reach.isNull else { return }
                for i in from..<idx where !recordBounds[i].isNull && recordBounds[i].intersects(reach) {
                    records[i].strokes.append(s)
                }
            }
            
            var recordBounds: [CGRect] = []    // content bounds per record, JSON space
            
            func flushPending() {
                let items = pendingItems
                pendingItems = []
                if let w = writingIndex {
                    guard !items.isEmpty else { return }
                    var appended = exportGPStrokes(
                        items: items, artToDevice: artToDevice, canvasHeight: exportCanvasHeight,
                        resampleStep: gpExportResampleStep, catmullRom: gpExportCatmullRom)
                    // in-position cut entries: keep only where there is content to erase
                    // (the paste layer's own strokes count — a cut over the island is real)
                    let contentBox = unionBounds(recordBounds[w], strokeBounds(appended))
                    appended = dropNoOpCutEntries(appended, contentBox: contentBox)
                    records[w].strokes.append(contentsOf: appended)
                    recordBounds[w] = unionBounds(recordBounds[w], strokeBounds(appended))
                    
                    // erasers drawn on the user-facing layer: reach down
                    for s in appended where s.is_eraser {
                        replicateEraserDown(s, below: w)
                    }
                } else {
                    guard items.contains(where: { item -> Bool in
                        if case .stroke = item { return true }
                        return false
                    }) else { return }
                    var layer = exportGPLayer(
                        items: items,
                        artToDevice: artToDevice,
                        canvasHeight: exportCanvasHeight,
                        layerName: layerName,
                        layerOpacity: layerOpacity,
                        layerVisible: layerVisible,
                        resampleStep: gpExportResampleStep,
                        catmullRom: gpExportCatmullRom)
                    layer.strokes = dropNoOpCutEntries(layer.strokes, contentBox: strokeBounds(layer.strokes))
                    records.append(layer)
                    recordBounds.append(strokeBounds(layer.strokes))
                    writingIndex = records.count - 1
                }
            }
            
            var currentPen = defaultPenInfo()
            var penMatrixScale: CGFloat = 1.0
            var actionLayerMatrix = initialActionLayerMatrix(layerIndex: layerIndex, art: art)
            
            for (actionIdx, action) in art.actions.enumerated() {
                guard let actionLayer = action["layer"] as? Int,
                      actionLayer == layerIndex,
                      let actionName = action["action_name"] as? String else { continue }
                
                switch actionName {
                    case "pen_properties":
                        actionPenProperties(action: action, currentPen: &currentPen)
                    case "pen_matrix":
                        actionPenMatrix(action: action, currentPen: &currentPen, penMatrixScale: &penMatrixScale)
                    case "is_eraser":
                        actionIsEraser(action: action, currentPen: &currentPen)
                    case "pen_color":
                        actionPenColor(action: action, currentPen: &currentPen)
                    case "layer_matrix":
                        if let mRaw = parseMatrixRobust(action["matrix"]) {
                            actionLayerMatrix = transformFromMatrix(mRaw.map { $0.map { Float($0) } }, scale: 1.0)
                        }
                        
                    case "stroke", "polyline", "rect", "ellipse":
                        var tempStrokes: [StrokeRecord] = []
                        switch actionName {
                            case "stroke":
                                actionStroke(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                            case "polyline":
                                actionPolyline(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                            case "rect":
                                actionRect(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                            default:
                                actionEllipse(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                        }
                        pendingItems.append(contentsOf: tempStrokes.map { GPExportItem.stroke($0) })
                        
                    case "cut":
                        guard let devCorners = cutRectDeviceCorners(
                            action: action, art: art, actionIndex: actionIdx, baseTransform: artToDevice) else { break }
                        // in-position entry: erases the active record's content drawn before it
                        pendingItems.append(.cut(corners: devCorners))
                        // geometric replication: the cut erases everything below it at
                        // action time — but only lower records whose CONTENT intersects
                        // the rect need the entry.
                        let cutEntry = GPExportStroke(
                            color: [0, 0, 0, 1], is_eraser: false, hardness: 1.0,
                            points: devCorners.map { GPExportPoint(x: Float($0.x), y: Float($0.y), radius: 1.0, opacity: 1.0) },
                            cut_rect: true)
                        var cbMinX = devCorners[0].x, cbMaxX = devCorners[0].x
                        var cbMinY = devCorners[0].y, cbMaxY = devCorners[0].y
                        for p in devCorners {
                            cbMinX = min(cbMinX, p.x); cbMaxX = max(cbMaxX, p.x)
                            cbMinY = min(cbMinY, p.y); cbMaxY = max(cbMaxY, p.y)
                        }
                        let cutBox = CGRect(x: cbMinX, y: cbMinY, width: cbMaxX - cbMinX, height: cbMaxY - cbMinY)
                        for i in 0..<(writingIndex ?? records.count) {
                            if !recordBounds[i].isNull && recordBounds[i].intersects(cutBox) {
                                records[i].strokes.append(cutEntry)
                            }
                        }
                        
                    case "paste_layer":
                        if let resolved = resolvePasteRender(
                            action: action, art: art, targetLayerIndex: layerIndex, actionIndex: actionIdx,
                            dstPenAffine: currentPen.penMatrixAffine ?? .identity,
                            dstLayerMatrix: actionLayerMatrix,
                            baseTransform: artToDevice) {
                            let groupLayers = exportPasteLayers(
                                resolved: resolved, actionIndex: actionIdx, isMerge: false,
                                destLayerName: layerName, destLayerOpacity: layerOpacity, colorAlpha: 1.0,
                                canvasHeight: exportCanvasHeight,
                                resampleStep: gpExportResampleStep, catmullRom: gpExportCatmullRom)
                            if !groupLayers.isEmpty {
                                flushPending()
                                let firstNew = records.count
                                records.append(contentsOf: groupLayers)
                                recordBounds.append(contentsOf: groupLayers.map { strokeBounds($0.strokes) })
                                // Pasted erasers act on the flat composite too: earlier
                                // groups of this paste (below their own layer in the
                                // stack) and everything under the paste. Their own
                                // group's content is already handled in-position.
                                for gi in groupLayers.indices {
                                    for s in groupLayers[gi].strokes where s.is_eraser {
                                        replicateEraserDown(s, below: firstNew + gi)
                                    }
                                }
                                writingIndex = records.count - 1
                            }
                        }
                        
                    case "merge_layer":
                        let opacitySrc = action["opacity_src"] as? Float ?? 1.0
                        if let resolved = resolveMergeRender(
                            action: action, art: art, targetLayerIndex: layerIndex, baseTransform: artToDevice) {
                            let groupLayers = exportPasteLayers(
                                resolved: resolved, actionIndex: actionIdx, isMerge: true,
                                destLayerName: layerName, destLayerOpacity: layerOpacity, colorAlpha: opacitySrc,
                                canvasHeight: exportCanvasHeight,
                                resampleStep: gpExportResampleStep, catmullRom: gpExportCatmullRom)
                            if !groupLayers.isEmpty {
                                flushPending()
                                let firstNew = records.count
                                records.append(contentsOf: groupLayers)
                                recordBounds.append(contentsOf: groupLayers.map { strokeBounds($0.strokes) })
                                // MERGE: erasers from the merged layer erase only that layer's
                                // own content — the sibling groups of this merge (from: firstNew).
                                // They must NOT reach the destination's records below.
                                for gi in groupLayers.indices {
                                    for s in groupLayers[gi].strokes where s.is_eraser {
                                        replicateEraserDown(s, from: firstNew, below: firstNew + gi)
                                    }
                                }
                                writingIndex = records.count - 1
                            }
                        }
                        
                    default: break
                }
            }
            
            flushPending()
            gpExportLayers.append(contentsOf: records)
            return nil
        }
        
#if os(macOS)
        // Render all strokes for this layer with Metal if available
        //        let useSegmentRendering: Bool = true
        print("useSegmentRendering: ", useSegmentRendering )
        print("forceCPU: ", forceCPU)
        if useSegmentRendering,
           let mr = self.metalRenderer,
           !layerOps.isEmpty,
           MetalRenderer.useGPURendering {
            
            do {
                let w = Int(self.canvasSize.width * self.scale)
                let h = Int(self.canvasSize.height * self.scale)
                
                if let image = try mr.renderSegmentGroupsInOrderSync(
                    layerOps: layerOps,
                    width: w,
                    height: h,
                    artToDevice: artToDevice,
                    flipTransform: flipTransform
                ) {
                    // 3. Pure Y-DOWN: Do NOT flip the image. Metal outputs Y-DOWN, CGContext expects Y-DOWN.
                    return image
                }
                return nil
                
            } catch {
                print("Segment rendering failed: \(error) \n Rendering on CPU.")
                return renderLayerWithCPU(
                    art: art,
                    layerIndex: layerIndex,
                    artToDevice: artToDevice,
                    context: layerContext
                )
            }
        } else if let mr = self.metalRenderer, !layerOps.isEmpty, MetalRenderer.useGPURendering {
            // ── GPU stamp path (re-enabled) ──
            // Resampled-stamp rendering (kept for its tapers). Cuts are CoreGraphics rect
            // erases on the compositing context; pastes/merges render as isolated GPU stamp
            // layers with the selection transforms baked into the point data, and their
            // masks are applied as CPU inside/outside erases.
            if let image = renderLayerWithGPUStamps(
                art: art,
                layerIndex: layerIndex,
                artToDevice: artToDevice,
                context: layerContext,
                metalRenderer: mr
            ) {
                return image
            }
            // Stamp path failed (layerContext may hold partial output) — CPU fallback on a fresh context
            let freshContext = createBitmapContext(size: canvasSize, scale: scale)
            Self.clearContext(freshContext, rect: CGRect(x: 0, y: 0, width: freshContext.width, height: freshContext.height))
            return renderLayerWithCPU(art: art, layerIndex: layerIndex, artToDevice: artToDevice, context: freshContext)
        }
#endif
        // ── CPU path (re-enabled) ──
        // Linux / no Metal renderer / GPU rendering disabled: action-order rendering with
        // CoreGraphics cut rectangles and isolated paste layers. Noise stays off.
        return renderLayerWithCPU(
            art: art,
            layerIndex: layerIndex,
            artToDevice: artToDevice,
            context: layerContext
        )
    }
    
    // CPU Fallback Function
    internal func renderLayerWithCPU(
        art: ArtParser,
        layerIndex: Int,
        artToDevice: CGAffineTransform,
        context: CGContext
    ) -> CGImage? {
        
        var currentPen = defaultPenInfo()
        var penMatrixScale: CGFloat = 1.0
        var actionLayerMatrix = initialActionLayerMatrix(layerIndex: layerIndex, art: art)
        
        for (actionIdx, action) in art.actions.enumerated() {
            guard let actionLayer = action["layer"] as? Int,
                  actionLayer == layerIndex,
                  let actionName = action["action_name"] as? String else { continue }
            
            switch actionName {
                case "pen_properties":
                    actionPenProperties(action: action, currentPen: &currentPen)
                case "pen_matrix":
                    actionPenMatrix(action: action, currentPen: &currentPen, penMatrixScale: &penMatrixScale)
                case "is_eraser":
                    actionIsEraser(action: action, currentPen: &currentPen)
                case "pen_color":
                    actionPenColor(action: action, currentPen: &currentPen)
                    
                case "stroke", "polyline", "rect", "ellipse":
                    var tempStrokes: [StrokeRecord] = []
                    switch actionName {
                        case "stroke":
                            actionStroke(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                        case "polyline":
                            actionPolyline(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                        case "rect":
                            actionRect(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                        default:
                            actionEllipse(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                    }
                    for stroke in tempStrokes {
                        drawStrokeOnCPU(stroke: stroke, lb: artToDevice, accNow: .identity, destMap: .identity, context: context)
                    }
                    
                case "cut":
                    applyCutRectCPU(context: context, action: action, art: art, actionIndex: actionIdx, baseTransform: artToDevice)
                    
                case "paste_layer":
                    guard let resolved = resolvePasteRender(
                        action: action, art: art, targetLayerIndex: layerIndex, actionIndex: actionIdx,
                        dstPenAffine: currentPen.penMatrixAffine ?? .identity,
                        dstLayerMatrix: actionLayerMatrix,
                        baseTransform: artToDevice) else { continue }
                    renderPasteGroupsCPU(resolved: resolved, context: context)
                    
                case "merge_layer":
                    guard let resolved = resolveMergeRender(
                        action: action, art: art, targetLayerIndex: layerIndex,
                        baseTransform: artToDevice) else { continue }
                    renderPasteGroupsCPU(resolved: resolved, context: context)
                    
                case "layer_matrix":
                    if let mRaw = parseMatrixRobust(action["matrix"]) {
                        actionLayerMatrix = transformFromMatrix(mRaw.map { $0.map { Float($0) } }, scale: 1.0)
                    }
                    
                default: break
            }
        }
        
        // Render embedded images (unchanged — this code already draws in device coords)
        context.saveGState()
        context.translateBy(x: CGFloat(context.width) / 2.0, y: CGFloat(context.height) / 2.0)
        context.concatenate(artToDevice)
        renderEmbeddedImages(art: art, in: context)
        context.restoreGState()
        
        return context.makeImage()
    }

#if canImport(Metal)
    // Resampled-stamp GPU rendering via renderStrokesInOrderSync. Action order is
    // preserved by flushing GPU runs at every cut/paste boundary:
    //   - strokes     -> stamp batches in the current run (draw or erase kind)
    //   - erase runs  -> rendered as alpha coverage, composited with .destinationOut
    //                    so they erase everything composited below (incl. pasted content)
    //   - cut         -> flush + CoreGraphics rect erase on the layer context
    //   - paste/merge -> flush + isolated GPU layer per group + CPU mask erases
    // Returns nil on GPU failure; the caller falls back to the CPU path.
    internal func renderLayerWithGPUStamps(
        art: ArtParser,
        layerIndex: Int,
        artToDevice: CGAffineTransform,
        context: CGContext,
        metalRenderer: MetalRenderer
    ) -> CGImage? {
        
        let w = Int(canvasSize.width * scale)
        let h = Int(canvasSize.height * scale)
        
        enum RunKind { case draw, erase }
        var run: (kind: RunKind, batches: [(stamps: [Stamp], color: SIMD4<Float>, isMarker: Bool)])? = nil
        
        func flushRun() -> Bool {
            guard let r = run, !r.batches.isEmpty else { run = nil; return true }
            run = nil
            let groups = r.batches.map {
                (stamps: $0.stamps, color: $0.color, isEraser: false,
                 isMarker: r.kind == .erase ? false : $0.isMarker)
            }
            let image: CGImage
            do {
                guard let img = try metalRenderer.renderStrokesInOrderSync(strokeGroups: groups, width: w, height: h) else {
                    print("GPU stamp flush returned nil (\(r.kind) run, \(r.batches.count) batch(es))")
                    return false
                }
                image = img
            } catch {
                print("GPU stamp flush failed: \(error)")
                return false
            }
            compositeImageCPU(image: image, erase: r.kind == .erase, into: context)
            return true
        }
        
        func appendRun(_ kind: RunKind,
                       _ batch: (stamps: [Stamp], color: SIMD4<Float>, isMarker: Bool)) -> Bool {
            if run?.kind != kind {
                if !flushRun() { return false }
                run = (kind: kind, batches: [])
            }
            run!.batches.append(batch)
            return true
        }
        
        var currentPen = defaultPenInfo()
        var penMatrixScale: CGFloat = 1.0
        var failed = false
        var actionLayerMatrix = initialActionLayerMatrix(layerIndex: layerIndex, art: art)
        
        for (actionIdx, action) in art.actions.enumerated() {
            guard let actionLayer = action["layer"] as? Int,
                  actionLayer == layerIndex,
                  let actionName = action["action_name"] as? String else { continue }
            
            switch actionName {
                case "pen_properties":
                    actionPenProperties(action: action, currentPen: &currentPen)
                case "pen_matrix":
                    actionPenMatrix(action: action, currentPen: &currentPen, penMatrixScale: &penMatrixScale)
                case "is_eraser":
                    actionIsEraser(action: action, currentPen: &currentPen)
                case "pen_color":
                    actionPenColor(action: action, currentPen: &currentPen)
                    
                case "stroke", "polyline", "rect", "ellipse":
                    var tempStrokes: [StrokeRecord] = []
                    switch actionName {
                        case "stroke":
                            actionStroke(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                        case "polyline":
                            actionPolyline(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                        case "rect":
                            actionRect(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                        default:
                            actionEllipse(action: action, currentPen: currentPen, penMatrixScale: penMatrixScale, layerStrokes: &tempStrokes)
                    }
                    for stroke in tempStrokes {
                        guard let batch = buildStampBatch(stroke: stroke, lb: artToDevice, accNow: .identity, destMap: .identity) else { continue }
                        if !appendRun(stroke.pen.isEraser ? .erase : .draw,
                                      (stamps: batch.stamps, color: batch.color, isMarker: batch.isMarker)) {
                            failed = true
                            break
                        }
                    }
                    
                case "cut":
                    if !flushRun() { failed = true; break }
                    applyCutRectCPU(context: context, action: action, art: art, actionIndex: actionIdx,
                                    baseTransform: artToDevice)
                    
                    // flushRun() composite:
                    //                    compositeImageCPU(image: image, erase: r.kind == .erase, into: context)
                    
                    
                    
                case "paste_layer":
                    if !flushRun() { failed = true; break }
                    if let resolved = resolvePasteRender(
                        action: action, art: art, targetLayerIndex: layerIndex, actionIndex: actionIdx,
                        dstPenAffine: currentPen.penMatrixAffine ?? .identity,
                        dstLayerMatrix: actionLayerMatrix,
                        baseTransform: artToDevice) {
                        if !renderPasteGroupsWithGPUStamps(resolved: resolved, context: context,
                                                           metalRenderer: metalRenderer) {
                            failed = true
                            break
                        }
                    }
                    
                case "merge_layer":
                    if !flushRun() { failed = true; break }
                    if let resolved = resolveMergeRender(
                        action: action, art: art, targetLayerIndex: layerIndex,
                        baseTransform: artToDevice) {
                        if !renderPasteGroupsWithGPUStamps(resolved: resolved, context: context,
                                                           metalRenderer: metalRenderer) {
                            failed = true
                            break
                        }
                    }
                    
                case "layer_matrix":
                    if let mRaw = parseMatrixRobust(action["matrix"]) {
                        actionLayerMatrix = transformFromMatrix(mRaw.map { $0.map { Float($0) } }, scale: 1.0)
                    }
                    
                default: break
            }
            if failed { break }
        }
        
        if !failed, !flushRun() { failed = true }
        if failed { return nil }
        
        // Render embedded images (same placement as the CPU path)
        context.saveGState()
        context.translateBy(x: CGFloat(context.width) / 2.0, y: CGFloat(context.height) / 2.0)
        context.concatenate(artToDevice)
        renderEmbeddedImages(art: art, in: context)
        context.restoreGState()
        
        return context.makeImage()
    }
#endif
}

// MARK: - Performance Monitoring
internal class PerformanceMonitor {
    static let shared = PerformanceMonitor()
    
    private var timers: [String: TimeInterval] = [:]
    private var counters: [String: Int] = [:]
    private let lock = NSLock()
    
    private init() {}
    
    func startTimer(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        timers[name] = CFAbsoluteTimeGetCurrent()
    }
    
    func endTimer(_ name: String) -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        
        guard let startTime = timers[name] else { return 0 }
        let endTime = CFAbsoluteTimeGetCurrent()
        let duration = endTime - startTime
        timers.removeValue(forKey: name)
        
        // Log slow operations (> 16ms)
        if duration > 0.016 {
            print("⚠︎ Performance: \(name) took \(String(format: "%.2f", duration * 1000))ms")
        }
        
        return duration
    }
    
    func incrementCounter(_ name: String) {
        lock.lock()
        defer { lock.unlock() }
        counters[name, default: 0] += 1
    }
    
    //        func getCounter(_ name: String) -> Int { // unused?
    //            lock.lock()
    //            defer { lock.unlock() }
    //            return counters[name, default: 0]
    //        }
    
    //        func printStats() { // unused?
    //            lock.lock()
    //            defer { lock.unlock() }
    //
    //            print("=== Performance Stats ===")
    //            for (name, count) in counters {
    //                print("Counter: \(name) = \(count)")
    //            }
    //            print("========================")
    //        }
    
    //        func reset() { // unused?
    //            lock.lock()
    //            defer { lock.unlock() }
    //
    //            timers.removeAll()
    //            counters.removeAll()
    //        }
}

// MARK: - PNG Output
//extension Renderer {
//    private static func saveCGImageAsPNG(_ image: CGImage, to path: String) {
//#if canImport(ImageIO) && canImport(UniformTypeIdentifiers)
//        let url = URL(fileURLWithPath: path)
//        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
//            print("Failed to create image destination")
//            return
//        }
//
//        CGImageDestinationAddImage(destination, image, nil)
//        if !CGImageDestinationFinalize(destination) {
//            print("Failed to finalize image destination")
//        }
//#elseif canImport(ImageIO)
//        // ImageIO available but UTType not (older macOS)
//        let url = URL(fileURLWithPath: path)
//        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
//            print("Failed to create image destination")
//            return
//        }
//
//        CGImageDestinationAddImage(destination, image, nil)
//        if !CGImageDestinationFinalize(destination) {
//            print("Failed to finalize image destination")
//        }
//#elseif os(Linux)
//        // Linux fallback: write raw RGBA data as PPM (simple format) or use Cairo directly
//        // For a proper PNG, integrate with a Linux PNG library or Silica's export capabilities
//        print("WARNING: PNG export not yet implemented for Linux. Path: \(path)")
//        // TODO: Implement PNG export on Linux using Cairo's cairo_surface_write_to_png
//        // or a cross-platform Swift PNG library
//#endif
//    }
//}
