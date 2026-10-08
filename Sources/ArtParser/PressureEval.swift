import Foundation
#if os(Linux)
import CoreFoundation
#endif

// MARK: - Test Data Models
struct PressurePoint: Codable {
    let x: Double
    let y: Double
    let p: Double
    let raw_p: Int?
    let radius: Double
}

// MARK: - Strategy & Config

struct UnwrapConfig {
    let name: String
    
    init(name: String, maxWraps: Int = 6
    ) {
        self.name = name
    }
}

func unwrapPressureSequenceInterface(rawPs: [Int]) -> [Int] {
    return unwrapPressureSequence(rawPs: rawPs)
}


// MARK: - Testing & Benchmarking Suite

class PressureTestSuite {
    
    struct Result {
        let configName: String
        let avgRmse: Double
        let validStrokes: Int
    }
    
    struct StrokeResult {
        let index: Int
        let rmse: Double
        let maxRadius: Double
        
        let rmseStart: Double
        let rmseMid: Double
        let rmseEnd: Double
        let normOffset: Double
    }
    
    // helper to compute window sizes for edge RMSE
    private static func edgeWindowSize(forCount n: Int) -> Int {
        // conservative: use up to 3 points or ~1/4th of stroke (whichever smaller), but at least 1
        return max(1, min(3, n / 4))
    }
    
    private static func mean(of arr: [Double]) -> Double {
        guard !arr.isEmpty else { return 0.0 }
        return arr.reduce(0.0, +) / Double(arr.count)
    }
    
    private static func computePerStrokeDiagnostics(
        normalizedNew: [Double],
        normalizedRadii: [Double]
    ) -> (rmseStart: Double, rmseMid: Double, rmseEnd: Double, normOffset: Double) {
        
        let n = normalizedNew.count
        guard n > 0 && normalizedRadii.count == n else {
            return (0.0, 0.0, 0.0, 0.0)
        }
        
        let ew = edgeWindowSize(forCount: n)
        
        // Start window
        let startEstF = normalizedNew[0..<ew].map { Float($0) }
        let startTgt = Array(normalizedRadii[0..<ew])
        let rmseStart = calculateRMSE(startEstF, startTgt)
        
        // End window
        let endStart = max(0, n - ew)
        let endEstF = normalizedNew[endStart..<n].map { Float($0) }
        let endTgt = Array(normalizedRadii[endStart..<n])
        let rmseEnd = calculateRMSE(endEstF, endTgt)
        
        // Mid window (exclude edges). If not enough points, set to 0.0
        var rmseMid: Double = 0.0
        if n > ew * 2 {
            let midStart = ew
            let midEnd = n - ew
            let midEstF = normalizedNew[midStart..<midEnd].map { Float($0) }
            let midTgt = Array(normalizedRadii[midStart..<midEnd])
            rmseMid = calculateRMSE(midEstF, midTgt)
        } else {
            // If no mid region, keep rmseMid as 0.0 to indicate "not-applicable"
            rmseMid = 0.0
        }
        
        // normalized mean offset
        let meanEst = mean(of: normalizedNew)
        let meanTgt = mean(of: normalizedRadii)
        let normOffset = abs(meanEst - meanTgt)
        
        return (rmseStart, rmseMid, rmseEnd, normOffset)
    }
    
    static func calculateRMSE(_ estimates: [Float], _ targets: [Double]) -> Double {
        var sumSq: Double = 0
        let count = min(estimates.count, targets.count)
        guard count > 0 else { return 0.0 }
        for i in 0..<count {
            let diff = Double(estimates[i]) - targets[i]
            sumSq += diff * diff
        }
        return sqrt(sumSq / Double(count))
    }
    
    static func smoothSignal(_ signal: [Int], window: Int = 3) -> [Double] {
        guard signal.count > window else { return signal.map { Double($0) } }
        var smoothed = [Double](repeating: 0.0, count: signal.count)
        let half = window / 2
        
        for i in 0..<signal.count {
            var sum: Double = 0
            var count = 0
            for j in (i - half)...(i + half) {
                if j >= 0 && j < signal.count {
                    sum += Double(signal[j])
                    count += 1
                }
            }
            smoothed[i] = sum / Double(count)
        }
        return smoothed
    }
    
