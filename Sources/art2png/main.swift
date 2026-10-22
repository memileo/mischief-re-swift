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
        print("  --live                 macOS only: Also render through the live Metal canvas path")
        print("                          (writes <input>-live.png next to the normal output)")
        print("  --live-only            macOS only: Only render the live canvas path")
        print("  --live-view            macOS only: Interactive (re-render) path; writes")
        print("                          <input>-live-view.png for the given view")
        print("  --live-cache           macOS only: Report geometry cache size / budget")
        print("  --viewport WxH         Viewport for --live-view (default 1600x900)")
        print("  --zoom F               Zoom factor for --live-view (1 = as the file shows)")
        print("  --pan X,Y              Pan in view pixels for --live-view")
        print("  --rotate R             Rotation in radians for --live-view")
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
    var useLiveCanvas = false
    var liveOnly = false
    var useLiveView = false
    var liveCacheReport = false
    var viewportSize = CGSize(width: 1600, height: 900)
    var liveZoom: CGFloat = 1
    var livePan = CGPoint.zero
    var liveRotation: CGFloat = 0
    
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
        } else if args[i] == "--live" {
            useLiveCanvas = true
            i += 1
        } else if args[i] == "--live-only" {
            useLiveCanvas = true
            liveOnly = true
            i += 1
        } else if args[i] == "--live-view" {
            useLiveView = true
            i += 1
        } else if args[i] == "--live-cache" {
            liveCacheReport = true
            i += 1
        } else if args[i] == "--flip-y" || args[i] == "--no-flip-y" {
            // Removed: canvas row order is no longer adjustable (see LiveViewTransform).
            print("Warning: \(args[i]) is gone — the live canvas orientation is fixed")
            i += 1
        } else if args[i] == "--zoom" {
            i += 1
            guard i < args.count, let v = Double(args[i]), v.isFinite, v > 0 else {
                print("Error: --zoom requires a positive number"); exit(1)
            }
            liveZoom = CGFloat(v)
            i += 1
        } else if args[i] == "--rotate" {
            i += 1
            guard i < args.count, let v = Double(args[i]), v.isFinite else {
                print("Error: --rotate requires a number"); exit(1)
            }
            liveRotation = CGFloat(v)
            i += 1
        } else if args[i] == "--pan" {
            i += 1
            guard i < args.count else { print("Error: --pan requires X,Y"); exit(1) }
            let parts = args[i].split(separator: ",").compactMap { Double($0) }
            guard parts.count == 2, parts.allSatisfy({ $0.isFinite }) else {
                print("Error: --pan requires X,Y"); exit(1)
            }
            livePan = CGPoint(x: CGFloat(parts[0]), y: CGFloat(parts[1]))
            i += 1
        } else if args[i] == "--viewport" {
            i += 1
            // Strict WxH. "0.25" (a zoom accidentally passed as the viewport) used to
            // parse as 0.25×0.25 and render a 1×1 PNG without a word — refuse instead.
            guard i < args.count else { print("Error: --viewport requires WxH"); exit(1) }
            let parts = args[i].split(separator: "x", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let w = Int(parts[0]), let h = Int(parts[1]),
                  w >= 1, h >= 1, w <= 16384, h <= 16384 else {
                print("Error: --viewport needs WxH with whole pixels (e.g. 1920x1080), "
                      + "got '\(args[i])'")
                exit(1)
            }
            viewportSize = CGSize(width: w, height: h)
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
    
    let inputURL = URL(fileURLWithPath: inputPath)
    let outputPath = inputURL.deletingPathExtension().appendingPathExtension("png").path
    
    let canvasSize = CGSize(width: 1920, height: 1080)
    let renderer = Renderer(canvasSize: canvasSize, scale: scale, forceCPU: forceCPU, useSegmentRendering: useSegmentRendering)
    // Per-stage breakdown of the interactive frames (`bin` / `encode` / `gpu` / `paper`).
    Renderer.livePathTiming = useLiveCanvas || useLiveView
    
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
    
    // ── Live Metal canvas path (what the interactive preview shows) ──
#if canImport(Metal)
    if useLiveCanvas {
        guard let live = renderer.renderLive(art: art) else {
            print("Error: Live Metal canvas render failed")
            exit(1)
        }
        guard let liveImage = renderer.livePreviewImage(
            live,
            transform: LiveViewTransform(),
            size: CGSize(width: Int(live.pixelSize.width), height: Int(live.pixelSize.height)))
        else {
            print("Error: Failed to render/read back the live preview")
            exit(1)
        }
        let livePath = inputURL.deletingPathExtension().appendingPathExtension("live.png").path
        saveCGImageAsPNG(liveImage, to: livePath)
        print("Live canvas (\(Int(live.pixelSize.width))×\(Int(live.pixelSize.height))): \(livePath)")
        
        if liveOnly { exit(0) }
    }
    
    // ── Interactive (re-render) path + cache report ──
    if useLiveView || liveCacheReport {
        guard let cache = renderer.buildLiveRenderCache(art: art, scale: scale) else {
            print("Error: live geometry cache failed to build")
            exit(1)
        }
        let megabytes = Double(cache.segmentCount * MemoryLayout<GPUSplineSegment>.stride) / 1_048_576.0
        print("""
              Live cache: \(cache.segmentCount) segments (\(String(format: "%.1f", megabytes)) MB), \
              \(cache.layers.count) layers, \
              \(cache.rebuildingLayers) rebuilt per frame (paste/merge), \
              budget \(Renderer.liveCacheSegmentBudget)
              """)
        
        if useLiveView {
            var transform = LiveViewTransform()
            if liveZoom != 1 { _ = transform.zoom(by: liveZoom, anchor: CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2), viewportSize: viewportSize) }
            if livePan != .zero { _ = transform.pan(by: livePan) }
            if liveRotation != 0 { _ = transform.rotate(by: liveRotation, anchor: CGPoint(x: viewportSize.width / 2, y: viewportSize.height / 2), viewportSize: viewportSize) }
            
            guard let live = renderer.renderLive(cache: cache, art: art, camera: transform,
                                                 viewport: viewportSize, clearPaper: true) else {
                print("Error: interactive live render failed")
                exit(1)
            }
            guard let image = renderer.livePreviewImage(live, transform: live.presentTransform,
                                                        size: live.pixelSize) else {
                print("Error: failed to read back the interactive live render")
                exit(1)
            }
            let viewPath = inputURL.deletingPathExtension().appendingPathExtension("live-view.png").path
            saveCGImageAsPNG(image, to: viewPath)
            print("Live view (\(Int(live.pixelSize.width))×\(Int(live.pixelSize.height)), "
                  + "zoom \(String(format: "%.2f", transform.zoom))x, "
                  + "rotate \(String(format: "%.3f", transform.rotation)) rad): \(viewPath)")
        }
        
        if liveCacheReport && !useLiveView { exit(0) }
    }
#else
    if useLiveCanvas || useLiveView || liveCacheReport {
        print("Error: --live / --live-view / --live-cache require macOS (Metal)")
        exit(1)
    }
#endif
    
    // ── Normal PNG render path ──
    guard let image = renderer.render(art: art) else {
        print("Error: Failed to render art")
        exit(1)
    }
    
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
