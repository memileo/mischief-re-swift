#### AI Disclaimer: In large part copy-paste coded with various LLMs.
<picture>
<img width="256" height="256" alt="ArtQuickLook icon" src="https://github.com/user-attachments/assets/c6a6d8d0-b173-4a05-a013-69ba5b35be25" />
</picture>

# art2png    ∙     ArtQuickLook    ∙    artparser swift

Swift port of [**mischief-re** by m1el](https://github.com/m1el/mischief-re) (for parsing Mischief .art files), as well as a Quick Look Preview extension and command line rendering tool.

[Blender GP import plugin.](https://github.com/memileo/mischief_gp_importer)
## **artparser:**  *macOS 12+ and Linux*
Command line tool that outputs json print of an .art-file. An addition in this port is phase unwrapping for pen pressure: It reconstructs the compressed 4‑band sequence into full pressure range, producing mostly correct, continuous stroke width. <small>(Still some issue cases. Mostly seen in short/dot-type strokes and art files saved with the lossy compress option and then resaved without it.)</small>

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
- **On macOS:** CoreGraphics CPU stamp rendering, Metal stamp rendering, Metal SDF-shape rendering (default if supported). Layer compositing currently happens on the CPU only.
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
```

## **ArtQuickLook:** *macOS 12+*
App that contains a quick look extension to preview .art files. Select a file in Finder and press spacebar to get a preview.

<picture>
<img width="382" height="253" alt="preview-screencap_03" src="https://github.com/user-attachments/assets/72a38959-64f8-4062-bd98-827fc7fbf74d" />
</picture>

# Compile:

**artparser:**
1. ```git clone https://github.com/memileo/mischief-re-swift.git```
2. ```cd mischief-re-swift/Sources/ArtParser```
3. ```swiftc -whole-module-optimization -O artparser.swift lzunpack.swift EmptyArtData.swift PressureEval.swift -o artparser```

**art2png:**
1. ```git clone https://github.com/memileo/mischief-re-swift.git```
2.  ```cd mischief-re-swift```
3. ```swift build -c release```
4. Binary and resource bundle are built to .build/release/

**ArtQuickLook:**
1. ```git clone https://github.com/memileo/mischief-re-swift.git```
2. Open the Xcode project in mischief-re-swift/ArtQuickLook
3. First build **ArtRenderShaders** scheme
4. Second build **ArtQuickLook** scheme

# State:
The .art format implementation/reverse engineering is incomplete. There are several known bugs.

Simpler documents with only brush strokes (no copy paste, free transforms, layer merge) saved with the latest Mischief version should render mostly fine.
