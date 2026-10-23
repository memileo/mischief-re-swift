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
    uint  boxTilesPerCol;
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

// Per-pixel prune gate: is `p` farther than `r` from the chord a→b? Exactly the predicate
// `liveSegDist(p, a, b) > r`, but with no sqrt and no division: the three point-to-segment
// cases compare squared distances directly (the perpendicular case multiplies through by
// |ba|²). SegmentPrune.radius() stores `reach + max(0.75, 0.375·r)` as the prune radius, so
// a pixel that passes the gate is still ≥0.75 px inside the SDF's coverage cutoff — the
// rounding difference between the two forms cannot flip a contributing pixel. The kaos
// pixel gate and the per-view A/B runs check that, since this is otherwise a pure gate.
static inline bool liveSegPruned(float2 p, float2 a, float2 b, float r2) {
    float2 pa = p - a;
    float2 ba = b - a;
    float bb = dot(ba, ba);
    float pb = dot(pa, ba);
    if (pb <= 0.0f) return dot(pa, pa) > r2;                       // nearest point is a
    if (pb >= bb) { float2 q = pa - ba; return dot(q, q) > r2; }   // nearest point is b
    float cr = ba.x * pa.y - ba.y * pa.x;                          // perpendicular offset
    return cr * cr > r2 * bb;
}

// Device-space prune margin for the noise kernels (mirror of
// `SegmentPrune.noiseDeviceMargin` in RendererTypes.swift). The noise coverage falls to
// zero at `1.375·max(radius, 1)` from the shape: 0.375·r for a thick stroke, and up to
// `1.375 - r` where the kernel's `max(radius, 1)` floor takes over on a thin or fading
// one. 0.5 (the AA margin) is the floor, because a noisy layer can still contain clean
// strokes that paint with the AA falloff.
static inline float liveNoisePruneMargin(float r0, float r1) {
    float rMax = max(r0, r1);
    float rMin = min(r0, r1);
    float margin = max(0.5f, 0.375f * rMax);
    if (rMin < 1.0f) margin = max(margin, 1.375f - rMin);
    return margin;
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
    // The dispatch covers whole 16×16 threadgroups per tile, so when the layer box's last
    // column/row is not a multiple of the group, the trailing threads cover pixels of a
    // tile outside the box. They must return here: `tileIndex` below would run past the
    // tile table (and composite a neighbouring tile's strokes into this layer).
    if (tileID.x - params.tileOriginX >= params.boxTilesPerRow ||
        tileID.y - params.tileOriginY >= params.boxTilesPerCol) return;
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

        // Per-pixel prune (see SegmentPrune): a pixel farther than the stored shape reach
        // from the chord p1→p2 cannot be covered by this segment, so skip the expensive
        // SDF. `padding1` is camera-scaled shape reach; the AA tail is a device-pixel
        // constant, hence the +aaDeviceMargin here. 0 = not set → never prune.
        float pruneRadius = (seg.padding1 != 0u)
            ? as_type<float>(seg.padding1) + 0.5f : 3.4e38f;
        if (liveSegPruned(pos, seg.p1, seg.p2, pruneRadius * pruneRadius)) continue;

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
    // The dispatch covers whole 16×16 threadgroups per tile, so when the layer box's last
    // column/row is not a multiple of the group, the trailing threads cover pixels of a
    // tile outside the box. They must return here: `tileIndex` below would run past the
    // tile table (and composite a neighbouring tile's strokes into this layer).
    if (tileID.x - params.tileOriginX >= params.boxTilesPerRow ||
        tileID.y - params.tileOriginY >= params.boxTilesPerCol) return;
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
        // coverage to this pixel. The noise falloff reaches
        // `1.375·max(radius, 1)` device px from the shape (aaDeviceMargin is the floor),
        // while `padding1` is the camera-scaled shape reach. 0 = not set → never prune.
        float pruneRadius = (seg.padding1 != 0u)
            ? as_type<float>(seg.padding1) + liveNoisePruneMargin(seg.radius0, seg.radius1)
            : 3.4e38f;
        if (liveSegPruned(pos, seg.p1, seg.p2, pruneRadius * pruneRadius)) continue;

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
    uint boxTilesPerCol;
    uint tileSize;
    uint ablate;            // ART_LIVE_ABLATE — counting/time attribution only (0 = normal)
};

