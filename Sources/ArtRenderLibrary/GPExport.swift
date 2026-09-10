import Foundation
#if os(Linux)
import CoreFoundation
import Silica
#endif
// import CoreGraphics
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
}
