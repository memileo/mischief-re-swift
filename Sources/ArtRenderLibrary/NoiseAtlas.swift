import Metal
import CoreGraphics

/// Helper class for creating and managing noise atlas textures
class NoiseAtlas {
    // MARK: - Properties
    
    private let device: MTLDevice?
    private var noiseTexture: MTLTexture?
    
    // MARK: - Initialization
    
    init(device: MTLDevice?) {
        self.device = device
    }
    
    // MARK: - Public API
    
    /// Create noise atlas from CGImage
    func createNoiseAtlas(from image: CGImage) throws -> MTLTexture? {
        guard let device = device else {
            throw NoiseAtlasError.deviceNotAvailable
        }
        
        guard let texture = MetalRenderer.createTexture(from: image, device: device) else {
            throw NoiseAtlasError.textureCreationFailed
        }
        
        self.noiseTexture = texture
        return texture
    }
    
    /// Get the current noise texture
    func getNoiseTexture() -> MTLTexture? {
        return noiseTexture
    }
    
    /// Create a procedural noise texture (fallback if no image provided)
    func createProceduralNoise(width: Int = 256, height: Int = 256) throws -> MTLTexture? {
        guard let device = device else {
            throw NoiseAtlasError.deviceNotAvailable
        }
        
        // r8 texture -> 1 byte per pixel
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = [.shaderRead]
        textureDescriptor.storageMode = .shared
        
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            throw NoiseAtlasError.textureCreationFailed
        }
        
        // Generate procedural noise data (0..255)
        var noiseData = [UInt8](repeating: 0, count: width * height)
        
        for y in 0..<height {
            for x in 0..<width {
                // Simple Perlin-like noise
                let value = generateNoiseValue(x: x, y: y, width: width, height: height)
                
                // clamp & convert to byte
                let clamped = max(0.0, min(1.0, value))
                noiseData[y * width + x] = UInt8(round(clamped * 255.0))
            }
        }
        
        // Copy to texture. bytesPerRow for r8 is width * 1
        let bytesPerRow = width
        let region = MTLRegionMake2D(0, 0, width, height)
        texture.replace(region: region, mipmapLevel: 0, withBytes: noiseData, bytesPerRow: bytesPerRow)
        
        self.noiseTexture = texture
        return texture
    }
    
    // MARK: - Private Methods
    
    /// Generate a simple noise value
    private func generateNoiseValue(x: Int, y: Int, width: Int, height: Int) -> Float {
        let nx = Float(x) / Float(width)
        let ny = Float(y) / Float(height)
        
        // Simple fractional Brownian motion
        var value: Float = 0.0
        var amplitude: Float = 1.0
        var frequency: Float = 1.0
        
        for _ in 0..<4 {  // 4 octaves
            value += amplitude * noise2D(x: nx * frequency, y: ny * frequency)
            amplitude *= 0.5
            frequency *= 2.0
        }
        
        // Normalize to [0, 1] assuming noise2D returns approx in [-1,1]
        return (value + 1.0) * 0.5
    }
    
    /// Simple 2D noise function
    private func noise2D(x: Float, y: Float) -> Float {
        let i = Int(floor(x)) & 255
        let j = Int(floor(y)) & 255
        
        let u = fade(x - floor(x))
        let v = fade(y - floor(y))
        
        let a = grad(hash(i, j), x - floor(x), y - floor(y))
        let b = grad(hash(i + 1, j), x - floor(x) - 1, y - floor(y))
        let c = grad(hash(i, j + 1), x - floor(x), y - floor(y) - 1)
        let d = grad(hash(i + 1, j + 1), x - floor(x) - 1, y - floor(y) - 1)
        
        return lerp(lerp(a, b, u), lerp(c, d, u), v)
    }
    
    // MARK: - Noise Helper Functions (unchanged)
    private func fade(_ t: Float) -> Float {
        return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)
    }
    
    private func lerp(_ a: Float, _ b: Float, _ t: Float) -> Float {
        return a + t * (b - a)
    }
    
    private func grad(_ hash: Int, _ x: Float, _ y: Float) -> Float {
        let h = hash & 15
        let u = h < 8 ? x : y
        let v = h < 4 ? y : (h == 12 || h == 14 ? x : 0)
        return ((h & 1) == 0 ? u : -u) + ((h & 2) == 0 ? v : -v)
    }
    
    private func hash(_ x: Int, _ y: Int) -> Int {
        return permutations[(permutations[x & 255] + y) & 255]
    }
    
    // Simple permutation table for noise
    private let permutations: [Int] = [
        151, 160, 137, 91, 90, 15, 131, 13, 201, 95, 96, 53, 194, 233, 7, 225, 140, 36, 103, 30, 69, 142,
        8, 99, 37, 240, 21, 10, 23, 190, 6, 148, 247, 120, 234, 75, 0, 26, 197, 62, 94, 252, 219, 203, 117,
        35, 11, 32, 57, 177, 33, 88, 237, 149, 56, 87, 174, 20, 125, 136, 171, 168, 68, 175, 74, 165, 71, 134,
        139, 48, 27, 166, 77, 146, 158, 231, 83, 111, 229, 122, 60, 211, 133, 230, 220, 105, 92, 41, 55, 46, 245,
        40, 244, 102, 143, 54, 65, 25, 63, 161, 1, 216, 80, 73, 209, 76, 132, 187, 208, 89, 18, 169, 200, 196,
        135, 130, 116, 188, 159, 86, 164, 100, 109, 198, 173, 186, 3, 64, 52, 217, 226, 250, 124, 123, 5, 202, 38,
        147, 118, 126, 255, 82, 85, 212, 207, 206, 59, 227, 47, 16, 58, 17, 182, 189, 28, 42, 223, 183, 170, 213,
        119, 248, 152, 2, 44, 154, 163, 70, 221, 153, 101, 155, 167, 43, 172, 9, 129, 22, 39, 253, 19, 98, 108,
        110, 79, 113, 224, 232, 178, 185, 112, 104, 218, 246, 97, 228, 251, 34, 242, 193, 238, 210, 144, 12, 191,
        179, 162, 241, 81, 51, 145, 235, 249, 14, 239, 107, 49, 192, 214, 31, 181, 199, 106, 157, 184, 84, 204,
        176, 115, 121, 50, 45, 127, 4, 150, 254, 138, 236, 205, 93, 222, 114, 67, 29, 24, 72, 243, 141, 128, 195,
        78, 66, 215, 61, 156, 180
    ]
}

// MARK: - Error Types

enum NoiseAtlasError: Error, LocalizedError {
    case deviceNotAvailable
    case textureCreationFailed
    case imageProcessingFailed
    
    var errorDescription: String? {
        switch self {
        case .deviceNotAvailable:
            return "Metal device not available"
        case .textureCreationFailed:
            return "Failed to create noise texture"
        case .imageProcessingFailed:
            return "Failed to process noise image"
        }
    }
}
