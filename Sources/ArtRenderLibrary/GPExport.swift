import Foundation
#if os(Linux)
import CoreFoundation
import Silica
#endif
import ArtParser

// MARK: - GP Export Data Structures

struct GPExportData: Codable {
    let version: Int
    let canvas: GPExportCanvas
    let radius_scale: Float
    let catmull_rom: Bool
    let layers: [GPExportLayer]
}

struct GPExportCanvas: Codable {
    let width: Int
    let height: Int
}

struct GPExportLayer: Codable {
    let name: String
    let opacity: Float
    let visible: Bool
    var strokes: [GPExportStroke]
}

struct GPExportStroke: Codable {
    let color: [Float]
    let is_eraser: Bool
    let hardness: Float
    let points: [GPExportPoint]
    var cut_rect: Bool? = nil   // NEW: true = selection-cut indicator (fill shape /
    //      erase region); points = 4 device-space rect corners
}

/// Ordered export items (draw order preserved): strokes and selection cuts.
enum GPExportItem {
    case stroke(StrokeRecord)
    case cut(corners: [CGPoint])   // device space, y-down
}

struct GPExportPoint: Codable {
    let x: Float             // device pixel space
    let y: Float             // device pixel space
    let radius: Float        // in pixels (plugin multiplies by radius_scale)
    let opacity: Float       // 0-1
}

// MARK: - Renderer GP Export Extension

extension Renderer {

    /// The item pipeline (strokes + cut rects) extracted from exportGPLayer so
    /// destination-layer content can also be appended to an existing paste layer.
    func exportGPStrokes(items: [GPExportItem],
                         artToDevice: CGAffineTransform,
                         canvasHeight: CGFloat,
                         resampleStep: CGFloat,
                         catmullRom: Bool) -> [GPExportStroke] {
        var exportStrokes: [GPExportStroke] = []
        let pencilStep = resampleStep * 0.75
        let flipTransform = verticalFlipTransform(canvasHeight: canvasHeight)
        
        for item in items {
            switch item {
                case .cut(let corners):
                    guard corners.count == 4 else { continue }
                    // corners are already in the JSON's y convention — no flip here
                    exportStrokes.append(GPExportStroke(
                        color: [0, 0, 0, 1], is_eraser: false, hardness: 1.0,
                        points: corners.map { GPExportPoint(x: Float($0.x), y: Float($0.y), radius: 1.0, opacity: 1.0) },
                        cut_rect: true))
                    
                case .stroke(let stroke):
                    guard !stroke.points.isEmpty else { continue }
                    // --- your existing scale calculations + exportGPStroke call, verbatim ---
                    let artToDeviceScaleX = sqrt(artToDevice.a * artToDevice.a + artToDevice.c * artToDevice.c)
                    let artToDeviceScaleY = sqrt(artToDevice.b * artToDevice.b + artToDevice.d * artToDevice.d)
                    var avgArtToDeviceScale = (artToDeviceScaleX + artToDeviceScaleY) / 2.0
                    if avgArtToDeviceScale <= 0.0 { avgArtToDeviceScale = 1.0 }
                    
                    var effectiveRadiusScale: CGFloat = stroke.penMatrixScale
                    if let affine = stroke.pen.penMatrixAffine {
                        let scaleX = sqrt(affine.a * affine.a + affine.c * affine.c)
                        let scaleY = sqrt(affine.b * affine.b + affine.d * affine.d)
                        effectiveRadiusScale = (scaleX + scaleY) / 2.0
                    }
                    effectiveRadiusScale *= avgArtToDeviceScale * 0.5
                    
                    var totalScale = avgArtToDeviceScale
                    if let affine = stroke.pen.penMatrixAffine {
                        let affineScale = sqrt(affine.b * affine.b + affine.d * affine.d)
                        totalScale *= affineScale / scale
                    }
                    
                    if let s = exportGPStroke(stroke: stroke, pointTransform: artToDevice,
                                              flipTransform: flipTransform, radiusScale: effectiveRadiusScale,
                                              totalScale: totalScale, resampleStep: resampleStep,
                                              pencilStep: pencilStep, catmullRom: catmullRom) {
                        exportStrokes.append(s)
                    }
            }
        }
        return exportStrokes
    }
    
