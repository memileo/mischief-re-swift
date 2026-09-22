import Foundation
#if os(Linux)
import Silica
import CoreFoundation
//import Cairo
//import JPEG
#elseif os(macOS)
import CoreGraphics
#endif

extension Renderer {
    // MARK: - Resampling & Splines
    // Full pipeline: spline -> dense samples -> arc-length table -> uniform sampling
    // Optimized resampling with early rejection and bounds checking
    internal func buildResampledStrokeWithSpline(_ raw: [Point], stepPx: CGFloat, samplesPerSegment: Int = 6, gamma: Float = 1.0, isPolyline: Bool) -> [Point] {
        guard raw.count > 1 else { return raw }
        
        // Add debug print for input pressure range
        //        let inputPressureRange = (raw.map { $0.p }.min() ?? 0, raw.map { $0.p }.max() ?? 0)
        //        print("[P][spline_input] count=\(raw.count), p.min=\(inputPressureRange.0), p.max=\(inputPressureRange.1)")
        
        // Performance monitoring
        let monitor = PerformanceMonitor.shared
        monitor.startTimer("resampling")
        
        // Early rejection: calculate stroke bounds first
        var minX = CGFloat.greatestFiniteMagnitude
        var minY = CGFloat.greatestFiniteMagnitude
        var maxX = -CGFloat.greatestFiniteMagnitude
        var maxY = -CGFloat.greatestFiniteMagnitude
        
        for point in raw {
            minX = min(minX, CGFloat(point.x))
            minY = min(minY, CGFloat(point.y))
            maxX = max(maxX, CGFloat(point.x))
            maxY = max(maxY, CGFloat(point.y))
        }
        
        let strokeBounds = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        
        // Skip if stroke is too small to be visible
        if strokeBounds.width < 0.5 && strokeBounds.height < 0.5 {
            //            monitor.endTimer("resampling")
            return raw.count > 0 ? [raw[0]] : []
        }
        
        // Handle negative pressure values by clamping to 0
        let clamped = raw.map { (pt) -> Point in
            let p = max(0.0, pt.p)  // Now working with Float
            return Point(x: pt.x, y: pt.y, p: p)
        }
        
        // Early rejection for degenerate strokes
        let (poly, pressures) = buildSplineSamples(clamped, samplesPerSegment: samplesPerSegment, isPolyline: isPolyline)
        guard poly.count > 1 else {
            //            monitor.endTimer("resampling")
            return clamped
        }
        
        let (segLens, cumulative, total) = buildArcLengthTable(poly)
        guard total > 0.0 else {
            //            monitor.endTimer("resampling")
            return clamped
        }
        
        // Ensure minimum step size to prevent too dense sampling
        let adjustedStep = max(stepPx, 0.5)
        
        // Pressure-adaptive step scaling: smaller pressure = denser sampling
        let minStepFactor: CGFloat = 0.01   // At p=0, use 1% of base step
        let maxStepFactor: CGFloat = 1.2   // At p=1, use 120% of base step
        
        // Conservative estimate since step size varies
        let estimatedSamples = max(1, Int(ceil(total / (adjustedStep * minStepFactor))))
        var out: [Point] = []
        out.reserveCapacity(min(estimatedSamples + 2, 10000))
        
        var target: CGFloat = 0.0
        var lastPoint: Point? = nil
        var consecutiveSkips = 0
        let maxConsecutiveSkips = 2
        let maxIterations = estimatedSamples * 2
        
        for _ in 0..<maxIterations {
            guard target <= total else { break }
            
            let p = sampleAtDistance(poly: poly, pressures: pressures, segLens: segLens, cumulative: cumulative, total: total, target: target)
            
            // Skip points that are too close to the previous one
            if let last = lastPoint {
                let dx = p.x - last.x
                let dy = p.y - last.y
                let distance = sqrtf(dx*dx + dy*dy)
                let adaptiveThreshold = max(Float(adjustedStep * minStepFactor) * 0.15, 0.3)
                
                if distance < adaptiveThreshold && consecutiveSkips < maxConsecutiveSkips {
                    consecutiveSkips += 1
                    target += adjustedStep * minStepFactor * 0.5
                    continue
                }
                consecutiveSkips = 0
            }
            
            out.append(p)
            lastPoint = p
            
            // Pressure-adaptive step: lower pressure -> smaller step -> denser sampling
            let normalizedP = min(max(CGFloat(p.p), 0.0), 1.0)
            let stepFactor = minStepFactor + (maxStepFactor - minStepFactor) * pow(normalizedP, CGFloat(gamma))
            target += adjustedStep * stepFactor
        }
        
        // Ensure we always have at least the first and last points
        if out.isEmpty && !clamped.isEmpty {
            out.append(clamped[0])
        }
        
        if let lastOriginal = clamped.last, (out.isEmpty || out.last! != lastOriginal) {
            out.append(lastOriginal)
        }
        
        //        monitor.endTimer("resampling")
        //        monitor.incrementCounter("strokes_resampled")
        
        // Add debug print for output pressure range
        //        let outputPressureRange = (out.map { $0.p }.min() ?? 0, out.map { $0.p }.max() ?? 0)
        //        print("[P][spline_output] count=\(out.count), p.min=\(outputPressureRange.0), p.max=\(outputPressureRange.1)")
        
        return out
    }
    
