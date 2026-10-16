#include <metal_stdlib>
#include "commonStructs.h"
using namespace metal;

// Uncomment to see individual segments colored randomly
// #define DEBUG_SEGMENT_COLORS
// #define DEBUG_CUT_PASTE

// Updated to 64 bytes to hold the 4 Catmull-Rom control points
struct GPUSplineSegment {
    float2 p0;          // CR Control Point 0 (Prev tangent)
    float2 p1;          // CR Control Point 1 (Segment start)
    float2 p2;          // CR Control Point 2 (Segment end)
    float2 p3;          // CR Control Point 3 (Next tangent)
    float  radius0;
    float  radius1;
    float  opacity0;
    float  opacity1;
    uint   noiseSeed;
    uint   segmentType; // 0 = Straight, 1 = Shape-1 (Long Bend), 2 = Shape-2 (Short Bend/Dot)
    uint   padding1;
    uint   padding2;
};

inline float smootherstep(float edge0, float edge1, float x) {
    float t = clamp((x - edge0) / (edge1 - edge0), 0.0f, 1.0f);
    return t * t * t * (t * (6.0f * t - 15.0f) + 10.0f);
}

struct SDFResult {
    float dist;
    float t;
};

// MARK: - Rectangle SDF (axis-aligned, used for cut + paste mask)

//inline float sdAxisAlignedRect(float2 p, float2 center, float2 halfExtents) {
//    float2 d = abs(p - center) - halfExtents;
//    return length(max(d, float2(0.0))) + min(max(d.x, d.y), 0.0);
//}

// New SDF function for a rotated/skewed box
float sdOrientedBox(float2 p, float4 center, float4 axisX, float4 axisY) {
    float2 d = p - center.xy;
    float lenX = length(axisX.xy);
    float lenY = length(axisY.xy);
    
    if (lenX < 0.0001f || lenY < 0.0001f) return 1e6f;
    
    float2 normX = axisX.xy / lenX;
    float2 normY = axisY.xy / lenY;
    
    // Project point onto local axes
    float lx = dot(d, normX);
    float ly = dot(d, normY);
    
    // Subtract half-extents
    float2 q = abs(float2(lx, ly)) - float2(lenX, lenY);
    return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
}

static inline float2 applyRow(float4 r0, float4 r1, float2 p) {
    return float2(r0.x*p.x + r0.y*p.y + r0.z,
                  r1.x*p.x + r1.y*p.y + r1.z);
}
static inline float rectMask(float2 p, float4 rect, float edgeWidth) {
    float2 minP = rect.xy, maxP = rect.xy + rect.zw;
    float2 d  = max(max(minP - p, p - maxP), 0.0f);
    float outS = length(d);
    float inS  = min(min(p.x - minP.x, maxP.x - p.x),
                     min(p.y - minP.y, maxP.y - p.y));
    return 1.0f - smootherstep(-edgeWidth, edgeWidth, outS - inS);
}


// Uneven Capsule shape by Inigo Quilez, MIT Lincesed
// https://www.shadertoy.com/view/4lcBWn
// https://iquilezles.org/articles/distfunctions2d/
// MARK: - Shape 0: Uneven Capsule

inline SDFResult sdUnevenCapsule(float2 pos, float2 pa, float2 pb, float ra, float rb) {
    float2 ab = pb - pa;
    float2 ap = pos - pa;
    float h = fast::length(ab);
    
    if (h < 1e-4f) {
        SDFResult res;
        res.dist = length(ap) - max(ra, rb);
        res.t = 0.0f;
        return res;
    }
    
    float2 d = ab / h;
    float parallel = dot(ap, d);
    float perpendicular = ap.x * -d.y + ap.y * d.x;
    
    float2 p = float2(abs(perpendicular), parallel);
    
    float b = (ra - rb) / h;
    
    // CRITICAL FIX: If one circle engulfs the other, return the larger circle.
    // This prevents NaN/Inf SDF values that cause tile glitches.
    if (abs(b) >= 1.0f) {
        SDFResult res;
        if (ra > rb) {
            res.dist = length(p) - ra;
            res.t = 0.0f;
        } else {
            res.dist = length(p - float2(0.0, h)) - rb;
            res.t = 1.0f;
        }
        return res;
    }
    
    float a = sqrt(1.0f - b * b);
    float k = dot(p, float2(-b, a));
    
    SDFResult res;
    if (k < 0.0f) {
        res.dist = length(p) - ra;
        res.t = 0.0f;
    } else if (k > a * h) {
        res.dist = length(p - float2(0.0, h)) - rb;
        res.t = 1.0f;
    } else {
        res.dist = dot(p, float2(a, b)) - ra;
        res.t = parallel / h;
    }
    res.t = clamp(res.t, 0.0f, 1.0f);
    return res;
}

// MARK: - Catmull-Rom Math

inline float2 getSplinePos(float2 p0, float2 p1, float2 p2, float2 p3, float t) {
    float t2 = t * t, t3 = t2 * t;
    return 0.5f * ((2.0f * p1) + (-p0 + p2) * t + (2.0f * p0 - 5.0f * p1 + 4.0f * p2 - p3) * t2 + (-p0 + 3.0f * p1 - 3.0f * p2 + p3) * t3);
}

inline float2 getSplineTangent(float2 p0, float2 p1, float2 p2, float2 p3, float t) {
    float t2 = t * t;
    return 0.5f * ((-p0 + p2) + 2.0f * (2.0f * p0 - 5.0f * p1 + 4.0f * p2 - p3) * t + 3.0f * (-p0 + 3.0f * p1 - 3.0f * p2 + p3) * t2);
}

// MARK: - Shape 1: Analytical Adaptive Spline
inline SDFResult sdSplineSegment(float2 p, float2 p0, float2 p1, float2 p2, float2 p3, float ra, float rb) {
    float best_t = 0.0f, min_dist_sq = 1e20f;
    const int PRE_SAMPLES = 6; // Reduced from 10 to 6 for performance
    
    
    for (int i = 0; i <= PRE_SAMPLES; i++) {
        float t_sample = float(i) / float(PRE_SAMPLES);
        float2 p_curve = getSplinePos(p0, p1, p2, p3, t_sample);
        float2 diff = p - p_curve;
        float d_sq = dot(diff, diff);
        if (d_sq < min_dist_sq) { min_dist_sq = d_sq; best_t = t_sample; }
    }
    
    float t = best_t;
    for (int i = 0; i < 2; i++) { // Reduced from 3 to 2
        float2 p_curve = getSplinePos(p0, p1, p2, p3, t);
        float2 tangent = getSplineTangent(p0, p1, p2, p3, t);
        float2 diff = p - p_curve;
        float t_len_sq = dot(tangent, tangent);
        t = clamp(t + (dot(diff, tangent) / (t_len_sq + 1e-5f)), 0.0f, 1.0f);
    }
    
    float2 p_curve = getSplinePos(p0, p1, p2, p3, t);
//    float current_radius = mix(ra, rb, smoothstep(0.0f, 1.0f, t));
    float current_radius = mix(ra, rb, t);
    
    float dist = fast::length(p - p_curve) - current_radius;
    
    SDFResult res;
    res.dist = dist;
    res.t = t;
    return res;
}


// MARK: - Shape 2: Soft Envelope Blended Spline
inline SDFResult sdSoftEnvelopeSpline(float2 p, float2 p0, float2 p1, float2 p2, float2 p3, float ra, float rb) {
    float strokeSDF = 1e20f;
    float best_t = 0.0f;
    const int SAMPLES = 9;
    
    for (int i = 0; i <= SAMPLES; i++) {
        float t = float(i) / float(SAMPLES);
        float2 p_curve = getSplinePos(p0, p1, p2, p3, t);
        
        // Exact mathematical radius, matching Shape 0 and Shape 1
        float radius = mix(ra, rb, t);
        float d_sample = fast::length(p - p_curve) - radius;
        
        // Simple minimum is perfectly continuous across segments and has no bulge
        if (d_sample < strokeSDF) {
            strokeSDF = d_sample;
            best_t = t;
        }
    }
    
    SDFResult res;
    res.dist = strokeSDF;
    res.t = best_t;
    return res;
}

// MARK: - Shape 3: Slanted Marker (chisel-tip, 4:1 length:diameter, 45° fixed)

// Even capsule SDF (Inigo Quilez)
inline float sdEvenCapsule(float2 pos, float2 pa, float2 pb, float r) {
    float2 ba = pb - pa;
    float2 pa2p = pos - pa;
    float h = clamp(dot(pa2p, ba) / max(dot(ba, ba), 1e-7f), 0.0f, 1.0f);
    return length(pa2p - ba * h) - r;
}

// Single slanted capsule stamp at a center point.
// Axis is fixed at 45° bottom-left → upper-right in screen coords (y-down).
//   axis = (1, -1) / √2
// Capsule length = 4 × diameter = 8r; half-length = 4r.
inline float sdSlantedMarkerStamp(float2 p, float2 center, float r) {
    constexpr float2 axis = float2(-0.70710678f, -0.70710678f);
    float halfLen = 3.0f * r;            // length = 6r from center = 4 × diameter
    float2 pa = center - axis * halfLen;
    float2 pb = center + axis * halfLen;
    return sdEvenCapsule(p, pa, pb, r);
}

