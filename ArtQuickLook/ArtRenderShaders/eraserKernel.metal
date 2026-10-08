#include <metal_stdlib>
#include "commonStructs.h"
using namespace metal;

// Hard-edged circle function for erasers
float drawEraserCircle(float2 pos, float2 center, float radius) {
    float dist = distance(pos, center);
    
    // Use a hard edge for erasers
    return dist < radius ? 1.0 : 0.0;
}

kernel void eraserKernel(
    const device Params &params [[buffer(0)]],
    const device Stamp *stamps [[buffer(1)]],
    texture2d<float, access::read_write> target [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint w = params.textureWidth;
    uint h = params.textureHeight;
    if (gid.x >= w || gid.y >= h) return;
    
    float2 pos = float2(gid.x, gid.y) + float2(0.5, 0.5);
    
    // Read current pixel value (already premultiplied)
    float4 currentColor = target.read(gid);
    
    // Process all stamps for this pixel
    float eraserCoverage = 0.0;
    
    for (uint i = 0; i < params.stampCount; ++i) {
        Stamp s = stamps[i];
        float coverage = drawEraserCircle(pos, s.center, s.radius);
        
        // Use maximum coverage for eraser (any eraser pixel should fully erase)
        eraserCoverage = max(eraserCoverage, coverage * s.opacity);
    }
    
    // Apply destination-out blending: result = dest * (1 - srcAlpha)
    if (eraserCoverage > 0.0) {
        float4 result;
        result.rgb = currentColor.rgb * (1.0 - eraserCoverage);
        result.a = currentColor.a * (1.0 - eraserCoverage);
        target.write(result, gid);
    }
}