    // Build dense sampled polyline from Catmull-Rom segments and sample pressures along the same param t
    func buildSplineSamples(_ pts: [Point], samplesPerSegment: Int, isPolyline: Bool)
    -> (positions: [CGPoint], pressures: [Float])
    {
        // Not enough points → return as-is
        guard pts.count >= 2 else {
            return (
                pts.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) },
                pts.map { Float($0.p) }
            )
        }
        
        // Convert once
        let gpts: [CGPoint] = pts.map { CGPoint(x: CGFloat($0.x), y: CGFloat($0.y)) }
        let pressures: [Float] = pts.map { $0.p }
        
        // Special-case a line with 2 points (no valid CR spline)
        if gpts.count == 2 {
            var pos: [CGPoint] = []
            var press: [Float] = []
            pos.reserveCapacity(samplesPerSegment + 1)
            press.reserveCapacity(samplesPerSegment + 1)
            
            for i in 0...samplesPerSegment {
                let t = CGFloat(i) / CGFloat(samplesPerSegment)
                pos.append(CGPoint(
                    x: lerp(gpts[0].x, gpts[1].x, t),
                    y: lerp(gpts[0].y, gpts[1].y, t)
                ))
                
                let p = pressures[0] + (pressures[1] - pressures[0]) * Float(t)
                press.append(p)
            }
            
            return (pos, press)
        }
        
        if isPolyline {
            return (gpts, pressures)
        }
        
        // Pad ends for standard Catmull-Rom
        var ext: [CGPoint] = []
        ext.reserveCapacity(gpts.count + 2)
        ext.append(gpts.first!)        // p0 duplicated
        ext.append(contentsOf: gpts)   // p1..pn
        ext.append(gpts.last!)         // p{n+1} duplicated
        
        var outPos: [CGPoint] = []
        var outP: [Float] = []
        outPos.reserveCapacity((gpts.count - 1) * samplesPerSegment + 1)
        outP.reserveCapacity((gpts.count - 1) * samplesPerSegment + 1)
        
        // For each segment between original points
        for i in 0..<(gpts.count - 1) {
            let p0 = ext[i]
            let p1 = ext[i + 1]
            let p2 = ext[i + 2]
            let p3 = ext[i + 3]
            
            let pr1 = pressures[i]
            let pr2 = pressures[i + 1]
            
            for s in 0...samplesPerSegment {
                let t = CGFloat(s) / CGFloat(samplesPerSegment)
                
                // Catmull-Rom for positions
                outPos.append(catmullRom(p0, p1, p2, p3, t))
                
                // Linear for pressures (same as before)
                outP.append(pr1 + (pr2 - pr1) * Float(t))
            }
        }
        
        return (outPos, outP)
    }
    
    
    // Compute arc-length table for a polyline
    func buildArcLengthTable(_ poly: [CGPoint]) -> (segLens: [CGFloat], cumulative: [CGFloat], total: CGFloat) {
        let n = poly.count
        if n < 2 { return ([], [0.0], 0.0) }
        
        var segLens: [CGFloat] = []
        var cumulative: [CGFloat] = [0.0]
        segLens.reserveCapacity(n - 1)
        cumulative.reserveCapacity(n)
        
        var total: CGFloat = 0.0
        for i in 0..<(n - 1) {
            let d = dist(poly[i].x, poly[i].y, poly[i + 1].x, poly[i + 1].y)
            segLens.append(d)
            total += d
            cumulative.append(total)
        }
        return (segLens, cumulative, total)
    }
    
    // Sample position+pressure at a target distance along the sampled spline polyline
    func sampleAtDistance(
        poly: [CGPoint],
        pressures: [Float],
        segLens: [CGFloat],
        cumulative: [CGFloat],
        total: CGFloat,
        target: CGFloat
    ) -> Point {
        let tgt = min(max(target, 0.0), total)
        
        // cumulative[0] is 0, so segment index is lowerBound - 1
        let idx = max(cumulative.lowerBound(tgt) - 1, 0)
        
        if idx >= segLens.count {
            return Point(x: Float(poly.last!.x), y: Float(poly.last!.y), p: pressures.last!)
        }
        
        let segStart = cumulative[idx]
        let segLen = segLens[idx]
        let localT: CGFloat = segLen > 0 ? (tgt - segStart) / segLen : 0.0
        
        let a = poly[idx]
        let b = poly[idx + 1]
        let x = a.x + localT * (b.x - a.x)
        let y = a.y + localT * (b.y - a.y)
        
        // Interpolate pressure
        let pa = pressures[idx]
        let pb = pressures[idx + 1]
        let p = Float(CGFloat(pa) + (CGFloat(pb) - CGFloat(pa)) * localT)
        
        return Point(x: Float(x), y: Float(y), p: p)
    }
}

