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

- `Scripts/stroke-splat-ab.sh` — rewritten. Per view: delete the previous
  `<doc>.live-view.png`, run walk (`ART_LIVE_SPLAT=0`) and default (`ART_LIVE_SPLAT`
  unset), move both to `tmp/splat-ab/<doc>@<zoom>-splat-{off,default}.png`, verify each
  PNG is the requested viewport size, byte-compare, and report the default run's own
  `[splat N×B]` marker. A view that never splatted is called out as *walk vs walk*, so a
  vacuous A/B can no longer pass. `--all` runs the standard matrix (kaos 1/0.21/0.05,
  logo 1/0.05, complex 1/0.3/0.05, dots 1/20); positional `pan` / `rotate` are supported.
  Output and logs live in `tmp/splat-ab/` (project-local, gitignored).
- `Scripts/build-metallib.sh --verify-only` — the stall was the verifier, not the tooling:
  it matched ~31 names with `[[ $haystack == *$name* ]]` against a multi-MB
  `metal-nm`+`strings` dump held in a shell variable, which bash 3.2 walks byte by byte
  in a UTF-8 locale. Now the dump goes to a file under `tmp/` and each probe is
  `grep -qF`, with `LC_ALL=C`. Also fixed: the timeout watcher's orphaned `sleep` kept the
  caller's stdout open inside `$(...)`, delaying every probe by the full 20 s. Measured
  here: 0.07 s for the checked-in metallib, 0.16 s for a 2 MB synthetic dump.

## Next levers (ranked by expected win per risk)

1. **`ART_LIVE_TILE_SIZE=8` on the dense views** — no code change, just an env var. The
   walk's work is `incidences × tileSize²`; halving the tile should cut kaos's 372 M
   evaluations to ~160 M (incidences grow ~1.8×, area drops 4×). Costs: ~2× the tiles,
   incidences and tile-table entries, so watch `scatter`/`sort` and the bin CPU time.
   `ART_LIVE_TILE_SIZE=32` is the other control point. Everything stays byte-identical
   (the walk is tile-size independent; the splat only reads `tileSize` for its fallback
   branch), so the usual A/B gates apply.
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
