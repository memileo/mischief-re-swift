#include <metal_stdlib>
using namespace metal;

struct Stamp {
    float2 center;
    float radius;
    float opacity;
    float rotation;
    uint   noiseSeed;
};

struct Params {
    uint32_t textureWidth;
    uint32_t textureHeight;
    uint32_t tileSize;
    uint32_t tilesPerRow;
    uint32_t stampCount;
    float4 penColor;
    float noiseScale;
    bool isEraser;
    bool isMarker;
};

struct TileIndex {
    uint start;
    uint count;
};
