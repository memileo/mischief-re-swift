//#include <metal_stdlib>
//#include "commonStructs.h"
//using namespace metal;
//
//struct GPUSplineSegment {
//    float2 p0;
//    float2 p1;
//    float  radius0;
//    float  radius1;
//    float  opacity0;
//    float  opacity1;
//    uint   noiseSeed;
//    uint   padding;
//};
//
//// Computes the analytical shortest distance to a tapered capsule (segment with variable radius)
//kernel void segmentSDFMaskKernel(
//                                 const device Params &params [[buffer(0)]],
//                                 const device GPUSplineSegment *segments [[buffer(1)]],
//                                 const device TileIndex *tileIndices [[buffer(2)]],
//                                 const device uint32_t *tileList [[buffer(3)]],
//                                 texture2d<float, access::write> distanceField [[texture(0)]],
//                                 texture2d<float, access::write> opacityField [[texture(1)]],
//                                 uint2 gid [[thread_position_in_grid]])
//{
//    uint w = params.textureWidth;
//    uint h = params.textureHeight;
//    if (gid.x >= w || gid.y >= h) return;
//
//    // --- TILE LOOKUP ---
//    uint2 tileID = gid / params.tileSize;
//    uint tileIndex = tileID.y * params.tilesPerRow + tileID.x;
//    TileIndex tIdx = tileIndices[tileIndex];
//
//    float2 pos = float2(gid.x, gid.y) + float2(0.5f, 0.5f);
//
//    float minSignedDist = 1.0e6f;
//    float closestOpacity = 0.0f; // Track opacity of the closest segment
//    float closestRadius = 0.0f;
//
//
//    // Iterate only over the segments overlapping this tile
//    for (uint i = 0; i < tIdx.count; ++i) {
//        uint segIdx = tileList[tIdx.start + i];
//        GPUSplineSegment seg = segments[segIdx];
//
//        float2 ab = seg.p1 - seg.p0;
//        float2 ap = pos - seg.p0;
//
//        float abLenSq = dot(ab, ab);
//        float t = 0.0f;
//
//        if (abLenSq > 0.0f) {
//            t = dot(ap, ab) / abLenSq;
//        }
//        t = clamp(t, 0.0f, 1.0f);
//
//        float2 closestPoint = seg.p0 + t * ab;
//        float2 diff = pos - closestPoint;
//
//        float distSq = dot(diff, diff);
//        float dist = fast::sqrt(distSq);
//
//        float radius = seg.radius0 + t * (seg.radius1 - seg.radius0);
//        float opacity = seg.opacity0 + t * (seg.opacity1 - seg.opacity0);
//
//        float signedDist = dist - radius;
//
//        // FIX 1: Tie opacity, radius, and distance together based on the closest segment.
//        if (signedDist < minSignedDist) {
//            minSignedDist = signedDist;
//            closestRadius = radius;
//            closestOpacity = opacity;
//        }
//    }
//
//    // FIX 2: Use a margin that satisfies BOTH the hard-edge AA (0.94f) and the noise kernel (radius * 0.2f)
//    float opacityMargin = max(0.94f, closestRadius * 0.2f);
//
//    // Only carry the opacity forward if the closest segment is within the active margin
//    float finalOpacity = (minSignedDist < opacityMargin) ? closestOpacity : 0.0f;
//
//    distanceField.write(float4(minSignedDist, 0.0f, 0.0f, 1.0f), gid);
//    opacityField.write(float4(0.0f, closestRadius, 0.0f, finalOpacity), gid);
//}
