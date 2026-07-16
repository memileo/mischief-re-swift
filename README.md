#### AI Disclaimer: In large part copy-paste coded with various LLMs.
Licence: MIT

<img src="256 6.png" style="display: block; margin-left: 18%; "/>

# art2png    ∙     ArtQuickLook    ∙    artparser swift

Swift fork of [**mischief-re** by m1el](https://github.com/m1el/mischief-re) (for parsing Mischief .art files), as well as a Quick Look Preview extension and command line rendering tool.

[Blender GP import plugin.]()
#### **artparser:**  *macOS 12+ and Linux*
Command line tool that outputs json print of an .art-file. An addition in this port is phase unwrapping for the pen pressure, which produce a mostly correct result. <small>(Still some issue corner cases. Mostly seen in short/dot-type strokes and art files saved with the lossy compress option and then resaved as uncompressed.)</small>

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

Pipe to less or similar (or try a faster terminal emulator) if the print appears slow: `./artparser <input_file> | less`

#### **art2png:** *macOS 12+ and Linux* 
Command line tool that renders to PNG using various techniques or exports to JSON.
**On macOS:** CoreGraphics CPU stamp rendering, Metal stamp rendering, Metal SDF-shape rendering (default if supported). Layer compositing currently only happens on CPU.
**On Linux:** currently only renders with Cairo via CoreGraphics translation layer Silica and is very slow.
Used in this Blender Grease Pencil-importer addon that also can import Rnote files - works on both macOS an Linux. [mischief_gp_importer]()

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

#### **ArtQuickLook:** *macOS 12+*
App that contains a quick look extension to preview .art files. Select a file in Finder and press spacebar to render a preview.

# Compile:

**artparser:**
1. ```git clone mischief-re-swift```
2. ```cd mischief-re-swift/Sources/ArtParser```
3. ```swiftc -whole-module-optimization -O artparser.swift lzunpack.swift EmptyArtData.swift PressureEval.swift -o artparser```

**art2png:**
1. ```git clone mischief-re-swift```
2.  ```cd mischief-re-swift```
3. ```swift build -c release```
4. Binary and resource bundle compiles to .build/release/

**ArtQuickLook:**
1. ```git clone mischief-re-swift```
2. Open the Xcode project in mischief-re-swift/ArtQuickLook
3. First build **ArtRenderShaders** scheme
4. Second build **ArtQuickLook** scheme

# State:
There are several issues still to be worked out. Example: Copy/transform data, merged layers, files saved using the lossy compress option, correct phase unwrap algorithm, files created in earlier versions of Mischief, metal rendering issue on integrated intel graphics, length/density calculation for sdSoftEnvelopeSpline segments on zoomed in view.