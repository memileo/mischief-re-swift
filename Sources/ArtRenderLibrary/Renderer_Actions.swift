import Foundation
#if os(Linux)
import Silica
import CoreFoundation
//import Cairo
//import JPEG
#endif

extension Renderer {
    // MARK: - Pen State Actions
    internal func actionPenProperties(action: [String: Any], currentPen: inout PenInfo) {
        // Tolerant numeric parser: handles Float, Double, Int
        func num(_ v: Any?) -> Float? {
            switch v {
                case let f as Float: return f
                case let d as Double: return Float(d)
                case let i as Int: return Float(i)
                case let ui8 as UInt8: return Float(ui8)
                case let ui16 as UInt16: return Float(ui16)
                default: return nil
            }
        }
        
        // Read common pen values (if present)
        if let v = num(action["size"]) { currentPen.size = v }
        if let v = num(action["size_min"]) { currentPen.sizeMin = v }
        if let v = num(action["sizeMin"]) { currentPen.sizeMin = v }        // accept alternate key
        if let v = num(action["opacity"]) { currentPen.opacity = v }
        
        // Raw "opacity_min" in the action may actually encode a subType for some pen types.
        // Read it as subType first (but keep it available).
        var rawSubType: Float? = nil
        if let v = num(action["opacity_min"]) { rawSubType = v }
        else if let v = num(action["subType"]) { rawSubType = v }
        else if let v = num(action["sub_type"]) { rawSubType = v }
        
        // Read 'type' if supplied (may be Int or numeric)
        var penTypeVal: Int? = nil
        if let tAny = action["type"] {
            if let ti = tAny as? Int {
                penTypeVal = ti
            } else if let td = tAny as? Double {
                penTypeVal = Int(td)
            } else if let tf = tAny as? Float {
                penTypeVal = Int(tf)
            }
        }
        
        // Store the brush type in the PenInfo
        currentPen.type = penTypeVal
        
        /*
         | 'type': 1 - 'opacity_min': 1 | 'type': 0 - 'opacity_min': 0          | 'type': 1 - 'opacity_min': 1 |
         | ---------------------------- | --------------------------------------| ---------------------------- |
         | 'type': 2 - 'opacity_min': 1 | 'type': 0 - 'opacity_min': 0.80000... | 'type': 0 - 'opacity_min': 0 |
         
         Presets:
         | Noise                        | 'type': 1 - 'opacity_min': 1          | 'type': 1 - 'opacity_min': 1          | 'type': 1 - 'opacity_min': 1  |
         | ---------------------------- | ------------------------------------- | ------------------------------------- | ----------------------------- |
         | Noise                        | 'type': 1 - 'opacity_min': 1          | 'type': 1 - 'opacity_min': 1          | 'type': 1 - 'opacity_min': 1  |
         | ---------------------------- | ------------------------------------- | ------------------------------------- | ----------------------------- |
         | Solid                        | 'type': 0 - 'opacity_min': 0          | 'type': 0 - 'opacity_min': 0          | 'type': 0 - 'opacity_min': 0  |
         | ---------------------------- | ------------------------------------- | ------------------------------------- | ----------------------------- |
         | Solid with opacity dynamics  | 'type': 0 - 'opacity_min': 0.80000... | 'type': 0 - 'opacity_min': 0.80000... | 'type': 0 - 'opacity_min': 1  |
         | ---------------------------- | ------------------------------------- | ------------------------------------- | ----------------------------- |
         | Marker                       | 'type': 2 - 'opacity_min': 1          | 'type': 2 - 'opacity_min': 0          | 'type': 2 - 'opacity_min': 0  |
         
         Type 0: Solid
         Type 1: Noise
         Type 2: Marker    opacity_min 1: opacity dynamics   opacity_min 0: full opacity
         
         */
        
        // Determine derived opacityMin based on (type, subType) heuristics you provided.
        // Start from the explicit value if it really was intended as opacity_min; otherwise derive.
        var derivedOpacityMin: Float = currentPen.opacityMin // keep existing default
        
        if let type = penTypeVal {
            // Map behaviors for types/subTypes (heuristics)
            if type == 1 {
                // pencil -> treat as type 2 round shape, full pressure range
                derivedOpacityMin = 0.16 // 0.44
            } else if type == 0 {
                // solid
                if let st = rawSubType {
                    // type 0 cases:
                    currentPen.isMarker = false
                    
                    if abs(st - 0.0) < 0.0001 {
                        // subtype == 0 -> fully opaque behavior (min == max)
                        derivedOpacityMin = currentPen.opacity
                    } else if st > 0.7 {
                        // subtype ~0.8 -> low but non-zero min opacity
                        derivedOpacityMin = 0.15   // chosen low constant (0.1-0.2 range)
                    } else {
                        // other subtype values -> keep whatever default is currently set
                        derivedOpacityMin = currentPen.opacityMin
                    }
                } else {
                    // no subtype — keep current default
                    derivedOpacityMin = currentPen.opacityMin
                }
            } else if type == 2 {
                // marker
                // 45° pill shape ratio 1:4 diameter
                currentPen.isMarker = true
                
                if let st = rawSubType {
                    if st == 1.0 {
                        // full pressure range (0..opacity)
                        derivedOpacityMin = 0.0
                    } else {
                        // max opacity (safe)
                        derivedOpacityMin = 1.0
                    }
                } else {
                    // type 2, no subtype -> assume full pressure range
                    derivedOpacityMin = 0.0
                }
            } else {
                // unknown types — leave as-is
                derivedOpacityMin = currentPen.opacityMin
            }
        }
        //                else if let st = rawSubType {
        //                    // No type provided but a raw subtype exists — apply some safe defaults:
        //                    // Not sure this is ever the case, but ok
        //                    if st > 0.7 {
        //                        derivedOpacityMin = 0.15
        //                    } else if abs(st - 0.33) < 0.08 {
        //                        derivedOpacityMin = currentPen.opacityMin
        //                    } else {
        //                        derivedOpacityMin = currentPen.opacityMin
        //                    }
        //                }
        
        // Final clamp to [0,1]
        derivedOpacityMin = min(max(derivedOpacityMin, 0.0), 1.0)
        
        // Assign derived result back into pen snapshot
        currentPen.opacityMin = derivedOpacityMin
        
        //        print("stroke pen snapshot -> type=\(penTypeVal ?? -1), subType=\(rawSubType ?? -1), opacity=\(currentPen.opacity), opacityMin=\(currentPen.opacityMin)")
        
    }
    