// Marker sweep along a straight segment (segmentType == 0)
inline SDFResult sdSlantedMarkerStraight(float2 p, float2 a, float2 b,
                                         float ra, float rb) {
    const int SAMPLES = 10;
    float best_t = 0.0f;
    float min_dist = 1e20f;
    
    for (int i = 0; i <= SAMPLES; ++i) {
        float t_sample = float(i) / float(SAMPLES);
        float2 center = mix(a, b, t_sample);
        float r = mix(ra, rb, t_sample);
        float d = sdSlantedMarkerStamp(p, center, r);
        if (d < min_dist) { min_dist = d; best_t = t_sample; }
    }
    
    SDFResult res;
    res.dist = min_dist;
    res.t = best_t;
    return res;
}

// Marker sweep along a Catmull-Rom spline (segmentType == 1 or 2)
inline SDFResult sdSlantedMarkerSpline(float2 p, float2 p0, float2 p1,
                                       float2 p2, float2 p3,
                                       float ra, float rb) {
    const int SAMPLES = 10;
    float best_t = 0.0f;
    float min_dist = 1e20f;
    
    for (int i = 0; i <= SAMPLES; ++i) {
        float t_sample = float(i) / float(SAMPLES);
        float2 center = getSplinePos(p0, p1, p2, p3, t_sample);
        float r = mix(ra, rb, t_sample);
        float d = sdSlantedMarkerStamp(p, center, r);
        if (d < min_dist) { min_dist = d; best_t = t_sample; }
    }
    
    SDFResult res;
    res.dist = min_dist;
    res.t = best_t;
    return res;
}

// MARK: - KERNEL 1: SDF + Hard Edge AA + Composite (Single Pass)
kernel void segmentAACompositeKernel(
                                     const device Params &params [[buffer(0)]],
                                     const device GPUSplineSegment *segments [[buffer(1)]],
                                     const device TileIndex *tileIndices [[buffer(2)]],
                                     const device uint32_t *tileList [[buffer(3)]],
                                     texture2d<float, access::read_write> target [[texture(0)]],
                                     uint2 gid [[thread_position_in_grid]])
{
    uint w = target.get_width();
    uint h = target.get_height();
    if (gid.x >= w || gid.y >= h) return;
    
    uint2 tileID = gid / params.tileSize;
    uint tileIndex = tileID.y * params.tilesPerRow + tileID.x;
    TileIndex tIdx = tileIndices[tileIndex];
    
    float2 pos = float2(gid.x, gid.y) + float2(0.5f, 0.5f);
    
    float maxCoverage = 0.0f;
#ifdef DEBUG_SEGMENT_COLORS
    float3 debugColor = float3(0.0);
#endif
    
    for (uint i = 0; i < tIdx.count; ++i) {
        uint segIdx = tileList[tIdx.start + i];
        GPUSplineSegment seg = segments[segIdx];
        
        float signedDist = 1e6f;
        float t = 0.0f;
        
        if (params.isMarker) {
            // ── Slanted chisel-tip marker mode ──
            // Fixed 45° axis, 4:1 capsule swept along the segment.
            if (seg.segmentType == 0) {
                SDFResult res = sdSlantedMarkerStraight(
                                                        pos, seg.p1, seg.p2, seg.radius0, seg.radius1);
                signedDist = res.dist;
                t = res.t;
            } else {
                // segmentType 1 or 2 — both use the same marker sweep
                // along the Catmull-Rom curve.
                SDFResult res = sdSlantedMarkerSpline(
                                                      pos, seg.p0, seg.p1, seg.p2, seg.p3,
                                                      seg.radius0, seg.radius1);
                signedDist = res.dist;
                t = res.t;
            }
        } else if (seg.segmentType == 0) {
            // Straight Uneven Capsule
            SDFResult res = sdUnevenCapsule(pos, seg.p1, seg.p2,
                                            seg.radius0, seg.radius1);
            signedDist = res.dist;
            t = res.t;
        } else if (seg.segmentType == 1) {
            SDFResult res = sdSplineSegment(pos, seg.p0, seg.p1, seg.p2,
                                            seg.p3, seg.radius0, seg.radius1);
            signedDist = res.dist;
            t = res.t;
        } else if (seg.segmentType == 2) {
            SDFResult res = sdSoftEnvelopeSpline(pos, seg.p0, seg.p1, seg.p2,
                                                 seg.p3, seg.radius0,
                                                 seg.radius1);
            signedDist = res.dist;
            t = res.t;
        }
        
        float opacity = mix(seg.opacity0, seg.opacity1, t);
        
        float edgeWidth = 0.94f;
        float bias = 0.5f;
        float adjustedDist = signedDist + bias;
        float cov = 1.0f - smootherstep(-edgeWidth, edgeWidth, adjustedDist);
        float stamped = cov * opacity;
        
        if (stamped > maxCoverage) {
            maxCoverage = stamped;
#ifdef DEBUG_SEGMENT_COLORS
            float rand = fract(sin(float(segIdx) * 12.9898) * 43758.5453);
//            debugColor = float3(rand, fract(rand * 1.3), fract(rand * 1.7));
            
            debugColor = float3( (seg.segmentType + 0.002) / 2, (seg.segmentType + 0.002) / 2, (seg.segmentType + 0.002) / 2  );
#endif
        }
    }
    
    if (maxCoverage < 0.001f) return;
    
    float finalAlpha = maxCoverage * params.penColor.a;
    float4 dst = target.read(gid);
    
#ifdef DEBUG_SEGMENT_COLORS
    float3 srcPremultiplied = debugColor * finalAlpha;
#else
    float3 srcPremultiplied = params.penColor.rgb * finalAlpha;
#endif
    
    if (params.isEraser) {
        dst.rgb = dst.rgb * (1.0f - finalAlpha);
        dst.a = dst.a * (1.0f - finalAlpha);
    } else {
        dst.rgb = srcPremultiplied + dst.rgb * (1.0f - finalAlpha);
        dst.a = finalAlpha + dst.a * (1.0f - finalAlpha);
    }
    target.write(dst, gid);
}

// MARK: - KERNEL 2: SDF + Soft Noise Shape + Composite (Single Pass)
kernel void segmentNoiseCompositeKernel(
                                        const device Params &params [[buffer(0)]],
                                        const device GPUSplineSegment *segments [[buffer(1)]],
                                        const device TileIndex *tileIndices [[buffer(2)]],
                                        const device uint32_t *tileList [[buffer(3)]],
                                        texture2d<float, access::read_write> target [[texture(0)]],
                                        texture2d<float, access::sample> noiseTex [[texture(1)]],
                                        sampler noiseSampler [[sampler(0)]],
                                        uint2 gid [[thread_position_in_grid]])
{
    uint w = target.get_width();
    uint h = target.get_height();
    if (gid.x >= w || gid.y >= h) return;
    
    uint2 tileID = gid / params.tileSize;
    uint tileIndex = tileID.y * params.tilesPerRow + tileID.x;
    TileIndex tIdx = tileIndices[tileIndex];
    
    float2 pos = float2(gid.x, gid.y) + float2(0.5f, 0.5f);
    
    float maxCoverage = 0.0f;
#ifdef DEBUG_SEGMENT_COLORS
    float3 debugColor = float3(0.0);
#endif
    
    for (uint i = 0; i < tIdx.count; ++i) {
        uint segIdx = tileList[tIdx.start + i];
        GPUSplineSegment seg = segments[segIdx];
        
        float signedDist = 1e6f;
        float t = 0.0f;
        
        if (seg.segmentType == 0) {
            // Straight Uneven Capsule
            SDFResult res = sdUnevenCapsule(pos, seg.p1, seg.p2, seg.radius0, seg.radius1);
            signedDist = res.dist;
            t = res.t;
        } else if (seg.segmentType == 1) {
            // Shape 1: Pure Analytical Spline
            SDFResult res = sdSplineSegment(pos, seg.p0, seg.p1, seg.p2, seg.p3, seg.radius0, seg.radius1);
            signedDist = res.dist;
            t = res.t;
        } else if (seg.segmentType == 2) {
            // Shape 2: Pure Soft Envelope Spline
            SDFResult res = sdSoftEnvelopeSpline(pos, seg.p0, seg.p1, seg.p2, seg.p3, seg.radius0, seg.radius1);
            signedDist = res.dist;
            t = res.t;
        }
        
//        float radius = mix(seg.radius0, seg.radius1, smoothstep(0.0f, 1.0f, t));
        float radius = mix(seg.radius0, seg.radius1, t);
        float opacity = mix(seg.opacity0, seg.opacity1, t);
        
        float dist = signedDist + radius;
        float nd = dist / (max(radius, 1.0f) * 1.1f); // reduced from * 1.2f
        
        float covPencil = 1.0f;
        if (nd > 0.08f) {
            float tSoft = clamp((nd - 0.1f) / 0.9f, 0.0f, 1.0f);
            float scurve = tSoft * tSoft * (3.0f - 2.0f * tSoft);
            covPencil = 1.0f - pow(scurve, 0.9f);
        }
        
        float tAir = clamp(nd * 0.8f, 0.0f, 1.0f);
        float covAirbrush = (1.0f - tAir);
        covAirbrush = covAirbrush * covAirbrush;
        
        float softness = saturate((radius - 4.0f) / 800.0f);
        float cov = mix(covPencil, covAirbrush, softness);
        
        float stamped = cov * opacity;
        
        if (stamped > maxCoverage) {
            maxCoverage = stamped;
#ifdef DEBUG_SEGMENT_COLORS
            float rand = fract(sin(float(segIdx) * 12.9898) * 43758.5453);
            debugColor = float3(rand, fract(rand * 1.3), fract(rand * 1.7));
#endif
        }
    }
    
    if (maxCoverage < 0.001f) return;
    
    float noiseVal = 1.0f;
    if (noiseTex.get_width() > 0) {
        float2 noiseUV = fract(float2(gid) / (float(noiseTex.get_width()) * params.noiseScale));
        noiseVal = noiseTex.sample(noiseSampler, noiseUV).r;
    }
    
    float inverted = 1.0f - maxCoverage;
    float noiseAdd = (maxCoverage * 0.94f) + noiseVal;
    float finalAlpha = 1.0f - saturate(inverted / noiseAdd);
    finalAlpha *= params.penColor.a;
    
    if (finalAlpha > 0.0001f) {
        float4 dst = target.read(gid);
        
#ifdef DEBUG_SEGMENT_COLORS
        float3 srcPremultiplied = debugColor * finalAlpha;
#else
        float3 srcPremultiplied = params.penColor.rgb * finalAlpha;
#endif
        
        if (params.isEraser) {
            dst.rgb = dst.rgb * (1.0f - finalAlpha);
            dst.a = dst.a * (1.0f - finalAlpha);
        } else {
            dst.rgb = srcPremultiplied + dst.rgb * (1.0f - finalAlpha);
            dst.a = finalAlpha + dst.a * (1.0f - finalAlpha);
        }
        target.write(dst, gid);
    }
}

