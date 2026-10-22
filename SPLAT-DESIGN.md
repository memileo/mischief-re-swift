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
`liveSegDist(p, p1, p2) ≤ padding1` (the prune). Pixels that fail the prune contribute
exactly 0 to `curMax`, so the walk's output is a function of only

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

The disk path needs `prune_dev ≤ pad_dev`, i.e. `margin_doc·rf ≤ 0.4·r_doc·rf + 1`
(`pad = 1.4·rMax_dev + 1`). For `r_doc ≥ 2` (`margin_doc = 0.375·r_doc`) that holds for
**any** `rf`; for `r_doc < 2` it degrades at large `rf`. So the kernel's per-segment
`prune <= pad` test is the real correctness switch, and `ART_LIVE_SPLAT_MAX_RF = 1.0` is
a *performance* gate (below it the disk is cheap; above it the disk can exceed the tile
band, so the walk is not worse). Do not raise `MAX_RF` expecting a win at zoom-in — the
tile is only 16 px, so the walk's expansion waste shrinks as `r_dev` grows.

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
`SegmentPrune.radius` stores `reach + max(0.75, 0.375·r)`, i.e. at least 0.75 px more than
the last pixel with non-zero coverage, so the rounding difference between the two forms
cannot flip a contributing pixel; the kaos pixel gate and `stroke-splat-ab.sh --all` are
the check.

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


