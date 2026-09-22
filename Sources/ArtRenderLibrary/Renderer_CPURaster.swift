import Foundation
#if os(Linux)
import Silica
import CoreFoundation
//import Cairo
//import JPEG
#elseif os(macOS)
import CoreGraphics
#endif

import ArtParser

extension Renderer {
    // MARK: - CPU Stroke Rendering
    internal func drawStrokeOnCPU(
        stroke: StrokeRecord,
        lb: CGAffineTransform,
        accNow: CGAffineTransform,
        destMap: CGAffineTransform,
        context: CGContext
    ) {
        guard !stroke.points.isEmpty else { return }
        let (stampStepPx, effectiveRadiusScale) = strokeScaleParams(stroke: stroke, lb: lb, accNow: accNow, destMap: destMap)
        
        let splinePoints = buildResampledStrokeWithSpline(
            stroke.points, stepPx: stampStepPx, samplesPerSegment: 6, gamma: 1.0, isPolyline: stroke.isPolyline)
        var resampledArt: [ResampledPoint] = splinePoints.map {
            ResampledPoint(x: CGFloat($0.x), y: CGFloat($0.y), p: $0.p)
        }
        guard !resampledArt.isEmpty else { return }
        
        applyEndTaperToResampled(&resampledArt, tailSamples: 4, ease: 1.8)
        
        var deviceResampled: [ResampledPoint] = []
        deviceResampled.reserveCapacity(resampledArt.count)
        for rp in resampledArt {
            // Device y-down coords go into the context DIRECTLY (see compositeImageCPU note).
            let pt = devicePointForStroke(CGPoint(x: rp.x, y: rp.y), stroke: stroke,
                                          lb: lb, accNow: accNow, destMap: destMap)
            deviceResampled.append(ResampledPoint(location: pt, pressure: rp.pressure))
        }
        
        renderStroke_drawDeviceResampled(
            resampledPoints: deviceResampled, pen: stroke.pen, in: context, radiusScale: effectiveRadiusScale)
    }
    
    internal func renderStroke_drawDeviceResampled(
        resampledPoints: [ResampledPoint],
        pen: PenInfo,
        in context: CGContext,
        radiusScale: CGFloat
    ) {
        //        let inputPressureRange = (resampledPoints.map { $0.pressure }.min() ?? 0, resampledPoints.map { $0.pressure }.max() ?? 0)
        //        print("[P][draw_stroke] count=\(resampledPoints.count), p.min=\(inputPressureRange.0), p.max=\(inputPressureRange.1)")
        
        guard resampledPoints.count > 0 else { return }
        
        var stamps: [Stamp] = []
        stamps.reserveCapacity(resampledPoints.count)
        for point in resampledPoints {
            let (radius, opacity) = pressureToRadiusOpacity(
                pressure: point.pressure,
                pen: pen,
                radiusScale: radiusScale,
                gamma: 1.0
            )
            
            let stamp = Stamp(
                center: SIMD2<Float>(Float(point.location.x), Float(point.location.y)),
                radius: Float(radius),
                opacity: opacity,
                rotation: 0.0,
                noiseSeed: arc4random()
            )
            stamps.append(stamp)
        }
        
        // Fallback to CPU implementation (always available)
        renderStroke_drawDeviceResampled_CPU(
            resampledPoints: resampledPoints,
            pen: pen,
            in: context,
            radiusScale: radiusScale
        )
    }
    
    internal func renderStroke_drawDeviceResampled_CPU(
        resampledPoints: [ResampledPoint],
        pen: PenInfo,
        in context: CGContext,
        radiusScale: CGFloat
    ) {
        // Performance monitoring
        let monitor = PerformanceMonitor.shared
        monitor.startTimer("stroke_rendering")
        
        // Early rejection for empty strokes
        guard resampledPoints.count > 0 else { return }
        
        // Check if we should use tile-based rendering (for texture brushes)
        let useTileRendering = pen.type == 1 // Only use tile rendering for pencil/texture brushes
        
        if useTileRendering {
            // Use existing tile-based rendering for texture brushes
            renderStrokeWithTiles(
                resampledPoints: resampledPoints,
                pen: pen,
                in: context,
                radiusScale: radiusScale
            )
        } else {
            // Use new bitmap-based rendering for non-texture brushes
            renderStrokeWithBitmapCircles(
                deviceResampled: resampledPoints,
                pen: pen,
                in: context,
                radiusScale: radiusScale
            )
        }
        
        //        monitor.endTimer("stroke_rendering")
        //        monitor.incrementCounter("strokes_rendered")
    }
    
