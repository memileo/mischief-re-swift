# Live view — performance optimisation task

Self-contained brief for whoever implements this (fresh session, possibly a different
model). Everything below was measured; nothing here is a guess. **Do not start until you
have read §0 and §6.**

---

## 0. The task in one paragraph

The interactive live view re-rasterises the whole visible document on every view change
(pan / zoom / rotate). On a one-layer document with **321 611 segments across 2 214
strokes** a frame at `--viewport 1920x1080` takes **433 ms**, of which **333 ms is GPU
time**. The GPU cost is *not* the distance-field maths: it is that **one dispatch per
stroke covers the whole canvas**, and the kernel immediately returns for tiles the stroke
does not touch. The fix is to dispatch each stroke **only over the tiles it actually
covers**, turning work from `strokes × canvas` into `strokes × ink`.

Nothing else in the live path is worth optimising first: the CPU stages together are
~20 % of the frame, and the geometry cache build is a one-off 170 ms.

---

## 1. Current numbers (reproduce them first)

`art/kaos.art` — 1 layer, 2 214 strokes, 321 611 segments, 19.6 MB of geometry:

```
$ swift build -c release
$ .build/release/art2png --live-view --viewport 1920x1080 art/kaos.art
Live view: cached 321611 segments across 1 layer(s)
Live view: cache built in 170 ms
Live view: 433 ms total (bin 59, encode 19, gpu 333, paper 1) — 2214 strokes / 321611
segments, 1 layers cached, 0 rebuilt, 0 culled
```

That `Live view: … total (bin …, encode …, gpu …)` line is printed by
`Renderer.livePathTiming` (set by art2png automatically for `--live`/`--live-view`) and is
your primary measurement. Stage breakdown:

| stage | ms | what it is |
|---|---|---|
| `bin` | 59 | CPU: camera re-map of cached geometry + tile binning |
| `encode` | 19 | CPU: writing the Metal dispatches |
| `gpu` | 333 | `waitUntilCompleted` — the dispatches themselves |
| `paper` | 1 | paper/background pass |

Reference points: the **static** CoreGraphics/GPU path renders the same document end to end
(parse + flatten + rasterise + PNG) in ~1.5 s, and the cache build plus camera re-map cost
213 ms + 8 ms on Linux (`ART_LIVE_PROFILE=1 swift test --filter LiveProfileTests`). So the
CPU is fine and the GPU dispatches are the whole story.

**Target:** `gpu` under ~30 ms for the fit view of this document (i.e. a 10× improvement at
minimum; the theoretical win is much larger). If you do not reach that, say so rather than
declaring success — the measurement line is the deliverable.

---

## 2. Why the GPU is slow, precisely

`MetalRenderer_LiveCompositing.renderCachedLayerIntoLiveCanvas` encodes **one dispatch per
stroke** into a single command buffer. Every dispatch is:

```swift
encoder.dispatchThreadgroups(
    Self.liveGroups(width: width, height: height),   // whole canvas
    threadsPerThreadgroup: Self.liveThreads)        // 32 × 32
```

and `segmentAACompositeKernel` in `ArtQuickLook/ArtRenderShaders/segmentKernels.metal`
starts with:

```metal
uint2 tileID = gid / params.tileSize;
uint tileIndex = tileID.y * params.tilesPerRow + tileID.x;
TileIndex tIdx = tileIndices[tileIndex];   // 8-byte load
// … then `for (i in 0..<tIdx.count)` — nothing when count == 0
```

So for a stroke covering a few tiles we still launch `1920×1080 / (32×32) = 2 040`
threadgroups, all but a handful of which do one 8-byte load and return. 2 214 strokes ×
2 040 threadgroups ≈ **4.5 M threadgroup launches per frame** whose only work is to find
out they have nothing to do.

The information needed to avoid this **already exists**: `buildSegmentTileIndices` computes
each segment's tile range and throws away the *per-stroke* bounding tile range. Capture it
and dispatch only that range.

(The threadgroup shape was already raised from 8×8 to 32×32, which cut launches 16×; there
is no more juice in that direction.)

---

## 3. What to implement

### 3.1 Capture the tile range per stroke