@inline(__always) func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { return a + (b - a) * t }
//    @inline(__always) func lerpF(_ a: Int, _ b: Int, _ t: Float) -> Int { return a + Int((Float(b - a) * t)) }

// Compute Euclidean distance between two points
func dist(_ ax: CGFloat, _ ay: CGFloat, _ bx: CGFloat, _ by: CGFloat) -> CGFloat {
    let dx = bx - ax
    let dy = by - ay
    return sqrt(dx*dx + dy*dy)
}

@inline(__always)
internal func catmullRom(_ p0: CGPoint, _ p1: CGPoint, _ p2: CGPoint, _ p3: CGPoint, _ t: CGFloat) -> CGPoint {
    func dist(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = a.x - b.x
        let dy = a.y - b.y
        // Replaces pow(dx*dx + dy*dy, 0.25). sqrt is drastically faster than pow.
        return sqrt(sqrt(dx * dx + dy * dy))
    }
    
    let d01 = max(dist(p0, p1), 1e-6)
    let d12 = max(dist(p1, p2), 1e-6)
    let d23 = max(dist(p2, p3), 1e-6)
    
    let t1 = d01
    let t2 = t1 + d12
    
    let u = t1 + t * d12
    
    // Precompute inverse distances to turn divisions into multiplications
    let inv_d01 = 1.0 / d01
    let inv_d23 = 1.0 / d23
    let inv_t2 = 1.0 / t2
    let inv_t3_t1 = 1.0 / (d12 + d23)
    
    let t_d12 = t * d12
    let one_minus_t = 1.0 - t
    let d12_1mt = d12 * one_minus_t
    
    // Algebraically simplified Barry-Goldman algorithm
    let A1x = (-t_d12 * p0.x + u * p1.x) * inv_d01
    let A1y = (-t_d12 * p0.y + u * p1.y) * inv_d01
    
    // A2 is just a simple LERP
    let A2x = p1.x + (p2.x - p1.x) * t
    let A2y = p1.y + (p2.y - p1.y) * t
    
    let A3x = ((d12_1mt + d23) * p2.x - d12_1mt * p3.x) * inv_d23
    let A3y = ((d12_1mt + d23) * p2.y - d12_1mt * p3.y) * inv_d23
    
    let B1x = (d12_1mt * A1x + u * A2x) * inv_t2
    let B1y = (d12_1mt * A1y + u * A2y) * inv_t2
    
    let B2x = ((d12_1mt + d23) * A2x + t_d12 * A3x) * inv_t3_t1
    let B2y = ((d12_1mt + d23) * A2y + t_d12 * A3y) * inv_t3_t1
    
    // C is just a simple LERP
    let Cx = B1x + (B2x - B1x) * t
    let Cy = B1y + (B2y - B1y) * t
    
    return CGPoint(x: Cx, y: Cy)
}

internal struct CRPointSpan {
    let p0: CGPoint; let p1: CGPoint; let p2: CGPoint; let p3: CGPoint
}

internal struct CRScalarSpan {
    let s0: CGFloat; let s1: CGFloat; let s2: CGFloat; let s3: CGFloat
}

