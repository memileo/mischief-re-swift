import Foundation
#if os(Linux)
import Silica
import CoreFoundation
// import Cairo
#elseif os(macOS)
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
#endif
import ArtParser
import ArtRenderLibrary

// MARK: - Main Entry Point
func main() {
    let args = CommandLine.arguments
    
    func info() {
        print("Usage: art2png [--option value] <input.art>")
        print("  --scale N              Render at N× device scale for high-res export")
        print("  --export-gp <path>     GP: Export to Grease Pencil intermediate JSON")
        print("  --gp-radius-scale N    GP: Radius scale for GP export in meters (default: 0.01 = 1cm)")
        print("  --resample-step N      GP: Base resampling step for non-pencil strokes (default: 4.0)")
        print("  --catmull-rom          GP: Export raw control points for Catmull-Rom strokes (skip resampling)")
        print("  --cpu                  macOS only: Render strokes on CPU instead of GPU/Metal.")
        print("  --stamp                macOS only: Use circle stamps instead of segments for Metal/GPU")
    }
    
    guard args.count > 1 else {
        info()
        exit(1)
    }
    
    // Parse arguments
    var inputFile: String?
    var scale: CGFloat = 1.0
    var gpExportPath: String?
    var gpRadiusScale: CGFloat = 0.01
    var resampleStep: CGFloat = 4.0
    var catmullRom: Bool = false
    var forceCPU: Bool = false
    var useSegmentRendering = true
    
    var i = 1
    while i < args.count {
        if args[i] == "--scale" {
            i += 1
            guard i < args.count, let scaleValue = Double(args[i]) else {
                print("Error: --scale requires a numeric value")
                exit(1)
            }
            scale = CGFloat(scaleValue)
            i += 1
        } else if args[i] == "--export-gp" {
            i += 1
            guard i < args.count else {
                print("Error: --export-gp requires an output path")
                exit(1)
            }
            gpExportPath = args[i]
            i += 1
        } else if args[i] == "--gp-radius-scale" {
            i += 1
            guard i < args.count, let rsValue = Double(args[i]) else {
                print("Error: --gp-radius-scale requires a numeric value")
                exit(1)
            }
            gpRadiusScale = CGFloat(rsValue)
            i += 1
        } else if args[i] == "--resample-step" {
            i += 1
            guard i < args.count, let stepValue = Double(args[i]) else {
                print("Error: --resample-step requires a numeric value")
                exit(1)
            }
            resampleStep = CGFloat(stepValue)
            i += 1
        } else if args[i] == "--catmull-rom" {
            catmullRom = true
            i += 1
        } else if args[i] == "--cpu" {
            forceCPU = true
            i += 1
        } else if args[i] == "--stamp" {
            useSegmentRendering = false
            i += 1
        } else if args[i] == "--help" || args[i] == "-h" {
            info()
            exit(1)
        } else {
            inputFile = args[i]
            i += 1
        }
    }
    
    guard let inputPath = inputFile else {
        print("Error: No input file specified")
        exit(1)
    }
    
    guard FileManager.default.fileExists(atPath: inputPath) else {
        print("Error: File not found: \(inputPath)")
        exit(1)
    }
    
    guard let data = try? Data(contentsOf: URL(fileURLWithPath: inputPath)) else {
        print("Error: Failed to read file: \(inputPath)")
        exit(1)
    }
    
    guard let art = ArtParser(data: [UInt8](data)) else {
        print("Error: Failed to parse art file")
        exit(1)
    }
    
    let canvasSize = CGSize(width: 1920, height: 1080)
    let renderer = Renderer(canvasSize: canvasSize, scale: scale, forceCPU: forceCPU, useSegmentRendering: useSegmentRendering)
    
    // ── GP Export path ──
    if let gpPath = gpExportPath {
        if renderer.exportToGreasePencil(
            art: art,
            outputPath: gpPath,
            radiusScale: gpRadiusScale,
            resampleStep: resampleStep,
            catmullRom: catmullRom
        ) {
            print("GP export complete: \(gpPath)")
            exit(0)
        } else {
            print("Error: GP export failed")
            exit(1)
        }
    }
    
    // ── Normal PNG render path ──
    guard let image = renderer.render(art: art) else {
        print("Error: Failed to render art")
        exit(1)
    }
    
    let inputURL = URL(fileURLWithPath: inputPath)
    let outputPath = inputURL.deletingPathExtension().appendingPathExtension("png").path
    saveCGImageAsPNG(image, to: outputPath)
    print("Successfully rendered \(inputPath) to \(outputPath)")
}

// Helper function to save CGImage as PNG
func saveCGImageAsPNG(_ image: CGImage, to path: String) {
    #if os(macOS)
    let url = URL(fileURLWithPath: path)
    
    // Ensure the image is explicitly in the sRGB color space before saving.
    // This re-creates the image, guaranteeing it's associated with the system's sRGB profile.
    guard let sRGBColorSpace = CGColorSpace(name: CGColorSpace.sRGB),
          let sRGBImage = image.copy(colorSpace: sRGBColorSpace) else {
        print("Error: Could not convert image to sRGB color space for saving.")
        // As a fallback, try to save the original image anyway.
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
            print("Failed to create image destination")
            exit(1)
        }
        CGImageDestinationAddImage(destination, image, nil)
        if !CGImageDestinationFinalize(destination) {
            print("Failed to finalize image destination")
            exit(1)
        }
        return
    }
    
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else {
        print("Failed to create image destination")
        exit(1)
    }
    
    // Save the new image that is guaranteed to be in the sRGB color space.
    // The PNG encoder should now correctly embed the sRGB profile information.
    CGImageDestinationAddImage(destination, sRGBImage, nil)
    if !CGImageDestinationFinalize(destination) {
        print("Failed to finalize image destination")
        exit(1)
    }
    
    #elseif os(Linux)
    // Silica's CGImage publicly exposes its underlying Cairo.Surface.Image.
    // We use PureSwift Cairo's throwing writePNG() to get the data, then write 
    // it to disk so we can catch and report errors properly.
    do {
        let pngData = try image.surface.writePNG()
        try pngData.write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
        print("Error: Failed to write PNG file to \(path). Error: \(error)")
        exit(1)
    }
    #endif
}

// Run the main function
main()