`MetalRenderer_Dispatch.buildSegmentTileIndices` already walks the segments and knows each
segment's tile range. Extend it (or add a sibling function) to also return the **union**
of the segment ranges:

```swift
func buildSegmentTileIndices(...) -> (tiles: [TileIndex], tileList: [UInt32],
                                     minTile: (x: Int32, y: Int32),
                                     maxTile: (x: Int32, y: Int32))
```

The union is bounded by the texture size already (`maxTileX = min(tilesPerRow-1, …)`), so it
can never run off the edge. A stroke whose tile list ends up empty (fully off screen) is
already skipped.

Store the range in `MetalRenderer.LiveStrokeBin` (a private struct in
`MetalRenderer_LiveCompositing.swift`) next to the arena offsets.

### 3.2 Dispatch only that range

Add a **live-only** kernel variant rather than changing the shared one. The kernel needs to
know where its grid starts; that has to arrive somehow, and the two options are:

**(a) Recommended — new kernels + new params struct.**
Add to `ArtQuickLook/ArtRenderShaders/liveCompositeKernels.metal` (or a new
`liveSegmentKernels.metal`, added to the same shader target):

```metal
struct LiveStrokeParams {
    uint2 tileOrigin;   // first tile of this stroke's range
    uint  tilesPerRow;
    uint  tileSize;
    uint  textureWidth;
    uint  textureHeight;
    uint  stampCount;
    float4 penColor;
    float noiseScale;
    uint  flags;        // bit0 = isEraser, bit1 = isMarker  (see §4!)
};

kernel void liveSegmentAACompositeKernel(
    constant LiveStrokeParams &params [[buffer(0)]],
    const device GPUSplineSegment *segments [[buffer(1)]],
    const device TileIndex *tileIndices [[buffer(2)]],
    const device uint32_t *tileList [[buffer(3)]],
    texture2d<float, access::read_write> target [[texture(0)]],
    uint2 gid [[thread_position_in_grid]])
{
    if (gid.x >= params.textureWidth || gid.y >= params.textureHeight) return;
    uint2 tileID = params.tileOrigin + gid / params.tileSize;   // ← the only change
    uint tileIndex = tileID.y * params.tilesPerRow + tileID.x;
    … identical body to segmentAACompositeKernel, with params.isMarker etc. read from flags
}
```

and a `liveSegmentNoiseCompositeKernel` twin if you keep the noise path working. Then
`MetalRenderer.encode(stroke:…)` builds that params struct, and dispatches:

```swift
let groupsX = Int(bin.maxTile.x - bin.minTile.x) + 1
let groupsY = Int(bin.maxTile.y - bin.minTile.y) + 1
encoder.dispatchThreadgroups(
    MTLSize(width: groupsX * threadsPerTileX, height: groupsY * threadsPerTileY, depth: 1),
    threadsPerThreadgroup: …)
```

Keep the whole-canvas early-out in the kernel: the stroke's range is the bbox of the
segments' *padded* ranges, so a threadgroup can still land on an empty tile near the
border — the `tIdx.count == 0` path must stay.

**(b) Alternative — one extra buffer instead of new kernels.** Keep
`segmentAACompositeKernel` and bind an 8-byte `uint2 tileOrigin` at `buffer(4)`. This
touches the *static* dispatch path too (it would have to bind something at index 4 there,
otherwise Metal validation rejects the dispatch), so it is riskier. Only do this if (a)
proves impossible.

### 3.3 Thread-per-tile vs thread-per-pixel

Two valid mappings; pick one and measure:

* **Thread per pixel** (minimal change): the grid is `(tilesX × threadsPerTile) × (tilesY ×
  threadsPerTile)` with 32×32 threads, i.e. exactly the old dispatch restricted to the
  stroke's tiles. Keeps `gid → pixel` identical to today.
* **Thread per tile** (fewer threads, more work each): `gid` is the tile index, each thread
  loops the 64×64 pixels of its tile. Fewer launches still, but a rewrite of the inner
  loop and worse load balance on small strokes.

Thread-per-pixel is the recommended starting point: it is a 10-line kernel diff.

---