// MARK: - Paste Layer and Cut Composite Kernels

kernel void segmentPasteLayerAACompositeKernel(
                                               const device Params              &params       [[buffer(0)]],
                                               const device GPUSplineSegment    *segments     [[buffer(1)]],
                                               const device TileIndex           *tileIndices  [[buffer(2)]],
                                               const device uint32_t            *tileList     [[buffer(3)]],
                                               const device PasteLayerMeta      &meta         [[buffer(4)]],
                                               const device PasteMask           *pasteMasks   [[buffer(5)]],
                                               texture2d<float, access::read_write> target    [[texture(0)]],
                                               uint2 gid [[thread_position_in_grid]])
{
    uint w = target.get_width();
    uint h = target.get_height();
    if (gid.x >= w || gid.y >= h) return;
    
    uint2 tileID     = gid / params.tileSize;
    uint tileIndex   = tileID.y * params.tilesPerRow + tileID.x;
    TileIndex tIdx   = tileIndices[tileIndex];
    
    // dst GPU → original source GPU (via meta.invAffine = destinationToSourceGPU)
    float2 dstPos = float2(gid) + float2(0.5f, 0.5f);
    
    float2 srcPos = float2(
                           meta.row0.x * dstPos.x +
                           meta.row0.y * dstPos.y +
                           meta.row0.z,
                           
                           meta.row1.x * dstPos.x +
                           meta.row1.y * dstPos.y +
                           meta.row1.z
                           );
    
    // dst GPU → src GPU → selection frame
    float maskAlpha = 1.0f;
#ifdef DEBUG_CUT_PASTE
    if (meta.maskCount >= 1u) {
        float2 selectionPos = applyRow(pasteMasks[0].inv0, pasteMasks[0].inv1, srcPos);
        float2 minP = pasteMasks[0].rect.xy;
        float2 maxP = minP + pasteMasks[0].rect.zw;
        float2 d   = max(max(minP - selectionPos, selectionPos - maxP), 0.0f);
        float  out = length(d);
        float  inX = min(selectionPos.x - minP.x, maxP.x - selectionPos.x);
        float  inY = min(selectionPos.y - minP.y, maxP.y - selectionPos.y);
        float  sd  = out - min(inX, inY);
        
        float4 dbg = target.read(gid);
        if (sd < -meta.edgeWidth)      dbg = float4(0.0, 0.0, 1.0, 1.0);
        else if (sd < meta.edgeWidth)  dbg = float4(0.0, 1.0, 0.0, 1.0);
        else return;
        target.write(dbg, gid);
        return;
    }
#else
    for (uint mi = 0u; mi < meta.maskCount; ++mi) {
        float2 selectionPos = applyRow(pasteMasks[mi].inv0, pasteMasks[mi].inv1, srcPos);
        float m = rectMask(selectionPos, pasteMasks[mi].rect, meta.edgeWidth);
        maskAlpha *= (pasteMasks[mi].flags.x > 0.5f) ? (1.0f - m) : m;
    }
    if (maskAlpha < 0.001f) return;
#endif
    
    float maxCoverage = 0.0f;
    float t = 0.0f;
    
    for (uint i = 0; i < tIdx.count; ++i) {
        uint segIdx = tileList[tIdx.start + i];
        GPUSplineSegment seg = segments[segIdx];
        
        float signedDist = 1e6f;
        float segT = 0.0f;
        
        if (params.isMarker) {
            if (seg.segmentType == 0) {
                SDFResult res = sdSlantedMarkerStraight(srcPos, seg.p1, seg.p2,
                                                        seg.radius0, seg.radius1);
                signedDist = res.dist; segT = res.t;
            } else {
                SDFResult res = sdSlantedMarkerSpline(srcPos, seg.p0, seg.p1,
                                                      seg.p2, seg.p3,
                                                      seg.radius0, seg.radius1);
                signedDist = res.dist; segT = res.t;
            }
        } else if (seg.segmentType == 0) {
            SDFResult res = sdUnevenCapsule(srcPos, seg.p1, seg.p2,
                                            seg.radius0, seg.radius1);
            signedDist = res.dist; segT = res.t;
        } else if (seg.segmentType == 1) {
            SDFResult res = sdSplineSegment(srcPos, seg.p0, seg.p1, seg.p2,
                                            seg.p3, seg.radius0, seg.radius1);
            signedDist = res.dist; segT = res.t;
        } else if (seg.segmentType == 2) {
            SDFResult res = sdSoftEnvelopeSpline(srcPos, seg.p0, seg.p1, seg.p2,
                                                 seg.p3, seg.radius0, seg.radius1);
            signedDist = res.dist; segT = res.t;
        }
        
        float opacity = mix(seg.opacity0, seg.opacity1, segT);
        float detInv = meta.row0.x * meta.row1.y - meta.row0.y * meta.row1.x;
        float shrink = sqrt(abs(detInv));        // source px per device px (geometric-mean approx)
        float edgeWidth = 0.94f * shrink;
        float bias = 0.5f * shrink;
        float adjustedDist = signedDist + bias;
        float cov = 1.0f - smootherstep(-edgeWidth, edgeWidth, adjustedDist);
        float stamped = cov * opacity;
        if (stamped > maxCoverage) { maxCoverage = stamped; t = segT; }
    }
    
    if (maxCoverage < 0.001f) return;
    
    float finalAlpha = maxCoverage * params.penColor.a * maskAlpha;
    float4 dst = target.read(gid);
    float3 srcPremul = params.penColor.rgb * finalAlpha;
    
    if (params.isEraser) {
        dst.rgb *= (1.0f - finalAlpha);
        dst.a   *= (1.0f - finalAlpha);
    } else {
        dst.rgb = srcPremul + dst.rgb * (1.0f - finalAlpha);
        dst.a   = finalAlpha + dst.a * (1.0f - finalAlpha);
    }
    target.write(dst, gid);
}

