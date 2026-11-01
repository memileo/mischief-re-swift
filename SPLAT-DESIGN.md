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

## Round 10 — the bin pad was 1.4·r while the prune was r: 18–26 % of all incidences

Round 9 landed: complex @zoom 10 `render+comp` 20.97 + 3.02 → **9.98 + 1.86 ms**, total
45 → **27 ms**; kaos unchanged (19.14 vs 19.57, duplicate-run noise); every identity A/B
byte-equal. So the saturation skip is real, and it is worth what the model said: the frames
where a pixel sits inside *many segments of the same stroke* are exactly the ones that
shrank.

### First: the Round 9 ablation numbers are confounded, use `ART_LIVE_SATURATE=0`

With the skip on, bits 1 and 16 *also* remove the skip, so they are not "one stage off":

* bit 1 (no SDF) leaves `signedDist = 1e6` ⇒ `cov = 0` ⇒ `curMax` never reaches 1 ⇒ no
  saturation ⇒ **more** visits than the baseline. That is why 13.32 > 9.77.
* bit 16 (constant segment address) gives every entry the same coverage: either the first
  entry saturates the stroke (near-free) or none ever does.

So for attribution, run the ablation with the skip disabled — that reproduces Round 7's
meaning (kaos, skip off: 18.87 baseline / 15.41 / 12.91 / 18.98 / 19.56 / 12.61). With the
skip on, `ART_LIVE_ABLATE=0` vs `ART_LIVE_SATURATE=0` is the honest measure of the skip
itself: **20.97 → 9.98 ms** on the zoom-10 layer.

### Where the remaining zoom-10 frame goes (warm)

```
layer 0  render+comp 9.98 | sort 2.98 | scatter 0.92 | xform 0.76
layer 1  render+comp 1.86 | sort 0.41 | scatter 0.41 | xform 0.36
total 27 ms = gpu 18 + bin 6 + paper 1
```

`render+comp` is now walk-bound (the SDF part was mostly saturated away), and the next
largest item is `bin` — 6 ms of CPU. Both are fed by the same quantity: **the number of
(segment, tile) incidences**.

### The change: bin to the prune radius, not to a radius guess

The composite kernels test each pixel with `padding1 + margin` (`margin` = 0.5 px AA for
the AA kernel, `liveNoisePruneMargin` for the noise kernel). `padding1` is the segment's
**shape reach from its chord** — the Bézier/hull deviation folded with the radius, and 4·r
rather than r for a chisel marker. A pixel can only be painted if `chordDist ≤ padding1 +
margin`, so the tiles a segment can touch are **exactly** `AABB(chord) ⊕ (padding1 + margin)`.

The bin, however, used `1.4·r + 1` (`4·r + 2` for markers) — a radius-only guess that
ignored the deviation term entirely and over-padded by 40 % of the radius. It was
conservative, so nothing clipped; it just binned tiles that no pixel of the segment could
ever paint, and every one of those costs a tile-list read, a 64-byte segment load and a
prune test in the walk, plus a slot in the scatter, the sort and the counts.

All three binning stages now use the same reach as the kernel:

* fused GPU transform kernel: `binPad()` = `padding1·radiusFactor + margin`, with
  `margin = max(1, liveNoisePruneMargin(r0, r1))` when the layer runs the noise kernel
  (that kernel prunes with the noise reach for *every* segment of the layer, clean ones
  included, or the soft falloff would clip) and `1.0` px otherwise (0.5 px AA + 0.5 px
  tile/float rounding). `LiveBinTransformParams` gained `noiseLayer`; `liveBinRangeForSeg`
  now takes the pad instead of computing one.
* CPU per-tile plan (`buildSegmentTileIndicesBoxed`, device space): the same expression,
  with `SegmentPadding.pad(reach:margin:)`.
* `padding1 == 0` (the "never prune" sentinel) keeps the historic radius constants in both.

The stroke-block table keeps its own looser pad: it is a *skip* structure, so a too-large
block box only costs a box test, never a visit.

Measured incidences (Linux probe, `ART_LIVE_PROFILE_BIN=… swift test --filter
testProfileBinPlan`, which now prints exact vs radius-only vs pad 0):

| document | radius-only | exact | Δ | pad 0 (lower bound) |
|---|---|---|---|---|
| kaos @zoom 1 | 1 454 923 | 1 185 719 | **−18.5 %** | 516 091 |
| qwerty @zoom 1 | 377 490 | 279 577 | **−25.9 %** | 82 591 |

The walk is linear in incidences and the SDF part is not (it only drops the entries that
could not paint anyway), so expect roughly half of the delta off `render+comp` — ~1.5 ms on
kaos, ~1 ms on qwerty, ~1.5–2 ms on the zoom-10 layer — plus the same ~20 % off `scatter`,
`xform` and the sort's element count.

Also in this round: the block table's usability gate can now **abandon pass 1** as soon as
both upper bounds (block-box area, blocks × dense tiles) exceed half the incidences — it
can only decline from there, and `blockTileEstimate` is monotone. Both bounds are computed
before the pass. Pixels are unaffected (a declined table is the plain walk); it only saves
the camera transform over blocks whose table gets thrown away. The `livebin` skip line now
prints that number as `bound ≥ N`.

### Files

* `ArtQuickLook/ArtRenderShaders/segmentKernels.metal` — `LiveBinTransformParams.noiseLayer`,
  `binPad()`, `liveBinRangeForSeg(p, p1, p2, pad)`.
* `Sources/ArtRenderLibrary/MetalRenderer_LiveCompositing.swift` — param field + `noiseLayer`,
  gate-line wording.
* `Sources/ArtRenderLibrary/RendererTypes.swift` — `SegmentPadding.pad(reach:margin:)` +
  `binDeviceMargin`, the gate's hoisted bounds and early exit.
* `Sources/ArtRenderLibrary/MetalRenderer_Dispatch.swift` — exact pad in the boxed plan.
* `Tests/ArtRenderLibraryTests/TileUnionTests.swift` — exact-pad invariants.
* `Tests/ArtRenderLibraryTests/LiveProfileTests.swift` — the probe's three-pad comparison.
* `SPLAT-DESIGN.md` — this section.

### Run this (metallib rebuild IS needed: `LiveBinTransformParams` grew to 60 bytes)

```
sh Scripts/build-metallib.sh
swift build -c release

# the real gates (the pad change is not optional — no knob: it produces the same pixels)
sh Scripts/stroke-splat-ab.sh --all
sh Scripts/stroke-prune-ab.sh --modes 0,1,2 art/kaos.art
# kaos zoom-1 pixel gate vs art/kaos.png, and qwerty (markers) vs its static render

sh Scripts/composite-ablate.sh --zoom 10 --pan 500,-400 art/complex.art   # with the skip ON
ART_LIVE_BINTIME=1 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 art/kaos.art
ART_LIVE_BINTIME=1 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 art/qwerty.art
ART_LIVE_BINTIME=1 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 --zoom 10 --pan 500,-400 art/complex.art
```

The `livebin` line should show **fewer `chunks` and a lower `render+comp`** for the same
document, with `tiles` unchanged (that is the layer box). If a pixel gate fails, the pad
lost ink — but the pad is the kernel's own prune reach, so that would mean `padding1`
under-reports the shape.

### Still open, in order

1. **`bin` (6 ms at zoom 10, 2–3 ms at zoom 1)** — now the second-largest term on the
   zoomed frame. Its parts are CPU: cull, `combine`, the block-table build, the sort chunk
   plan. Run `ART_LIVE_STROKE_PRUNE=0` on the zoom-10 view to price the table directly; if
   it is most of `bin`, the table needs to be built incrementally (only for the tiles whose
   list actually got long) or dropped there.
2. **Jump the list, not just the segment** — a saturated stroke still reads 4 bytes per
   entry to discover it is saturated. A per-block `jStart` would let it skip to the next
   stroke's first block.
3. **Stage the tile's segments in threadgroup memory** — one threadgroup is already one
   16×16 tile; a preload turns 256 dependent 64-byte loads per entry into one coalesced one.
4. **`xform` 4.3–4.9 ms on kaos** — global atomics into 7800 counters → threadgroup-local
   histogram.
5. **SDF math** — only with an accepted tolerance.

## Round 11 — stage the tile list in threadgroup memory: the walk was a chain of dependent loads

### What Round 10 bought (warm, user's Mac)

| view | before | after |
|---|---|---|
| complex @zoom 10 L0 `render+comp` | 9.98 | **6.76** |
| complex @zoom 10 L1 | 1.86 | **1.55** |
| complex @zoom 10 total | 27 | **21** |
| kaos `render+comp` | 19.14 | **17.76** |
| qwerty `render+comp` / total | 5.49 / 24 | **5.18 / 12** |

All identity gates byte-equal (splat 10/10, prune 0/1/2 on kaos), so the exact pad is
sound. Two things stand out in the numbers:

* `sdf` fell 433 M → 237 M and `chunks` 7813 → 7614 on the zoom-10 layer — the binned set
  really was 20–26 % fatter than the ink.
* the sort fell **2.98 → 0.43 ms** because `passes 1 → 0`: with fewer incidences each
  chunk's bitonic fits one pass, so the co-rank merge disappeared. That is the incidence
  count paying twice (elements *and* passes), which is worth remembering for later rounds.

