import Cocoa
import QuickLookUI
import UniformTypeIdentifiers
import ArtParser
import Metal
import os.log

class PreviewViewController: NSViewController, QLPreviewingController {
//    @IBOutlet var imageView: NSImageView!
    
    private let logger = Logger(subsystem: "org.potato.ArtQuickLook", category: "Preview")
    
    func preparePreviewOfFile(at url: URL, completionHandler handler: @escaping (Error?) -> Void) {
        logger.log("Previewing file: \(url.path)")
        
        // Read and parse the art file
        guard let data = try? Data(contentsOf: url) else {
            logger.error("Failed to read art file")
            handler(NSError(domain: "ArtParser", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to read art file"]))
            return
        }
        
        let artBytes = [UInt8](data)
        logger.log("Read \(artBytes.count) bytes from file")
        
        guard let art = ArtParser(data: artBytes) else {
            logger.error("Failed to parse art file")
            handler(NSError(domain: "ArtParser", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to parse art file"]))
            return
        }
        
        logger.log("Successfully parsed art file")
        
        // Create Metal renderer
        let canvasSize = CGSize(width: 1920, height: 1080)
        let renderer = Renderer(canvasSize: canvasSize, scale: 1.0)
        
        // Render the art
        guard let image = renderer.render(art: art) else {
            logger.error("Failed to render art")
            handler(NSError(domain: "ArtRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to render art"]))
            return
        }
        
        logger.log("Successfully rendered art")
        
        // Update the image view on the main thread
        DispatchQueue.main.async {
            let nsImage = NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
            self.imageView.image = nsImage
            handler(nil)
        }
    }
}