kernel void segmentPasteLayerNoiseCompositeKernel(
                                                  const device Params              &params       [[buffer(0)]],
                                                  const device GPUSplineSegment    *segments     [[buffer(1)]],
                                                  const device TileIndex           *tileIndices  [[buffer(2)]],
                                                  const device uint32_t            *tileList     [[buffer(3)]],
                                                  const device PasteLayerMeta      &meta         [[buffer(4)]],
                                                  const device PasteMask           *pasteMasks   [[buffer(5)]],
                                                  texture2d<float, access::read_write> target    [[texture(0)]],
                                                  texture2d<float, access::sample>  noiseTex     [[texture(1)]],
                                                  sampler noiseSampler [[sampler(0)]],
                                                  uint2 gid [[thread_position_in_grid]])
{
    uint w = target.get_width();
    uint h = target.get_height();
    if (gid.x >= w || gid.y >= h) return;
    
    uint2 tileID     = gid / params.tileSize;
    uint tileIndex   = tileID.y * params.tilesPerRow + tileID.x;
    TileIndex tIdx   = tileIndices[tileIndex];
    
    // dst GPU → original source GPU
    float2 dstPos = float2(gid) + float2(0.5f, 0.5f);
    
    float2 srcPos = float2(
                           meta.row0.x * dstPos.x +
                           meta.row0.y * dstPos.y +
                           meta.row0.z,
                           
                           meta.row1.x * dstPos.x +
                           meta.row1.y * dstPos.y +
                           meta.row1.z
                           );
    
    // dst GPU → src GPU → selection frame
    float maskAlpha = 1.0f;
#ifdef DEBUG_CUT_PASTE
    if (meta.maskCount >= 1u) {
        float2 selectionPos = applyRow(pasteMasks[0].inv0, pasteMasks[0].inv1, srcPos);
        float2 minP = pasteMasks[0].rect.xy;
        float2 maxP = minP + pasteMasks[0].rect.zw;
        float2 d   = max(max(minP - selectionPos, selectionPos - maxP), 0.0f);
        float  out = length(d);
        float  inX = min(selectionPos.x - minP.x, maxP.x - selectionPos.x);
        float  inY = min(selectionPos.y - minP.y, maxP.y - selectionPos.y);
        float  sd  = out - min(inX, inY);
        
        float4 dbg = target.read(gid);
        if (sd < -meta.edgeWidth)      dbg = float4(0.0, 0.0, 1.0, 1.0);
        else if (sd < meta.edgeWidth)  dbg = float4(0.0, 1.0, 0.0, 1.0);
        else return;
        target.write(dbg, gid);
        return;
    }
#else
    for (uint mi = 0u; mi < meta.maskCount; ++mi) {
        float2 selectionPos = applyRow(pasteMasks[mi].inv0, pasteMasks[mi].inv1, srcPos);
        float m = rectMask(selectionPos, pasteMasks[mi].rect, meta.edgeWidth);
        maskAlpha *= (pasteMasks[mi].flags.x > 0.5f) ? (1.0f - m) : m;
    }
    if (maskAlpha < 0.001f) return;
#endif
    
    
    float maxCoverage = 0.0f;
#ifdef DEBUG_SEGMENT_COLORS
    float3 debugColor = float3(0.0);
#endif
    
    for (uint i = 0; i < tIdx.count; ++i) {
        uint segIdx = tileList[tIdx.start + i];
        GPUSplineSegment seg = segments[segIdx];
        
        float signedDist = 1e6f;
        float t = 0.0f;
        
        if (seg.segmentType == 0) {
            SDFResult res = sdUnevenCapsule(srcPos, seg.p1, seg.p2, seg.radius0, seg.radius1);
            signedDist = res.dist;
            t = res.t;
        } else if (seg.segmentType == 1) {
            SDFResult res = sdSplineSegment(srcPos, seg.p0, seg.p1, seg.p2, seg.p3, seg.radius0, seg.radius1);
            signedDist = res.dist;
            t = res.t;
        } else if (seg.segmentType == 2) {
            SDFResult res = sdSoftEnvelopeSpline(srcPos, seg.p0, seg.p1, seg.p2, seg.p3, seg.radius0, seg.radius1);
            signedDist = res.dist;
            t = res.t;
        }
        
        float radius  = mix(seg.radius0, seg.radius1, t);
        float opacity = mix(seg.opacity0, seg.opacity1, t);
        
        float dist = signedDist + radius;
        
        if (isnan(dist) || isnan(signedDist)) {
            continue;
        }
        
        float nd = dist / (max(radius, 1.0f) * 1.1f);
        
        float covPencil = 1.0f;
        if (nd > 0.08f) {
            float tSoft = clamp((nd - 0.1f) / 0.9f, 0.0f, 1.0f);
            float scurve = tSoft * tSoft * (3.0f - 2.0f * tSoft);
            covPencil = 1.0f - pow(scurve, 0.9f);
        }
        
        float tAir = clamp(nd * 0.8f, 0.0f, 1.0f);
        float covAirbrush = (1.0f - tAir);
        covAirbrush = covAirbrush * covAirbrush;
        
        float softness = saturate((radius - 4.0f) / 800.0f);
        float cov = mix(covPencil, covAirbrush, softness);
        
        float stamped = cov * opacity;
        
        if (stamped > maxCoverage) {
            maxCoverage = stamped;
#ifdef DEBUG_SEGMENT_COLORS
            float rand = fract(sin(float(segIdx) * 12.9898) * 43758.5453);
            debugColor = float3(rand, fract(rand * 1.3), fract(rand * 1.7));
#endif
        }
    }
    
    if (maxCoverage < 0.001f) return;
    
    float noiseVal = 1.0f;
    if (noiseTex.get_width() > 0) {
        float2 noiseUV = fract(float2(gid) / (float(noiseTex.get_width()) * params.noiseScale));
        noiseVal = noiseTex.sample(noiseSampler, noiseUV).r;
    }
    
    float inverted = 1.0f - maxCoverage;
    float noiseAdd = (maxCoverage * 0.94f) + noiseVal;
    float finalAlpha = (1.0f - saturate(inverted / noiseAdd)) * maskAlpha;
    finalAlpha *= params.penColor.a;
    
    if (finalAlpha > 0.0001f) {
        float4 dst = target.read(gid);
        
#ifdef DEBUG_SEGMENT_COLORS
        float3 srcPremultiplied = debugColor * finalAlpha;
#else
        float3 srcPremultiplied = params.penColor.rgb * finalAlpha;
#endif
        
        if (params.isEraser) {
            dst.rgb = dst.rgb * (1.0f - finalAlpha);
            dst.a = dst.a * (1.0f - finalAlpha);
        } else {
            dst.rgb = srcPremultiplied + dst.rgb * (1.0f - finalAlpha);
            dst.a = finalAlpha + dst.a * (1.0f - finalAlpha);
        }
        target.write(dst, gid);
    }
}


#ifdef DEBUG_CUT_PASTE
kernel void segmentCutCompositeKernel(
                                      const device CutMeta &meta [[buffer(0)]],
                                      texture2d<float, access::read_write> target [[texture(0)]],
                                      uint2 gid [[thread_position_in_grid]])
{
    uint w = target.get_width();
    uint h = target.get_height();
    if (gid.x >= w || gid.y >= h) return;
    
    float2 dstPos = float2(gid) + float2(0.5f, 0.5f);
    
    // Apply the current cut transform.
    float2 p = float2(
                      meta.row0.x * dstPos.x + meta.row0.y * dstPos.y + meta.row0.z,
                      meta.row1.x * dstPos.x + meta.row1.y * dstPos.y + meta.row1.z
                      );
    
    float2 minP = float2(meta.rect.x, meta.rect.y);
    float2 maxP = minP + float2(meta.rect.z, meta.rect.w);
    
    float2 d   = max(max(minP - p, p - maxP), 0.0f);
    float  out = length(d);
    float  inX = min(p.x - minP.x, maxP.x - p.x);
    float  inY = min(p.y - minP.y, maxP.y - p.y);
    float  sd  = out - min(inX, inY);
    
    // Outside rect:           alpha = 0  (transparent / no write)
    // Inside rect by > edge:  alpha = 1  (solid RED)
    // Feather band:           alpha = .5 (solid GREEN so you can see the band)
    float4 dst = target.read(gid);
    if (sd < -meta.edgeWidth) {
        dst = float4(1.0, 0.0, 0.0, 1.0);          // solid red — interior
    } else if (sd < meta.edgeWidth) {
        dst = float4(0.0, 1.0, 0.0, 1.0);          // solid green — feather band
    } else {
        return;                                    // outside — don't touch
    }
    target.write(dst, gid);
}
#else
kernel void segmentCutCompositeKernel(
                                      const device CutMeta &meta [[buffer(0)]],
                                      texture2d<float, access::read_write> target [[texture(0)]],
                                      uint2 gid [[thread_position_in_grid]]
                                      )
{
  uint w = target.get_width();
  uint h = target.get_height();

  if (gid.x >= w || gid.y >= h) {
      return;
  }

  float2 dstPos =
  float2(gid) + float2(0.5f, 0.5f);

  float2 p = float2(
                    meta.row0.x * dstPos.x +
                    meta.row0.y * dstPos.y +
                    meta.row0.z,

                    meta.row1.x * dstPos.x +
                    meta.row1.y * dstPos.y +
                    meta.row1.z
                    );

  float2 minP = float2(
                       meta.rect.x,
                       meta.rect.y
                       );

  float2 maxP = minP + float2(
                              meta.rect.z,
                              meta.rect.w
                              );

  float2 d = max(
                 max(
                     minP - p,
                     p - maxP
                     ),
                 0.0f
                 );

  float outside = length(d);

  float insideX = min(
                      p.x - minP.x,
                      maxP.x - p.x
                      );

  float insideY = min(
                      p.y - minP.y,
                      maxP.y - p.y
                      );

  float signedDistance =
  outside - min(insideX, insideY);

  float alpha =
  1.0f -
  smootherstep(
               -meta.edgeWidth,
               meta.edgeWidth,
               signedDistance
               );

  if (alpha < 0.001f) {
      return;
  }

  float4 dst = target.read(gid);

  dst.rgb *= (1.0f - alpha);
  dst.a   *= (1.0f - alpha);

  target.write(dst, gid);
}
#endif


kernel void mergeFlattenCompositeKernel(
                                        texture2d<float, access::read>       srcTex  [[texture(0)]],
                                        texture2d<float, access::read_write> target  [[texture(1)]],
                                        constant float &opacity                      [[buffer(0)]],
                                        uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;
    
    float4 src = srcTex.read(gid);
    float sa = saturate(src.a * opacity);
    if (sa <= 0.0f) return;
    
    float4 dst = target.read(gid);
    dst.rgb = src.rgb * opacity + dst.rgb * (1.0f - sa);   // src is premultiplied
    dst.a   = sa + dst.a * (1.0f - sa);
    target.write(dst, gid);
}

// MARK: - Live-view twins (tile-range dispatch)
//
// These are byte-for-byte the same maths as `segmentAACompositeKernel` /
// `segmentNoiseCompositeKernel`, but they carry the stroke's *tile box* so the live
// path can dispatch each stroke over only the tiles it covers instead of the whole
// canvas. The shared kernels above stay untouched — the static path still uses them.