    internal func renderStrokeWithBitmapCircles(
        deviceResampled: [ResampledPoint],
        pen: PenInfo,
        in context: CGContext,
        radiusScale: CGFloat
    ) {
        guard !deviceResampled.isEmpty else { return }
        let canvasW = context.width
        let canvasH = context.height
        
        var dirty = DirtyRect.null
        let plane = AlphaPlanePool.acquire(width: canvasW, height: canvasH)
        defer { AlphaPlanePool.recycle(plane, dirty: dirty) }
        
        let bufferPool = TileBufferPool.shared
        var tileBuf = bufferPool.getBuffer()
        defer { bufferPool.returnBuffer(tileBuf) }
        
        var visiblePoints: [(location: CGPoint, radius: CGFloat, opacity: Float)] = []
        visiblePoints.reserveCapacity(deviceResampled.count)
        
        for point in deviceResampled {
            let (radius, opacity) = pressureToRadiusOpacity(
                pressure: point.pressure, pen: pen,
                radiusScale: radiusScale, gamma: 1.1)
            if radius < 0.5 || opacity < 0.01 { continue }
            visiblePoints.append((point.location, radius, opacity))
        }
        if visiblePoints.isEmpty { return }
        
        for p in visiblePoints {
            var tileOrigin = CGPoint.zero
            let (tilePtr, tileW, tileH) = makeCircleTileInto(
                center: p.location, radius: p.radius, opacity: p.opacity,
                canvasW: canvasW, canvasH: canvasH,
                tileOrigin: &tileOrigin, buf: &tileBuf)
            
            if let tilePtr = tilePtr, tileW > 0, tileH > 0,
               let d = plane.maxBlitOptimized(tile: tilePtr, tileW: tileW, tileH: tileH,
                                              dstX: Int(tileOrigin.x), dstY: Int(tileOrigin.y)) {
                dirty.formUnion(d)
            }
        }
        guard !dirty.isEmpty, let mask = makeMaskFromAlphaPlane(plane: plane, dirty: dirty) else { return }
        
        let rect = dirty.cgRect(canvasHeight: canvasH)
        context.saveGState()
        if pen.isEraser {
            context.setBlendMode(.destinationOut)
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        } else {
            context.setBlendMode(.normal)
            context.setFillColor(red: CGFloat(pen.color.r), green: CGFloat(pen.color.g),
                                 blue: CGFloat(pen.color.b), alpha: 1)
        }
        context.clip(to: rect, mask: mask)
        context.fill(rect)
        context.restoreGState()
    }
    
