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
        
        // Calculate the scale based on the main screen width.
        let backingScaleFactor = NSScreen.main?.backingScaleFactor ?? 1.0
        let screenWidth = CGFloat(NSScreen.main?.frame.size.width ?? CGFloat(1920)) * CGFloat(backingScaleFactor)
        let scale: CGFloat = (screenWidth / 1920 * 10).rounded() / 10 // round to circumvent scale crash bug

        // Screen height
        let screenHeight = Double(NSScreen.main?.frame.size.height ?? 1080) * Double(backingScaleFactor)
        let height: Double = Double(1920 / screenWidth) * screenHeight
        
        
        let canvasSize = CGSize(width: screenWidth, height: height)
        let renderer = Renderer(canvasSize: canvasSize, scale: scale, forceCPU: false)
        let resultImage = renderer.render(art: art)
        
        // If renderer returns nil, show a clear diagnostic test image so we still see something
        let cgImageToShow: CGImage
        if let r = resultImage {
            cgImageToShow = r
        } else {
            guard let test = makeTestImage(w: Int(canvasSize.width), h: Int(canvasSize.height), color: .systemPink) else {
                handler(NSError(domain: "ArtRenderer", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to create test image"]))
                return
            }
            cgImageToShow = test
        }
        
        DispatchQueue.main.async {
            self.view.subviews.forEach { $0.removeFromSuperview() }
            
            let image = NSImage(cgImage: cgImageToShow,
                                size: NSSize(width: cgImageToShow.width,
                                             height: cgImageToShow.height))
            
            let iv = NSImageView()
            iv.translatesAutoresizingMaskIntoConstraints = false
            iv.image = image
            iv.imageScaling = .NSScaleProportionally
            iv.wantsLayer = true
            iv.layer?.masksToBounds = true
            
            self.view.addSubview(iv)
            
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: self.view.leadingAnchor),
                iv.trailingAnchor.constraint(equalTo: self.view.trailingAnchor),
                iv.topAnchor.constraint(equalTo: self.view.topAnchor),
                iv.bottomAnchor.constraint(equalTo: self.view.bottomAnchor)
            ])
            
            // preferredContentSize is only a *hint*
            self.preferredContentSize = image.size
            
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