    /// Composite scoring that distinguishes shape error, whole-stroke offset, edge blobs, isolated spikes, and abrupt small-motion jumps.
    /// Returns (totalError, (shapeRMSE, offset, edgePenalty, spikePenalty, jumpPenalty))
    static func computeCompositeError(normalizedNew: [Double],
                                      normalizedRadii: [Double],
                                      xs: [Float],
                                      ys: [Float]) -> (Double, (Double, Double, Double, Double, Double)) {
        guard normalizedNew.count == normalizedRadii.count, normalizedNew.count > 1 else {
            return (0.0, (0,0,0,0,0))
        }
        
        // 1) Shape RMSE (same domain [0..1])
        let shapeRMSE = calculateRMSE(normalizedNew.map { Float($0) }, normalizedRadii)
        
        // 2) Mean offset (normalized domain)
        let meanEst = normalizedNew.reduce(0.0, +) / Double(normalizedNew.count)
        let meanTgt = normalizedRadii.reduce(0.0, +) / Double(normalizedRadii.count)
        let offset = abs(meanEst - meanTgt) // in [0,1]
        
        // 3) Edge blob penalty (first/last sample mismatch vs neighbor, weighted by spatial motion)
        let spatialThreshold: Float = 2.0  // pixels: small movement means edge shouldn't change much
        func spatialWeight(at i: Int, neighbor: Int) -> Double {
            let dx = xs[i] - xs[neighbor]
            let dy = ys[i] - ys[neighbor]
            let d = hypotf(dx, dy)
            if d < spatialThreshold { return 1.0 }    // very small motion -> strong penalty
            if d < spatialThreshold * 3.0 { return 0.4 } // moderate motion -> weaker
            return 0.15 // fast motion -> little penalty
        }
        
        var edgePenalty: Double = 0.0
        // first point
        if normalizedNew.count >= 2 {
            let diff0 = abs(normalizedNew[0] - normalizedNew[1])
            let w0 = spatialWeight(at: 0, neighbor: 1)
            // small baseline tolerance to avoid tiny measurement noise
            edgePenalty += max(0.0, diff0 - 0.03) * w0 * 1.5
            // last point
            let n = normalizedNew.count
            let diffL = abs(normalizedNew[n-1] - normalizedNew[n-2])
            let wL = spatialWeight(at: n-1, neighbor: n-2)
            edgePenalty += max(0.0, diffL - 0.03) * wL * 1.5
        }
        
        // 4) Isolated single-sample spike penalty
        var spikePenalty: Double = 0.0
        if normalizedNew.count >= 3 {
            for i in 1..<(normalizedNew.count - 1) {
                let left = normalizedNew[i-1]
                let mid = normalizedNew[i]
                let right = normalizedNew[i+1]
                // neighbors agree but mid differs
                if abs(left - right) < 0.04 && abs(mid - left) > 0.06 {
                    // verify small spatial motion around i
                    let dPrev = hypotf(xs[i] - xs[i-1], ys[i] - ys[i-1])
                    let dNext = hypotf(xs[i+1] - xs[i], ys[i+1] - ys[i])
                    if dPrev < spatialThreshold && dNext < spatialThreshold {
                        spikePenalty += min(0.6, abs(mid - left) * 2.0)
                    } else {
                        // if motion is moderate, down-weight
                        spikePenalty += min(0.25, abs(mid - left) * 1.0)
                    }
                }
            }
        }
        
        // 5) Abrupt jump penalty in small-motion zones (indicates unwrap jumps)
        var jumpPenalty: Double = 0.0
        for i in 1..<normalizedNew.count {
            let dval = abs(normalizedNew[i] - normalizedNew[i-1])
            let dx = xs[i] - xs[i-1]
            let dy = ys[i] - ys[i-1]
            let dist = hypotf(dx, dy)
            if dist < spatialThreshold && dval > 0.25 {
                // severe jump while finger didn't move much
                jumpPenalty += min(1.0, (dval - 0.25) * 2.0)
            } else if dist < spatialThreshold * 2.0 && dval > 0.40 {
                jumpPenalty += min(0.6, (dval - 0.40) * 1.5)
            }
        }
        
        // 6) Combine components with conservative weights (tunable)
        // Keep final composite roughly in same magnitude as original RMSE (0..2 typical)
        let totalError = shapeRMSE
        + 0.9 * offset            // strong penalty for whole-stroke offset
        + 1.4 * edgePenalty       // make edge blobs prominent
        + 0.9 * spikePenalty      // single-sample spike penalty
        + 0.6 * jumpPenalty       // abrupt jumps in small motion
        
        return (totalError, (shapeRMSE, offset, edgePenalty, spikePenalty, jumpPenalty))
    }
    
