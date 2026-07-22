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
        
        // 1. Get the screen's visible dimensions in POINTS (excluding dock/menu bar)
        let screenFrame = NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let screenWidthPts = screenFrame.width
        let screenHeightPts = screenFrame.height
        
    
        // 2. Calculate native PIXELS for the renderer so it draws at full Retina density
        let backingScaleFactor = NSScreen.main?.backingScaleFactor ?? 1.0
        let screenWidthPx = screenWidthPts * backingScaleFactor
        let screenHeightPx = screenHeightPts * backingScaleFactor
        
        // 3. Original Renderer math (now safely using native pixels)
        let scale: CGFloat = (screenWidthPx / 1920.0 * 10).rounded() / 10
        let height: CGFloat = (1920.0 / screenWidthPx) * screenHeightPx
        
        let canvasSize = CGSize(width: 1920, height: height)
        let renderer = Renderer(canvasSize: canvasSize, scale: scale, forceCPU: false)
        let resultImage = renderer.render(art: art)
        
        let cgImageToShow: CGImage
        if let r = resultImage {
            cgImageToShow = r
        } else {
            // Ensure the test image matches the intended render resolution
            let pixelWidth = Int(canvasSize.width * scale)
            let pixelHeight = Int(canvasSize.height * scale)
            guard let test = makeTestImage(w: pixelWidth, h: pixelHeight, color: .systemPink) else {
                handler(NSError(domain: "ArtRenderer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create test image"]))
                return
            }
            cgImageToShow = test
        }
        
        DispatchQueue.main.async {
            self.view.subviews.forEach { $0.removeFromSuperview() }
            
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
            
            self.view.addSubview(imageView)
            
            NSLayoutConstraint.activate([
                imageView.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                imageView.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
                imageView.topAnchor.constraint(equalTo: self.view.topAnchor),
                imageView.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
            ])
            
            // Tell QuickLook the natural size is 1920x...
            self.preferredContentSize = canvasSize
            
            handler(nil)
        }
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
        // example additional content so it’s obvious
        ctx.setFillColor(NSColor.red.cgColor)
        ctx.fillEllipse(in: CGRect(x: 20, y: 20, width: 80, height: 80))
        return ctx.makeImage()
    }

}


