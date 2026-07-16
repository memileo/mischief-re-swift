//#include <metal_stdlib>
//#include "commonStructs.h"
//using namespace metal;
//
////float smootherstepNoise(float edge0, float edge1, float x) {
////    float t = clamp((x - edge0) / (edge1 - edge0), float(0), float(1));
////    return t * t * t * (t * (6.0f * t - 15.0f) + 10.0f);
////}
//
//// This kernel runs AFTER segmentSDFMaskKernel, sharing the mask field
//kernel void segmentNoiseCompositeKernel(
//                                        texture2d<float, access::read> distanceField [[texture(0)]],
//                                        texture2d<float, access::read> opacityField [[texture(1)]],
//                                        texture2d<float, access::read_write> target [[texture(2)]],
//                                        texture2d<float, access::sample> noiseTex [[texture(3)]],
//                                        sampler noiseSampler [[sampler(0)]],
//                                        constant Params &params [[buffer(0)]],
//                                        uint2 gid [[thread_position_in_grid]])
//{
//    uint w = target.get_width();
//    uint h = target.get_height();
//    if (gid.x >= w || gid.y >= h) return;
//    
//    // 1. Read the analytical SDF, opacity, and radius
//    float signedDist = distanceField.read(gid).r;
//    float4 opacField = opacityField.read(gid);
//    float baseOpacity = opacField.a;
//    float radius = opacField.g; // Read the radius!
//    
//    if (baseOpacity < 0.001f) return;
//    
//    // 2. Reconstruct the normalized distance (nd) to match the old stamp logic
//    float dist = signedDist + radius;
//    float nd = dist / (radius * 1.2f);
//    
//    float coverage = 1.0f;
//    if (nd > 0.08f) {
//        float t = clamp((nd - 0.1f) / 0.9f, 0.0f, 1.0f);
//        float scurve = t * t * (3.0f - 2.0f * t);
//        float gradual = pow(scurve, 0.9f);
//        coverage = 1.0f - gradual;
//    }
//    
//    // Combine coverage with opacity to get the base smooth mask
//    float maxMask = coverage * baseOpacity;
//    
//    // 3. Noise Injection
//    if (maxMask > 0.0001f) {
//        float noiseVal = 1.0f;
//        if (noiseTex.get_width() > 0) {
//            float2 noiseUV = fract(float2(gid) / (float(noiseTex.get_width()) * params.noiseScale));
//            noiseVal = noiseTex.sample(noiseSampler, noiseUV).r;
//        }
//        
//        float inverted = 1.0f - maxMask;
//        float noiseAdd = (maxMask * 0.94f) + noiseVal;
//        float finalAlpha = 1.0f - saturate(inverted / noiseAdd);
//        
//        // 4. Blend to Target
//        if (finalAlpha > 0.0001f) {
//            float4 dst = target.read(gid);
//            
//            if (params.isEraser) {
//                dst.rgb = dst.rgb * (1.0f - finalAlpha);
//                dst.a = dst.a * (1.0f - finalAlpha);
//            } else {
//                float3 srcPremultiplied = params.penColor.rgb * finalAlpha;
//                dst.rgb = srcPremultiplied + dst.rgb * (1.0f - finalAlpha);
//                dst.a = finalAlpha + dst.a * (1.0f - finalAlpha);
//            }
//            target.write(dst, gid);
//        }
//    }
//}