## 4. Constraints — read before writing MSL or Swift

These are the things that have broken this codebase before. Violating them causes silent
corruption or wrong pixels, not compile errors.

1. **Never change the shared `Params` struct** (`ArtRenderShaders/commonStructs.h`) for this
   work. Its Swift counterpart is `Renderer.Params`, and the two layouts must match
   byte-for-byte: MSL lays out `bool` as 4 bytes and aligns `float4` to 16, while Swift's
   `Bool` is 1 byte, so any hand-written padding has to be reproduced exactly. A mismatch
   does not fail loudly — it feeds garbage into the kernel. Use a new struct (3.2a).
   Note: the existing struct encodes the flags as `bool isEraser; bool isMarker;`; in your
   new struct prefer `uint flags` with explicit bits so both compilers agree.
2. **Uniform structs use scalars only.** MSL `float3` is 12 bytes, Swift `SIMD3<Float>` is
   16. Pack `float2`/`float4` fields as pairs/quads of `Float`s, as `LivePresentUniforms`
   and `LivePaperParams` do.
3. **metal2 / macOS 12.** The app's deployment target is macOS 12, so Metal 2 only. No
   mesh shaders, no argument buffers tier 2, no `MTLRenderPipelineState` conveniences that
   arrived later. Indirect dispatch (`dispatchThreadgroups(indirectBuffer:…)`,
   `MTLIndirectCommandBuffer`) *is* Metal 2 and therefore allowed — it is a reasonable
   alternative to packing the range into params, but the params approach is simpler.
4. **Do not edit `ArtQuickLook/ArtQuickLook.xcodeproj/project.pbxproj`.** If you need a new
   *shader* file in the shader target, it cannot be added without a project change — so put
   new kernels in the **existing** `ArtQuickLook/ArtRenderShaders/liveCompositeKernels.metal`.
   If you need a new Swift file in `Sources/ArtRenderLibrary`, add it to the `sources:`
   array in `Package.swift` and say so in your summary — a stale manifest is the usual
   cause of "cannot find X in scope" in the Xcode build. Never add files to the Xcode
   project itself.
5. **One render in flight, ever.** `LivePreviewSession` guarantees it. That is what makes it
   safe to reuse `liveStaging` / `liveArena` across frames and to keep presenting the
   previous canvas while the next one is being written (the canvas is double-buffered:
   `MetalRenderer.beginLiveFrame()`). Do not introduce a second concurrent render.
6. **The geometry arena layout.** Each stroke's segments / tile indices / tile list live at
   256-byte-aligned offsets in one buffer, and every dispatch binds its own `offset:` into
   it. Adding fields to `LiveStrokeBin` is fine; moving existing slices is not (the static
   path shares the *other* buffers and relies on waiting per command buffer — never do that
   inside a batched command buffer).
7. **Orientation is settled.** `LiveViewTransform.clipMatrix` maps the y-down canvas to
   clip space with `ndc.y = 1 - viewY/viewH * 2`, and there is deliberately **no** mirror in
   the present pass. Anything you do must not reintroduce one; canvas row 0 is the
   document's top row (verified, see `LIVE_VIEW.md` §9.6).
8. **Transform composition order.** `a.concatenating(b)` applies **a first**, then b. The
   `camera ∘ base ∘ layer` ordering in `LiveRenderCache` is load-bearing — reversing it put
   pasted content "on a different depth plane" (§9.2).

---

## 5. Out of scope — do not implement

These were considered and explicitly deferred. Implementing them now will muddy the
measurement and may not help at all:

* **Half-resolution frames while interacting.** Tried as an option and dropped: on
  medium/large documents even half resolution is too slow to be worth the blur, and it
  competes with the real fix above.
* **Smaller tiles (32 px).** The static path moved from 32 → 64 px tiles because tile
  *creation* got slower and the gain did not materialise on an AMD discrete GPU. There is no
  Apple-silicon hardware available to test on, and half-float experiments on the test GPU
  were slower as well. Do not touch `MetalRenderer.tileSize` (64).
* **GPU tile binning** (build the tile lists with atomics on the GPU instead of on the CPU).
  Real, and it would remove the 59 ms `bin` stage and the arena entirely — but it is a
  second, larger project and does nothing about the dominant cost. Only after this one.