    /// Evaluates a single configuration against the dataset
    static func evaluate(strokes: [[PressurePoint]], config: UnwrapConfig) -> Result {
        var totalRmse: Double = 0
        var validCount = 0
        
        for stroke in strokes {
            let validPoints = stroke.filter { $0.raw_p != nil && $0.radius > 0 }
            guard !validPoints.isEmpty else { continue }
            
            // --- Cull Last Point ---
            // Since each stroke ends with a 0 and shares coordinates, we drop the last point
            // from the raw data AND the corresponding radius/coordinate data.
            let culledPoints = validPoints.dropLast()
            
            let rawPs = culledPoints.map { $0.raw_p! }
            let radii = culledPoints.map { $0.radius }
            let xs = culledPoints.map { Float($0.x) }
            let ys = culledPoints.map { Float($0.y) }
            
            // Ensure we still have points after culling
            guard !rawPs.isEmpty else { continue }
            
            let radiiThicknessadjust = radii.map { $0 * 0.8 }
            let clampedRadii = radiiThicknessadjust.map { max(1.0, min(33.0, $0)) }
            
            // filter by radius span
            guard let rMax = clampedRadii.max(), rMax > 8.9 else { continue }
            guard let rMin = clampedRadii.min(), rMax > rMin else { continue }
            
            // Normalize radius (target)
            let normalizedRadii = clampedRadii.map { ($0 - rMin) / (rMax - rMin) }
            
            // Unwrap (existing function)
            //            let unwrapped = unwrapPressureSequenceInterface(rawPs: rawPs, xs: xs, ys: ys)
            let unwrapped = unwrapPressureSequenceInterface(rawPs: rawPs)
            //            let unwrapped = guardedUnwrap(
            //                rawPs: rawPs,
            //                xs: xs,
            //                ys: ys,
            //                radii: radii,
            //                stödhjul: stödhjul
            //            )
            
            // Smooth to mimic rendering pipeline
            let smoothedUnwrapped = smoothSignal(unwrapped, window: 3)
            
            // Normalize unwrapped
            guard let pMin = smoothedUnwrapped.min(), let pMax = smoothedUnwrapped.max(), pMax > pMin else { continue }
            let normalizedNew = smoothedUnwrapped.map { ($0 - pMin) / (pMax - pMin) }
            
            // Composite scoring
            let (composite, _) = computeCompositeError(normalizedNew: normalizedNew, normalizedRadii: normalizedRadii, xs: xs, ys: ys)
            
            totalRmse += composite
            validCount += 1
        }
        
        let avg = validCount > 0 ? totalRmse / Double(validCount) : 0.0
        return Result(configName: config.name, avgRmse: avg, validStrokes: validCount)
    }
    