    // Fallback method for tile-based rendering (texture brushes)
    internal func renderStrokeWithTiles(
        resampledPoints: [ResampledPoint],
        pen: PenInfo,
        in context: CGContext,
        radiusScale: CGFloat
    ) {
        if !isStrokeVisible(resampledPoints, pen: pen) {
            return
        }
        
        let canvasW = context.width
        let canvasH = context.height
        
        let bufferPool = TileBufferPool.shared
        
        var dirty = DirtyRect.null
        let plane = AlphaPlanePool.acquire(width: canvasW, height: canvasH)
        defer { AlphaPlanePool.recycle(plane, dirty: dirty) }
        
        var circleTileBuf = bufferPool.getBuffer()
        defer { bufferPool.returnBuffer(circleTileBuf) }
        
        // disable-noise
        //    var noiseTileBuf = bufferPool.getBuffer()
        //    defer { bufferPool.returnBuffer(noiseTileBuf) }
        
        var visiblePoints: [(index: Int, radius: CGFloat, opacity: Float)] = []
        visiblePoints.reserveCapacity(resampledPoints.count)
        
        for i in 0..<resampledPoints.count {
            let pressure = max(0, resampledPoints[i].pressure)
            let (r, a) = pressureToRadiusOpacity(pressure: pressure, pen: pen, radiusScale: radiusScale, gamma: 1.0)
            if r < 0.5 || a < 0.01 { continue }
            visiblePoints.append((i, r, a))
        }
        if visiblePoints.isEmpty { return }
        
        let isPencilType1 = pen.type == 1
        
        for (index, r, a) in visiblePoints {
            let p = resampledPoints[index].location
            
            var tileOrigin = CGPoint.zero
            var tileBufPtr: UnsafeMutablePointer<UInt8>?
            var tileW: Int = 0
            var tileH: Int = 0
            
            if isPencilType1 {
                var circleOrigin = CGPoint.zero
                let (circleBuf, circleW, circleH) = makeFalloffCircleTileInto(
                    center: p, radius: r, opacity: a,
                    canvasW: canvasW, canvasH: canvasH,
                    tileOrigin: &circleOrigin, buf: &circleTileBuf)
                
                if let circleBuf = circleBuf {
                    // disable-noise (kept for re-enabling later)
                    //                var seed: UInt64 = 0
                    //                var rotation: CGFloat = 0
                    //                var offset: CGPoint = .zero
                    //                seed = UInt64(abs(p.x.hashValue ^ p.y.hashValue ^ index.hashValue ^ Int.random(in: 0..<Int.max)))
                    //                rotation = (Double(seed % 360) / 180.0) * Double.pi
                    //                offset = CGPoint(
                    //                    x: CGFloat(seed >> 16).truncatingRemainder(dividingBy: noiseImageSize.width),
                    //                    y: CGFloat(seed >> 32).truncatingRemainder(dividingBy: noiseImageSize.height)
                    //                )
                    //                var noiseOrigin = CGPoint.zero
                    //                let (noiseBuf, noiseW, noiseH) = makeNoiseTileInto(
                    //                    center: p, radius: r, rotation: rotation, offset: offset,
                    //                    canvasW: canvasW, canvasH: canvasH,
                    //                    tileOrigin: &noiseOrigin, buf: &noiseTileBuf)
                    //
                    //                if let noiseBuf = noiseBuf, circleW == noiseW, circleH == noiseH {
                    //                    let combinedBuf = UnsafeMutablePointer<UInt8>.allocate(capacity: circleW * circleH)
                    //                    defer { combinedBuf.deallocate() }
                    //                    multiplyAlphaTiles(circlePtr: circleBuf, noisePtr: noiseBuf,
                    //                                       outPtr: combinedBuf, w: circleW, h: circleH)
                    //                    tileBufPtr = combinedBuf; tileW = circleW; tileH = circleH; tileOrigin = circleOrigin
                    //                } else {
                    tileBufPtr = circleBuf
                    tileW = circleW
                    tileH = circleH
                    tileOrigin = circleOrigin
                    //                }
                }
            } else {
                let (circleBuf, circleW, circleH) = makeCircleTileInto(
                    center: p, radius: r, opacity: a,
                    canvasW: canvasW, canvasH: canvasH,
                    tileOrigin: &tileOrigin, buf: &circleTileBuf)
                tileBufPtr = circleBuf
                tileW = circleW
                tileH = circleH
            }
            
            if let tileBuf = tileBufPtr, tileW > 0, tileH > 0,
               let d = plane.maxBlitOptimized(tile: tileBuf, tileW: tileW, tileH: tileH,
                                              dstX: Int(tileOrigin.x), dstY: Int(tileOrigin.y)) {
                dirty.formUnion(d)
            }
        }
        guard !dirty.isEmpty, let mask = makeMaskFromAlphaPlane(plane: plane, dirty: dirty) else { return }
        
        let rect = dirty.cgRect(canvasHeight: canvasH)
        context.saveGState()
        if pen.isEraser {
            context.setBlendMode(.destinationOut)
            context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        } else {
            context.setBlendMode(.normal)
            context.setFillColor(red: CGFloat(pen.color.r), green: CGFloat(pen.color.g),
                                 blue: CGFloat(pen.color.b), alpha: 1)
        }
        context.clip(to: rect, mask: mask)
        context.fill(rect)
        context.restoreGState()
    }
    