    internal func actionPenMatrix(action: [String: Any], currentPen: inout PenInfo, penMatrixScale: inout CGFloat) {
        // Helper to coerce Any -> Double
        func toDouble(_ v: Any?) -> Double? {
            switch v {
                case let d as Double: return d
                case let f as Float: return Double(f)
                case let i as Int: return Double(i)
                case let s as String: return Double(s)
                default: return nil
            }
        }
        
        // Read matrix as [[Any]] or [[Double]]
        var a: Double = 1.0, b: Double = 0.0, c: Double = 0.0, d: Double = 1.0
        var tx: Double = 0.0, ty: Double = 0.0
        var parsed = false
        
        if let matAny = action["matrix"] as? [[Any]] {
            // Many files encode 4x4 row-major: mat[row][col]
            if matAny.count >= 4 && matAny[3].count >= 2 {
                // guess: layout like:
                // [ [a, b, ...],
                //   [c, d, ...],
                //   [...],
                //   [tx, ty, ..., 1] ]
                if let aa = toDouble(matAny[0][0]) { a = aa }
                if matAny[0].count > 1, let bb = toDouble(matAny[0][1]) { b = bb }
                if matAny.count > 1 && matAny[1].count > 0, let cc = toDouble(matAny[1][0]) { c = cc }
                if matAny.count > 1 && matAny[1].count > 1, let dd = toDouble(matAny[1][1]) { d = dd }
                if let txx = toDouble(matAny[3][0]) { tx = txx }
                if let tyy = toDouble(matAny[3][1]) { ty = tyy }
                parsed = true
            } else if matAny.count >= 2 && matAny[0].count >= 2 && matAny[1].count >= 2 {
                // fallback: take top-left 2x2 and row 2 as translation
                if let aa = toDouble(matAny[0][0]) { a = aa }
                if let bb = toDouble(matAny[0][1]) { b = bb }
                if let cc = toDouble(matAny[1][0]) { c = cc }
                if let dd = toDouble(matAny[1][1]) { d = dd }
                // translation not present — keep tx/ty = 0
                parsed = true
            }
        } else if let matDouble = action["matrix"] as? [[Double]] {
            if matDouble.count >= 4 && matDouble[3].count >= 2 {
                a = matDouble[0][0]; b = matDouble[0][1]
                c = matDouble[1][0]; d = matDouble[1][1]
                tx = matDouble[3][0]; ty = matDouble[3][1]
                parsed = true
            } else if matDouble.count >= 2 && matDouble[0].count >= 2 {
                a = matDouble[0][0]; b = matDouble[0][1]
                c = matDouble[1][0]; d = matDouble[1][1]
                parsed = true
            }
        }
        
        if parsed {
            // Compose candidate CGAffineTransform.
            // We use a layout where affine maps (x,y) -> (a*x + b*y + tx, c*x + d*y + ty)
            let affine = CGAffineTransform(a: CGFloat(a), b: CGFloat(b), c: CGFloat(c), d: CGFloat(d), tx: CGFloat(tx), ty: CGFloat(ty))
            
            // Compute numeric scale from affine (average column vector length)
            let sx = sqrt(a*a + c*c)
            let sy = sqrt(b*b + d*d)
            var computedScale = CGFloat((sx + sy) / 2.0)
            if !computedScale.isFinite || computedScale <= 0.0 { computedScale = 1.0 }
            
            // Store into current pen snapshot
            currentPen.penMatrixAffine = affine
            penMatrixScale = computedScale
            
            //            print("Parsed pen_matrix: a=\(a) b=\(b) c=\(c) d=\(d) tx=\(tx) ty=\(ty) scale=\(computedScale)")
        } else {
            print("Warning: couldn't parse pen_matrix action: \(action)")
        }
        
    }
    
