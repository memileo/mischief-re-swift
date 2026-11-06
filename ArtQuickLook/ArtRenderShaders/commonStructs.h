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
    float noiseOffsetX;
    float noiseOffsetY;
    bool isEraser;
    bool isMarker;
    // `ART_DEBUG_SEG_COLORS`: paint each segment with its shape-type colour and composite
    // it on its own (see debugSegmentColor in segmentKernels.metal). Off in normal use.
    bool debugSegmentColors;
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

// Destination tile box a paste dispatch covers (buffer index 6). The static path
// passes (0, 0, tilesPerRow) and dispatches the whole canvas, so its pixels and
// tile indexing are unchanged. The live path dispatches only the paste's box:
// `gid` is then box-local and gets offset by originTile * tileSize.
struct PasteBoxParams {
    uint originTileX;
    uint originTileY;
    uint boxTilesPerRow;
    uint pad;
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
