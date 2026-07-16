// Swift 5.5+ (macOS 12+, Linux compatible)
// Port of mischief-re/artparser.py
// Notes:
// - Avoids newer Swift features for macOS 12 compatibility.
// - Uses Foundation only; no AppKit.
// To compile separately: swiftc -whole-module-optimization -O artparser.swift lzunpack.swift EmptyArtData.swift PressureEval.swift -o artparser

import Foundation
#if os(Linux)
import CoreFoundation
#endif

// MARK: - Phase unwrap pressure
func unwrapPressureSequence(rawPs: [Int]) -> [Int] {
    let count = rawPs.count
    guard count > 0 else { return [] }
    if count == 1 { return rawPs }
    
    let mod: Double = 1024.0
    let maxValue: Double = 4095.0
    let beamWidth = 6
    
    let raws = rawPs.map { Double($0) }
    let anchor = raws[0]
    
    func getCandidates(raw: Double, refAbs: Double) -> (v0: Double, v1: Double, v2: Double, count: Int) {
        let base = Int(round((refAbs - raw) / mod))
        var v0: Double = 0, v1: Double = 0, v2: Double = 0
        var cnt = 0
        for n in [base - 1, base, base + 1] {
            let cand = raw + (Double(n) * mod)
            if cand >= 0.0 && cand <= maxValue {
                switch cnt {
                case 0: v0 = cand
                case 1: v1 = cand
                case 2: v2 = cand
                default: break
                }
                cnt += 1
            }
        }
        if cnt == 0 {
            let cand = raw + (Double(base) * mod)
            if cand >= 0.0 && cand <= maxValue { v0 = cand; cnt = 1 }
        }
        return (v0, v1, v2, cnt)
    }
    
    struct State {
        let cost: Double
        let prevIndex: Int
        let value: Double
        let prevVelocity: Double
    }
    
    var history: [[State]] = []
    history.reserveCapacity(count)
    
    var currentStates: [State] = []
    let ic = getCandidates(raw: raws[1], refAbs: anchor)
    for j in 0..<ic.count {
        let cand = j == 0 ? ic.v0 : j == 1 ? ic.v1 : ic.v2
        let vel = cand - anchor
        currentStates.append(State(cost: 0.05 * abs(vel), prevIndex: -1, value: cand, prevVelocity: vel))
    }
    history.append(currentStates)
    
    if count == 2 {
        let best = currentStates.min(by: { $0.cost < $1.cost })!
        return [Int(round(anchor)), Int(round(best.value))]
    }
    
    for i in 2..<count {
        var newStates: [State] = []
        newStates.reserveCapacity(beamWidth * 3)
        
        for (si, state) in currentStates.enumerated() {
            let prevAbs = state.value
            let cands = getCandidates(raw: raws[i], refAbs: prevAbs)
            
            for j in 0..<cands.count {
                let cand = j == 0 ? cands.v0 : j == 1 ? cands.v1 : cands.v2
                let vel = cand - prevAbs
                let jerk = abs(vel - state.prevVelocity)
                let stepPenalty = 1e-3 * abs(vel)
                var boundaryPenalty = 0.0
                if cand <= 0.0 || cand >= maxValue { boundaryPenalty = 0.25 }
                var reversalPenalty = 0.0
                if i >= count - 2 && state.prevVelocity < 0.0 && vel > 0.0 {
                    reversalPenalty = 5.0 * (abs(state.prevVelocity) + abs(vel))
                }
                let totalCost = state.cost + jerk + stepPenalty + boundaryPenalty + reversalPenalty
                newStates.append(State(cost: totalCost, prevIndex: si, value: cand, prevVelocity: vel))
            }
        }
        
        newStates.sort(by: { $0.cost < $1.cost })
        if newStates.count > beamWidth {
            newStates.removeLast(newStates.count - beamWidth)
        }
        
        history.append(newStates)
        currentStates = newStates
    }
    
    // Backtrack to reconstruct path
    guard let bestIdx = currentStates.indices.min(by: { currentStates[$0].cost < currentStates[$1].cost }) else {
        return rawPs
    }
    
    var path = [Double](repeating: 0, count: count)
    path[0] = anchor
    
    var idx = bestIdx
    for i in stride(from: count - 1, through: 1, by: -1) {
        let state = history[i - 1][idx]
        path[i] = state.value
        idx = state.prevIndex
    }
    
    let unwrappedPs = path.map { Int(round($0)) }
    //    print("unwrappedPs: ", unwrappedPs)
    return boostLines(pressureSequence: unwrappedPs)
}

func boostLines(pressureSequence: [Int], linearShift: Int = 100) -> [Int] {
    let maxVal = 4095
    
    return pressureSequence.map { rawVal in
        let result = rawVal + linearShift
        
        // --- COMMENTED OUT: Curve Boost (More aggressive on lighter values) ---
        // Uncomment and use this block instead of 'let result' above to try a curve.
        // This formula adds a larger chunk of the remaining headroom to lighter values.
        /*
         let normalized = Double(rawVal) / Double(maxVal)
         // Factor 0.5 adds 50% of the distance to the max value.
         // Example: 100 -> 100 + 0.5*(3995) = ~2097 (Significant boost)
         // Example: 3000 -> 3000 + 0.5*(1095) = ~3547 (Small boost)
         let factor = 0.5
         let boosted = Double(rawVal) + (Double(maxVal) - Double(rawVal)) * factor
         let result = Int(round(boosted))
         */
        
        return max(0, min(maxVal, result))
    }
}


// MARK: - Custom Matrix Formatter
extension Array where Element == Array<Float> {
    func toMatrixString() -> String {
        var result = "["
        var firstRow = true
        
        for row in self {
            if !firstRow {
                result += ", "
            } else {
                firstRow = false
            }
            
            result += "["
            var firstElement = true
            
            for element in row {
                if !firstElement {
                    result += ", "
                } else {
                    firstElement = false
                }
                
                // Use faster string conversion without formatting
                result += String(element)
            }
            
            result += "]"
        }
        
        result += "]"
        return result
    }
}

// MARK: - Codable Structs for JSON Encoding/Decoding
struct CodablePenInfo: Codable {
    let type: Int
    let color: [UInt8]
    let noise: Float
    let size: Float
    let sizeMin: Float
    let opacity: Float
    let opacityMin: Float
    let isEraser: Int
    
    enum CodingKeys: String, CodingKey {
        case type, color, noise, size, sizeMin, opacity, opacityMin, isEraser
    }
    
    init(from penInfo: [String: Any]) {
        self.type = penInfo["type"] as! Int
        self.color = penInfo["color"] as! [UInt8]
        self.noise = penInfo["noise"] as! Float
        self.size = penInfo["size"] as! Float
        self.sizeMin = penInfo["size_min"] as! Float
        self.opacity = penInfo["opacity"] as! Float
        self.opacityMin = penInfo["opacity_min"] as! Float
        self.isEraser = penInfo["is_eraser"] as! Int
    }
    
    // Custom dictionary representation for better formatting
    func toDictionary() -> [String: Any] {
        return [
            "type": type,
            "color": color,
            "is_eraser": isEraser,
            "opacity_min": opacityMin,
            "size": size,
            "opacity": opacity,
            "noise": noise,
            "size_min": sizeMin
        ]
    }
}

struct CodablePin: Codable {
    let matrix: [[Float]]
    let name: String
    
    init(from pin: [String: Any]) {
        self.matrix = pin["matrix"] as! [[Float]]
        self.name = pin["name"] as! String
    }
    
    // Custom dictionary representation for better formatting
    func toDictionary() -> [String: Any] {
        return [
            "matrix": matrix.toMatrixString(),
            "name": name
        ]
    }
}

struct CodableLayer: Codable {
    let visible: Int
    let opacity: Float
    let name: String
    let actionCount: Int
    let matrix: [[Float]]
    let zoom: Float
    
    enum CodingKeys: String, CodingKey {
        case visible, opacity, name, actionCount, matrix, zoom
    }
    
    init(from layer: [String: Any]) {
        self.visible = layer["visible"] as! Int
        self.opacity = layer["opacity"] as! Float
        self.name = layer["name"] as! String
        self.actionCount = layer["action_count"] as! Int
        self.matrix = layer["matrix"] as! [[Float]]
        self.zoom = layer["zoom"] as! Float
    }
    
    // Custom dictionary representation for better formatting
    func toDictionary() -> [String: Any] {
        return [
            "action_count": actionCount,
            "matrix": matrix.toMatrixString(),
            "zoom": zoom,
            "name": name,
            "opacity": opacity,
            "visible": visible
        ]
    }
}

struct CodableImage: Codable {
    let type: Int
    let raw: [UInt8]
    
    init(from image: [String: Any]) {
        self.type = image["type"] as! Int
        self.raw = image["raw"] as! [UInt8]
    }
    
    // Custom dictionary representation for better formatting
    func toDictionary() -> [String: Any] {
        return [
            "type": type,
            "raw": "<\(raw.count) bytes>"
        ]
    }
}

struct CodableAction: Codable {
    let layer: Int
    let actionId: Int
    let actionName: String?
    let argument: Int?
    let x: Float?
    let y: Float?
    let pressure: Float?
    let x1: Float?
    let y1: Float?
    let x2: Float?
    let y2: Float?
    let width: Float?
    let height: Float?
    let visible: Int?
    let opacity: Float?
    let name: String?
    let matrix: [[Float]]?
    let zoom: Float?
    let type: Int?
    let color: [UInt8]?
    let noise: Float?
    let size: Float?
    let sizeMin: Float?
    let opacityMin: Float?
    let isEraser: Bool?
    let points: [StrokePoint]?
    