### Where the 21 ms is now

```
layer 0  render+comp 6.76 | xform 1.05 | scatter 0.65 | sort 0.43
layer 1  render+comp 1.55 | xform 0.57 | scatter 0.34 | sort 0.22
total 21 = gpu 12 + bin 5 + paper 1
```

Ablation (skip ON, `--zoom 10 --pan 500,-400`): 6.77 / 8.37 / 6.94 / 6.04 / 6.21 / 7.83.

Read that with Round 9's warning in mind (bits 1 and 16 un-do the saturation skip, so they
run *longer* than the baseline). What matters is **bit 2 = 6.94 ≈ 6.77 baseline**: with the
SDF switched off, the kernel still costs the whole frame. The SDF, blend and write are now
rounding error; **the entry walk is the frame**.

### Why the walk is expensive even though it "just skips"

Per entry, per pixel, the old loop did:

1. `tileList[tc.start + j]` — 4 B from global;
2. `strokeOfSegment[segIdx]` — a *random* 4 B global load, needed to know whether the entry
   starts a new stroke (and therefore whether the running max must be flushed);
3. `segments[segIdx]` — the 64 B segment record, fetched **before** the prune test, so every
   entry paid it even though the prune then rejected almost all of them;
4. the prune itself, and only then the SDF for the survivors.

Steps 1–3 are a dependent chain, and steps 2–3 are *irregular* addresses. All 256 threads
of the group read the same addresses (a broadcast), so the bytes are not the problem — the
serialized latency chain is: 157 entries × 3 dependent loads is the kernel's critical path.

### The change

The threadgroup that composites a 16×16 tile now stages the tile's prune record once, then
walks it from threadgroup memory:

* `tgSeg[j]` — the global segment index (4 B);
* `tgStroke[j]` — that segment's stroke (4 B), so the boundary test needs no global read;
* `tgChord[j]` — `p1.xy, p2.xy` in device space (16 B);
* `tgPad2[j]` — the segment's prune radius² (4 B), `padding1 + 0.5` for the AA kernel and
  `padding1 + liveNoisePruneMargin` for the noise twin — the same two expressions the walk
  used, just evaluated once per entry per group instead of once per pixel per entry.

That is 28 B × 128 entries = **3.5 KB** of threadgroup memory per group (≈9 groups still fit
a 32 KB budget). The walk then reads four `threadgroup` values per entry, prunes from
`tgChord`/`tgPad2`, and only fetches the 64 B `GPUSplineSegment` for the entries that survive
the prune. The stage loop itself is coalesced (`tileList` ascending, `strokeOfSegment`
ascending, `segments` ascending) and costs one bucket per entry per *group*, not per pixel.

Two details that are easy to get wrong:

* **The stage is chunked.** A tile can hold more entries than the stage (`kaos` averages
  157/tile, so two chunks; a dense zoom-in tile can hold thousands). `base` walks the tile
  list in `LIVE_STAGE`-sized chunks and the walk state — current stroke, running max, block
  cursor, `nextFirst` — lives in registers and carries across chunks. Identical output.
* **No early return.** `threadgroup_barrier` requires every thread of the group to reach it,
  and the old kernel returned early for pixels past the canvas edge (1080 is not a whole
  number of 16 px tiles, so the last tile row *does* hit it). The kernel now clamps the tile
  index instead and skips only the final write, so the whole group runs the same number of
  chunks. (The clamp is a no-op for every group inside the box; a dispatched group can never
  straddle a tile, since the tile size is a multiple of the 16 px threadgroup.)

Exactness is structural, not approximate: the staged values are literally the values the old
loop read from global memory, and the walk order is unchanged. The kernel is a different
kernel, so the **metallib has to be rebuilt**, but no buffer, struct or dispatch changed.

One caveat: for `ART_LIVE_TILE_SIZE > 16` the four (or 9/16) threadgroups of one tile each
stage the whole tile list redundantly, so staging wins less there. The default is 16, where
one group owns exactly one tile.

### Also in this round: `bin` is attributable now

`bin` is 5 ms at zoom 10 and 2–5 ms elsewhere, and until now the Mac had no breakdown (the
Linux probe only approximates it, and it is 6× slower). Under `ART_LIVE_BINTIME=1` the GPU
path now prints one extra line per layer:

```
livebin layer 0: cpu cull 0.42 prep 0.05 counts 0.09 table 1.31 plan+upload 0.18 ms | alloc 0.00
```

* `cull` — the per-stroke viewport test + layer tile box;
* `prep` — visible-stroke bytes + the transform/box params;
* `counts` — the counts readback memcpy + `GpuBinSpec.combine` (prefix sum);
* `table` — the stroke-block table build (`strokeBlockTable`), or ~0 when the gate drops it;
* `plan+upload` — chunk plan, merge plan and the memcpys into the shared buffers.

Gated on `ART_LIVE_BINTIME`, so the shipping path takes no extra timestamps.

### Files

* `ArtQuickLook/ArtRenderShaders/segmentKernels.metal` — `LIVE_STAGE`, the stage in both
  `livePerTileAACompositeKernel` and `livePerTileNoiseCompositeKernel`, prune from the staged
  record, no early return, ablation-comment update.
* `Sources/ArtRenderLibrary/RendererTypes.swift` — `ablate` doc (bits 2/16 mean something
  narrower now: the prune no longer touches the segment).
* `Sources/ArtRenderLibrary/MetalRenderer_LiveCompositing.swift` — per-stage `bin` timing
  under `ART_LIVE_BINTIME`. No pixel or buffer change.
* `SPLAT-DESIGN.md` — this section.

### Run this (metallib rebuild required, no Swift struct change)

```
sh Scripts/build-metallib.sh
swift build -c release

sh Scripts/stroke-splat-ab.sh --all                      # must stay 10/10 identical
sh Scripts/stroke-prune-ab.sh --modes 0,1,2 art/kaos.art # must stay byte-equal
# kaos zoom-1 pixel gate vs art/kaos.png; qwerty marker gate vs its static render

ART_LIVE_BINTIME=1 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 art/kaos.art
ART_LIVE_BINTIME=1 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 art/qwerty.art
ART_LIVE_BINTIME=1 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 --zoom 10 --pan 500,-400 art/complex.art

sh Scripts/composite-ablate.sh --zoom 10 --pan 500,-400 art/complex.art
```

Decision rule for this round: **`render+comp` must fall** (target L0 ≈ 4–5 ms, kaos ≈ 15–16,
qwerty ≈ 4). `tiles`/`chunks`/`sdf` must not move at all — if they do, the stage changed the
entry set, which can only be a bug. If `render+comp` gets *worse*, the walk was
bandwidth-bound rather than latency-bound and the stage can be reverted on its own (it is one
self-contained hunk per kernel).

Also price the CPU side while the metallib is built — this is the data Round 12 needs:

```
ART_LIVE_STROKE_PRUNE=0 ART_LIVE_BINTIME=1 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 --zoom 10 --pan 500,-400 art/complex.art
ART_LIVE_STROKE_PRUNE=0 ART_LIVE_BINTIME=1 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 art/qwerty.art
```

`bin` at zoom 10 is 5 ms and qwerty 3 ms; the difference between those two lines and the
default run is the block-table build's price on each. If it is most of `bin`, the table wants
to be built only for tiles whose list actually got long (or dropped where the saturation skip
already covers the tile).

### Result (Mac, warm; committed as `15537ca` + compile fixes in `4f3bfe1`)

| view | before | after |
|---|---|---|
| complex @10 L0 `render+comp` | 6.76 | **5.61** |
| complex @10 L1 | 1.55 | **1.39** |
| complex @10 total | 21 | **19** |
| kaos `render+comp` | 17.76 | **14.29** |
| kaos total | 27 | **23** |
| qwerty `render+comp` / total | 5.18 / 12 | **4.89 / 12** |

`tiles`, `chunks`, `sdf` and all pixel gates unchanged, as required.

The ablation is the interesting part: **6.94 → 5.59 / 6.00 / 3.02 / 4.80 / 5.05 / 15.16** (bits
0/1/2/4/8/16). Bit 2 has fallen from 6.94 to **3.02**, so the walk floor really was the
dependent-load chain — it halved. What is left of the 5.6 ms is roughly 1.2 SDF + 0.8 blend
+ 0.5 write, so a third of the frame is now real shading work rather than stalls.

Two ablation bits are now *invalid measurements*, not just noisy ones: bit 1 (no SDF) and bit
16 (constant segment) both change `curMax`, which changes when the Round 9 saturation skip
fires, so they run *longer* than the baseline (bit 16 = 15.16). Only bits 2/4/8 are additive.
Bit 16 in particular can no longer isolate the 64 B fetch: with the prune reading the staged
chord, the fetch only happens for entries that are about to run the SDF anyway.

The round missed the 17–18 ms target by ~1 ms, and the `cpu` line that landed with it says
exactly where: `bin` is 5 ms at zoom 10, of which `table` is 3.33 ms.

### Still open, in order (as of Round 12)

1. **`bin`** — done in Round 12: the block-table build was the whole cost and it has been
   retired (see the next section).