// Exact mathematical subdivision of a Catmull-Rom span (CGPoint)
func subdivideCRPoint(_ span: CRPointSpan) -> (CRPointSpan, CRPointSpan) {
    let p0 = span.p0, p1 = span.p1, p2 = span.p2, p3 = span.p3
    
    // Convert CR to Bezier
    let b0 = p1
    let b1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6.0, y: p1.y + (p2.y - p0.y) / 6.0)
    let b2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6.0, y: p2.y - (p3.y - p1.y) / 6.0)
    let b3 = p2
    
    // De Casteljau split at t=0.5
    let m01 = CGPoint(x: (b0.x + b1.x) / 2.0, y: (b0.y + b1.y) / 2.0)
    let m12 = CGPoint(x: (b1.x + b2.x) / 2.0, y: (b1.y + b2.y) / 2.0)
    let m23 = CGPoint(x: (b2.x + b3.x) / 2.0, y: (b2.y + b3.y) / 2.0)
    let m012 = CGPoint(x: (m01.x + m12.x) / 2.0, y: (m01.y + m12.y) / 2.0)
    let m123 = CGPoint(x: (m12.x + m23.x) / 2.0, y: (m12.y + m23.y) / 2.0)
    let m = CGPoint(x: (m012.x + m123.x) / 2.0, y: (m012.y + m123.y) / 2.0)
    
    // Convert Left Bezier back to CR
    let l_p0 = CGPoint(x: m.x - 6.0 * (m01.x - b0.x), y: m.y - 6.0 * (m01.y - b0.y))
    let l_p1 = b0
    let l_p2 = m
    let l_p3 = CGPoint(x: b0.x + 6.0 * (m.x - m012.x), y: b0.y + 6.0 * (m.y - m012.y))
    let left = CRPointSpan(p0: l_p0, p1: l_p1, p2: l_p2, p3: l_p3)
    
    // Convert Right Bezier back to CR
    let r_p0 = CGPoint(x: b3.x - 6.0 * (m123.x - m.x), y: b3.y - 6.0 * (m123.y - m.y))
    let r_p1 = m
    let r_p2 = b3
    let r_p3 = CGPoint(x: m.x + 6.0 * (b3.x - m23.x), y: m.y + 6.0 * (b3.y - m23.y))
    let right = CRPointSpan(p0: r_p0, p1: r_p1, p2: r_p2, p3: r_p3)
    
    return (left, right)
}

// Exact mathematical subdivision of a Catmull-Rom span (CGFloat)
func subdivideCRScalar(_ span: CRScalarSpan) -> (CRScalarSpan, CRScalarSpan) {
    let s0 = span.s0, s1 = span.s1, s2 = span.s2, s3 = span.s3
    
    let b0 = s1
    let b1 = s1 + (s2 - s0) / 6.0
    let b2 = s2 - (s3 - s1) / 6.0
    let b3 = s2
    
    let m01 = (b0 + b1) / 2.0
    let m12 = (b1 + b2) / 2.0
    let m23 = (b2 + b3) / 2.0
    let m012 = (m01 + m12) / 2.0
    let m123 = (m12 + m23) / 2.0
    let m = (m012 + m123) / 2.0
    
    let l_s0 = m - 6.0 * (m01 - b0)
    let l_s1 = b0
    let l_s2 = m
    let l_s3 = b0 + 6.0 * (m - m012)
    let left = CRScalarSpan(s0: l_s0, s1: l_s1, s2: l_s2, s3: l_s3)
    
    let r_s0 = b3 - 6.0 * (m123 - m)
    let r_s1 = m
    let r_s2 = b3
    let r_s3 = m + 6.0 * (b3 - m23)
    let right = CRScalarSpan(s0: r_s0, s1: r_s1, s2: r_s2, s3: r_s3)
    
    return (left, right)
}

@inline(__always)
func isSafeAngle(_ v1: CGPoint, _ v2: CGPoint) -> Bool {
    let dot = v1.x * v2.x + v1.y * v2.y
    if dot <= 0 { return false }
    let len1Sq = v1.x * v1.x + v1.y * v1.y
    let len2Sq = v2.x * v2.x + v2.y * v2.y
    // cos(60) = 0.5. We want cos(angle) > 0.5
    // dot / (len1 * len2) > 0.5  =>  4 * dot^2 > len1Sq * len2Sq
    return 4.0 * dot * dot > len1Sq * len2Sq
}

@inline(__always)
func isStraightAngle(_ v1: CGPoint, _ v2: CGPoint) -> Bool {
    let dot = v1.x * v2.x + v1.y * v2.y
    if dot <= 0 { return false }
    let len1Sq = v1.x * v1.x + v1.y * v1.y
    let len2Sq = v2.x * v2.x + v2.y * v2.y
    // cos(3 degrees) ~= 0.9986
    return dot * dot > len1Sq * len2Sq * 0.998
}