    enum CodingKeys: String, CodingKey {
        case layer = "layer"
        case actionId = "action_id"
        case actionName = "action_name"
        case argument = "argument"
        case x = "x"
        case y = "y"
        case pressure = "p"
        case x1 = "x1"
        case y1 = "y1"
        case x2 = "x2"
        case y2 = "y2"
        case width = "width"
        case height = "height"
        case visible = "visible"
        case opacity = "opacity"
        case name = "name"
        case matrix = "matrix"
        case zoom = "zoom"
        case type = "type"
        case color = "color"
        case noise = "noise"
        case size = "size"
        case sizeMin = "size_min"
        case opacityMin = "opacity_min"
        case isEraser = "is_eraser"
        case points = "points"
    }
    
    init(from action: [String: Any]) {
        self.layer = action["layer"] as! Int
        self.actionId = action["action_id"] as! Int
        self.actionName = action["action_name"] as? String
        self.argument = action["argument"] as? Int
        self.x = action["x"] as? Float
        self.y = action["y"] as? Float
        
        // Updated to handle Int, Double, or Float
        if let pressureInt = action["p"] as? Int {
            self.pressure = Float(pressureInt)
        } else if let pressureDouble = action["p"] as? Double {
            self.pressure = Float(pressureDouble)
        } else if let pressureFloat = action["p"] as? Float {
            self.pressure = pressureFloat
        } else {
            self.pressure = nil
        }
        self.x1 = action["x1"] as? Float
        self.y1 = action["y1"] as? Float
        self.x2 = action["x2"] as? Float
        self.y2 = action["y2"] as? Float
        self.width = action["width"] as? Float
        self.height = action["height"] as? Float
        self.visible = action["visible"] as? Int
        self.opacity = action["opacity"] as? Float
        self.name = action["name"] as? String
        self.matrix = action["matrix"] as? [[Float]]
        self.zoom = action["zoom"] as? Float
        self.type = action["type"] as? Int
        self.color = action["color"] as? [UInt8]
        self.noise = action["noise"] as? Float
        self.size = action["size"] as? Float
        self.sizeMin = action["size_min"] as? Float
        self.opacityMin = action["opacity_min"] as? Float
        self.isEraser = action["is_eraser"] as? Bool
        
        // Convert points from [String: Any] to StrokePoint
        if let pointsArray = action["points"] as? [[String: Any]] {
            self.points = pointsArray.map { StrokePoint(from: $0) }
        } else {
            self.points = nil
        }
    }
    
    func toDictionary() -> [String: Any] {
        var dict: [String: Any] = [
            "action_id": actionId,
            "layer": layer
        ]
        
        if let actionName = actionName {
            dict["action_name"] = actionName
        }
        
        if let argument = argument {
            dict["argument"] = argument
        }
        
        if let x = x {
            dict["x"] = x
        }
        
        if let y = y {
            dict["y"] = y
        }
        
        if let pressure = pressure {
            dict["p"] = pressure
        }
        
        if let x1 = x1 {
            dict["x1"] = x1
        }
        
        if let y1 = y1 {
            dict["y1"] = y1
        }
        
        if let x2 = x2 {
            dict["x2"] = x2
        }
        
        if let y2 = y2 {
            dict["y2"] = y2
        }
        
        if let width = width {
            dict["width"] = width
        }
        
        if let height = height {
            dict["height"] = height
        }
        
        if let visible = visible {
            dict["visible"] = visible
        }
        
        if let opacity = opacity {
            dict["opacity"] = opacity
        }
        
        if let name = name {
            dict["name"] = name
        }
        
        if let matrix = matrix {
            dict["matrix"] = matrix.toMatrixString()
        }
        
        if let zoom = zoom {
            dict["zoom"] = zoom
        }
        
        if let type = type {
            dict["type"] = type
        }
        
        if let color = color {
            dict["color"] = color
        }
        
        if let noise = noise {
            dict["noise"] = noise
        }
        
        if let size = size {
            dict["size"] = size
        }
        
        if let sizeMin = sizeMin {
            dict["size_min"] = sizeMin
        }
        
        if let opacityMin = opacityMin {
            dict["opacity_min"] = opacityMin
        }
        
        if let isEraser = isEraser {
            dict["is_eraser"] = isEraser
        }
        
        if let points = points {
            dict["points"] = points.map { $0.toDictionary() }
        }
        
        return dict
    }
}


struct CodableArtData: Codable {
    let penInfo: CodablePenInfo
    let viewMatrix: [[Double]]
    let viewZoom: Double
    let layerOrder: [Int]
    let pins: [CodablePin]
    let layers: [CodableLayer]
    let images: [CodableImage]
    let actions: [CodableAction]
    let backgroundColor: [UInt8]
    let paperStrength: Float
    let paperTextureId: Int
    let paperTextureData: [UInt8]
    
    init(from art: ArtParser) {
        self.penInfo = CodablePenInfo(from: art.penInfo)
        
        // Use high precision values if available
        if !art.highPrecisionViewMatrix.isEmpty {
            self.viewMatrix = art.highPrecisionViewMatrix
            self.viewZoom = art.highPrecisionViewZoom
        } else {
            self.viewMatrix = art.viewMatrix.map { row in
                row.map { Double($0) }
            }
            self.viewZoom = Double(art.viewMatrix.first?.first ?? 0)
        }
        
        self.layerOrder = art.layerOrder
        self.pins = art.pins.map { CodablePin(from: $0) }
        self.layers = art.layers.map { CodableLayer(from: $0) }
        self.images = art.images.map { CodableImage(from: $0) }
        self.actions = art.actions.map { CodableAction(from: $0) }
        self.backgroundColor = art.backgroundColor
        self.paperStrength = art.paperStrength
        self.paperTextureId = art.paperTextureId
        self.paperTextureData = art.paperTextureData
    }
    
    // Simplified toPythonStyleString with reduced formatting but maintaining precision
    func toPythonStyleString() -> String {
        var result = ""
        
        // Background information
        result += "background color: \(backgroundColor)\n"
        result += "paper strength: \(String(format: "%.16g", paperStrength))\n"
        result += "paper texture id: \(String(format: "%02d", paperTextureId))\n"
        result += "paper texture data: <\(paperTextureData.count) bytes>\n"
        
        // Pen info
        result += "pen info:\n"
        let penDict = penInfo.toDictionary()
        let penInfoStr = penDict.map { key, value in
            if let floatVal = value as? Float {
                return "'\(key)': \(String(format: "%.16g", floatVal))"
            } else if let intVal = value as? Int {
                return "  '\(key)': \(intVal)"
            } else if let arrayVal = value as? [UInt8] {
                return "  '\(key)': \(arrayVal)"
            } else {
                return "  '\(key)': \(value)"
            }
        }.joined(separator: ",\n  ")
        result += "{\(penInfoStr)}\n"
        
        // View matrix with high precision
        result += "view matrix:\n"
        result += "[\n"
        for i in 0..<viewMatrix.count {
            let row = viewMatrix[i]
            let rowStr = row.map { doubleValue in
                return String(format: "%.17g", doubleValue)
            }.joined(separator: ", ")
            result += "  [\(rowStr)]"
            if i < viewMatrix.count - 1 {
                result += ","
            }
            result += "\n"
        }
        result += "]\n"
        
        // View zoom
        result += "view zoom: \(String(format: "%.16g", viewZoom))\n"
        
        // Layer order
        result += "layer order:\n"
        result += "  \(layerOrder)\n"
        
        // Pins
        result += "pins:\n"
        if pins.isEmpty {
            result += "  None\n"
        } else {
            let pinsStr = pins.map { pin in
                let pinDict = pin.toDictionary()
                return "  {\(pinDict.map { "\($0): \($1)" }.joined(separator: ", "))}"
            }.joined(separator: ",\n")
            result += "[\n\(pinsStr)\n]"
        }
        
        // Layer info
        result += "layer info:"
        let layersStr = layers.map { layer in
            let layerDict = layer.toDictionary()
            return "{\n  \(layerDict.map { "\($0): \($1)" }.joined(separator: ",\n  "))}"
        }.joined(separator: ",\n  ")
        result += "\n[\(layersStr)]\n"
        
        // Actions
        result += "actions:\n"
        if actions.isEmpty {
            result += "  []\n"
        } else {
            let actionsStr = actions.map { action in
                let actionDict = action.toDictionary()
                var actionParts: [String] = []
                
                // Always include action_id and layer
                actionParts.append("'action_id': \(actionDict["action_id"] ?? 0)")
                actionParts.append("'layer': \(actionDict["layer"] ?? 0)")
                
                // Add action_name if present
                if let actionName = actionDict["action_name"] as? String {
                    actionParts.append("'action_name': '\(actionName)'")
                }
                
                // Add points for stroke actions
                if let points = actionDict["points"] as? [[String: Any]] {
                    let pointsStr = points.map { point in
                        let x = point["x"] as? Float ?? 0
                        let y = point["y"] as? Float ?? 0
                        let p = point["p"] as? Float ?? 0
                        return "{'p': \(String(format: "%.8g", p)), 'x': \(String(format: "%.16g", x)), 'y': \(String(format: "%.16g", y))}"
                    }.joined(separator: ",\n             ")
                    actionParts.append("'points': [\n             \(pointsStr)\n            ]")
                }
                
                // Add other fields as needed
                for (key, value) in actionDict {
                    if key != "action_id" && key != "layer" && key != "action_name" && key != "points" {
                        if let floatValue = value as? Float {
                            actionParts.append("'\(key)': \(String(format: "%.17g", floatValue))")
                        } else if let intValue = value as? Int {
                            actionParts.append("'\(key)': \(intValue)")
                        } else if let stringValue = value as? String {
                            actionParts.append("'\(key)': '\(stringValue)'")
                        } else if let doubleValue = value as? Double {
                            actionParts.append("'\(key)': \(String(format: "%.17g", doubleValue))")
                        } else if let boolValue = value as? Bool {
                            actionParts.append("'\(key)': \(boolValue)")
                        }
                    }
                }
                
                return "{\(actionParts.joined(separator: ",\n   "))}"
            }.joined(separator: ",\n ")
            result += "[\n \(actionsStr)\n]"
        }
        
        return result
    }
}

