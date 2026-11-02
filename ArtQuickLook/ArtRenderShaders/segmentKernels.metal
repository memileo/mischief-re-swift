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
    // Six uniform samples (five intervals) plus one parabolic refinement. The refinement
    // recovers most of the old 10-sample resolution for a single extra evaluation: the
    // original uniform minimum was off by up to half the sample spacing, which is visible
    // on the fat noisy spans (shape 2 is chosen when the chord is short relative to the
    // radius change). Measured on robotcrab layer 2 z3: 58.3 → 50.4 ms, max channel
    // difference 6 LSB, 23 813 pixels (≈1.2 %) differ; live-vs-static stays identical
    // because both paths call this function.
    const int SAMPLES = 5;
    float ds[SAMPLES + 1];
    int best_i = 0;

    for (int i = 0; i <= SAMPLES; i++) {
        float t = float(i) / float(SAMPLES);
        float2 p_curve = getSplinePos(p0, p1, p2, p3, t);

        // Exact mathematical radius, matching Shape 0 and Shape 1
        float radius = mix(ra, rb, t);
        float d_sample = fast::length(p - p_curve) - radius;
        ds[i] = d_sample;

        // Simple minimum is perfectly continuous across segments and has no bulge
        if (d_sample < strokeSDF) {
            strokeSDF = d_sample;
            best_t = t;
            best_i = i;
        }
    }

    // One parabolic step through the three samples around the coarse minimum: d(t) is
    // smooth near its minimum. The divisor is positive at a true minimum; anything else
    // (flat/degenerate span) keeps the coarse result.
    if (best_i > 0 && best_i < SAMPLES) {
        float h = 1.0f / float(SAMPLES);
        float dl = ds[best_i - 1], dc = ds[best_i], dr = ds[best_i + 1];
        float denom = dl - 2.0f * dc + dr;
        if (denom > 1e-6f) {
            float delta = clamp(0.5f * h * (dl - dr) / denom, -h, h);
            float t = clamp(best_t + delta, 0.0f, 1.0f);
            float radius = mix(ra, rb, t);
            float d_refined = fast::length(p - getSplinePos(p0, p1, p2, p3, t)) - radius;
            if (d_refined < strokeSDF) {
                strokeSDF = d_refined;
                best_t = t;
            }
        }
    }

    SDFResult res;
    res.dist = strokeSDF;
    res.t = best_t;
    return res;
}

// MARK: - Shape 3: Slanted Marker (chisel-tip, 4:1 length:diameter, page-fixed 45°)

// Even capsule SDF (Inigo Quilez)
inline float sdEvenCapsule(float2 pos, float2 pa, float2 pb, float r) {
    float2 ba = pb - pa;
    float2 pa2p = pos - pa;
    float h = clamp(dot(pa2p, ba) / max(dot(ba, ba), 1e-7f), 0.0f, 1.0f);
    return length(pa2p - ba * h) - r;
}

// The nib's device-space axis. The chisel is fixed to the page (the ±(1, −1)/√2
// diagonal), so it must turn with the camera: `theta` is the extra rotation the
// segment's transform applies on top of that reference (0 for an unrotated view — and
// then the early-out returns the reference axis bit for bit, so existing renders cannot
// move).
inline float2 liveMarkerAxis(float theta) {
    constexpr float2 reference = float2(-0.70710678f, -0.70710678f);
    if (theta == 0.0f) return reference;
    float cs = cos(theta);
    float sn = sin(theta);
    return float2(reference.x * cs - reference.y * sn,
                  reference.x * sn + reference.y * cs);
}

// Single slanted capsule stamp at a center point.
// Capsule length = 4 × diameter = 8r; half-length = 3r (stamp extent).
inline float sdSlantedMarkerStamp(float2 p, float2 center, float r, float theta) {
    float2 axis = liveMarkerAxis(theta);
    float halfLen = 3.0f * r;            // length = 6r from center = 4 × diameter
    float2 pa = center - axis * halfLen;
    float2 pb = center + axis * halfLen;
    return sdEvenCapsule(p, pa, pb, r);
}