2. **`xform` 1.0–1.1 ms per layer** (4.4 ms on kaos) — global atomics into a per-tile counter
   array; a threadgroup-local histogram first would cut most of the atomic traffic.
3. **kaos' `render+comp` (14.3 ms)** — 1.19M incidences and 303M SDF evals; the walk floor is
   small now, so this is shading-bound. Either fewer incidences (the pad is already exact) or
   SDF math, which needs an accepted tolerance.
4. **SDF math** — only with an accepted tolerance.

## Round 12 — retire the stroke-block table: the stage made it a net loss

### What the `cpu` line said

Round 11's per-stage `bin` timing paid for itself immediately. At zoom 10 the frame was

```
livebin layer 0: cpu cull 0.20 prep 0.00 counts 0.05 table 3.33 plan+upload 0.20 ms
```

`table` — the `strokeBlockTable` build — is **3.33 ms of a 5 ms `bin`**, i.e. ~17 % of the
whole 19 ms frame, spent on the CPU to build a pruning table for the GPU. qwerty says the same
(1.86 ms of 3 ms). The block table was Round 5's answer to an expensive segment walk, and
Round 11 removed that problem.

The `ART_LIVE_STROKE_PRUNE=0` runs price what the table buys on the other side:

| view | `render+comp` with table | without | `bin` with | without |
|---|---|---|---|---|
| complex @10 | 5.61 (5.19 cold) | **4.71** | 5 | **1** |
| qwerty | 4.89 | **4.63** | 3 | **1** |

So the table does not even break even on the GPU any more: the block cursor (one 24 B global
load + a `segStart` compare per entry, plus the `do/while`) costs about as much as the staged
prune it skips, and at complex@10 it is *slower* with the table than without. The staged prune
is four threadgroup loads and ~10 flops; the only way a block skip wins is by covering a long
run of entries at once, and a `pruneBlockSize`-segment block padded by `1.4·r·radiusFactor`
rarely misses a zoomed-in pixel completely.

The two views the usability gate admitted, and how far off the gate's `bound × 2 ≤ incidences`
rule was (Linux profile, zoom 1):

| view | incidences | `bound` | ratio |
|---|---|---|---|
| kaos | 1 185 719 | 592 883 | 0.50 → gate declines |
| qwerty | 279 577 | 92 328 | 0.33 → built, net loss |
| complex @1 | 153 247 | 35 370 | 0.23 → built, net loss |

Halving the candidate count is nowhere near enough once the per-entry prune is free: the table
would have to skip the large majority of entries *and* be nearly free to build.

### The change

`LiveConfig.strokePruneEnabled()` is **off by default**. `ART_LIVE_STROKE_PRUNE=1` re-enables the
gated build, `=2` forces it past the gate (unchanged). The kernels, buffers and dispatch are
untouched: with no table the per-tile kernels see `gCount == 0` and take the direct-walk branch
that `ART_LIVE_STROKE_PRUNE=0` has always exercised, which is why the pixel identity argument is
the existing A/B rather than a new one.

Nothing else in the frame changes: the per-block arrays (`blockRects`, `blockMaxRadius`, …) are
built once per document in `BinRefState`, not per frame, and the empty header/entry stubs still
have to be bound, so the disabled path costs a `memcpy` of nothing.

The `livebin … prune table skipped` line is now printed only when the table was actually asked
for, so the default log stays quiet.

Also in this round (comment/hygiene only):

* the Round 11 staging kernels declare `threads_per_threadgroup` / `thread_position_in_threadgroup`
  as `uint2` and drop the `z` terms — the live group is 16×16 with `depth: 1`, so `z` is always 1
  and the flatten `tid.x + tid.y * tpg.x` is exact. (The compile error was `tid.z` on a `uint2`;
  there is no `uint3` requirement and no optimisation that needs `z`.)
* `LiveProfileTests` prints the gate's `bound` next to the block/entry counts.

### Expected numbers

| view | before (Round 11) | expected |
|---|---|---|
| complex @10 `bin` / `render+comp` / total | 5 / 5.61 / 19 | **~1.7 / ~5 / ~15** |
| qwerty `bin` / total | 3 / 12 | **~1.1 / ~10** |
| kaos | 2 / 23 (table already declined) | unchanged |

The frame target (~16 ms at zoom 10) is reached by this round alone if the estimate holds.

### Run this (no kernel change; metallib rebuild only to keep the binary in step with the comment edit)

```
sh Scripts/build-metallib.sh
swift build -c release

sh Scripts/stroke-prune-ab.sh --modes 0,1,2 art/kaos.art   # still byte-equal, all three
# kaos zoom-1 pixel gate vs art/kaos.png; qwerty marker gate vs its static render

ART_LIVE_BINTIME=1 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 art/kaos.art
ART_LIVE_BINTIME=1 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 art/qwerty.art
ART_LIVE_BINTIME=1 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 --zoom 10 --pan 500,-400 art/complex.art
```

Decision rule: `bin` must drop by ~3.3 ms (complex @10) and ~1.9 ms (qwerty), `render+comp` must
not rise, and `tiles`/`chunks`/`sdf` must be identical. If `render+comp` moves *up* while the
pixel gates pass, the table was doing real work somewhere the three views do not cover — re-run
`--modes 0,2` on that view before keeping the new default.

### Still open, in order

1. **`xform`** — 1.0 ms per layer at zoom 10, **4.4 ms on kaos** (321k segments): each segment
   scatters atomically into every tile it touches. A threadgroup-local histogram over the tile
   range, flushed once per group, removes all but a fraction of the global atomics.
2. **kaos `render+comp` 14.3 ms** — 1.19M incidences, 303M SDF evals, walk floor now small. This
   is shading-bound: either fewer incidences or SDF math, and the latter needs an accepted
   tolerance.
3. **`scatter` / `sort`** — 0.65 / 0.45 ms per layer; only worth it after the two above.

## Round 13 — the 4.4 ms `xform` was 20 MB of system-memory reads, not atomics

### The number that did not fit

Round 12 queued a threadgroup-local histogram for `xform`, on the theory that kaos'
4.4 ms was atomic contention: 321 611 segments scatter 1.19 M increments into 7800 tile
counters. The ablation says otherwise. Each variant below is a temporary kernel patch on
kaos @zoom 1, warm, `ART_LIVE_BINTIME=1`; "gpu" is the whole frame because with the counts
zeroed the frame early-returns after the transform.

| variant | time |
|---|---|
| empty kernel (`return` right after the bounds check) | **0 ms** |
| no counting atomics (transform + stores kept) | **4.0 ms** |
| no `outSegs`/range stores (rare store keeps the math alive) | **4.0 ms** |
| `refSegs[0]` instead of `refSegs[gid]` (math + stores kept) | **0 ms** |
| shipping | 4.36 ms |

So the atomics are worth ≈0.3 ms and everything is worth 0 except one NULL pointer:
the per-thread 64 B `GPUSplineSegment` read. 321 611 × 64 B = **20.6 MB**, and 4 ms for
20 MB is 5 GB/s — PCIe speed, not VRAM speed.

The reason: `ensureBinRefState` uploaded the read-only reference arrays with
`.storageModeShared`. On a **discrete** GPU that is system memory; the GPU reads it
across the bus every frame. (On Apple Silicon / integrated GPUs `.shared` is the same
memory, so the bug is invisible there — which is why it survived every earlier round.)
The comment on `LiveBinRefLayer` even said "reference space (.shared)" as if the storage
mode were part of the design.

### The change

`ensureBinRefState.upload` now writes the array into a one-off `.shared` staging buffer
and blits it into a `.private` destination, then waits once. It runs once per
document/layer (`ensureBinRefState` is cached by document identity), so the extra command
buffer is a load-time cost, not a frame cost. Four arrays move to VRAM:

* `refSegments` — 64 B × N (kaos: 20.6 MB) — read in full by the transform kernel;
* `segStroke` — 4 B × N — read per incidence in the composite's stage loop;
* `strokeFlags` — 4 B × S — read per stroke/block in the walk;
* `strokeColors` — 16 B × S — read per stroke in the walk and the splat composite.

`strokeVisible` stays `.shared`: the CPU rewrites it every frame by design.

No kernel, binding, dispatch, struct or metallib symbol changed. `frameSegments` and
`ranges` were already `.private`; this makes the *input* to the transform match its
output.

### Result (Mac, warm, `ART_LIVE_BINTIME=1`; before = Round 12 data)

| view | stage | before | after |
|---|---|---|---|
| kaos | `xform` | 4.37 | **0.71** |
| kaos | `scatter` / `sort` | 0.63 / 0.54 | 0.41 / 0.44 |
| kaos | `render+comp` | 14.29 | 14.05 |
| kaos | total (gpu) | 23 (20) | **18–19 (16)** |
| qwerty | `xform` / total | 1.14 / 10 | **0.64 / 9** |
| complex @10 L0 | `xform` | 0.99 | **0.79** |
| complex @10 L1 | `xform` | 0.59 | **0.52** |
| complex @10 | total | 15 | **14–15** |