// `flags`: bit0 = isEraser, bit1 = isMarker. Scalars only, laid out to match Swift's
// `LiveStrokeParams` exactly (a float4/SIMD4 penColor would sit at different offsets in
// the two languages — see the note above LivePresentUniforms in liveCompositeKernels.metal).
struct LiveStrokeParams {
    uint  tileOriginX;
    uint  tileOriginY;
    uint  boxTilesPerRow;
    uint  tileSize;
    uint  textureWidth;
    uint  textureHeight;
    uint  stampCount;
    float penColorR;
    float penColorG;
    float penColorB;
    float penColorA;
    float noiseScale;
    uint  flags;
};

// Distance from p to segment a-b (0 when inside the a/b clamp). The per-pixel prune gate
// below uses this against the chord p1→p2 — one sqrt, versus the multi-sample spline SDF.
static inline float liveSegDist(float2 p, float2 a, float2 b) {
    float2 pa = p - a;
    float2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 1e-7f), 0.0f, 1.0f);
    return length(pa - ba * h);
}

// Live twin of `segmentAACompositeKernel`.
//
// CRITICAL: a Metal compute grid always starts at (0,0) — there is no grid-origin
// offset — so the ABSOLUTE canvas pixel (tileOrigin * tileSize + gid) drives the bounds
// check, the tile lookup, the SDF sample position and the destination write. Using the
// raw gid for those would rasterise every stroke into the top-left corner.
kernel void liveSegmentAACompositeKernel(
                                         const device LiveStrokeParams &params [[buffer(0)]],
                                         const device GPUSplineSegment *segments [[buffer(1)]],
                                         const device TileIndex *tileIndices [[buffer(2)]],
                                         const device uint32_t *tileList [[buffer(3)]],
                                         texture2d<float, access::read_write> target [[texture(0)]],
                                         uint2 gid [[thread_position_in_grid]])
{
    uint2 originPx = uint2(params.tileOriginX, params.tileOriginY) * params.tileSize;
    uint2 pixel = originPx + gid;
    uint w = target.get_width();
    uint h = target.get_height();
    if (pixel.x >= w || pixel.y >= h) return;

    uint2 tileID = pixel / params.tileSize;
    uint tileIndex = (tileID.y - params.tileOriginY) * params.boxTilesPerRow
                   + (tileID.x - params.tileOriginX);
    TileIndex tIdx = tileIndices[tileIndex];

    float2 pos = float2(pixel.x, pixel.y) + float2(0.5f, 0.5f);

    bool isMarker = (params.flags & 0x2u) != 0u;
    bool isEraser = (params.flags & 0x1u) != 0u;
    const float3 penRGB = float3(params.penColorR, params.penColorG, params.penColorB);
    const float  penA  = params.penColorA;

    float maxCoverage = 0.0f;
    for (uint i = 0; i < tIdx.count; ++i) {
        uint segIdx = tileList[tIdx.start + i];
        GPUSplineSegment seg = segments[segIdx];

        // Per-pixel prune (see SegmentPrune): a pixel farther than the stored radius from the
        // chord p1→p2 cannot be covered by this segment, so skip the expensive SDF. 0 = not
        // set → never prune. Output-identical.
        float pruneRadius = (seg.padding1 != 0u) ? as_type<float>(seg.padding1) : 3.4e38f;
        if (liveSegDist(pos, seg.p1, seg.p2) > pruneRadius) continue;

        float signedDist = 1e6f;
        float t = 0.0f;

        if (isMarker) {
            if (seg.segmentType == 0) {
                SDFResult res = sdSlantedMarkerStraight(pos, seg.p1, seg.p2, seg.radius0, seg.radius1);
                signedDist = res.dist; t = res.t;
            } else {
                SDFResult res = sdSlantedMarkerSpline(pos, seg.p0, seg.p1, seg.p2, seg.p3, seg.radius0, seg.radius1);
                signedDist = res.dist; t = res.t;
            }
        } else if (seg.segmentType == 0) {
            SDFResult res = sdUnevenCapsule(pos, seg.p1, seg.p2, seg.radius0, seg.radius1);
            signedDist = res.dist; t = res.t;
        } else if (seg.segmentType == 1) {
            SDFResult res = sdSplineSegment(pos, seg.p0, seg.p1, seg.p2, seg.p3, seg.radius0, seg.radius1);
            signedDist = res.dist; t = res.t;
        } else if (seg.segmentType == 2) {
            SDFResult res = sdSoftEnvelopeSpline(pos, seg.p0, seg.p1, seg.p2, seg.p3, seg.radius0, seg.radius1);
            signedDist = res.dist; t = res.t;
        }

        float opacity = mix(seg.opacity0, seg.opacity1, t);
        float edgeWidth = 0.94f;
        float bias = 0.5f;
        float adjustedDist = signedDist + bias;
        float cov = 1.0f - smootherstep(-edgeWidth, edgeWidth, adjustedDist);
        float stamped = cov * opacity;
        if (stamped > maxCoverage) { maxCoverage = stamped; }
    }

    if (maxCoverage < 0.001f) return;

    float finalAlpha = maxCoverage * penA;
    float4 dst = target.read(pixel);
    float3 srcPremultiplied = penRGB * finalAlpha;

    if (isEraser) {
        dst.rgb = dst.rgb * (1.0f - finalAlpha);
        dst.a = dst.a * (1.0f - finalAlpha);
    } else {
        dst.rgb = srcPremultiplied + dst.rgb * (1.0f - finalAlpha);
        dst.a = finalAlpha + dst.a * (1.0f - finalAlpha);
    }
    target.write(dst, pixel);
}

// Live twin of `segmentNoiseCompositeKernel` (markers always take the AA path, exactly
// like the static twin — isMarker is intentionally not consulted here).
kernel void liveSegmentNoiseCompositeKernel(
                                            const device LiveStrokeParams &params [[buffer(0)]],
                                            const device GPUSplineSegment *segments [[buffer(1)]],
                                            const device TileIndex *tileIndices [[buffer(2)]],
                                            const device uint32_t *tileList [[buffer(3)]],
                                            texture2d<float, access::read_write> target [[texture(0)]],
                                            texture2d<float, access::sample> noiseTex [[texture(1)]],
                                            sampler noiseSampler [[sampler(0)]],
                                            uint2 gid [[thread_position_in_grid]])
{
    uint2 originPx = uint2(params.tileOriginX, params.tileOriginY) * params.tileSize;
    uint2 pixel = originPx + gid;
    uint w = target.get_width();
    uint h = target.get_height();
    if (pixel.x >= w || pixel.y >= h) return;

    uint2 tileID = pixel / params.tileSize;
    uint tileIndex = (tileID.y - params.tileOriginY) * params.boxTilesPerRow
                   + (tileID.x - params.tileOriginX);
    TileIndex tIdx = tileIndices[tileIndex];

    float2 pos = float2(pixel.x, pixel.y) + float2(0.5f, 0.5f);

    bool isEraser = (params.flags & 0x1u) != 0u;
    const float3 penRGB = float3(params.penColorR, params.penColorG, params.penColorB);
    const float  penA  = params.penColorA;

    float maxCoverage = 0.0f;
    for (uint i = 0; i < tIdx.count; ++i) {
        uint segIdx = tileList[tIdx.start + i];
        GPUSplineSegment seg = segments[segIdx];

        // Per-pixel prune (see SegmentPrune): skip segments that provably contribute no
        // coverage to this pixel. 0 = not set → never prune. Output-identical.
        float pruneRadius = (seg.padding1 != 0u) ? as_type<float>(seg.padding1) : 3.4e38f;
        if (liveSegDist(pos, seg.p1, seg.p2) > pruneRadius) continue;

        float signedDist = 1e6f;
        float t = 0.0f;

        if (seg.segmentType == 0) {
            SDFResult res = sdUnevenCapsule(pos, seg.p1, seg.p2, seg.radius0, seg.radius1);
            signedDist = res.dist; t = res.t;
        } else if (seg.segmentType == 1) {
            SDFResult res = sdSplineSegment(pos, seg.p0, seg.p1, seg.p2, seg.p3, seg.radius0, seg.radius1);
            signedDist = res.dist; t = res.t;
        } else if (seg.segmentType == 2) {
            SDFResult res = sdSoftEnvelopeSpline(pos, seg.p0, seg.p1, seg.p2, seg.p3, seg.radius0, seg.radius1);
            signedDist = res.dist; t = res.t;
        }

        float radius = mix(seg.radius0, seg.radius1, t);
        float opacity = mix(seg.opacity0, seg.opacity1, t);

        float dist = signedDist + radius;
        float nd = dist / (max(radius, 1.0f) * 1.1f);

        float covPencil = 1.0f;
        if (nd > 0.08f) {
            float tSoft = clamp((nd - 0.1f) / 0.9f, 0.0f, 1.0f);
            float scurve = tSoft * tSoft * (3.0f - 2.0f * tSoft);
            covPencil = 1.0f - pow(scurve, 0.9f);
        }

        float tAir = clamp(nd * 0.8f, 0.0f, 1.0f);
        float covAirbrush = (1.0f - tAir);
        covAirbrush = covAirbrush * covAirbrush;

        float softness = saturate((radius - 4.0f) / 800.0f);
        float cov = mix(covPencil, covAirbrush, softness);
        float stamped = cov * opacity;
        if (stamped > maxCoverage) { maxCoverage = stamped; }
    }

    if (maxCoverage < 0.001f) return;

    float noiseVal = 1.0f;
    if (noiseTex.get_width() > 0) {
        float2 noiseUV = fract(float2(pixel) / (float(noiseTex.get_width()) * params.noiseScale));
        noiseVal = noiseTex.sample(noiseSampler, noiseUV).r;
    }

    float inverted = 1.0f - maxCoverage;
    float noiseAdd = (maxCoverage * 0.94f) + noiseVal;
    float finalAlpha = 1.0f - saturate(inverted / noiseAdd);
    finalAlpha *= penA;

    if (finalAlpha > 0.0001f) {
        float4 dst = target.read(pixel);
        float3 srcPremultiplied = penRGB * finalAlpha;
        if (isEraser) {
            dst.rgb = dst.rgb * (1.0f - finalAlpha);
            dst.a = dst.a * (1.0f - finalAlpha);
        } else {
            dst.rgb = srcPremultiplied + dst.rgb * (1.0f - finalAlpha);
            dst.a = finalAlpha + dst.a * (1.0f - finalAlpha);
        }
        target.write(dst, pixel);
    }
}

