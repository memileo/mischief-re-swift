# Live Metal View for ArtQuickLook — Implementation Plan

Status: **in progress** (updated as work proceeds; see [Progress log](#progress-log))

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
| `Tests/ArtRenderLibraryTests/LiveViewTransformTests.swift` | 15 Linux-runnable tests for the transform maths |

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

## 7b. Known limitations / deliberate choices

- **Embedded images** (`art.images`) are not drawn by the live path, matching the
  existing GPU SDF segment path. The CPU/GPU-stamp paths do draw them.
- **Document raster** is fixed at render time (`previewScale`, floored at 1×): zooming
  in past 100% magnifies that raster, it does not re-render at higher resolution. This
  is the point of the live view; re-rendering on demand is a possible follow-up.
- **Paper texture** is baked once at canvas resolution, so it magnifies with the
  document (same as a raster preview).
- **Drag released outside the view** ends the interaction via a `pressedMouseButtons`
  check in the draw loop rather than delivering `otherMouseUp`.
- The middle button is reserved while the live view is up.

## 7. Risks

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

### Follow-ups (only if something misbehaves on macOS)
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

### Test points still to run (needs macOS)

1. `Scripts/build-metallib.sh` → metallib contains the four new functions.
2. `swift build -c release` on macOS, then `art2png --live art/<file>.art` →
   `<file>-live.png` must match `<file>.png` (paper, layer opacity, background) — the
   live hook runs the real present pass at 100% zoom, so the two PNGs should be
   pixel-close.
3. Build the **ArtQuickLook** scheme, tick "Live Metal view", open a `.art` in Quick
   Look: pan / zoom / rotate, FPS HUD, zoom %, all four resets, and no redraws at
   idle.
4. Regression: the three existing render paths still look identical (the layer-op
   extraction is a pure move, but verify anyway).
5. Try a file with embedded images (`art/embedd.art`): note that the default GPU
   segment path already drops them, and the live path behaves the same (see
   "Stretch" below).