`render+comp` is unchanged within noise, as it must be — this round moves memory, not
work. The 0.7 ms left in kaos' `xform` is ~45 MB of read+write at ~60 GB/s plus the
dispatch, i.e. the array traffic is now cheap.

Pixel gates: `stroke-splat-ab.sh --all` 10/10 identical; `stroke-prune-ab.sh --modes
0,1,2 art/kaos.art` byte-equal; kaos @zoom 1 vs the static render unchanged (peak error
1 LSB, the long-standing live-vs-static rounding difference); **live-vs-live** hashes of
kaos, qwerty and complex @10 before/after the change are identical (the pre-change binary
was rebuilt from `git stash`). `swift test`: 106 tests, 4 skipped, 0 failures.

### Why the histogram would have been wasted work

The proposed threadgroup-local histogram targets the one part of this kernel that is
cheap. Priced against the measurements: if the 1.19 M atomics cost ~0.3 ms, even a
perfect aggregation can only save that fraction, and it would add ~9 KB of
threadgroup memory (plus a flush pass) to a kernel that is already latency-bound on a
20 MB read. The right first question was "where do the 4.4 ms go", and the answer was a
buffer storage mode.

### Tile size 8: exact, and only worth it for kaos (measured, not adopted)

While the SDF was under the microscope, the obvious exact lever was tried: `tileThreads`
was generalized so a per-tile dispatch uses an 8×8 group for an 8 px tile (the tile-size
knob already existed for 16…64, but tile 8 previously made groups straddle tiles). All
three views are **byte-identical at tile 8 vs 16**, as expected: tiles partition pixels
and the bin pad is exact.

| view | `render+comp` 16 → 8 | `scatter` | `sort` | total |
|---|---|---|---|---|
| kaos | 14.04 → **11.45** (`sdf` 303.5 M → 168.3 M) | 0.42 → 1.02 | 0.45 → 0.87 | 19 → **17** |
| qwerty | 4.47 → 3.7–4.4 | 0.24 → 0.37 | 0.89 → **2.34** | 9 → 10–11 |
| complex @10 | 5.11/1.38 → 4.31/0.97 | 0.67 → **2.25** | 0.45 → 1.07 | 15 → 17–18 |

Incidences grow 2.2× (kaos 1.19 M → 2.63 M) because a segment touches ≈(1+(L+2R)/tile)²
tiles. Half the pixels per incidence is a real win for `render+comp`, but the scatter,
sort and transform-count costs scale with incidences, so it only pays when `render+comp`
is nearly the whole frame (kaos). It is not a default; the tile-8 plumbing was reverted so
the measured default stays 16.

Two numbers from the same session that bound what is left:

* **The walk floor is prune math, not staging.** `ART_LIVE_ABLATE=2` at tile 16 vs 32:
  3.44 vs 6.66 ms while pixel-entry pairs go 303 M → 697 M and staged bytes *halve*.
  Fitting `a·pairs + b·incidences` gives ≈2.7 ms of per-pixel prune + ≈0.7 ms of stage
  loads at tile 16.
* **The SDF is one function.** Temporarily widening the ablation mask (it clamps at 31)
  and skipping one segment type at a time: type 0 (capsule) ≈ 0.7 ms, type 1
  (`sdSplineSegment`) ≈ **4.1 ms**, type 2 (soft envelope) ≈ 1.1 ms of the 7.0 ms SDF
  total. Only ~11 % of the 303 M pixel-entry pairs survive the prune, so the SDF is
  already evaluating close to the ink area; a tighter prune has little to win.

### Files

* `Sources/ArtRenderLibrary/MetalRenderer_LiveCompositing.swift` — private staging blit in
  `ensureBinRefState.upload`; no other logic.
* `Sources/ArtRenderLibrary/MetalRenderer.swift` — `LiveBinRefLayer` storage-mode
  comments (`.shared` → `.private`).
* `SPLAT-DESIGN.md` — this section.

### Run this (no kernel change; metallib rebuild only to keep the checked-in binary in step)

```
sh Scripts/build-metallib.sh
swift build -c release
swift test

sh Scripts/stroke-splat-ab.sh --all                      # 10/10 identical
sh Scripts/stroke-prune-ab.sh --modes 0,1,2 art/kaos.art # byte-equal
# kaos zoom-1 vs the static render; qwerty marker visual check

ART_LIVE_BINTIME=1 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 art/kaos.art
ART_LIVE_BINTIME=1 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 art/qwerty.art
ART_LIVE_BINTIME=1 .build/release/art2png --live-view --warmup 1 --viewport 1920x1080 --zoom 10 --pan 500,-400 art/complex.art
```

Decision rule: `xform` must collapse on kaos/qwerty (≈4.4 → ≈0.7, ≈1.1 → ≈0.6) and
`render+comp` must not move. `tiles`/`chunks`/`sdf` must be identical. If `xform` does not
move on a discrete GPU, the upload did not reach the new `upload` (check that
`ensureBinRefState` rebuilt — it is cached per document identity).

### Still open, in order

1. **kaos `render+comp` 14.0 ms** — now the whole frame. ~2.7 ms walk (prune per pixel),
   ~4.1 ms `sdSplineSegment`, ~1.1 ms soft envelope, ~0.9 ms blend, ~0.3 ms write. The
   exact levers are incidence count (tile 8: wins kaos by 2 ms, loses qwerty/complex) or
   cheaper spline math; the latter changes pixels and needs an accepted tolerance.
2. **`bin` ~2 ms** — `cpu cull` is 1.0 ms on kaos for 2214 strokes (~450 ns each), and the
   corner transform is computed twice per visible stroke (`intersects` + the AABB). The
   segment-level tile range already culls exactly on the GPU; dropping the CPU stroke cull
   (and binning against the full canvas grid) would remove the loop, at the cost of a
   full-grid prefix.
3. **`scatter` / `sort`** — 0.4 / 0.45 ms (kaos), 0.25 / 0.9 ms (qwerty, two merge passes).
4. **SDF approximations** — only with an accepted tolerance.


## Round 14 — `bin`'s CPU cull, and why the view stutters under a 16 ms budget

### `cpu cull`: 1.0 ms → 0.4 ms, no pixel change

The per-frame cull in `renderCachedLayerGPUThrowing` walked `layer.ops` — an enum whose
`.stroke` payload carries a `[GPUSplineSegment]` — twice (a cut scan, then the cull), and
transformed the same four bounds corners twice per stroke (`LiveRenderCache.intersects`
plus the tile AABB). Three changes:

* `LiveCachedLayer` now precomputes `strokeBounds: [CGRect]`, `strokeIsMarker: [Bool]` and
  `hasCut` once at cache build; the cut scan is gone and the cull walks flat arrays.
  `LiveRenderCache.strokeCount(at:)` uses it too (it ran a `reduce` over `ops` every frame
  just to report the culled count).
* The four corners are transformed once, inline, in Double — exactly CGAffineTransform's
  `x·a + y·c + tx`, `x·b + y·d + ty` — and both the visibility test and the AABB read the
  result. Same strict inequalities; no `CGPoint.applying` calls.
* The layer box is the tile AABB of the *union* of the visible strokes' ink boxes instead
  of a per-stroke union of tile boxes. `floor`/`ceil` are monotone, so
  `⋃ᵢ boxᵢ == box(⋃ᵢ aabbᵢ)`: the same tiles from one conversion for the layer.

Measured on Mac (warm, `ART_LIVE_BINTIME=1`, 5 runs):

| view | `cpu cull` before | after |
|---|---|---|
| kaos (2214 strokes) | 1.01 | **0.40–0.45** |
| qwerty (1141) | 0.54 | **0.21–0.25** |
| complex @10 L0 / L1 | 0.19 / 0.12 | **0.13 / 0.08** |

`bin` reports 2 → 1 ms on kaos; `render+comp`/`xform`/`tiles`/`chunks`/`sdf` are unchanged,
as they must be. Warm live-view hashes for kaos, qwerty and complex @10 are byte-identical
to Round 13's (`d807df…`, `36e9b1…`, `55c188…`). Gates: `stroke-splat-ab.sh --all` 10/10,
`stroke-prune-ab.sh --modes 0,1,2` byte-equal, `swift test` 107 tests / 4 skipped / 0
failures, and the Xcode app + extension build.

### The stutter: the frame cap was pacing from the wrong end of the frame

`LiveFrameThrottle` measured the gap from when the previous render **finished**. On a 60 fps
cap a 10 ms render therefore waited another 16.7 ms *after* finishing: a 26.7 ms cycle
(37 fps) with a 16.7 ms idle gap between every pair of frames. The display then shows
frames at 16.7/33.3 ms intervals in an irregular pattern — stutter while "staying way below
16 ms". It is now start-to-start: a 10 ms frame waits 6.7 ms and the cadence is a steady
16.7 ms. A unit test pins the cadence (`testFrameThrottleDoesNotAddRenderTimeToTheInterval`).

Two related bugs found on the way:

* The **app window never applied the cap at all** — `LiveDocumentSession` built a throttle
  and never consulted it, so the FPS setting only worked in the Quick Look extension.
