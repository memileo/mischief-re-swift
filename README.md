#### AI Disclaimer: In large part coded with various LLMs.
<picture>
<img width="256" height="256" alt="ArtQuickLook icon" src="https://github.com/user-attachments/assets/c6a6d8d0-b173-4a05-a013-69ba5b35be25" />
</picture>

# art2png    ∙     ArtQuickLook    ∙    artparser swift

Swift port of [**mischief-re** by m1el](https://github.com/m1el/mischief-re) (for parsing Mischief .art files), as well as a Quick Look Preview extension and command line rendering tool.

[Blender GP import plugin.](https://github.com/memileo/mischief_gp_importer)
## **artparser:**  *macOS 12+ and Linux*
Command line tool that outputs json print of an .art-file. An addition to this port is a fix to how the pen pressure is being read.

```
Usage: ./artparser <input_file>
Flags:
  --validate-empty: Validate empty.art
  --debug-unpack: Test LZUnpack only
  --performance-test: Time parsing performance
  --extract-hashes: Print paper texture hashes from jpg files
  --extract-paper: Output paper texture
  --pressure-json [file]: Run analytics against JSON reference data
```

Pipe to less or similar (or try a faster terminal emulator) if prints appears slow: `./artparser <input_file> | less`

## **art2png:** *macOS 12+ and Linux* 
Command line tool that renders to PNG using various techniques or exports to JSON.
- **On macOS:** CoreGraphics CPU stamp rendering, Metal stamp rendering, Metal SDF-shape rendering (default if supported). Layer compositing currently happens on the CPU only. There is also an `--live` mode that composites entirely in Metal (used by the interactive Quick Look preview).
- **On Linux:** currently only renders with Cairo via CoreGraphics translation layer Silica and is very slow.

Used in this Blender Grease Pencil-importer addon that also can import Rnote files - works on both macOS an Linux. [mischief_gp_importer](https://github.com/memileo/mischief_gp_importer)

```
Usage: art2png [--option value] <input.art>
  --scale N              Render at N× device scale for high-res export
  --export-gp <path>     GP: Export to Grease Pencil intermediate JSON
  --gp-radius-scale N    GP: Radius scale for GP export in meters (default: 0.01 = 1cm)
  --resample-step N      GP: Base resampling step for non-pencil strokes (default: 4.0)
  --catmull-rom          GP: Export raw control points for Catmull-Rom strokes (skip resampling)
  --cpu                  macOS only: Render strokes on CPU instead of GPU/Metal.
  --stamp                macOS only: Use circle stamps instead of segments for Metal/GPU
  --live                 macOS only: Also render through the live Metal canvas path
                         (writes <input>-live.png next to the normal output)
  --live-only            macOS only: Only render the live canvas path
  --live-view            macOS only: Render the interactive (re-rasterised) path
                         (writes <input>-live-view.png)
  --live-cache           macOS only: Only report the live geometry cache size/budget
  --zoom F               --live-view: zoom factor (1 = as the file shows it)
  --pan X,Y              --live-view: pan offset in pixels
  --rotate R             --live-view: rotation in radians
  --viewport WxH         --live-view: canvas size (default 1920x1080)
  --no-flip-y            macOS only: Present the live canvas unmirrored
                         (the canvas is mirrored by default, see LIVE_VIEW.md)
```

## **ArtQuickLook:** *macOS 12+*
App that contains a quick look extension to preview .art files. Select a file in Finder and press spacebar to get a preview.

<picture>
<img width="382" height="253" alt="preview-screencap_03" src="https://github.com/user-attachments/assets/72a38959-64f8-4062-bd98-827fc7fbf74d" />
</picture>

# Compile:

**artparser:**
1. ```git clone https://github.com/memileo/mischief-re-swift.git```
2. ```cd mischief-re-swift```
3. ```mkdir build && cd Sources/ArtParser```
4. ```swiftc -whole-module-optimization -O artparser.swift lzunpack.swift EmptyArtData.swift PressureEval.swift -o ../../build/artparser```

**art2png:**
1. ```git clone https://github.com/memileo/mischief-re-swift.git```
2.  ```cd mischief-re-swift```
3. ```swift build -c release```
4. Binary and resource bundle are built to .build/release/

**ArtQuickLook:**
1. ```git clone https://github.com/memileo/mischief-re-swift.git```
2. Build the **ArtRenderShaders** scheme (see *Metal shaders* below for installing the
   metallib it produces)
3. Open the Xcode project in mischief-re-swift/ArtQuickLook
4. Build the **ArtQuickLook** scheme

# Metal shaders

The kernels in `ArtQuickLook/ArtRenderShaders/*.metal` are compiled into a single
`ArtRenderShaders.metallib` that is **checked in** at
`Sources/ArtRenderLibrary/ArtRenderShaders.metallib` — that is the file SwiftPM copies
into the `ArtRenderLibrary` resource bundle and that the renderer loads at runtime.
Building the **ArtRenderShaders** scheme produces a metallib in DerivedData which is not
embedded anywhere, so after changing a `.metal` file:

```
Scripts/build-metallib.sh --from-xcode     # install the metallib Xcode just built
Scripts/build-metallib.sh                  # or compile the .metal files directly
Scripts/build-metallib.sh --verify-only    # check which functions are present
```

The verify step matters: if the live kernels are missing from the metallib the live view
falls back to the static render path instead of showing an error.

# Live Metal view (interactive preview)

The ArtQuickLook app has a **Live Metal view** radio option next to the static render
paths. The document is rendered on the GPU, **re-rasterised for the current view
whenever the view changes** (so zooming in keeps real detail instead of magnifying a
bitmap), and shown in an `MTKView`. All compositing — layer stacking, layer opacity,
paper texture, background multiply — happens in Metal shaders.

| Gesture | Action |
|---|---|
| left- or middle-mouse drag | pan |
| + **⌘** drag (either button) | zoom |
| + **⇧** drag (either button) | rotate about the view centre |
| scroll wheel | zoom at the pointer |

* The HUD (mode label, FPS, zoom percentage) appears only while the view is changing.
  FPS counts completed re-renders per second.
* Resets: right-click for the menu (the reliable path), or press **⌃0** (whole view, back
  to the view matrix stored in the file), **⌃P** (pan), **⌃Z** (zoom), **⌃R** (rotation).
  Bare `0`/`P`/`Z`/`R` also work if the host passes them on. ⌘-based shortcuts cannot be
  used here: ⌘O/⌘P/⌘Z/⌘R belong to the system and Finder and never reach the extension.
* "Preview image scale" sets the resolution the geometry cache is built at — below 1×
  is allowed, for weak GPUs on Retina displays.
* "Max frames/second" caps the live view (default 60; presets 30/60/120, uncapped, or a
  custom value). Rendering faster than the display can show only burns GPU.
* Nothing redraws when idle: frames happen when a canvas arrives or the transform
  changes, never on a timer.
* A document whose geometry is too big for the cache (or where Metal/the live kernels
  are unavailable) falls back to one rendered image that is transformed instead — the
  gestures then stay instant, but the raster does not gain detail.
* Frames slower than 250 ms log their breakdown (bin / encode / gpu / paper) to the
  unified log, so sluggishness can be diagnosed without a rebuild.
* `art2png` can dump and compare the two paths on macOS:
  * `--live` → `<file>-live.png` (single raster, present pass applied)
  * `--live-view [--zoom F] [--pan X,Y] [--rotate R] [--viewport WxH]` →
    `<file>-live-view.png` (interactive path at that view)
  * `--live-cache` → cache size / budget report
* The transform and cache maths are unit tested and run on Linux too: `swift test`.
  `ART_LIVE_PROFILE=1 swift test --filter LiveProfileTests` additionally prints the CPU
  cost of the cache build and of a camera re-map for the sample documents in `art/`.

See `LIVE_VIEW.md` for the design and the test checklist.

# Profiling the live view

A Quick Look preview is hosted out-of-process, which makes it an awkward Instruments
target. The app can open a document in its own live-view window instead — build and run
**ArtQuickLook**, then *Open Document…*; every window is a separate document, and the
settings window is a singleton.

Documents open from *File ▸ Open .art-file…* or *Open Document…* in the settings window,
each in its own window. That process can be profiled directly: *Product ▸ Profile*, or attach
**Instruments** (Metal System Trace, GPU Frame Debugger) to "ArtQuickLook". The window
shows the frame breakdown (total / bin / encode / gpu) while you pan, zoom and rotate.

For shader work without Instruments, the Metal Frame Debugger in Xcode (Debug ▸ Metal ▸
Capture Frame) works against the same running window.

Two conventions are easy to get wrong and cost real time: canvas rows are y-down (row 0 is
the document's *top*) while AppKit mouse coordinates are y-down and the live view's view
pixels / clip space are y-**up** — gestures convert through `LiveViewSpace`, and the present
matrix carries no mirror. See `LIVE_VIEW.md` §9.6.

# State:
There are some known bugs.
Most files saved with the latest Mischief version should render mostly fine.
