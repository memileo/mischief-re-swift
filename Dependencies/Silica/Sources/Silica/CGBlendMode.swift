#if os(macOS)
import Darwin.C.math
#elseif os(Linux)
import Glibc
#endif

import Cairo
import CCairo
import Foundation

public enum CGBlendMode {
    case normal
    case multiply
    case screen
    case overlay
    case darken
    case lighten
    case colorDodge
    case colorBurn
    case softLight
    case hardLight
    case difference
    case exclusion
    case hue
    case saturation
    case color
    case luminosity
    case clear
    case copy
    case sourceIn
    case sourceOut
    case sourceAtop
    case destinationOver
    case destinationIn
    case destinationOut
    case destinationAtop
    case xor
    case plusDarker
    case plusLighter
}

extension CGContext {

    public func setBlendMode(_ mode: CGBlendMode) {
        let op: cairo_operator_t
        switch mode {
        case .clear:            op = CAIRO_OPERATOR_CLEAR
        case .copy:             op = CAIRO_OPERATOR_SOURCE
        case .normal:           op = CAIRO_OPERATOR_OVER
        case .sourceIn:         op = CAIRO_OPERATOR_IN
        case .sourceOut:        op = CAIRO_OPERATOR_OUT
        case .sourceAtop:       op = CAIRO_OPERATOR_ATOP
        case .destinationOver:  op = CAIRO_OPERATOR_DEST_OVER
        case .destinationIn:    op = CAIRO_OPERATOR_DEST_IN
        case .destinationOut:   op = CAIRO_OPERATOR_DEST_OUT
        case .destinationAtop:  op = CAIRO_OPERATOR_DEST_ATOP
        case .xor:              op = CAIRO_OPERATOR_XOR
        case .multiply:         op = CAIRO_OPERATOR_MULTIPLY
        case .screen:           op = CAIRO_OPERATOR_SCREEN
        case .overlay:          op = CAIRO_OPERATOR_OVERLAY
        case .darken:           op = CAIRO_OPERATOR_DARKEN
        case .lighten:          op = CAIRO_OPERATOR_LIGHTEN
        case .colorDodge:       op = CAIRO_OPERATOR_COLOR_DODGE
        case .colorBurn:        op = CAIRO_OPERATOR_COLOR_BURN
        case .hardLight:        op = CAIRO_OPERATOR_HARD_LIGHT
        case .softLight:        op = CAIRO_OPERATOR_SOFT_LIGHT
        case .difference:       op = CAIRO_OPERATOR_DIFFERENCE
        case .exclusion:        op = CAIRO_OPERATOR_EXCLUSION
        case .hue:              op = CAIRO_OPERATOR_HSL_HUE
        case .saturation:       op = CAIRO_OPERATOR_HSL_SATURATION
        case .color:            op = CAIRO_OPERATOR_HSL_COLOR
        case .luminosity:       op = CAIRO_OPERATOR_HSL_LUMINOSITY
        case .plusDarker:       op = CAIRO_OPERATOR_DARKEN   // no direct Cairo equivalent; approximate
        case .plusLighter:      op = CAIRO_OPERATOR_ADD
        }
        internalContext.operator = op
    }
}