// struct Matrix: Codable {
//     var rows: [[Double]]
// 
//     init(from dictionary: [String: Any]) {
//         
//     }
// 
//     /// Encode with each row on its own line, values compactly
//     func encode(to encoder: Encoder) throws {
//         var container = encoder.unkeyedContainer()
//         for row in rows {
//             try container.encode(row)  // each row as a compact array
//         }
//     }
// }

// MARK: - Stroke Point Codable Type
struct StrokePoint: Codable {
    let x: Float
    let y: Float
    let p: Float
    
    enum CodingKeys: String, CodingKey {
        case x, y, p
    }
    
    init(from dictionary: [String: Any]) {
        self.x = dictionary["x"] as? Float ?? 0
        self.y = dictionary["y"] as? Float ?? 0
        
        // Updated to handle Int, Double, or Float
        if let pressureInt = dictionary["p"] as? Int {
            self.p = Float(pressureInt)
        } else if let pressureDouble = dictionary["p"] as? Double {
            self.p = Float(pressureDouble)
        } else if let pressureFloat = dictionary["p"] as? Float {
            self.p = pressureFloat
        } else {
            self.p = 0
        }
    }
    
    func toDictionary() -> [String: Any] {
        return [
            "x": x,
            "y": y,
            "p": p
        ]
    }
}


// MARK: - Custom JSON Encoder with Matrix Formatting
// class CustomJSONEncoder: JSONEncoder {
//     override func encode<T>(_ value: T) throws -> Data where T : Encodable {
//         // First encode with standard encoder
//         let data = try super.encode(value)
//         
//         // Convert to string for processing
//         guard var jsonString = String(data: data, encoding: .utf8) else {
//             return data
//         }
//         
//         // Format matrices more compactly
// //         jsonString = formatMatrices(in: jsonString)
//         
//         // Return formatted data
//         return jsonString.data(using: .utf8) ?? data
//     }
//     
// //     private func formatMatrices(in jsonString: String) -> String {
// //         // Pattern to match matrix arrays
// //         let pattern = "\\[\\s*\\[\\s*([\\d\\.\\-]+)\\s*(?:,\\s*([\\d\\.\\-]+)\\s*)*\\]\\s*(?:,\\s*\\[\\s*([\\d\\.\\-]+)\\s*(?:,\\s*([\\d\\.\\-]+)\\s*)*\\]\\s*)*\\]"
// //         
// //         do {
// //             let regex = try NSRegularExpression(pattern: pattern, options: [])
// //             let range = NSRange(location: 0, length: jsonString.utf16.count)
// //             
// //             let formattedString = regex.stringByReplacingMatches(
// //                 in: jsonString,
// //                 options: [],
// //                 range: range,
// //                 withTemplate: "[[1.0, 0.0, 0.0, 0.0], [0.0, 1.0, 0.0, 0.0], [0.0, 0.0, 1.0, 0.0], [0.0, 0.0, 0.0, 1.0]]"
// //             )
// //             
// //             return formattedString
// //         } catch {
// //             return jsonString
// //         }
// //     }
// }

// MARK: - Cursor
// A simple byte cursor over the raw file
final class FileCursor {
    let data: [UInt8]
    private(set) var pos: Int = 0
    
    init(_ data: [UInt8]) { self.data = data }
    
    func readBE32() -> UInt32 {
        precondition(pos + 4 <= data.count, "EOF")
        let v = (UInt32(data[pos]) << 24) | (UInt32(data[pos+1]) << 16) | (UInt32(data[pos+2]) << 8) | UInt32(data[pos+3])
        pos += 4
        return v
    }
    func readLE32() -> UInt32 {
        precondition(pos + 4 <= data.count, "EOF")
        let v = UInt32(data[pos]) | (UInt32(data[pos+1]) << 8) | (UInt32(data[pos+2]) << 16) | (UInt32(data[pos+3]) << 24)
        pos += 4
        return v
    }
    func readBytes(_ count: Int) -> [UInt8] {
        precondition(pos + count <= data.count, "EOF")
        let s = Array(data[pos..<pos+count])
        pos += count
        return s
    }
}

// Pins (for version 0x82)
struct ArtPin {
    var matrix: [[Float]]
    var name: String
}

extension FileCursor {
    func readFloatLE() -> Float {
        let u = readLE32()
        return Float(bitPattern: u)
    }
    func readFloatMatrix(rows: Int, cols: Int) -> [[Float]] {
        var m: [[Float]] = []
        for _ in 0..<rows {
            var row: [Float] = []
            for _ in 0..<cols {
                row.append(readFloatLE())
            }
            m.append(row)
        }
        return m
    }
}

// MARK: - Parser
public struct ArtParser {
    private var rawData: [UInt8]
    
    // Separate byte and bit cursors
    private var byteCursor: Int = 0
    private var bitCursor: Int = 0
    
    var highPrecisionViewMatrix: [[Double]] = []
    var highPrecisionViewZoom: Double = 0.0
    
    mutating private func alignToByte() {
        if bitCursor != 0 {
            bitCursor = 0
            byteCursor += 1
        }
    }
    