    // MARK: - Tile Generation
    // Build a circle tile into a reusable buffer. Returns (buf,w,h) and sets tileOrigin.
    internal func makeCircleTileInto(
        center: CGPoint,
        radius: CGFloat,
        opacity: Float,
        canvasW: Int,
        canvasH: Int,
        tileOrigin: inout CGPoint,
        buf: inout TileBuffer
    ) -> (UnsafeMutablePointer<UInt8>?, Int, Int) {
        let pad: CGFloat = 2
        let minX = floor(center.x - radius - pad)
        let minY = floor(center.y - radius - pad)
        let maxX = ceil(center.x + radius + pad)
        let maxY = ceil(center.y + radius + pad)
        let w = max(1, Int(maxX - minX))
        let h = max(1, Int(maxY - minY))
        
        // Skip if fully off-canvas
        if Int(maxX) <= 0 || Int(maxY) <= 0 || Int(minX) >= canvasW || Int(minY) >= canvasH {
            return (nil, 0, 0)
        }
        
        // Safety cap (defensive)
        if w > 8192 || h > 8192 { return (nil, 0, 0) }
        
        buf.ensureCapacity(w * h)
        buf.zero(count: w * h)
        tileOrigin = CGPoint(x: minX, y: minY)
        
        let cx = Float(center.x - minX)
        let cy = Float(center.y - minY)
        let r = Float(radius)
        let alpha = UInt8(max(0, min(1, opacity)) * 255)
        
        guard let out = buf.ptr else { return (nil, 0, 0) }
        
        // Pre-calculate constants
        let innerRadius = r - 0.75
        let outerRadius = r + 0.75
        let radiusRange = outerRadius - innerRadius
        
        for j in 0..<h {
            let y = Float(j) + 0.5
            let dy = y - cy
            let dySquared = dy * dy
            
            let row = out.advanced(by: j * w)
            
            // Process pixels in this row
            for i in 0..<w {
                let x = Float(i) + 0.5
                let dx = x - cx
                let dxSquared = dx * dx
                
                // Calculate distance
                let distanceSquared = dxSquared + dySquared
                let distance = sqrtf(distanceSquared)
                
                // Calculate coverage using pre-calculated values
                var coverage: Float
                
                if distance <= innerRadius {
                    coverage = 1.0
                } else if distance >= outerRadius {
                    coverage = 0.0
                } else {
                    // Smoothstep for anti-aliasing
                    let t = (distance - innerRadius) / radiusRange
                    let tSquared = t * t
                    coverage = 1.0 - tSquared * (3.0 - 2.0 * t)
                }
                
                let v = UInt8(min(255, Int(Float(alpha) * coverage + 0.5)))
                if v > row[i] { row[i] = v }
            }
        }
        
        return (buf.ptr, w, h)
    }
    
    internal func makeFalloffCircleTileInto(
        center: CGPoint,
        radius: CGFloat,
        opacity: Float,
        canvasW: Int,
        canvasH: Int,
        tileOrigin: inout CGPoint,
        buf: inout TileBuffer
    ) -> (UnsafeMutablePointer<UInt8>?, Int, Int) {
        guard radius > 0, radius.isFinite, center.x.isFinite, center.y.isFinite, opacity.isFinite else {
            return (nil, 0, 0)
        }
        
        let pad: CGFloat = 2
        let minX = max(0, (center.x - radius - pad).rounded(.down))
        let minY = max(0, (center.y - radius - pad).rounded(.down))
        let maxX = min(CGFloat(canvasW), (center.x + radius + pad).rounded(.up))
        let maxY = min(CGFloat(canvasH), (center.y + radius + pad).rounded(.up))
        
        let w = Int(maxX - minX)
        let h = Int(maxY - minY)
        guard w > 0, h > 0 else { return (nil, 0, 0) }
        if w > 8192 || h > 8192 { return (nil, 0, 0) }
        
        buf.ensureCapacity(w * h)
        buf.zero(count: w * h)
        tileOrigin = CGPoint(x: minX, y: minY)
        guard let out = buf.ptr else { return (nil, 0, 0) }
        
        let alpha = UInt8(max(0, min(1, opacity)) * 255)
        if alpha == 0 { return (nil, 0, 0) }   // tile would be all zeros; skipping the blit is equivalent
        
        let r  = Float(radius)
        let cx = Float(center.x - minX)
        let cy = Float(center.y - minY)
        
        // Per pixel: bin = d² · n / r²  →  coverage  →  alpha. No per-stamp LUT, no allocation.
        let curve   = Self.falloffCurve.bins            // raw pointer: no bounds checks in the loop
        let n       = Self.falloffLutSize
        let d2ToBin = Float(n) / (r * r)
        let zeroD2  = Self.falloffCurve.zeroNd2 * r * r
        let alphaF  = Float(alpha)
        
        for j in 0..<h {
            let dy  = (Float(j) + 0.5) - cy
            let dy2 = dy * dy
            if dy2 >= zeroD2 { continue }               // row misses the circle entirely
            
            let halfSpan = (zeroD2 - dy2).squareRoot()
            var i0 = Int((cx - halfSpan - 0.5).rounded(.up))
            let i1 = min(w - 1, Int((cx + halfSpan - 0.5).rounded(.down)))
            if i0 < 0 { i0 = 0 }
            if i0 > i1 { continue }
            
            let row = out.advanced(by: j * w)
            var dx = (Float(i0) + 0.5) - cx
            var i = i0
            while i <= i1 {
                let cov = curve[Int((dx * dx + dy2) * d2ToBin)]
                let v   = alphaF * cov + 0.5
                row[i] = v >= 255 ? 255 : UInt8(v)      // v ≤ 255.5, so UInt8(v) never traps
                dx += 1.0
                i += 1
            }
        }
        
        return (buf.ptr, w, h)
    }
    