internal func flattenAndBuild(span: CRPointSpan, rSpan: CRScalarSpan, oSpan: CRScalarSpan, seed: UInt32, depth: Int = 0, into segments: inout [GPUSplineSegment], isPolyline: Bool, isMarker: Bool) {
    
    if isPolyline {
        flattenPolyline(span: span, rSpan: rSpan, oSpan: oSpan, seed: seed, into: &segments)
        return
    }
    
    let p0 = span.p0, p1 = span.p1, p2 = span.p2, p3 = span.p3
    let r1 = rSpan.s1, r2 = rSpan.s2
    let o1 = oSpan.s1, o2 = oSpan.s2
    
    let dx = p2.x - p1.x
    let dy = p2.y - p1.y
    let h_chord = hypot(dx, dy)
    
    let v0 = CGPoint(x: p1.x - p0.x, y: p1.y - p0.y)
    let v1 = CGPoint(x: dx, y: dy)
    let v2 = CGPoint(x: p3.x - p2.x, y: p3.y - p2.y)
    
    var needsSubdivide = false
    if h_chord > 500.0 { needsSubdivide = true }
    if isMarker && h_chord > 10.0 { needsSubdivide = true }
    if !isSafeAngle(v0, v1) || !isSafeAngle(v1, v2) { needsSubdivide = true }
    
    if !needsSubdivide || depth > 8 {
        let r_max = max(r1, r2)
        
        // Changed from 1.5 to 1.0 for more overlap.
        // This allows the shader to use a simple `min` instead of `smin`,
        let shape2_max_len = min(
            5.0 * max(0.0, (r_max - 0.82) * abs(r1 - r2)),
            1.0 * r_max
        )
        
        var segmentType: UInt32 = 0
        if h_chord <= shape2_max_len || h_chord < 1.0 {
            segmentType = 2
        } else if isStraightAngle(v0, v1) && isStraightAngle(v1, v2) {
            segmentType = 0
        } else {
            segmentType = 1
        }
        
        // Append the final GPU struct directly
        segments.append(GPUSplineSegment(
            p0: SIMD2<Float>(Float(p0.x), Float(p0.y)),
            p1: SIMD2<Float>(Float(p1.x), Float(p1.y)),
            p2: SIMD2<Float>(Float(p2.x), Float(p2.y)),
            p3: SIMD2<Float>(Float(p3.x), Float(p3.y)),
            radius0: Float(r1), radius1: Float(r2),
            opacity0: Float(o1), opacity1: Float(o2),
            segmentType: segmentType,
            noiseSeed: seed
        ))
        return
    }
    
    let (leftP, rightP) = subdivideCRPoint(span)
    let (leftR, rightR) = subdivideCRScalar(rSpan)
    let (leftO, rightO) = subdivideCRScalar(oSpan)
    
    flattenAndBuild(span: leftP, rSpan: leftR, oSpan: leftO, seed: seed, depth: depth + 1, into: &segments, isPolyline: isPolyline, isMarker: isMarker)
    flattenAndBuild(span: rightP, rSpan: rightR, oSpan: rightO, seed: seed, depth: depth + 1, into: &segments, isPolyline: isPolyline, isMarker: isMarker)
}

func flattenPolyline(
    span: CRPointSpan,
    rSpan: CRScalarSpan,
    oSpan: CRScalarSpan,
    seed: UInt32,
    into segments: inout [GPUSplineSegment]
) {
    let p1 = span.p1, p2 = span.p2
    let dx = p2.x - p1.x, dy = p2.y - p1.y
    let len = hypot(dx, dy)
    
    // 1. Base target length on the maximum radius of this span
    let r_max = max(rSpan.s1, rSpan.s2)
    
    // 2. Determine how many radii long a segment should be.
    // Adjust this multiplier based on visual testing (e.g. 2.0 to 8.0).
    let radiusMultiplier: CGFloat = 0.5
    
    // We use max(..., 4.0) as a hard floor to prevent infinite subdivisions
    // or millions of segments if the radius is 0 or extremely small.
    let targetLen = max(4.0, r_max * radiusMultiplier)
    
    let n = max(1, Int((len / targetLen).rounded(.up)))
    let invN = 1.0 / CGFloat(n)
    
    // 3. Emit segments
    for i in 0..<n {
        let t0 = CGFloat(i) * invN
        let t1 = CGFloat(i + 1) * invN
        
        let a = CGPoint(x: p1.x + dx * t0, y: p1.y + dy * t0)
        let b = CGPoint(x: p1.x + dx * t1, y: p1.y + dy * t1)
        
        // Straight extrapolation for tangent hints
        let a0 = CGPoint(x: 2 * a.x - b.x, y: 2 * a.y - b.y)
        let b3 = CGPoint(x: 2 * b.x - a.x, y: 2 * b.y - a.y)
        
        // Linearly interpolate radius and opacity
        let r0 = rSpan.s1 + (rSpan.s2 - rSpan.s1) * t0
        let r1 = rSpan.s1 + (rSpan.s2 - rSpan.s1) * t1
        let o0 = oSpan.s1 + (oSpan.s2 - oSpan.s1) * t0
        let o1 = oSpan.s1 + (oSpan.s2 - oSpan.s1) * t1
        
        segments.append(GPUSplineSegment(
            p0: SIMD2<Float>(Float(a0.x), Float(a0.y)),
            p1: SIMD2<Float>(Float(a.x),  Float(a.y)),
            p2: SIMD2<Float>(Float(b.x),  Float(b.y)),
            p3: SIMD2<Float>(Float(b3.x), Float(b3.y)),
            radius0: Float(r0), radius1: Float(r1),
            opacity0: Float(o0), opacity1: Float(o1),
            segmentType: 0,
            noiseSeed: seed
        ))
    }
}

