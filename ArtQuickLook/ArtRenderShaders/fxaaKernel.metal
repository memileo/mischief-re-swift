#include <metal_stdlib>
#include "commonStructs.h"
using namespace metal;

// Enhanced FXAA constants for softer edges
#define FXAA_REDUCE_MIN (1.0/256.0)      // Reduced for more sensitivity
#define FXAA_REDUCE_MUL (1.0/6.0)        // Increased for stronger effect
#define FXAA_SPAN_MAX 12.0               // Increased for wider sampling

// Enhanced alpha-aware FXAA implementation with softer blending
kernel void fxaaKernel(
    texture2d<float, access::sample> src [[texture(0)]],
    texture2d<float, access::write> dst [[texture(1)]],
    sampler samp [[sampler(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint w = src.get_width();
    uint h = src.get_height();
    if (gid.x >= w || gid.y >= h) return;

    float2 inverseVP = float2(1.0 / float(w), 1.0 / float(h));
    float2 uv = (float2(gid) + 0.5) * inverseVP;

    // Sample center and neighboring pixels
    float4 center = src.sample(samp, uv);
    float3 rgbM = center.rgb;
    float alphaM = center.a;
    
    // If center pixel is fully transparent, just write it and return
    if (alphaM < 0.01) {
        dst.write(center, gid);
        return;
    }
    
    // Sample the 4 corners
    float2 uvNW = uv + float2(-1.0, -1.0) * inverseVP;
    float2 uvNE = uv + float2(1.0, -1.0) * inverseVP;
    float2 uvSW = uv + float2(-1.0, 1.0) * inverseVP;
    float2 uvSE = uv + float2(1.0, 1.0) * inverseVP;
    
    float4 rgbNW = src.sample(samp, uvNW);
    float4 rgbNE = src.sample(samp, uvNE);
    float4 rgbSW = src.sample(samp, uvSW);
    float4 rgbSE = src.sample(samp, uvSE);
    
    // Convert to luma (considering alpha for edge detection)
    float3 luma = float3(0.299, 0.587, 0.114);
    float lumaNW = dot(rgbNW.rgb, luma) * rgbNW.a;
    float lumaNE = dot(rgbNE.rgb, luma) * rgbNE.a;
    float lumaSW = dot(rgbSW.rgb, luma) * rgbSW.a;
    float lumaSE = dot(rgbSE.rgb, luma) * rgbSE.a;
    float lumaM = dot(rgbM, luma) * alphaM;
    
    // Also consider pure alpha edges
    float alphaNW = rgbNW.a;
    float alphaNE = rgbNE.a;
    float alphaSW = rgbSW.a;
    float alphaSE = rgbSE.a;
    
    float alphaMin = min(alphaM, min(min(alphaNW, alphaNE), min(alphaSW, alphaSE)));
    float alphaMax = max(alphaM, max(max(alphaNW, alphaNE), max(alphaSW, alphaSE)));
    float alphaRange = alphaMax - alphaMin;
    
    // Find min and max luma
    float lumaMin = min(lumaM, min(min(lumaNW, lumaNE), min(lumaSW, lumaSE)));
    float lumaMax = max(lumaM, max(max(lumaNW, lumaNE), max(lumaSW, lumaSE)));
    float lumaRange = lumaMax - lumaMin;
    
    // Lower threshold for more edge detection
    float edgeThreshold = max(FXAA_REDUCE_MIN, lumaMax * FXAA_REDUCE_MUL);
    if (lumaRange < edgeThreshold && alphaRange < 0.05) {  // Reduced alpha threshold
        dst.write(center, gid);
        return;
    }
    
    // Calculate edge direction (combine luma and alpha edges)
    float2 dir;
    dir.x = -((lumaNW + lumaNE) - (lumaSW + lumaSE)) - ((alphaNW + alphaNE) - (alphaSW + alphaSE)) * 0.8;  // Increased alpha weight
    dir.y = ((lumaNW + lumaSW) - (lumaNE + lumaSE)) + ((alphaNW + alphaSW) - (alphaNE + alphaSE)) * 0.8;  // Increased alpha weight
    
    // Normalize and scale direction
    float dirReduce = max((lumaNW + lumaNE + lumaSW + lumaSE) * (0.25 * FXAA_REDUCE_MUL), FXAA_REDUCE_MIN);
    float rcpDirMin = 1.0 / (min(abs(dir.x), abs(dir.y)) + dirReduce);
    dir = min(float2(FXAA_SPAN_MAX, FXAA_SPAN_MAX),
              max(float2(-FXAA_SPAN_MAX, -FXAA_SPAN_MAX),
              dir * rcpDirMin)) * inverseVP;
    
    // Sample along the edge direction with more aggressive blending
    float4 sampleA1 = src.sample(samp, uv + dir * (1.0/3.0 - 0.5));
    float4 sampleA2 = src.sample(samp, uv + dir * (2.0/3.0 - 0.5));
    float3 rgbA = 0.5 * (sampleA1.rgb + sampleA2.rgb);
    float alphaA = 0.5 * (sampleA1.a + sampleA2.a);
    
    float4 sampleB1 = src.sample(samp, uv + dir * -0.5);
    float4 sampleB2 = src.sample(samp, uv + dir * 0.5);
    
    // More aggressive blending for softer AA
    float3 rgbB = rgbA * 0.3 + 0.35 * (sampleB1.rgb + sampleB2.rgb);  // Changed from 0.5/0.25 to 0.3/0.35
    float alphaB = alphaA * 0.3 + 0.35 * (sampleB1.a + sampleB2.a);  // Changed from 0.5/0.25 to 0.3/0.35
    
    float lumaB = dot(rgbB, luma) * alphaB;
    
    // Choose between rgbA/alphaA and rgbB/alphaB based on luma range
    float4 result;
    if ((lumaB < lumaMin) || (lumaB > lumaMax)) {
        result = float4(rgbA, alphaA);
    } else {
        result = float4(rgbB, alphaB);
    }
    
    // Additional blending with original for softer effect
    float blendStrength = 0.75;  // Increased from implicit blending
    result.rgb = mix(center.rgb, result.rgb, blendStrength);
    result.a = mix(center.a, result.a, blendStrength);
    
    // Ensure we don't create alpha where there was none
    if (alphaM < 0.01) {
        result.a = 0.0;
    }
    
    dst.write(result, gid);
}
