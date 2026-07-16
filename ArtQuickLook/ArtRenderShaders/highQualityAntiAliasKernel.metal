#include <metal_stdlib>
#include "commonStructs.h"
using namespace metal;

float smootherstep(float edge0, float edge1, float x) {
    // Scale, and clamp x to 0..1 range
    float t = clamp((x - edge0) / (edge1 - edge0), float(0), float(1));

    return t * t * t * (t * (6.0f * t - 15.0f) + 10.0f);
}

// https://en.wikipedia.org/wiki/Smoothstep
//float smootherstep(float edge0, float edge1, float x) {
//    // Scale, and clamp x to 0..1 range
//    x = clamp((x - edge0) / (edge1 - edge0));
//
//    return x * x * x * (x * (6.0f * x - 15.0f) + 10.0f);
//}
//
//float clamp(float x, float lowerlimit = 0.0f, float upperlimit = 1.0f) {
//    if (x < lowerlimit) return lowerlimit;
//    if (x > upperlimit) return upperlimit;
//    return x;
//}

//METAL_FUNC float smoothstep(float edge0, float edge1, float x)
//{
//    float t = clamp((x - edge0) / (edge1 - edge0), float(0), float(1));
//    return t * t * (float(3) - float(2) * t);
//}
//METAL_FUNC float clamp(float x, float minval, float maxval)
//{
//    return __metal_clamp(x, minval, maxval, __METAL_MAYBE_FAST_MATH__);
//}


float4 applyAntiAliasing(float signedDist, float opacity, float4 penColor, bool isEraser, float4 currentColor) {
    // Standard SDF AA:
    // 1.0 when signedDist < -edgeWidth (Deep inside)
    // 0.0 when signedDist > edgeWidth (Outside)
    // 0.5 when signedDist = 0 (Exact Edge)
    
    float edgeWidth = 0.94; // Adjust this: 1.0 is standard, 0.5 is sharper/crisper
    
    // BIAS: Shifts the gradient inwards.
    // 0.0 = Standard SDF (50% opacity exactly on the line)
    // 0.5 = Matches "CPU/Binary" look (50% opacity 0.5px inside the line)
    // 1.0 = Very thin (Stroke appears 1px smaller)
    float bias = 0.5;
    
    // Adding bias makes 'signedDist' effectively larger (less negative), moving the "cut off" point inward.
    float adjustedDist = signedDist + bias;
    
    float coverage = 1.0 - smootherstep(-edgeWidth, edgeWidth, adjustedDist);
    
    float finalAlpha = coverage * opacity * penColor.a;
    
    float4 result;
    if (isEraser) {
        // Destination-out blending
        result.rgb = currentColor.rgb * (1.0 - finalAlpha);
        result.a = currentColor.a * (1.0 - finalAlpha);
    } else {
        // Standard premultiplied alpha blending
        float3 srcPremultiplied = penColor.rgb * finalAlpha;
        result.rgb = srcPremultiplied + currentColor.rgb * (1.0 - finalAlpha);
        result.a = finalAlpha + currentColor.a * (1.0 - finalAlpha);
    }
    
    return result;
}

kernel void highQualityAntiAliasKernel(
    texture2d<float, access::read> distanceField [[texture(0)]],
    texture2d<float, access::read> opacityField [[texture(1)]],
    texture2d<float, access::read_write> target [[texture(2)]],
    constant Params &params [[buffer(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    uint w = distanceField.get_width();
    uint h = distanceField.get_height();
    if (gid.x >= w || gid.y >= h) return;
    
    // Read distance field and opacity
    float4 distField = distanceField.read(gid);
    float4 opacField = opacityField.read(gid);
    
    float signedDist = distField.r;
    float opacity = opacField.a;
    
    // Skip if completely transparent
    if (opacity < 0.001) {
        return;
    }
    
    // Read current color from target (already premultiplied)
    float4 currentColor = target.read(gid);
    
    // Apply high-quality anti-aliasing with proper alpha handling
    float4 finalColor = applyAntiAliasing(signedDist, opacity, params.penColor, params.isEraser, currentColor);
    
    // Write final color
    target.write(finalColor, gid);
}
