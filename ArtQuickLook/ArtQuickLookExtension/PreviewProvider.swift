import Cocoa
import QuickLookUI
import UniformTypeIdentifiers
import ArtParser
// import your renderer module(s)

@available(macOS 12.0, *)
class PreviewProvider: NSViewController, QLPreviewingController {
    
    override func loadView() {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        self.view = v
    }
        
    // macOS 12+ data-based API — implement the Swift signature exactly (do NOT add a custom @objc name)
    @objc
    func providePreview(for request: QLFilePreviewRequest,
                        completionHandler handler: @escaping (Error?) -> Void) {
        preparePreviewOfFile(at: request.fileURL, completionHandler: handler)
    }
    
    // Legacy API — keep for compatibility with older hosts/tools
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        guard let data = try? Data(contentsOf: url) else {
            handler(NSError(domain: "ArtParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to read art file"]))
            return
        }
        
        guard let art = ArtParser(data: [UInt8](data)) else {
            handler(NSError(domain: "ArtParser", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to parse art file"]))
            return
        }
        
        // Read group plist settings
        let settings = Settings()
        let geometry = PreviewGeometry(settings: settings)
        
        // The live Metal view is a different kind of preview: it keeps an MTKView
        // around instead of producing one image, and falls back to the static path
        // whenever Metal/the live kernels are unavailable.
        if settings.renderPath.isLiveView {
            presentLivePreview(art: art, geometry: geometry, handler: handler)
            return
        }
        
        // Static path: render synchronously (as before), then install on the main thread.
        let cgImageToShow = renderStaticImage(art: art, geometry: geometry)
        DispatchQueue.main.async {
            guard let image = cgImageToShow else {
                handler(NSError(domain: "ArtRenderer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create test image"]))
                return
            }
            self.installStaticPreview(image, geometry: geometry)
            handler(nil)
        }
    }
    
    // MARK: - Live Metal view
    
    private var liveSession: LivePreviewSession?
    
    private func presentLivePreview(art: ArtParser,
                                    geometry: PreviewGeometry,
                                    handler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            let session: LivePreviewSession
            do {
                // The live view shows a document raster, so a scale below 1x would only
                // make it blurry — floor it at 1x.
                session = try LivePreviewSession(art: art,
                                                 canvasSize: geometry.canvasSize,
                                                 scale: max(1.0, geometry.scale))
            } catch {
                NSLog("ArtQuickLook live view unavailable: \(error.localizedDescription) — using static preview")
                self.renderStaticPreviewInBackground(art: art, geometry: geometry, handler: handler)
                return
            }
            
            self.liveSession = session
            self.replaceContent(with: session.view)
            self.preferredContentSize = geometry.preferredContentSize
            
            // Tell Quick Look we are ready right away: the GPU render happens on a
            // background queue and lands in the view when it is done.
            handler(nil)
            
            session.render(onReady: { [weak self] view in
                // The view may only have its real size now; force one frame at it.
                view.needsLayout = true
                view.layoutSubtreeIfNeeded()
                view.needsDisplay = true
                self?.preferredContentSize = geometry.preferredContentSize
            }, onFailure: { [weak self] error in
                NSLog("ArtQuickLook live render failed: \(error.localizedDescription) — using static preview")
                guard let self = self else { return }
                self.liveSession = nil
                // The preview was already announced to Quick Look, so just swap the
                // content instead of calling the completion handler a second time.
                self.renderStaticPreviewInBackground(art: art, geometry: geometry, handler: nil)
            })
        }
    }
    
    // MARK: - Static (single image) preview
    
    /// Renders the document the "old" way: one image, CPU/CoreGraphics compositing.
    private func renderStaticImage(art: ArtParser, geometry: PreviewGeometry) -> CGImage? {
        let forceCPU: Bool
        let useSegmentRendering: Bool
        switch geometry.renderPath {
            case .gpuSegments:
                forceCPU = false
                useSegmentRendering = true
            case .gpuStamps:
                forceCPU = false
                useSegmentRendering = false
            case .cpuStamps:
                forceCPU = true
                useSegmentRendering = false
            case .liveMetal:
                forceCPU = false
                useSegmentRendering = true
        }
        
        let renderer = Renderer(canvasSize: geometry.canvasSize,
                                scale: geometry.scale,
                                forceCPU: forceCPU,
                                useSegmentRendering: useSegmentRendering)
        let resultImage = renderer.render(art: art)
        
        if let image = resultImage { return image }
        
        // Ensure the test image matches the intended render resolution
        let pixelWidth = Int(geometry.canvasSize.width * geometry.scale)
        let pixelHeight = Int(geometry.canvasSize.height * geometry.scale)
        return makeTestImage(w: pixelWidth, h: pixelHeight, color: .systemPink)
    }
    
    /// Static fallback after the live view was already handed to Quick Look: render off
    /// the main thread, then swap the content in.
    private func renderStaticPreviewInBackground(art: ArtParser,
                                                 geometry: PreviewGeometry,
                                                 handler: ((Error?) -> Void)?) {
        DispatchQueue.global(qos: .userInitiated).async {
            let image = self.renderStaticImage(art: art, geometry: geometry)
            DispatchQueue.main.async {
                guard let image = image else {
                    NSLog("ArtQuickLook static preview fallback failed")
                    handler?(NSError(domain: "ArtRenderer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create test image"]))
                    return
                }
                self.installStaticPreview(image, geometry: geometry)
                handler?(nil)
            }
        }
    }
    
    private func installStaticPreview(_ cgImageToShow: CGImage, geometry: PreviewGeometry) {
        // 1. Replace NSImageView with a basic NSView
        let imageView = NSView()
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.wantsLayer = true
        
        // 2. Assign the CGImage directly to the layer
        imageView.layer?.contents = cgImageToShow
        
        // 3. .resizeAspect scales the image proportionally to fit the view bounds.
        // It acts exactly like .scaleProportionallyUpOrDown, but at the GPU level.
        imageView.layer?.contentsGravity = .resizeAspect
        imageView.layer?.masksToBounds = true
        
        // 4. Crucial for Retina: Tell the layer how many pixels per point to use
        // so it maps the 2x backing pixels to the 1x logical points perfectly.
        let backingScaleFactor = NSScreen.main?.backingScaleFactor ?? 1.0
        imageView.layer?.contentsScale = backingScaleFactor
        
        replaceContent(with: imageView)
        
        // Tell QuickLook the natural size is 1920x...
        preferredContentSize = geometry.preferredContentSize
    }
    
    /// Replaces the preview content with `content`, filling the whole view.
    private func replaceContent(with content: NSView) {
        self.view.subviews.forEach { $0.removeFromSuperview() }
        // Programmatic views autoresize by default; we drive the frame with constraints.
        content.translatesAutoresizingMaskIntoConstraints = false
        self.view.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
            content.topAnchor.constraint(equalTo: self.view.topAnchor),
            content.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
        ])
    }
    
    func makeTestImage(w: Int, h: Int, color: NSColor = .systemBlue) -> CGImage? {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil,
                                  width: w,
                                  height: h,
                                  bitsPerComponent: 8,
                                  bytesPerRow: w * 4,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // example additional content so it's obvious
        ctx.setFillColor(NSColor.red.cgColor)
        ctx.fillEllipse(in: CGRect(x: 20, y: 20, width: 80, height: 80))
        return ctx.makeImage()
    }
}