    /// Runs a list of configurations, prints a leaderboard, and analyzes worst/best strokes for the winner
    static func runFullAnalysis(jsonPath: String, configs: [UnwrapConfig], topWorstCount: Int = 400, topBestCount: Int = 100, minPointsInStroke: Int = 0) {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
            let strokes = try JSONDecoder().decode([[PressurePoint]].self, from: data)
            
            // Filter strokes based on minPointsInStroke for analysis
            let filteredStrokes = minPointsInStroke > 0 ? strokes.filter { $0.count >= minPointsInStroke } : strokes
            
            print("========== LEADERBOARD ==========")
            print("Strokes: \(strokes.count) (Analyzed: \(filteredStrokes.count)), Configs: \(configs.count)\n")
            
            var results: [Result] = []
            
            for config in configs {
                // Evaluate on filtered strokes
                let res = evaluate(strokes: filteredStrokes, config: config)
                results.append(res)
                print(String(format: "%-30@ | RMSE: %.4f | Valid: %d", res.configName, res.avgRmse, res.validStrokes))
            }
            
            results.sort { $0.avgRmse < $1.avgRmse }
            guard let winner = results.first else { return }
            
            print("\n========== WINNER: \(winner.configName) ==========")
            print("RMSE: \(String(format: "%.4f", winner.avgRmse))")
            
            // Deep Dive on Winner
            guard let winnerConfig = configs.first(where: { $0.name == winner.configName }) else {
                print("Warning: Could not find winner config object.")
                return
            }
            
            print("Performing detailed stroke analysis for \(winnerConfig.name)...")
            let detailedResults = evaluateAllStrokes(strokes: filteredStrokes, config: winnerConfig)
            
            // Report Worst
            analyzeWorstStrokes(allResults: detailedResults, topN: topWorstCount)
            
            // Report Best
            analyzeBestStrokes(allResults: detailedResults, topN: topBestCount)
            
            summaryDiagnostics(allResults: detailedResults)
            
        } catch {
            print("Error loading JSON: \(error)")
        }
    }
    
    private static func evaluateAllStrokes(strokes: [[PressurePoint]], config: UnwrapConfig) -> [StrokeResult] {
        var results: [StrokeResult] = []
        
        for (index, stroke) in strokes.enumerated() {
            let validPoints = stroke.filter { $0.raw_p != nil && $0.radius > 0 }
            guard !validPoints.isEmpty else { continue }
            
            // --- Cull Last Point ---
            // Since each stroke ends with a 0 and shares coordinates, we drop the last point
            // from the raw data AND the corresponding radius/coordinate data.
            let culledPoints = validPoints.dropLast()
            
            let rawPs = culledPoints.map { $0.raw_p! }
            let radii = culledPoints.map { $0.radius }
            //            let xs = culledPoints.map { Float($0.x) }
            //            let ys = culledPoints.map { Float($0.y) }
            
            // Ensure we still have points after culling
            guard !rawPs.isEmpty else { continue }
            
            let radiiThicknessadjust = radii.map { $0 * 0.8 }
            let clampedRadii = radiiThicknessadjust.map { max(1.0, min(33.0, $0)) }
            
            guard let rMax = clampedRadii.max(), rMax > 8.9 else { continue }
            guard let rMin = clampedRadii.min(), rMax > rMin else { continue }
            
            let normalizedRadii = clampedRadii.map { ($0 - rMin) / (rMax - rMin) }
            
            // Unwrap using your chosen function
            //            let unwrapped = unwrapPressureSequenceInterface(rawPs: rawPs, xs: xs, ys: ys)
            let unwrapped = unwrapPressureSequenceInterface(rawPs: rawPs)
            
            // Smooth (as in evaluation pipeline)
            let smoothedUnwrapped = smoothSignal(unwrapped, window: 3)
            
            guard let pMin = smoothedUnwrapped.min(), let pMax = smoothedUnwrapped.max(), pMax > pMin else { continue }
            let normalizedNew = smoothedUnwrapped.map { Double($0 - pMin) / Double(pMax - pMin) }
            
            // Overall RMSE (shape)
            let overallRmse = calculateRMSE(normalizedNew.map { Float($0) }, normalizedRadii)
            
            // Per-window diagnostics
            let (rmseStart, rmseMid, rmseEnd, normOffset) = computePerStrokeDiagnostics(normalizedNew: normalizedNew, normalizedRadii: normalizedRadii)
            
            results.append(
                StrokeResult(
                    index: index,
                    rmse: overallRmse,
                    maxRadius: rMax,
                    rmseStart: rmseStart,
                    rmseMid: rmseMid,
                    rmseEnd: rmseEnd,
                    normOffset: normOffset
                )
            )
        }
        return results
    }
    
    static func analyzeWorstStrokes(allResults: [StrokeResult], topN: Int) {
        let sorted = allResults.sorted { $0.rmse > $1.rmse } // Worst first
        let worst = sorted.prefix(topN)
        
        print("\n========== TOP \(topN) WORST STROKES (WITH EDGE / MID RMSE) ==========")
        print("Format: IDX | RMSE(all) | RMSE(start) | RMSE(mid) | RMSE(end) | Offset     | MaxR")
        for res in worst {
            let idxStr = String(format: "S%04d", res.index)
            let line = String(
                format: ">>> %@   | %.4f    | %.4f      | %.4f    | %.4f    | off=%.4f | R=%.1f <<<",
                idxStr, res.rmse, res.rmseStart, res.rmseMid, res.rmseEnd, res.normOffset, res.maxRadius
            )
            print(line)
        }
        print("=============================================\n")
    }
    
    static func analyzeBestStrokes(allResults: [StrokeResult], topN: Int) {
        let sorted = allResults.sorted { $0.rmse < $1.rmse } // Ascending (Best first)
        let best = sorted.prefix(topN)
        
        print("========== TOP \(topN) BEST STROKES (REFERENCE) ==========")
        for res in best {
            let idxStr = String(format: "S%04d", res.index)
            print(">>> \(idxStr) | RMSE: \(String(format: "%.4f", res.rmse)) | MaxRadius: \(String(format: "%.1f", res.maxRadius)) <<<")
        }
        print("=======================================================\n")
    }
    
    static func summaryDiagnostics(allResults: [StrokeResult]) {
        let count = allResults.count
        guard count > 0 else { return }
        
        func avg(_ keyPath: KeyPath<StrokeResult, Double>) -> Double {
            return allResults.map { $0[keyPath: keyPath] }.reduce(0.0, +) / Double(count)
        }
        
        print("SUMMARY DIAGNOSTICS (avg across analyzed strokes):")
        print(String(format: "avg RMSE all:   %.4f", avg(\.rmse)))
        print(String(format: "avg RMSE start: %.4f", avg(\.rmseStart)))
        print(String(format: "avg RMSE mid:   %.4f", avg(\.rmseMid)))
        print(String(format: "avg RMSE end:   %.4f", avg(\.rmseEnd)))
        print(String(format: "avg norm offset: %.4f", avg(\.normOffset)))
    }
}

// MARK: - Tuning & Configs

// --- Configs ---

let baseConfigs: [UnwrapConfig] = [
    UnwrapConfig(name: "0. Defaults"),
]