    internal func actionIsEraser(action: [String: Any], currentPen: inout PenInfo) {
        if let isEraser = action["is_eraser"] as? Bool {
            currentPen.isEraser = isEraser
        }
    }
    
    internal func actionPenColor(action: [String: Any], currentPen: inout PenInfo) {
        // keep your reverted logic here — accept different encodings robustly
        if let t = action["color"] as? (Int, Int, Int) {
            currentPen.color = (r: Float(t.0)/255.0, g: Float(t.1)/255.0, b: Float(t.2)/255.0)
        } else if let arr = action["color"] as? [Any], arr.count >= 3 {
            if let r = arr[0] as? Int, let g = arr[1] as? Int, let b = arr[2] as? Int {
                currentPen.color = (r: Float(r)/255.0, g: Float(g)/255.0, b: Float(b)/255.0)
            } else if let r = arr[0] as? UInt8, let g = arr[1] as? UInt8, let b = arr[2] as? UInt8 {
                currentPen.color = (r: Float(r)/255.0, g: Float(g)/255.0, b: Float(b)/255.0)
            } else if let rf = arr[0] as? Float, let gf = arr[1] as? Float, let bf = arr[2] as? Float {
                currentPen.color = (r: rf, g: gf, b: bf)
            } else if let rd = arr[0] as? Double, let gd = arr[1] as? Double, let bd = arr[2] as? Double {
                currentPen.color = (r: Float(rd), g: Float(gd), b: Float(bd))
            }
        }
    }
    
    // MARK: - Stroke Actions
    internal func actionStroke(action: [String: Any], currentPen: PenInfo, penMatrixScale: CGFloat, layerStrokes: inout [StrokeRecord]) {
        // Parse points and create stroke record
        if let pts = action["points"] as? [[String: Any]], !pts.isEmpty {
            // Parse points
            let rawPoints: [Point] = pts.map { dict in
                let x = toFloat(dict["x"])
                let y = toFloat(dict["y"])
                let p = toFloat(dict["p"])
                //                        print("[P][raw point] x=\(x) y=\(y) p(raw)=\(p)")
                return Point(x: x, y: y, p: p)
            }
            
            // Create StrokeRecord
            let rec = StrokeRecord(
                points: rawPoints,
                pen: currentPen,
                penMatrixScale: penMatrixScale,
                penMatrixAffine: currentPen.penMatrixAffine,
                isPolyline: false
            )
            //                    if let first = rawPoints.first, let last = rawPoints.last {
            //                        print("[P][stroke record] points=\(rawPoints.count) p.first=\(first.p) p.last=\(last.p) pen.opacity=\(currentPen.opacity) pen.opacityMin=\(currentPen.opacityMin)")
            //                    }
            
            layerStrokes.append(rec)
        }
    }
    