/// Everything derived from the shared settings that both preview modes need.
struct PreviewGeometry {
    let renderPath: RenderPath
    /// Art canvas in points (1920 wide, aspect from the main screen).
    let canvasSize: CGSize
    /// Device scale for the static render path.
    let scale: CGFloat
    /// Size Quick Look should give the preview window.
    let preferredContentSize: CGSize

    init(settings: Settings) {
        let plistScale = CGFloat(settings.previewScale)
        self.renderPath = settings.renderPath
        
        // 1. Get the screen's visible dimensions in POINTS (excluding dock/menu bar)
        let screenFrame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let screenWidthPts = screenFrame.width
        let screenHeightPts = screenFrame.height
        
        // 2. Calculate native PIXELS for the renderer so it draws at full Retina density
        let backingScaleFactor = NSScreen.main?.backingScaleFactor ?? 1.0
        let screenWidthPx = screenWidthPts * backingScaleFactor
        let screenHeightPx = screenHeightPts * backingScaleFactor
        
        // 3. Original Renderer math (now safely using native pixels)
        self.scale = screenWidthPx / 1920.0 * plistScale
        let height: CGFloat = (1920.0 / screenWidthPx) * screenHeightPx
        
        self.canvasSize = CGSize(width: 1920, height: height)
        self.preferredContentSize = CGSize(width: canvasSize.width * plistScale,
                                           height: canvasSize.height * plistScale)
    }
}