// Apply short linear taper on last `tailSamples` samples (multiplies pressure values).
internal func applyEndTaperToResampled(_ resampled: inout [ResampledPoint], tailSamples: Int = 6, ease: Float = 2.0) {
    guard resampled.count > 2, tailSamples > 0 else { return }
    
    let taperPoint = resampled.count - 1
    let actualTail = min(tailSamples, resampled.count)
    
    for i in 0..<actualTail {
        let idx = taperPoint - i
        let t = Float(i) / Float(actualTail) // normalized [0, 1]
        let eased = 1.0 - pow(1.0 - t, ease) // ease-out: fast drop, gentle finish
        let orig = resampled[idx].pressure
        let newp = orig * eased  // Multiply float pressure directly
        resampled[idx].pressure = newp
    }
}

// MARK: - Stroke Scale and Pressure
// Map pressure -> effective radius & opacity (use in your render pipeline).
// gamma: small curve to favor mid/high pressure (e.g. 0.9..1.2)
// Optimized pressure to radius and opacity conversion
internal func pressureToRadiusOpacity(pressure: Float, pen: PenInfo, radiusScale: CGFloat, gamma: Float = 1.0) -> (CGFloat, Float) {
    // Pressure is already a normalized float value (0.0 to 1.0)
    let p = max(0.0, min(1.0, pressure))
    let pg = powf(p, gamma)
    
    // Optimized radius calculation
    let sizeMin = pen.sizeMin
    let sizeMax = pen.size
    let sizeRange = sizeMax - sizeMin
    
    
    var radius = CGFloat(sizeMin + sizeRange * pg) * radiusScale
    
    
    // Ensure minimum visible radius with optimized threshold
    let minVisibleRadius: CGFloat = max(0.5, CGFloat(sizeMin) * 0.5)
    radius = max(radius, minVisibleRadius)
    
    // Optimized opacity calculation
    let opMin = pen.opacityMin
    let opMax = pen.opacity
    let opRange = opMax - opMin
    var opacity = opMin + opRange * p /* * pg */
    
    // Apply minimum visible opacity threshold
    let minVisibleOpacity: Float = 0.02
    opacity = max(opacity, minVisibleOpacity)
    
    // Clamp final values
    opacity = max(0.0, min(1.0, opacity))
    
    // Add debug print
    //        print("[P][radius_opacity] pressure=\(pressure), radius=\(radius), opacity=\(opacity), pen.type=\(pen.type ?? -1)")
    
    return (radius, opacity)
}

extension Renderer {
    /// Shared scale computation for the stamp/CPU point paths (existing idioms for
    /// pen affine + layer/view; selection transforms contribute their widest axis).
    internal func strokeScaleParams(
        stroke: StrokeRecord,
        lb: CGAffineTransform,
        accNow: CGAffineTransform,
        destMap: CGAffineTransform
    ) -> (stepPx: CGFloat, radiusScale: CGFloat) {
        let targetStepInDevicePx: CGFloat = stroke.pen.type == 1 ? 2.0 : 1.5
        let lbScaleX = sqrt(lb.a * lb.a + lb.c * lb.c)
        let lbScaleY = sqrt(lb.b * lb.b + lb.d * lb.d)
        var avgLbScale = (lbScaleX + lbScaleY) / 2.0
        if avgLbScale <= 0.0 { avgLbScale = 1.0 }
        
        // SELECTION SCALE: widest axis (max, not averaged).
        // (zoom_2/zoom_1 equivalent for uniform m2 — swap in here if parsed instead)
        let selectionScale = maxAxisScale(accNow) * maxAxisScale(destMap)
        
        var totalScale = avgLbScale * selectionScale
        if let affine = stroke.pen.penMatrixAffine {
            let affineScale = sqrt(affine.b * affine.b + affine.d * affine.d)
            totalScale *= affineScale / scale
        }
        let stampStepPx = targetStepInDevicePx / totalScale
        
        var effectiveRadiusScale: CGFloat = stroke.penMatrixScale
        if let affine = stroke.pen.penMatrixAffine {
            let scaleX = sqrt(affine.a * affine.a + affine.c * affine.c)
            let scaleY = sqrt(affine.b * affine.b + affine.d * affine.d)
            effectiveRadiusScale = (scaleX + scaleY) / 2.0
        }
        effectiveRadiusScale *= avgLbScale * selectionScale * 0.5
        
        return (stampStepPx, effectiveRadiusScale)
    }
    