* The app posted its timing string through `@Published` on **every** frame, making SwiftUI
  re-lay-out a text view inside the present path at frame rate. Now 5 Hz. The extension's
  HUD had the same shape (an unrounded `fps` in `LiveHUDState` changed every frame, so the
  equality check never matched and the HUD view re-drew per frame); the value is rounded to
  whole fps now, which is what it prints anyway.

### Why there is still ~1–2 frames of input lag (analysis, not yet changed)

The chain per gesture frame is:

```
mouse event → main thread → session hop → CPU bin (~1.5 ms)
            → cb1 (xform) waitUntilCompleted
            → cb2 (scatter/sort/render, 7–14 ms) waitUntilCompleted
            → main thread → display() → present pass → drawable.present() → next vsync
```

Two structural costs:

1. **The render starts when the event arrives, not when the display flips.** Whatever phase
   of the refresh that is, the present can only land on the following vsync, so the frame
   waits up to a full refresh (16.7 ms) before it is shown. A render that starts late in a
   refresh misses the next flip entirely.
2. **Both GPU stages are CPU-synchronised** (`waitUntilCompleted`), after which the main
   thread is hopped to and only then is the present encoded. The physics of the flip do not
   change — the canvas must be complete first — but the CPU cannot begin the next frame's
   binning during the previous frame's GPU work.

`MTKView` itself does not add a frame here: `presentsWithTransaction` is left at its default
(false), nothing waits on the drawable, and `present()` schedules the flip at the next
vsync. The lag is the on-demand start phase plus the render duration, not MTKView.

The fix that removes both the phase and the cap's vsync drift is to drive the render start
from a display link (render right after a flip, present at the next flip: a constant one
frame), with the pending request coalesced exactly as it is now. It is deferred because it
needs interactive A/B (it changes how the gesture feels) and the targets ship for macOS
12, where `NSView.displayLink(target:selector:)` (macOS 14) is unavailable — it has to be a
`CVDisplayLink` (deprecated in 15 but functional). The 60 fps cap now behaves, but with an
app-side timer whose period is nominally the same as the panel's, phase drifts slowly and
periodically costs one extra refresh; the display link also removes that.

### SDF / spline math: what is GPU work and what the "table" would be

`sdSplineSegment` is the 4.1 ms item, and it runs **per pixel-entry on the GPU**, not on the
CPU. Each call currently rebuilds the four Catmull-Rom coefficient vectors from `p0…p3`
inside `getSplinePos`, and does that **ten times per pixel** (7 pre-samples + 2 Newton steps
+ the final position) plus two tangents. The per-tile walk already stages the segment into
threadgroup memory, so the same coefficients can be staged once per (tile, segment) and
every evaluation becomes three multiply-adds per component. That is the exact lever: no
changed sample count, no changed iteration count, gated by byte-identical PNGs. Expect
~1–2 ms of the 4.1 ms; worth an A/B before adopting.

The "table" (what I meant by fitting into it) is the *approximate* alternative: at cache
build, sample each spline segment into an arc-length table (say 8–16 positions + radii) and
have the kernel measure distance to that polyline instead of re-solving the cubic. It
removes the per-pixel cubic work entirely, but it changes the distance field: the reported
deviation would be a fraction of a pixel near the curve and up to one sample spacing in
high-curvature spots, i.e. different AA edges (a few 1-LSB pixels per segment), not a visual
change. I would implement it only with a stated tolerance and report `compare -metric
AE/PAE` plus the max error against the exact render for review.

CPU-side splines (building `GPUSplineSegment`s, `remap`, cache build) are **one-time work**
— "cache built in 25 ms" on complex, paid at open. Multi-threading it would only shorten
time-to-first-frame; it cannot move the frame time, because the per-frame CPU path is the
bin/cull/prefix above and never touches spline math.

### Still open, in order

1. **Display-link frame pacing** (above) — the remaining stutter/latency item; needs an
   interactive A/B and a `CVDisplayLink` shim for the macOS 12 target.
2. **Spline coefficients in the stage** — exact, ~1–2 ms of kaos' 14 ms; byte-gated.
3. **Heavier real documents** — `LiveRenderCache` declines any layer with cut/paste
   (`needsRebuild`/`hasCut`), which is what pushes real artwork onto the slow path. That is
   the next real bench, and it needs the cache to replay cut/copy ops.
4. `scatter` / `sort` — 0.4 / 0.45 ms (kaos), 0.25 / 0.9 ms (qwerty).
5. SDF approximations — only with an accepted tolerance.

## Round 15 — cut / copy / paste / merge go into the cache

Round 14 ended with the open item that mattered most: `LiveRenderCache` declined any layer
holding a cut or paste, so real artwork (and anything that had been pasted, merged or
erased as a shape) was re-walked through the action list on **every** frame. This round
caches those ops at a reference camera and replays them, remapped per frame.

### The cache model