    internal func actionPolyline(action: [String: Any], currentPen: PenInfo, penMatrixScale: CGFloat, layerStrokes: inout [StrokeRecord]) {
        if let pts = action["points"] as? [[String: Any]], !pts.isEmpty {
            // Parse points
            let rawPoints: [Point] = pts.map { dict in
                let x = toFloat(dict["x"])
                let y = toFloat(dict["y"])
                let p = toFloat(dict["p"])
                //                        print("[P][raw point] x=\(x) y=\(y) p(raw)=\(p)")
                return Point(x: x, y: y, p: p)
            }
            
            // Create StrokeRecord
            let rec = StrokeRecord(
                points: rawPoints,
                pen: currentPen,
                penMatrixScale: penMatrixScale,
                penMatrixAffine: currentPen.penMatrixAffine,
                isPolyline: true
            )
            //                    print("POLYLINE")
            
            layerStrokes.append(rec)
        }
    }
    
    internal func actionRect(action: [String: Any], currentPen: PenInfo, penMatrixScale: CGFloat, layerStrokes: inout [StrokeRecord]) {
        if let x = action["x"] as? Float,
           let y = action["y"] as? Float,
           let w = action["w"] as? Float,
           let h = action["h"] as? Float {
            let angle = action["angle"] as? Float ?? 0.0
            let cosA = cos(angle)
            let sinA = sin(angle)
            
            let halfW = w * 0.5
            let halfH = h * 0.5
            let localCorners: [(Float, Float)] = [
                (-halfW, -halfH),
                ( halfW, -halfH),
                ( halfW,  halfH),
                (-halfW,  halfH),
                (-halfW, -halfH)
            ]
            
            let pts: [Point] = localCorners.map { (dx, dy) in
                let rx = dx * cosA - dy * sinA
                let ry = dx * sinA + dy * cosA
                return Point(x: x + rx, y: y + ry, p: 1.0)
            }
            
            let rec = StrokeRecord(
                points: pts,
                pen: currentPen,
                penMatrixScale: penMatrixScale,
                penMatrixAffine: currentPen.penMatrixAffine,
                isPolyline: true
            )
            layerStrokes.append(rec)
        }
    }
    
    internal func actionEllipse(action: [String: Any], currentPen: PenInfo, penMatrixScale: CGFloat, layerStrokes: inout [StrokeRecord]) {
        if let cx = action["cx"] as? Float,
           let cy = action["cy"] as? Float,
           let rx = action["rx"] as? Float,
           let ry = action["ry"] as? Float {
            let angle = action["angle"] as? Float ?? 0.0
            let cosA = cos(angle)
            let sinA = sin(angle)
            
            let tx = -rx / 2.0
            let ty = -ry / 2.0
            
            // Generate points directly on the true ellipse.
            let segments = 128 // 96
            let twoPi: Float = 2.0 * .pi
            
            var pts: [Point] = []
            pts.reserveCapacity(segments + 1)
            for i in 0..<segments {
                let t = Float(i) / Float(segments) * twoPi
                let ex = rx * cos(t)
                let ey = ry * sin(t)
                
                let ox = ex + tx
                let oy = ey + ty
                
                let rotX = ox * cosA - oy * sinA
                let rotY = ox * sinA + oy * cosA
                
                pts.append(Point(x: cx + rotX, y: cy + rotY, p: 1.0))
            }
            
            // Explicitly close the loop for the polyline renderer
            if let firstPt = pts.first {
                pts.append(firstPt)
            }
            
            // Render as a dense polyline
            let rec = StrokeRecord(
                points: pts,
                pen: currentPen,
                penMatrixScale: penMatrixScale,
                penMatrixAffine: currentPen.penMatrixAffine,
                isPolyline: true
            )
            layerStrokes.append(rec)
        }
    }
    