    mutating private func readUInt32LE() -> UInt32 {
        alignToByte()
        if byteCursor + 4 > rawData.count {
            // Clamp cursor to EOF to avoid repeated prints/advancing
            if byteCursor < rawData.count {
                print("Warning: Attempted to read UInt32 beyond data bounds at position \(byteCursor) — clamping to EOF")
            } else {
                // Already at/after EOF: silently return 0 to avoid log spam
            }
            byteCursor = rawData.count
            return 0
        }
        let b0 = UInt32(rawData[byteCursor])
        let b1 = UInt32(rawData[byteCursor + 1])
        let b2 = UInt32(rawData[byteCursor + 2])
        let b3 = UInt32(rawData[byteCursor + 3])
        byteCursor += 4
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
    
    mutating private func readBitMSBFirst() -> Int {
        guard byteCursor < rawData.count else {
            print("Warning: Attempted to read bit beyond data bounds")
            return 0
        }
        
        let currentByte = rawData[byteCursor]
        let bit = Int((currentByte >> (7 - bitCursor)) & 1)
        
        bitCursor += 1
        if bitCursor == 8 {
            bitCursor = 0
            byteCursor += 1
        }
        
        return bit
    }
    
    private var mruList: MRUList
    
    public var penInfo: [String: Any] = [:]
    public var viewMatrix: [[Float]] = []
    public var layerOrder: [Int] = []
    public var pins: [[String: Any]] = []
    public var layers: [[String: Any]] = []
    public var images: [[String: Any]] = []
    public var actions: [[String: Any]] = []
    
    public var backgroundColor: [UInt8] = [0, 0, 0]
    public var paperStrength: Float = 1.0  // Renamed from backgroundAlpha
    public var paperTextureId: Int = 0  // Papers 1-19
    public var paperTextureData: [UInt8] = []  // Raw JPEG data
    
    public init?(data: [UInt8], enableValidation: Bool = false) {
        // === Parse header ===
        // Read magic (big‑endian) and version (little‑endian) manually
        let fc = FileCursor(data)
        let magic = fc.readBE32()
        guard magic == 0xc5b38be9 || magic == 0xc5b38be7 else {
            print("Error: Invalid magic 0x\(String(magic, radix: 16))")
            return nil
        }
        let version = fc.readLE32()
        
        var pinsParsed: [ArtPin] = []
        
        // Version‑specific extra header
        if (version & 0xFF) == 0x00 {
            _ = fc.readBytes(0x08)
        } else if version == 0x81 {
            _ = fc.readBytes(0x1C)
        } else if version == 0x82 {
            _ = fc.readBytes(0x21)
            // Read pins
            let pinCount = Int(fc.readLE32())
            for _ in 0..<pinCount {
                var mat: [[Float]] = []
                for _ in 0..<4 {
                    mat.append([
                        fc.readFloatLE(),
                        fc.readFloatLE(),
                        fc.readFloatLE(),
                        fc.readFloatLE()
                    ])
                }
                let nameLen = Int(fc.readLE32())
                let nameBytes = fc.readBytes(nameLen)
                let name = String(bytes: nameBytes, encoding: .utf8) ?? ""
                pinsParsed.append(ArtPin(matrix: mat, name: name))
            }
        }
        
        // === Extract compressed data ===
        let compressedDataSize = Int(fc.readLE32())
        
        guard fc.pos + compressedDataSize <= data.count else {
            return nil
        }
        
        let compressedData = fc.readBytes(compressedDataSize)
        
        // === Unpack data ===
        guard let unpackedData = MischiefUnpacker.unpack(byteInput: compressedData) else {
            return nil
        }
        
        // Special empty file marker check
        if compressedData.count == 2 && compressedData[0] == 0x02 && compressedData[1] == 0x02 {
            print("Detected special empty file marker")
            if unpackedData.count == EmptyArtData.data.count {
                let match = zip(unpackedData, EmptyArtData.data).allSatisfy { $0 == $1 }
                print("Validation against known empty file data: \(match ? "PASSED" : "FAILED")")
            } else {
                print("Validation against known empty file data: SIZE MISMATCH (expected \(EmptyArtData.data.count), got \(unpackedData.count))")
            }
        }
        
        // === Initialize stored properties ===
        self.pins = pinsParsed.map { ["matrix": $0.matrix, "name": $0.name] }
        
        self.rawData = unpackedData
        self.byteCursor = 0
        self.bitCursor = 0
        self.mruList = MRUList(length: 16)
        
        // === Parse payload ===
        parse()
        
        // === Validate results ===
        if enableValidation {
            validateResults()
        }
    }
    
    private mutating func parse() {
        guard !rawData.isEmpty else {
            print("Warning: No data to parse")
            return
        }
        
        // Parse header fields from the unpacked data
        let version = readUInt32LE()
        _ = version
        let activeLayerNum = readUInt32LE()
        _ = activeLayerNum
        let unkn_08 = readUInt32LE()
        _ = unkn_08
        
        // Store background color and paper strength
        self.backgroundColor = readColor()
        self.paperStrength = readFloat()
        
        let unknown_13 = readUInt32LE()
        _ = unknown_13
        let unknown_17 = readUInt32LE()
        _ = unknown_17
        let unknown_1b = readUInt32LE()
        _ = unknown_1b
        
        // Check if we have enough data for the next field
        if byteCursor + 4 > rawData.count {
            print("Warning: Not enough data for unknown_1f field. Skipping remaining parsing.")
            return
        }
        
        let unknown_1f = readUInt32LE()
        _ = unknown_1f
        
        // Parse
        parsePenInfo()
        parseDocumentState() // Unknown fields
        parseViewMatrix()
        parseLayerOrder()
        parseLayers()
        parseImages() // Paper texture is handled in parseImages
        parseActions()
    }
    
    
    // MARK: - Parsing Methods
    
    private func determineTextureId(from jpegData: [UInt8]) -> Int {
        // Create a hash of the JPEG data for comparison
        let hash = ArtParser.calculateHash(of: jpegData)
        
        // Compare against known texture hashes
        let textureHashes: [UInt32: Int] = [
            0x927e2e6b: 1,  // texture_01
            0x2cff611e: 2,  // texture_02
            0xc954bda5: 3,  // texture_03
            0x535ed619: 4,  // texture_04
            0x7c76253c: 5,  // texture_05
            0x84fb31a0: 6,  // texture_06
            0x25d7e5e4: 7,  // texture_07
            0xa8c52510: 8,  // texture_08
            0xf9a85d17: 9,  // texture_09
            0x13fab734: 10,  // texture_10
            0x701c8d0f: 11,  // texture_11
            0xb2bad67d: 12,  // texture_12
            0xa6aae884: 13,  // texture_13
            0xfb4d6451: 14,  // texture_14
            0xda2ed1a6: 15,  // texture_15
            0xa655954a: 16,  // texture_16
            0xba3f84f8: 17,  // texture_17
            0x9679fab1: 18,  // texture_18
            0x93bb3ae3: 19,  // texture_19
        ]
        
        // Return the matching texture ID, or default to 0 if not found
        return textureHashes[hash, default: 0]
    }
    
    static func calculateHash(of data: [UInt8]) -> UInt32 {
        // Simple FNV-1a hash
        var hash: UInt32 = 2166136261
        for byte in data {
            hash = hash ^ UInt32(byte)
            hash = hash &* 16777619
        }
        return hash
    }
    
    static func extractTextureHashes() {
        let textureFiles = [
            "01.jpg",
            "02.jpg",
            "03.jpg",
            "04.jpg",
            "05.jpg",
            "06.jpg",
            "07.jpg",
            "08.jpg",
            "09.jpg",
            "10.jpg",
            "11.jpg",
            "12.jpg",
            "13.jpg",
            "14.jpg",
            "15.jpg",
            "16.jpg",
            "17.jpg",
            "18.jpg",
            "19.jpg"
        ]
        
        print("let textureHashes: [UInt32: Int] = [")
        
        for (index, file) in textureFiles.enumerated() {
            do {
                let data = try Data(contentsOf: URL(fileURLWithPath: file))
                let byteArray = [UInt8](data)
                
                // Calculate hash directly from the JPEG data
                let hash = calculateHash(of: byteArray)
                print("    0x\(String(hash, radix: 16)): \(index + 1),  // texture_\(String(format: "%02d", index + 1))")
            } catch {
                print("Error processing \(file): \(error)")
            }
        }
        
        print("]")
    }
    
    func extractTextureData(to filename: String) -> Bool {
        guard !paperTextureData.isEmpty else {
            print("No texture data to extract")
            return false
        }
        
        do {
            let data = Data(paperTextureData)
            try data.write(to: URL(fileURLWithPath: filename))
            print("Texture data extracted to \(filename) (\(paperTextureData.count) bytes)")
            return true
        } catch {
            print("Error extracting texture data: \(error)")
            return false
        }
    }
    
    private mutating func parsePenInfo() {
        // Read pen info sequentially
        let type = Int(readUInt32LE())
        let color = readColor()
        let noise = readFloat()
        let size = readFloat()
        let sizeMin = readFloat()
        let opacity = readFloat()
        let opacityMin = readFloat()
        let isEraser = Int(readUInt32LE())
        
        penInfo["type"] = type
        penInfo["color"] = color
        penInfo["noise"] = noise
        penInfo["size"] = size
        penInfo["size_min"] = sizeMin
        penInfo["opacity"] = opacity
        penInfo["opacity_min"] = opacityMin
        penInfo["is_eraser"] = isEraser
    }
    
    private mutating func parseDocumentState() {
        let unknown_42 = readUInt32LE()
        _ = unknown_42
        let unknown_46 = readFloat()
        _ = unknown_46
    }
    
    mutating private func parseViewMatrix() {
        // Store both Float and Double versions
        var viewMatrixDoubles: [[Double]] = []
        viewMatrix = []
        
        for _ in 0..<4 {
            var rowFloat: [Float] = []
            var rowDouble: [Double] = []
            for _ in 0..<4 {
                let floatValue = readFloat()
                let doubleValue = Double(floatValue)
                rowFloat.append(floatValue)
                rowDouble.append(doubleValue)
            }
            viewMatrix.append(rowFloat)
            viewMatrixDoubles.append(rowDouble)
        }
        
        let viewZoom = readFloat()
        let viewZoomDouble = Double(viewZoom)
        
        // Store high precision values
        highPrecisionViewMatrix = viewMatrixDoubles
        highPrecisionViewZoom = viewZoomDouble
    }
    
    private mutating func parseLayerOrder() {
        // Check if we have at least 4 bytes for the count
        guard byteCursor + 4 <= rawData.count else {
            print("Warning: Not enough data for layerOrder count")
            layerOrder = []
            return
        }
        
        // First try reading as little-endian
        let countLE = Int(readUInt32LE())
        
        // If the little-endian value looks unreasonable, try big-endian
        if countLE < 0 || countLE > 1000 {
            // Reset position and try big-endian
            byteCursor -= 4
            
            // Read the raw bytes
            let b0 = rawData[byteCursor]
            let b1 = rawData[byteCursor + 1]
            let b2 = rawData[byteCursor + 2]
            let b3 = rawData[byteCursor + 3]
            
            // Convert to big-endian
            let countBE = Int((UInt32(b0) << 24) | (UInt32(b1) << 16) | (UInt32(b2) << 8) | UInt32(b3))
            
            // If big-endian also looks unreasonable, reset to 0
            if countBE < 0 || countBE > 1000 {
                print("Warning: Invalid layerOrder count (both LE and BE unreasonable), resetting to 0")
                byteCursor += 4  // Advance past the count
                layerOrder = []
                return
            }
            
            // Use big-endian count
            let count = countBE
            byteCursor += 4  // Advance past the count
            
            // Check if we have enough data for all the layer indices
            guard byteCursor + count * 4 <= rawData.count else {
                print("Warning: Not enough data for layerOrder indices (need \(count * 4) bytes, have \(rawData.count - byteCursor))")
                layerOrder = []
                return
            }
            
            layerOrder = []
            for i in 0..<count {
                let value = Int(readUInt32LE())  // Assume indices are still little-endian
                layerOrder.append(value)
                _ = i
            }
        } else {
            // Use little-endian count
            let count = countLE
            
            // Check if we have enough data for all the layer indices
            guard byteCursor + count * 4 <= rawData.count else {
                print("Warning: Not enough data for layerOrder indices (need \(count * 4) bytes, have \(rawData.count - byteCursor))")
                layerOrder = []
                return
            }
            
            layerOrder = []
            for i in 0..<count {
                let value = Int(readUInt32LE())
                layerOrder.append(value)
                _ = i
            }
        }
    }
    
    private mutating func parseLayers() {
        // Check if we have at least 4 bytes for the count
        guard byteCursor + 4 <= rawData.count else {
            print("Warning: Not enough data for layers count")
            layers = []
            return
        }
        
        let count = Int(readUInt32LE())
        
        // Validate count to prevent excessive memory usage
        if count < 0 || count > 1000 {
            print("Warning: Invalid layer count \(count), resetting to 0")
            layers = []
            return
        }
        
        layers = []
        
        for _ in 0..<count {
            var layer: [String: Any] = [:]
            
            // visible (u32)
            guard byteCursor + 4 <= rawData.count else {
                print("Warning: Not enough data for layer visible flag")
                break
            }
            layer["visible"] = Int(readUInt32LE())
            
            // opacity (float)
            guard byteCursor + 4 <= rawData.count else {
                print("Warning: Not enough data for layer opacity")
                break
            }
            layer["opacity"] = readFloat()
            
            // name: fixed 256 bytes, 0-terminated UTF-8
            guard byteCursor + 256 <= rawData.count else {
                print("Warning: Not enough data for layer name")
                break
            }
            let nameBytes = readFixedBytes(256)
            let name = String(bytes: nameBytes.prefix { $0 != 0 }, encoding: .utf8) ?? ""
            layer["name"] = name
            
            // action_count (u32)
            guard byteCursor + 4 <= rawData.count else {
                print("Warning: Not enough data for layer action_count")
                break
            }
            layer["action_count"] = Int(readUInt32LE())
            
            // matrix 4x4 floats (64 bytes)
            guard byteCursor + 64 <= rawData.count else {
                print("Warning: Not enough data for layer matrix")
                break
            }
            var matrix: [[Float]] = []
            for _ in 0..<4 {
                var row: [Float] = []
                for _ in 0..<4 {
                    let val = readFloat()
                    row.append(val)
                }
                matrix.append(row)
            }
            layer["matrix"] = matrix
            
            // zoom (float)
            guard byteCursor + 4 <= rawData.count else {
                print("Warning: Not enough data for layer zoom")
                break
            }
            layer["zoom"] = readFloat()
            
            layers.append(layer)
        }
    }
    
    private mutating func readFixedBytes(_ n: Int) -> [UInt8] {
        alignToByte()
        let end = min(byteCursor + n, rawData.count)
        let s = Array(rawData[byteCursor..<end])
        byteCursor = end
        return s.count == n ? s : s + Array(repeating: 0, count: n - s.count)
    }
    
    private mutating func parseImages() {
        
        // Check if we have at least 4 bytes for the count
        guard byteCursor + 4 <= rawData.count else {
            print("Warning: Not enough data for images count")
            images = []
            return
        }
        
        let count = Int(readUInt32LE())
        
        // Validate count to prevent excessive memory usage
        if count < 0 || count > 1000 {
            print("Warning: Invalid image count \(count), resetting to 0")
            images = []
            return
        }
        
        images = []
        
        for i in 0..<count {
            var image: [String: Any] = [:]
            
            // type (u32)
            guard byteCursor + 4 <= rawData.count else {
                print("Warning: Not enough data for image type")
                break
            }
            image["type"] = Int(readUInt32LE())
            
            // size (u32)
            guard byteCursor + 4 <= rawData.count else {
                print("Warning: Not enough data for image size")
                break
            }
            let size = Int(readUInt32LE())
            
            // Validate the size to prevent reading beyond bounds
            if size < 0 || size > (rawData.count - byteCursor) {
                print("Warning: Invalid image size \(size) at position \(byteCursor), skipping image")
                break
            }
            
            // Check if we have enough data for the image
            guard byteCursor + size <= rawData.count else {
                print("Warning: Not enough data for image \(i) (need \(size) bytes, have \(rawData.count - byteCursor))")
                break
            }
            
            let imageData = readExactBytes(size)
            
            // Check if this image matches a known paper texture hash
            let textureId = determineTextureId(from: imageData)
            if textureId > 0 {
                // This is a paper texture
                self.paperTextureId = textureId
                self.paperTextureData = imageData
                image["textureId"] = textureId
            } else {
                
                image["raw"] = imageData
                images.append(image)
            }
        }
    }
    
    private mutating func readExactBytes(_ n: Int) -> [UInt8] {
        alignToByte()
        guard byteCursor + n <= rawData.count else {
            let remaining = max(0, rawData.count - byteCursor)
            let s = Array(rawData[byteCursor..<byteCursor+remaining])
            byteCursor = rawData.count
            return s
        }
        let s = Array(rawData[byteCursor..<byteCursor+n])
        byteCursor += n
        return s
    }
    
    private mutating func parseActions() {
        // Check if we have at least 4 bytes for the action count
        guard byteCursor + 4 <= rawData.count else {
            print("Warning: Not enough data for action count")
            actions = []
            return
        }
        
        let actionCount = Int(readUInt32LE())
        
        // Validate action count to prevent excessive memory usage
        if actionCount < 0 || actionCount > 100000 {
            print("Warning: Invalid action count \(actionCount), resetting to 0")
            actions = []
            return
        }
        
        // Pre-allocate the actions array with capacity
        actions = []
        actions.reserveCapacity(actionCount)
        
        for i in 0..<actionCount {
            // Check if we have enough data for at least the action header (8 bytes)
            guard byteCursor + 8 <= rawData.count else {
                print("Warning: Not enough data for action \(i) header")
                break
            }
            
            // Parse layer and action_id
            let layer = Int(readUInt32LE())
            let actionId = Int(readUInt32LE())
            
            var action: [String: Any] = [
                "layer": layer,
                "action_id": actionId
            ]
            
            // Parse action-specific data with bounds checking
            switch actionId {
            case 0x01:
                action["action_name"] = "stroke"
                
                // Check if we have enough data for point count
                guard byteCursor + 4 <= rawData.count else {
                    print("Warning: Not enough data for stroke point count in action \(i)")
                    break
                }
                let pointCount = Int(readUInt32LE())
                
                // Validate point count to prevent excessive memory usage
                if pointCount < 0 || pointCount > 100000 {
                    print("Warning: Invalid point count \(pointCount) in action \(i)")
                    break
                }
                
                // Pre-allocate arrays with capacity
                var xs: [Float] = []
                var ys: [Float] = []
                var rawPs: [Int] = []
                xs.reserveCapacity(pointCount)
                ys.reserveCapacity(pointCount)
                rawPs.reserveCapacity(pointCount)
                
                // Read first point (absolute coordinates)
                guard byteCursor + 12 <= rawData.count else {
                    print("Warning: Not enough data for first stroke point in action \(i)")
                    break
                }
                
                let x0 = readFloat()
                let y0 = readFloat()
                let p0Float = readFloat()
                
                // Store coordinates
                xs.append(x0)
                ys.append(y0)
                
                // --- Anchor Calculation ---
                // The first point is an absolute float (0.0 to 1.0).
                // We must scale it to the 12-bit range (0-4096) to match the unwrap target range.
                // Previous code used 0x3ff (1023) which was incorrect for this unwrap logic.
                let firstPRaw = Int(p0Float * 4096.0)
                rawPs.append(firstPRaw)
                
                // Read remaining points (delta encoded)
                var x = x0
                var y = y0
                
                for j in 1..<pointCount {
                    // Check if we have enough data for this point
                    guard byteCursor + 5 <= rawData.count else {
                        print("Warning: Not enough data for stroke point \(j) in action \(i)")
                        break
                    }
                    
                    let tmp = readUInt32LE()
                    let byt = readByte()
                    
                    // Extract dx (14 bits, signed)
                    var dx = Int(tmp & 0x3fff)
                    if (tmp & (1 << 14)) != 0 {
                        dx = -dx
                    }
                    
                    // Extract dy (14 bits, signed)
                    var dy = Int((tmp >> 15) & 0x3fff)
                    if (tmp & (1 << 29)) != 0 {
                        dy = -dy
                    }
                    
                    // Extract pressure (2 bits from tmp + 8 bits from byt)
                    let pRaw = Int((tmp >> 30) | (UInt32(byt) << 2))
                    
                    // Update coordinates
                    x += Float(Double(dx) / 32.0)
                    y += Float(Double(dy) / 32.0)
                    
                    // Store coordinates and raw pressure
                    xs.append(x)
                    ys.append(y)
                    rawPs.append(pRaw)
                }
                
                // --- Cull End Point ---
                // Remove the spurious final point (raw 0) before unwrapping.
                // We check rawPs.last == 0 as requested.
                var didCull = 0
                if !rawPs.isEmpty && rawPs.last == 0 {
                    rawPs.removeLast()
                    xs.removeLast()
                    ys.removeLast()
                    didCull = 1
                }
                
                // Unwrap pressure sequence
                let unwrappedPs = unwrapPressureSequence(rawPs: rawPs)
                
//                let normalizedPs = normalizePressure(unwrapped: unwrappedPs) // fix dots
                let normalizedPs = unwrappedPs.map { Float($0) / 4095.0 } // normalization without short stroke fix
                
//                print("rawPs: ", rawPs)

//                for p in rawPs {
//                    print("rawPs p: ", p)
//                }
                
                // Create points with unwrapped pressure values
                var points: [[String: Any]] = []
                points.reserveCapacity(pointCount - didCull)
                
                for i in 0..<(pointCount - didCull) {
                    var point: [String: Any] = [:]
                    point["x"] = xs[i]
                    point["y"] = ys[i]
                    point["p"] = normalizedPs[i]
                    points.append(point)
                }
                
                action["points"] = points
                
            case 0x02:
                action["action_name"] = "polyline"
                action["points"] = readPolyline(count: 2)
                
            case 0x03:
                action["action_name"] = "polyline"
                guard byteCursor + 4 <= rawData.count else {
                    print("  Error: Not enough data for polyline count")
                    break
                }
                let count = Int(readUInt32LE())
                action["points"] = readPolyline(count: count)
                
            case 0x04:
                action["action_name"] = "polyline"
                guard byteCursor + 4 <= rawData.count else {
                    print("  Error: Not enough data for polyline count")
                    break
                }
                let count = Int(readUInt32LE())
                action["points"] = readPolyline(count: count)
                
            case 0x05:
                action["action_name"] = "rect"
                guard byteCursor + 20 <= rawData.count else {
                    print("  Error: Not enough data for rect parameters")
                    break
                }
                let floats = readFloatArray(count: 5)
                action["x"] = floats[0]
                action["y"] = floats[1]
                action["w"] = floats[2]
                action["h"] = floats[3]
                action["angle"] = floats[4]
                
            case 0x06:
                action["action_name"] = "ellipse"
                guard byteCursor + 20 <= rawData.count else {
                    print("  Error: Not enough data for ellipse parameters")
                    break
                }
                let floats = readFloatArray(count: 5)
                let cx = floats[0] + floats[2] / 4.0
                let cy = floats[1] + floats[3] / 4.0
                let rx = floats[2] / 2.0
                let ry = floats[3] / 2.0
                let angle = floats[4]
                action["cx"] = cx
                action["cy"] = cy
                action["rx"] = rx
                action["ry"] = ry
                action["angle"] = angle
                
            case 0x07:
                action["action_name"] = "draw_image"
                guard byteCursor + 28 <= rawData.count else {
                    print("  Error: Not enough data for draw_image parameters")
                    break
                }
                let dstCenter = readFloatArray(count: 2)
                let dstSize = readFloatArray(count: 2)
                let unknown = readUInt32LE()
                let srcSize = readUInt32Array(count: 2)
                let imageId = readUInt32LE()
                action["dst_center"] = dstCenter
                action["dst_size"] = dstSize
                action["unknown"] = unknown
                action["src_size"] = srcSize
                action["image_id"] = imageId
                
            case 0x08:
                action["action_name"] = "unknown_08"
                guard byteCursor + 4 <= rawData.count else {
                    print("  Error: Not enough data for unknown_08 parameter")
                    break
                }
                action["argument"] = Int(readUInt32LE())
                
            case 0x0C:
                action["action_name"] = "merge_layer"
                guard byteCursor + 76 <= rawData.count else {
                    print("  Error: Not enough data for merge_layer parameters")
                    break
                }
                let fromLayer = Int(readUInt32LE())
                let opacitySrc = readFloat()
                let opacityDst = readFloat()
                let matrix = readFloatMatrix(rows: 4, columns: 4)
                let zoom = readFloat()
                action["from_layer"] = fromLayer
                action["opacity_src"] = opacitySrc
                action["opacity_dst"] = opacityDst
                action["matrix"] = matrix
                action["zoom"] = zoom
                
            case 0x0D:
                action["action_name"] = "layer_matrix"
                guard byteCursor + 68 <= rawData.count else {
                    print("  Error: Not enough data for layer_matrix parameters")
                    break
                }
                let matrix = readFloatMatrix(rows: 4, columns: 4)
                let zoom = readFloat()
                action["matrix"] = matrix
                action["zoom"] = zoom
                
            case 0x0E:
                action["action_name"] = "cut"
                guard byteCursor + 16 <= rawData.count else {
                    print("  Error: Not enough data for cut parameters")
                    break
                }
                let rect = readFloatArray(count: 4)
                action["rect"] = rect
                
            case 0x0F:
                action["action_name"] = "paste_layer"
                guard byteCursor + 148 <= rawData.count else {
                    print("  Error: Not enough data for paste_layer parameters")
                    break
                }
                let fromLayer = Int(readUInt32LE())
                let rect = readFloatArray(count: 4)
                let matrix1 = readFloatMatrix(rows: 4, columns: 4)
                let zoom1 = readFloat()
                let matrix2 = readFloatMatrix(rows: 4, columns: 4)
                let zoom2 = readFloat()
                action["from_layer"] = fromLayer
                action["rect"] = rect
                action["matrix_1"] = matrix1
                action["zoom_1"] = zoom1
                action["matrix_2"] = matrix2
                action["zoom_2"] = zoom2
                
            case 0x33:
                action["action_name"] = "pen_matrix"
                guard byteCursor + 68 <= rawData.count else {
                    print("  Error: Not enough data for pen_matrix parameters")
                    break
                }
                let matrix = readFloatMatrix(rows: 4, columns: 4)
                let zoom = readFloat()
                action["matrix"] = matrix
                action["zoom"] = zoom
                
            case 0x34:
                action["action_name"] = "pen_properties"
                guard byteCursor + 28 <= rawData.count else {
                    print("  Error: Not enough data for pen_properties parameters")
                    break
                }
                let type = Int(readUInt32LE())
                let noise = readFloat()
                let size = readFloat()
                let sizeMin = readFloat()
                let opacity = readFloat()
                let opacityMin = readFloat()
                action["type"] = type
                action["noise"] = noise
                action["size"] = size
                action["size_min"] = sizeMin
                action["opacity"] = opacity
                action["opacity_min"] = opacityMin
                
            case 0x35:
                action["action_name"] = "pen_color"
                guard byteCursor + 3 <= rawData.count else {
                    print("  Error: Not enough data for pen_color")
                    break
                }
                action["color"] = readColor()
                
            case 0x36:
                action["action_name"] = "is_eraser"
                guard byteCursor + 4 <= rawData.count else {
                    print("  Error: Not enough data for is_eraser parameter")
                    break
                }
                let isEraser = readUInt32LE()
                action["is_eraser"] = isEraser != 0
                
            default:
                action["action_name"] = "unknown_\(String(format: "%02x", actionId))"
                print("Warning: Unknown action ID \(actionId) in action \(i)")
                break
            }
            
            actions.append(action)
        }
        
        // Read trailing unknown EOF marker if there's enough data
        if byteCursor + 4 <= rawData.count {
            let unknown_eof = readUInt32LE()
            if unknown_eof != 0 {print("Trailing EOF marker:", unknown_eof)}
            _ = unknown_eof
        }
        
    }
    
    // MARK: - Helper Methods
    private mutating func readBit() -> Int {
        return readBitMSBFirst()
    }
    
    private mutating func readUInt32() -> UInt32 {
        return readUInt32LE()
    }
    
    private mutating func readFloat() -> Float {
        return Float(bitPattern: readUInt32LE())
    }
    
    private mutating func readColor() -> [UInt8] {
        alignToByte()
        
        guard byteCursor + 3 <= rawData.count else {
            print("Warning: Attempted to read Color beyond data bounds")
            byteCursor += 3
            return [0, 0, 0]
        }
        
        let result = [rawData[byteCursor], rawData[byteCursor + 1], rawData[byteCursor + 2]]
        byteCursor += 3
        
        return result
    }
    
    private mutating func readString() -> String {
        alignToByte()
        
        let length = Int(readUInt32LE())
        guard length > 0 && byteCursor + length <= rawData.count else {
            return ""
        }
        
        let characters = Array(rawData[byteCursor..<byteCursor + length])
        byteCursor += length
        
        return String(data: Data(characters), encoding: .utf8) ?? ""
    }
    
    private mutating func readData() -> [UInt8] {
        alignToByte()
        
        let length = Int(readUInt32LE())
        guard length > 0 && byteCursor + length <= rawData.count else {
            return []
        }
        
        let result = Array(rawData[byteCursor..<byteCursor + length])
        byteCursor += length
        
        return result
    }
    
    private mutating func peekNextBytes(_ count: Int) -> [UInt8] {
        let end = min(byteCursor + count, rawData.count)
        return Array(rawData[byteCursor..<end])
    }
    
    private func looksLikeValidActionId(_ value: UInt32) -> Bool {
        // Valid action IDs are typically small values (0x00 to 0xFF)
        return value <= 0xFF
    }
    
    private func looksLikeFloatValue(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 4 else { return false }
        
        // Check if the bit pattern looks like a reasonable float
        let uint32 = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) |
        (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
        let floatValue = Float(bitPattern: uint32)
        
        // Check if it's a reasonable float value (not infinity, NaN, or extremely large)
        return floatValue.isFinite && abs(floatValue) < 1000000
    }
    
    private mutating func readPolyline(count: Int) -> [[String: Any]] {
        var points: [[String: Any]] = []
        
        for i in 0..<count {
            guard byteCursor + 12 <= rawData.count else {
                print("    Error: Not enough data for polyline point \(i)")
                break
            }
            var point: [String: Any] = [:]
            point["x"] = readFloat()
            point["y"] = readFloat()
            point["p"] = readFloat()
            points.append(point)
        }
        return points
    }
    
    private mutating func readFloatArray(count: Int) -> [Float] {
        var floats: [Float] = []
        for _ in 0..<count {
            floats.append(readFloat())
        }
        return floats
    }
    
    private mutating func readUInt32Array(count: Int) -> [UInt32] {
        var uints: [UInt32] = []
        for _ in 0..<count {
            uints.append(readUInt32LE())
        }
        return uints
    }
    
    private mutating func readFloatMatrix(rows: Int, columns: Int) -> [[Float]] {
        var matrix: [[Float]] = []
        for _ in 0..<rows {
            var row: [Float] = []
            for _ in 0..<columns {
                row.append(readFloat())
            }
            matrix.append(row)
        }
        return matrix
    }
    
    private mutating func readByte() -> UInt8 {
        guard byteCursor < rawData.count else {
            print("Warning: Attempted to read byte beyond data bounds")
            return 0
        }
        let byte = rawData[byteCursor]
        byteCursor += 1
        return byte
    }
    
    
    // MARK: - Validation Method
    // Validation test for empty document
    
    private func validateResults() {
        print("\n=== VALIDATION ===")
        
        // Expected values for empty.art
        let expectedPenInfo: [String: Any] = [
            "color": [105, 250, 206] as [UInt8],
            "is_eraser": 0 as Int,
            "noise": 0.20000000298023224 as Float,
            "opacity": 0.800000011920929 as Float,
            "opacity_min": 1.0 as Float,
            "size": 46.27036666870117 as Float,
            "size_min": 0.8594013452529907 as Float,
            "type": 1 as Int
        ]
        
        let expectedViewMatrix: [[Float]] = [
            [1.0, 0.0, 0.0, 0.0],
            [0.0, 1.0, 0.0, 0.0],
            [0.0, 0.0, 1.0, 0.0],
            [0.0, 0.0, 0.0, 1.0]
        ]
        
        let expectedLayerOrder: [Int] = [0]
        
        let expectedPins: [[String: Any]] = []
        
        let expectedLayers: [[String: Any]] = [
            [
                "action_count": 392 as Int,
                "matrix": [
                    [1.0 as Float, 0.0 as Float, 0.0 as Float, 0.0 as Float],
                    [0.0 as Float, 1.0 as Float, 0.0 as Float, 0.0 as Float],
                    [0.0 as Float, 0.0 as Float, 1.0 as Float, 0.0 as Float],
                    [0.0 as Float, 0.0 as Float, 0.0 as Float, 1.0 as Float]
                ] as [[Float]],
                "name": "Layer 1" as String,
                "opacity": 1.0 as Float,
                "visible": 1 as Int,
                "zoom": 1.0 as Float
            ]
        ]
        
        let expectedActions: [[String: Any]] = [
            ["action_id": 8 as Int, "action_name": "unknown_08" as String, "argument": 0 as Int, "layer": 0 as Int]
        ]
        
        // Validate pen info
        print("\nValidating pen info...")
        var penInfoValid = true
        for (key, expectedValue) in expectedPenInfo {
            if let actualValue = penInfo[key] {
                if let expectedFloat = expectedValue as? Float, let actualFloat = actualValue as? Float {
                    if abs(expectedFloat - actualFloat) > 0.0001 {
                        print("  Mismatch: \(key) expected \(expectedFloat), got \(actualFloat)")
                        penInfoValid = false
                    }
                } else if let expectedInt = expectedValue as? Int, let actualInt = actualValue as? Int {
                    if expectedInt != actualInt {
                        print("  Mismatch: \(key) expected \(expectedInt), got \(actualInt)")
                        penInfoValid = false
                    }
                } else if let expectedArray = expectedValue as? [UInt8], let actualArray = actualValue as? [UInt8] {
                    if expectedArray != actualArray {
                        print("  Mismatch: \(key) expected \(expectedArray), got \(actualArray)")
                        penInfoValid = false
                    }
                } else {
                    print("  Mismatch: \(key) type mismatch, expected \(type(of: expectedValue)), got \(type(of: actualValue))")
                    penInfoValid = false
                }
            } else {
                print("  Missing key: \(key)")
                penInfoValid = false
            }
        }
        print("Pen info validation: \(penInfoValid ? "PASSED" : "FAILED")")
        
        // Validate view matrix
        print("\nValidating view matrix...")
        var viewMatrixValid = true
        if viewMatrix.count == expectedViewMatrix.count {
            for i in 0..<viewMatrix.count {
                if viewMatrix[i].count == expectedViewMatrix[i].count {
                    for j in 0..<viewMatrix[i].count {
                        if abs(viewMatrix[i][j] - expectedViewMatrix[i][j]) > 0.0001 {
                            print("  Mismatch: matrix[\(i)][\(j)] expected \(expectedViewMatrix[i][j]), got \(viewMatrix[i][j])")
                            viewMatrixValid = false
                        }
                    }
                } else {
                    print("  Mismatch: matrix row \(i) length mismatch")
                    viewMatrixValid = false
                }
            }
        } else {
            print("  Mismatch: matrix row count mismatch")
            viewMatrixValid = false
        }
        print("View matrix validation: \(viewMatrixValid ? "PASSED" : "FAILED")")
        
        // Validate layer order
        print("\nValidating layer order...")
        let layerOrderValid = layerOrder == expectedLayerOrder
        if !layerOrderValid {
            print("  Expected: \(expectedLayerOrder), got: \(layerOrder)")
        }
        print("Layer order validation: \(layerOrderValid ? "PASSED" : "FAILED")")
        
        // Validate pins
        print("\nValidating pins...")
        var pinsValid = true
        if pins.count == expectedPins.count {
            for i in 0..<pins.count {
                let pin = pins[i]
                let expectedPin = expectedPins[i]
                
                for (key, expectedValue) in expectedPin {
                    if let actualValue = pin[key] {
                        if let expectedFloat = expectedValue as? Float, let actualFloat = actualValue as? Float {
                            if abs(expectedFloat - actualFloat) > 0.0001 {
                                print("  Pin \(i) mismatch: \(key) expected \(expectedFloat), got \(actualFloat)")
                                pinsValid = false
                            }
                        } else if let expectedInt = expectedValue as? Int, let actualInt = actualValue as? Int {
                            if expectedInt != actualInt {
                                print("  Pin \(i) mismatch: \(key) expected \(expectedInt), got \(actualInt)")
                                pinsValid = false
                            }
                        } else {
                            print("  Pin \(i) mismatch: \(key) type mismatch")
                            pinsValid = false
                        }
                    } else {
                        print("  Pin \(i) missing key: \(key)")
                        pinsValid = false
                    }
                }
            }
        } else {
            print("  Mismatch: pin count expected \(expectedPins.count), got \(pins.count)")
            pinsValid = false
        }
        print("Pins validation: \(pinsValid ? "PASSED" : "FAILED")")
        
        // Validate layers
        print("\nValidating layers...")
        var layersValid = true
        if layers.count == expectedLayers.count {
            for i in 0..<layers.count {
                let layer = layers[i]
                let expectedLayer = expectedLayers[i]
                
                for (key, expectedValue) in expectedLayer {
                    if let actualValue = layer[key] {
                        if let expectedFloat = expectedValue as? Float, let actualFloat = actualValue as? Float {
                            if abs(expectedFloat - actualFloat) > 0.0001 {
                                print("  Layer \(i) mismatch: \(key) expected \(expectedFloat), got \(actualFloat)")
                                layersValid = false
                            }
                        } else if let expectedInt = expectedValue as? Int, let actualInt = actualValue as? Int {
                            if expectedInt != actualInt {
                                print("  Layer \(i) mismatch: \(key) expected \(expectedInt), got \(actualInt)")
                                layersValid = false
                            }
                        } else if let expectedString = expectedValue as? String, let actualString = actualValue as? String {
                            if expectedString != actualString {
                                print("  Layer \(i) mismatch: \(key) expected '\(expectedString)', got '\(actualString)'")
                                layersValid = false
                            }
                        } else if let expectedMatrix = expectedValue as? [[Float]], let actualMatrix = actualValue as? [[Float]] {
                            var matrixValid = true
                            if expectedMatrix.count == actualMatrix.count {
                                for mi in 0..<expectedMatrix.count {
                                    if expectedMatrix[mi].count == actualMatrix[mi].count {
                                        for mj in 0..<expectedMatrix[mi].count {
                                            if abs(expectedMatrix[mi][mj] - actualMatrix[mi][mj]) > 0.0001 {
                                                print("  Layer \(i) matrix[\(mi)][\(mj)] mismatch: expected \(expectedMatrix[mi][mj]), got \(actualMatrix[mi][mj])")
                                                matrixValid = false
                                            }
                                        }
                                    } else {
                                        print("  Layer \(i) matrix row \(mi) length mismatch")
                                        matrixValid = false
                                    }
                                }
                            } else {
                                print("  Layer \(i) matrix row count mismatch")
                                matrixValid = false
                            }
                            if !matrixValid {
                                layersValid = false
                            }
                        } else {
                            print("  Layer \(i) mismatch: \(key) type mismatch")
                            layersValid = false
                        }
                    } else {
                        print("  Layer \(i) missing key: \(key)")
                        layersValid = false
                    }
                }
            }
        } else {
            print("  Mismatch: layer count expected \(expectedLayers.count), got \(layers.count)")
            layersValid = false
        }
        print("Layers validation: \(layersValid ? "PASSED" : "FAILED")")
        
        // Validate actions
        print("\nValidating actions...")
        var actionsValid = true
        if actions.count == expectedActions.count {
            for i in 0..<actions.count {
                let action = actions[i]
                let expectedAction = expectedActions[i]
                
                for (key, expectedValue) in expectedAction {
                    if let actualValue = action[key] {
                        if let expectedInt = expectedValue as? Int, let actualInt = actualValue as? Int {
                            if expectedInt != actualInt {
                                print("  Action \(i) mismatch: \(key) expected \(expectedInt), got \(actualInt)")
                                actionsValid = false
                            }
                        } else if let expectedString = expectedValue as? String, let actualString = actualValue as? String {
                            if expectedString != actualString {
                                print("  Action \(i) mismatch: \(key) expected '\(expectedString)', got '\(actualString)'")
                                actionsValid = false
                            }
                        } else {
                            print("  Action \(i) mismatch: \(key) type mismatch")
                            actionsValid = false
                        }
                    } else {
                        print("  Action \(i) missing key: \(key)")
                        actionsValid = false
                    }
                }
            }
        } else {
            print("  Mismatch: action count expected \(expectedActions.count), got \(actions.count)")
            actionsValid = false
        }
        print("Actions validation: \(actionsValid ? "PASSED" : "FAILED")")
        
        // Overall validation
        let overallValid = penInfoValid && viewMatrixValid && layerOrderValid && pinsValid && layersValid && actionsValid
        print("\nOverall validation: \(overallValid ? "PASSED" : "FAILED")")
    }
}

// MARK: - Main function
func runProgram() -> Int32 {
    let args = CommandLine.arguments
    
    if args.contains("-h") || args.contains("--help") {
        print("Usage: \(args[0]) <input_file>")
        print("Flags:")
        print("  --validate-empty: Validate empty.art")
        print("  --debug-unpack: Test LZUnpack only")
        print("  --performance-test: Time parsing performance")
        print("  --extract-hashes: Print paper texture hashes from jpg files")
        print("  --extract-paper: Output paper texture")
        print("  --pressure-json [file]: Run analytics against JSON reference data")
        return 0
    }
    
    // Parse flags
    var shouldDebugUnpack = false
    var shouldPerformanceTest = false
    var validateOption = false
    var inputFileIndex = -1
    var shouldExtractHashes = false
    var shouldExtractPaper = false
    var pressureJsonFile: String? = nil
    
    for (index, arg) in args.enumerated() {
        switch arg {
        case "--validate-empty":
            validateOption = true
        case "--debug-unpack":
            shouldDebugUnpack = true
        case "--performance-test":
            shouldPerformanceTest = true
        case "--extract-hashes":
            shouldExtractHashes = true
        case "--extract-paper":
            shouldExtractPaper = true
        case "--pressure-json":
            if index + 1 < args.count {
                pressureJsonFile = args[index + 1]
            }
        default:
            if index > 0 && !arg.hasPrefix("--") {
                // Check if this is the main input file or part of another flag
                // We only set inputFileIndex if it's not already claimed by a flag handler
                if pressureJsonFile == nil || args[index-1] != "--pressure-json" {
                    inputFileIndex = index
                }
            }
        }
    }
    
    // Handle Pressure JSON Test
    if let jsonFile = pressureJsonFile {
        print("Running pressure comparison test using: \(jsonFile)")
        PressureTestSuite.runFullAnalysis(jsonPath: jsonFile, configs: baseConfigs)
        return 0
    }
    
    if shouldDebugUnpack {
        print("=== Debug Mode: Testing LZUnpack only ===")
        
        guard inputFileIndex != -1 else {
            print("Usage: \(args[0]) --debug-unpack <input_file>")
            return 1
        }
        
        let filename = args[inputFileIndex]
        print("Testing unpack with file: \(filename)")
        
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: filename))
            let byteArray = [UInt8](data)
            