// MARK: - Per-tile composite (one dispatch per layer, one canvas write per pixel)
//
// Same result as one-dispatch-per-stroke, but every overlapping stroke of a pixel is
// composited in registers and the canvas is written ONCE (instead of read+written once per
// stroke). That is the memory win: the Instruments profile showed the per-stroke kernel is
// ~98% memory-stall with only ~7 resident SIMD-groups (register-limited occupancy), and a
// single large dispatch both removes the k× canvas traffic and raises occupancy. It is used
// for layers without cut ops and without markers (noise included via the noise-capable
// twin below); anything else falls back to the per-stroke path above.

// Source-over of one stroke's coverage onto the running accumulator. `flagsBit0` = eraser.
static inline void perTileCompositeStroke(thread float4 &acc, float4 col, uint flagsValue, float a) {
    if ((flagsValue & 0x1u) != 0u) {                 // eraser: multiply coverage out
        acc.rgb *= (1.0f - a);
        acc.a   *= (1.0f - a);
    } else {                                         // normal: premultiplied source-over
        acc.rgb = col.rgb * a + acc.rgb * (1.0f - a);
        acc.a   = a + acc.a * (1.0f - a);
    }
    // Match the per-stroke path exactly: it blends onto an RGBA8 canvas between strokes, so
    // it quantises to 8 bits after each overlap. The per-tile path keeps full-float, which is
    // *more* accurate but no longer byte-identical to the static render (faint AA rounding).
    // Quantise the accumulator per stroke so the outputs agree bit-for-bit.
    acc = round(clamp(acc, 0.0f, 1.0f) * 255.0f) / 255.0f;
}

struct PerTileParams {
    uint tileOriginX;
    uint tileOriginY;
    uint boxTilesPerRow;
    uint tileSize;
};