// Marker sweep along a straight segment (segmentType == 0)
inline SDFResult sdSlantedMarkerStraight(float2 p, float2 a, float2 b,
                                         float ra, float rb, float theta) {
    const int SAMPLES = 10;
    float best_t = 0.0f;
    float min_dist = 1e20f;
    
    for (int i = 0; i <= SAMPLES; ++i) {
        float t_sample = float(i) / float(SAMPLES);
        float2 center = mix(a, b, t_sample);
        float r = mix(ra, rb, t_sample);
        float d = sdSlantedMarkerStamp(p, center, r, theta);
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
                                       float ra, float rb, float theta) {
    const int SAMPLES = 10;
    float best_t = 0.0f;
    float min_dist = 1e20f;
    
    for (int i = 0; i <= SAMPLES; ++i) {
        float t_sample = float(i) / float(SAMPLES);
        float2 center = getSplinePos(p0, p1, p2, p3, t_sample);
        float r = mix(ra, rb, t_sample);
        float d = sdSlantedMarkerStamp(p, center, r, theta);
        if (d < min_dist) { min_dist = d; best_t = t_sample; }
    }
    
    SDFResult res;
    res.dist = min_dist;
    res.t = best_t;
    return res;
}

// MARK: - Debug shape colouring (`ART_DEBUG_SEG_COLORS`)
//
// Hue identifies the shape type: red = 0 (straight capsule), blue = 1 (shape-1 spline),
// magenta = 2 (shape-2 soft envelope). The value follows a short sawtooth over the
// segment index, so consecutive segments of the same type shade differently and their
// individual caps can be told apart. The debug branch composites **per segment** (not
// per stroke) for exactly that reason: the normal max-over-a-stroke walk would hide a
// missing/back-facing cap behind the neighbouring segment that still covers the pixel.
// Per-segment alpha is capped at 0.8 so overlapping strokes and their caps show through.
#define DEBUG_ALPHA_CAP 0.8f
static inline float3 debugSegmentColor(uint segmentType, uint segIdx) {
    float v = 0.45f + 0.55f * float(segIdx % 6u) / 5.0f;
    if (segmentType == 1) return float3(0.0f, 0.0f, v);   // blue - sdSplineSegment
    if (segmentType == 2) return float3(v, 0.0f, v);      // magenta - sdSoftEnvelopeSpline
    return float3(v, 0.0f, 0.0f);                         // red - sdUnevenCapsule
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
    const bool debugColors = params.debugSegmentColors;
    
    for (uint i = 0; i < tIdx.count; ++i) {
        uint segIdx = tileList[tIdx.start + i];
        GPUSplineSegment seg = segments[segIdx];
        
        float signedDist = 1e6f;
        float t = 0.0f;
        
        if (params.isMarker) {
            // ── Slanted chisel-tip marker mode ──
            // Page-fixed 45° reference axis, rotated by this segment's camera angle;
            // a 4:1 capsule swept along the segment.
            if (seg.segmentType == 0) {
                SDFResult res = sdSlantedMarkerStraight(
                                                        pos, seg.p1, seg.p2, seg.radius0, seg.radius1,
                                                        as_type<float>(seg.padding2));
                signedDist = res.dist;
                t = res.t;
            } else {
                // segmentType 1 or 2 — both use the same marker sweep
                // along the Catmull-Rom curve.
                SDFResult res = sdSlantedMarkerSpline(
                                                      pos, seg.p0, seg.p1, seg.p2, seg.p3,
                                                      seg.radius0, seg.radius1,
                                                      as_type<float>(seg.padding2));
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
        
        if (debugColors) {
            // One composite per segment: the normal max-over-a-stroke walk would hide a
            // bad cap behind the neighbour still covering the pixel.
            float a = min(stamped * params.penColor.a, DEBUG_ALPHA_CAP);
            if (a > 0.0f) {
                float4 dst = target.read(gid);
                float3 rgb = debugSegmentColor(seg.segmentType, segIdx);
                if (params.isEraser) {
                    dst.rgb *= (1.0f - a);
                    dst.a *= (1.0f - a);
                } else {
                    dst.rgb = rgb * a + dst.rgb * (1.0f - a);
                    dst.a = a + dst.a * (1.0f - a);
                }
                target.write(dst, gid);
            }
        } else if (stamped > maxCoverage) {
            maxCoverage = stamped;
        }
    }
    
    if (maxCoverage < 0.001f) return;
    
    float finalAlpha = maxCoverage * params.penColor.a;
    float4 dst = target.read(gid);
    
    float3 srcPremultiplied = params.penColor.rgb * finalAlpha;
    
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
    const bool debugColors = params.debugSegmentColors;

    // The noise sample depends only on the pixel, so hoist it: the debug branch needs it
    // per segment and the normal path uses it once at the end.
    float noiseVal = 1.0f;
    if (noiseTex.get_width() > 0) {
        float2 noiseUV = fract(float2(gid) / (float(noiseTex.get_width()) * params.noiseScale));
        noiseVal = noiseTex.sample(noiseSampler, noiseUV).r;
    }
    
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
        
        if (debugColors) {
            // Per-segment composite (see segmentAACompositeKernel): each segment's own
            // noise coverage, so a bad cap cannot hide under its neighbour.
            float inverted = 1.0f - stamped;
            float noiseAdd = (stamped * 0.94f) + noiseVal;
            float a = min((1.0f - saturate(inverted / noiseAdd)) * params.penColor.a,
                          DEBUG_ALPHA_CAP);
            if (a > 0.0001f) {
                float4 dst = target.read(gid);
                float3 rgb = debugSegmentColor(seg.segmentType, segIdx);
                if (params.isEraser) {
                    dst.rgb *= (1.0f - a);
                    dst.a *= (1.0f - a);
                } else {
                    dst.rgb = rgb * a + dst.rgb * (1.0f - a);
                    dst.a = a + dst.a * (1.0f - a);
                }
                target.write(dst, gid);
            }
        } else if (stamped > maxCoverage) {
            maxCoverage = stamped;
        }
    }
    
    if (maxCoverage < 0.001f) return;
    
    float inverted = 1.0f - maxCoverage;
    float noiseAdd = (maxCoverage * 0.94f) + noiseVal;
    float finalAlpha = 1.0f - saturate(inverted / noiseAdd);
    finalAlpha *= params.penColor.a;
    
    if (finalAlpha > 0.0001f) {
        float4 dst = target.read(gid);
        
        float3 srcPremultiplied = params.penColor.rgb * finalAlpha;
        
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

// Defined with the live stroke twins below; the paste kernels use the same exact prune.
static inline bool liveSegPruned(float2 p, float2 a, float2 b, float r2);
static inline float liveNoisePruneMargin(float r0, float r1);

kernel void segmentPasteLayerAACompositeKernel(
                                               const device Params              &params       [[buffer(0)]],
                                               const device GPUSplineSegment    *segments     [[buffer(1)]],
                                               const device TileIndex           *tileIndices  [[buffer(2)]],
                                               const device uint32_t            *tileList     [[buffer(3)]],
                                               const device PasteLayerMeta      &meta         [[buffer(4)]],
                                               const device PasteMask           *pasteMasks   [[buffer(5)]],
                                               const device PasteBoxParams      &box          [[buffer(6)]],
                                               texture2d<float, access::read_write> target    [[texture(0)]],
                                               uint2 gid [[thread_position_in_grid]])
{
    uint w = target.get_width();
    uint h = target.get_height();
    uint2 px = gid + uint2(box.originTileX, box.originTileY) * params.tileSize;
    if (px.x >= w || px.y >= h) return;
    
    uint2 tileID     = gid / params.tileSize;
    uint tileIndex   = tileID.y * box.boxTilesPerRow + tileID.x;
    TileIndex tIdx   = tileIndices[tileIndex];
    
    // dst GPU → original source GPU (via meta.invAffine = destinationToSourceGPU)
    float2 dstPos = float2(px) + float2(0.5f, 0.5f);
    
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
        
        float4 dbg = target.read(px);
        if (sd < -meta.edgeWidth)      dbg = float4(0.0, 0.0, 1.0, 1.0);
        else if (sd < meta.edgeWidth)  dbg = float4(0.0, 1.0, 0.0, 1.0);
        else return;
        target.write(dbg, px);
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

    // The AA falloff widens with the destination→source scale, but it is still a
    // *device-pixel* falloff: coverage is exactly zero past `0.44·shrink` source px
    // from the shape. `padding1` is the shape's reach from its chord, so one
    // chord-distance test rejects every segment that cannot paint this pixel — the
    // same exact prune the stroke kernels run before their SDF.
    float detInv = meta.row0.x * meta.row1.y - meta.row0.y * meta.row1.x;
    float shrink = sqrt(abs(detInv));        // source px per device px (geometric-mean approx)
    float edgeWidth = 0.94f * shrink;
    float bias = 0.5f * shrink;
    float pruneMargin = 0.5f + 0.5f * shrink;   // cutoff + float slack

    for (uint i = 0; i < tIdx.count; ++i) {
        uint segIdx = tileList[tIdx.start + i];
        GPUSplineSegment seg = segments[segIdx];

        if (seg.padding1 != 0u) {
            float pr = as_type<float>(seg.padding1) + pruneMargin;
            if (liveSegPruned(srcPos, seg.p1, seg.p2, pr * pr)) continue;
        }

        float signedDist = 1e6f;
        float segT = 0.0f;
        
        if (params.isMarker) {
            if (seg.segmentType == 0) {
                SDFResult res = sdSlantedMarkerStraight(srcPos, seg.p1, seg.p2,
                                                        seg.radius0, seg.radius1,
                                                        as_type<float>(seg.padding2));
                signedDist = res.dist; segT = res.t;
            } else {
                SDFResult res = sdSlantedMarkerSpline(srcPos, seg.p0, seg.p1,
                                                      seg.p2, seg.p3,
                                                      seg.radius0, seg.radius1,
                                                      as_type<float>(seg.padding2));
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
        float adjustedDist = signedDist + bias;
        float cov = 1.0f - smootherstep(-edgeWidth, edgeWidth, adjustedDist);
        float stamped = cov * opacity;
        if (stamped > maxCoverage) { maxCoverage = stamped; t = segT; }
    }
    
    if (maxCoverage < 0.001f) return;
    
    float finalAlpha = maxCoverage * params.penColor.a * maskAlpha;
    float4 dst = target.read(px);
    float3 srcPremul = params.penColor.rgb * finalAlpha;
    
    if (params.isEraser) {
        dst.rgb *= (1.0f - finalAlpha);
        dst.a   *= (1.0f - finalAlpha);
    } else {
        dst.rgb = srcPremul + dst.rgb * (1.0f - finalAlpha);
        dst.a   = finalAlpha + dst.a * (1.0f - finalAlpha);
    }
    target.write(dst, px);
}

kernel void segmentPasteLayerNoiseCompositeKernel(
                                                  const device Params              &params       [[buffer(0)]],
                                                  const device GPUSplineSegment    *segments     [[buffer(1)]],
                                                  const device TileIndex           *tileIndices  [[buffer(2)]],
                                                  const device uint32_t            *tileList     [[buffer(3)]],
                                                  const device PasteLayerMeta      &meta         [[buffer(4)]],
                                                  const device PasteMask           *pasteMasks   [[buffer(5)]],
                                                  const device PasteBoxParams      &box          [[buffer(6)]],
                                                  texture2d<float, access::read_write> target    [[texture(0)]],
                                                  texture2d<float, access::sample>  noiseTex     [[texture(1)]],
                                                  sampler noiseSampler [[sampler(0)]],
                                                  uint2 gid [[thread_position_in_grid]])
{
    uint w = target.get_width();
    uint h = target.get_height();
    uint2 px = gid + uint2(box.originTileX, box.originTileY) * params.tileSize;
    if (px.x >= w || px.y >= h) return;
    
    uint2 tileID     = gid / params.tileSize;
    uint tileIndex   = tileID.y * box.boxTilesPerRow + tileID.x;
    TileIndex tIdx   = tileIndices[tileIndex];
    
    // dst GPU → original source GPU
    float2 dstPos = float2(px) + float2(0.5f, 0.5f);
    
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
        
        float4 dbg = target.read(px);
        if (sd < -meta.edgeWidth)      dbg = float4(0.0, 0.0, 1.0, 1.0);
        else if (sd < meta.edgeWidth)  dbg = float4(0.0, 1.0, 0.0, 1.0);
        else return;
        target.write(dbg, px);
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

    // Same exact per-pixel prune as the AA paste kernel, but a noisy segment's falloff
    // reaches `1.375·max(radius, 1)` from the shape (device px), so scale that margin
    // into source px before testing the chord distance.
    float detInv = meta.row0.x * meta.row1.y - meta.row0.y * meta.row1.x;
    float shrink = sqrt(abs(detInv));

    for (uint i = 0; i < tIdx.count; ++i) {
        uint segIdx = tileList[tIdx.start + i];
        GPUSplineSegment seg = segments[segIdx];

        if (seg.padding1 != 0u) {
            float pr = as_type<float>(seg.padding1)
                     + liveNoisePruneMargin(seg.radius0, seg.radius1) * shrink
                     + 0.5f;
            if (liveSegPruned(srcPos, seg.p1, seg.p2, pr * pr)) continue;
        }

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
        float2 noiseUV = fract(float2(px) / (float(noiseTex.get_width()) * params.noiseScale));
        noiseVal = noiseTex.sample(noiseSampler, noiseUV).r;
    }
    
    float inverted = 1.0f - maxCoverage;
    float noiseAdd = (maxCoverage * 0.94f) + noiseVal;
    float finalAlpha = (1.0f - saturate(inverted / noiseAdd)) * maskAlpha;
    finalAlpha *= params.penColor.a;
    
    if (finalAlpha > 0.0001f) {
        float4 dst = target.read(px);
        
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
        target.write(dst, px);
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

// Squared point-to-segment distance, used by the noise kernel's staged tile ceiling
// (one evaluation per entry, not per pixel).
static inline float liveSegmentDistSq(float2 p, float2 a, float2 b) {
    float2 pa = p - a;
    float2 ba = b - a;
    float bb = dot(ba, ba);
    float pb = dot(pa, ba);
    if (pb <= 0.0f) return dot(pa, pa);
    if (pb >= bb) { float2 q = pa - ba; return dot(q, q); }
    float cr = ba.x * pa.y - ba.y * pa.x;
    return (cr * cr) / bb;
}

// Conservative upper bound on the noise coverage at `nd`, used to skip an entry's SDF
// when even that bound cannot beat the stroke's running max. The kernel's coverage is
//   cov = mix(1 - scurve(nd)^0.9, (1 - clamp(0.8·nd))², softness(radius)),
// with softness ∈ [0,1]. `scurve^0.9 ≥ scurve` on [0,1], so the pencil term is at most
// `1 - scurve`; a mix of two values is at most their max. Both terms are non-increasing
// in nd, so evaluating them at a *lower* bound on nd over-estimates the coverage.
static inline float liveNoiseCovUB(float nd) {
    float tSoft = clamp((nd - 0.1f) / 0.9f, 0.0f, 1.0f);
    float covPencil = 1.0f - tSoft * tSoft * (3.0f - 2.0f * tSoft);
    float tAir = clamp(nd * 0.8f, 0.0f, 1.0f);
    float covAir = (1.0f - tAir) * (1.0f - tAir);
    return max(covPencil, covAir);
}

// The AA twin: `cov = 1 − smootherstep(−0.94, 0.94, sd + 0.5)` is non-increasing in the
// signed distance, so evaluating it at a lower bound on sd upper-bounds the coverage.
static inline float liveAACovUB(float sd) {
    return 1.0f - smootherstep(-0.94f, 0.94f, sd + 0.5f);
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
                SDFResult res = sdSlantedMarkerStraight(pos, seg.p1, seg.p2,
                                                        seg.radius0, seg.radius1,
                                                        as_type<float>(seg.padding2));
                signedDist = res.dist; t = res.t;
            } else {
                SDFResult res = sdSlantedMarkerSpline(pos, seg.p0, seg.p1, seg.p2, seg.p3,
                                                      seg.radius0, seg.radius1,
                                                      as_type<float>(seg.padding2));
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
// for layers without cut ops (noise included via the noise-capable twin below, markers via
// the stroke's bit2 flag → the same chisel SDF the per-stroke AA kernel uses); a layer with
// both markers and noise falls back to the per-stroke path.

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
    uint flags;             // bit0 = saturation skip (ART_LIVE_SATURATE=0 turns it off)
    uint tileGridStride;    // tiles per row of `tileStartCount` (wider than the dispatch
                            // box when a mixed layer's stroke run renders a sub-box of the
                            // GPU-binned layer grid; equal to boxTilesPerRow otherwise)
    uint tileArrayBase;     // this dispatch's box origin inside `tileStartCount`
    uint strokeLo;          // inclusive reference-stroke range this dispatch composites
    uint strokeHi;          // (0…UINT_MAX = all strokes: CPU plan and the pure GPU path)
};

// A stroke's contribution to one pixel is `max` over its segments of `stamped = cov ·
// opacity`, with cov ≤ 1 and opacity ≤ 1 (the geometry builder clamps point opacity to
// 0…1), so `curMax` can never exceed 1. Once it *is* 1, no later segment of the same
// stroke can raise it: the remaining segments of that stroke are provably dead for this
// pixel and can be skipped without touching their 64-byte segment record — a max-only
// short circuit, not an approximation. It pays where a stroke covers a pixel many times
// over: a wide stroke puts ~radius/segmentLength of its own segments in one tile.
#define PT_SAT_CEIL(params) (((params).flags & 0x1u) != 0u ? 1.0f : 3.4e38f)

// The per-tile walk used to fetch a dependent chain of globals per entry: `tileList[j]`,
// then `strokeOfSegment[segIdx]` (random 4-byte load), then `segments[segIdx]` (64 B) —
// and the 64-byte fetch happened for *every* entry, even though the prune rejects almost
// all of them for a given pixel. Staging the entry's prune record in threadgroup memory
// once per threadgroup turns that chain into threadgroup reads and leaves the 64-byte
// segment fetch to the few entries that survive the prune.
//
// 128 entries × (4 B segIdx + 4 B stroke + 4 B prune radius² + 16 B chord) = 3.5 KB per
// threadgroup, so ~9 threadgroups still fit the 32 KB budget. A tile with more entries
// than that stages in further chunks; the walk state (current stroke, running max, block
// cursor) lives in registers and carries across chunks, so the output is unchanged.
#define LIVE_STAGE 128u

// One segment's stamped coverage at one pixel, for every walk and the splat.
//
// These used to exist as three verbatim copies: the AA walk, the noise walk's clean
// branch (its noisy branch is the fourth), and `liveSplatStamped`. The identity gates
// compare splat vs walk byte-for-byte, so a copy that drifted was a pixel difference, not
// a compile error. One definition each, inlined at the call site.
static inline float liveAAStamped(float2 pos, GPUSplineSegment seg) {
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
    return cov * opacity;
}

// The noisy-stroke coverage (per-stroke noise kernel and the noise-capable walk).
static inline float liveNoisyStamped(float2 pos, GPUSplineSegment seg) {
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
    return cov * opacity;
}

// MARK: - Per-tile AA composite (one dispatch per layer, AA only), stroke-box pruning
//
// One pruning block: `GpuBinSpec.pruneBlockSize` (=32) consecutive segments of one
// stroke, carried as (segStart, strokeID) plus a conservative half-open device-space
// stamp box [min, max). Must match `GpuBinStrokeBlock` field for field (uint, uint,
// four plain floats — scalar alignment, stride 24). The pad (CPU: 1.4·maxRadius·
// radiusFactor + 3.5 px over the block's transformed AABB, or 4·maxRadius·radiusFactor +
// 3.5 for a chisel-marker block) covers every stamp cutoff
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
    const device uint32_t *strokeFlags [[buffer(6)]],         // per stroke: bit0 = eraser, bit2 = marker
    const device uint2 *strokeGroupTiles [[buffer(7)]],       // per box-local tile: (start, count) groups
    const device LiveStrokeGroupBlock *strokeGroups [[buffer(8)]], // flat block table
    texture2d<float, access::read_write> target [[texture(0)]],
    uint2 gid [[thread_position_in_grid]],
    uint2 tpg [[threads_per_threadgroup]],
    uint2 tid [[thread_position_in_threadgroup]])
{
    threadgroup uint  tgSeg[LIVE_STAGE];
    threadgroup uint  tgStroke[LIVE_STAGE];
    threadgroup float tgPad2[LIVE_STAGE];
    threadgroup float4 tgChord[LIVE_STAGE];
    threadgroup uchar tgOpMax[LIVE_STAGE];   // max(op0,op1)·255, rounded down; 255 = >1
    uint w = target.get_width();
    uint h = target.get_height();
    uint2 originTile = uint2(params.tileOriginX, params.tileOriginY);
    uint2 originPx = originTile * params.tileSize;
    uint2 pixel = originPx + gid;
    // No early return: the tile-list stage below uses a threadgroup barrier, and a thread
    // that already left the kernel cannot reach it. Trailing threads (a canvas edge that is
    // not a whole number of tiles) clamp to their group's tile — always a valid record,
    // since the dispatch covers exactly the layer's tile box — and skip the final write.
    bool active = (pixel.x < w && pixel.y < h);
    uint2 tileID = pixel / params.tileSize;
    tileID.x = min(max(tileID.x, originTile.x), originTile.x + params.boxTilesPerRow - 1u);
    tileID.y = min(max(tileID.y, originTile.y), originTile.y + params.boxTilesPerCol - 1u);
    uint localTile = params.tileArrayBase
                   + (tileID.y - originTile.y) * params.tileGridStride
                   + (tileID.x - originTile.x);
    TileIndex tc = tileStartCount[localTile];
    float2 pos = float2(pixel.x, pixel.y) + float2(0.5f, 0.5f);

    // ART_LIVE_ABLATE (debug, `LiveConfig.ablate`): 0 in normal use, wrong pixels else.
    // Every bit removes one stage so the frame time can be attributed on GPUs without
    // per-line profiling (AMD). Measured deltas from bit 0:
    //   1  no SDF                 → SDF + coverage time
    //   2  prune rejects all      → loop + tile staging + staged prune (the walk floor)
    //   4  no per-stroke blend    → blend/quantise time
    //   8  no pixel write         → target write time
    //   16 constant segment load  → the surviving entries' segment fetch
    //
    // Bits 2 and 16 no longer touch the prune (it reads the staged record), which is what
    // makes them additive with the saturation skip instead of fighting it.
    const uint ablate = params.ablate;
    const float satCeil = PT_SAT_CEIL(params);
    // `ART_DEBUG_SEG_COLORS`: paint and composite each segment on its own. `curMax` then
    // stays 0, which makes every max-based fast path below inert without extra gates.
    const bool debugColors = (params.flags & 0x2u) != 0u;

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
    // Start from whatever the target already holds. A stroke run can follow cuts/pastes
    // in the same layer (mixed path), so this kernel's box must composite over that
    // content instead of replacing it. Reading the RGBA8 target also matches the
    // per-stroke path, which reads/writes the same 8-bit values between strokes.
    float4 acc = active ? target.read(pixel) : float4(0.0f);
    bool modified = false;              // did any stroke touch this pixel?
    uint curStroke = 0xFFFFFFFFu;       // no stroke yet
    uint curFlags = 0u;                 // per-stroke flags (bit2 = marker)
    float curMax = 0.0f;

    // Tile-list stage (see LIVE_STAGE). The group is 2D (16×16, depth 1), so the flat
    // thread index needs no z term — `stageSize` is exactly the group's thread count.
    const uint stageSize = tpg.x * tpg.y;
    const uint stageIndex = tid.x + tid.y * tpg.x;

    for (uint base = 0; base < tc.count; base += LIVE_STAGE) {
        const uint n = min(LIVE_STAGE, tc.count - base);
        for (uint t = stageIndex; t < n; t += stageSize) {
            uint si = tileList[tc.start + base + t];
            GPUSplineSegment st = segments[si];
            tgSeg[t] = si;
            tgStroke[t] = strokeOfSegment[si];
            tgChord[t] = float4(st.p1, st.p2);
            // Shape reach (camera-scaled) + the device-pixel AA margin (see liveNoisePruneMargin).
            float pruneRadius = (st.padding1 != 0u)
                ? as_type<float>(st.padding1) + 0.5f : 3.4e38f;
            tgPad2[t] = pruneRadius * pruneRadius;
            // Per-entry ceiling for the max-only walk (see the skip below).
            float opMax = max(st.opacity0, st.opacity1);
            tgOpMax[t] = (opMax > 1.0f)
                ? 255u : (uchar)min(254.0f, floor(opMax * 255.0f));
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        for (uint j = 0; j < n; ++j) {
            uint segIdx = tgSeg[j];              // ascending global index == document order
            // Mixed-layer GPU-binned runs: a run composites only its own reference-stroke
            // range. The tile list is ascending by segment index (document order) and
            // stroke ids are non-decreasing with segment index, so entries below the range
            // belong to earlier runs (already composited) and are skipped, and the first
            // entry past it ends this dispatch's work for the pixel.
            if (gCount == 0u) {
                uint sId = tgStroke[j];
                if (sId < params.strokeLo) continue;
                if (sId > params.strokeHi) {
                    if (curStroke != 0xFFFFFFFFu && curMax >= 0.001f && (ablate & 4u) == 0u) {
                        float4 col = strokeColor[curStroke];
                        perTileCompositeStroke(acc, col, curFlags, curMax * col.a);
                        modified = true;
                    }
                    curStroke = 0xFFFFFFFFu;
                    curMax = 0.0f;
                    break;
                }
            }
            if (gCount > 0u) {
                if (segIdx >= nextFirst) {
                    do {
                        LiveStrokeGroupBlock g = strokeGroups[gBase + blockCursor];
                        ++blockCursor;
                        if (haveCur && curStroke != g.strokeID) {   // stroke boundary: composite the last
                            if (curMax >= 0.001f && (ablate & 4u) == 0u) {
                                float4 col = strokeColor[curStroke];
                                perTileCompositeStroke(acc, col, curFlags, curMax * col.a);
                                modified = true;
                            }
                            curMax = 0.0f;
                        }
                        curStroke = g.strokeID;
                        curFlags = strokeFlags[curStroke];
                        haveCur = true;
                        strokeActive = (pos.x >= g.minX && pos.y >= g.minY &&
                                        pos.x < g.maxX  && pos.y < g.maxY);
                        nextFirst = (blockCursor < gCount)
                            ? strokeGroups[gBase + blockCursor].segStart : 0xFFFFFFFFu;
                    } while (segIdx >= nextFirst);
                }
            } else {
                uint sId = tgStroke[j];
                if (sId != curStroke) {                       // crossed into a new stroke: composite the last
                    if (curStroke != 0xFFFFFFFFu && curMax >= 0.001f && (ablate & 4u) == 0u) {
                        float4 col = strokeColor[curStroke];
                        perTileCompositeStroke(acc, col, curFlags, curMax * col.a);
                        modified = true;
                    }
                    strokeActive = true;
                    curStroke = sId;
                    curFlags = strokeFlags[sId];
                    curMax = 0.0f;
                }
            }
            if (!strokeActive) continue;    // box-missed block: every segment stamps nothing
            // Exact per-entry max ceiling (see tgOpMax): this segment's stamped value can
            // never beat max(op0,op1), so a max that already reached it is final for this
            // entry — skip the prune and the SDF without changing the result.
            uint opByte = tgOpMax[j];
            if (opByte != 255u &&
                curMax >= float(opByte + 1u) * (1.0f / 255.0f)) continue;
            if (curMax >= satCeil) continue;    // saturated stroke: this pixel's max is final

            // Prune from the staged record: the entry's chord and prune radius² are already
            // in threadgroup memory, so a rejected entry costs no global fetch at all.
            float4 chord = tgChord[j];
            bool pruned = ((ablate & 2u) != 0u)
                ? true
                : liveSegPruned(pos, chord.xy, chord.zw, tgPad2[j]);
            if (pruned) continue;

            uint segLoad = ((ablate & 16u) != 0u) ? 0u : segIdx;   // bit 16: hoistable load address
            GPUSplineSegment seg = segments[segLoad];               // only entries that can paint

            float stamped = 0.0f;
            if ((ablate & 1u) == 0u) {
                if ((curFlags & 4u) != 0u) {                  // chisel marker stroke
                    float signedDist;
                    float t;
                    if (seg.segmentType == 0) {
                        SDFResult res = sdSlantedMarkerStraight(pos, seg.p1, seg.p2,
                                                        seg.radius0, seg.radius1,
                                                        as_type<float>(seg.padding2));
                        signedDist = res.dist; t = res.t;
                    } else {
                        SDFResult res = sdSlantedMarkerSpline(pos, seg.p0, seg.p1, seg.p2, seg.p3,
                                                      seg.radius0, seg.radius1,
                                                      as_type<float>(seg.padding2));
                        signedDist = res.dist; t = res.t;
                    }
                    float opacity = mix(seg.opacity0, seg.opacity1, t);
                    float cov = 1.0f - smootherstep(-0.94f, 0.94f, signedDist + 0.5f);
                    stamped = cov * opacity;
                } else {
                    stamped = liveAAStamped(pos, seg);
                }
            }
            if (debugColors) {
                float4 sc = strokeColor[curStroke];
                float a = min(stamped * sc.a, DEBUG_ALPHA_CAP);
                if (a > 0.0f) {
                    perTileCompositeStroke(acc,
                                           float4(debugSegmentColor(seg.segmentType, segIdx), 1.0f),
                                           curFlags, a);
                    modified = true;
                }
            } else if (stamped > curMax) {
                curMax = stamped;
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }   // stage chunk
    // Composite the final stroke group.
    if (curStroke != 0xFFFFFFFFu && curMax >= 0.001f && (ablate & 4u) == 0u) {
        float4 col = strokeColor[curStroke];
        perTileCompositeStroke(acc, col, curFlags, curMax * col.a);
        modified = true;
    }

    if (modified && (ablate & 8u) == 0u && active) target.write(acc, pixel);
}

// MARK: - Per-tile noise-capable composite (one dispatch per layer, AA + noise)
//
// Same one-write-per-pixel structure as `livePerTileAACompositeKernel`, but each stroke
// group uses its own coverage + final-alpha maths: clean strokes the AA path, noisy
// strokes the noise path (strokeFlags bit1 = hasNoise, set by the CPU plan builder).
// That matches the per-stroke path exactly — which picks the noise kernel per stroke —
// including the per-stroke 8-bit quantisation in `perTileCompositeStroke`.
//
// Markers reach only the AA kernel above (bit2 flag); a layer that contains both a marker
// and a noisy segment stays on the per-stroke path, so this kernel never has to pick a
// marker SDF. Cuts never reach here either (they force the per-stroke path). `noiseScale`
// is the same 0.4 constant the per-stroke noise twin uses.
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
    uint2 gid [[thread_position_in_grid]],
    uint2 tpg [[threads_per_threadgroup]],
    uint2 tid [[thread_position_in_threadgroup]])
{
    threadgroup uint  tgSeg[LIVE_STAGE];
    threadgroup uint  tgStroke[LIVE_STAGE];
    threadgroup float tgPad2[LIVE_STAGE];
    threadgroup float4 tgChord[LIVE_STAGE];
    threadgroup uchar tgOpMax[LIVE_STAGE];   // max(op0,op1)·255, rounded down; 255 = >1
    threadgroup float tgBound[LIVE_STAGE];   // stamped ceiling over this whole tile
    uint w = target.get_width();
    uint h = target.get_height();
    uint2 originTile = uint2(params.tileOriginX, params.tileOriginY);
    uint2 originPx = originTile * params.tileSize;
    uint2 pixel = originPx + gid;
    // No early return (the tile-list stage below uses a threadgroup barrier): trailing
    // canvas-edge threads clamp to their group's tile and skip the final write.
    bool active = (pixel.x < w && pixel.y < h);
    uint2 tileID = pixel / params.tileSize;
    tileID.x = min(max(tileID.x, originTile.x), originTile.x + params.boxTilesPerRow - 1u);
    tileID.y = min(max(tileID.y, originTile.y), originTile.y + params.boxTilesPerCol - 1u);
    uint localTile = params.tileArrayBase
                   + (tileID.y - originTile.y) * params.tileGridStride
                   + (tileID.x - originTile.x);
    TileIndex tc = tileStartCount[localTile];
    float2 pos = float2(pixel.x, pixel.y) + float2(0.5f, 0.5f);

    // Same sampling as liveSegmentNoiseCompositeKernel (noiseScale 0.4).
    float noiseVal = 1.0f;
    if (noiseTex.get_width() > 0) {
        float2 noiseUV = fract(float2(pixel) / (float(noiseTex.get_width()) * 0.4f));
        noiseVal = noiseTex.sample(noiseSampler, noiseUV).r;
    }

    // Composite over what the target already holds: a stroke run may follow cuts or
    // pastes in the same layer (mixed path). See livePerTileAACompositeKernel.
    float4 acc = active ? target.read(pixel) : float4(0.0f);
    bool modified = false;
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
    const float satCeil = PT_SAT_CEIL(params);
    // `ART_DEBUG_SEG_COLORS` (see the AA per-tile kernel): per-segment composite, and
    // `curMax` stays 0 so the max-based skips below never fire.
    const bool debugColors = (params.flags & 0x2u) != 0u;
    // Same attribution bits as the AA kernel (ART_LIVE_ABLATE, debug only, wrong pixels):
    //   1 no SDF, 2 prune all, 4 no composite, 8 no write, 16 constant segment load.
    const uint ablate = params.ablate;

    // Tile-list stage (see LIVE_STAGE); the noise kernel's prune reach is the noise one.
    const uint stageSize = tpg.x * tpg.y;
    const uint stageIndex = tid.x + tid.y * tpg.x;
    // The staged coverage bound is per (entry, tile), not per pixel: the tile centre plus
    // its half-diagonal lower-bounds every pixel's chord distance by `d_centre − halfDiag`,
    // so one bound covers all 256 pixels. Computing it once here instead of per pixel is
    // what makes the bound affordable (3.7 M evaluations, not 950 M).
    const float2 stageTileCenter = (float2(tileID) + 0.5f) * float(params.tileSize);
    const float stageTileSlack = float(params.tileSize) * 0.70710678f;

    for (uint base = 0; base < tc.count; base += LIVE_STAGE) {
        const uint n = min(LIVE_STAGE, tc.count - base);
        for (uint t = stageIndex; t < n; t += stageSize) {
            uint si = tileList[tc.start + base + t];
            GPUSplineSegment st = segments[si];
            uint sid = strokeOfSegment[si];
            uint sFlags = strokeFlags[sid];
            tgSeg[t] = si;
            tgStroke[t] = sid;
            tgChord[t] = float4(st.p1, st.p2);
            // Per-stroke margin, matching the stroke's actual coverage: the wide noise
            // disk only for a noisy stroke; a clean stroke in the same layer renders AA
            // coverage (zero past 0.44 px), so `aaDeviceMargin` is exact and rejects far
            // more entries — the dominant win on a layer that is mostly clean strokes.
            float margin = ((sFlags & 2u) != 0u)
                ? liveNoisePruneMargin(st.radius0, st.radius1) : 0.5f;
            float pruneRadius = (st.padding1 != 0u)
                ? as_type<float>(st.padding1) + margin
                : 3.4e38f;
            tgPad2[t] = pruneRadius * pruneRadius;
            // Per-entry ceiling for the max-only walk (see the skip below).
            float opMax = max(st.opacity0, st.opacity1);
            tgOpMax[t] = (opMax > 1.0f)
                ? 255u : (uchar)min(254.0f, floor(opMax * 255.0f));
            // Stamped ceiling for the whole tile. Every curve point is within `farOff` of
            // the chord (SegmentPrune.radius's shape term), so the distance from any tile
            // pixel to the curve is ≥ (centre→chord) − halfDiag − farOff. With
            // nd = dist/(1.1·max(r,1)) that lower bound gives an upper bound on the noise
            // coverage; times the entry's opacity ceiling it bounds stamped. Computing it
            // per tile rather than per pixel costs one sqrt per entry, not per pixel.
            float bound = 1e30f;                      // marker or opacity > 1: no bound
            if (st.padding1 != 0u && opMax <= 1.0f && (sFlags & 4u) == 0u) {
                float rMax = max(st.radius0, st.radius1);
                float farOff = max(0.0f, as_type<float>(st.padding1) - rMax);
                float dc = sqrt(liveSegmentDistSq(stageTileCenter, st.p1, st.p2));
                // Lower bound on the distance from any tile pixel to the curve.
                float distLB = max(0.0f, dc - stageTileSlack - farOff - 0.5f);
                float covUB = ((sFlags & 2u) != 0u)
                    ? liveNoiseCovUB(distLB / (1.1f * max(rMax, 1.0f)))
                    : liveAACovUB(distLB - rMax);
                bound = covUB * float((uint)tgOpMax[t] + 1u) * (1.0f / 255.0f);
            }
            tgBound[t] = bound;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        for (uint j = 0; j < n; ++j) {
            uint segIdx = tgSeg[j];
            // Mixed-layer GPU-binned runs (see the AA kernel): skip earlier runs and stop at
            // the first entry of a later one, compositing the last stroke of this run.
            if (gCount == 0u) {
                uint sId = tgStroke[j];
                if (sId < params.strokeLo) continue;
                if (sId > params.strokeHi) {
                    if (curStroke != 0xFFFFFFFFu && curMax >= 0.001f && (ablate & 4u) == 0u) {
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
                            if (!curNoisy || a > 0.0001f) {
                                perTileCompositeStroke(acc, col, strokeFlags[curStroke], a);
                                modified = true;
                            }
                        }
                    }
                    curStroke = 0xFFFFFFFFu;
                    curMax = 0.0f;
                    break;
                }
            }
            if (gCount > 0u) {
                if (segIdx >= nextFirst) {
                    do {
                        LiveStrokeGroupBlock g = strokeGroups[gBase + blockCursor];
                        ++blockCursor;
                        if (haveCur && curStroke != g.strokeID) {   // stroke boundary: composite the last
                            if (curMax >= 0.001f && (ablate & 4u) == 0u) {
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
                                        modified = true;
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
                uint sId = tgStroke[j];
                if (sId != curStroke) {
                    if (curStroke != 0xFFFFFFFFu && curMax >= 0.001f && (ablate & 4u) == 0u) {
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
                                modified = true;
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
            // Exact per-entry max ceiling (see tgOpMax): this segment's stamped value can
            // never beat max(op0,op1), so a max that already reached it is final for this
            // entry — skip the prune and the SDF without changing the result.
            uint opByte = tgOpMax[j];
            if (opByte != 255u &&
                curMax >= float(opByte + 1u) * (1.0f / 255.0f)) continue;
            if (curMax >= satCeil) continue;    // saturated stroke: this pixel's max is final

            // Staged tile-level ceiling: this entry cannot beat curMax anywhere in the
            // tile, so the SDF and the fetch below are dead work.
            if (tgBound[j] <= curMax) continue;

            // Prune from the staged record (see the AA kernel): no global fetch on this path.
            float4 chord = tgChord[j];
            bool pruned = ((ablate & 2u) != 0u)
                ? true
                : liveSegPruned(pos, chord.xy, chord.zw, tgPad2[j]);
            if (pruned) continue;

            uint segLoad = ((ablate & 16u) != 0u) ? 0u : segIdx;
            GPUSplineSegment seg = segments[segLoad];   // only entries that can paint

            float stamped = 0.0f;
            if ((ablate & 1u) == 0u) {
                stamped = curNoisy ? liveNoisyStamped(pos, seg)
                                   : liveAAStamped(pos, seg);
            }
            if (debugColors) {
                float4 sc = strokeColor[curStroke];
                float a;
                if (curNoisy) {
                    float inverted = 1.0f - stamped;
                    float noiseAdd = (stamped * 0.94f) + noiseVal;
                    a = (1.0f - saturate(inverted / noiseAdd)) * sc.a;
                } else {
                    a = stamped * sc.a;
                }
                a = min(a, DEBUG_ALPHA_CAP);
                if (a > 0.0001f) {
                    perTileCompositeStroke(acc,
                                           float4(debugSegmentColor(seg.segmentType, segIdx), 1.0f),
                                           strokeFlags[curStroke], a);
                    modified = true;
                }
            } else if (stamped > curMax) {
                curMax = stamped;
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }   // stage chunk
    if (curStroke != 0xFFFFFFFFu && curMax >= 0.001f && (ablate & 4u) == 0u) {
        float4 col = strokeColor[curStroke];
        if (curNoisy) {
            float inverted = 1.0f - curMax;
            float noiseAdd = (curMax * 0.94f) + noiseVal;
            float a = (1.0f - saturate(inverted / noiseAdd)) * col.a;
            if (a > 0.0001f) {
                perTileCompositeStroke(acc, col, strokeFlags[curStroke], a);
                modified = true;
            }
        } else {
            perTileCompositeStroke(acc, col, strokeFlags[curStroke], curMax * col.a);
            modified = true;
        }
    }

    if (modified && (ablate & 8u) == 0u && active) target.write(acc, pixel);
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
// Splat coverage is `liveAAStamped` / `liveNoisyStamped` — the same functions the walk
// kernels call, so splat-vs-walk identity is structural, not a copy that has to be kept
// in step.
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
            float stamped = noisy ? liveNoisyStamped(pos, s) : liveAAStamped(pos, s);
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
// Only per-tile-eligible layers (no cuts; markers only in a noise-free layer) use this
// path (enforced on the CPU, which falls back to per-stroke when ineligible). The tile
// pad is therefore `SegmentPadding`'s rule, marker-aware via the stroke's bit2 flag.

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
    uint  noiseLayer;   // 1 = this layer runs the noise-capable composite (wider prune)
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
// `buildSegmentTileIndicesBoxed` (pad = 1.4 * rMax + 1 for a capsule/spline, or
// 4 * rMax + 2 for a chisel marker — the same `SegmentPadding.pad` rule, fed by the
// stroke's bit2 flag), strict-inequality off-canvas cull, truncation-toward-zero int
// conversion, clamp to the grid. Returns the `SegTileRange.empty` sentinel (1,0,0,0) when
// off-canvas or degenerate. Used by the fused transform+count kernel.
// `pad` is the segment's *exact* ink reach from the chord plus the composite kernels'
// device-pixel prune margin (`prune + margin`, see `binPad`) — the same quantity the
// per-tile kernels test each pixel against, so a binned tile set is exactly "every tile
// that can contain a painted pixel". The old radius-only guess (1.4·r + 1, 4·r + 2 for
// markers) ignored both the Bézier deviation folded into `padding1` and the difference
// between 1.4 and 1.0, and binned 15–35 % more incidences than can paint.
//
// Margin: 0.5 px is the AA kernels' own prune margin (`aaCutoff` 0.44 + rounding), +0.5 px
// absorbs the tile-range truncation and float rounding. A noise layer is binned with the
// noise kernel's wider reach (`liveNoisePruneMargin`), because that kernel prunes with it
// for every segment of the layer — including its clean strokes, whose AA falloff is the
// floor of that margin.
//
// `padding1 == 0` is the "unset" sentinel (never prune): fall back to the historic
// radius-only constants, which stay conservative.
inline float binPad(constant LiveBinTransformParams &p, float r0, float r1,
                    float prune, bool isMarker, bool noisy) {
    if (prune > 0.0f) {
        // Only a noisy stroke needs the wide noise disk. A clean stroke in the same
        // noisy layer renders through the AA coverage, whose reach is 0.44 px + slack,
        // so the AS margin is exact for it and bins far fewer tiles. `p.noiseLayer`
        // forces the noise margin for every segment (`ART_LIVE_FORCE_KERNEL` A/B, where
        // both kernels must traverse identical tile lists).
        float margin = (p.noiseLayer != 0u || noisy)
            ? max(1.0f, liveNoisePruneMargin(r0, r1)) : 1.0f;
        return prune + margin;
    }
    float rMax = max(r0, r1);
    return isMarker ? (4.0f * rMax + 2.0f) : (1.4f * rMax + 1.0f);
}

inline int4 liveBinRangeForSeg(constant LiveBinTransformParams &p,
                               float2 p1, float2 p2, float pad) {
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
    const device uint *strokeFlags [[buffer(8)]],   // bit2 = isMarker (tile pad 4r+2)
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
    o.padding1 = as_type<uint>(prune);
    // The nib angle is document-space; the per-frame camera rotates it too. Identity
    // camera → atan2(0, 2) = 0 exactly, so the stored bits pass through unchanged.
    float camTheta = atan2(p.camB - p.camC, p.camA + p.camD);
    o.padding2 = as_type<uint>(as_type<float>(s.padding2) + camTheta);
    outSegs[gid] = o;

    uint sFlags = strokeFlags[sId];
    int4 r = liveBinRangeForSeg(p, p1, p2, binPad(p, r0, r1, prune,
                                                (sFlags & 4u) != 0u, (sFlags & 2u) != 0u));
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
// The CPU splits every tile slice into fixed chunks of at most
// `GpuBinSpec.sortChunkSize` entries (1024; `GpuBinSpec.chunkTable`);
// one thread heapsorts one chunk in place (`liveBinChunkSortV3Kernel`: no pads, no
// barriers, no cross-thread cooperation — its failure mode is misordering, never
// poison), then pairwise merge passes over a tiny CPU-built unit table
// (`GpuBinSpec.mergePlan`: each pair's output split into `mergeUnitSize`-entry units,
// one thread per unit locating its input split with a co-rank binary search, then
// serial-merging only its partition) restore full order. The common case (every tile fits
// one chunk) needs zero merge passes. The CPU scatter is stable, so sorted-ascending
// == the exact CPU tile list, which is what makes the per-tile render kernel's
// stroke grouping correct. Segment indices are unique, so only ascending order
// matters.
//
// The chunk length and the merge run sizes both arrive in the parameters (the chunk
// table's `len` and `LiveBinSortParams.runSize`), so no constant here has to match
// `GpuBinSpec.sortChunkSize` — only the bitonic kernel's `sh[1024]` capacity does.

// `LiveBinSortParams` — must match the Swift struct field for field, in order.
struct LiveBinSortParams {
    uint unitCount;
    uint runSize;
};

// Sort one chunk (at most `GpuBinSpec.sortChunkSize` entries) in place with a per-thread
// heapsort (O(n log n) worst case). Deliberately NO cross-thread cooperation: no threadgroup memory, no pads,
// no barriers — one thread owns its chunk start to finish, so the kernel can only
// ever permute the scattered indices, never inject out-of-range values. (A 512-wide
// cooperative bitonic tried here sorted correctly in review and in the Swift mirror
// yet emitted UINT_MAX pads into the tile list on-device — BINCHECK attributed;
// cooperation removed, class of failure removed.) Chunks hold at most
// `GpuBinSpec.sortChunkSize` entries, so per-thread work stays bounded at any zoom; the
// pair-parallel merges reassemble full order.

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

// Sort one chunk in place (heapsort via `liveBinSiftDown`). Chunks cover only slices
// with >= 2 entries and hold at most `GpuBinSpec.sortChunkSize` of them, so per-thread
// nonlinear work is bounded no matter how far the user zooms out.
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

// Carries a tile list between the sort's ping-pong buffers.
//
// Every merge pass moves the whole list from one buffer to the other: a tile that needs
// no merge still has to end up in the pass's destination. Encoding that as merge "units"
// with an empty B run (the pre-Round-17 plan) made the plan's size and the dispatch width
// scale with the tile count — at 8×8 tiles that was ~40 k copy threads per pass versus a
// handful of real merges. This is one coalesced pass over the list instead, and the
// merge units now exist only for pairs that actually merge. It runs before the pass's
// merge dispatches in the same encoder, so a merged range simply overwrites the copy of
// itself that was just written.
kernel void liveBinCopyKernel(
    const device uint *src [[buffer(0)]],
    device uint *dst [[buffer(1)]],
    constant uint &count [[buffer(2)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= count) return;
    dst[gid] = src[gid];
}

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