            print("Total file size: \(byteArray.count) bytes")
            
            // Use ArtFileHeader to parse the header
            guard let header = ArtFileHeader(data: byteArray) else {
                print("Error: Failed to parse file header")
                return 1
            }
            
            print("Header parsed successfully")
            print("Data size from header: \(header.dataSize)")
            
            // Use FileCursor to extract the compressed data
            let fc = FileCursor(byteArray)
            
            // Skip magic and version (8 bytes total)
            _ = fc.readBytes(8)
            
            // Skip version-specific extra header
            let version = UInt32(byteArray[4]) | UInt32(byteArray[5]) << 8 | UInt32(byteArray[6]) << 16 | UInt32(byteArray[7]) << 24
            print("Version: 0x\(String(version, radix: 16))")
            
            if (version & 0xFF) == 0x00 {
                _ = fc.readBytes(0x08)
            } else if version == 0x81 {
                _ = fc.readBytes(0x1C)
            } else if version == 0x82 {
                _ = fc.readBytes(0x21)
                // Read pins
                let pinCount = Int(fc.readLE32())
                for _ in 0..<pinCount {
                    var mat: [[Float]] = []
                    for _ in 0..<4 {
                        mat.append([
                            fc.readFloatLE(),
                            fc.readFloatLE(),
                            fc.readFloatLE(),
                            fc.readFloatLE()
                        ])
                    }
                    let nameLen = Int(fc.readLE32())
                    let nameBytes = fc.readBytes(nameLen)
                    _ = String(bytes: nameBytes, encoding: .utf8) ?? ""
                }
            }
            
