//
//  liveCompositeKernels.metal
//  ArtRenderShaders
//
//  Shaders for the live Metal view (pan / zoom / rotate preview).
//
//  The live path never composites on the CPU with CoreGraphics:
//    1. every layer is rasterised by the existing segment kernels into a scratch
//       texture (already premultiplied rgba8),
//    2. liveCompositeLayerKernel stacks it onto the canvas with the layer opacity,
//    3. livePaperBackgroundKernel bakes paper colour + tiled paper texture +
//       background multiply into a second canvas-sized texture, and
//    4. livePresent{Vertex,Fragment}Shader draws both into the drawable through the
//       user view transform (canvas pixels -> NDC).
//

#include <metal_stdlib>
using namespace metal;

// MARK: - Shared structs

// NOTE: these structs use plain scalars (not float2/float3) on purpose. MSL's float3 is
// 12 bytes (16-byte aligned) while Swift's SIMD3<Float> is 16 bytes, so a
// vector-based Swift struct would lay the following fields out at different offsets than
// the shader expects. Scalars give an identical layout in both languages.

/// Canvas pixels -> clip space (column-major 2x3).
struct LivePresentUniforms {
    float m00, m10;      // image of canvas x
    float m01, m11;      // image of canvas y
    float m02, m12;      // translation
    float canvasW, canvasH;
    float pad0, pad1;
};

struct LivePaperParams {
    float paperR, paperG, paperB;
    float paperStrength;
    float bgR, bgG, bgB;
    float hasTexture;    // 1 = art.paperTextureId != 0
    float tileW, tileH;  // paper tile size in canvas points (0.666 * image size)
    float canvasW, canvasH;
    // canvas pixels -> canvas points, so the paper is anchored to the page and pans /
    // zooms with the view instead of sitting on the glass.
    float m00, m01, m02;
    float m10, m11, m12;
};

// MARK: - Layer stacking

/// Premultiplied source-over with an opacity multiplier, i.e. what
/// `context.setAlpha(opacity); context.draw(layerImage, ...)` does on the CPU.
///   src: read-only texture holding the freshly rasterised layer
///   target: read_write canvas texture (levels > 0 are untouched here)
kernel void liveCompositeLayerKernel(
                                        texture2d<float, access::read>       srcTex  [[texture(0)]],
                                        texture2d<float, access::read_write> target  [[texture(1)]],
                                        constant float &opacity              [[buffer(0)]],
                                        uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;
    if (opacity <= 0.0f) return;

    float4 src = srcTex.read(gid);
    float sa  = saturate(src.a) * opacity;
    if (sa <= 0.0f) return;

    float4 dst = target.read(gid);
    dst.rgb = src.rgb * opacity + dst.rgb * (1.0f - sa);   // src is premultiplied
    dst.a   = sa            + dst.a   * (1.0f - sa);
    target.write(dst, gid);
}

// MARK: - Paper / background

/// Bakes the whole background in one pass:
///   paperTextureId == 0 -> flat background colour
///   paperTextureId != 0 -> paper colour, tiled paper texture at paperStrength,
///                          then multiplied by the background colour
///
/// The tile pattern is evaluated in canvas space (canvas px -> canvas points via the
/// supplied matrix), so it is anchored to the page and pans/zooms with the view.
kernel void livePaperBackgroundKernel(
                                        const device LivePaperParams &params [[buffer(0)]],
                                        texture2d<float, access::sample>   paper   [[texture(0)]],
                                        texture2d<float, access::read_write> target [[texture(1)]],
                                        sampler linearClamp [[sampler(0)]],
                                        uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;

    float2 px = float2(gid) + 0.5f;   // canvas pixel position, y down

    if (params.hasTexture > 0.5f)
    {
        // paper colour first, then the tiled texture over it at paperStrength
        float3 colour = float3(params.paperR, params.paperG, params.paperB);

        float2 doc = float2(params.m00 * px.x + params.m01 * px.y + params.m02,
                            params.m10 * px.x + params.m11 * px.y + params.m12);

        float2 tile = max(float2(params.tileW, params.tileH), float2(1.0f));
        float2 tileUV = fract(doc / tile);
        float4 texel = paper.sample(linearClamp, tileUV);

        colour = mix(colour, texel.rgb, saturate(params.paperStrength) * texel.a);

        // CoreGraphics `.multiply` with an opaque source == src * dst
        colour *= float3(params.bgR, params.bgG, params.bgB);
        target.write(float4(saturate(colour), 1.0f), gid);
    }
    else
    {
        target.write(float4(saturate(float3(params.bgR, params.bgG, params.bgB)), 1.0f), gid);
    }
}

// MARK: - Present

struct LivePresentVaryings {
    float4 position [[position]];
    float2 uv;
};

/// Draws the canvas as a single quad whose four corners are the canvas corners
/// pushed through the view transform, so panning / zooming / rotating is pure
/// vertex work.
vertex LivePresentVaryings livePresentVertexShader(
                                                    uint vertexID [[vertex_id]],
                                                    constant LivePresentUniforms &u [[buffer(0)]])
{
    // Triangle strip, canvas-relative corners (y down).
    float2 corners[4] = { float2(0.0, 0.0), float2(1.0, 0.0), float2(0.0, 1.0), float2(1.0, 1.0) };

    LivePresentVaryings out;
    float2 canvasPos = corners[vertexID] * float2(u.canvasW, u.canvasH);
    float2 clip = float2(u.m00, u.m10) * canvasPos.x
                + float2(u.m01, u.m11) * canvasPos.y
                + float2(u.m02, u.m12);
    out.position = float4(clip, 0.0, 1.0);
    out.uv = corners[vertexID];
    return out;
}

/// The canvas is premultiplied over an opaque background texture.
fragment float4 livePresentFragmentShader(
                                        LivePresentVaryings in [[stage_in]],
                                        texture2d<float> canvasTex [[texture(0)]],
                                        texture2d<float> backgroundTex [[texture(1)]],
                                        sampler linearClamp [[sampler(0)]])
{
    float4 canvas = canvasTex.sample(linearClamp, in.uv);
    float4 bg     = backgroundTex.sample(linearClamp, in.uv);

    float3 rgb = bg.rgb * (1.0f - canvas.a) + canvas.rgb;   // canvas is premultiplied
    return float4(saturate(rgb), 1.0f);
}