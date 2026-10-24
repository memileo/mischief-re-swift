# Live splat composite — design + round notes

**Read this first if the context was compacted.**

Status: splat implemented; the layer-composite vanish bug fixed; the zoom-in dot
de-duplication fixed; the splat cost model added so the splat is only used when it is
predicted to be *cheaper*, not merely exact. Linux-green (90 tests, 1 skipped, 0
failures) and the `#if os(macOS)` files were syntax-checked with a forced macOS parse.
Exactness (kaos gate + splat A/B) still needs the gated Mac run. Committed: the v4
bitonic sort and the splat kernels/pipelines (`ed0d082`). Uncommitted: the layer-composite
fix, the dot fix, the cost model, the script fixes, and this note.

## Why (the diagnosis up to now)

Measured `livebin` stages (release, 1920×1080, `ART_LIVE_BINTIME=1`):

| view | xform | scatter | sort | render+comp |
|---|---|---|---|---|
| kaos regular | 9.3 | 0.9 | **0.7** | **36.4** |
| kaos zoom-out | 8.8 | 0.7 | 4.7 | **33.6** |
| dots zoom 20 | 7.2 | 8.6 | **1.5** | **97.0** |
| logo_03 zoom-out L1 | 3.5 | 0.4 | 2.6 | **65.5** |

The v4 bitonic sort killed the sort stage (was 17–24 / 10 / 930 ms). What is left is
`render+comp`, and it is *flat* from zoom-in to zoom-out even though the pixel count
collapses ~1000×.

Root cause of the flatness: the per-tile walk costs
`Σ_tiles (pixels in tile) × (entries in tile)`, which by double counting equals
`Σ_segments (pixels in the segment's tile-EXPANDED box)`. At tile=16 a 2 px stamp still
costs up to 256 px per segment ⇒ kaos zoom-out spends ~112 M cheap iterations on only
**11.5 K pixel-threads**: the GPU is thread-starved and the work is ~85× the ink area.

## The fix: splat (segment-parallel) instead of walk (pixel-parallel)

Cost `Σ_segments (pixels within the segment's prune disk)` — the ink area, ~1.3 M for
kaos zoom-out — and parallelism `segments × disk` (a few M threads). ~85× fewer ops
**and** full occupancy.

### Exactness argument (the whole correctness proof)

The walk evaluates segment `s` at pixel `p` iff `s` is in `p`'s tile list and
`liveSegDist(p, p1, p2) ≤ padding1 + margin` (the prune; `padding1` is the camera-scaled
shape reach and `margin` is the kernel's device-pixel coverage tail — 0.5 px for AA, the
noise falloff otherwise). Pixels that fail the prune contribute exactly 0 to `curMax`, so
the walk's output is a function of only

    W(s) = { p ∈ range(s) : liveSegDist(p, s) ≤ prune(s) }

`SegmentPrune.radius` is defined so that `dist(chord) > prune ⇒ no contribution`, so the
disk contains every pixel that can stamp anything, and (for `radiusFactor ≤ 1`)
`prune ≤ 1.4·rMax_dev + 1 = pad`, so `dist ≤ prune ⇒ p ∈ box(s) ⊆ range(s)` — the disk
does **not depend on the tile size at all**. The splat kernel iterates exactly that disk.
The block-box prune is also safe for `rf ≤ 1` (its pad `1.4·blockMaxRadius·rf + 3.5 ≥
prune`), and, since the SDF's ink reach is covered by the block box, a pixel with
`stamped > 0` is never block-skipped by the walk either.

Per pixel, per stroke the walk keeps `curMax = max over the stroke's segments of
stamped`; a per-`(pixel, stroke)` `atomic_max` is identical (max is commutative;
`stamped` depends only on `(segment, pixel)`). `liveSplatStamped` and the composite's
per-stroke alpha maths are **verbatim copies** of the walk kernels' (AA + noisy), so
values are bit-identical. If a future edit changes one, change both.

### Ordering (why batches)

Strokes must composite in document order, but the atomic reduce erases order *within* a
stroke only. So the visible strokes are processed in **batches of `B`** (visible order).
A batch exposes `B` slots per pixel (`splatMax[slot*pixelCount + idx]`, slot-major), the
splat kernel atomically maxes the batch's segments into them, then the composite kernel
replays those `B` slots **in slot order** into a persistent per-pixel `acc` (`splatAcc`).
Batches run in order ⇒ the final `acc` is the ordered composite. The composite kernel
zeroes each slot it reads, so the only clear is one initial blit fill.