`LiveCachedOp` grows `.cut(rect:selectionFrame:)` and `.paste(...)`; `LiveDeviceOp`
mirrors them. At cache build the ops are stored exactly as the static path would build them
at the reference camera (zoom 1, centred, the cache's `baseTransform`). Per frame they are
mapped by the camera delta `C = camera ∘ ref⁻¹`:

| op | per-frame remap |
|---|---|
| stroke | segments move by `C`; radii and `padding1` scale by `sqrt\|det C\|` |
| cut | `inverse = liveBase⁻¹ ∘ m1` (device → selection frame) |
| paste / merge | segments move by `C`; `invAffine` → `mask.inv ∘ C⁻¹`; `sourceToDestination` → `C⁻¹ ∘ ref ∘ C` |

`a.concatenating(b)` applies `a` first, which is where the one **real bug** of the round
was: the cut meta was stored as `selectionFrame.concatenating(inverse)` — the camera on the
wrong side, correct only when it was identity. The symptom was a cut-paste document that
looked right at zoom 1 and fell apart away from it: cached-vs-rebuild at zoom 2 was 113 136
pixels with errors up to 255 LSB. With `inverse.concatenating(selectionFrame)` it is 235
pixels / 1 LSB at zoom 2 and 17 pixels / 1 LSB at 0.5. The unit test that pinned the old
order (`testCutRecomposesAgainstAnyCamera`) now states the invariant the kernel actually
needs: a canvas point through the live base and then the cut lands where the selection
frame puts it, at any camera.

### One command buffer, in document order

`renderCachedLayerMixedIntoLiveCanvas` splits a cached layer into maximal stroke runs and
the cut/paste/merge ops between them. Every step is encoded into one compute command buffer
and committed once: clear → stroke runs (per-tile plan, or per-stroke bin when ineligible) →
for each paste, a boxed dispatch → merges grouped by `mergeID` around the stroke runs that
sit inside them. One `waitUntilCompleted` per layer, so a mixed layer costs three textures
committed in order, not one wait per op.

Two things this exposed:

* The per-tile AA/noise kernels assumed they owned the target and *wrote* their pixels.
  That is true for the pure path (the canvas was just cleared) but not after a cut or a
  merge, which leave pixels inside the same tile. They now start from
  `acc = active ? target.read(pixel) : 0` and only write pixels a stroke actually touched.
  On `doodle` (57 strokes, 7 merges, then 951 strokes on top) the wrong-pixel count fell
  from 252 589 to 26 935, all 1 LSB.
* Paste dispatch was a full-canvas grid: every paste paid for every tile. `PasteBoxParams`
  (buffer 6) carries the origin and box size, so one dispatch covers exactly the paste's
  own tile box. The static path passes `(0,0)` and the full grid — unchanged.

### Exact paste binning: `padding1`, not `1.4·r`

Pastes were binned with the historic radius pad (`1.4·r + 1`), which on a radius-188 stamp
is ~76 px of slack on every side. They are now binned from the same exact reach the
composite kernel prunes with (`padding1`, which already folds the Bézier hull and the
marker sweep), plus the same 1 px device margin, and — because a paste's segments are
source-space while the box is transformed into destination space — divided by the map's
uniform scale `sqrt|det|` before the transform. On `cutpaste` (2047 pastes): box tiles
942 890 → 539 781, GPU 195 → 127 ms, byte-identical PNG.

The paste kernels also got the per-pixel prune the stroke kernels have had since Round 7
(`liveSegPruned`, with the segment's padding1 shrunk by the similarity scale; the noise
margin for noisy segments). Byte-identical on `doodle` and `cutpaste`, ~5 % of paste GPU.

### The expensive thing was printing: per-op environment reads

After the changes above `cutpaste` still took 497 ms, and the mixed plan alone was 415 ms
for 2047 pastes — 200 µs per paste. The cause was not the binning: it was
`ProcessInfo.processInfo.environment["ART_…"]` sitting inside the per-paste loop (two A/B
hooks, plus a debug print check). Each read bridges the whole environment dictionary, so it
costs ~0.1–0.2 ms. Hoisted to static `let`s read once, and the hooks removed:

| document (1920×1080, zoom 1, warm) | before | after |
|---|---|---|
| cutpaste — 36 821 segs, 11 cuts, 2 047 pastes | 497 ms (bin 282, gpu 195) | **177 ms** (bin 34, gpu 127) |
| doodle — 90 916 segs, 7 merges | 42 ms (bin 19, gpu 10) | **29 ms** (bin 14, gpu 8) |
| kaos — 321 611 segs, no cuts/pastes | — | 64 ms (bin 1, gpu 19) |

The lesson is a rule now: never read the environment per op. `LiveConfig` has one reader per
knob, called once per frame or once per process.

### Exactness

At zoom 1 the cached path and the static render agree to 1 LSB — the same envelope as the
stroke-only cache (AA edge rounding from device-space remap, no structural difference):

| view | live vs static AE | max channel error |
|---|---|---|
| kaos | 42 px | 1 LSB |
| doodle | 26 935 px | 1 LSB |
| cutpaste | 9 070 px | 1 LSB |

Away from zoom 1 the cache is approximate by construction: it replays ops from the
reference camera instead of re-deriving them, so AA edges move by float rounding, and a
cached layer commits three textures in order where the rebuild path re-flattens after every
op. Cached vs the rebuild path (`ART_LIVE_REBUILD_ALL=1`):

| view | @2 | @0.5 |
|---|---|---|
| kaos (stroke-only) | 324 px / 28 LSB | — |
| doodle | 5 459 px / 26 LSB | 1 590 px / 7 LSB |
| cutpaste | 235 px / 1 LSB | 17 px / 1 LSB |

`kaos` is the control: a stroke-only document that never touched a cut/paste still shows
324 px / 28 LSB at zoom 2, so the amplitude is the reference-camera remap, not the new ops.
`ART_LIVE_REBUILD_PASTE=1` / `ART_LIVE_REBUILD_ALL=1` remain as documented A/B knobs for
this comparison (off by default; they are the reference semantics the cache is checked
against).

Gates: kaos static byte-identical to `art/kaos.png`; live-vs-static 1 LSB on kaos, doodle
and cutpaste; `stroke-splat-ab.sh --all` 10/10 identical; `stroke-prune-ab.sh --modes 0,1,2`
byte-equal on kaos, doodle and cutpaste; `swift test` 107 tests / 4 skipped / 0 failures;
Xcode app + extension build; `build-metallib.sh` verifies all 31 kernels and the installed
metallib matches a fresh build of the sources.

### What is left, in order

1. **The mixed path still bins strokes on the CPU.** `doodle`'s 14 ms of `bin` is 90 916
   segments through `buildSegmentTileIndicesBoxed` + `SegmentBinner.bin` (8 stroke runs
   around 7 merges); the pure path does the same job on the GPU in ~1 ms. Reusing the GPU
   binner for stroke runs inside the mixed command buffer is the next ~11 ms on that
   document (29 → ~18 ms) and it is the structural fix, not a micro-optimisation. A
   pointer-based rewrite of `SegmentBinner.bin` measured no difference, so the win has to
   come from moving the work to the GPU.
2. **`cutpaste` is now GPU-bound at 127 ms** for 2 047 pastes × ~264 tiles each, with 1–11
   masks per paste. That is overdraw of the canvas, not per-op overhead: reducing it means
   merging non-overlapping pastes into one dispatch or pruning the mask loop by rect AABB,
   and it is a synthetic stress document — the real-art target is the stroke + merge case.
3. **Spline coefficients in the stage** (Round 14, item 2) — the exact lever for the pure
   path, still byte-gated.
4. Display-link pacing (Round 14, item 1) — unchanged, still needs an interactive A/B.


## Round 16 — mixed layers bin on the GPU once; 8×8 tiles

Round 15 ended with two known costs: the mixed path still binned every stroke run on the
CPU (its open item 1, ~11 ms of `doodle`'s frame), and the per-tile walk was the floor on
every document. This round removes the first and measures a second, smaller lever.

### One GPU bin per mixed layer, rendered as stroke ranges

`renderCachedLayerMixedIntoLiveCanvas` no longer builds a CPU per-tile plan per stroke run.
It first splits the layer into `MixedStrokeRun`s — the op range, the reference stroke ids
it covers, whether it contains noise or chisel-marker strokes — and then, when every run
can use the same per-tile kernel, calls `prepareMixedGPUBin` **once for the whole layer**:
the same transform+count → CPU prefix → scatter → chunk sort → merge pipeline the pure
path uses. Each work item is then encoded in document order into the same command buffer,
and a run renders as its own sub-rectangle of that layer's tile grid.

Two filters make that exact without re-binning per run:

* `PerTileParams` grew `tileGridStride` and `tileArrayBase`, so a run's dispatch can start
  inside a wider tile grid than its own box (`localTile = base + y·stride + x`).
* `strokeLo` / `strokeHi` bound the reference strokes a dispatch may composite. The tile
  lists are ascending by segment index and stroke ids are non-decreasing with segment
  index, so a run's strokes are a contiguous slice of every list: entries below the range
  belong to earlier runs (already composited) and the first entry above it ends the pixel's
  work for that dispatch, after compositing its last stroke. `LiveDeviceOp.stroke` carries
  the stroke's reference ordinal (`strokeID`, counting culled strokes, matching
  `strokeBounds` / `ensureBinRefState`) to derive that range from an op range.

Everything else is unchanged: cuts erase in place, pastes dispatch their destination box,
merge groups render into the fragment texture and flatten once, and the layer stacks onto
the canvas at the end — one command buffer, two waits per layer.

A bug this exposed: `ensureBinRefState` validated the reference buffers with
`cachedSegmentCount`, which includes paste geometry. A mixed layer therefore rebuilt its
58 k-segment reference buffer **every frame** — ~8 ms hidden inside what the timing calls
"cull". `LiveCachedLayer.strokeSegmentCount` is the stroke-only count, which is exactly what
that buffer holds. Cached-vs-rebuild PNGs at zoom 2 and 0.5 are identical for doodle,
y-flip and cutpaste (the rebuilt path re-derives every op, so a stale reference cannot hide
there).

Measured warm, 1920×1080, zoom 1:

| document | Round 15 | now |
|---|---|---|
| doodle — 1 008 strokes, 90 916 segments, 7 merges | 29 ms (bin 14, gpu 8) | **16–17 ms** (bin 4, gpu 9) |
| y-fliptest-freetransform | 14–15 ms (bin 6) | **12–13 ms** (bin 4, gpu 7–8) |
| cutpaste — 2 047 pastes | 177 ms (bin 34, gpu 127) | 179 ms (bin 33, gpu 132) |
| kaos — no cuts/pastes (control) | 20 ms (bin 1, gpu 19) | 20 ms |

`cutpaste` does not move because it is paste-bound, not stroke-bound: 541 k dispatched tiles
and 6.9 G per-pixel SDF evaluations come from the paste boxes, not from the two strokes. The
mixed bin removes the per-run planning; it cannot remove overdraw.

### 8×8 tiles: fewer list entries, four times the lists

A tile must be a whole number of per-tile threadgroups, so the tile size was previously
16…64. It is now 8 (an 8×8 group, exactly one tile per group) or a multiple of 16 in 16…64
(one or more 16×16 groups); `perTileThreads` caps the group at 16×16. The staged tile list
and its barrier still cover exactly one tile, which is the invariant the walk depends on.

The reason to care is the cost model the old comment got wrong. Each pixel walks every
entry whose *tile* its padded box touches, so the evaluation count scales like
`(tileSize + pad)²`, not "invariantly": measured on kaos, 32×32 tiles cost 697 M SDF
evaluations against 303 M at 16×16, and 8×8 costs 168 M. Rendering is byte-identical to the
16×16 grid on kaos, doodle, cutpaste and y-flip (only the decomposition changes; the walk
order and prune are untouched).

| document | 16×16 | 8×8 |
|---|---|---|
| kaos | 20 ms (gpu 19) | **18 ms** (gpu 16) |
| doodle | 18 ms (gpu 11) | **16 ms** (gpu 8) |
| qwerty | 8 ms (gpu 6) | **7 ms** (gpu 5) |
| logo-sketch_03 — 4 layers | **36 ms** (gpu 30) | 41 ms (gpu 32) |

The multi-layer regression is the sort, not the render: with four times the tiles, layer
0's chunk count goes 2 834 → 9 936 and its sort 1.7 → 7.7 ms, while `render+comp` *drops*
11.2 → 9.4 ms. Shrinking the sort chunk (128, 64) and reverting to the heapsort both
measured worse, because the chunk sort is dispatched per tile slice and small slices are
all overhead. The default therefore stays 16; `ART_LIVE_TILE_SIZE=8` is a knob for dense
single-layer views, not a new default.

### Tried and rejected: hoisting the spline coefficients per call

`sdSplineSegment` evaluates the cubic ten times per pixel-entry (7 pre-samples, 2 Newton
steps, the final point) plus two tangents, and each evaluation rebuilt the four
Catmull-Rom coefficients. Building them once per call is bit-identical (folding the final
`0.5f` into the coefficients commutes with rounding, and the association order is
unchanged), so it was implemented and measured: **no change** on kaos or doodle. The Metal
compiler already common-subexpressions the control-point combination, so the remaining SDF
cost is the ten evaluations themselves. Reverted rather than kept as dead complexity; the
exact way to go faster there is fewer evaluations, which is approximation and off the
exact list.

### Gates

kaos static byte-identical to `art/kaos.png`; live-vs-static 1 LSB (in practice identical)
on kaos, doodle, cutpaste, y-flip and b; cached-vs-rebuild identical at zoom 2 and 0.5 for
doodle, y-flip and cutpaste; `stroke-splat-ab.sh --all` 10/10 identical;
`stroke-prune-ab.sh --modes 0,1,2` byte-equal on kaos, doodle and cutpaste; the 8×8 grid
byte-identical to 16×16 on kaos, doodle, cutpaste and y-flip; `swift test` 107 tests /
4 skipped / 0 failures; Xcode app + extension build; `build-metallib.sh` verifies all 31
kernels and the installed metallib matches a fresh build of the sources.

### What is left, in order

1. **The chunk sort is O(tiles), not O(entries).** That is what makes 8×8 a loss on
   multi-layer art (logo layer 0: 1.7 → 7.7 ms) even though it cuts SDF evaluations by
   45 %. Batching several small chunks per threadgroup, or sorting the concatenated list
   once, would let 8×8 become the default (logo ≈ 31 → 26 ms of GPU time).
2. **`cutpaste` paste overdraw** — 541 k dispatched tiles / 6.9 G SDF evaluations for
   2 047 pastes. Merging non-overlapping pastes per destination box, or tightening the
   per-dispatch box, is the lever; it is a synthetic stress document.
3. **Display-link frame pacing** (Round 14, item 1) — unchanged, still needs an
   interactive A/B and a `CVDisplayLink` shim for the macOS 12 target.
4. **SDF approximations** — only with an accepted tolerance.

## Round 17 — the merge pass pays for merges, not for tiles

Round 16 left one lever open: the sort's cost grew with the tile count, which is why 8×8
was a loss on multi-layer art (logo layer 0: 1.7 → 7.7 ms) even though it cuts SDF
evaluations by 45 %. This round attributes that cost and removes it, then folds the sort
plumbing both GPU paths had duplicated into one place.

### Attribution: the plan, not the merge work

A temporary ablation knob (`ART_LIVE_SORT_ABLATE`, since removed) skipped the chunk sort
(bit 0) and the merge passes (bit 1) on logo at 8×8: the chunk sort was 0.65 ms, the merge
passes ~7.9 ms of the 8.6 ms sort. The product is ~190 k tile-list entries per pass and
three passes; a merge of that much data is not 8 ms of work on this GPU.

The shape of the plan was. `mergePlan` emitted one unit for *every* pair `mergePairs`
produced, including pairs whose B run was empty (`bLen == 0`). Those units just copy a
finished tile into the next ping-pong buffer, and at 8×8 there are ~17.6 k tiles per pass,
so three passes dispatched ~40 k such copy threads — each doing a co-rank binary search,
like a real merge unit. A unit-size sweep (64…1024) moved the sort between 14.5 ms and
6.0 ms with the best at 128–512: 64 was pathological, and no unit size came close to
proportional, because the units were doing the ping-pong bookkeeping tile by tile.

### One copy per pass, units only where runs merge

`liveBinCopyKernel` copies the whole tile list from the pass's source to its destination
in one coalesced dispatch; `mergePlan` now emits units only for pairs with `bLen > 0`. A
merged range overwrites the copy of itself, and a tile that needs no merge simply stays
where the copy put it. The pass's cost is O(entries) bytes copied plus O(entries that
merge) serial-merge work, and the plan — and therefore the dispatch width — grows with the
runs that really merge, not with the tile grid.

