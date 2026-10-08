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

struct PasteMask {
    float4 inv0; float4 inv1;   // src device -> that mask's selection frame
    float4 rect;                // x, y, w, h
    float4 flags;               // flags.x: 0 = keep (selection), 1 = erase (cut)
};

struct PasteLayerMeta {
    float4 row0;       // dest device -> src device
    float4 row1;
    float  edgeWidth;
    uint   maskCount;  // entries in the mask buffer (buffer index 5)
    uint   pad0;
    uint   pad1;
};

struct CutMeta {
    // Destination GPU/device -> selection frame.
    float4 row0;
    float4 row1;
    
    // x, y, width, height in selection-frame coordinates.
    float4 rect;
    
    float edgeWidth;
    uint padding0;
    uint padding1;
    uint padding2;
};