    func toFloat(_ v: Any?) -> Float {
        if let f = v as? Float { return f }
        if let d = v as? Double { return Float(d) }
        if let i = v as? Int { return Float(i) }
        if let s = v as? String, let d = Double(s) { return Float(d) }
        return 0.0
    }
    
    func toInt(_ v: Any?) -> Int {
        if let i = v as? Int { return i }
        if let f = v as? Float { return Int(f) }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String, let d = Int(s) { return d }
        return 0
    }
    
    // MARK: - Visibility Decoding
    internal func getVisibility(from layer: [String: Any]) -> Bool {
        if let visibleInt = layer["visible"] as? Int {
            return visibleInt != 0
        } else if let visibleBool = layer["visible"] as? Bool {
            return visibleBool
        }
        return true  // Default to visible
    }
    
    internal func isStrokeVisible(_ strokePoints: [ResampledPoint], pen: PenInfo, minRadius: CGFloat = 0.5) -> Bool {
        guard !strokePoints.isEmpty else { return false }
        
        // Check if any point in the stroke has a radius large enough to be visible
        for point in strokePoints {
            let pressure = max(0.0, point.pressure) // Handle negative pressure
            let p = max(0.0, min(1.0, pressure)) // Pressure is already normalized
            
            // Calculate minimum possible radius for this point using the ACTUAL pen info
            let sizeMin = pen.sizeMin
            let sizeMax = pen.size
            let sizeRange = sizeMax - sizeMin
            let gamma: Float = 1.0
            let pg = powf(p, gamma)
            let minPossibleRadius = CGFloat(sizeMin + sizeRange * pg) * 0.5 // Apply a conservative radius scale
            
            if minPossibleRadius >= minRadius {
                return true
            }
        }
        
        return false
    }
    
    // MARK: - Value Parsing
    internal func parseMatrixRobust(_ v: Any?) -> [[Double]]? {
        if let m = v as? [[Double]] {
            return m
        }
        
        if let m = v as? [[Float]] {
            return m.map { row in
                row.map { Double($0) }
            }
        }
        
        if let mAny = v as? [[Any]] {
            var result: [[Double]] = []
            result.reserveCapacity(mAny.count)
            
            for row in mAny {
                var converted: [Double] = []
                converted.reserveCapacity(row.count)
                
                for item in row {
                    switch item {
                        case let d as Double:
                            converted.append(d)
                        case let f as Float:
                            converted.append(Double(f))
                        case let i as Int:
                            converted.append(Double(i))
                        case let i as Int32:
                            converted.append(Double(i))
                        case let i as Int64:
                            converted.append(Double(i))
                        case let s as String:
                            guard let d = Double(s) else {
                                return nil
                            }
                            converted.append(d)
                        default:
                            return nil
                    }
                }
                
                result.append(converted)
            }
            
            return result
        }
        
        // Some parser/debug paths expose the whole 4x4 matrix as a string.
        if let string = v as? String,
           let data = string.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data),
           let matrix = object as? [[Any]] {
            return parseMatrixRobust(matrix)
        }
        
        return nil
    }
    
    internal func parseFloatArray(_ v: Any?) -> [Float]? {
        if let arr = v as? [Float] { return arr }
        if let arr = v as? [Double] { return arr.map { Float($0) } }
        if let arrAny = v as? [Any] {
            var res: [Float] = []
            for item in arrAny {
                if let f = item as? Float { res.append(f) }
                else if let d = item as? Double { res.append(Float(d)) }
                else if let i = item as? Int { res.append(Float(i)) }
                else if let s = item as? String, let d = Double(s) { res.append(Float(d)) }
                else { return nil }
            }
            return res
        }
        return nil
    }
    
    internal func defaultPenInfo() -> PenInfo {
        return PenInfo(
            size: 5.0,
            sizeMin: 1.0,
            opacity: 1.0,
            opacityMin: 1.0,
            color: (r: 1.0, g: 0.0, b: 1.0),
            isEraser: false,
            isMarker: false,
            type: nil
        )
    }
}
