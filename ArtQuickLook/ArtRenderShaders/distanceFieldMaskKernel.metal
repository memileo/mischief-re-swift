#include <metal_stdlib>
#include "commonStructs.h"
using namespace metal;

kernel void distanceFieldMaskKernel(
                                    const device Params &params [[buffer(0)]],
                                    const device Stamp *stamps [[buffer(1)]],
                                    const device TileIndex *tileIndices [[buffer(2)]], // New buffer
                                    const device uint32_t *tileList [[buffer(3)]],      // New buffer
                                    texture2d<float, access::write> distanceField [[texture(0)]],
                                    texture2d<float, access::write> opacityField [[texture(1)]],
                                    uint2 gid [[thread_position_in_grid]])
{
    uint w = params.textureWidth;
    uint h = params.textureHeight;
    if (gid.x >= w || gid.y >= h) return;
    
    float2 pos = float2(gid.x, gid.y) + float2(0.5, 0.5);
    
    float minSignedDist = 1.0e6;
    float maxOpacity = 0.0;
    
    // --- TILE LOOKUP ---
    // Calculate which tile this pixel belongs to
    uint2 tileID = gid / params.tileSize;
    uint tileIndex = tileID.y * params.tilesPerRow + tileID.x;
    
    // Fetch the list of stamps overlapping this tile
    TileIndex tIdx = tileIndices[tileIndex];
    // ------------------
    
    // Iterate only over the stamps relevant to this tile
    for (uint i = 0; i < tIdx.count; ++i) {
        // Lookup the actual stamp index from the tile list
        uint stampIdx = tileList[tIdx.start + i];
        Stamp s = stamps[stampIdx];
        
        float2 offset = pos - s.center;
        
        // Optimized Math
        float distSq = dot(offset, offset);
        float radiusSq = s.radius * s.radius;
        
        if (distSq < radiusSq) {
            maxOpacity = max(maxOpacity, s.opacity);
        }
        
        float dist = fast::sqrt(distSq);
        float signedDist = dist - s.radius;
        
        // Define a margin for AA (match the edgeWidth in the AA shader)
        float aaMargin = 0.94;
        
        if (signedDist < aaMargin) {
            maxOpacity = max(maxOpacity, s.opacity);
        }
        
        minSignedDist = min(minSignedDist, signedDist);
    }
    
    distanceField.write(float4(minSignedDist, 0.0, 0.0, 1.0), gid);
    opacityField.write(float4(0.0, 0.0, 0.0, maxOpacity), gid);
}
