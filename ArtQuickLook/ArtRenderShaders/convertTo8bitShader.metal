#include <metal_stdlib>
#include "commonStructs.h"
using namespace metal;

struct VSOut {
    float4 position [[position]];
    float2 uv;
};

vertex VSOut vs_passthrough(uint vertexID [[vertex_id]]) {
    float2 corners[4] = { float2(-1.0,-1.0), float2(1.0,-1.0), float2(-1.0,1.0), float2(1.0,1.0) };
    float2 uvs[4] = { float2(0.0,1.0), float2(1.0,1.0), float2(0.0,0.0), float2(1.0,0.0) };
    VSOut out;
    out.position = float4(corners[vertexID], 0.0, 1.0);
    out.uv = uvs[vertexID];
    return out;
}

fragment float4 fs_convert(VSOut in [[stage_in]],
                           texture2d<float, access::sample> src [[texture(0)]],
                           sampler samp [[sampler(0)]]) {
    // Sample the texture (should already be premultiplied)
    float4 col = src.sample(samp, in.uv);
    
    // For CoreGraphics compatibility, ensure proper premultiplied alpha
    // The texture should already be in premultiplied format
    return col;
}