            // Read compressed data size
            let compressedDataSize = Int(fc.readLE32())
            print("Compressed data size: \(compressedDataSize) bytes at offset \(fc.pos)")
            
            // Extract compressed data
            guard fc.pos + compressedDataSize <= byteArray.count else {
                print("Error: Compressed data size exceeds file size")
                return 1
            }
            
            let compressedData = fc.readBytes(compressedDataSize)
            print("Extracted \(compressedData.count) bytes of compressed data")
            
            // Print the first 32 bytes of compressed data for debugging
            let compressedHex = compressedData.prefix(32).map { String(format: "%02x", $0) }.joined()
            print("Compressed data (first 32 bytes): \(compressedHex)")
            
            // Pass the compressed data to MischiefUnpacker.unpack
            guard let unpackedData = MischiefUnpacker.unpack(byteInput: compressedData) else {
                print("Error: Failed to unpack data")
                return 1
            }
            
            let compressedHex2 = unpackedData.prefix(32).map { String(format: "%02x", $0) }.joined()
            print("Unpacked data (first 32 bytes): \(compressedHex2)")
            
            print("Successfully unpacked \(unpackedData.count) bytes")
            
            // Save the result
            let nsData = NSData(bytes: unpackedData, length: unpackedData.count)
            try nsData.write(to: URL(fileURLWithPath: "debug_unpacked.bin"))
            print("Saved to debug_unpacked.bin")
            
        } catch {
            print("Error: \(error)")
            return 1
        }
        
        return 0
    }
    
    if shouldExtractHashes {
        print("=== Extracting Texture Hashes ===")
        ArtParser.extractTextureHashes()
        return 0
    }
    
    // Normal execution path
    guard inputFileIndex != -1 else {
        print("Usage: \(args[0]) <input_file>")
        print("Or for debug: \(args[0]) --debug-unpack <input_file>")
        print("For performance testing: \(args[0]) --performance-test <input_file>")
        return 1
    }
    
    let filename = args[inputFileIndex]
    
    if shouldPerformanceTest {
        print("Performance testing with file: \(filename)")
        
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: filename))
            let byteArray = [UInt8](data)
            
            print("File size: \(byteArray.count) bytes")
            
            // Warm-up run (to account for caching effects)
            print("Performing warm-up run...")
            _ = ArtParser(data: byteArray)
            
            // Performance test
            print("Starting performance test...")
            let startTime = CFAbsoluteTimeGetCurrent()
            
            // Run the parser multiple times for more accurate measurement
            let iterations = 10
            for i in 0..<iterations {
                if i % 3 == 0 {
                    print("  Progress: \(i+1)/\(iterations)")
                }
                _ = ArtParser(data: byteArray)
            }
            
            let timeElapsed = CFAbsoluteTimeGetCurrent() - startTime
            let avgTime = timeElapsed / Double(iterations)
            
            print("Performance test results:")
            print("  Total time for \(iterations) iterations: \(timeElapsed) seconds")
            print("  Average time per parse: \(avgTime) seconds")
            print("  Parses per second: \(1.0 / avgTime)")
            
        } catch {
            print("Error reading file: \(error)")
            return 1
        }
        
        return 0
    }
    
    
    print("Processing file: \(filename)")
    
    do {
        let data = try Data(contentsOf: URL(fileURLWithPath: filename))
        let byteArray = [UInt8](data)
        
        //        print("File size: \(byteArray.count) bytes")
        
        guard let art = ArtParser(data: byteArray, enableValidation: validateOption) else {
            print("Error: Invalid art file format")
            return 1
        }
        
        
        // Create a Codable representation of the art data
        let codableArtData = CodableArtData(from: art)
        
        // Print in Python-style format to console
        print("\n=== PARSED RESULTS ===")
        print(codableArtData.toPythonStyleString())
        
        if shouldExtractPaper {
            guard let art = ArtParser(data: byteArray) else {
                print("Error: Invalid art file format")
                return 1
            }
            
            let outputFilename = "extracted_texture.jpg"
            if art.extractTextureData(to: outputFilename) {
                print("Texture extraction successful")
            } else {
                print("Texture extraction failed")
            }
            return 0
        }
        
        
    } catch {
        print("Error reading file: \(error)")
        return 1
    }
    
    return 0
}

// MARK: - Entry point
#if !ART2PNG_MODULE
@main
struct EntryPoint {
    static func main() {
        if CommandLine.arguments.count > 1 {
            exit(runProgram())
        }
    }
}
#endif
