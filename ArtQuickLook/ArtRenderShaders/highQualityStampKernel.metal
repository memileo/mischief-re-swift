#include <metal_stdlib>
#include "commonStructs.h"
using namespace metal;

kernel void highQualityStampKernel(
    const device Params &params [[buffer(0)]],
    const device Stamp *stamps [[buffer(1)]],
    texture2d<float, access::read_write> target [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint w = params.textureWidth;
    uint h = params.textureHeight;
    if (gid.x >= w || gid.y >= h) return;
    
    float2 pos = float2(gid.x, gid.y) + float2(0.5, 0.5);
    
    // Read current pixel value (already premultiplied from previous operations)
    float4 currentColor = target.read(gid);
    
    // Process all stamps for this pixel to find the one with highest coverage
    float maxCoverage = 0.0;
    float maxOpacity = 0.0;
    
    for (uint i = 0; i < params.stampCount; ++i) {
        Stamp s = stamps[i];
        float dist = distance(pos, s.center);
        
        if (dist < s.radius) {
            float coverage = 1.0 - smoothstep(s.radius - 1.0, s.radius + 1.0, dist);
            if (coverage > maxCoverage) {
                maxCoverage = coverage;
                maxOpacity = s.opacity;
            }
        }
    }
    
    // Apply the best stamp
    if (maxCoverage > 0.001) {
        float4 stampColor = params.penColor;
        float finalAlpha = maxCoverage * maxOpacity;
        
        float4 result;
        if (params.isEraser) {
            // Destination-out blending: result = dest * (1 - srcAlpha)
            // For erasers, we work with premultiplied alpha
            result.rgb = currentColor.rgb * (1.0 - finalAlpha);
            result.a = currentColor.a * (1.0 - finalAlpha);
        } else {
            // Standard premultiplied alpha blending
            // Both source and destination should be in premultiplied format
            float3 srcPremultiplied = stampColor.rgb * finalAlpha;
            result.rgb = srcPremultiplied + currentColor.rgb * (1.0 - finalAlpha);
            result.a = finalAlpha + currentColor.a * (1.0 - finalAlpha);
        }
        
        target.write(result, gid);
    }
}