// MARK: - Per-tile AA composite (one dispatch per layer, AA only), stroke-box pruning
//
// One pruning block: `GpuBinSpec.pruneBlockSize` (=32) consecutive segments of one
// stroke, carried as (segStart, strokeID) plus a conservative half-open device-space
// stamp box [min, max). Must match `GpuBinStrokeBlock` field for field (uint, uint,
// four plain floats — scalar alignment, stride 24). The pad (CPU: 1.4·maxRadius·
// radiusFactor + 3.5 px over the block's transformed AABB) covers every stamp cutoff
// (AA cov > 0 needs signedDist < 0.44 ⇒ chord distance < r(t)+0.44; noise cov > 0 needs
// chord distance < 1.375·max(r,1); the stored prune gate only tightens). A pixel outside
// the box therefore provably stamps nothing for the block's segments — skipping it
// changes no output value, it only skips provably-zero work.
struct LiveStrokeGroupBlock {
    uint segStart;
    uint strokeID;
    float minX;
    float minY;
    float maxX;
    float maxY;
};

kernel void livePerTileAACompositeKernel(
    const device PerTileParams &params    [[buffer(0)]],
    const device GPUSplineSegment *segments [[buffer(1)]],   // global, document (stroke) order
    const device uint32_t *strokeOfSegment [[buffer(2)]],     // global segIdx -> stroke idx
    const device TileIndex *tileStartCount [[buffer(3)]],     // per box-local tile: start/count
    const device uint32_t *tileList [[buffer(4)]],            // global segIdx, ascending (= doc order)
    const device float4 *strokeColor [[buffer(5)]],           // per stroke: pen colour
    const device uint32_t *strokeFlags [[buffer(6)]],         // per stroke: bit0 = eraser
    const device uint2 *strokeGroupTiles [[buffer(7)]],       // per box-local tile: (start, count) groups
    const device LiveStrokeGroupBlock *strokeGroups [[buffer(8)]], // flat block table
    texture2d<float, access::read_write> target [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = target.get_width();
    uint h = target.get_height();
    uint2 originPx = uint2(params.tileOriginX, params.tileOriginY) * params.tileSize;
    uint2 pixel = originPx + gid;
    if (pixel.x >= w || pixel.y >= h) return;

    uint2 tileID = pixel / params.tileSize;
    // Same trailing-thread guard as the per-stroke kernels: the dispatch covers whole
    // 16×16 groups per tile, so anything outside the layer's tile box must not index the
    // per-tile tables (Metal validation: "Invalid device load" without this).
    if (tileID.x - params.tileOriginX >= params.boxTilesPerRow ||
        tileID.y - params.tileOriginY >= params.boxTilesPerCol) return;
    uint localTile = (tileID.y - params.tileOriginY) * params.boxTilesPerRow
                   + (tileID.x - params.tileOriginX);
    TileIndex tc = tileStartCount[localTile];
    float2 pos = float2(pixel.x, pixel.y) + float2(0.5f, 0.5f);

    // ART_LIVE_ABLATE (debug, `LiveConfig.ablate`): 0 in normal use, wrong pixels else.
    // Every bit removes one stage so the frame time can be attributed on GPUs without
    // per-line profiling (AMD). Measured deltas from bit 0:
    //   1  no SDF                 → SDF + coverage time
    //   2  prune rejects all      → loop + tile-list/segment loads + block table only
    //   4  no per-stroke blend    → blend/quantise time
    //   8  no pixel write         → target write time
    //   16 constant segment load  → the 64-byte per-iteration segment load
    const uint ablate = params.ablate;

    // Block skip table: per box-local tile, blocks ascending by segStart, each with a
    // conservative half-open device box. The cursor advances exactly when the walk's
    // segment index crosses a block start (nextFirst is register-cached), so skipped
    // segments pay one branch and each resolved block pays one 24-byte load. Blocks
    // never span strokes, so stroke-completion boundaries stay exact. Count 0 = no
    // table (sparse tile, prune off, or a dropped table) → the direct segment walk
    // that predated the table, byte-for-byte behaviour.
    uint2 groupsInfo = strokeGroupTiles[localTile];
    const uint gBase = groupsInfo.x;
    const uint gCount = groupsInfo.y;
    uint blockCursor = 0u;
    uint nextFirst = (gCount > 0u) ? strokeGroups[gBase].segStart : 0u;
    bool strokeActive = true;
    bool haveCur = false;
    float4 acc = float4(0.0f);          // canvas is cleared before the layer, so start transparent
    uint curStroke = 0xFFFFFFFFu;       // no stroke yet
    float curMax = 0.0f;

    for (uint j = 0; j < tc.count; ++j) {
        uint segIdx = tileList[tc.start + j];        // ascending global index == document order
        if (gCount > 0u) {
            if (segIdx >= nextFirst) {
                do {
                    LiveStrokeGroupBlock g = strokeGroups[gBase + blockCursor];
                    ++blockCursor;
                    if (haveCur && curStroke != g.strokeID) {   // stroke boundary: composite the last
                        if (curMax >= 0.001f && (ablate & 4u) == 0u) {
                            float4 col = strokeColor[curStroke];
                            perTileCompositeStroke(acc, col, strokeFlags[curStroke], curMax * col.a);
                        }
                        curMax = 0.0f;
                    }
                    curStroke = g.strokeID;
                    haveCur = true;
                    strokeActive = (pos.x >= g.minX && pos.y >= g.minY &&
                                    pos.x < g.maxX  && pos.y < g.maxY);
                    nextFirst = (blockCursor < gCount)
                        ? strokeGroups[gBase + blockCursor].segStart : 0xFFFFFFFFu;
                } while (segIdx >= nextFirst);
            }
        } else {
            uint sId = strokeOfSegment[segIdx];
            if (sId != curStroke) {                       // crossed into a new stroke: composite the last
                if (curStroke != 0xFFFFFFFFu && curMax >= 0.001f && (ablate & 4u) == 0u) {
                    float4 col = strokeColor[curStroke];
                    perTileCompositeStroke(acc, col, strokeFlags[curStroke], curMax * col.a);
                }
                strokeActive = true;
                curStroke = sId;
                curMax = 0.0f;
            }
        }
        if (!strokeActive) continue;    // box-missed block: every segment stamps nothing

        uint segLoad = ((ablate & 16u) != 0u) ? 0u : segIdx;   // bit 16: hoistable load address
        GPUSplineSegment seg = segments[segLoad];
        // Shape reach (camera-scaled) + the device-pixel AA margin (see liveNoisePruneMargin).
        float pruneRadius = (seg.padding1 != 0u)
            ? as_type<float>(seg.padding1) + 0.5f : 3.4e38f;
        bool pruned = ((ablate & 2u) != 0u)
            ? true
            : liveSegPruned(pos, seg.p1, seg.p2, pruneRadius * pruneRadius);
        if (pruned) continue;

        float signedDist = 1e6f;
        float t = 0.0f;
        if ((ablate & 1u) == 0u) {
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
        }
        float opacity = mix(seg.opacity0, seg.opacity1, t);
        float edgeWidth = 0.94f;
        float bias = 0.5f;
        float cov = 1.0f - smootherstep(-edgeWidth, edgeWidth, signedDist + bias);
        float stamped = cov * opacity;
        if (stamped > curMax) curMax = stamped;
    }
    // Composite the final stroke group.
    if (curStroke != 0xFFFFFFFFu && curMax >= 0.001f && (ablate & 4u) == 0u) {
        float4 col = strokeColor[curStroke];
        perTileCompositeStroke(acc, col, strokeFlags[curStroke], curMax * col.a);
    }

    if (acc.a > 0.0001f && (ablate & 8u) == 0u) target.write(acc, pixel);
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
    const device uint2 *strokeGroupTiles [[buffer(7)]],       // per box-local tile: (start, count) groups
    const device LiveStrokeGroupBlock *strokeGroups [[buffer(8)]], // flat block table
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
    // Same trailing-thread guard as the per-stroke kernels: the dispatch covers whole
    // 16×16 groups per tile, so anything outside the layer's tile box must not index the
    // per-tile tables (Metal validation: "Invalid device load" without this).
    if (tileID.x - params.tileOriginX >= params.boxTilesPerRow ||
        tileID.y - params.tileOriginY >= params.boxTilesPerCol) return;
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
    // Block skip table (same contract as livePerTileAACompositeKernel): cursor over
    // this tile's blocks ascending by segStart; count 0 = no table → direct walk.
    uint2 groupsInfo = strokeGroupTiles[localTile];
    const uint gBase = groupsInfo.x;
    const uint gCount = groupsInfo.y;
    uint blockCursor = 0u;
    uint nextFirst = (gCount > 0u) ? strokeGroups[gBase].segStart : 0u;
    bool strokeActive = true;
    bool haveCur = false;
    uint curStroke = 0xFFFFFFFFu;
    float curMax = 0.0f;
    bool curNoisy = false;

    for (uint j = 0; j < tc.count; ++j) {
        uint segIdx = tileList[tc.start + j];
        if (gCount > 0u) {
            if (segIdx >= nextFirst) {
                do {
                    LiveStrokeGroupBlock g = strokeGroups[gBase + blockCursor];
                    ++blockCursor;
                    if (haveCur && curStroke != g.strokeID) {   // stroke boundary: composite the last
                        if (curMax >= 0.001f) {
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
                        curMax = 0.0f;
                    }
                    curStroke = g.strokeID;
                    haveCur = true;
                    curNoisy = (strokeFlags[g.strokeID] & 0x2u) != 0u;
                    strokeActive = (pos.x >= g.minX && pos.y >= g.minY &&
                                    pos.x < g.maxX  && pos.y < g.maxY);
                    nextFirst = (blockCursor < gCount)
                        ? strokeGroups[gBase + blockCursor].segStart : 0xFFFFFFFFu;
                } while (segIdx >= nextFirst);
            }
        } else {
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
                strokeActive = true;
                curStroke = sId;
                curMax = 0.0f;
                curNoisy = (strokeFlags[sId] & 0x2u) != 0u;
            }
        }
        if (!strokeActive) continue;    // box-missed block: every segment stamps nothing

        GPUSplineSegment seg = segments[segIdx];
        float pruneRadius = (seg.padding1 != 0u)
            ? as_type<float>(seg.padding1) + liveNoisePruneMargin(seg.radius0, seg.radius1)
            : 3.4e38f;

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

// MARK: - Splat composite (segment-parallel small-stamp regime)
//
// The per-tile walk is pixel-parallel: its cost is
// `Σ_segments (pixels in the segment's tile-EXPANDED box)`, which at zoom-out is ~85×
// the ink area (a 2 px stamp still pays for every pixel of the 16 px tile it binned
// into) and runs on only a handful of thousand pixel-threads. The splat path is
// segment-parallel instead: each segment writes the pixels of its prune disk, and the
// per-(pixel, stroke) max is an atomicMax. Cost = the ink area; threads = segments ×
// disk. For an exactness proof (why the prune disk equals the walk's contributing set)
// see SPLAT-DESIGN.md.
//
// `liveSplatStamped` is a VERBATIM copy of the walk kernels' inner stamp maths (AA and
// noisy branches). The identity gates compare splat vs walk byte-for-byte, so any edit
// here must be mirrored there.
//
// `LiveSplatParams` — must match the Swift struct field for field, in order.
struct LiveSplatParams {
    uint segCount;
    uint slotsPerPixel;     // batch size B
    uint batchStart;        // first visible-stroke ordinal in this batch
    uint batchCount;
    uint tileSize;
    uint boxTilesPerRow;
    uint boxTilesPerCol;
    uint flags;             // bit0 = noise enabled (sample the noise texture)
    int  originPxX;         // boxMinTileX * tileSize (left edge of the splat box)
    int  originPxY;
    int  boxPixW;           // boxTilesPerRow * tileSize
    int  boxPixH;
};

inline float liveSplatStamped(GPUSplineSegment seg, float2 pos, bool noisy) {
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
    if (noisy) {
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
        return cov * opacity;
    }
    float opacity = mix(seg.opacity0, seg.opacity1, t);
    float cov = 1.0f - smootherstep(-0.94f, 0.94f, signedDist + 0.5f);
    return cov * opacity;
}

// One thread per reference segment. Segments outside this batch's visible-ordinal range
// return immediately, so one dispatch per batch re-reads the whole segment buffer; that
// is far cheaper than building per-batch segment lists.
kernel void liveSplatKernel(
    constant LiveSplatParams &p [[buffer(0)]],
    const device GPUSplineSegment *frames [[buffer(1)]],   // device space, this frame
    const device uint *segStroke [[buffer(2)]],
    const device uint *strokeFlags [[buffer(3)]],
    const device uint *visOrd [[buffer(4)]],               // strokeId -> visible ordinal | 0xFFFFFFFF
    const device int4 *ranges [[buffer(5)]],               // per-segment tile range (box-clamped use)
    device atomic_uint *splatMax [[buffer(6)]],            // pixels × slotsPerPixel, cleared per batch
    uint3 tpg [[thread_position_in_grid]])
{
    uint gid = tpg.x;
    if (gid >= p.segCount) return;
    uint sid = segStroke[gid];
    uint ord = visOrd[sid];
    if (ord == 0xFFFFFFFFu) return;
    if (ord < p.batchStart || ord >= p.batchStart + p.batchCount) return;

    GPUSplineSegment s = frames[gid];
    float2 a = s.p1, b = s.p2;
    float rMax = max(s.radius0, s.radius1);
    float pad = 1.4f * rMax + 1.0f;
    uint slot = ord - p.batchStart;
    bool noisy = (strokeFlags[sid] & 0x2u) != 0u;
    // Camera-scaled shape reach + the same device-pixel coverage margin the walk prunes
    // with, so the splat's pixel set is exactly the walk's contributing set.
    float prune = as_type<float>(s.padding1);
    if (!(prune > 0.0f)) prune = 3.4e38f;   // walk's "unset" sentinel (never expected)
    prune += noisy ? liveNoisePruneMargin(s.radius0, s.radius1) : 0.5f;

    int x0, y0, x1, y1;
    if (prune <= pad) {
        // Exact path (the normal case at radiusFactor ≤ 1): the prune disk is inside
        // the binning box, so iterating the disk pixel-by-pixel is exactly the walk's
        // contributing set — no tile size dependence at all.
        x0 = max(p.originPxX, int(floor(min(a.x, b.x) - prune)));
        x1 = min(p.originPxX + p.boxPixW - 1, int(ceil(max(a.x, b.x) + prune)));
        y0 = max(p.originPxY, int(floor(min(a.y, b.y) - prune)));
        y1 = min(p.originPxY + p.boxPixH - 1, int(ceil(max(a.y, b.y) + prune)));
    } else {
        // Rare: a strongly curved spline whose prune radius exceeds the box pad, so the
        // disk can reach outside the box. Fall back to the full tile range ∩ box (the
        // walk's evaluated set) and let the disk test trim inside it.
        int4 r = ranges[gid];
        if (r.x > r.z || r.y > r.w) return;
        int bx = p.originPxX / int(p.tileSize);
        int by = p.originPxY / int(p.tileSize);
        int minTX = max(r.x, bx), maxTX = min(r.z, bx + int(p.boxTilesPerRow) - 1);
        int minTY = max(r.y, by), maxTY = min(r.w, by + int(p.boxTilesPerCol) - 1);
        if (minTX > maxTX || minTY > maxTY) return;
        x0 = max(p.originPxX, minTX * int(p.tileSize));
        x1 = min(p.originPxX + p.boxPixW - 1, (maxTX + 1) * int(p.tileSize) - 1);
        y0 = max(p.originPxY, minTY * int(p.tileSize));
        y1 = min(p.originPxY + p.boxPixH - 1, (maxTY + 1) * int(p.tileSize) - 1);
    }
    if (x0 > x1 || y0 > y1) return;

    uint pixelCount = uint(p.boxPixW) * uint(p.boxPixH);
    for (int py = y0; py <= y1; ++py) {
        for (int px = x0; px <= x1; ++px) {
            float2 pos = float2(float(px), float(py)) + float2(0.5f, 0.5f);
            if (liveSegPruned(pos, a, b, prune * prune)) continue;
            float stamped = liveSplatStamped(s, pos, noisy);
            if (!(stamped > 0.0f)) continue;    // 0 adds nothing to the max
            uint idx = uint(py - p.originPxY) * uint(p.boxPixW) + uint(px - p.originPxX);
            // Slot-major (slot * pixelCount + idx): a segment's inner loop walks
            // consecutive idx (contiguous writes), and the composite's per-pixel loop
            // reads consecutive idx across threads (coalesced). Non-negative float bit
            // patterns order like the floats, so the integer max is the float max — and
            // max is commutative, so segment order is irrelevant.
            atomic_fetch_max_explicit(&splatMax[slot * pixelCount + idx],
                                      as_type<uint>(stamped), memory_order_relaxed);
        }
    }
}

// One thread per box pixel. Replays this batch's `slotsPerPixel` slots in visible-
// stroke order into the persistent per-pixel accumulator, then zeroes each slot so the
// next batch's splat writes start clean (one clear total, not one per batch).
kernel void liveSplatCompositeKernel(
    constant LiveSplatParams &p [[buffer(0)]],
    device uint *splatMax [[buffer(1)]],                   // non-atomic read + clear
    const device uint *visStrokeIDs [[buffer(2)]],         // ordinal -> stroke id
    const device float4 *strokeColor [[buffer(3)]],
    const device uint *strokeFlags [[buffer(4)]],
    device float4 *splatAcc [[buffer(5)]],                 // persistent per-pixel accumulator
    texture2d<float, access::sample> noiseTex [[texture(0)]],
    sampler noiseSampler [[sampler(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(p.boxPixW) || gid.y >= uint(p.boxPixH)) return;
    uint idx = gid.y * uint(p.boxPixW) + gid.x;
    int px = p.originPxX + int(gid.x);
    int py = p.originPxY + int(gid.y);

    float noiseVal = 1.0f;
    if ((p.flags & 0x1u) != 0u && noiseTex.get_width() > 0) {
        float2 noiseUV = fract(float2(float(px), float(py)) / (float(noiseTex.get_width()) * 0.4f));
        noiseVal = noiseTex.sample(noiseSampler, noiseUV).r;
    }

    float4 acc = splatAcc[idx];
    uint pixelCount = uint(p.boxPixW) * uint(p.boxPixH);
    device uint *slots = splatMax + idx;              // slot-major: slot * pixelCount + idx
    for (uint k = 0; k < p.slotsPerPixel; ++k) {
        uint bits = slots[k * pixelCount];
        slots[k * pixelCount] = 0u;                   // consumed: next batch starts clean
        if (bits == 0u) continue;
        float v = as_type<float>(bits);
        if (v < 0.001f) continue;             // walk's per-stroke threshold
        uint stroke = visStrokeIDs[p.batchStart + k];
        float4 col = strokeColor[stroke];
        uint fl = strokeFlags[stroke];
        if ((fl & 0x2u) != 0u) {
            float inverted = 1.0f - v;
            float noiseAdd = (v * 0.94f) + noiseVal;
            float a = (1.0f - saturate(inverted / noiseAdd)) * col.a;
            if (a > 0.0001f) perTileCompositeStroke(acc, col, fl, a);
        } else {
            perTileCompositeStroke(acc, col, fl, v * col.a);
        }
    }
    splatAcc[idx] = acc;
}

// One thread per box pixel: writes the finished accumulator into the layer target,
// exactly like the walk kernels' single `target.write` (cleared texture = untouched
// pixels stay transparent).
kernel void liveSplatWriteKernel(
    constant LiveSplatParams &p [[buffer(0)]],
    const device float4 *splatAcc [[buffer(1)]],
    texture2d<float, access::read_write> target [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= uint(p.boxPixW) || gid.y >= uint(p.boxPixH)) return;
    uint idx = gid.y * uint(p.boxPixW) + gid.x;
    float4 acc = splatAcc[idx];
    if (acc.a <= 0.0001f) return;
    uint2 pixel = uint2(uint(p.originPxX) + gid.x, uint(p.originPxY) + gid.y);
    if (pixel.x >= target.get_width() || pixel.y >= target.get_height()) return;
    target.write(acc, pixel);
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
// The CPU splits every tile slice into fixed 512-entry chunks (`GpuBinSpec.chunkTable`);
// one thread heapsorts one chunk in place (`liveBinChunkSortV3Kernel`: no pads, no
// barriers, no cross-thread cooperation — its failure mode is misordering, never
// poison), then pairwise merge passes over a tiny CPU-built unit table
// (`GpuBinSpec.mergePlan`: each pair's output split into ≤1024-entry units, one
// thread per unit locating its input split with a co-rank binary search, then
// serial-merging only its partition) restore full order. The common case (every tile fits
// one chunk) needs zero merge passes. The CPU scatter is stable, so sorted-ascending
// == the exact CPU tile list, which is what makes the per-tile render kernel's
// stroke grouping correct. Segment indices are unique, so only ascending order
// matters.
//
// Chunk size 512 must match `GpuBinSpec.sortChunkSize` (merge run sizes start at one
// chunk and double from there).

// `LiveBinSortParams` — must match the Swift struct field for field, in order.
struct LiveBinSortParams {
    uint unitCount;
    uint runSize;
};

// Sort one 512-entry chunk in place with a per-thread heapsort (O(n log n) worst
// case). Deliberately NO cross-thread cooperation: no threadgroup memory, no pads,
// no barriers — one thread owns its chunk start to finish, so the kernel can only
// ever permute the scattered indices, never inject out-of-range values. (A 512-wide
// cooperative bitonic tried here sorted correctly in review and in the Swift mirror
// yet emitted UINT_MAX pads into the tile list on-device — BINCHECK attributed;
// cooperation removed, class of failure removed.) Chunks hold at most 512 entries,
// so per-thread work stays bounded at any zoom; the pair-parallel merges reassemble
// full order. Chunk size 512 must match `GpuBinSpec.sortChunkSize` (merge run sizes
// start at one chunk and double from there).

// Max-heap sift-down over `list[0, heapEnd)`: drops `v` from `root` to its heap
// position. Iterative (no recursion/stack) and in-place — Metal-2 safe.
inline void liveBinSiftDown(device uint *list, uint root, uint v, uint heapEnd) {
    for (;;) {
        uint left = root * 2 + 1;
        if (left >= heapEnd) break;
        uint right = left + 1;
        uint child = (right < heapEnd && list[right] > list[left]) ? right : left;
        if (list[child] <= v) break;
        list[root] = list[child];
        root = child;
    }
    list[root] = v;
}

// Sort one chunk in place (heapsort via `liveBinSiftDown`). Chunks cover only
// slices with >= 2 entries and hold at most 512 of them, so per-thread nonlinear
// work is bounded no matter how far the user zooms out.
kernel void liveBinChunkSortV3Kernel(
    constant LiveBinSortParams &p [[buffer(0)]],
    const device uint2 *chunks [[buffer(1)]],
    device uint *tileList [[buffer(2)]],
    uint3 tpg [[thread_position_in_grid]])
{
    uint c = tpg.x;
    if (c >= p.unitCount) return;
    uint start = chunks[c].x;
    uint len = chunks[c].y;
    if (len < 2) return;
    device uint *list = tileList + start;
    for (uint i = len / 2; i > 0; --i) {
        liveBinSiftDown(list, i - 1, list[i - 1], len);
    }
    for (uint end = len; end > 1; --end) {
        uint maxV = list[0];
        // Move the tail into the root, restore the heap over [0, end - 1), park max.
        liveBinSiftDown(list, 0, list[end - 1], end - 1);
        list[end - 1] = maxV;
    }
}

// Sort one chunk in place with a threadgroup-cooperative bitonic network over
// threadgroup memory (v4 — replaces the v3 per-thread heapsort default).
//
// Why: the heapsort is ONE thread running ~n·log n DEPENDENT compare-swaps
// (each sift step's loads depend on the previous), so it is latency-bound —
// measured 17–24 ms for kaos-regular's ~7.7k small chunks, ~10 ms at zoom-out,
// and 0.9 s for dots-zoom-in's 512-wide chunks (~30–113 µs per chunk at a
// handful of cycles per dependent step). A bitonic network performs the same
// compare-swaps, but spread across the threadgroup's lanes in shared memory:
// each column is parallel, the serial chain is only O(log² n) columns, and the
// total measured sort should drop to ~1 ms everywhere. The merge passes, the
// chunk table, and all parameters are untouched — same chunks, same offsets.
//
// The earlier on-device attempt of this idea emitted UINT_MAX pads into the
// tile list (BINCHECK-attributed). That kernel padded the DEVICE array out to
// the pow2 width. This version pads ONLY the threadgroup-shared copy — every
// device read/write stays within [start, start+len) — so that failure mode is
// structurally impossible: the kernel writes exactly the input values,
// permuted, and nothing else.
//
// Order: strictly ascending segIdx within the chunk (values are unique — each
// (segment, tile) pair scatters exactly once), so the output is byte-identical
// to the v3 heapsort's; every later stage (merge passes, per-tile render order)
// is untouched. All 128 lanes of a threadgroup share one chunk, so the early
// `len < 2` return is uniform and every barrier is legal.
kernel void liveBinChunkSortV4Kernel(
    constant LiveBinSortParams &p [[buffer(0)]],
    const device uint2 *chunks [[buffer(1)]],
    device uint *tileList [[buffer(2)]],
    uint3 tid [[thread_position_in_grid]])
{
    // Dispatch shape: MTLSize(chunks,1,1) × MTLSize(128,1,1) — global.x is
    // chunk*128 + lane, so these two lines split it. Must stay in sync with
    // `encodeChunkSort`'s dispatch and with the `sh[1024]` capacity below
    // (chunk size is clamped to ≤1024, so pow2ceil(len) ≤ 1024).
    uint c = tid.x >> 7u;
    if (c >= p.unitCount) return;
    uint len = chunks[c].y;
    if (len < 2u) return;
    device uint *list = tileList + chunks[c].x;
    uint lane = tid.x & 127u;
    threadgroup uint sh[1024];
    uint m = 1u;
    while (m < len) m <<= 1u;
    for (uint e = lane; e < len; e += 128u) sh[e] = list[e];
    for (uint e = len + lane; e < m; e += 128u) sh[e] = 0xFFFFFFFFu;
    // Ascending bitonic network. One barrier per column: it guarantees every
    // previous column's writes are visible. Within a column the pairs (e, e^j)
    // are disjoint, and only the LOWER element's owner (p > e) handles a pair,
    // so no element is ever read or written by two lanes of the same column.
    for (uint k = 2u; k <= m; k <<= 1u) {
        for (uint j = k >> 1u; j > 0u; j >>= 1u) {
            threadgroup_barrier(mem_flags::mem_threadgroup);
            for (uint e = lane; e < m; e += 128u) {
                uint p2 = e ^ j;
                if (p2 > e) {
                    uint v = sh[e], pv = sh[p2];
                    bool up = (e & k) == 0u;
                    sh[e] = up ? min(v, pv) : max(v, pv);
                    sh[p2] = up ? max(v, pv) : min(v, pv);
                }
            }
        }
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    // Only the valid prefix goes back — pads (0xFFFFFFFF sorts last) are
    // dropped here, never written to the tile list.
    for (uint e = lane; e < len; e += 128u) list[e] = sh[e];
}

// One thread's share of a pairwise merge: the pair bounds plus the output partition
// [dst+part, dst+part+partLen) this thread owns. Must match `GpuBinMergeUnit` field
// for field (six uints, stride 24).
struct LiveBinMergeUnit {
    uint aStart;
    uint aLen;
    uint bLen;
    uint dst;
    uint part;
    uint partLen;
};

// One partitioned merge over the CPU-built unit table: one thread per unit, each
// owning at most `mergeUnitSize` outputs. The thread locates its input split with a
// co-rank binary search (no inter-thread communication, no barriers), then
// serial-merges only its partition from `src` to `dst`. Passes strictly alternate
// tileList/scratch (src is never dst); units with an empty B run degenerate to plain
// copies of their slice, carrying finished tiles across the ping-pong. No pads, no
// literals written — output values are always exactly the input values, permuted.
// A unit's dst partitions tile its pair's range and pairs tile their slices, so dst
// regions are disjoint across all threads of a pass: race-free by construction.
kernel void liveBinMergePassV3Kernel(
    constant LiveBinSortParams &p [[buffer(0)]],
    const device LiveBinMergeUnit *units [[buffer(1)]],
    const device uint *src [[buffer(2)]],
    device uint *dst [[buffer(3)]],
    uint3 tpg [[thread_position_in_grid]])
{
    uint i = tpg.x;
    if (i >= p.unitCount) return;
    LiveBinMergeUnit u = units[i];
    uint bStart = u.aStart + u.aLen;
    // Co-rank: find (ia, ib) with ia + ib == u.part, A[ia-1] <= B[ib] and
    // B[ib-1] <= A[ia] (missing neighbours count as satisfied). Binary search on ia
    // over [max(0, part-bLen), min(aLen, part)]; guarded reads only, nothing written.
    uint lo = (u.part > u.bLen) ? (u.part - u.bLen) : 0u;
    uint hi = (u.part < u.aLen) ? u.part : u.aLen;
    while (lo < hi) {
        uint ia = (lo + hi) >> 1;
        uint ib = u.part - ia;
        bool tooSmall = (ib > 0u) && (ia < u.aLen)
            && (src[u.aStart + ia] < src[bStart + ib - 1]);
        if (tooSmall) { lo = ia + 1u; } else { hi = ia; }
    }
    uint ia = lo, ib = u.part - lo;
    // Serial two-finger merge over exactly this partition (linear, sequential).
    uint d = u.dst + u.part;
    uint end = d + u.partLen;
    while (d < end) {
        bool takeA = (ib >= u.bLen)
            || ((ia < u.aLen) && (src[u.aStart + ia] <= src[bStart + ib]));
        if (takeA) { dst[d] = src[u.aStart + ia]; ++ia; }
        else { dst[d] = src[bStart + ib]; ++ib; }
        ++d;
    }
}