All dispatches live in one compute encoder (same as the walk path's CB2), relying on
in-encoder dispatch ordering — which the existing scatter→sort→merge chain already does.

### Scope / fallbacks

- `ART_LIVE_SPLAT=0` forces the walk (A/B and tripwire).
- Splat is used only when `radiusFactor ≤ ART_LIVE_SPLAT_MAX_RF` (default 1.0) **and**
  `boxPixels × B ≤ ART_LIVE_SPLAT_SLOT_BUDGET` (default 16 M slots). Regular zoom is
  excluded by the budget (2 M px × 128), deep zoom-in by `radiusFactor`; both keep the
  walk. Missing splat pipelines fall through to the walk automatically.
- Markers / cuts already force the CPU path (unchanged). Noisy layers use the same
  composite kernel with the noisy alpha branch and the same noise sampling.

## Files

- `ArtQuickLook/ArtRenderShaders/segmentKernels.metal`: `LiveSplatParams`,
  `liveSplatStamped`, `liveSplatKernel`, `liveSplatCompositeKernel`,
  `liveSplatWriteKernel`.
- `Sources/ArtRenderLibrary/RendererTypes.swift`: `LiveConfig.splat*` knobs.
- `Sources/ArtRenderLibrary/MetalRenderer.swift`: pipeline vars +
  `LiveBinRefLayer` splat buffers (`splatMax`, `splatAcc`, `visOrd`, `visStrokeIDsBuf`)
  + `liveSplatDummyTexture`.
- `Sources/ArtRenderLibrary/MetalRenderer_LiveCompositing.swift`: pipeline
  registration, `LiveSplatParams` mirror, `ensureSplatBuffers`, `splatNoiseBinding`,
  and the `useSplat` branch (`encodeSplat` inline).
- `Tests/ArtRenderLibraryTests/TileUnionTests.swift`: `testSplatConfigDefaultsAndClamps`,
  `testSplatPruneDiskInsideBoxAtZoomOut`, `testSplatWideBranchOnlyForCurvedSplinesAtZoomIn`.

## Next round — the Mac run (in order)

```sh
# 0. rebuild the metallib (new kernels) — Xcode scheme copy or Scripts/build-metallib.sh — then:
swift build -c release

# 1. tripwire once, splat off, walk sanity
ART_LIVE_BINCHECK=1 .build/release/art2png --live-view --viewport 1920x1080 art/kaos.art

# 2. kaos gate (must stay ~2 bytes off art/kaos.png)
.build/release/art2png --live-view --viewport 1920x1080 art/kaos.art   # then diff vs art/kaos.png

# 3. identity A/B — splat ON (default) vs ART_LIVE_SPLAT=0, byte-compare the PNGs
#    views: kaos regular, kaos zoom-out, logo zoom-out (all layers), complex zoom-out,
#    dots zoom 20 (must be walk==walk: rf>1, budget), kaos 0.05
#    (use Scripts/stroke-prune-ab.sh's pattern, or per-view art2png + cmp)

# 4. BINTIME with splat on
ART_LIVE_BINTIME=1 .build/release/art2png --live-view --viewport 1920x1080 <doc>   # report livebin lines
```

Expected: zoom-out `render+comp` drops and the line ends with `[splat Nb×B]`; regular zoom
and dots zoom-in keep walking (no `[splat …]` suffix). Measured at zoom 0.21 (24733 segs,
484 tiles, `splat 4×128`): ≈16 ms vs the walk's ≈34 ms, i.e. ~2× — not the order of
magnitude guessed here. The composite floor is `pixels × visibleStrokes`, so the win grows
as the box shrinks but is bounded by the visible-stroke count (see Round 2b).
The identity step is the real gate: any mismatch means the prune-disk ⇔ walk-contributing
-set argument is wrong somewhere — report the view and I'll re-derive.

## Open problems / next levers

1. **Regular-zoom `render+comp` (~31–36 ms) is untouched** (budget-excluded). Options:
   splat at *tile* granularity for regular zoom, or attack the walk's bandwidth.
2. **dots zoom-in 97 ms** is the huge-stamp regime (walk already near-optimal per-op);
   needs a different idea (e.g. per-pixel SIMD entry reduction). Last on the list.
3. **`xform` 7–9 ms for 2 K–321 K segments** still looks like fixed overhead (BINTIME
   window or the CB1 wait). One CLI capture of `liveBinTransformCountKernel` resolves it.
4. If splat wins, raise `ART_LIVE_SPLAT_SLOT_BUDGET` / lower `ART_LIVE_SPLAT_MAX_RF`
   progressively toward regular zoom, gating each step.
5. `ART_LIVE_SPLAT_BATCH` (default 128) trades dispatches for composite-loop width; the
   total composite work (pixels × visible strokes) is independent of it.

---

# Round 2 — the installed metallib predated the splat kernels, and the zoom-in dot blow-up

## The measurements above defaulted to the walk

The round-1 Mac run reported:

```
Live view: liveSplatKernel not in metallib — CPU binning for now
Live view: liveSplatCompositeKernel not in metallib — CPU binning for now
Live view: liveSplatWriteKernel not in metallib — CPU binning for now
```

So `useSplat` was false on every layer and the whole run was the walk — `render+comp`
36/34/30/15 ms are *unchanged walk* numbers, and the "splat A/B IDENTICAL" result was
vacuous (walk vs walk). The installed `Sources/ArtRenderLibrary/ArtRenderShaders.metallib`
contains `liveBinChunkSortV4Kernel` but no `liveSplat*`: it had been built from an older
`segmentKernels.metal`, so the new kernels were simply not in the file to load. That was a
rebuild/source-copy slip — not a code path and not a tooling fault. Nothing was wrong;
there was just nothing new in the library.

Building the metallib in Xcode is fine: the `ArtRenderShaders` scheme's run script copies
it next to the sources, which is where the runtime looks. `Scripts/build-metallib.sh` is an
alternative, not a requirement. What the script now adds is a check: `LIVE_KERNELS` lists
the V4 sort and the three splat kernels, so a metallib missing any of them is reported as
`MISSING:` and refused. The renderer also prints a loud one-liner when the splat kernels
are absent. **Rebuild and verify the metallib before any splat measurement.**

## The zoomed-in single point (dots.art)

A pen "dot" is a *fully degenerate span* — all four control points equal. `isSafeAngle`
calls a zero-length tangent unsafe, so `flattenAndBuild` recursed to the depth cap and
appended **2^9 = 512 byte-identical** type‑2 segments per dot. dots.art has four dots:
`2 + 4·512 = 2050` segments, all four dots duplicated 512× (measured: `unique 1` per
dot). At zoom 20 the walk is `tiles × 256 px × entries`, so one dot costs
`8160 · 256 · 512` ≈ 1.07 G iterations → the >100 ms frame. The 3‑point stroke is a real
2‑segment spline → 6 ms.

Fix: `flattenAndBuild` detects `p0 == p1 == p2 == p3` and emits the single stamp the
existing `h_chord < 1` rule already selects. A stroke's coverage is unioned (live path:
per-stroke `curMax`; static path: `maxCoverage` across the stroke's stamps and the
two-pass mask), so the 512 copies were redundant → **pixel-identical**, and dots.art
drops from 2050 to 6 segments. This is a *geometry* fix, so it also un-bloats any other
dots in any document (it is not splat-specific, and it does not depend on the
`radiusFactor` gate).

## Correctness invariant, stated precisely

The disk path wants `prune_dev ≤ pad_dev`, i.e. `reach_doc·rf + margin_dev ≤ 1.4·r_doc·rf + 1`
(`pad = 1.4·rMax_dev + 1`; the margin is a device-pixel constant now, no longer scaled).
For a straight capsule (`reach_doc = r_doc`, `margin_dev ≤ 1.4`) it holds for **any** `rf`;
for a spline with a large handle bulge (`reach_doc` includes `farOffChord`) it can fail at
radiusFactor ≈ 1, which is exactly what the kernel's per-segment `prune <= pad` test
catches: those segments iterate their tile range instead of the disk (both exact, the disk
is just cheaper). `ART_LIVE_SPLAT_MAX_RF = 1.0` is a *performance* gate (below it the disk
is cheap; above it the disk can exceed the tile band, so the walk is not worse). Do not
raise `MAX_RF` expecting a win at zoom-in — the tile is only 16 px, so the walk's expansion
waste shrinks as `r_dev` grows.

## Next round (corrected)

Rebuild the metallib however you normally do — the Xcode scheme's copy step, or
`sh Scripts/build-metallib.sh`. Then optionally verify it and build:

```sh
Scripts/build-metallib.sh --verify-only   # wants: OK: all N kernels/functions present
swift build -c release
```
At launch expect `Live view: GPU tile binning ready` and **no** `SPLAT kernels missing`
line. The verification probes are time-bounded, so a hung tool can no longer look like a
hung build; `--no-verify` skips the check entirely.

Then redo the round‑1 steps 1–4 (tripwire, kaos gate, splat A/B, BINTIME) and report the
`livebin` lines. Also re-check dots zoom 20: it should now be ~6 segments and fast
*before* any splat involvement.

## Round 2b — the vanish bug: the splat never composited the layer

With the kernels actually loaded, every layer using the splat **disappeared** as it
crossed the slot budget while zooming out (`[splat N×128]` in the log was the tell).
Cause: the walk path ends with `encodeTail`, which does *two* dispatches — the per-tile
render into `gpuRenderTarget`, **and** `liveCompositeLayerKernel` stacking that layer
onto `liveCanvasTexture` with the layer opacity. The splat branch wrote the layer texture
and returned `true`, so the caller `continue`d and the canvas never received the layer.

Fix: after the splat write kernel, encode the same layer composite
(`compositePipeline` ← `liveCompositeLayerPipeline`, `layerTex` at texture 0, `canvas` at
texture 1, opacity at buffer 0, `Self.liveGroups(width:height:)`). **Any future
early-return path must end with this composite** — writing `gpuRenderTarget` alone is not
enough to make a layer appear.

