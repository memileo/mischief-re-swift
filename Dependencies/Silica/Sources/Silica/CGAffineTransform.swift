//
//  AffineTransform.swift
//  Silica
//
//  Created by Alsey Coleman Miller on 5/8/16.
//  Copyright © 2016 PureSwift. All rights reserved.
//

import Cairo
import CCairo
import Foundation

#if os(macOS)

import struct CoreGraphics.CGAffineTransform
public typealias CGAffineTransform = CoreGraphics.CGAffineTransform

#else

/// Affine Transform
public struct CGAffineTransform: Equatable {
    
    // MARK: - Properties
    
    public var a, b, c, d, tx, ty: CGFloat
    
    // MARK: - Initialization
    
    public init(a: CGFloat, b: CGFloat, c: CGFloat, d: CGFloat, tx: CGFloat, ty: CGFloat) {
        
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }
}


#endif

public extension CGAffineTransform {

    static var identity: CGAffineTransform { CGAffineTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0) }

    func inverted() -> CGAffineTransform {
        let determinant = a * d - b * c

        // CoreGraphics treats near-singular transforms as non-invertible
        // and returns the all-zero transform.
        if abs(determinant) < .ulpOfOne {
            return CGAffineTransform(a: 0, b: 0, c: 0, d: 0, tx: 0, ty: 0)
        }

        let factor = 1.0 / determinant

        return CGAffineTransform(
            a:  d * factor,
            b: -b * factor,
            c: -c * factor,
            d:  a * factor,
            tx: (c * ty - d * tx) * factor,
            ty: (b * tx - a * ty) * factor
        )
    }

    /// Returns an affine transformation matrix constructed by combining two existing affine transforms.
    /// The result represents the operation of the current transform followed by the specified transform (t2).
    func concatenating(_ t2: CGAffineTransform) -> CGAffineTransform {
        return CGAffineTransform(
            // Row 1, Column 1 & 2 (Rotation/Scaling)
            a:  self.a * t2.a + self.b * t2.c,
            b:  self.a * t2.b + self.b * t2.d,

            // Row 2, Column 1 & 2 (Rotation/Scaling)
            c:  self.c * t2.a + self.d * t2.c,
            d:  self.c * t2.b + self.d * t2.d,

            // Row 3, Column 1 & 2 (Translation tx, ty)
            tx: self.tx * t2.a + self.ty * t2.c + t2.tx,
            ty: self.tx * t2.b + self.ty * t2.d + t2.ty
        )
    }
}
    
// MARK: - Geometry Math

// Immutable math

public protocol CGAffineTransformMath {
    
    func applying(_ transform: CGAffineTransform) -> Self
}

// Mutable versions

public extension CGAffineTransformMath {
    
    @inline(__always)
    mutating func apply(_ transform: CGAffineTransform) {
        
        self = self.applying(transform)
    }
}

// Implementations

extension CGPoint: CGAffineTransformMath {
    
    @inline(__always)
    public func applying(_ t: CGAffineTransform) -> CGPoint {
        
        return CGPoint(x: t.a * x + t.c * y + t.tx,
                       y: t.b * x + t.d * y + t.ty)
    }
}

extension CGSize: CGAffineTransformMath {
    
    @inline(__always)
    public func applying( _ transform: CGAffineTransform) -> CGSize  {
        
        var newSize = CGSize(width:  transform.a * width + transform.c * height,
                             height: transform.b * width + transform.d * height)
        
        if newSize.width < 0 { newSize.width = -newSize.width }
        if newSize.height < 0 { newSize.height = -newSize.height }
        
        return newSize
    }
}

// MARK: - Cairo Conversion

extension CGAffineTransform: CairoConvertible {
    
    public typealias CairoType = Cairo.Matrix
    
    @inline(__always)
    public init(cairo matrix: CairoType) {
        
        self.init(a: CGFloat(matrix.xx),
                  b: CGFloat(matrix.xy),
                  c: CGFloat(matrix.yx),
                  d: CGFloat(matrix.yy),
                  tx: CGFloat(matrix.x0),
                  ty: CGFloat(matrix.y0))
    }
    
    @inline(__always)
    public func toCairo() -> CairoType {
        
        var matrix = Matrix()
        
        matrix.xx = Double(a)
        matrix.xy = Double(b)
        matrix.yx = Double(c)
        matrix.yy = Double(d)
        matrix.x0 = Double(tx)
        matrix.y0 = Double(ty)
        
        return matrix
    }
}

