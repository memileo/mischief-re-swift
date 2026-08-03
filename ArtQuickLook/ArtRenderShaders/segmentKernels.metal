#include <metal_stdlib>
#include "commonStructs.h"
using namespace metal;

// Uncomment to see individual segments colored randomly
// #define DEBUG_SEGMENT_COLORS

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
    constexpr float2 axis = float2(0.70710678f, -0.70710678f);
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
