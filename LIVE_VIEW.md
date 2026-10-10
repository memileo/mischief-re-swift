# Live Metal View for ArtQuickLook — Implementation Plan

Status: **in progress** (updated as work proceeds; see [Progress log](#progress-log))

> **Working agreements (2026-10-08):**
> - **Never touch `project.pbxproj`.** New files that live *inside* the Xcode project
>   (extension Swift files, `.metal` files) get a sibling `ADD_TO_XCODE.txt` note and are
>   added by hand. Files under `Sources/ArtRenderLibrary/` need nothing — SwiftPM picks
>   them up from the `sources:` list in `Package.swift`, which is ours to edit.
> - The metallib is built with the **ArtRenderShaders** scheme in Xcode and copied to
>   `Sources/ArtRenderLibrary/ArtRenderShaders.metallib`.

## 1. Goal

Add a **live view** preview mode to the Quick Look extension:

- Renders the art **once** into Metal textures.
- Displays it in an `MTKView` where pan / zoom / rotate are pure **view-transform**
  changes — no re-render, no CoreGraphics compositing on the CPU.
- All remaining compositing (layer stacking, layer opacity, paper texture, background)
  happens in **Metal shaders**.
- The view only redraws while something changes (paused `MTKView` + explicit
  redraw requests).
- While interacting, an on-screen HUD shows FPS (and the zoom percentage while zooming).
- Reset functions: one **full reset** (back to the file's own view matrix) plus one
  per mode (pan / zoom / rotate).
- The existing three render paths (`.gpuSegments`, `.gpuStamps`, `.cpuStamps`) keep
  working **exactly as before**.

Interaction spec (from the request):

| Gesture | Action |
|---|---|
| middle-mouse drag | pan |
| middle-mouse + **cmd** drag | zoom |
| middle-mouse + **shift** drag | rotate |

## 2. Current architecture (recon notes)

Reference points found while planning:

- `Sources/ArtRenderLibrary/Renderer.swift:120` — `render(art:)` is the single
  "everything to a `CGImage`" entry point. It creates a **CoreGraphics** context,
  then loops layers, calling `renderLayerIsolated` and drawing each layer image
  into the CG context (`context.draw(layerImage, ...)`, `Renderer.swift:205`).
  Background/paper is composited with CG blend modes (`destinationOver`,
  `multiply`) at `Renderer.swift:212-273`.
- `Renderer.swift:325` — `renderLayerIsolated` builds a `LayerOperation` list
  (`.stroke`, `.cut`, `.paste`) from `art.actions`, then renders via
  `MetalRenderer.renderSegmentGroupsInOrderSync` (GPU SDF segments) or the
  CPU/stamp paths. All of those end in a **CPU readback to `CGImage`**.
- `MetalRenderer.swift:474` — `renderSegmentGroupsInOrderSync`: dispatch into
  `gpuRenderTarget` (`.private`, `rgba8Unorm`, premultiplied) → `convertFloatTextureTo8bitSync`
  → `readbackToCGImageSync`. **The readback is the only thing we need to skip.**
- `MetalRenderer_Dispatch.swift` — `dispatchStrokeToGPU` / `dispatchPasteToGPU` /
  `dispatchCutToGPU` all write into `gpuRenderTarget` (or a merge-fragment texture)
  and each `waitUntilCompleted()`. Reusable as-is.
- `segmentKernels.metal:900` — `mergeFlattenCompositeKernel` is exactly the
  premultiplied source-over-with-opacity composite we need for layer stacking
  (`dst.rgb = src.rgb*opacity + dst.rgb*(1-sa)`).
- `Renderer_Resources.swift:407` — `renderPaperTexture` tiles the paper JPEG over a
  paper colour with `paperStrength` alpha, at tile size `0.666 * scale`; the
  background colour is multiplied on top unless it is pure white.
- `Renderer_StrokeGeometry.swift:776` — `transformFromMatrix` maps the art's
  view matrix (and the layer matrix) into device pixels. This is the "current view
  matrix in the file" the full reset returns to.
- Extension entry point: `ArtQuickLook/ArtQuickLookExtension/PreviewProvider.swift`
  (this is the file actually in the extension target's Sources phase).
  `PreviewViewController.swift` is **dead code** — not referenced by the pbxproj.
- Settings/radio group: `ArtQuickLook/ArtQuickLook/SharedSettings.swift`
  (`RenderPath` enum drives `ContentView.swift`'s `Picker` over `allCases`).
- Shaders: `ArtQuickLook/ArtRenderShaders/*.metal` compile to
  `Sources/ArtRenderLibrary/ArtRenderShaders.metallib` (checked in, copied into the
  SwiftPM resource bundle). **A new `.metal` file therefore requires recompiling
  that metallib on macOS** — see §4 and Stage 3.
- `project.pbxproj` is missing `segmentNoiseCompositeKernel.metal` and
  `segmentSDFMaskKernel.metal` from the shader target, so Xcode's metallib would be
  incomplete even though the checked-in metallib contains those kernels. Fixing
  that as a drive-by (Stage 1) and adding the shader build script makes the Xcode
  build authoritative.

## 3. Design

### 3.1 New render path: GPU canvas build (`ArtRenderLibrary`)

`Renderer.renderLive(art:) -> LiveRenderedCanvas?` mirrors `render(art:)` but never
touches CoreGraphics for compositing:

1. `MetalRenderer.prepareLiveCompositing()` (lazy, idempotent) builds the new
   pipelines. Missing shader functions are **non-fatal**: returns `false` → caller
   falls back to the existing static path.
2. Allocate a canvas-sized `rgba8Unorm` `.private` texture
   (`liveCanvasTexture`, mipmapped for minified quality) + a background texture.
3. Per layer (same visibility/opacity/action-order logic as `render(art:)`):
   `renderLayerOpsToTexture(...)` → `gpuRenderTarget`, then
   `compositeLayerOnGPU(opacity:)` merges it into the canvas texture.
4. Background/paper → `renderPaperBackgroundOnGPU(...)` writes a canvas-sized
   background texture (paper colour ⊕ tiled paper texture ⊕ background multiply).
5. Returns `LiveRenderedCanvas` (canvas texture + background texture + pixel size +
   the `MTLDevice` + the art's base transform metadata). Mipmaps generated once.

Everything is additive: `render(art:)` and its helpers are untouched, and the new
code paths are only reached from `renderLive(art:)`.

### 3.2 View transform (`LiveViewTransform`, in `ArtRenderLibrary`)

Pure value type, cross-platform (compiles on Linux too), no Metal needed:

```
viewPos = viewCentre + R(rotation) · (zoom · contentOffset) + pan
contentOffset = (canvasPx - canvasCentre)
zoom == 1  →  the file's own view matrix, aspect-fitted to the view  (= "reset all")
```

- `panBy(_:)`, `pan(by:)`, `zoom(by:anchor:viewportSize:)`,
  `rotate(by:anchor:viewportSize:)` with anchor-preserving math.
- `resetAll()` / `resetPan()` / `resetZoom()` / `resetRotation()`.
- `zoomPercent` = `zoom * 100`.
- Zoom clamp `0.05 … 64`.
- Rotation is a **screen-space** rotation pre-multiplied onto the content transform,
  so `pan' = (anchor − centre) − R(δ)·(anchor − centre − pan)`; zoom is a scalar and
  therefore also scales the existing pan:
  `pan' = ratio·pan + (1 − ratio)·(anchor − centre)`. Both invariants are pinned by
  the unit tests.

### 3.3 Present (`MetalRenderer_LivePresent`)

Render pipeline, full-canvas quad in the vertex shader, transformed by a
`LiveViewTransform.clipMatrix` uniform (canvas px → clip space, y-flipped for Metal NDC).
Mip selection is implicit (`access::sample`) so zooming out below 1:1 stays clean.
`livePresentFragmentShader` samples canvas + background (background is opaque, so
`canvas.a` decides the mix) — transparent canvas regions fall back to the
view's clear colour.

The same body serves two entry points: the MTKView drawable (`.bgra8Unorm`) and an
offscreen `.rgba8Unorm` texture used by `art2png --live`, so the test hook dumps
exactly what the view shows.

All of the transform maths (`matrix`, `clipMatrix`, `inverted`, `concatenated`) lives in
the portable `LiveViewTransform`/`LiveViewMatrix` types and is covered by unit tests that
run on Linux (`swift test`).

### 3.4 Interaction + HUD (`ArtQuickLookExtension`)

- `LivePreviewView: MTKView, MTKViewDelegate` — draw loop, middle-button handling,
  redraw gating, resize handling, context menu, key equivalents. It declares **no**
  initializers on purpose, so every `MTKView` initializer is inherited unchanged
  (`LivePreviewView.make(device:)` configures it).
- `LiveHUDController` + `LiveHUDView` — one object owns **all** HUD state and is the
  single funnel used by every pan/zoom/rotate/reset function:

  ```
  beginInteraction(mode:zoomPercent:) / updateInteraction(...) / endInteraction(message:)
  registerFrame(at:zoomPercent:)   // called by the draw loop → FPS
  announce(_ message:)              // "Rendering…", "Reset view", …
  showStatus(_:)                    // thin wrapper on the view for transient status
  ```

  Every interaction *and* every reset function goes through these, so the FPS counter,
  the zoom percentage and the transient messages behave the same no matter what
  triggered them.
- `LivePreviewSession` (`LivePreviewController.swift`) — owns the background render
  queue → canvas install → `handler(nil)`, plus the fallback to the static path.

### 3.5 Redraw gating

- `isPaused = true` by default; `MTKView` is explicitly asked to draw only via
  `setNeedsDisplay`/`display()` or while interacting.
- Interaction start → `isPaused = false`; end → keep alive ~0.35 s, then pause.
- Resize / canvas install / reset → single manual frame.

### 3.6 Fallbacks

| Condition | Behaviour |
|---|---|
| No Metal device | fall back to the current static path (unchanged behaviour) |
| Live pipelines missing (stale metallib) | log + fall back to the static path |
| `renderLive` returns nil | log + fall back to the static path |
| Metal command error | log + fall back to the static path |

Nothing in the existing paths changes.

## 4. macOS-only test hook

`art2png --live <file.art>` renders through the live GPU canvas path *and runs the real
present pass at 100%*, writing `<file>-live.png` next to the normal `<file>.png`
(`--live-only` skips the normal render). Since both images are the same document at the
same size, the compositing can be compared pixel for pixel — which matters because
development happens on Linux.

`Scripts/build-metallib.sh` compiles `ArtQuickLook/ArtRenderShaders/*.metal` with
`xcrun metal` and copies the result to
`Sources/ArtRenderLibrary/ArtRenderShaders.metallib` (the file the SwiftPM
resource bundle copies). `--verify-only` reports whether it is up to date.

## 5. File inventory

### New

| File | Purpose |
|---|---|
| `Sources/ArtRenderLibrary/LiveViewTransform.swift` | pan/zoom/rotate state, gesture math, resets, canvas→view and canvas→clip matrices (cross-platform) |
| `Sources/ArtRenderLibrary/LiveRenderedCanvas.swift` | value type carrying the GPU canvas from the renderer to the view |
| `Sources/ArtRenderLibrary/MetalRenderer_LiveCompositing.swift` | live pipelines, layer composite, paper background, mipmaps |
| `Sources/ArtRenderLibrary/MetalRenderer_LivePresent.swift` | present pass (drawable + offscreen) and uniform packing |
| `Sources/ArtRenderLibrary/Renderer_Live.swift` | `Renderer.renderLive(art:)` + present/readback API |
| `ArtQuickLook/ArtRenderShaders/liveCompositeKernels.metal` | live shaders |
| `ArtQuickLook/ArtQuickLookExtension/LivePreviewView.swift` | `MTKView` + interactions + resets + redraw gating |
| `ArtQuickLook/ArtQuickLookExtension/LiveHUD.swift` | shared HUD state/logic + overlay view |
| `ArtQuickLook/ArtQuickLookExtension/LivePreviewController.swift` | glue: render off-main, install canvas, fallback |
| `Scripts/build-metallib.sh` | metallib rebuild helper (with kernel verification) |
| `Sources/ArtRenderLibrary/LiveRenderCache.swift` | the "process once" geometry cache + the per-frame camera re-mapping |
| `Tests/ArtRenderLibraryTests/LiveViewTransformTests.swift` | 15 Linux-runnable tests for the transform maths |
| `Tests/ArtRenderLibraryTests/LiveRenderCacheTests.swift` | 8 Linux-runnable tests for the cache re-mapping maths |

### Modified

| File | Change |
|---|---|
| `Sources/ArtRenderLibrary/MetalRenderer.swift` | live stored properties; `renderSegmentGroupsInOrderSync` split into rasterise + readback |
| `Sources/ArtRenderLibrary/Renderer.swift` | layer-op building extracted into `buildLayerOperations` (shared by all paths) |
| `ArtQuickLook/ArtQuickLook/SharedSettings.swift` | new `RenderPath.liveMetal` case + `isLiveView` |
| `ArtQuickLook/ArtQuickLook/ContentView.swift` | live-mode toggle + shortcut help next to the static paths |
| `ArtQuickLook/ArtQuickLookExtension/PreviewProvider.swift` | live branch, static path extracted, fallback without a double completion call |
| `Package.swift` | new `ArtRenderLibrary` sources + the test target |
| `ArtQuickLook/ArtQuickLook.xcodeproj/project.pbxproj` | new Swift files → extension target, new `.metal` → shader target |
| `Sources/art2png/main.swift` | `--live` / `--live-only` test hook |
| `README.md` | live view docs, shader build step |

## 6. Stages

### Stage 0 — Plan & recon ✅
This document.

### Stage 1 — Settings, toggle, project plumbing
`RenderPath.liveMetal`, app toggle, pbxproj + `Package.swift` wiring for the files
that will be added (empty/placeholder-free: add real files in the same stage as
their content where practical).

**Test point:** `swift build` on Linux still passes; app builds on macOS and the new
option appears next to the other three; existing three modes still render.

### Stage 2 — `LiveViewTransform` + HUD state object
Transform math and the shared HUD funnel (pure Swift).

**Test point:** `swift build` + `swift test` on Linux. `Tests/ArtRenderLibraryTests`
pins down the aspect fit, pan, zoom/rotate anchoring, the NDC flip, the clamps and all
four resets. *(This test already caught one real bug: the zoom-anchor formula did not
scale the existing pan, so zooming after panning drifted.)*

### Stage 3 — Live Metal shaders + build script
`liveCompositeKernels.metal`, `Scripts/build-metallib.sh`, pbxproj shader target
entries.

**Test point:** on macOS run the script, then
`xcrun metal-readobj`/strings shows `liveCompositeLayerKernel`, `livePaperBackgroundKernel`,
`livePresentVertexShader`, `livePresentFragmentShader`.

### Stage 4 — GPU canvas build in the library
`MetalRenderer_LiveCompositing`, `Renderer_Live`, `LiveRenderedCanvas`, plus
`art2png --live`.

**Test point (macOS):** `art2png --live art/x.art` — `<x>-live.png` must match
`<x>.png` visually (paper, layer opacity, multiply background).

### Stage 5 — `MTKView`, interaction, HUD, resets
`LivePreviewView`, `LiveHUD`, `LivePreviewController`, `PreviewProvider` branch.

**Test point (macOS):** in Quick Look — mmb drag pans; mmb+cmd zooms (HUD shows %);
mmb+shift rotates; FPS HUD only while interacting; resets via context menu and keys;
no redraw when idle.

### Stage 6 — Polish / optional extras
Embedded images on GPU (stretch: the default GPU segment path does not draw them
either, so the live path matches it — only worth doing if the whole renderer gets it),
per-mode HUD tweaks, `Scripts/build-metallib.sh` in CI, README screenshots.

**Test point:** regression pass over the three original render paths.

### Stage 7 — Take 3: re-render architecture (this round)
See §9. Work in this order so each step is independently testable:

- **7a** SDK/robustness fixes in the extension (no `contentScaleFactor`,
  `NSCursor.closedHand`, no `isOpaque`/`acceptsFirstResponder` overrides), live view as
  a radio option, no 1× floor, explicit canvas orientation flag + `--live-view` dump.
  **Test:** gestures track 1:1 on Retina *and* non-Retina; the dump either matches
  `<file>.png` or reveals the flip (then set the flag).
- **7b** `LiveRenderCache`: geometry flattened once at a reference transform, per layer,
  with a memory budget. `art2png --live-cache` reports budget usage.
  **Test:** the cache builds on every `art/*.art` and the report looks sane.
- **7c** `renderLive(camera:size:)`: re-map cached geometry, dispatch, composite into a
  screen-sized canvas, paper in document space.
  **Test:** `art2png --live-view --zoom 4 --rotate 0.3` produces a *re-rasterised*
  image (crisper than `--live`), and `--live-view` at 100% matches `--live`.
- **7d** Extension: request-a-rerender scheduler with coalescing, FPS = renders/sec.
  **Test:** one long drag stays live for the whole gesture; HUD FPS is sane; nothing
  happens when idle.
- **7e** Fallback wiring: budget exceeded → single-raster mode; a setting to force it for
  A/B comparison.

### Stage 8 — Take 4: make it correct, then fast
See §9.3. Followed by take 4b (§9.4/§9.5): the present/gesture orientation, the reset keys,
the metallib script, and document windows for profiling. Composition order, canvas orientation, the arena growth bug, off-screen
culling, 32×32 live threadgroups, extra input bindings, per-stage frame timing, and the
cache build moved to a Metal-free file so it can be tested on Linux.
**Test:** the checklist at the end of this file, in order.

## 7b. Known limitations / deliberate choices

- **Embedded images** (`art.images`) are not drawn by the live path, matching the
  existing GPU SDF segment path. The CPU/GPU-stamp paths do draw them.
- **Document raster** is fixed at render time (`previewScale`, floored at 1×): zooming
  in past 100% magnifies that raster, it does not re-render at higher resolution. This
  is the point of the live view; re-rendering on demand is a possible follow-up.
- **Paper texture** is baked once at canvas resolution, so it magnifies with the
  document (same as a raster preview).
- **Drag released outside the view** ends the interaction via a `pressedMouseButtons`
  check in the draw loop rather than delivering `…MouseUp`.
- The middle button is reserved while the live view is up.
- **Canvas row order is settled** (see §9.4): the present matrix is y-down throughout, so
  there is no mirror and no setting.
- **Per-stroke dispatches cover the whole canvas.** Correct but wasteful for large
  documents; see §9.2(c) for why the fix is not in yet.

## 9. Take 3 — what the first working build taught us (2026-10-08)

Reported after building on macOS:

1. **It renders, it is a bit faster than the CG path, the HUD looks right.**
2. **The image is y-flipped.** The present pass assumed canvas row 0 = document top
   (which is what the static path implies). Rather than guess again, the orientation is
   now a single Swift-side flag (`LiveRenderedCanvas.flipsVertically`) and there is an
   `art2png --live-view` dump so the correct value can be confirmed in one command
   against the static PNG.
3. **"Not quite what I had in mind":** transforming one raster is not a live view. The
   document must be **re-rendered** for the new view matrix so strokes stay crisp at any
   zoom, with the parsed/processed stroke data kept in memory so only the cheap part is
   redone. Above a large memory budget, fall back to the single-raster mode.
4. **Gestures only applied for a fraction of a second.** The old gating depended on
   MTKView's display link running inside the Quick Look host. The new scheduler does not:
   every change schedules a re-render on a serial queue, coalescing while one is in
   flight, and presents when it finishes. FPS = completed renders per second.
5. **Live view should be a radio-button option**, not a separate toggle.
6. **No 1× floor** on the render scale — a weak GPU on a Retina display should be able
   to render below 1×.
7. SDK constraints found while compiling: `NSView.contentScaleFactor`,
   `NSView.acceptsFirstResponder()` and `MTKView.isOpaque` are not usable in this target,
   and `NSCursor.closed` does not exist.

### 9.1 Target architecture (take 3)

```
                   ┌──────────────────────── once per document ──────────────────────┐
  ArtParser ─────► │ LiveRenderCache:  per layer, per op, geometry flattened in      │
                   │ *reference* space (100% zoom).  Strokes/cuts only; a layer that │
                   │ contains paste/merge actions is marked `needsRebuild` and is      │
                   │ re-walked per frame so it stays exactly correct.                 │
                   │ Budget: ~4M cached points; over that → fall back to raster mode. │
                   └───────────────────────────────────────────────────────────────┘
                                        │
  view change ─► camera (LiveViewTransform) ─► for each layer:
                                        │    artToDevice = camera ∘ base ∘ layer
                                        │    • re-map cached control points + radii (no recursion)
                                        │    • re-classify segmentType (scale-invariant)
                                        │    • dispatch + composite onto a **screen-sized** canvas
                                        │    • paper background tiled in *document* space
                                        └─► present (identity transform) ─► MTKView
```

Re-rendering at screen resolution (instead of transforming a document-sized raster) is
what makes zooming in show real detail, and it also bounds the per-frame cost by the
window size rather than by the zoom level.

The single-raster mode stays as the fallback and as the reference for `--live`.

- **Stale metallib** → live mode silently falls back. Mitigated by a loud log + the
  build script + documented step.
- **QL extension + MTKView lifecycle**: `preferredContentSize`/drawable resizing.
  Mitigated by handling `mtkView(_:drawableSizeWillChange:)` + one-off redraws.
- **Threading**: rendering off-main, presenting on main. Only the whole
  `LiveRenderedCanvas` reference crosses threads (atomic swap on main).
- **Colour space**: canvas texture is `.rgba8Unorm` (linear values as the existing
  GPU path already produces) to avoid double sRGB conversion; the existing paths
  are untouched.

## Progress log

- **2026-10-06** — Stage 0 done (plan written). Recon complete.
- **2026-10-06** — Stage 1 done: `RenderPath.liveMetal` added, separate "Live Metal
  view" toggle + shortcut help in the app, pbxproj entries for the new Swift and
  `.metal` files (also added the two shader files that were missing from the shader
  target).
- **2026-10-06** — Stage 2 done: `LiveViewTransform` (pan/zoom/rotate + anchor math +
  the four resets + canvas→view matrix). Compiles on Linux (`swift build`).
- **2026-10-06** — Stage 3 done: `liveCompositeKernels.metal` (layer stack, paper
  background, present vertex/fragment) + `Scripts/build-metallib.sh` with kernel
  verification. Uniform structs deliberately use scalar fields so the Swift layout
  matches MSL byte for byte.
- **2026-10-06** — Stage 4 done: split
  `MetalRenderer.renderSegmentGroupsInOrderSync` into a rasterise step plus readback,
  extracted `Renderer.buildLayerOperations` (shared by all paths), added
  `MetalRenderer_LiveCompositing`, `MetalRenderer_LivePresent`, `Renderer_Live`,
  `LiveRenderedCanvas`, and the `art2png --live / --live-only` test hook.
- **2026-10-06** — Stage 5 done: `LiveHUD` (shared HUD controller + overlay),
  `LivePreviewView` (MTKView, mmb pan / mmb+cmd zoom / mmb+shift rotate, redraw gating,
  resets via keys + context menu), `LivePreviewSession`, and the `PreviewProvider`
  branch with fallback to the static path.
- **2026-10-08** — Stages 7a–7e done (take 3: cached re-render per view change). See §9.
- **2026-10-08** — Stage 8 done (take 4: composition order + canvas orientation fixed,
  arena growth bug fixed, culling + 32×32 live threadgroups, extra input bindings, frame
  timing, Metal-free cache build with Linux tests). See §9.2/§9.3.

### Follow-ups (only if something misbehaves on macOS)
- Dispatch only the tiles a stroke touches (needs a pixel origin in the shared `Params`
  struct — a Swift/MSL layout mismatch there would silently corrupt every segment).
  With the arena fixed, the GPU dispatches are the whole remaining frame cost (§9.2c).
- Higher-resolution document raster for zoomed-in views.
- HUD text in Metal instead of a CoreGraphics overlay.
- Embedded images on the GPU (currently matched to the GPU segment path).

### Review pass (2026-10-06)
A separate review of the macOS-only code (which cannot be compiled on Linux) found and
the following were fixed before any macOS run:

*Blockers (would not have compiled)*
- `Int & UInt` in the middle-button check → `Int(NSEventMask.otherMouseDown.rawValue)`.
- `override var menu` cannot be read-only (NSView's `menu` is readwrite) → the menu is
  now assigned to the inherited property in `configure()`.
- `private(set)` is **file**-scoped in Swift, so `liveCompositingPrepared` could not be
  set from the extension file → plain `internal var`.
- `public` methods taking the internal `MetalRenderer` → made internal (only used inside
  the module).

*Behaviour*
- **Y axis**: NSEvent locations are AppKit (y up) while the transform maths is y-down;
  the event→pixel conversion now flips vertically (pan was inverted and zoom/rotate
  anchored the mirrored point).
- **Uniform buffer race**: one shared buffer meant in-flight drawables could be shaded
  with a newer transform → ring of three buffers (MTKView keeps 3 drawables in flight).
- **Mips were never sampled**: `linearSampler` has `mipFilter = .notMipmapped` → added a
  mip-filtered `livePresentSampler` for the present pass, so canvas mips actually help
  when zoomed out.
- HUD overlay now wipes its dirty rect (`NSView.isOpaque` defaults to true, so AppKit
  left the last HUD frame on screen after hiding).
- `refreshFrame()` no longer requests *two* frames per change (it inflated the FPS).
- Letterbox colour: the present pass now clears with the view's `clearColor`.
- Paper texture is dropped per document, so a second document of the same size cannot
  inherit the first one's paper.
- Pipeline-creation errors are reported (instead of always blaming a stale metallib).
- The paper texture slot is always bound (1×1 stand-in) rather than left empty.
- Gesture speeds are per *point*, not per device pixel (same feel on Retina).
- HUD/pause hold durations now match, so the FPS number never freezes on screen.
- The `Renderer` is constructed on the render queue, not the main thread.
- `liveViewEnabled` is a published mirror driven by an explicit `Binding`, instead of a
  computed property that only worked by side effect.
- `--live` on a non-Metal platform now errors instead of silently doing nothing.

A claim in the review that `SIMD3<Float>` matches MSL `float3` was checked and is
incorrect (`MemoryLayout<SIMD3<Float>>.size == 16` vs MSL's 12), so the scalar uniform
layout stays.

### Take 3 progress (2026-10-08)

**7a — SDK fixes, UI, orientation**
- No `NSView.contentScaleFactor` / `NSView.acceptsFirstResponder()` /
  `MTKView.isOpaque` in this target: backing scale now comes from
  `window?.backingScaleFactor`, the cursor is `NSCursor.closedHand`, and neither override
  is used. (All three were commented out in the macOS build; they are now written the way
  that SDK accepts.)
- Live view is back in the **radio group** (`RenderPath.allCases`), the separate toggle is
  gone, and the shortcut help + a "Flip canvas vertically" escape hatch only appear while
  it is selected.
- **No 1× floor**: `previewScale` is used as-is, so a weak GPU on Retina can rasterise
  below 1×.
- Canvas row order is now one flag: `presentLiveCanvas(..., flipVertically:)`, plumbed
  through `LiveRenderedCanvas.previewImage` and the app setting, so the orientation
  question is settled with `art2png --live [--flip-y]` instead of by eye.

**7b — `LiveRenderCache`** (`Sources/ArtRenderLibrary/LiveRenderCache.swift`)
- Per layer: flattened segments at the 100% reference transform, plus cut rects with
  their selection-frame transform. Layers containing paste/merge are flagged
  `needsRebuild`.
- Budget: 1.5 M segments (~84 MB) → cache refused → single-raster fallback.
- Deliberately **not** wrapped in `#if canImport(Metal`, so the maths type-checks and
  unit-tests on Linux: 8 new tests in `LiveRenderCacheTests` (identity/scale/translate/
  rotation re-mapping, chord-to-radius invariance under a similarity, inversion).

**7c — `renderLive(cache:camera:viewport:)`**
- Re-maps cached geometry with the camera, dispatches a whole layer in **one command
  buffer** (per-stroke dispatches, so overlap compositing matches the static path),
  composites onto a **viewport-sized** canvas (so zooming in gains real detail and the
  per-frame cost is bounded by the window, not by the zoom), and bakes the paper in
  *document* space so it travels with the artwork.
- Two hazards found while writing it, both worth remembering:
  - **Shared buffers under many dispatches.** The static path reuses `segmentBuffer` /
    `tileIndicesBuffer` per stroke, which is only safe because it waits for each command
    buffer. Encoding a whole layer into one command buffer means the CPU finishes writing
    every dispatch before the GPU starts the first, so those buffers would be overwritten
    mid-flight. Fixed with a per-layer **arena**: every dispatch binds its own `offset:`
    into one buffer, and the scheduler's one-render-at-a-time rule makes reusing it across
    frames safe. (`setBytes` snapshots its value, so params/cuts can still share one
    command buffer.)
  - **Paper tile units.** The tile size is in *document* units, so the interactive path
    needs `camera⁻¹ ∘ scale⁻¹` and `tileScale: 1`; the raster path keeps `tileScale: scale`
    because it tiles in canvas pixels.

**7d — request-driven scheduling**
- `LivePreviewView` no longer depends on MTKView's display link: it reports
  `(transform, viewport)` changes and the session re-rasterises on its own queue,
  coalescing to the newest transform while a render is in flight. FPS = completed
  re-renders per second. The single-raster fallback keeps the old "transform and
  redraw" behaviour (no re-render per change).

**7e — fallbacks**
- Cache unavailable/over budget, or Metal/kernels missing → single raster, announced in
  the log; nothing fails hard. Total failure still falls back to the static preview.
- `art2png`: `--live-view`, `--live-cache`, `--zoom`, `--pan`, `--rotate`, `--viewport`,
  `--flip-y`.
- `Scripts/build-metallib.sh` gained `--from-xcode` (installs the metallib the
  **ArtRenderShaders** scheme just produced — that is the route that works) and now
  refuses to install an incomplete library.

**Not touched:** `project.pbxproj` (per the agreement above). No new files were added
inside the Xcode project: the cache lives in `Sources/ArtRenderLibrary/` (SwiftPM picks it
up via `Package.swift`) and the shader change is inside the existing
`liveCompositeKernels.metal`.

### Test points for take 3 (needs macOS)

Ordered so the cheapest, most diagnostic runs come first.

1. **Orientation.** `art2png --live art/mischief-document.art` → compare
   `<file>-live.png` with `<file>.png`. The live canvas is now **mirrored by default**
   (`LiveCanvasRowOrder.presentsMirrored`), which is the orientation macOS actually
   showed; `art2png --no-flip-y` / the app's "Mirror canvas vertically" toggle turn it
   back off. `--live`, `--live-only` and `--live-view` all honour it now.
2. **Cache.** `art2png --live-cache art/*.art` (loop over the samples) → the report must
   show a sane segment count and budget, and "N rebuilt per frame" only for documents
   that really contain paste/merge actions.
3. **Interactive path at 100%.** `art2png --live-view --viewport 1920x1080` →
   `<file>-live-view.png` should match `<file>.png` closely (same strokes, same paper;
   the AA may differ by a hair because the re-render flattens at the cache's reference
   transform). Every render prints its stage breakdown now, e.g.
   `Live view: 410 ms total (bin 95, encode 12, gpu 300, paper 3) — 2214 strokes / 321611 segments, 1 layers cached, 0 rebuilt, 0 culled`.
4. **Interactive path zoomed in.** `--live-view --zoom 4` must show *more* detail than
   `--zoom 1`, not a magnified bitmap — that is the whole point of the re-render path.
   Also try `--rotate 0.4` and `--pan 120,-80`. A zoomed-in view should cull most strokes
   (`… N culled` in the breakdown) and get *faster* than the fit view.
5. **Paste documents.** `art2png --live-view art/complex2.art` and a paste document in
   Quick Look: pasted content must sit exactly where it sits in `<file>.png`, at 100% and
   after a pan/zoom/rotate (this was the "different depth planes" bug — see §9.2).
6. **In Quick Look:** one long drag must stay live for the whole gesture, with the left
   button as well as the middle one, and the scroll wheel must zoom at the pointer; HUD
   shows mode + FPS (renders/sec); zoom shows a percentage; the four resets work from the
   context menu and from `0`/`P`/`Z`/`R`; nothing renders when idle. Slow frames
   (>250 ms) log their breakdown to the unified log.
7. **Regression:** the three static render paths unchanged; `--live` (single raster)
   still works; a document with pastes (`art/paste*`, `art/layers.art`) still looks
   right through the "rebuilt per frame" path.

### Take 4 — what the first take-3 *interactive* build taught us (2026-10-08)

Reported after building take 3 on macOS:

1. **Orientation: the live image is y-flipped**, and `--flip-y` did nothing —
   `art2png --live` simply never passed the flag through to the present pass (it only
   did for `--live-view`). The present pass *did* have a flip, but it composed the mirror
   **after** the clip matrix, i.e. mirrored in NDC space about the canvas height, which is
   why the app's checkbox made the image *disappear* instead of flipping it.
2. **Pasted content sat "on a different depth plane"** as soon as the camera changed,
   and only in the interactive path — the static path was fine.
3. **Very slow**: 25 s for one frame of a 321 611-segment document (the CG path takes
   1.5 s for the same file), and it got worse with `--viewport`.
4. **"No continuous action"**: with 25 s frames, dragging cannot feel continuous.
5. Suggested extra bindings: lmb pan, scroll-wheel zoom, lmb+shift rotate.

#### 9.2 Root causes found

**(a) Reversed transform composition — the "planes" bug and the broken flip.** The live
path composed transforms as `camera.concatenating(base)`, which applies the *camera*
first. `a.concatenating(b)` applies **a first**, then b (identical in CoreGraphics and
Silica), so the intended order — layer, then base, then camera — was inverted in three
places (`LiveRenderCache.liveBaseTransform`, `artToDevice`, the cut recomposition) plus
the `m1` recovery in the cache build and the present pass's mirror.

That is invisible at 100% zoom for a plain document (a uniform-scale view matrix
commutes with the camera, so both orders agree) and appears as soon as anything is
rotated, panned, or the layer/paste matrices are not axis-aligned — exactly the reported
symptom. Fixed, and pinned down by tests that check the *order* by applying each
composition to a point (`LiveRenderCacheTests.testLiveBaseAppliesTheBaseFirst`,
`testArtToDeviceAppliesLayerBaseCamera`, `testCutRecomposesAgainstAnyCamera`).

**(b) A quadratic arena growth — the 25 s frames.** One interactive frame bins every
stroke into a staging arena, asking for more room each time. Growth was **exact-fit**:
`allocate` + `memcpy` + `deallocate` per stroke, and a fresh raw block is a new `mmap`, so
every stroke also faulted every page of the growing arena back in. For 2 214 strokes and a
~20 MB arena that is tens of gigabytes of copying and tens of millions of page faults —
and it happened on the *first* frame only (the capacity survives), which matches "the
image eventually shows up, then it is fine". Growth is now geometric and seeded with the
previous frame's size (`MetalRenderer_LiveCompositing.staging(needed:)`).

Measured CPU cost of the same document on Linux (`ART_LIVE_PROFILE=1 swift test
--filter LiveProfileTests`): cache build 213 ms, camera re-mapping 8 ms — so the CPU was
never the problem and the arena was.

**(c) Per-stroke full-canvas dispatches.** Every stroke dispatches over the whole canvas
and the kernel early-outs on empty tiles, so a 2 214-stroke document launches ~72 M
threadgroups. Bumping the live passes from 8×8 to 32×32 threads per threadgroup (the
kernels derive their tile from `thread_position_in_grid`, so the shape is free) cuts the
launch count 16× with identical output. Dispatching only the tiles a stroke touches needs
a pixel-origin in the shared `Params` struct — deliberately **not** done yet, since a
Swift/MSL layout mismatch there would silently corrupt every segment.

**(d) Off-screen strokes were rasterised anyway.** Cached strokes now carry ink bounds in
reference space (`LiveCachedStroke.referenceBounds`) and are skipped when the
camera-transformed box misses the viewport. A stroke that touches no pixel of the target
cannot change a pixel, so this is free correctness-wise — and a zoomed-in frame gets much
cheaper.

#### 9.3 Take 4 changes

- **Orientation**: mirror composed *inside* the canvas (`mirrored.concatenated(with: clip)`),
  wired into `--live` / `--live-only` / `--live-view`, default on via the single constant
  `LiveCanvasRowOrder.presentsMirrored` (app setting renamed to `mirrorLiveCanvas`,
  default on; `art2png --no-flip-y` opts out).
- **Composition order** fixed in the five places above.
- **Arena** grows geometrically, seeded from the previous frame.
- **32×32 threadgroups** for all live passes.
- **Off-screen culling** per cached stroke, with a culled counter in the report.
- **Extra input bindings**: left drag pans (shift → rotate, cmd → zoom), middle drag
  keeps pan/cmd-zoom/shift-rotate, the scroll wheel zooms at the pointer, all through the
  same `commitTransform` funnel.
- **Instrumentation**: `Renderer.lastLiveFrameTiming` (`LiveFrameTiming`) with
  bin/encode/gpu/paper; `art2png --live*` prints it, the QL extension logs frames
  slower than 250 ms.
- **Testability**: the cache build moved out of the Metal-guarded file into
  `LiveRenderCache.swift` (which is not Metal-guarded), so it runs on Linux — plus
  `LiveCacheBuildTests` (real documents, paste layers excluded from the cache size,
  bounds sanity) and `LiveProfileTests` (opt-in CPU profile of the geometry stages).

**Not touched:** `project.pbxproj`.

> **Adding a library file:** a new file in `Sources/ArtRenderLibrary` has to be listed in
> `Package.swift`'s `sources:` array — that *is* enough for Xcode to compile it, because
> the project references this package. What is not enough is a stale copy of
> `Package.swift`: the first take-4 build failed with
> `Cannot find 'buildLiveRenderCacheGeometry' in scope` for a file the manifest listed
> correctly on disk. If a new library file is ever needed, list it in `Package.swift` and
> make sure that manifest is the one being built. (This round ended up not needing a new
> library file at all: the builder and the frame timing live in `LiveRenderCache.swift`,
> which every target already compiles.)

### Test points for take 3 (needs macOS)

Ordered so the cheapest, most diagnostic runs come first.

1. **Orientation.** `art2png --live art/mischief-document.art` → compare
   `<file>-live.png` with `<file>.png`. The live canvas is now **mirrored by default**
   (`LiveCanvasRowOrder.presentsMirrored`), which is the orientation macOS actually
   showed; `art2png --no-flip-y` / the app's "Mirror canvas vertically" toggle turn it
   back off. `--live`, `--live-only` and `--live-view` all honour it now.
2. **Cache.** `art2png --live-cache art/*.art` (loop over the samples) → the report must
   show a sane segment count and budget, and "N rebuilt per frame" only for documents
   that really contain paste/merge actions.
3. **Interactive path at 100%.** `art2png --live-view --viewport 1920x1080` →
   `<file>-live-view.png` should match `<file>.png` closely (same strokes, same paper;
   the AA may differ by a hair because the re-render flattens at the cache's reference
   transform). Every render prints its stage breakdown now, e.g.
   `Live view: 410 ms total (bin 95, encode 12, gpu 300, paper 3) — 2214 strokes / 321611 segments, 1 layers cached, 0 rebuilt, 0 culled`.
4. **Interactive path zoomed in.** `--live-view --zoom 4` must show *more* detail than
   `--zoom 1`, not a magnified bitmap — that is the whole point of the re-render path.
   Also try `--rotate 0.4` and `--pan 120,-80`. A zoomed-in view should cull most strokes
   (`… N culled` in the breakdown) and get *faster* than the fit view.
5. **Paste documents.** `art2png --live-view art/complex2.art` and a paste document in
   Quick Look: pasted content must sit exactly where it sits in `<file>.png`, at 100% and
   after a pan/zoom/rotate (this was the "different depth planes" bug — see §9.2).
6. **In Quick Look:** one long drag must stay live for the whole gesture, with the left
   button as well as the middle one, and the scroll wheel must zoom at the pointer; HUD
   shows mode + FPS (renders/sec); zoom shows a percentage; the four resets work from the
   context menu and from `0`/`P`/`Z`/`R`; nothing renders when idle. Slow frames
   (>250 ms) log their breakdown to the unified log.
7. **Regression:** the three static render paths unchanged; `--live` (single raster)
   still works; a document with pastes (`art/paste*`, `art/layers.art`) still looks
   right through the "rebuilt per frame" path.

### Take 4 — what the first take-3 *interactive* build taught us (2026-10-08)

Reported after building take 3 on macOS:

1. **Orientation: the live image is y-flipped**, and `--flip-y` did nothing —
   `art2png --live` simply never passed the flag through to the present pass (it only
   did for `--live-view`). The present pass *did* have a flip, but it composed the mirror
   **after** the clip matrix, i.e. mirrored in NDC space about the canvas height, which is
   why the app's checkbox made the image *disappear* instead of flipping it.
2. **Pasted content sat "on a different depth plane"** as soon as the camera changed,
   and only in the interactive path — the static path was fine.
3. **Very slow**: 25 s for one frame of a 321 611-segment document (the CG path takes
   1.5 s for the same file), and it got worse with `--viewport`.
4. **"No continuous action"**: with 25 s frames, dragging cannot feel continuous.
5. Suggested extra bindings: lmb pan, scroll-wheel zoom, lmb+shift rotate.

#### 9.2 Root causes found

**(a) Reversed transform composition — the "planes" bug and the broken flip.** The live
path composed transforms as `camera.concatenating(base)`, which applies the *camera*
first. `a.concatenating(b)` applies **a first**, then b (identical in CoreGraphics and
Silica), so the intended order — layer, then base, then camera — was inverted in three
places (`LiveRenderCache.liveBaseTransform`, `artToDevice`, the cut recomposition) plus
the `m1` recovery in the cache build and the present pass's mirror.

That is invisible at 100% zoom for a plain document (a uniform-scale view matrix
commutes with the camera, so both orders agree) and appears as soon as anything is
rotated, panned, or the layer/paste matrices are not axis-aligned — exactly the reported
symptom. Fixed, and pinned down by tests that check the *order* by applying each
composition to a point (`LiveRenderCacheTests.testLiveBaseAppliesTheBaseFirst`,
`testArtToDeviceAppliesLayerBaseCamera`, `testCutRecomposesAgainstAnyCamera`).

**(b) A quadratic arena growth — the 25 s frames.** One interactive frame bins every
stroke into a staging arena, asking for more room each time. Growth was **exact-fit**:
`allocate` + `memcpy` + `deallocate` per stroke, and a fresh raw block is a new `mmap`, so
every stroke also faulted every page of the growing arena back in. For 2 214 strokes and a
~20 MB arena that is tens of gigabytes of copying and tens of millions of page faults —
and it happened on the *first* frame only (the capacity survives), which matches "the
image eventually shows up, then it is fine". Growth is now geometric and seeded with the
previous frame's size (`MetalRenderer_LiveCompositing.staging(needed:)`).

Measured CPU cost of the same document on Linux (`ART_LIVE_PROFILE=1 swift test
--filter LiveProfileTests`): cache build 213 ms, camera re-mapping 8 ms — so the CPU was
never the problem and the arena was.

**(c) Per-stroke full-canvas dispatches.** Every stroke dispatches over the whole canvas
and the kernel early-outs on empty tiles, so a 2 214-stroke document launches ~72 M
threadgroups. Bumping the live passes from 8×8 to 32×32 threads per threadgroup (the
kernels derive their tile from `thread_position_in_grid`, so the shape is free) cuts the
launch count 16× with identical output. Dispatching only the tiles a stroke touches needs
a pixel-origin in the shared `Params` struct — deliberately **not** done yet, since a
Swift/MSL layout mismatch there would silently corrupt every segment.

**(d) Off-screen strokes were rasterised anyway.** Cached strokes now carry ink bounds in
reference space (`LiveCachedStroke.referenceBounds`) and are skipped when the
camera-transformed box misses the viewport. A stroke that touches no pixel of the target
cannot change a pixel, so this is free correctness-wise — and a zoomed-in frame gets much
cheaper.

#### 9.3 Take 4 changes

- **Orientation**: mirror composed *inside* the canvas (`mirrored.concatenated(with: clip)`),
  wired into `--live` / `--live-only` / `--live-view`, default on via the single constant
  `LiveCanvasRowOrder.presentsMirrored` (app setting renamed to `mirrorLiveCanvas`,
  default on; `art2png --no-flip-y` opts out).
- **Composition order** fixed in the five places above.
- **Arena** grows geometrically, seeded from the previous frame.
- **32×32 threadgroups** for all live passes.
- **Off-screen culling** per cached stroke, with a culled counter in the report.
- **Extra input bindings**: left drag pans (shift → rotate, cmd → zoom), middle drag
  keeps pan/cmd-zoom/shift-rotate, the scroll wheel zooms at the pointer, all through the
  same `commitTransform` funnel.
- **Instrumentation**: `Renderer.lastLiveFrameTiming` (`LiveFrameTiming`) with
  bin/encode/gpu/paper; `art2png --live*` prints it, the QL extension logs frames
  slower than 250 ms.
- **Testability**: the cache build moved out of the Metal-guarded file into
  `LiveRenderCache.swift` (which is not Metal-guarded), so it runs on Linux — plus
  `LiveCacheBuildTests` (real documents, paste layers excluded from the cache size,
  bounds sanity) and `LiveProfileTests` (opt-in CPU profile of the geometry stages).

**Not touched:** `project.pbxproj` — and, as of this round, **no new library files either**.

> **Lesson (cost one build round):** a new file in `Sources/ArtRenderLibrary` has to be
> listed in `Package.swift`'s `sources:` array *and* picked up by the Xcode project's
> library target, and the second part is not automatic — the first take-4 build failed with
> `Cannot find 'buildLiveRenderCacheGeometry' in scope` for a brand-new file that
> `Package.swift` did list. Anything the live path needs therefore goes **into a file that
> is already compiled** (`LiveRenderCache.swift`), so the project never has to learn about
> it.

### Take 4b — orientation, keys, metallib script, profiling harness (2026-10-09)

Reported after the take-4 build:

1. The metallib script does not work, `--from-xcode` included (building in Xcode does).
2. `--live` looks correct — orientation fixed.
3. The 25 s frames are gone: **433 ms total (bin 59, encode 19, gpu 333, paper 1)** for
   321 611 segments / 2 214 strokes, cache built in 170 ms. So the remaining cost is the
   GPU dispatches, exactly as §9.2(c) predicted.
4. Pasted content stays registered — the composition-order fix holds.
5. Keyboard shortcuts do not work, and the canvas mirror inverts vertical panning and the
   zoom-to-the-pointer anchor.

#### 9.4 The orientation was the mirror, not the data

The mirror added in §9.3 made the image right and the *gestures* wrong, which is the
signature of a flip applied **outside** the mapping the gestures are expressed in:
panning runs along the y axis, so a mirrored display reverses it, and a zoom anchor is a
view-pixel point, so it lands on the mirrored point. Both symptoms, one cause.

The fix is one sign. `LiveViewTransform.clipMatrix` assumed "clip +1 is the top of the
drawable"; the drawable this presents into wants clip −1 at the top for a y-down canvas, so
`ndc.y = viewY / viewH * 2 - 1` replaces `1 - viewY / viewH * 2`. Now:

* the present matrix **is** the gesture mapping (`matrix` and `clipMatrix` agree), and
* canvas row 0 → clip −1 → the top of the screen, i.e. the document comes out upright with
  no mirroring at all.

So `LiveCanvasRowOrder`, the app setting, and `--flip-y`/`--no-flip-y` are all gone — the
orientation lives in exactly one matrix, and
`LiveViewTransformTests.testClipMatrixAgreesWithGestureOrientation` pins the convention
(canvas row 0 → clip −1 when the canvas fills the viewport, and increasing y increases
clip y).

`--flip-y`/`--no-flip-y` are still *accepted* by art2png, printing a deprecation warning,
so old command lines do not fail.

#### 9.5 Other take-4b changes

- **Keys**: ⌘-based shortcuts can never reach a Quick Look extension (⌘O/⌘P/⌘Z/⌘R belong
  to the system and Finder), so the resets moved to **⌃0 / ⌃P / ⌃Z / ⌃R** (bare keys still
  accepted). The right-click menu remains the guaranteed path.
- **"One frame, then the gesture stops"**: the drag-cancel check trusted a single frame with
  an empty `pressedMouseButtons`. Inside the Quick Look host that reading can be empty while
  the user is still dragging (the host can swallow the button-down), so the gesture was
  cancelled after its first frame. The check is now gated by a 0.35 s quiet period since the
  last drag event.
- **Metallib script**: rewritten around what actually failed — it now asks
  `xcodebuild -showBuildSettings` for `BUILT_PRODUCTS_DIR` (with a DerivedData search as a
  fallback), verifies kernel names as substrings (metallibs store them with suffixes
  depending on the compiler), and gained `--install <path>` and `--force`.
  `xcrun metal` is now invoked without `-c`, which was producing an AIR object rather than
  a linkable metallib.
- **Profiling harness / document windows** (`ArtQuickLook/ArtQuickLook/LiveDocumentWindow.swift`,
  added to the app target by hand — see `ADD_TO_XCODE.txt`): `ArtQuickLook` can open an
  `.art` file in its own live-view window. Settings became a singleton `Window`, documents
  a `WindowGroup(for: URL.self)`, and `ContentView` got an *Open Document…* button plus
  `.onOpenURL`. The point is profiling: a Quick Look preview runs out-of-process, an app
  window does not, so Instruments (Metal System Trace / GPU Frame Debugger) can attach to
  it. The window also prints the live frame breakdown while you interact.

### Take 4c — orientation settled, flicker, FPS cap (2026-10-09)

From the take-4b run: continuous camera operation now works; the metallib script is
unnecessary (Xcode builds it); Instruments runs against the app's document window
(`performance-profiling/`); vertical pan/zoom was *still* y-flipped; frames blinked; the
frame rate was soft-capped around 120; rotate-around-pointer was unwanted; and the app must
stay macOS 12 compatible.

#### 9.6 The orientation, second attempt — what I got wrong

§9.4 "fixed" the orientation by flipping the sign in `clipMatrix` and removing the mirror.
It did not change anything: the old code was `clipOld(flipY(canvas))` and the new code was
`clipNew(canvas)`, and with `clipOld(y) = 1 - 2y/H` those are *the same function*:

    clipOld(H - y) = 1 - 2(H - y)/H = 2y/H - 1 = clipNew(y)

So the rendered image was identical, and the gesture/display mismatch survived — exactly
what the follow-up run reported ("still Y-flipped"). The mistake was treating the mirror as
cosmetic; it was the only reason the sign looked wrong, and removing one without replacing
the other cancelled out.

What is actually needed is the combination nobody had: **no mirror** *and* the original
sign, `ndc.y = 1 - viewY/viewH * 2`. The canvas' own orientation then survives to the
screen: row 0 at the top, increasing y going down — the same direction the gestures move
it.

To stop guessing about conventions, the canvas orientation is now *measured* rather than
assumed (`tmp/canvas_row_probe.py`, see §9.7): the art file's view matrix is the identity for
the sample documents, so canvas row index == document y, and probing where the ink of each
document point lands pins down which end row 0 is.

#### 9.7 Blinking between frames

`renderLive(cache:…)` starts every frame with `clearTexture(canvas)` — on the *same*
texture the UI is still presenting. Between the clear and the layer composite the next
present showed an empty canvas, so the strokes blinked. The paper/background texture is
only written at the very end of the frame, which is why the background did not blink — the
symptom matched exactly that asymmetry.

Fixed by double buffering: `MetalRenderer.liveCanvasTextures` / `liveBackgroundTextures`
hold two pairs, `beginLiveFrame()` flips to the pair the UI is not showing, and
`LiveRenderedCanvas` carries the pair it was rendered into (it already did, so the present
pass needed no change).

#### 9.8 Other take-4c changes

- **Rotation is about the view centre**, not the pointer (both the extension and the document
  window) — rotating from an edge then moves a lot, near the centre barely at all.
- **Frame-rate cap** (`Settings.liveMaxFPS`, default 60, presets Uncapped/30/60/120 plus a
  custom field). `LivePreviewSession.kick()` defers a request that arrives before the next
  slot instead of rendering a frame the display cannot show.
- **File ▸ Open .art-file…** in the app menu (NSOpenPanel; SwiftUI's `.fileImporter` has no
  menu-command equivalent), wired to the user's `DocumentWindowCoordinator`.
- **Single settings window on macOS 12**: `Window` is macOS 13+, so the answer for 12 is
  `applicationShouldHandleReopen` returning true — a reopen activates the running window
  instead of creating a second one (the user had already gone the "remove File ▸ New" route
  as well; both are in).
- `tmp/` added to `.gitignore` for orientation probes.

#### 9.9 Next task

`LIVE-VIEW-Performance-optimizations.md` — the per-stroke tile-range dispatch (dispatch each
stroke only over the tiles it covers), written for a fresh agent, with the measurements, the
kernel sketch, the layout/SDK constraints that have bitten this code, and an explicit list of
the options that were considered and rejected. Deferred on purpose: half-resolution
interacting frames, 32 px tiles, GPU tile binning, SDF caching, and incremental edge-tile
rendering (with the reasoning for why the last one is unnecessary once tile-range dispatch
lands).