    func exportGPLayer(items: [GPExportItem],
                       artToDevice: CGAffineTransform,
                       canvasHeight: CGFloat,
                       layerName: String,
                       layerOpacity: Float,
                       layerVisible: Bool,
                       resampleStep: CGFloat = 4.0,
                       catmullRom: Bool = false) -> GPExportLayer {
        GPExportLayer(
            name: layerName,
            opacity: layerOpacity,
            visible: layerVisible,
            strokes: exportGPStrokes(items: items, artToDevice: artToDevice,
                                     canvasHeight: canvasHeight, resampleStep: resampleStep,
                                     catmullRom: catmullRom))
    }

    /// Write accumulated GP export data to a JSON file
    func writeGPExportJSON(outputPath: String) -> Bool {
        let exportData = GPExportData(
            version: 1,
            canvas: GPExportCanvas(
                width: Int(canvasSize.width * scale),
                height: Int(canvasSize.height * scale)
            ),
            radius_scale: Float(gpExportRadiusScale),
            catmull_rom: gpExportCatmullRom,
            layers: gpExportLayers
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        
        guard let jsonData = try? encoder.encode(exportData) else {
            print("Error: Failed to encode GP export data to JSON")
            return false
        }
        
        do {
            try jsonData.write(to: URL(fileURLWithPath: outputPath))
            let totalStrokes = gpExportLayers.reduce(0) { $0 + $1.strokes.count }
            let totalPoints = gpExportLayers.reduce(0) { sum, layer in
                sum + layer.strokes.reduce(0) { $0 + $1.points.count }
            }
            print("GP export: \(gpExportLayers.count) layers, \(totalStrokes) strokes, \(totalPoints) points -> \(outputPath)")
            return true
        } catch {
            print("Error: Failed to write GP export file: \(error)")
            return false
        }
    }

    /// Main entry point for Grease Pencil export.
    /// Calls render() in export mode to iterate all layers, then writes JSON.
    public func exportToGreasePencil(
        art: ArtParser,
        outputPath: String,
        radiusScale: CGFloat = 0.01,
        resampleStep: CGFloat = 4.0,
        catmullRom: Bool = false
    ) -> Bool {
        gpExportMode = true
        gpExportRadiusScale = radiusScale
        gpExportResampleStep = resampleStep
        gpExportCatmullRom = catmullRom
        gpExportLayers = []
        gpExportOutputPath = outputPath
        
        // render() iterates layers and calls renderLayerIsolated()
        // which will accumulate export data in gpExportLayers
        _ = render(art: art)
        
        return writeGPExportJSON(outputPath: outputPath)
    }

    
    // MARK: - Stroke and Layer Export
    /// Per-stroke export body. pointTransform is applied AFTER the pen affine
    /// (art -> device y-down). radiusScale/totalScale come fully computed from the
    /// caller (regular layers: averaged; pastes: widest-axis selection rule).
    internal func exportGPStroke(stroke: StrokeRecord,
                                 pointTransform: CGAffineTransform,
                                 flipTransform: CGAffineTransform,
                                 radiusScale: CGFloat,
                                 totalScale: CGFloat,
                                 resampleStep: CGFloat,
                                 pencilStep: CGFloat,
                                 catmullRom: Bool) -> GPExportStroke? {
        guard !stroke.points.isEmpty else { return nil }
        var exportPoints: [GPExportPoint] = []
        
        if catmullRom {
            exportPoints.reserveCapacity(stroke.points.count)
            for point in stroke.points {
                let pressure = Float(max(0.0, point.p))
                var pt = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
                if let affine = stroke.pen.penMatrixAffine { pt = pt.applying(affine) }
                pt = pt.applying(pointTransform)
                pt = pt.applying(flipTransform)
                let (radius, opacity) = pressureToRadiusOpacity(
                    pressure: pressure, pen: stroke.pen, radiusScale: radiusScale, gamma: 1.0)
                exportPoints.append(GPExportPoint(x: Float(pt.x), y: Float(pt.y), radius: Float(radius), opacity: opacity))
            }
        } else {
            let targetStepInDevicePx: CGFloat = stroke.pen.type == 1 ? pencilStep : resampleStep
            let stampStepPx = targetStepInDevicePx / totalScale
            let splinePoints = buildResampledStrokeWithSpline(
                stroke.points, stepPx: stampStepPx, samplesPerSegment: 6, gamma: 1.0, isPolyline: stroke.isPolyline)
            let resampledArt: [ResampledPoint] = splinePoints.map {
                ResampledPoint(x: CGFloat($0.x), y: CGFloat($0.y), p: $0.p)
            }
            if resampledArt.isEmpty { return nil }
            // (end taper stays disabled for export, as before)
            exportPoints.reserveCapacity(resampledArt.count)
            for rp in resampledArt {
                var pt = CGPoint(x: rp.x, y: rp.y)
                if let affine = stroke.pen.penMatrixAffine { pt = pt.applying(affine) }
                pt = pt.applying(pointTransform)
                pt = pt.applying(flipTransform)
                let (radius, opacity) = pressureToRadiusOpacity(
                    pressure: rp.pressure, pen: stroke.pen, radiusScale: radiusScale, gamma: 1.0)
                exportPoints.append(GPExportPoint(x: Float(pt.x), y: Float(pt.y), radius: Float(radius), opacity: opacity))
            }
        }
        guard !exportPoints.isEmpty else { return nil }
        
        let hardness: Float
        if stroke.pen.type == 1 {
            hardness = 0.946
        } else if stroke.pen.opacityMin > 0.5 {
            hardness = 1.0
        } else {
            hardness = 1.0
        }
        let color: [Float] = [stroke.pen.color.r, stroke.pen.color.g, stroke.pen.color.b, 1.0]
        return GPExportStroke(color: color, is_eraser: stroke.pen.isEraser, hardness: hardness, points: exportPoints)
    }
    
    internal func cutRectStroke(exportCorners: [CGPoint]) -> GPExportStroke {
        GPExportStroke(color: [0, 0, 0, 1], is_eraser: false, hardness: 1.0,
                       points: exportCorners.map { GPExportPoint(x: Float($0.x), y: Float($0.y), radius: 1.0, opacity: 1.0) },
                       cut_rect: true)
    }
    
    
    /// One GP layer PER GROUP. A group's mask shapes (keep frames + erase quads)
    /// erase everything below them within their layer, so groups must not share
    /// one layer: masks scope to their own group in the source semantics (the
    /// renderers dispatch one masked paste per group). Stacking preserves group
    /// order; the LAST group's layer is the record subsequent content joins.
    internal func exportPasteLayers(resolved: ResolvedPasteRender,
                                    actionIndex: Int,
                                    isMerge: Bool,
                                    destLayerName: String,
                                    destLayerOpacity: Float,
                                    colorAlpha: Float,
                                    canvasHeight: CGFloat,
                                    resampleStep: CGFloat,
                                    catmullRom: Bool) -> [GPExportLayer] {
        let pencilStep = resampleStep * 0.75
        let exportFlip = verticalFlipTransform(canvasHeight: canvasHeight)
        let baseName = "\(destLayerName) [\(isMerge ? "merge" : "paste") \(actionIndex)]"
        var layers: [GPExportLayer] = []
        
        for (gi, g) in resolved.groups.enumerated() {
            // pen affine -> lb -> accNow -> destMap, then the export flip
            let pointTransform = g.lb.concatenating(g.accNow).concatenating(resolved.destMap)
            
            let lbScaleX = sqrt(g.lb.a * g.lb.a + g.lb.c * g.lb.c)
            let lbScaleY = sqrt(g.lb.b * g.lb.b + g.lb.d * g.lb.d)
            var avgLbScale = (lbScaleX + lbScaleY) / 2.0
            if avgLbScale <= 0.0 { avgLbScale = 1.0 }
            let selectionScale = maxAxisScale(g.accNow) * maxAxisScale(resolved.destMap)
            
            var strokes: [GPExportStroke] = []
            var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
            var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
            var maxRadius: CGFloat = 0
            
            for stroke in g.strokes {
                guard !stroke.points.isEmpty else { continue }
                var effectiveRadiusScale: CGFloat = stroke.penMatrixScale
                if let affine = stroke.pen.penMatrixAffine {
                    let sx = sqrt(affine.a * affine.a + affine.c * affine.c)
                    let sy = sqrt(affine.b * affine.b + affine.d * affine.d)
                    effectiveRadiusScale = (sx + sy) / 2.0
                }
                effectiveRadiusScale *= avgLbScale * selectionScale * 0.5
                
                var totalScale = avgLbScale * selectionScale
                if let affine = stroke.pen.penMatrixAffine {
                    let affineScale = sqrt(affine.b * affine.b + affine.d * affine.d)
                    totalScale *= affineScale / scale
                }
                
                if let s = exportGPStroke(stroke: stroke, pointTransform: pointTransform,
                                          flipTransform: exportFlip, radiusScale: effectiveRadiusScale,
                                          totalScale: totalScale, resampleStep: resampleStep,
                                          pencilStep: pencilStep, catmullRom: catmullRom) {
                    strokes.append(s)
                    for p in s.points {
                        minX = min(minX, CGFloat(p.x)); maxX = max(maxX, CGFloat(p.x))
                        minY = min(minY, CGFloat(p.y)); maxY = max(maxY, CGFloat(p.y))
                        maxRadius = max(maxRadius, CGFloat(p.radius))
                    }
                }
            }
            
            // This group's OWN content bounds — the keep frame only has to
            // cover this group's strokes (not the running union).
            guard minX <= maxX, minY <= maxY else { continue }
            let pad = maxRadius + 16.0
            let layerBounds = CGRect(x: minX - pad, y: minY - pad,
                                     width: (maxX - minX) + 2.0 * pad,
                                     height: (maxY - minY) + 2.0 * pad)
            
            for m in g.maskEntries {
                guard let devCorners = maskRectDeviceCorners(maskInv: m.inv, rect: m.rect,
                                                             destMap: resolved.destMap) else { continue }
                let exportCorners = devCorners      // already in the JSON's y convention
                if m.erase {
                    // erase INSIDE the mask rect: the quad itself
                    strokes.append(cutRectStroke(exportCorners: exportCorners))
                } else {
                    // keep: erase OUTSIDE via the frame — this group's layer only
                    for shape in outsideKeepFrameShapes(keepQuad: exportCorners, bounds: layerBounds) {
                        strokes.append(cutRectStroke(exportCorners: shape))
                    }
                }
            }
            
            guard !strokes.isEmpty else { continue }
            layers.append(GPExportLayer(
                name: gi == 0 ? baseName : "\(baseName) #\(gi + 1)",
                opacity: destLayerOpacity * colorAlpha,
                visible: true,
                strokes: strokes))
        }
        return layers
    }
    
    
    // MARK: - Export Bounds
    /// AABB of a cut_rect entry's corner points (JSON space).
    internal func cutEntryBox(_ s: GPExportStroke) -> CGRect {
        guard s.points.count >= 3 else { return .null }
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for p in s.points {
            minX = min(minX, CGFloat(p.x)); maxX = max(maxX, CGFloat(p.x))
            minY = min(minY, CGFloat(p.y)); maxY = max(maxY, CGFloat(p.y))
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    
    /// Drops cut_rect entries with nothing to erase on the record they're being
    /// written to (existing record content + this batch's strokes). contentBox is
    /// a superset of what any entry in the batch can reach, so this never drops
    /// an entry that would erase something — it only removes no-ops. Lower-record
    /// replication is gated separately (same criterion) and is unaffected.
    internal func dropNoOpCutEntries(_ strokes: [GPExportStroke], contentBox: CGRect) -> [GPExportStroke] {
        guard strokes.contains(where: { $0.cut_rect == true }) else { return strokes }
        guard !contentBox.isNull else { return strokes.filter { $0.cut_rect != true } }
        return strokes.filter { s in
            guard s.cut_rect == true else { return true }
            let box = cutEntryBox(s)
            return !box.isNull && contentBox.intersects(box)
        }
    }
    
    /// JSON-space bounds of exported strokes (points ± radius). cut_rect entries
    /// are erase operators and erasers carry no content — both are excluded from
    /// CONTENT bounds; pass includeErasers: true to measure an eraser's reach.
    internal func strokeBounds(_ strokes: [GPExportStroke], includeErasers: Bool = false) -> CGRect {
        var minX = CGFloat.greatestFiniteMagnitude, minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude, maxY = -CGFloat.greatestFiniteMagnitude
        for s in strokes {
            if s.cut_rect == true { continue }
            if s.is_eraser && !includeErasers { continue }
            for p in s.points {
                let r = CGFloat(p.radius)
                minX = min(minX, CGFloat(p.x) - r)
                maxX = max(maxX, CGFloat(p.x) + r)
                minY = min(minY, CGFloat(p.y) - r)
                maxY = max(maxY, CGFloat(p.y) + r)
            }
        }
        guard minX <= maxX, minY <= maxY else { return .null }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
    
    internal func unionBounds(_ a: CGRect, _ b: CGRect) -> CGRect {
        if a.isNull { return b }
        if b.isNull { return a }
        return a.union(b)
    }
    
    /// "Erase outside the keep quad" as up to 4 shapes: the outside of a convex quad
    /// is the union of the four outside-edge half-planes; clip the bounds polygon
    /// against each. Axis-aligned quads yield plain rectangles.
    internal func outsideKeepFrameShapes(keepQuad: [CGPoint], bounds: CGRect) -> [[CGPoint]] {
        guard keepQuad.count == 4 else { return [] }
        let cx = (keepQuad[0].x + keepQuad[1].x + keepQuad[2].x + keepQuad[3].x) / 4.0
        let cy = (keepQuad[0].y + keepQuad[1].y + keepQuad[2].y + keepQuad[3].y) / 4.0
        var area: CGFloat = 0
        for i in 0..<4 {
            let a = keepQuad[i], b = keepQuad[(i + 1) % 4]
            area += a.x * b.y - b.x * a.y
        }
        let boundsCorners = [
            CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY),
            CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.maxY)
        ]
        // Degenerate selection: keep nothing — erase the whole bounds.
        guard abs(area) > 1e-6 else { return [boundsCorners] }
        
        var shapes: [[CGPoint]] = []
        for i in 0..<4 {
            let p1 = keepQuad[i], p2 = keepQuad[(i + 1) % 4]
            let ex = p2.x - p1.x, ey = p2.y - p1.y
            func side(_ q: CGPoint) -> CGFloat { ex * (q.y - p1.y) - ey * (q.x - p1.x) }
            let centroidSide = side(CGPoint(x: cx, y: cy))
            guard abs(centroidSide) > 1e-9 else { continue }
            func isOutside(_ q: CGPoint) -> Bool { side(q) * centroidSide < 0 }   // boundary stays kept
            
            var clipped: [CGPoint] = []
            for j in 0..<boundsCorners.count {
                let cur = boundsCorners[j], nxt = boundsCorners[(j + 1) % boundsCorners.count]
                let curOut = isOutside(cur), nxtOut = isOutside(nxt)
                if nxtOut {
                    if !curOut { clipped.append(edgeLineIntersection(cur, nxt, p1: p1, ex: ex, ey: ey)) }
                    clipped.append(nxt)
                } else if curOut {
                    clipped.append(edgeLineIntersection(cur, nxt, p1: p1, ex: ex, ey: ey))
                }
            }
            if clipped.count >= 3 { shapes.append(clipped) }
        }
        return shapes
    }
    
    internal func edgeLineIntersection(_ a: CGPoint, _ b: CGPoint, p1: CGPoint, ex: CGFloat, ey: CGFloat) -> CGPoint {
        let sa = ex * (a.y - p1.y) - ey * (a.x - p1.x)
        let sb = ex * (b.y - p1.y) - ey * (b.x - p1.x)
        let denom = sa - sb
        guard abs(denom) > 1e-12 else { return a }
        let t = sa / denom
        return CGPoint(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y))
    }
}