Strict tileList/scratch alternation is unchanged: src is never dst, so a merge can never
clobber unread input. The copy is encoded before the pass's merge dispatch in the same
compute encoder, which is the same execution-order assumption the existing
scatter → sort → render sequence already relies on. No pads or literals are written; the
output is still a permutation of the input.

Logo layer 0 sort (warm, 1920×1080, zoom 1):

| grid | Round 16 | now |
|---|---|---|
| 16×16 (4 480 tiles, 2 834 chunks) | 1.67 ms | 1.65–1.79 ms |
| 8×8 (17 653 tiles, 9 936 chunks) | 7.7–8.6 ms | **3.6–3.7 ms** |

Of the remaining 3.65 ms at 8×8, ~0.95 ms is the chunk sort and ~2.7 ms is copy + merges.
Frame totals are noisier than the stage split and move ±2 ms between runs on this machine;
repeated runs now put logo at 38–41 ms on 8×8 and 40–42 ms on 16×16 (Round 16 recorded
36 ms for 16×16; the sort is unchanged within noise, so that difference is run variance,
not this round).

### 8×8 is still a knob, not the default

With the tile-count term gone, 8×8 is now neutral on multi-layer art at zoom 1 and a win
on dense single-layer art:

| document, zoom 1 | 16×16 | 8×8 |
|---|---|---|
| kaos — 321 k segments | 21–22 ms | **18–19 ms** |
| doodle | 17–19 ms | **15–18 ms** |
| qwerty | 9 ms | 9 ms |
| logo-sketch_03 — 4 layers | 40–42 ms | 38–41 ms |
| cutpaste — paste-bound | 173–175 ms | 173–174 ms |

It still loses where the ink covers the whole tile grid, because smaller tiles buy no SDF
savings but add per-tile overhead: zooms 2 put logo at 48 vs 44 ms and kaos at 21 vs 18 ms
(doodle ties). Zoomed out, single-layer documents win big (kaos 11 vs 14 ms, doodle 14 vs
17 ms), but the multi-layer CPU bin scales with the tile count — logo at zoom 0.5 pays
10 ms of `bin` on 10 596 tiles against 3 ms on 2 857, with identical 32 ms GPU time, for
49 vs 39 ms total. The default therefore stays **16**; `ART_LIVE_TILE_SIZE=8` is the knob
for dense single-layer views and zoomed-out work, and no longer a sort regression.

### One sort plan for both GPU paths

The pure path (`renderCachedLayerGPUThrowing`) and the mixed-layer path
(`prepareMixedGPUBin`) built and encoded the same chunk table, merge plan and five
dispatches twice. They now share:

* `LiveBinSortPlan` — chunks, per-pass real-merge units + offsets, chunk size, merge count,
  and which buffer the ping-pong leaves the ordered list in (`finalTileList`);
* `makeBinSortPlan` — chunk table, all-passes-concatenated unit upload, final-buffer parity
  (the pure path still reports its allocation window separately for `BINTIME`);
* `encodeBinScatter`, `encodeBinChunkSort`, `encodeBinMergePass`, `encodeBinOrder`.

`MixedGPUBin` shrank to `sortPlan` plus the two list buffers; the pure path's local
closures are one-line calls into the shared encoders (the `BINTIME` form keeps its
per-stage waits, `BINCHECK` reads the plan's tables and the pass's units for its mirrors).
Both GPU-path guards, the startup readiness line and `build-metallib.sh` now require/list
`liveBinCopyKernel` (32 kernels), since a metallib with merges but no copy would silently
lose every unmerged tile.

### One definition of a stamp

The same coverage maths existed four times in `segmentKernels.metal`: the AA walk, the
noise walk's clean branch and noisy branch, and `liveSplatStamped`, which the file itself
described as a "VERBATIM copy" kept in step by hand. The splat-vs-walk identity gates
compare bytes, so a drifting copy showed up as a pixel difference, not as a build error.

`liveAAStamped` and `liveNoisyStamped` now hold the only definitions; the AA walk's marker
branch still selects its own chisel SDF but uses the same coverage tail, and the noise
walk picks one of the two per stroke. Splat-vs-walk identity is structural now. The
walk scaffolding above the stamp — threadgroup staging, block-table cursor, stroke
switching, stroke-range filter, saturation — stays duplicated between the AA and noise
kernels: the two differ in prune reach and composite rules on every entry, and the
inlined twins measurably cost nothing (logo `render+comp` 9.6–10.0 ms at 8×8 before and
after, kaos 17.3 ms), so a flag-driven shared walk is deliberately not taken.

### Gates

kaos static byte-identical to `art/kaos.png`; live-vs-static identical on kaos, doodle,
logo, cutpaste and y-flip; cached-vs-rebuild identical at zoom 2 and 0.5 for kaos, logo and
doodle; `stroke-splat-ab.sh --all` 10/10 identical; `stroke-prune-ab.sh --modes 0,1,2`
byte-equal on kaos and logo; the 8×8 grid byte-identical to 16×16 on kaos, logo and doodle;
`swift test` 107 tests / 4 skipped / 0 failures (the merge-plan and chunk-sort mirrors now
apply the whole-list copy and expect units only for real merges); Xcode app + extension
build; `build-metallib.sh` verifies all 32 kernels and the installed metallib matches a
fresh build of the sources. After the stamp consolidation the full set was re-run,
including noise/marker documents (`b`, `dab`, `marker`, `shapes`, `multiply`): all
identical. `tiles` / `chunks` / `sdf` counters are unchanged for a given tile size: this
round changes the shape of the sort tables and the memory movement, not what is rendered.

### What is left, in order

1. **Merge dispatch at 8×8** — still ~2.7 ms for logo layer 0 (copy + real merges, three
   passes). Batching several units per thread, or one threadgroup per merged run, would
   matter if 8×8 ever becomes the default.