kernel void livePerTileAACompositeKernel(
    const device PerTileParams &params    [[buffer(0)]],
    const device GPUSplineSegment *segments [[buffer(1)]],   // global, document (stroke) order
    const device uint32_t *strokeOfSegment [[buffer(2)]],     // global segIdx -> stroke idx
    const device TileIndex *tileStartCount [[buffer(3)]],     // per box-local tile: start/count
    const device uint32_t *tileList [[buffer(4)]],            // global segIdx, ascending (= doc order)
    const device float4 *strokeColor [[buffer(5)]],           // per stroke: pen colour
    const device uint32_t *strokeFlags [[buffer(6)]],         // per stroke: bit0 = eraser
    texture2d<float, access::read_write> target [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = target.get_width();
    uint h = target.get_height();
    uint2 originPx = uint2(params.tileOriginX, params.tileOriginY) * params.tileSize;
    uint2 pixel = originPx + gid;
    if (pixel.x >= w || pixel.y >= h) return;

    uint2 tileID = pixel / params.tileSize;
    uint localTile = (tileID.y - params.tileOriginY) * params.boxTilesPerRow
                   + (tileID.x - params.tileOriginX);
    TileIndex tc = tileStartCount[localTile];
    float2 pos = float2(pixel.x, pixel.y) + float2(0.5f, 0.5f);

    float4 acc = float4(0.0f);          // canvas is cleared before the layer, so start transparent
    uint curStroke = 0xFFFFFFFFu;       // no stroke yet
    float curMax = 0.0f;

    for (uint j = 0; j < tc.count; ++j) {
        uint segIdx = tileList[tc.start + j];        // ascending global index == document order
        uint sId = strokeOfSegment[segIdx];
        if (sId != curStroke) {                       // crossed into a new stroke: composite the last
            if (curStroke != 0xFFFFFFFFu && curMax >= 0.001f) {
                float4 col = strokeColor[curStroke];
                perTileCompositeStroke(acc, col, strokeFlags[curStroke], curMax * col.a);
            }
            curStroke = sId;
            curMax = 0.0f;
        }

        GPUSplineSegment seg = segments[segIdx];
        float pruneRadius = (seg.padding1 != 0u) ? as_type<float>(seg.padding1) : 3.4e38f;
        if (liveSegDist(pos, seg.p1, seg.p2) > pruneRadius) continue;

        float signedDist = 1e6f;
        float t = 0.0f;
        if (seg.segmentType == 0) {
            SDFResult res = sdUnevenCapsule(pos, seg.p1, seg.p2, seg.radius0, seg.radius1);
            signedDist = res.dist; t = res.t;
        } else if (seg.segmentType == 1) {
            SDFResult res = sdSplineSegment(pos, seg.p0, seg.p1, seg.p2, seg.p3, seg.radius0, seg.radius1);
            signedDist = res.dist; t = res.t;
        } else if (seg.segmentType == 2) {
            SDFResult res = sdSoftEnvelopeSpline(pos, seg.p0, seg.p1, seg.p2, seg.p3, seg.radius0, seg.radius1);
            signedDist = res.dist; t = res.t;
        }
        float opacity = mix(seg.opacity0, seg.opacity1, t);
        float edgeWidth = 0.94f;
        float bias = 0.5f;
        float cov = 1.0f - smootherstep(-edgeWidth, edgeWidth, signedDist + bias);
        float stamped = cov * opacity;
        if (stamped > curMax) curMax = stamped;
    }
    // Composite the final stroke group.
    if (curStroke != 0xFFFFFFFFu && curMax >= 0.001f) {
        float4 col = strokeColor[curStroke];
        perTileCompositeStroke(acc, col, strokeFlags[curStroke], curMax * col.a);
    }

    if (acc.a > 0.0001f) target.write(acc, pixel);
}

// MARK: - Per-tile noise-capable composite (one dispatch per layer, AA + noise)
//
// Same one-write-per-pixel structure as `livePerTileAACompositeKernel`, but each stroke
// group uses its own coverage + final-alpha maths: clean strokes the AA path, noisy
// strokes the noise path (strokeFlags bit1 = hasNoise, set by the CPU plan builder).
// That matches the per-stroke path exactly — which picks the noise kernel per stroke —
// including the per-stroke 8-bit quantisation in `perTileCompositeStroke`.
//
// Markers never reach here (the CPU eligibility excludes them); cuts never reach here
// either (they force the per-stroke path). `noiseScale` is the same 0.4 constant the
// per-stroke noise twin uses.
kernel void livePerTileNoiseCompositeKernel(
    const device PerTileParams &params    [[buffer(0)]],
    const device GPUSplineSegment *segments [[buffer(1)]],
    const device uint32_t *strokeOfSegment [[buffer(2)]],
    const device TileIndex *tileStartCount [[buffer(3)]],
    const device uint32_t *tileList [[buffer(4)]],
    const device float4 *strokeColor [[buffer(5)]],
    const device uint32_t *strokeFlags [[buffer(6)]],   // bit0 = eraser, bit1 = hasNoise
    texture2d<float, access::read_write> target [[texture(0)]],
    texture2d<float, access::sample> noiseTex [[texture(1)]],
    sampler noiseSampler [[sampler(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = target.get_width();
    uint h = target.get_height();
    uint2 originPx = uint2(params.tileOriginX, params.tileOriginY) * params.tileSize;
    uint2 pixel = originPx + gid;
    if (pixel.x >= w || pixel.y >= h) return;

    uint2 tileID = pixel / params.tileSize;
    uint localTile = (tileID.y - params.tileOriginY) * params.boxTilesPerRow
                   + (tileID.x - params.tileOriginX);
    TileIndex tc = tileStartCount[localTile];
    float2 pos = float2(pixel.x, pixel.y) + float2(0.5f, 0.5f);

    // Same sampling as liveSegmentNoiseCompositeKernel (noiseScale 0.4).
    float noiseVal = 1.0f;
    if (noiseTex.get_width() > 0) {
        float2 noiseUV = fract(float2(pixel) / (float(noiseTex.get_width()) * 0.4f));
        noiseVal = noiseTex.sample(noiseSampler, noiseUV).r;
    }

    float4 acc = float4(0.0f);
    uint curStroke = 0xFFFFFFFFu;
    float curMax = 0.0f;
    bool curNoisy = false;

    for (uint j = 0; j < tc.count; ++j) {
        uint segIdx = tileList[tc.start + j];
        uint sId = strokeOfSegment[segIdx];
        if (sId != curStroke) {
            if (curStroke != 0xFFFFFFFFu && curMax >= 0.001f) {
                float4 col = strokeColor[curStroke];
                float a;
                if (curNoisy) {
                    float inverted = 1.0f - curMax;
                    float noiseAdd = (curMax * 0.94f) + noiseVal;
                    a = (1.0f - saturate(inverted / noiseAdd)) * col.a;
                } else {
                    a = curMax * col.a;
                }
                if (a > 0.0001f || !curNoisy) {
                    // Match per-stroke: AA strokes composite when curMax >= 0.001;
                    // noisy strokes when final alpha clears 0.0001.
                    if (!curNoisy || a > 0.0001f) {
                        perTileCompositeStroke(acc, col, strokeFlags[curStroke], a);
                    }
                }
            }
            curStroke = sId;
            curMax = 0.0f;
            curNoisy = (strokeFlags[sId] & 0x2u) != 0u;
        }

        GPUSplineSegment seg = segments[segIdx];
        float pruneRadius = (seg.padding1 != 0u) ? as_type<float>(seg.padding1) : 3.4e38f;
        if (liveSegDist(pos, seg.p1, seg.p2) > pruneRadius) continue;

        float stamped = 0.0f;
        if (curNoisy) {
            float signedDist = 1e6f;
            float t = 0.0f;
            if (seg.segmentType == 0) {
                SDFResult res = sdUnevenCapsule(pos, seg.p1, seg.p2, seg.radius0, seg.radius1);
                signedDist = res.dist; t = res.t;
            } else if (seg.segmentType == 1) {
                SDFResult res = sdSplineSegment(pos, seg.p0, seg.p1, seg.p2, seg.p3, seg.radius0, seg.radius1);
                signedDist = res.dist; t = res.t;
            } else if (seg.segmentType == 2) {
                SDFResult res = sdSoftEnvelopeSpline(pos, seg.p0, seg.p1, seg.p2, seg.p3, seg.radius0, seg.radius1);
                signedDist = res.dist; t = res.t;
            }
            float radius = mix(seg.radius0, seg.radius1, t);
            float opacity = mix(seg.opacity0, seg.opacity1, t);
            float dist = signedDist + radius;
            float nd = dist / (max(radius, 1.0f) * 1.1f);
            float covPencil = 1.0f;
            if (nd > 0.08f) {
                float tSoft = clamp((nd - 0.1f) / 0.9f, 0.0f, 1.0f);
                float scurve = tSoft * tSoft * (3.0f - 2.0f * tSoft);
                covPencil = 1.0f - pow(scurve, 0.9f);
            }
            float tAir = clamp(nd * 0.8f, 0.0f, 1.0f);
            float covAirbrush = (1.0f - tAir);
            covAirbrush = covAirbrush * covAirbrush;
            float softness = saturate((radius - 4.0f) / 800.0f);
            float cov = mix(covPencil, covAirbrush, softness);
            stamped = cov * opacity;
        } else {
            float signedDist = 1e6f;
            float t = 0.0f;
            if (seg.segmentType == 0) {
                SDFResult res = sdUnevenCapsule(pos, seg.p1, seg.p2, seg.radius0, seg.radius1);
                signedDist = res.dist; t = res.t;
            } else if (seg.segmentType == 1) {
                SDFResult res = sdSplineSegment(pos, seg.p0, seg.p1, seg.p2, seg.p3, seg.radius0, seg.radius1);
                signedDist = res.dist; t = res.t;
            } else if (seg.segmentType == 2) {
                SDFResult res = sdSoftEnvelopeSpline(pos, seg.p0, seg.p1, seg.p2, seg.p3, seg.radius0, seg.radius1);
                signedDist = res.dist; t = res.t;
            }
            float opacity = mix(seg.opacity0, seg.opacity1, t);
            float cov = 1.0f - smootherstep(-0.94f, 0.94f, signedDist + 0.5f);
            stamped = cov * opacity;
        }
        if (stamped > curMax) curMax = stamped;
    }
    if (curStroke != 0xFFFFFFFFu && curMax >= 0.001f) {
        float4 col = strokeColor[curStroke];
        if (curNoisy) {
            float inverted = 1.0f - curMax;
            float noiseAdd = (curMax * 0.94f) + noiseVal;
            float a = (1.0f - saturate(inverted / noiseAdd)) * col.a;
            if (a > 0.0001f) {
                perTileCompositeStroke(acc, col, strokeFlags[curStroke], a);
            }
        } else {
            perTileCompositeStroke(acc, col, strokeFlags[curStroke], curMax * col.a);
        }
    }

    if (acc.a > 0.0001f) target.write(acc, pixel);
}

// MARK: - GPU tile binning (live view `bin` stage)
//
// Moves the per-frame bulk CPU work — camera re-mapping, per-segment tile ranges, tile
// counts, tile-list scatter — onto the GPU. The reference-space segments are uploaded
// ONCE per document/layer into a persistent buffer; per frame the CPU only uploads a few
// KB (visible-stroke bytes, params, the prefixed tile table) and reads back the tile
// counts (one tile grid of uints).
//
// Pixel contract (see `GpuBinSpec`): the transform + range maths below mirror the Swift
// `LiveRenderCache.remap` + `buildSegmentTileIndicesBoxed` op order exactly, with the
// same truncation-toward-zero int conversion and clamps. The padding is conservative
// (~1px beyond the ink), so even a 1-ulp compiler difference can only add empty tiles,
// never drop inked ones. Scatter order is restored by the chunked sort below, so the
// render kernels see the same ascending document order the CPU binner produces — the
// render kernels themselves are UNTOUCHED by this work.
//
// Only per-tile-eligible layers use this path (no cuts, no markers — enforced on the
// CPU, which falls back to the CPU binning when ineligible). `isMarker` is therefore
// hardcoded to the plain `1.4r + 1` padding here, exactly like the CPU per-tile plan.

// `LiveBinTransformParams` — must match the Swift struct field for field (scalars only).
struct LiveBinTransformParams {
    uint  segCount;
    uint  tilesPerRow;
    uint  tilesPerCol;
    uint  tileSize;
    float texW;
    float texH;
    float invTile;
    float radiusFactor;
    float camA;
    float camB;
    float camC;
    float camD;
    float camTX;
    float camTY;
};

// `LiveBinBoxParams` — must match the Swift struct field for field (scalars only).
struct LiveBinBoxParams {
    uint segCount;
    int  boxMinX;
    int  boxMinY;
    int  boxW;
    int  boxH;
    uint tilesPerRow;
};

// Tile range for one camera-transformed segment: mirror of
// `buildSegmentTileIndicesBoxed` with isMarker == false (per-tile layers never contain
// markers): pad = 1.4 * rMax + 1, strict-inequality off-canvas cull,
// truncation-toward-zero int conversion, clamp to the grid. Returns the
// `SegTileRange.empty` sentinel (1,0,0,0) when off-canvas or degenerate. Used by the
// fused transform+count kernel.
inline int4 liveBinRangeForSeg(constant LiveBinTransformParams &p,
                               float2 p1, float2 p2, float r0, float r1) {
    float rMax = max(r0, r1);
    float pad = 1.4f * rMax + 1.0f;
    float minX = min(p1.x, p2.x) - pad;
    float maxX = max(p1.x, p2.x) + pad;
    float minY = min(p1.y, p2.y) - pad;
    float maxY = max(p1.y, p2.y) + pad;
    if (maxX < 0.0f || minX > p.texW || maxY < 0.0f || minY > p.texH) {
        return int4(1, 0, 0, 0);
    }
    int rowLimit = int(p.tilesPerRow) - 1;
    int colLimit = int(p.tilesPerCol) - 1;
    int minTX = max(0, min(rowLimit, int(minX * p.invTile)));
    int maxTX = max(0, min(rowLimit, int(maxX * p.invTile)));
    int minTY = max(0, min(colLimit, int(minY * p.invTile)));
    int maxTY = max(0, min(colLimit, int(maxY * p.invTile)));
    if (minTX > maxTX || minTY > maxTY) {
        return int4(1, 0, 0, 0);
    }
    return int4(minTX, minTY, maxTX, maxTY);
}

// Per-segment camera transform + tile range + tile incidence counts, fused in one
// dispatch. One thread per reference segment; the grid is 1D
// (`thread_position_in_grid.x`). Culled strokes (visible == 0) emit the
// `SegTileRange.empty` sentinel (1,0,0,0), which the scatter kernel skips exactly
// like the CPU `isValid` check does.
//
// Fusion rationale: the count loop reuses the just-computed range straight from
// registers, saving a dispatch and a full re-read of the ranges buffer. Order-free
// (atomics only accumulate totals), so fusing changes no pixel.
kernel void liveBinTransformCountKernel(
    constant LiveBinTransformParams &p [[buffer(0)]],
    const device GPUSplineSegment *refSegs [[buffer(1)]],
    const device uint *segStroke [[buffer(2)]],
    const device uchar *strokeVisible [[buffer(3)]],
    device GPUSplineSegment *outSegs [[buffer(4)]],
    device int4 *outRanges [[buffer(5)]],
    constant LiveBinBoxParams &b [[buffer(6)]],
    device atomic_uint *counts [[buffer(7)]],
    uint3 tpg [[thread_position_in_grid]])
{
    uint gid = tpg.x;
    if (gid >= p.segCount) return;

    GPUSplineSegment s = refSegs[gid];
    uint sId = segStroke[gid];
    if (strokeVisible[sId] == 0) {
        outSegs[gid] = s;
        outRanges[gid] = int4(1, 0, 0, 0);
        return;
    }

    // Mirror of `LiveRenderCache.remap` in full-math form (branch-free here evaluates to
    // the identical values: x*1+0 is exact in IEEE, 0*anything+0 is 0).
    float2 p0 = float2(p.camA * s.p0.x + p.camC * s.p0.y + p.camTX,
                       p.camB * s.p0.x + p.camD * s.p0.y + p.camTY);
    float2 p1 = float2(p.camA * s.p1.x + p.camC * s.p1.y + p.camTX,
                       p.camB * s.p1.x + p.camD * s.p1.y + p.camTY);
    float2 p2 = float2(p.camA * s.p2.x + p.camC * s.p2.y + p.camTX,
                       p.camB * s.p2.x + p.camD * s.p2.y + p.camTY);
    float2 p3 = float2(p.camA * s.p3.x + p.camC * s.p3.y + p.camTX,
                       p.camB * s.p3.x + p.camD * s.p3.y + p.camTY);
    float r0 = s.radius0 * p.radiusFactor;
    float r1 = s.radius1 * p.radiusFactor;
    float prune = as_type<float>(s.padding1) * p.radiusFactor;

    GPUSplineSegment o;
    o.p0 = p0; o.p1 = p1; o.p2 = p2; o.p3 = p3;
    o.radius0 = r0; o.radius1 = r1;
    o.opacity0 = s.opacity0; o.opacity1 = s.opacity1;
    o.noiseSeed = s.noiseSeed; o.segmentType = s.segmentType;
    o.padding1 = as_type<uint>(prune); o.padding2 = s.padding2;
    outSegs[gid] = o;

    int4 r = liveBinRangeForSeg(p, p1, p2, r0, r1);
    outRanges[gid] = r;
    if (r.x > r.z || r.y > r.w) return;   // empty sentinel — nothing to count
    // Clamp to the layer box: stroke-bounds boxes don't carry the full 1.4r+1 binning
    // slop, so a fringe tile of the range can sit outside the box. Those incidences
    // are never read (render dispatches cover the box only), while an unclamped index
    // faults the atomic and drops the whole command buffer (missing tiles).
    int minTX = max(r.x, b.boxMinX);
    int maxTX = min(r.z, b.boxMinX + b.boxW - 1);
    int minTY = max(r.y, b.boxMinY);
    int maxTY = min(r.w, b.boxMinY + b.boxH - 1);
    if (minTX > maxTX || minTY > maxTY) return;
    // Fused count over the layer box (box-local indexing): same totals the old
    // standalone count kernel produced, straight from registers.
    for (int ty = minTY; ty <= maxTY; ++ty) {
        int tbase = (ty - b.boxMinY) * b.boxW - b.boxMinX;
        for (int tx = minTX; tx <= maxTX; ++tx) {
            uint t = uint(tbase + tx);
            atomic_fetch_add_explicit(&counts[t], 1u, memory_order_relaxed);
        }
    }
}

// Scatter segment indices into the tile list. `heads` are per-tile bump counters that
// must be ZEROED before dispatch; each thread writes slot `starts[t] + bump(heads[t])`.
// (Seeding heads with starts would add the base twice and store past the tile list.)
// Deliberately unordered (parallel) — the chunked sort below restores document order.
kernel void liveBinScatterKernel(
    constant LiveBinBoxParams &p [[buffer(0)]],
    const device int4 *ranges [[buffer(1)]],
    const device uint *starts [[buffer(2)]],
    device atomic_uint *heads [[buffer(3)]],
    device uint *tileList [[buffer(4)]],
    uint3 tpg [[thread_position_in_grid]])
{
    uint gid = tpg.x;
    if (gid >= p.segCount) return;
    int4 r = ranges[gid];
    if (r.x > r.z || r.y > r.w) return;
    // Same box clamp as the fused count loop: out-of-box tiles fault the atomic and
    // drop the frame's render; in-box incidences are unaffected.
    int minTX = max(r.x, p.boxMinX);
    int maxTX = min(r.z, p.boxMinX + p.boxW - 1);
    int minTY = max(r.y, p.boxMinY);
    int maxTY = min(r.w, p.boxMinY + p.boxH - 1);
    if (minTX > maxTX || minTY > maxTY) return;
    for (int ty = minTY; ty <= maxTY; ++ty) {
        int tbase = (ty - p.boxMinY) * p.boxW - p.boxMinX;
        for (int tx = minTX; tx <= maxTX; ++tx) {
            uint t = uint(tbase + tx);
            uint pos = atomic_fetch_add_explicit(&heads[t], 1u, memory_order_relaxed);
            tileList[starts[t] + pos] = gid;
        }
    }
}

// Ascending document order, restored with bounded work per thread (zoom-independent).
// One thread sorting even a 512-entry chunk in global memory goes latency-bound
// (dependent loads nothing can hide), so: the CPU splits every tile slice into fixed
// 512-entry chunks (`GpuBinSpec.chunkTable`), one *threadgroup* bitonic-sorts one
// chunk entirely in threadgroup (SRAM) memory, then pairwise merge passes over a tiny
// CPU-built pair table (`GpuBinSpec.mergePairs`, one thread per pair, sequential
// runs) restore full order. The common case (every tile fits one chunk) needs zero
// merge passes. The CPU scatter is stable, so sorted-ascending == the exact CPU tile
// list, which is what makes the per-tile render kernel's stroke grouping correct.
// Segment indices are unique, so only ascending order matters.
//
// Chunk size 512 must match `GpuBinSpec.sortChunkSize` (merge run sizes start at one
// chunk and double from there).

// `LiveBinSortParams` — must match the Swift struct field for field, in order.
struct LiveBinSortParams {
    uint unitCount;
    uint runSize;
};

// Sort one 512-entry chunk in SRAM (bitonic network, 512 threads cooperating — the
// dispatch MUST use 512 threads per threadgroup, one threadgroup per chunk).
// Chunks cover only slices with >= 2 entries and hold at most 512 of them; shorter
// chunks are padded with UINT_MAX in SRAM only (sinks to the end, never written back).
kernel void liveBinChunkSortKernel(
    constant LiveBinSortParams &p [[buffer(0)]],
    const device uint2 *chunks [[buffer(1)]],
    device uint *tileList [[buffer(2)]],
    uint3 tpg [[threadgroup_position_in_grid]],
    uint3 ttid [[thread_position_in_threadgroup]])
{
    uint c = tpg.x;
    if (c >= p.unitCount) return;
    uint start = chunks[c].x;
    uint len = chunks[c].y;
    if (len < 2) return;
    // One whole chunk fits in SRAM (512 x 4B = 2KB of the 32KB threadgroup budget).
    // Uniform per group (len is per-chunk), so the barriers below always converge.
    threadgroup uint buf[512];
    uint tid = ttid.x;
    buf[tid] = (tid < len) ? tileList[start + tid] : 0xFFFFFFFFu;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint k = 2u; k <= 512u; k <<= 1) {
        for (uint j = k >> 1; j > 0u; j >>= 1) {
            uint ix = tid ^ j;
            if (ix > tid) {
                uint a = buf[tid], b = buf[ix];
                bool up = ((tid & k) == 0u);
                if ((a > b) == up) { buf[tid] = b; buf[ix] = a; }
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
        }
    }
    if (tid < len) tileList[start + tid] = buf[tid];
}

// One pairwise merge over the CPU-built pair table: one thread per pair, serial
// two-finger merge (linear, sequential reads/writes) from `src` to `dst`. `src` and
// `dst` are NEVER the same buffer: passes strictly alternate tileList/scratch, so an
// in-place merge (which clobbers unread input) is impossible by construction. Pairs
// with an empty B run are plain copies — they carry finished or single-chunk tiles
// across the ping-pong, so after the final pass every non-empty tile rests in the
// buffer the CPU directs the render kernel at. Empty tiles appear in no pair.
kernel void liveBinMergePassKernel(
    constant LiveBinSortParams &p [[buffer(0)]],
    const device uint4 *pairs [[buffer(1)]],
    const device uint *src [[buffer(2)]],
    device uint *dst [[buffer(3)]],
    uint3 tpg [[thread_position_in_grid]])
{
    uint i = tpg.x;
    if (i >= p.unitCount) return;
    uint4 pr = pairs[i];
    uint aStart = pr.x, aLen = pr.y, bLen = pr.z, d = pr.w;
    uint bStart = aStart + aLen;
    uint ia = 0, ib = 0;
    while (ia < aLen && ib < bLen) {
        uint a = src[aStart + ia];
        uint b = src[bStart + ib];
        if (a <= b) { dst[d] = a; ++ia; } else { dst[d] = b; ++ib; }
        ++d;
    }
    while (ia < aLen) { dst[d] = src[aStart + ia]; ++ia; ++d; }
    while (ib < bLen) { dst[d] = src[bStart + ib]; ++ib; ++d; }
}
