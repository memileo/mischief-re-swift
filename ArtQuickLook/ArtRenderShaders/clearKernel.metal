#include <metal_stdlib>
using namespace metal;

kernel void clearKernel(
    texture2d<float, access::write> target [[texture(0)]],
    uint2 gid [[thread_position_in_grid]]
) {
    uint width = target.get_width();
    uint height = target.get_height();
    if (gid.x >= width || gid.y >= height) return;
    
    // Clear to fully transparent (NON-premultiplied format)
    float4 clear = float4(0.0, 0.0, 0.0, 0.0);
    target.write(clear, gid);
}