First real splat numbers (zoom 0.21, layer 0 = 24733 segs / 484 tiles): `render+comp`
≈ 16 ms vs the walk's ≈ 34 ms, i.e. ~2×. The win grows as the box shrinks (the walk is
`256 × Σ incidences`; the splat composite floor is `pixels × visibleStrokes`).



---

# Round 3 — the splat cost model, and the two scripts

## What the Mac numbers said

The splat is a large win at deep zoom-out and a clear *loss* at moderate zoom-out:

| view | splat | walk |
|---|---|---|
| kaos 0.05 | 16.8 ms (`18×128`) | not run — the box is 45 tiles |
| logo 0.05 L0 | 5.9 ms (`13×128`) | not run |
| complex 0.05 | 2.1 ms (`5×128`) | not run |
| **complex 0.3 L0** | **16.1 ms** (`5×128`) | **3.5 ms** |
| complex 0.3 L1 | 3.6 ms | 2.9 ms |

The gate only asked *is the splat exact here* (`radiusFactor ≤ 1`) plus a scratch-memory
budget — never *is it cheaper*. At 0.3 the box is 187 tiles × 256 px = 47.9 K pixels while
640 strokes are visible, so the composite replays `47.9 K × 640 = 30.6 M` slot reads. A
slot costs ~2× a walk pixel evaluation (same SDF, then an atomic max; and the composite
only has `boxPixels` ≈ 48 K threads, so it is latency-bound). The walk needs 21.9 M
cheaper evaluations instead — hence 3.5 ms vs 16.1 ms.

## The model

Both paths are exact, so this only picks the faster one, per layer, from numbers the
binning has already produced:

- walk: `entries × tileSize²` pixel evaluations — `entries` is the tile-count sum from
  the CPU prefix, i.e. exactly the `sdf` counter BINTIME prints.
- splat: `boxPixels × ceil(visibleStrokes / B) × B` slot reads.
- use the splat when `walk > splat × ART_LIVE_SPLAT_COST` (default 2.0; `0` disables the
  model and restores the plain radius-factor gate).

With the default weight: complex.art @ 0.3 → walk (21.9 M vs 30.6 M×2), complex @ 0.05 →
walk-ish (the box is already tiny), kaos @ 0.05 → splat (≥82 M vs 26.5 M×2). When the
model overrules the old gate the log says so:

```
livebin layer 0: splat declined — walk 21.9M px-ops vs splat 30.6M slots ×2.0; using the walk
```

Tests: `testSplatCostModelPicksTheCheaperPath` (the measured numbers above), and the knob
clamps (`ART_LIVE_SPLAT_COST`, 0…16).

## The scripts

- `Scripts/stroke-splat-ab.sh` — see round 3b. Copy-per-mode, render in place, SHA-256
  compare; `--all` runs the standard matrix (kaos 1/0.25/0.05, logo 1/0.05,
  complex 1/0.3/0.05, dots 1/20). Output and logs live in `tmp/splat-ab/` (project-local,
  gitignored).
- `Scripts/build-metallib.sh --verify-only` — the stall was the verifier, not the tooling:
  it matched ~31 names with `[[ $haystack == *$name* ]]` against a multi-MB
  `metal-nm`+`strings` dump held in a shell variable, which bash 3.2 walks byte by byte
  in a UTF-8 locale. Now the dump goes to a file under `tmp/` and each probe is
  `grep -qF`, with `LC_ALL=C`. Also fixed: the timeout watcher's orphaned `sleep` kept the
  caller's stdout open inside `$(...)`, delaying every probe by the full 20 s. Measured
  here: 0.07 s for the checked-in metallib, 0.16 s for a 2 MB synthetic dump.

## Next levers (ranked by expected win per risk)

1. **Tile size: measured — no win, and it exposed a real bug.** `ART_LIVE_TILE_SIZE=8`
   on kaos: `render+comp` 36.05 ms vs 36.63 at 16 (xform 9.06 vs 7.65), and Metal
   validation reported `Invalid device load executing kernel function
   "livePerTileAACompositeKernel"`. That was not noise. The composite dispatches
   `ceil(tileSize / 16)` *whole* 16×16 threadgroups per tile, so a tile smaller than the
   group makes every group also cover the next tile: `localTile` runs past
   `tileStartCount` and the trailing threads composite a neighbouring tile's strokes into
   the layer. Fixed with a box-bounds guard in all four live composite kernels
   (`boxTilesPerCol` added to `PerTileParams` and `LiveStrokeParams`), and
   `LiveConfig.liveTileSize` now accepts only multiples of 16 in 16…64 and prints a note
   when a requested value is ignored. Conclusion: 16 stays; the SDF count does not fall
   the way `incidences × tileSize²` predicts (incidences grow much faster than 1.8× at 8).
2. **The splat composite is the splat's floor**: `boxPixels × visibleStrokes` slot reads.
   A per-tile compaction (append each stroke's ordinal to the tiles it actually touches,
   then replay only those per pixel) would make the splat converge to the walk's incidences
   instead of the whole box — but it is exactly the walk's data structure again, so the
   ceiling is ~2×. Only worth it if the splat is kept at moderate zoom.
3. **Bin CPU time** (kaos `bin` 59 ms = 11 ms CPU + 9.4 `xform` + 36.7 `render+comp`) is
   dominated by per-frame CPU prep: the stroke-block table build, `visBytes`/ordinal
   uploads and the 7800-tile prefix. Cheap checks: time `strokeBlockTable` separately, and
   see whether the table is worth it at the current density.
4. **Excluded layers** (`cut` ops, markers, `needsRebuild` paste/merge layers) still take
   the per-stroke CPU path. That is a bigger job: cut metas would have to be remapped and
   interleaved in document order inside the GPU plan.

## Round 3b — the A/B script, the 1×1 PNG, and why the tile knob was unsound

`art2png --viewport` used to accept anything: `--viewport 0.25` split on `x` into
`["0.25"]` and parsed both ends as the same number, i.e. a 0.25×0.25 canvas, which rounds
to **1×1** — written without a warning. The A/B script's old positional form was
`<doc> <viewport> [zoom]`, so `stroke-splat-ab.sh art/kaos.art 0.25` passed the zoom as the
viewport and produced exactly those 161-byte PNGs. Both sides are fixed: `--viewport` now
requires integer `WxH` (1…16384) and exits non-zero otherwise; the script takes
`<doc> [zoom]` / flags and refuses a non-`WxH` `--viewport` itself.

`stroke-splat-ab.sh` is rewritten around one idea: **copy the document, render in place,
compare hashes.** Each view gets `tmp/splat-ab/<doc>@<zoom>/off|default/<doc>.art`, so the
output PNG is always `<copy>.live-view.png` next to a known input — no guessing where a
run wrote, no fixed filenames overwritten by the next view, no shell field plumbing. The
two PNGs are compared by SHA-256, each is checked to be the requested viewport size, the
command line is echoed into each `run.log`, and a failure prints the log tail. The default
run's own `[splat N×B]` marker is reported, so a view where the cost model declined the
splat (kaos at 0.25) is labelled `walk (splat declined)` instead of pretending to exercise
it. `--all` renders the standard matrix (kaos 1/0.25/0.05, logo 1/0.05, complex 1/0.3/0.05,
dots 1/20).

## Round 4 — attributing the composite, and honest CLI timings