    /// Widest-axis scale of a transform — the "widest rectangle side" rule for
    /// non-uniform selection transforms: radius/pressure scale as if the transform
    /// were uniform by this factor (equals zoom_2/zoom_1 for uniform pastes).
    internal func maxAxisScale(_ t: CGAffineTransform) -> CGFloat {
        let sx = sqrt(t.a * t.a + t.c * t.c)
        let sy = sqrt(t.b * t.b + t.d * t.d)
        return max(sx, sy)
    }
    
    /// Full point transform: pen affine -> lb (Lsrc ∘ B) -> accNow -> destMap (D).
    /// Identical chain to the segment path's buildOpFromStroke + GPU D — no flips.
    internal func devicePointForStroke(
        _ p: CGPoint,
        stroke: StrokeRecord,
        lb: CGAffineTransform,
        accNow: CGAffineTransform,
        destMap: CGAffineTransform
    ) -> CGPoint {
        var pt = p
        if let affine = stroke.pen.penMatrixAffine { pt = pt.applying(affine) }
        pt = pt.applying(lb)
        pt = pt.applying(accNow)
        pt = pt.applying(destMap)
        return pt
    }
}
    // MARK: - Stamp / Segment Construction
    
internal func buildOpFromStroke(
    _ stroke: StrokeRecord,
    artToDevice: CGAffineTransform,
    flipTransform: CGAffineTransform?
) -> (segments: [GPUSplineSegment], color: SIMD4<Float>, isEraser: Bool, isMarker: Bool, meta: PasteLayerMeta?, m2Transform: CGAffineTransform?)? {
    
    guard stroke.points.count >= 1 else { return nil }
    let points = stroke.points.count == 1 ? [stroke.points[0], stroke.points[0]] : stroke.points
    
    var effectiveRadiusScale: CGFloat = stroke.penMatrixScale
    if let affine = stroke.pen.penMatrixAffine {
        let scaleX = sqrt(affine.a * affine.a + affine.c * affine.c)
        let scaleY = sqrt(affine.b * affine.b + affine.d * affine.d)
        effectiveRadiusScale = (scaleX + scaleY) / 2.0
    }
    let artToDeviceScaleX = sqrt(artToDevice.a * artToDevice.a + artToDevice.c * artToDevice.c)
    let artToDeviceScaleY = sqrt(artToDevice.b * artToDevice.b + artToDevice.d * artToDevice.d)
    let artToDeviceScale = (artToDeviceScaleX + artToDeviceScaleY) / 2.0
    effectiveRadiusScale *= artToDeviceScale * 0.5
    
    let color = SIMD4<Float>(Float(stroke.pen.color.r), Float(stroke.pen.color.g), Float(stroke.pen.color.b), 1.0)
    let flip = flipTransform ?? .identity
    
    var transformedPoints: [(p: CGPoint, pressure: Float)] = []
    for p in points {
        var pt = CGPoint(x: CGFloat(p.x), y: CGFloat(p.y))
        if let affine = stroke.pen.penMatrixAffine { pt = pt.applying(affine) }
        pt = pt.applying(artToDevice)
        pt = pt.applying(flip)
        transformedPoints.append((pt, p.p))
    }
    
    var radii: [CGFloat] = []
    var opacities: [CGFloat] = []
    for tp in transformedPoints {
        let (r, op) = pressureToRadiusOpacity(pressure: tp.pressure, pen: stroke.pen, radiusScale: effectiveRadiusScale, gamma: 1.0)
        radii.append(r)
        opacities.append(CGFloat(op))
    }
    
    var pts  = transformedPoints.map { $0.p }
    var rads = radii
    var opas = opacities
    
    let firstPt = pts[0]
    let secondPt = pts[1]
    pts.insert(CGPoint(x: 2.0 * firstPt.x - secondPt.x, y: 2.0 * firstPt.y - secondPt.y), at: 0)
    rads.insert(rads[0], at: 0)
    opas.insert(opas[0], at: 0)
    
    let lastPt = pts[pts.count - 1]
    let secondToLastPt = pts[pts.count - 2]
    pts.append(CGPoint(x: 2.0 * lastPt.x - secondToLastPt.x, y: 2.0 * lastPt.y - secondToLastPt.y))
    rads.append(rads[rads.count - 1])
    opas.append(opas[opas.count - 1])
    
    let seed = stroke.pen.type == 1 ? arc4random() + 1 : 0
    var segmentsForStroke: [GPUSplineSegment] = []
    segmentsForStroke.reserveCapacity((pts.count - 3) * 4)
    
    for i in 1..<(pts.count - 2) {
        let pSpan = CRPointSpan(p0: pts[i-1], p1: pts[i], p2: pts[i+1], p3: pts[i+2])
        let rSpan = CRScalarSpan(s0: rads[i-1], s1: rads[i], s2: rads[i+1], s3: rads[i+2])
        let oSpan = CRScalarSpan(s0: opas[i-1], s1: opas[i], s2: opas[i+1], s3: opas[i+2])
        flattenAndBuild(span: pSpan, rSpan: rSpan, oSpan: oSpan, seed: seed, depth: 0, into: &segmentsForStroke, isPolyline: stroke.isPolyline, isMarker: stroke.pen.isMarker)
    }
    
    return (segments: segmentsForStroke, color: color, isEraser: stroke.pen.isEraser, isMarker: stroke.pen.isMarker, meta: nil, m2Transform: nil)
}
    