    // TODO: Composit noise per stroke instead. Per dab is too slow on cpu.
    private func multiplyAlphaTiles(circlePtr: UnsafePointer<UInt8>, noisePtr: UnsafePointer<UInt8>,
                                    outPtr: UnsafeMutablePointer<UInt8>, w: Int, h: Int) {
        //        print("[P][multiply_tiles] w=\(w), h=\(h)")
        //        print("DEBUG: multiplyAlphaTiles - multiplying \(w)x\(h) tiles")
        
        var nonZeroCount = 0
        var maxResult: UInt8 = 0
        var maskedCount = 0
        var circleZeroCount = 0
        
        // Debug: Check first few values in each tile
        //        print("DEBUG: First 5 circle values: \(circlePtr[0]), \(circlePtr[1]), \(circlePtr[2]), \(circlePtr[3]), \(circlePtr[4])")
        //        print("DEBUG: First 5 noise values: \(noisePtr[0]), \(noisePtr[1]), \(noisePtr[2]), \(noisePtr[3]), \(noisePtr[4])")
        
        for i in 0..<(w*h) {
            let ca = Int(circlePtr[i])  // Circle alpha (shape with falloff)
            let ng = Int(noisePtr[i])   // Noise grayscale (texture)
            
            var v: UInt8
            
            if ca == 0 {
                // If circle alpha is 0, result should be 0 (completely transparent)
                v = 0
                maskedCount += 1
                circleZeroCount += 1
            } else {
                // Normalize values to [0, 1] range
                let dab = Float(ca) / 255.0
                let tex = Float(ng) / 255.0
                
                // MSL logic
                let inverted:Float = 1.0 - dab
                let noiseAdd:Float = (dab * 0.94) + tex
                let result:Float = 1.0 - max(0.0, min(1.0, (inverted / noiseAdd)))
                
                // Convert back to [0, 255] range
                v = UInt8(result * 255.0 + 0.5)
            }
            
            outPtr[i] = v
            if v > 0 { nonZeroCount += 1 }
            if v > maxResult { maxResult = v }
        }
        
        print("DEBUG: multiplyAlphaTiles - nonZeroCount: \(nonZeroCount), maxResult: \(maxResult), maskedCount: \(maskedCount), circleZeroCount: \(circleZeroCount)")
    }
    
    internal static let falloffLutSize = 4096
    
    /// bins[i] = coverage at d/r = sqrt((i + 0.5) / n)
    /// zeroNd2 = (d/r)² beyond which coverage == 0 (lets the span loop skip work)
    internal static let falloffCurve: (bins: UnsafeMutablePointer<Float>, zeroNd2: Float) = {
        let n = falloffLutSize
        let p = UnsafeMutablePointer<Float>.allocate(capacity: n + 1)
        var lastNonZero = 0
        for i in 0...n {
            let nd = ((Float(i) + 0.5) / Float(n)).squareRoot()
            
            // === original curve, evaluated n+1 times total ===
            var coverage: Float
            if nd <= 0.2 {
                coverage = 1.0
            } else if nd >= 1.0 {
                coverage = 0.0
            } else {
                let t = (nd - 0.2) / 0.8
                let sCurve = t * t * (2.8 - 1.4 * t)
                let c = 1.0 - powf(sCurve, 0.7)
                coverage = c > 0 ? c : 0
            }
            // =================================================
            
            p[i] = coverage
            if coverage > 0 { lastNonZero = i }
        }
        return (p, (Float(lastNonZero) + 1) / Float(n))
    }()
    
    
    // MARK: - Alpha Plane to Image
    internal func makeMaskFromAlphaPlane(plane: AlphaPlane, dirty: DirtyRect) -> CGImage? {
        guard !dirty.isEmpty else { return nil }
        let x0 = max(0, dirty.x0), y0 = max(0, dirty.y0)
        let x1 = min(plane.width, dirty.x1), y1 = min(plane.height, dirty.y1)
        let w = x1 - x0, h = y1 - y0
        guard w > 0, h > 0 else { return nil }
        
        let bpr = plane.bytesPerRow
        let byteCount = w * h
        
#if os(Linux)
        var packed = Data(count: byteCount)
        packed.withUnsafeMutableBytes { raw in
            guard var dst = raw.baseAddress else { return }
            var src = UnsafeRawPointer(plane.data) + y0 * bpr + x0
            for _ in 0..<h {
                memcpy(dst, src, w)
                dst = dst.advanced(by: w)
                src = src.advanced(by: bpr)
            }
        }
        return CGImage(alphaData: packed, width: w, height: h, bytesPerRow: w)
#else
        guard let buf = malloc(byteCount)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        var dst = buf
        var src = UnsafeRawPointer(plane.data) + y0 * bpr + x0
        for _ in 0..<h {
            memcpy(dst, src, w)
            dst = dst.advanced(by: w)
            src = src.advanced(by: bpr)
        }
        guard let cfData = CFDataCreateWithBytesNoCopy(nil, buf, byteCount, kCFAllocatorMalloc) else {
            free(buf)
            return nil
        }
        guard let provider = CGDataProvider(data: cfData) else { return nil }
        return CGImage(width: w, height: h,
                       bitsPerComponent: 8,
                       bitsPerPixel: 8,
                       bytesPerRow: w,
                       space: Self.maskColorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: provider,
                       decode: nil,
                       shouldInterpolate: true,
                       intent: .defaultIntent)
#endif
    }
    