### What the Mac said

* Tile 8 vs tile 16 on kaos: `xform 8.62 / 8.77`, `render+comp 36.59 / 36.63` — within
  noise on both, and logo likewise. Tile size is **not** a lever (the work is
  incidences × tile area, and incidences grow as the tile shrinks). 16 stays.
* GPU frame capture: `livePerTileAACompositeKernel` ≈ **28–29 ms** on kaos zoom 1, of
  which ≈ **12 ms** disappears when the SDFs are stubbed. The remaining ~16 ms has no
  per-line attribution available: AMD + Metal has no shader line counters.
* The SDF count itself is intrinsic: 7800 tiles × 256 px × ~186 incidences/px = 372 M
  pixel-segment pairs, i.e. the drawing, not redundancy. At 12 ms that is ~31 G evals/s,
  about 20–25 % of the card's FP32 peak — so the walk is **stall-bound, not FLOP-bound**.

That last number is the whole story: 372 M iterations in 28 ms is ~320 lane-cycles per
iteration against maybe 90 cycles of useful arithmetic. The missing time is latency and
divergence (dependent `tileList → segments` loads, the 64-byte struct per iteration, the
3-way branch inside the capsule SDF, the per-pixel prune branch). Guessing which one is a
coin flip, so this round ships the instrumentation to measure it, plus the fixes that are
certain.

### `ART_LIVE_ABLATE` — attribute the kernel with uniform branches

`LiveConfig.ablate` (`ART_LIVE_ABLATE`, clamped 0…31) lands in `PerTileParams.ablate` and
is read once per thread in `livePerTileAACompositeKernel`. Every bit is a *uniform* branch
(same for the whole dispatch), so with 0 the kernel is unchanged and with a bit set the
timing delta is the stage's cost. The pixels are wrong by construction — it is a
measurement tool, never a shipping path. The renderer prints a note when it is set.

| bit | stage removed | what the delta means |
|-----|---------------|----------------------|
| 1 | SDF | SDF + coverage (`signedDist → smootherstep`) |
| 2 | prune rejects everything | loop + `tileList` load + segment load + block table only |
| 4 | per-stroke blend | `perTileCompositeStroke` (quantise + source-over) |
| 8 | pixel write | the one `target.write` per pixel |
| 16 | constant-address segment load | the 64-byte `segments[segIdx]` fetch per iteration |

Read it as: `(0 − 1)` = SDF, `(0 − 4)` = blend, `(0 − 8)` = write, `(0 − 16)` = segment
load, `2` = the fixed loop/loads/table floor. If `16` is large, the walk is memory-latency
bound → the fix is two pixels per thread (below). If `1` is large, the SDF's divergence is
the target → make `sdUnevenCapsule` branchless with `select` (bit-exact). If `2` is close
to `0`, the loop body is the problem, not any one stage.

Only the AA per-tile kernel honours the bits (noisy layers take the noise twin, whose
structure differs enough that copying the branches would only add risk).

### Honest BINTIME

`bin` was never steady-state CPU on a one-shot CLI run: it sat inside a window that
included every cold Metal allocation (the 20 MB segment arena, the tile list + scratch,
the group/table buffers, and for splat views the 64 MB slot buffer) — and on the **splat**
return it also added the whole GPU tail (`since(prefixStart)` across
`waitUntilCompleted`), so an 18 ms splat render was reported as `bin`. kaos printing
`bin 60` while the entire GPU was 47 ms is the tell.

Now:
* `LiveFrameTiming.allocMilliseconds` — cold buffer growth, measured around each
  `makeBuffer` site and around `ensureBinFrameBuffers` / `ensureEmptyGroupBuffers` /
  `ensureSplatBuffers`. Printed as `alloc` in the summary line.
* `bin` excludes it (`bin = window − alloc`), and the splat path subtracts its GPU tail
  (`− tRenderSplat`), which was already counted in `gpu`.
* `art2png --live-view --warmup N` renders N throwaway frames first, so the reported
  numbers are the steady state. Expect the first frame to show `alloc` in the tens of ms
  and later frames to show `alloc 0`.

The A/B script does not need warmup (pixels are identical), but anything used to *compare
timings* should pass `--warmup 1`.

### The prune gate: no sqrt, no division

