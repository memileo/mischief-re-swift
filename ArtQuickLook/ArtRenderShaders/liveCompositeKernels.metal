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
    float tileW, tileH;  // base paper tile size in canvas points
    float canvasW, canvasH;
    // canvas pixels -> canvas points. *Full matrix, translation included*
    // (m02/m12): the pattern is anchored to the document space, so it translates
    // with the view and zooms around the camera's zoom point, exactly like the
    // strokes. Callers add offset below as a phase nudge.
    float m00, m01, m02;
    float m10, m11, m12;
    // Recursive tile blending: the fine level's apparent screen size is
    // referenceScale * (paper tile) at the reference state (viewRelZoom == 0), and
    // sweeps minScale..maxScale per octave of magnification by crossfading two
    // tile levels one octave apart (B is the finer one, half the fine tile, so
    // consecutive bands hand off on the same grid with no pop).
    float minScale, maxScale;
    float referenceScale;
    // log2 of the document's on-screen magnification relative to the reference
    // state (0 == saved view baked at 1:1).
    float viewRelZoom;
    // Pattern offset in document points. Tunable only - never derived from a view
    // translation.
    float offsetX, offsetY;
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
/// To keep the texture's apparent screen size within [minScale, maxScale] of its
/// base size (recursive / LOD blending), two power-of-two tile
/// levels are sampled and crossfaded based on the current view scale.
kernel void livePaperBackgroundKernel(
                                        const device LivePaperParams &params [[buffer(0)]],
                                        texture2d<float, access::sample>   paper   [[texture(0)]],
                                        texture2d<float, access::read_write> target [[texture(1)]],
                                        sampler paperSampler [[sampler(0)]],
                                        uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;

    // Canvas pixel position, y down. The +1/3 doc phase lands the tile-boundary
    // column on its texel centre (full depth, as in the refs) while dash lines
    // straddle between texels (half depth, as in the refs).
    float2 px = float2(gid) + (1.0f / 3.0f);

    if (params.hasTexture > 0.5f)
    {
        // paper colour first, then the tiled texture over it at paperStrength
        float3 colour = float3(params.paperR, params.paperG, params.paperB);

        // Document position: full mapping (translation included, so the pattern is
        // glued to the page) + tunable offset.
        float2 doc = float2(params.m00 * px.x + params.m01 * px.y + params.m02,
                            params.m10 * px.x + params.m11 * px.y + params.m12)
                   + float2(params.offsetX, params.offsetY);

        float2 baseTile = max(float2(params.tileW, params.tileH), float2(1.0f));

        // Recursive tile blending. The fine level's apparent size
        // sweeps [minScale, maxScale] of its base size once per octave of view
        // magnification: at band position f it is minScale * (maxScale/minScale)^f.
        // Two doc-anchored levels one octave apart are sampled at that apparent
        // size and crossfaded by f; the finer level (half the fine tile) carries
        // the larger weight as f grows, and because maxS == 2*minS the handoff
        // between bands lands exactly on the resumed level's grid.
        float minS = max(params.minScale, 1e-4f);
        float maxS = max(params.maxScale, minS * 1.001f);
        float L  = log2(maxS / minS);           // one blend band, in log2 units
        float u  = params.viewRelZoom;          // log2 magnification since reference
        float t  = log2(max(params.referenceScale, 1e-6f) / minS) / L + u / L;
        float band = floor(t);
        float f = t - band;                     // 0 -> minScale, 1 -> maxScale

        float fineRatio = exp2(L * f) * minS;   // apparent tile size / paper width

        // Screen pixels per canvas point (uniform scale of the mapping).
        float docPerPx = max(length(float2(params.m00, params.m10)), 1e-6f);

        // Tile sizes in document points such that the fine level appears at
        // fineRatio * paperW screen pixels at the current mapping. Level B is the
        // next *finer* octave (half the fine tile): every band then hands off on
        // the same grid as the band it replaces, so zooming through a band
        // boundary never pops the pattern (zoom in: B(b) == A(b+1); zoom out:
        // A(b) == B(b-1)).
        float2 tileA = fineRatio * baseTile * docPerPx;
        float2 tileB = tileA * 0.5f;

        // Sample with repeat wrap. Tile sizes are document-anchored (mag cancels
        // inside a band), so the sampled grid is frozen while zooming and does not
        // shimmer; base-level linear sampling matches the reference render's
        // feature depths (trilinear mip blending washed dash/seam contrast out).
        float4 texelA = paper.sample(paperSampler, doc / tileA);
        float4 texelB = paper.sample(paperSampler, doc / tileB);
        float4 texel  = mix(texelA, texelB, f);

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