    // MARK: - Paste and Mask Compositing
    /// Composites a layer-space CGImage into a (y-up) layer context with a RAW draw
    /// (pixel-exact copy; the y-down main context's raw draw fixes final orientation).
    /// `offsetPx`: top-left pixel-space rect the image was cropped from; the image is
    /// drawn at the position it occupied in the full canvas. nil = full-canvas draw.
    internal func compositeImageCPU(image: CGImage, erase: Bool = false, alpha: CGFloat = 1.0,
                                    into context: CGContext, offsetPx: CGRect? = nil) {
        context.saveGState()
        defer { context.restoreGState() }
        if erase { context.setBlendMode(.destinationOut) }
        if alpha < 1.0 { context.setAlpha(alpha) }
        guard let c = offsetPx else {
            context.draw(image, in: CGRect(x: 0, y: 0,
                                           width: context.width,
                                           height: context.height))
            return
        }
        guard !c.isEmpty else { return } // cropped region was empty; draw nothing
        context.draw(image, in: CGRect(x: c.minX,
                                       y: CGFloat(context.height) - c.maxY,
                                       width: c.width,
                                       height: c.height))
    }
    
    /// Intersection of keep-quad bboxes, converted to top-left pixel rect, 1px pad.
    /// nil = no valid keeps (full canvas), .zero = empty intersection (nothing visible).
    internal func keepCropPx(keeps: [(inv: CGAffineTransform, rect: [Float])],
                             destMap: CGAffineTransform, pxW: Int, pxH: Int) -> CGRect? {
        var b = CGRect.null
        for k in keeps {
            guard let c = maskRectDeviceCorners(maskInv: k.inv, rect: k.rect, destMap: destMap) else { continue }
            b = b.isNull ? quadBBox(c) : b.intersection(quadBBox(c))
        }
        if b.isNull { return nil }
        guard !b.isEmpty else { return .zero }
        let x0 = max(0, floor(b.minX) - 1)
        let x1 = min(CGFloat(pxW), ceil(b.maxX) + 1)
        let y0 = max(0, CGFloat(pxH) - ceil(b.maxY) - 1)
        let y1 = min(CGFloat(pxH), CGFloat(pxH) - floor(b.minY) + 1)
        return CGRect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
    }
    