2. **CPU `bin` prefix scales with the tile count** — logo at zoom 0.5: 10 ms on 10 596
   tiles vs 3 ms on 2 857. A prefix/scatter pass that does not walk every tile on the CPU
   is the prerequisite for a fine default grid on multi-layer art.
3. **Display-link frame pacing** (Round 14, item 1) — unchanged, still needs an
   interactive A/B and a `CVDisplayLink` shim for the macOS 12 target.
4. **SDF approximations** — only with an accepted tolerance.
5. **`cutpaste` paste overdraw** — 541 k dispatched tiles / 6.9 G SDF evaluations for
   2 047 pastes. Merging non-overlapping pastes per destination box, or tightening the
   per-dispatch box, is the lever; it is a synthetic stress document.

## Round 18 — the noise walk skips dead entries; sort chunks at 1024

Committed as `c652a73` (marked *WIP interrupted* — the code is complete, the doc entry was
not). Three changes, all exact: they remove work that provably cannot change a pixel, or
change only how the sort's work is cut up.

### A staged coverage ceiling per (entry, tile)

The per-tile noise kernel walks every tile-list entry at every pixel of the tile. The AA
walker already had a per-entry skip (`curMax >= satCeil`), but on noisy art the expensive
part is the staged entries whose SDF can never beat the stroke's running max. That test was
being repeated 256 times per entry.

`tgBound[t]` now holds a coverage upper bound for the **whole tile**:

* every curve point of the entry is within `farOff = padding1 − rMax` of its chord, so any
  tile pixel is at least `d(centre, chord) − halfDiagonal(tile) − farOff − 0.5` from the
  curve;
* the noise and AA falloffs are non-increasing in that distance, so evaluating them at the
  lower bound upper-bounds the coverage;
* `× (opacityByte + 1)/255` upper-bounds `stamped`.

The bound costs one distance + one falloff per entry and is computed in the same staging
loop that already loads the record: **3.7 M evaluations instead of ~950 M per-pixel ones**
on robotcrab zoom 3. The skip `tgBound[j] <= curMax` is a max-only short circuit, so it
cannot change the result; the bound is conservative in the safe direction (a too-large
bound only loses the skip). Markers and entries with opacity > 1 get no bound.

### A per-entry opacity ceiling byte

Both per-tile kernels stage `tgOpMax`: `floor(max(op0, op1) · 255)`, capped at 254, with
255 meaning "opacity > 1, no ceiling". Since `stamped = cov · opacity`, `cov ≤ 1`, and the
composite is a max over segments, once `curMax ≥ (byte + 1)/255` the entry's remaining
segments are dead *for that pixel*. Rounding down is what makes the threshold safe: it is
at or below the true ceiling, so the skipped stamps were all ≤ the value already there.
The byte also feeds the tile bound above.

### Sort chunks at 1024, with no matching metallib constant

`GpuBinSpec.sortChunkSize` is now 1024 (was 512), and it is the only definition. The chunk
table already carried each chunk's `len`, and `LiveBinSortParams.runSize` carries the merge
run size, so `liveBinChunkSortV3Kernel` / `liveBinMergePassV2Kernel` need no compile-time
chunk constant at all; only the bitonic `sh[1024]` capacity is a hard ceiling, which the
env override (`ART_LIVE_SORT_CHUNK`, clamped 64…1024) also respects. On robotcrab zoom 3 a
wider chunk halves the chunk count and turns **two merge passes into one** (sort
19.7 → 2.8 ms); at zoom ≤ 1 every tile already fits one chunk, so the change is neutral.

### Measurements (1920×1080, release, `ART_LIVE_BINTIME=1`, steady state)

| view | entries | chunks | passes | xform | scatter | sort | render+comp | frame |
|---|---|---|---|---|---|---|---|---|
| robotcrab z3 L0 | 3 723 371 | 7 950 | 1 | 1.0 | 1.4 | 2.8 | **58.9** | 81 ms |
| robotcrab z3 L1 | 505 258 | 6 259 | 0 | 0.8 | 1.0 | 0.4 | 11.2 | |
| robotcrab z1 | 764 603 | 2 675 | 1 | 0.7 | 0.4 | 1.0 | 14.0 | 24 ms |
| kaos z1 | 1 185 719 | 7 559 | 0 | 0.7 | 0.5 | 0.5 | 19.2 | 24 ms |
| doodle z1 | — | — | — | — | — | — | — | 19 ms |

Zoom 3 on robotcrab is still 81 ms: 3.7 M entries × 256 px of magnified ink is a real
amount of coverage work, and the staged bound only removes entries that cannot beat the
running max — most of those entries *are* ink at that zoom. Reaching ~16 ms there needs a
cheaper coverage evaluation (SDF approximation) or a different dispatch shape, not another
skip.

### Gates

`swift test` 107 tests / 4 skipped / 0 failures; `stroke-splat-ab.sh --all` 10/10 identical
(3 views actually on the splat); `stroke-prune-ab.sh --modes 0,1,2` byte-equal on robotcrab
at zoom 1 and 3; kaos static byte-identical to `art/kaos.png`; live-vs-static 42 px / 1 LSB
(the long-standing envelope); Xcode `ArtQuickLook` app + extension build; `build-metallib.sh`
verifies all 32 kernels. Cached-path renders for kaos, doodle and robotcrab at zoom 2 and 0.5
are byte-identical before and after the round. `tiles` / `chunks` / `sdf` change only where
the chunking or the skips change the work, as intended; the pixels do not.

## Round 19 — mixed paste batches, and a chisel that turns with the page

Two live-view regressions from the rounds above, plus the comparator that had been hiding
differences.

### One noisy stroke no longer softens a whole paste group

Paste groups are keyed by colour / eraser / marker / transform / masks
(`Renderer_PasteMerge.swift`), so a group can hold both clean (AA) and noisy strokes. The
live paste planner put the group into **one** bin with one `hasNoise` flag, while the static
dispatcher (`dispatchPasteToGPU`) split a mixed batch into a clean batch and a noisy batch
and dispatched clean first. On a mixed group the live bin therefore sent every clean stroke
through the noise kernel, and the composite — a max over the batch's segments — also used
the wrong softness. The symptom was the pasted drawing turning into noise dots.

The planner now performs the same split, in the same order, before boxing each batch:
same segments, same pixels, one bin per class. `art/groupings-dispatch.art` (mixed AA and
noisy pasted strokes) is the regression case: live and static are now byte-identical.

### The chisel is page-fixed, so it has to rotate with the camera

`sdSlantedMarkerStamp` hard-coded the nib axis in **device** space. Panning and zooming were
fine, but rotating the camera left the chisel at 45° while the artwork turned. The nib is
part of the artwork, so its angle is now carried per segment in `GPUSplineSegment.padding2`
(float bits; `0` = the reference axis):

* `buildOpFromStroke` bakes `atan2(b − c, a + d)` of `artToDevice ∘ flip` (a similarity's
  rotation; exactly 0 for scale/translation, so unrotated renders keep the reference axis
  bit for bit). A mirrored transform falls back to `atan2(b, a)`.
* `LiveRenderCache.remap` adds the camera's angle to the stored nib angle.
* `liveBinTransformCountKernel` adds the same angle when it stages a segment.

The kernel's `liveMarkerAxis(theta)` rotates `±(1, −1)/√2` by `theta`, and short-circuits
`theta == 0` to the literal reference axis, so the static and unrotated live paths cannot
move. Only the `isMarker` branch reads `padding2`; circular markers and ordinary strokes
take the capsule/spline SDF and are untouched. Verified by rendering `qwerty` and `marker`
at the default view and at `--rotate 0.6`: per-tile and per-stroke paths are byte-identical
in both views, and the chisel visibly turns with the page.

### `tmp/pngdiff.py` was reporting false IDENTICALs

Pillow's `ImageChops.difference(...).getbbox()` defaults to **alpha-only** on RGBA, and the
live/static PNGs have identical alpha, so the comparator printed `IDENTICAL` whenever RGB
differed. It now builds the union of per-band "any difference" masks and scans all four
channels, with the old tolerance argument (default 1 LSB) retained. The gates above were
re-run after the fix; the ones that had been reported IDENTICAL on RGB were re-checked
directly (`shasum` where identity is expected, `pngdiff` where a 1-LSB envelope applies).

### Gates

`stroke-splat-ab.sh --all` 10/10; `stroke-prune-ab.sh --modes 0,1,2` byte-equal on
robotcrab z1/z3; `groupings-dispatch` live == static; kaos live-vs-static 42 px / 1 LSB;
qwerty live-vs-static 9 px / 1 LSB (both the historical envelopes); per-tile vs per-stroke
identical for `qwerty` and `marker` at rotation 0 and 0.6; cached renders for kaos, doodle and
robotcrab at zoom 2 and 0.5 byte-identical to the pre-change build; `swift test` 107 / 4
skipped / 0 failures; Xcode `ArtQuickLook` app + extension build; `build-metallib.sh` 32/32.

### What is left

1. **Robotcrab zoom 3 is still ~81 ms**, 59 ms of it `render+comp` (Round 18). The remaining
   cost is genuine magnified coverage, not skippable entries.
2. **Display-link frame pacing** — unchanged (Round 14, item 1).
3. **`cutpaste` paste overdraw** — deliberately still last priority.