* **Caching the distance field / SDF.** Not possible across frames: the field is evaluated
  per destination pixel for the *current* camera, and every interactive frame changes the
  camera. What is reusable across frames — the flattened segment geometry — is already
  cached (`LiveRenderCache`).
* **"Render only the new edge tiles while panning".** Tempting (pure pan is a translation,
  so most tiles are unchanged) but see §6.
* **Transform the existing raster instead of re-rendering.** Last resort only; it is what
  the interactive mode exists to avoid.

---

## 6. On incremental edge-tile rendering (asked about, answered)

Idea: during a pan, keep the tiles already rasterised and only re-render the strip that
scrolled in, feeding the camera offset into tile creation.

It would work for pure translation, but with the per-stroke tile-range dispatch the cost it
saves is already small: a pan renders the same number of ink pixels either way (a few
strokes enter, a few leave), and what you would save is only the *dispatch* count for the
unchanged ones. Once each stroke dispatches only over its own tiles, the remaining frame is
tens of milliseconds and this buys very little for a lot of state (which tiles are valid
under which camera, invalidation on zoom/rotate/resize/camera-shape changes, partial
re-readback or a persistent GPU buffer per viewport region). Do not build it. If the
measurement after this task still shows hundreds of milliseconds, revisit with numbers in
hand.

---

## 7. How to build, test, measure

**Build (both platforms must stay green):**

```
swift build -c release                 # Linux/macOS library + art2png
swift test                             # 34 tests, 1 skipped (opt-in profiler)
ART_LIVE_PROFILE=1 swift test --filter LiveProfileTests    # CPU stage costs
```

**The live path is Metal-only**, so it cannot run on Linux. To exercise it:

```
Scripts/build-metallib.sh --from-xcode          # or --install <path>, see --help
.build/release/art2png --live-view --viewport 1920x1080 art/kaos.art
```

`Scripts/build-metallib.sh --verify-only` must list every kernel, including any you added
(add your new names to `REQUIRED_KERNELS` in that script — it is how a half-installed
metallib gets caught instead of silently falling back to the static path).

**Measure:**

* `art2png --live-view` prints the `bin / encode / gpu / paper` breakdown (that is the
  number this task is judged on).
* For kernel-level truth: run the **ArtQuickLook** app (macOS 12-compatible, no project
  change needed for it any more), *File ▸ Open .art-file…*, and attach **Instruments ▸
  Metal System Trace** to the process. Look at `liveSegment*CompositeKernel`: grid size
  should now be a few threadgroups per stroke instead of 2 040.
* Debug ▸ Metal ▸ Capture Frame works against that window for shader-source stepping.

**Regression checks that must still pass:**

* `--live` (single-raster mode) renders the same image as before.
* A paste/merge document (`art/complex2.art`, which reports "7 rebuilt per frame") renders
  identical geometry before and after your change.
* Overlaid strokes composite in document order — the cached path dispatches one kernel per
  stroke precisely so overlapping strokes blend like the static path. Do not batch strokes
  into a single dispatch to save launches; that changes overlap semantics and *will* be
  visible.
* `swift test` still green; add a unit test for anything you can test without a GPU (e.g.
  the tile-range union: construct segments at known positions, assert the returned range).

---

## 8. Background reading

* `LIVE_VIEW.md` §9.1–§9.6 — the live path's architecture, the composition-order bug, the
  arena growth bug, the orientation investigation, and what was already measured.
* `LIVE_VIEW.md` §9.2(c) — the original analysis of the per-stroke dispatch cost.
* `Sources/ArtRenderLibrary/MetalRenderer_LiveCompositing.swift` — `bin`, `encode`,
  `staging`, the arena.
* `Sources/ArtRenderLibrary/MetalRenderer_Dispatch.swift` — `buildSegmentTileIndices`.
* `ArtQuickLook/ArtRenderShaders/segmentKernels.metal` — `segmentAACompositeKernel`,
  `segmentNoiseCompositeKernel`, and `commonStructs.h` for `Params`/`TileIndex`.