`liveSegPruned(p, a, b, r²)` replaces `liveSegDist(p, a, b) > r` at all five call sites
(four walk kernels + the splat's disk trim). The three point-to-segment cases compare
squared distances directly and the perpendicular case multiplies through by `|ba|²`, so
the gate costs ~8 ops with no `sqrt` and no divide instead of a divide plus a `length`.
`SegmentPrune.radius` stores the shape reach and the kernels add a device-pixel margin
(0.5 px for the AA kernels, the noise falloff for the noise twins — see Round 7), so the
rounding difference between the two forms cannot flip a contributing pixel; the kaos pixel
gate and `stroke-splat-ab.sh --all` are the check.

### Next step, decided by the numbers

Run this first (one command, six steady-state frames, ~5 s on kaos):

```
sh Scripts/composite-ablate.sh                     # art/kaos.art at zoom 1, 1920x1080
sh Scripts/composite-ablate.sh art/complex.art --zoom 0.3
```

It prints the `livebin layer 0:` line and the `Live view:` summary per bit, plus the delta
legend. Then pick the branch below.

1. `ART_LIVE_ABLATE=16` ≈ `0` → not the segment load. Go to 2.
   `16` materially lower → **two pixels per thread**: one 64-byte load and one loop
   iteration serve two pixels, and the two SDF chains interleave (ILP into the stalls).
   The block cursor and `nextFirst` are pixel-independent, so only `acc`, `curMax`,
   `curStroke`, `haveCur` and `strokeActive` need a second copy; a 16×16 threadgroup then
   covers 16×32 px (two tiles stacked) and the existing box guard already tolerates the
   overshoot.
2. `ART_LIVE_ABLATE=1` ≈ 12 ms and the rest is spread → the SDF's 3-way branch is the
   cost; make `sdUnevenCapsule` a `select` over the three case distances (bit-identical
   results, no divergence).
3. `ART_LIVE_ABLATE=2` ≈ `0` → the loop/loads/table floor dominates; the fix is fewer
   iterations (pix2) rather than a cheaper body.
4. Only if the composite drops under ~10 ms does `xform` (8.8 ms, 1.45 M atomics into
   7800 counters) become the next target: a threadgroup-local histogram with one global
   atomic per distinct tile.

## Round 5 — the ablation verdict, and `bin` was the block table

### What the ablation said (kaos zoom 1, `--warmup 1`)

| bit | `render+comp` | delta vs 0 | stage |
|-----|---------------|------------|-------|
| 0 (shipping) | 33.69 ms | — | — |
| 1 | 26.39 | **7.30** | SDF + coverage |
| 2 | 21.02 | **12.67** | loop + `tileList` + segment load + block table |
| 4 | 31.97 | 1.72 | per-stroke blend/quantise |
| 8 | 31.73 | 1.96 | pixel write |
| 16 | 22.64 | **11.05** | the 64-byte `segments[segIdx]` fetch |

Reading: the segments are fetched with a *dependent, per-iteration* address while the SDF
only costs 7.3 ms, and the loop/table floor (12.67) is almost entirely that same fetch
(11.05) — the fixed loop overhead is ~1.6 ms. Blend and write are noise. The isolated
deltas sum to 22.0 of 33.7, i.e. ~11.7 ms is latency exposure that no single stage owns,
which is the signature of a dependency chain: `tileList[i]` → `segIdx` → 64-byte struct →
SDF, with nothing to overlap it.

Xform also fell from 8.77 to 4.34 ms with a warm frame, so the earlier atomics number was
half cold-cache.

### `bin 39` was not CPU planning — it was one table

The honest timing split exposed `bin 39` against `gpu 39`, which could not be culling: the
cull is 2214 strokes. `ART_LIVE_PROFILE_BIN=art/kaos.art swift test --filter
testProfileBinPlan` (new, Linux, no Metal) replicated the real kaos tile counts and timed
the stages `bin` owns:

```
cull 2.61 | combine 0.92 | blockTable 187.41 | chunkTable 1.00 | mergePlan 0.49 | memcpys 2.14
```

96 % of it in `GpuBinSpec.strokeBlockTable`, and the reason is visible in its output:
**1,501,372 block-tile entries against 1,454,923 incidences**. kaos strokes are long
scribbles, so a 32-segment AABB spans ~150 tiles; the table then adds a block to every tile
its box touches. Every pixel pays one box test per listed block (~192 per tile) *and still
walks the same ~186 segments*, so the pruning value is nil while the table costs ~39 ms of
CPU per frame, a 36 MB upload, and ~380M extra box tests on the GPU. That single table was
the biggest cost in the frame.

**Fixed with a usability gate** in `strokeBlockTable`, decided *before* the O(entries)
work: no block can own more entries than its clamped box area, and none can own more than
one per dense tile, so `bound = min(areaSum, blocks × denseTiles)` is a safe upper bound.
If `bound × 2 > incidences` the table is dropped — it cannot even halve the per-tile
candidate count. Dropping it changes no pixel (the kernels walk the tile list directly, the
pre-table behaviour). `ART_LIVE_STROKE_PRUNE=2` forces the table back for A/B.

After the gate, the same profile prints `blockTable 7.59 | memcpys 0.01` and `blocks 0`
(debug), i.e. release `bin` should drop from ~39 ms to a few ms.

### Next

1. Confirm on the Mac: `bin` should fall to single digits with `render+comp` unchanged or
   lower, since the kernel also loses the per-pixel block-table walk. A/B the table's GPU
   value directly with `ART_LIVE_STROKE_PRUNE=2` (identical pixels, so the only difference
   is time) — `Scripts/stroke-prune-ab.sh --modes 0,1,2 art/kaos.art` renders all three
   modes from separate copies and hashes the PNGs, so the identity is checked in the same
   run. `Scripts/stroke-splat-ab.sh --all` must stay 10× IDENTICAL. No metallib rebuild
   this round: the kernels are untouched, only the table that feeds them.
2. Re-run `Scripts/composite-ablate.sh` afterwards: with the block table gone, the bit-2
   floor should shrink, and the remaining attribution decides between **pix2** (bit 16
   still large, as it is now) and the branchless SDF (bit 1 large).
3. pix2 is the expected next structural step: one dependent fetch per *two* pixels, and two
   interleaved SDF chains to fill the ~11.7 ms of exposed latency.




## Round 6 — the gate paid off, and the composite is latency-bound

### What the Mac said (kaos zoom 1, `--warmup 1`)

Prune gate (table dropped), warm frame:

```
Live view: 33 ms total (bin 2, alloc 0, encode 0, gpu 30, paper 1)
xform 4.34  scatter 0.66  sort 0.60  render+comp 24.05
```

`ART_LIVE_STROKE_PRUNE=2` (table forced back), same frame: `bin 38`,
`render+comp 32.48`, `total 78`. So the gate is a straight win on *both* sides — the table
cost 40 ms of wall clock and 8.4 ms of GPU, and the fallback (walking the tile list) is both
cheaper and exact. All three modes stay byte-identical
(`stroke-prune-ab.sh --modes 0,1,2`), 10/10 splat views identical.

### The fresh ablation (same frame, table gone)

| bit | `render+comp` | Δ | stage |
|---|---|---|---|
| 0 | 23.44 | — | — |
| 1 | 15.53 | 7.91 | SDF + coverage |
| 2 | 12.81 | 10.63 | loop + list loads + segment loads |
| 4 | 23.20 | 0.24 | blend/quantise |
| 8 | 23.84 | −0.40 | target write |
| 16 | 12.53 | 10.91 | the 64-byte `segments[segIdx]` gather |

Two things changed from Round 4: the floor dropped 12.67 → 12.53 while the total dropped
33.69 → 23.44 (the table's 8.4 ms of GPU box tests are gone), and **blend/write are now
free** (0.24 / −0.40 vs 1.72 / 1.96). Blend and write were never really 2 ms of work; they
were part of the same latency window. Removing them now just moves where the stall lands.

That is the real diagnosis: the pass is **latency-bound, not throughput-bound**. It walks
`372,460,288` (pixel × listed-segment) iterations in 23.4 ms, and the prune rejects the
large majority before any SDF runs — the arithmetic for 372M iterations is ≲1 ms at this
GPU's ALU rate, so ~95 % of the frame is waiting on the dependent chain

```
tileList[j] → segIdx → segments[segIdx] (64 B gather) → prune → SDF → curMax
```

Three chips (bit 16 = 10.9 ms, blend/write ≈ 0, floor ≈ 12.5) all say the same thing: the
kernel is one load-to-use stall per listed segment. Cutting arithmetic cannot help; cutting
*iterations per pixel* or *stalls per iteration* can.

### The change that was tried: four pixels per thread (rejected)

`livePerTileAACompositePix4Kernel` (ART_LIVE_PIX, default 4) gave one thread four
vertically adjacent pixels: the tile-list walk and the 64-byte `segments[segIdx]` gather
were paid once per four pixels, and the four prunes/SDFs could interleave. It was exact
(`pix-ab.sh`: 1 vs 4 byte-equal) and it did exactly what the latency model predicted — and
it was still ~1 ms *slower*:

```
pix1  23.77 / 24.94   render+comp
pix4  25.09 / 25.12   render+comp

ablation (pix4):  bit0 25.09 | bit1 10.32 | bit2 6.78 | bit4 23.87 | bit8 24.96 | bit16 7.47
ablation (pix1):  bit0 23.44 | bit1 15.53 | bit2 12.81 | bit4 23.20 | bit8 23.84 | bit16 12.53
```

Read it as a resource model rather than one chain: `pix4` halved the loop/gather floor
(12.81 → 6.78) as designed, but the SDF's *marginal* cost doubled (7.91 → 14.77) because
four lanes per thread means four times fewer warps, and the SDF is 10–12 dependent curve
evaluations with two divisions. At pix1 the SDF's issue slots hide under the gather stalls
(12.8 + 18.3 − 7.7 overlap ≈ 23.4); at pix4 there is nothing left to hide behind
(6.8 + 18.3 ≈ 25.1). **Net: no.** Reverted in full — kernel, pipeline, `LiveConfig` knob,
tests and `Scripts/pix-ab.sh` are gone. The data point is kept because it fixes the budget:
the composite is ~18 ms of SDF work, ~13 ms of loop+loads at pix1, and only ~7.7 ms of the
loop is hidden.

That leaves exactly two exact levers: fewer SDF evaluations, or a cheaper loop. Round 7
took the first one, and it turned out the prune bound was not merely loose — it was
*double* the ink radius.

## Round 7 — the prune bound was 2× the ink: Bézier hull + device-space margin

### What was wrong

`padding1` was `farOffChord + reach + max(0.75, 0.375·rMax)`:

1. **`farOffChord` used the Catmull-Rom control points p0/p3.** A CR span deviates from its
   chord by about a *sixth* of the neighbour offsets — the curve lives in the Bézier hull
   B0 = p1, B1 = p1 + (p2-p0)/6, B2 = p2 - (p3-p1)/6, B3 = p2, and only B0/B3 are on the
   chord. Bounding p0/p3 is the obvious-but-6×-loose choice. (Guarded by the p0/p3 hull
   too: `min(handleReach, pointReach)`, because with non-uniform spacing a far-back p0 can
   push B1 past the chord end and make the handle bound the looser one. Both are valid,
   neither is ever looser than the old rule.)
2. **The margin was folded into the camera-scaled value.** The AA tail (0.44 px) and the
   noise falloff (1.375·max(r,1)) are *device-pixel* constants, so scaling
   `max(0.75, 0.375·rMax)` with the zoom was too loose at zoom-in (1.375·r vs the 1.0·r +
   0.5 px the ink needs) and too tight at zoom-out (the constant tail shrank below 0.44 px,
   and a thin noisy stroke's `max(radius, 1)` floor needs up to 1.375 − r).

### Measured on Linux before touching the Mac

`ART_LIVE_PROFILE_PRUNE=art/kaos.art swift test --filter testProfilePruneHeadroom` walks the
same pixel box the binner lists (`1.4·r + 1` around the chord) and counts prune survivors:

```
strokes 2214 | segments 321611 | noisy 0 (0.0%)
rMax histogram: ≤1 0  ≤2 61337  ≤4 98442  ≤8 161832  ≤16 0  >16 0
bucket           segs    boxPx     old      new      ink   new/old
type0 clean      8722  5959682 2636702  1968203  1935740   74.65%
type1 clean     30725 11793829 5723726  4026399  3952534   70.35%
type2 clean      7451  2101346  965682   626802   613060   64.91%
TOTAL           46898 19854857 9326110  6621404  6501334   71.00%
mean prune radius: old 5.73 px  new 4.68 px  ink 4.62 px
```

Those `old`/`new` columns are both under the *new* `farOffChord`; against the shipped code
the pass count goes **14.70 M → 6.62 M (45 %)**, the mean prune radius **9.77 → 4.68 px**,
and the survivors sit within 1.8 % of the *exact* ink cutoff (6.50 M) — there is nothing
left to squeeze here. kaos has no noisy segments at all, so the noise margin costs it
nothing; other documents keep the scaled `0.375·r` tail.

SDF was ~18.3 ms (Round 6, pix4-exposed), so a 55 % cut predicts
`render+comp 23.4 → ~13–14 ms`, i.e. the 16 ms target, with the loop untouched.

### The change

* `SegmentPrune.radius` returns **shape reach only**: `min(handle hull, control hull) + rMax`
  (markers: `+ 4·rMax`). Document space, scales with the camera like the radii.
* The kernels add the **device-space** margin themselves:
  `as_type<float>(padding1) + 0.5f` in the two AA kernels (0.44 px cutoff + rounding),
  `+ liveNoisePruneMargin(r0, r1)` in the two noise kernels, where
  `max(0.5, 0.375·rMax, rMin < 1 ? 1.375 − rMin : 0)`; the splat kernel uses the same two
  expressions, so the walk's and the splat's contributing sets stay identical.
* `0` keeps meaning "never prune" (only degenerate `rMax = 0` type-0 segments).

### Why it is still output-identical

* The curve is only evaluated at t ∈ [0, 1] (`PRE_SAMPLES`, Newton steps clamp, the marker
  sweep), and a cubic Bézier lies in the convex hull of its handles, so every evaluated
  curve point is at most `handleReach` from the chord.
* Paint ⇒ `dist(p, curve) ≤ r + 0.44`; with the 1-Lipschitz chord distance,
  `dist(p, chord) ≤ handleReach + rMax + 0.44`, and the kernel prunes at
  `handleReach + rMax + 0.5`.
* Noise: paint ⇒ the pixel is at most `1.375·max(r, 1)` from the curve; the margin covers it
  for every local radius between rMin and rMax.
* Static kernels do not read `padding1` at all, so `art/kaos.png` ground truth cannot move.

### Files

* `Sources/ArtRenderLibrary/RendererTypes.swift` — `SegmentPrune`: Bézier/point hull reach,
  `aaCutoff`, `aaDeviceMargin`, `noiseReachFactor`, `noiseDeviceMargin`.
* `ArtQuickLook/ArtRenderShaders/segmentKernels.metal` — `liveNoisePruneMargin` and the five
  prune sites (per-stroke AA/noise, per-tile AA/noise, splat disk radius).
* `Tests/ArtRenderLibraryTests/TileUnionTests.swift` — hull reach values, a dense
  span-containment test, and the margin-coverage tests.
* `Tests/ArtRenderLibraryTests/LiveProfileTests.swift` — `testProfilePruneHeadroom` (opt-in).
* `SPLAT-DESIGN.md` — this section.

### Run this (metallib rebuild IS needed this round)

```
sh Scripts/build-metallib.sh          # or the ArtRenderShaders scheme in Xcode
swift build -c release

sh Scripts/stroke-splat-ab.sh --all                       # 10/10 IDENTICAL
sh Scripts/stroke-prune-ab.sh --modes 0,1,2 art/kaos.art  # byte-equal
# kaos zoom-1 pixel gate vs art/kaos.png (~2 bytes is the historical pass)

ART_LIVE_BINTIME=1 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 art/kaos.art
sh Scripts/composite-ablate.sh                            # re-baseline the composite
```

Expect `render+comp` ≈ 13–14 ms and bit 1 (SDF) to fall to ~4 ms; the loop/gather bits
(12.8 / 12.5) stay put. If that holds, the composite is loop-bound again and the next exact
levers are, in order:

1. **`xform` 4.3–4.9 ms** — one global-atomic histogram (1.45 M atomics into 7800 counters);
   a threadgroup-local histogram per tile block removes the contention.
2. **Bin pad** — `1.4·r + 1` is now much larger than the (much tighter) prune radius; the
   tile box can shrink to `reach + 0.5` without changing any pixel, cutting incidences and
   the sort/merge volume.
3. **SDF math** — only with a documented tolerance: the spline SDF is 7 curve samples + 2
   Newton steps per evaluation, and kaos spends most of its SDF budget in `type 1`.

## Round 8 — eight marker strokes cost 1141 dispatches

### What was wrong

Round 7's ablation says the kaos composite is loop-bound again (12.8 ms floor, SDF marginal
3.4 ms). But a user document exposed a much bigger hole: `art/qwerty.art` has **1/5 of
kaos's points** (1141 strokes / 68 221 segments vs 2214 / 321 611), yet it took **77 ms
warm, `gpu 56`** against kaos's 28 ms / `gpu 25`.

`ART_LIVE_PROFILE_ELIGIBLE=art/qwerty.art swift test --filter testProfileEligibility`
(before this round; it now prints `per-tile ELIGIBLE`):

```
layer 0: strokes 1141 | segments 68221 | noisy 0 | cuts 0 | markers 8
  per-tile blocked (8 marker strokes) | per-stroke path: 1141 dispatches over 19689
  tile-threads vs 2070 tiles for the whole layer
```

**Eight marker strokes** out of 1141 dropped the whole layer onto the per-stroke path: 1141
dispatches (each with its own tile-box launch) covering 19 689 tile-threads — 9.5× the
per-tile path's 2070 — and `bin 7–13`. The per-tile path was marker-free only because
`LivePerTileEligibility` excluded markers and the AA kernel had no chisel branch; neither was
a correctness requirement, just an unimplemented case.

### The change

Markers are now per-tile-eligible **when the layer has no noisy segment**:

* `LivePerTileEligibility.isEligible` — cuts still force the per-stroke path; a marker is
  allowed unless the layer also has a noisy stroke. The per-tile *noise* kernel owns the
  whole layer when any segment is noisy and has no marker SDF, so `markers + noise` stays
  on the proven per-stroke path (one rare combination, still exact).
* `strokeFlags` bit layout: bit0 = eraser, bit1 = hasNoise, **bit2 = isMarker** (independent
  of the per-stroke `LiveStrokeParams.flags`, which keeps bit1 = marker).
* Pads — a chisel reaches 4·r from the curve, a capsule only ~1.4·r, and all three binning
  stages must agree or the marker tips clip:
  * fused GPU transform kernel: `strokeFlags` bound at buffer 8, `pad = marker ? 4·rMax + 2
    : 1.4·rMax + 1`;
  * CPU per-tile plan: `buildSegmentTileIndicesBoxed(..., markerFlags:)` (per segment, so a
    mixed layer pads each segment by its own rule; `nil` keeps the old whole-call flag for
    the static path);
  * stroke-block table: `blockIsMarker` → `pad = (marker ? 4 : 1.4)·rMax·radiusFactor + 3.5`.
* Per-tile AA kernel — caches `curFlags` when the stroke changes (block and direct walks)
  and picks `sdSlantedMarkerStraight` / `sdSlantedMarkerSpline` for bit2 strokes, exactly
  the two calls the per-stroke AA kernel makes for `params.flags & 2`.
* The splat kernel has no marker SDF, so a layer with any *visible* marker declines the
  splat and takes the walk (the walk is exact by the Round 7 argument).

### Why it is still output-identical

* The per-tile path already reproduces the per-stroke path pixel for pixel for capsules and
  splines: same tile list, same per-stroke max-coverage, same per-stroke 8-bit quantisation
  in `perTileCompositeStroke`, one canvas write per pixel.
* A marker stroke differs *only* in the distance function. The per-stroke AA kernel applies
  `sdSlantedMarker*` to every segment of a marker stroke; the per-tile kernel now does the
  same for the stroke group's segments (`curFlags & 4`), with the same opacity/t and the same
  `smootherstep` coverage.
* Markers are excluded from the noise kernel in both paths: per-stroke, a noisy stroke picks
  the noise kernel *before* looking at `isMarker` (so marker-ness is ignored there); per-tile
  we keep the whole `markers + noise` layer on the per-stroke path rather than reimplement
  that interaction.
* The bin/block pads only ever grow to the true reach, so they can add provably-empty tiles,
  never drop ink.

### Files

* `Sources/ArtRenderLibrary/LiveRenderCache.swift` — eligibility + bit2 flags.
* `Sources/ArtRenderLibrary/RendererTypes.swift` — `strokeBlockTable(blockIsMarker:)`.
* `Sources/ArtRenderLibrary/MetalRenderer.swift` — `LiveBinRefLayer.blockIsMarker`.
* `Sources/ArtRenderLibrary/MetalRenderer_Dispatch.swift` — `markerFlags` in
  `buildSegmentTileIndicesBoxed`.
* `Sources/ArtRenderLibrary/MetalRenderer_LiveCompositing.swift` — plan flags + per-segment
  marker pads, ref-state flags/blocks, transform-kernel binding, splat gate, visible-marker
  cull rule.
* `ArtQuickLook/ArtRenderShaders/segmentKernels.metal` — `liveBinRangeForSeg(isMarker:)` +
  buffer 8, `curFlags` and the chisel branch in `livePerTileAACompositeKernel`.
* `Tests/ArtRenderLibraryTests/TileUnionTests.swift` — eligibility (clean markers yes,
  markers + noise no), bit2 layout, block-table marker pad (16 vs 49 tiles).
* `Tests/ArtRenderLibraryTests/LiveProfileTests.swift` — `testProfileEligibility` (opt-in).
* `SPLAT-DESIGN.md` — this section.

### Run this (metallib rebuild IS needed: MSL + buffer index changed)

```
sh Scripts/build-metallib.sh          # or the ArtRenderShaders scheme in Xcode
swift build -c release

# the new A/B: per-tile ON vs OFF on the marker document, then on kaos
ART_LIVE_PERTILE=1 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 art/qwerty.art
ART_LIVE_PERTILE=0 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 art/qwerty.art
# compare the two .live-view.png byte for byte (same for art/kaos.art)

sh Scripts/stroke-splat-ab.sh --all                       # 10/10 IDENTICAL
sh Scripts/stroke-prune-ab.sh --modes 0,1,2 art/kaos.art  # byte-equal
# kaos zoom-1 pixel gate vs art/kaos.png

ART_LIVE_BINTIME=1 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 art/kaos.art
ART_LIVE_BINTIME=1 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 art/qwerty.art
```

Expect qwerty to report **one `livebin` line** (`segs 68221`, `tiles ~2070`, no per-stroke
dispatches), `render+comp` in kaos territory (~10–14 ms) and `total` ~20–25 ms instead of 77,
with the PNGs byte-identical to the per-stroke render. kaos must not move (it has no
markers; only the extra 4-byte flags load per stroke boundary is new).

Then the next exact lever is still `xform` (4.3–4.9 ms of global atomics into 7800
counters → a threadgroup-local histogram), then the bin pad, then (only with an accepted
tolerance) the SDF math.

## Round 9 — reading the ablation, and why width² is the real cost model

Round 8 shipped: qwerty 77 → **14 ms** warm (one `livebin` line, `segs 68221 tiles 2352`,
`render+comp 6.01`), 10/10 splat views identical, prune modes 0/1/2 byte-equal, kaos
unmoved (20.73 vs 19.29 is duplicate-run variance on this machine). Round 9 asks the next
question — wide strokes — and starts by reading the ablation table properly.

### How to read `ART_LIVE_ABLATE`

Each bit removes exactly one stage behind a dispatch-uniform branch; every run still has
all the others, so a delta is that stage's **marginal** cost *in the presence of the rest*,
not its share of a sum. They need not add up, and the two small/negative ones are the
interesting part. kaos zoom 1, pix1:

| bit | what it removes | `render+comp` | marginal vs bit 0 |
|----|------------------|---------------|-------------------|
| 0 | nothing (baseline) | 18.87 | — |
| 1 | the SDF + coverage | 15.41 | **3.46 ms** |
| 2 | every segment (prune rejects all) | 12.91 | **5.96 ms** for everything after the walk |
| 4 | the per-stroke blend/quantise | 18.98 | ≈ 0 (noise) |
| 8 | the pixel write | 19.56 | ≈ 0 (noise) |
| 16 | the real 64 B segment load (hot address) | 12.61 | **6.26 ms** |

Read the other way: **12.6–12.9 ms of the ~19 ms is the walk itself** — the `tileList`
read, the block-table cursor, and the 64-byte dependent load of the segment that the loop
cannot hoist (one per pixel, per list entry). Then:

* bit 16 vs bit 2 (12.61 vs 12.91) is the giveaway: with the segment coming from a hot
  address, the SDF costs ~0.3 ms. Its 3.46 ms at bit 1 is *latency it uncovers*, not
  arithmetic it performs. The SDF is not the bill; it is what the bill buys.
* blend and write are negative — they hide under the load latency, so removing them frees
  nothing.

So the majority of `render+comp` is the per-`(pixel, segment)` visit and its load. Two
consequences: a cheaper SDF is the wrong target (Round 6 proved the marginal *doubles*
when occupancy drops), and every lever has to remove **visits**, not instructions.

### The cost model, and what "wide" really does

`render+comp` ≈ 256 × Σ_tiles |tileList| (one evaluation per pixel per list entry, minus
prunes). All three documents land at the same rate, ~18–20 G evaluations/s:

| view | segments | tiles | evaluations | render+comp |
|---|---|---|---|---|
| kaos zoom 1 | 321 611 | 7800 | 372 M | 20.2 ms |
| qwerty zoom 1 | 68 221 | 2352 | 97 M | 6.0 ms |
| complex zoom 10 | 33 216 | 16 320 | 433 M | 24.5 ms (2 layers) |

complex at zoom 10 costs **4.5× qwerty with 4.6× fewer segments**: 1.69 M list entries
over 12 707 ink tiles = **133 entries per ink tile**, against qwerty's 40. It is not the
document, it is the overdraw: at device radius `r`, one pixel sits inside roughly
`r / segmentLength` segments of the *same* stroke, and that stroke's segments fill
`(tileSize + 2r)² / tileSize²` tiles each. Both factors grow with `r`, so ink work grows
like `r²` while the segment count stays fixed — which is exactly what the user hit by
zooming to 10.

### The change: per-pixel stroke saturation is dead work

A pixel's coverage for one stroke is `max` over that stroke's segments in the tile of
`stamped = cov · opacity`. Both factors are ≤ 1 — the coverage functions saturate at
exactly 1.0 (`smootherstep` returns 1 for arguments past its edge, `covPencil`/`covAirbrush`
are bounded by 1) and point opacity is clamped to 0…1 when the segment is built
(`Renderer_StrokeGeometry`, `opacity = max(0, min(1, opacity))`, then span interpolation
between clamped values). So `curMax ≤ 1`, and **once `curMax == 1` no later segment of that
stroke can change the pixel**. The stroke's remaining segments are provably dead: skipping
them skips their 64-byte load as well, which is the 6.3 ms term.

That is the whole change: one compare in each per-tile kernel (`curMax >= satCeil`, with
`satCeil = 1` normally and `3.4e38` under `ART_LIVE_SATURATE=0` for the A/B). It is not an
approximation — it is the associativity of `max` plus the fact that 1 is its ceiling. A
translucent pen (point opacity < 1 everywhere) simply never reaches the ceiling and keeps
the old walk: the test is self-limiting rather than needing a per-stroke opacity bound.

Expected shape of the numbers: it can only remove work from the SDF+load half of the
frame, because the `tileList` read and the block-table cursor still happen for every list
entry. So `k / 256` of the entries being saturated is worth at most `k/256 × 9.7 ms` on
kaos. It should be near-invisible where the overdraw is ~1 (qwerty), visible on kaos
(radius 2–8 px, several of a stroke's own segments per tile) and largest at zoom 10, where
a 50-px stroke re-walks itself dozens of times per pixel.

### Files

* `ArtQuickLook/ArtRenderShaders/segmentKernels.metal` — `PerTileParams.flags`, the
  `PT_SAT_CEIL` note, the guard in both per-tile kernels.
* `Sources/ArtRenderLibrary/MetalRenderer_LiveCompositing.swift` — `flags` field +
  construction.
* `Sources/ArtRenderLibrary/RendererTypes.swift` — `LiveConfig.saturationSkipEnabled`.
* `Tests/ArtRenderLibraryTests/TileUnionTests.swift` — knob defaults.
* `Scripts/live-var-ab.sh` — generic env A/B (copy the doc per value, compare SHA-256).

### Run this (metallib rebuild IS needed: `PerTileParams` grew by 4 bytes)

```
sh Scripts/build-metallib.sh          # or the ArtRenderShaders scheme
swift build -c release

# pixel identity, wide-stroke view included
sh Scripts/live-var-ab.sh art/kaos.art art/complex.art
sh Scripts/live-var-ab.sh --zoom 10 --pan 500,-400 art/complex.art
sh Scripts/stroke-splat-ab.sh --all                     # 10/10 identical
# kaos zoom-1 gate vs art/kaos.png

# timing: ON vs OFF, same view twice
ART_LIVE_BINTIME=1 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 art/kaos.art
ART_LIVE_BINTIME=1 ART_LIVE_SATURATE=0 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 art/kaos.art
ART_LIVE_BINTIME=1 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 art/qwerty.art
ART_LIVE_BINTIME=1 ART_LIVE_SATURATE=0 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 art/qwerty.art
ART_LIVE_BINTIME=1 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 --zoom 10 --pan 500,-400 art/complex.art
ART_LIVE_BINTIME=1 ART_LIVE_SATURATE=0 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 --zoom 10 --pan 500,-400 art/complex.art

# and the wide-stroke frame's own ablation, since kaos's mix does not transfer
sh Scripts/composite-ablate.sh --zoom 10 --pan 500,-400 art/complex.art
```

Also worth re-running the zoom-10 ablation (`ART_LIVE_ABLATE=0,1,2,16`): the bet here is
that its SDF+load share is *larger* than kaos's, because every one of those 133 entries
per tile is a dependent 64 B load.

### Still open, in order

1. **Make the skip jump the list, not just the segment.** The remaining 12.6 ms floor is
   the `tileList` read itself: a saturated stroke still pays 4 bytes per entry to discover
   it is saturated. A per-block `jStart` (the list index where the block begins) would let
   a saturated stroke advance `j` to the next stroke's first block — a few 24-byte block
   reads instead of ~35 list reads. Costs one uint per block in `GpuBinStrokeBlock`.
2. **Stage the tile's segments in threadgroup memory.** Every pixel in a tile loads the
   same 64-byte records; one threadgroup is already exactly one 16×16 tile, so a preload
   into threadgroup memory (64 × 128 = 8 KB for the first 128 entries, global fallback
   beyond) replaces 256 dependent loads per entry with one coalesced load. Watch occupancy:
   the kernel was register-limited at ~7 SIMD groups before Round 5.
3. **`xform` (4.3–4.9 ms)** — global atomics into 7800 counters → threadgroup-local
   histogram.
4. **Bin pad** — still much larger than the prune radius.
5. **SDF math** — only with an accepted tolerance.
