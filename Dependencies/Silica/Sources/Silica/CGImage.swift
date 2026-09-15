//
//  Image.swift
//  Silica
//
//  Created by Alsey Coleman Miller on 5/11/16.
//  Copyright © 2016 PureSwift. All rights reserved.
//

import struct Foundation.Data
import Foundation
import Cairo

/// Represents bitmap images and bitmap image masks, based on sample data that you supply. 
/// A bitmap (or sampled) image is a rectangular array of pixels, 
/// with each pixel representing a single sample or data point in a source image.
public final class CGImage {

    // MARK: - Properties

    public var width: Int {
        return surface.width
    }

    public var height: Int {
        return surface.height
    }

    /// The cached Cairo surface for this image.
    public let surface: Cairo.Surface.Image

    // MARK: - Initialization

    public init(surface: Cairo.Surface.Image) {
        self.surface = surface
    }

    /// Initializes an image from raw alpha mask data (A8 format).
    /// This method allocates a new Cairo surface and copies the provided data into it.
    /// - Parameters:
    ///   - alphaData: The raw pixel data buffer.
    ///   - width: Width of the image.
    ///   - height: Height of the image.
    ///   - bytesPerRow: Stride of the image data in the source buffer.
    public init?(alphaData: Data, width: Int, height: Int, bytesPerRow: Int) {
        do {
            // 1. Create a new surface. Cairo allocates the memory for this surface.
            let surface = try Cairo.Surface.Image(format: .a8, width: width, height: height)

            // 2. Get the destination stride (Cairo may pad rows for alignment).
            let stride = surface.stride

            // 3. Copy the data into the surface's memory buffer.
            // Returns Bool? because the pointer might be invalid.
            let success = surface.withUnsafeMutableBytes { destPtr in
                // destPtr is UnsafeMutablePointer<UInt8>, guaranteed non-optional here.

                return alphaData.withUnsafeBytes { srcPtr in
                    guard let srcBase = srcPtr.baseAddress else { return false }
                    let src = srcBase.assumingMemoryBound(to: UInt8.self)

                    // Copy row by row to handle potential stride differences
                    // between the source data and the Cairo surface.
                    for y in 0..<height {
                        let srcOffset = y * bytesPerRow
                        let destOffset = y * stride

                        if srcOffset + width <= alphaData.count {
                            // Use update(from:count:) to copy bytes.
                            // This is a Swift standard library method and avoids needing memcpy imports.
                            destPtr.advanced(by: destOffset).update(from: src.advanced(by: srcOffset), count: width)
                        }
                    }
                    return true
                }
            }

            // 4. Check success. withUnsafeMutableBytes returns Optional<Bool>.
            if success == true {
                // Ensure Cairo knows the data was modified externally
                surface.markDirty()
                self.surface = surface
                return
            } else {
                return nil
            }

        } catch {
            // If surface creation or copying fails, return nil.
            return nil
        }
    }
}

extension CGImage {

    public func cropping(to rect: CGRect) -> CGImage? {
        // Snap to whole pixels, then clip to the image bounds (CG semantics).
        let requested = rect.integral
        guard !requested.isEmpty else { return nil }

        let bounds = CGRect(x: 0, y: 0, width: Double(width), height: Double(height))
        let clipped = requested.intersection(bounds)
        guard !clipped.isEmpty else { return nil }

        let cropWidth  = Int(clipped.width)
        let cropHeight = Int(clipped.height)
        guard cropWidth > 0, cropHeight > 0 else { return nil }

        // Bytes per pixel; .a1 is bit-packed and can't be row-copied safely.
        guard let format = surface.format else { return nil }
        let bytesPerPixel: Int
        switch format {
            case .argb32, .rgb24, .rgb30: bytesPerPixel = 4
            case .rgb16565:               bytesPerPixel = 2
            case .a8:                     bytesPerPixel = 1
            default:                      return nil   // .a1 or unknown format
        }

        let sourceStride = surface.stride
        let sourceX = Int(clipped.minX)
        let sourceY = Int(clipped.minY)

        do {
            let croppedSurface = try Cairo.Surface.Image(
                format: format,
                    width: cropWidth,
                    height: cropHeight
            )

            let copied = croppedSurface.withUnsafeMutableBytes { dest -> Bool in
                // Reading through the mutable accessor is fine; we never write to `source`.
                let ok = surface.withUnsafeMutableBytes { src -> Bool in
                    let rowBytes = cropWidth * bytesPerPixel
                    for y in 0..<cropHeight {
                        let srcOffset = (sourceY + y) * sourceStride + sourceX * bytesPerPixel
                        let dstOffset = y * croppedSurface.stride
                        dest.advanced(by: dstOffset)
                        .update(from: src.advanced(by: srcOffset), count: rowBytes)
                    }
                    return true
                }
                return ok ?? false   // inner wrapper returns R? (nil = invalid data pointer)
            }

            guard copied == true else { return nil }

            croppedSurface.markDirty()
            return CGImage(surface: croppedSurface)
        } catch {
            return nil
        }
    }
}
