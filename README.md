#### AI Disclaimer: In large part coded with various LLMs.
<picture>
<img width="256" height="256" alt="ArtQuickLook icon" src="https://github.com/user-attachments/assets/c6a6d8d0-b173-4a05-a013-69ba5b35be25" />
</picture>

# art2png    ∙     ArtQuickLook    ∙    artparser swift

Swift port of [**mischief-re** by m1el](https://github.com/m1el/mischief-re) (for parsing Mischief .art files), as well as a Quick Look Preview extension and command line rendering tool.

[Blender GP import plugin.](https://github.com/memileo/mischief_gp_importer)

## **ArtQuickLook:** *macOS 12+*
App that contains a quick look extension to preview .art files. Select a file in Finder and press spacebar to get a preview. Art-files can also be opened in ArtQuickLook.

<picture>
<img width="382" height="253" alt="preview-screencap_03" src="https://github.com/user-attachments/assets/72a38959-64f8-4062-bd98-827fc7fbf74d" />
</picture>

## **artparser:**  *macOS 12+ and Linux*
Command line tool that outputs json print of an .art-file. An addition to this port is a fix to how the pen pressure is read.

List commands:
```
./artparser --help
```

Pipe to less or similar (or try a faster terminal emulator) if prints appears slow: `./artparser <input_file> | less`

## **art2png:** *macOS 12+ and Linux* 
Command line tool that renders to PNG using various techniques or exports to JSON.
- **On macOS:** CoreGraphics CPU stamp rendering, Metal stamp rendering, Metal SDF-shape rendering (default if supported), full metal-compositing via the --live-* flags.
- **On Linux:** currently only renders with Cairo via CoreGraphics translation layer Silica and is very slow.

Used in this Blender Grease Pencil-importer addon that also can import Rnote files - works on both macOS an Linux. [mischief_gp_importer](https://github.com/memileo/mischief_gp_importer)

List commands:
```
./art2png
```


# Compile:

### artparser:
1. ```git clone https://github.com/memileo/mischief-re-swift.git```
2. ```cd mischief-re-swift```
3. ```mkdir build && cd Sources/ArtParser```
4. ```swiftc -whole-module-optimization -O artparser.swift lzunpack.swift EmptyArtData.swift PressureEval.swift -o ../../build/artparser```

### art2png: 

**macOS:**
1. ```git clone https://github.com/memileo/mischief-re-swift.git```
2. ```cd mischief-re-swift```
3. ```Scripts/build-metallib.sh```
4. ```swift build -c release```  
Binary and resource bundle are built to .build/release/

**Linux:**
1. ```git clone https://github.com/memileo/mischief-re-swift.git```
2. ```cd mischief-re-swift```
3. ```swift build -c release```  
Binary and resource bundle are built to .build/release/

### ArtQuickLook:
1. ```git clone https://github.com/memileo/mischief-re-swift.git```
2. Open the Xcode project in mischief-re-swift/ArtQuickLook
3. First build **ArtRenderShaders** scheme
4. Second build **ArtQuickLook** scheme

# State:
There are some known bugs.  
Most files saved with the latest Mischief version should render mostly fine.
