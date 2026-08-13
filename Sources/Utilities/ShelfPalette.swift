import SwiftUI

struct ShelfPalette {
    let dark: Bool

    var surface: Color { dark ? color(38, 40, 44, 0.96) : color(230, 230, 230, 0.96) }
    var activeSurface: Color { dark ? color(46, 49, 55, 0.98) : color(238, 238, 238, 0.98) }
    var ink: Color { dark ? color(242, 244, 247) : color(54, 54, 54) }
    var muted: Color { dark ? color(176, 181, 189) : color(116, 116, 122) }
    var control: Color { dark ? .white.opacity(0.09) : .black.opacity(0.07) }
    var controlHover: Color { dark ? .white.opacity(0.14) : .black.opacity(0.105) }
    var edge: Color { dark ? .white.opacity(0.13) : .black.opacity(0.10) }
    var highlight: Color { dark ? .white.opacity(0.12) : .white.opacity(0.68) }
    var handle: Color { dark ? color(118, 123, 131) : color(167, 167, 167) }
    var selected: Color { dark ? .white.opacity(0.08) : .white.opacity(0.28) }
    var selectedEdge: Color { dark ? .white.opacity(0.09) : .black.opacity(0.07) }
    var fileType: Color { dark ? color(174, 179, 187) : color(112, 112, 118) }
    var action: Color { dark ? .white.opacity(0.07) : .white.opacity(0.24) }
    var divider: Color { dark ? .white.opacity(0.09) : .black.opacity(0.075) }
    var inspector: Color { dark ? .black.opacity(0.10) : .white.opacity(0.18) }
    var accent: Color { dark ? color(113, 169, 255) : color(48, 112, 207) }
    var accentSurface: Color { dark ? color(75, 130, 218, 0.20) : color(48, 112, 207, 0.11) }
    var accentEdge: Color { dark ? color(113, 169, 255, 0.32) : color(48, 112, 207, 0.24) }
    var danger: Color { dark ? color(255, 138, 132) : color(180, 71, 67) }
    var focusRing: Color { dark ? color(120, 169, 245, 0.45) : color(56, 117, 205, 0.25) }

    private func color(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> Color {
        Color(red: red / 255, green: green / 255, blue: blue / 255, opacity: alpha)
    }
}