    // MARK: - Pixel Mask Operations
    /// keep-masks: clear everything outside the intersection of all quads (one full-canvas sweep).
    internal func clearKeepMasksCPU(_ ctx: CGContext,
                                    keeps: [(inv: CGAffineTransform, rect: [Float])],
                                    destMap: CGAffineTransform,
                                    boundsPx: CGRect? = nil) {
        guard ctx.bitsPerPixel == 32, let base = ctx.data else { return }
        let quads = keeps.compactMap { maskRectDeviceCorners(maskInv: $0.inv, rect: $0.rect, destMap: destMap) }
        guard !quads.isEmpty else { return }
        let w = ctx.width, h = ctx.height, bpr = ctx.bytesPerRow
        // boundsPx is top-left pixel space == buffer row/col space (no y flip here).
        let rowLo = boundsPx.map { max(0, Int($0.minY.rounded(.down))) } ?? 0
        let rowHi = boundsPx.map { min(h, Int($0.maxY.rounded(.up))) } ?? h
        let colLo = boundsPx.map { max(0, Int($0.minX.rounded(.down))) } ?? 0
        let colHiEx = boundsPx.map { min(w, Int($0.maxX.rounded(.up))) } ?? w
        guard rowLo < rowHi, colLo < colHiEx else { return }
        var covs: [(xL: CGFloat, xR: CGFloat, v: CGFloat)] = []
        // ^ declare once: var covs: [...] = []; covs.reserveCapacity(quads.count)
        for y in rowLo..<rowHi {
            let yc = CGFloat(h - 1 - y) + 0.5
            covs.removeAll(keepingCapacity: true)
            var rowDead = false
            for q in quads {
                guard let cv = quadRowCoverageAA(q, yc: yc) else { rowDead = true; break }
                covs.append(cv)
            }
            let row = base.advanced(by: y * bpr)
            if rowDead {
                memset(row.advanced(by: colLo * 4), 0, (colHiEx - colLo) * 4)
                continue
            }
            var iLo = covs[0].xL, iHi = covs[0].xR, rowKeep = covs[0].v
            for cv in covs.dropFirst() {
                iLo = max(iLo, cv.xL); iHi = min(iHi, cv.xR); rowKeep *= cv.v
            }
            guard iHi > iLo, rowKeep > 0 else {
                memset(row.advanced(by: colLo * 4), 0, (colHiEx - colLo) * 4)
                continue
            }
            let runLo = max(colLo, Int((iLo - 0.5).rounded(.up)))
            let runHi = min(colHiEx - 1, Int((iHi + 0.5).rounded(.down)))
            let fullLo = max(runLo, Int((iLo + 0.5).rounded(.up)))   // first fully-kept px
            let fullHi = min(runHi, Int((iHi - 0.5).rounded(.down))) // last fully-kept px
            if runLo > colLo { memset(row.advanced(by: colLo * 4), 0, (runLo - colLo) * 4) }
            if runHi < colHiEx - 1 { memset(row.advanced(by: (runHi + 1) * 4), 0, (colHiEx - runHi - 1) * 4) }
            let leftEnd = min(fullLo, runHi + 1)                     // exclusive
            for px in runLo..<leftEnd {
                var keep = rowKeep
                for cv in covs { keep *= horizCoverage(cv.xL, cv.xR, px) }
                scaleRunCPU(row, px, px + 1, keep)
            }
            if fullLo <= fullHi {
                scaleRunCPU(row, fullLo, fullHi + 1, rowKeep)        // no-op when rowKeep == 1
            }
            let rightStart = max(fullHi + 1, leftEnd)
            if rightStart <= runHi {
                for px in rightStart...runHi {
                    var keep = rowKeep
                    for cv in covs { keep *= horizCoverage(cv.xL, cv.xR, px) }
                    scaleRunCPU(row, px, px + 1, keep)
                }
            }
        }
    }
    
    /// erase-masks: clear inside the quad only.
    internal func eraseQuadPixelsCPU(_ ctx: CGContext, maskInv: CGAffineTransform,
                                     rect: [Float], destMap: CGAffineTransform) {
        guard ctx.bitsPerPixel == 32, let base = ctx.data,
              let c = maskRectDeviceCorners(maskInv: maskInv, rect: rect, destMap: destMap) else { return }
        let w = ctx.width, h = ctx.height, bpr = ctx.bytesPerRow
        let yMinV = c.map { $0.y }.min()!, yMaxV = c.map { $0.y }.max()!
        // value-space [yMinV, yMaxV] → buffer rows [h - ceil(yMaxV), h - 1 - floor(yMinV)]
        let y0 = max(0, h - Int(yMaxV.rounded(.up)))
        let y1 = min(h - 1, h - 1 - Int(yMinV.rounded(.down)))
        guard y0 <= y1 else { return }
        for y in y0...y1 {
            let yc = CGFloat(h - 1 - y) + 0.5
            guard let cv = quadRowCoverageAA(c, yc: yc) else { continue }
            let runLo = max(0, Int((cv.xL - 0.5).rounded(.up)))
            let runHi = min(w - 1, Int((cv.xR + 0.5).rounded(.down)))
            guard runLo <= runHi else { continue }
            let fullLo = max(runLo, Int((cv.xL + 0.5).rounded(.up)))
            let fullHi = min(runHi, Int((cv.xR - 0.5).rounded(.down)))
            let row = base.advanced(by: y * bpr)
            let leftEnd = min(fullLo, runHi + 1)
            for px in runLo..<leftEnd {
                scaleRunCPU(row, px, px + 1, 1 - cv.v * horizCoverage(cv.xL, cv.xR, px))
            }
            if fullLo <= fullHi {
                scaleRunCPU(row, fullLo, fullHi + 1, 1 - cv.v)       // memset when v == 1
            }
            let rightStart = max(fullHi + 1, leftEnd)
            if rightStart <= runHi {
                for px in rightStart...runHi {
                    scaleRunCPU(row, px, px + 1, 1 - cv.v * horizCoverage(cv.xL, cv.xR, px))
                }
            }
        }
    }
    
