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
    let strokes: [GPExportStroke]
}

struct GPExportStroke: Codable {
    let color: [Float]       // [r, g, b, a] normalized 0-1
    let is_eraser: Bool
    let hardness: Float      // 0-1, derived from pen type
    let points: [GPExportPoint]
}

struct GPExportPoint: Codable {
    let x: Float             // device pixel space
    let y: Float             // device pixel space
    let radius: Float        // in pixels (plugin multiplies by radius_scale)
    let opacity: Float       // 0-1
}

// MARK: - Renderer GP Export Extension

extension Renderer {

    /// Process a layer's strokes into GP export format.
    /// Reuses the same resampling, taper, transform, and radius/opacity pipeline
    /// as the rendering path so exported data matches what the rasterizer produces.
    func exportGPLayer(
        layerStrokes: [StrokeRecord],
        artToDevice: CGAffineTransform,
        canvasHeight: CGFloat,
        layerName: String,
        layerOpacity: Float,
        layerVisible: Bool,
        resampleStep: CGFloat = 4.0,
        catmullRom: Bool = false
    ) -> GPExportLayer {
        
        var exportStrokes: [GPExportStroke] = []
        
        // Pencil step is 75% of the non-pencil base step
        let pencilStep = resampleStep * 0.75
        
        for stroke in layerStrokes {
            guard !stroke.points.isEmpty else { continue }
            
            // --- Common scale calculations ---
            let artToDeviceScaleX = sqrt(artToDevice.a * artToDevice.a + artToDevice.c * artToDevice.c)
            let artToDeviceScaleY = sqrt(artToDevice.b * artToDevice.b + artToDevice.d * artToDevice.d)
            var avgArtToDeviceScale = (artToDeviceScaleX + artToDeviceScaleY) / 2.0
            if avgArtToDeviceScale <= 0.0 { avgArtToDeviceScale = 1.0 }
            
            var effectiveRadiusScale: CGFloat = stroke.penMatrixScale
            if let affine = stroke.pen.penMatrixAffine {
                let scaleX = sqrt(affine.a * affine.a + affine.c * affine.c)
                let scaleY = sqrt(affine.b * affine.b + affine.d * affine.d)
                let affineScale = (scaleX + scaleY) / 2.0
                effectiveRadiusScale = affineScale
            }
            effectiveRadiusScale *= avgArtToDeviceScale * 0.5
            
            let flipTransform = verticalFlipTransform(canvasHeight: canvasHeight)
            
            // --- Build export points ---
            var exportPoints: [GPExportPoint] = []
            
            if catmullRom {
                // ── Catmull-Rom: use raw points as control points, skip resampling ──
                exportPoints.reserveCapacity(stroke.points.count)
                
                for point in stroke.points {
                    let pressure = Float(max(0.0, point.p))
                    var pt = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
                    
                    if let affine = stroke.pen.penMatrixAffine {
                        pt = pt.applying(affine)
                    }
                    pt = pt.applying(artToDevice)
                    pt = pt.applying(flipTransform)
                    
                    let (radius, opacity) = pressureToRadiusOpacity(
                        pressure: pressure,
                        pen: stroke.pen,
                        radiusScale: effectiveRadiusScale,
                        gamma: 1.0
                    )
                    
                    exportPoints.append(GPExportPoint(
                        x: Float(pt.x),
                        y: Float(pt.y),
                        radius: Float(radius),
                        opacity: opacity
                    ))
                }
            } else {
                // ── Resampled mode: step controlled by --resample-step flag ──
                let targetStepInDevicePx: CGFloat = stroke.pen.type == 1 ? pencilStep : resampleStep

                // Calculate the total scale from art space to final device space.
                // Both penMatrixAffine (draw-time zoom) and artToDevice (export transform)
                // are applied to points, so the step must compensate for their combined effect.
                var totalArtToDeviceScale = avgArtToDeviceScale
                if let affine = stroke.pen.penMatrixAffine {
                    let scaleY = sqrt(affine.b * affine.b + affine.d * affine.d)
                    let affineScale = scaleY
                    totalArtToDeviceScale *= affineScale
                }
                // Safety clamp to prevent degenerate steps
//                 totalArtToDeviceScale = max(totalArtToDeviceScale, 0.01)

                let stampStepPx = targetStepInDevicePx / totalArtToDeviceScale

                let splinePoints = buildResampledStrokeWithSpline(
                    stroke.points, stepPx: stampStepPx, samplesPerSegment: 6, gamma: 1.0, isPolyline: stroke.isPolyline
                )
                let resampledArt: [ResampledPoint] = splinePoints.map { p in
                    ResampledPoint(x: CGFloat(p.x), y: CGFloat(p.y), p: p.p)
                }
                
                if resampledArt.isEmpty { continue }
                
                // Apply end taper (same as rendering path)
                //            applyEndTaperToResampled(&resampledArt, tailSamples: 4, ease: 1.8)
                
                exportPoints.reserveCapacity(resampledArt.count)
                
                for rp in resampledArt {
                    let pressure = rp.pressure
                    var pt = CGPoint(x: rp.x, y: rp.y)
                    
                    if let affine = stroke.pen.penMatrixAffine {
                        pt = pt.applying(affine)
                    }
                    pt = pt.applying(artToDevice)
                    pt = pt.applying(flipTransform)
                    
                    let (radius, opacity) = pressureToRadiusOpacity(
                        pressure: pressure,
                        pen: stroke.pen,
                        radiusScale: effectiveRadiusScale,
                        gamma: 1.0
                    )
                    
                    exportPoints.append(GPExportPoint(
                        x: Float(pt.x),
                        y: Float(pt.y),
                        radius: Float(radius),
                        opacity: opacity
                    ))
                }
            }
            
            guard !exportPoints.isEmpty else { continue }
            
            // Derive hardness from pen type / opacityMin heuristics
            let hardness: Float
            if stroke.pen.type == 1 {
                // Pencil — softer edges for textured brush feel
                hardness = 0.946
            } else if stroke.pen.opacityMin > 0.5 {
                // High minimum opacity — hard/flat pen behavior
                hardness = 1.0
            } else {
                // Default round pen
                hardness = 1.0
            }
            
            let color: [Float] = [
                stroke.pen.color.r,
                stroke.pen.color.g,
                stroke.pen.color.b,
                1.0
            ]
            
            exportStrokes.append(GPExportStroke(
                color: color,
                is_eraser: stroke.pen.isEraser,
                hardness: hardness,
                points: exportPoints
            ))
        }
        
        return GPExportLayer(
            name: layerName,
            opacity: layerOpacity,
            visible: layerVisible,
            strokes: exportStrokes
        )
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
