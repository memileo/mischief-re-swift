#include <metal_stdlib>
#include "commonStructs.h"
using namespace metal;

kernel void highQualityStampWithNoiseKernel(
    const device Params &params [[buffer(0)]],
    const device Stamp *stamps [[buffer(1)]],
    const device TileIndex *tileIndices [[buffer(2)]],
    const device uint32_t *tileList [[buffer(3)]],
    texture2d<float, access::read_write> target [[texture(0)]],
    texture2d<float, access::sample> noiseTex [[texture(1)]],
    sampler noiseSampler [[sampler(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint w = target.get_width();
    uint h = target.get_height();
    if (gid.x >= w || gid.y >= h) return;
    
    float2 pos = float2(gid.x, gid.y) + float2(0.5, 0.5);
    
    // --- 1. Tiling Optimization ---
    // Identify which tile this pixel belongs to
    uint2 tileID = gid / params.tileSize;
    uint tileIndex = tileID.y * params.tilesPerRow + tileID.x;
    TileIndex tIdx = tileIndices[tileIndex];
    
    // Early exit if no stamps overlap this tile
    if (tIdx.count == 0) return;
    
    // --- 2. Calculate Stroke Mask (Max Blending) ---
    float maxMask = 0.0;
    
    for (uint i = 0; i < tIdx.count; ++i) {
        uint stampIdx = tileList[tIdx.start + i];
        Stamp s = stamps[stampIdx];
        
        // Efficient distance calculation
        float2 offset = pos - s.center;
        float dist = fast::sqrt(dot(offset, offset));
        
        // Hard culling based on radius (soft falloff is calculated inside radius)
        // Note: The 1.2 factor in coverage calculation makes the falloff steeper inside this bound
        if (dist >= s.radius) continue;
        
        // Soft falloff: inner 10% full opacity, outer 90% S-curve
        // Normalized distance (0 at center, 1.0 at radius)
        float nd = dist / (s.radius * 1.2);
        
        float coverage;
        if (nd <= 0.08) {
            coverage = 1.0;
        } else {
            float t = clamp((nd - 0.1) / 0.9, 0.0, 1.0);
            float scurve = t * t * (3.0 - 2.0 * t);
            float gradual = pow(scurve, 0.9);
            coverage = 1.0 - gradual;
        }
        
        float dab = coverage * s.opacity;
        
        // "Greater than" blending: Take the maximum opacity found
        maxMask = max(maxMask, dab);
        
        // Optimization: If we are already fully opaque, stop checking other stamps
        if (maxMask >= 1.0) break;
    }
    
    // --- 3. Noise Injection (Canvas Scaled) ---
    if (maxMask > 0.0001) {
        float noiseVal = 1.0; // Default to full opacity if no noise texture
        
        if (noiseTex.get_width() > 0) {
            // Scale: texture size * noiseScale
            float2 noiseUV = fract(float2(gid) / (float(noiseTex.get_width()) * params.noiseScale));
            noiseVal = noiseTex.sample(noiseSampler, noiseUV).r;
        }
        
        // Apply noise to the accumulated stroke mask
        float inverted = 1.0 - maxMask;
        float noiseAdd = (maxMask * 0.94) + noiseVal;
        float finalAlpha = 1.0 - saturate(inverted / noiseAdd);
        
        if (finalAlpha > 0.0001) {
            float4 dst = target.read(gid);
            
            if (params.isEraser) {
                dst.rgb = dst.rgb * (1.0 - finalAlpha);
                dst.a = dst.a * (1.0 - finalAlpha);
            } else {
                float3 srcPremultiplied = params.penColor.rgb * finalAlpha;
                dst.rgb = srcPremultiplied + dst.rgb * (1.0 - finalAlpha);
                dst.a = finalAlpha + dst.a * (1.0 - finalAlpha);
            }
            
            target.write(dst, gid);
        }
    }
}