extension Renderer {
#if canImport(Metal)
    /// Builds the stamp batch for one stroke (the pipeline of the previously disabled
    /// stamp renderer, generalized with the selection transforms).
    internal func buildStampBatch(
        stroke: StrokeRecord,
        lb: CGAffineTransform,
        accNow: CGAffineTransform,
        destMap: CGAffineTransform
    ) -> (stamps: [Stamp], color: SIMD4<Float>, isEraser: Bool, isMarker: Bool)? {
        
        guard !stroke.points.isEmpty else { return nil }
        let (stampStepPx, effectiveRadiusScale) = strokeScaleParams(stroke: stroke, lb: lb, accNow: accNow, destMap: destMap)
        
        let splinePoints = buildResampledStrokeWithSpline(
            stroke.points, stepPx: stampStepPx, samplesPerSegment: 6, gamma: 1.0, isPolyline: stroke.isPolyline)
        var resampled: [ResampledPoint] = splinePoints.map {
            ResampledPoint(x: CGFloat($0.x), y: CGFloat($0.y), p: $0.p)
        }
        guard !resampled.isEmpty else { return nil }
        applyEndTaperToResampled(&resampled, tailSamples: 4, ease: 1.8)
        
        let color = SIMD4<Float>(Float(stroke.pen.color.r), Float(stroke.pen.color.g), Float(stroke.pen.color.b), 1.0)
        
        var stamps: [Stamp] = []
        stamps.reserveCapacity(resampled.count)
        for rp in resampled {
            let pt = devicePointForStroke(CGPoint(x: rp.x, y: rp.y), stroke: stroke,
                                          lb: lb, accNow: accNow, destMap: destMap)
            let (radius, opacity) = pressureToRadiusOpacity(
                pressure: rp.pressure, pen: stroke.pen, radiusScale: effectiveRadiusScale, gamma: 1.0)
            stamps.append(Stamp(
                center: SIMD2<Float>(Float(pt.x), Float(pt.y)),
                radius: Float(radius),
                opacity: opacity,
                rotation: 0.0,
                noiseSeed: stroke.pen.type == 1 ? arc4random() + 1 : 0))
        }
        return (stamps: stamps, color: color, isEraser: stroke.pen.isEraser, isMarker: stroke.pen.isMarker)
    }
#endif
    
    // MARK: - Transform Helpers
    // Convert a 4x4 matrix to a CGAffineTransform
    internal func transformFromMatrix(_ m: [[Float]], scale: CGFloat = 1.0) -> CGAffineTransform {
        guard m.count >= 4, m[0].count >= 4 else { return .identity }
        return CGAffineTransform(
            a:  CGFloat(m[0][0]) * scale,
            b: -CGFloat(m[1][0]) * scale,
            c: -CGFloat(m[0][1]) * scale,
            d:  CGFloat(m[1][1]) * scale,
            tx: CGFloat(m[3][0]) * scale,
            ty: CGFloat(m[3][1]) * scale
        )
    }
    
    // Legacy alias so old call sites keep compiling
    internal func toDirectCGTransform(_ m: [[Float]], scale: CGFloat = 1.0) -> CGAffineTransform {
        transformFromMatrix(m, scale: scale)
    }
    
    internal func isIdentityTransform(_ t: CGAffineTransform) -> Bool {
        abs(t.a - 1) < 1e-6 && abs(t.d - 1) < 1e-6 &&
        abs(t.b) < 1e-6 && abs(t.c) < 1e-6 &&
        abs(t.tx) < 1e-6 && abs(t.ty) < 1e-6
    }
    
    internal func verticalFlipTransform(canvasHeight: CGFloat) -> CGAffineTransform {
        // Translate down by canvasHeight, then scale Y by -1 to flip vertically.
        // Equivalent to: translate(0, canvasHeight) * scale(1, -1)
#if os(Linux)
        return CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: canvasHeight)
#else
        return CGAffineTransform(translationX: 0, y: canvasHeight).scaledBy(x: 1.0, y: -1.0)
#endif
    }
}