    internal func quadBBox(_ c: [CGPoint]) -> CGRect {
        var r = CGRect(origin: c[0], size: .zero)
        for p in c.dropFirst() { r = r.union(CGRect(origin: p, size: .zero)) }
        return r
    }
    
    /// AA row coverage of a convex quad (device/value space, y-down values).
    /// nil = quad doesn't cover this row at all.
    ///   xL/xR: subpixel covered interval; pixel px has horizontal coverage
    ///          clamp(min(px+0.5, xR) - max(px-0.5, xL), 0, 1)
    ///   v:     vertical fraction of the row band inside the quad
    internal func quadRowCoverageAA(_ c: [CGPoint], yc: CGFloat)
    -> (xL: CGFloat, xR: CGFloat, v: CGFloat)? {
        var xL = CGFloat.greatestFiniteMagnitude, xR = -xL
        for i in 0..<4 {
            let a = c[i], b = c[(i + 1) & 3]
            if (a.y <= yc) != (b.y <= yc) {
                let x = a.x + (yc - a.y) / (b.y - a.y) * (b.x - a.x)
                xL = min(xL, x); xR = max(xR, x)
            }
        }
        guard xR > xL else { return nil }
        let xm = (xL + xR) * 0.5
        var yT = CGFloat.greatestFiniteMagnitude, yB = -yT
        var hits = 0
        for i in 0..<4 {
            let a = c[i], b = c[(i + 1) & 3]
            if (a.x <= xm) != (b.x <= xm) {
                let yv = a.y + (xm - a.x) / (b.x - a.x) * (b.y - a.y)
                yT = min(yT, yv); yB = max(yB, yv); hits += 1
            }
        }
        guard hits >= 2 else { return nil }
        let v = max(0, min(1, min(yc + 0.5, yB) - max(yc - 0.5, yT)))
        return v > 0 ? (xL, xR, v) : nil
    }
    
    @inline(__always)
    internal func horizCoverage(_ xL: CGFloat, _ xR: CGFloat, _ px: Int) -> CGFloat {
        max(0, min(CGFloat(px) + 0.5, xR) - max(CGFloat(px) - 0.5, xL))
    }
    
    /// Scales a premultiplied pixel run by f (0 → memset, 1 → no-op).
    @inline(__always)
    internal func scaleRunCPU(_ row: UnsafeMutableRawPointer, _ px0: Int, _ px1Ex: Int, _ f: CGFloat) {
        guard px1Ex > px0 else { return }
        if f <= 0 {
            memset(row.advanced(by: px0 * 4), 0, (px1Ex - px0) * 4)
            return
        }
        let k = UInt8(max(0, min(255, (f * 255).rounded())))
        guard k < 255 else { return }
        let p = row.advanced(by: px0 * 4).assumingMemoryBound(to: UInt8.self)
        for i in 0..<(px1Ex - px0) * 4 {
            p[i] = UInt8((UInt16(p[i]) * UInt16(k) + 127) / 255)
        }
    }
    
    // MARK: - Cut Application
    internal func applyCutRectCPU(context: CGContext, action: [String: Any], art: ArtParser,
                                  actionIndex: Int, baseTransform: CGAffineTransform) {
        guard let corners = cutRectDeviceCorners(action: action, art: art,
                                                 actionIndex: actionIndex, baseTransform: baseTransform) else { return }
        context.saveGState()
        context.setBlendMode(.clear)
        context.beginPath()
        context.addLines(between: corners)
        context.closePath()
        context.fillPath()
        context.restoreGState()
    }
}
