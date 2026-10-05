import SwiftUI

struct ShelfPalette {
    let dark: Bool
    var focused = false

    var surface: Color { dark ? color(38, 40, 44, 0.96) : color(230, 230, 230, 0.96) }
    var activeSurface: Color { dark ? color(46, 49, 55, 0.98) : color(246, 246, 247, 0.98) }
    var focusedSurface: Color {
        dark ? color(22, 25, 30, 0.34) : color(255, 255, 255, 0.46)
    }
    var ink: Color {
        dark ? color(246, 247, 249) : color(focused ? 30 : 54, focused ? 30 : 54, focused ? 32 : 54)
    }
    var muted: Color {
        dark ? color(190, 195, 203) : color(focused ? 91 : 116, focused ? 91 : 116, focused ? 97 : 122)
    }
    var control: Color { dark ? .white.opacity(focused ? 0.13 : 0.09) : .black.opacity(focused ? 0.095 : 0.07) }
    var controlHover: Color { dark ? .white.opacity(0.14) : .black.opacity(0.105) }
    var edge: Color { dark ? .white.opacity(focused ? 0.2 : 0.13) : .black.opacity(focused ? 0.16 : 0.10) }
    var highlight: Color { dark ? .white.opacity(focused ? 0.22 : 0.12) : .white.opacity(focused ? 0.94 : 0.68) }
    var handle: Color { dark ? color(132, 137, 146) : color(focused ? 112 : 167, focused ? 112 : 167, focused ? 116 : 167) }
    var activeHandle: Color { dark ? ink.opacity(0.65) : (focused ? color(88, 143, 205) : handle) }
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

    private func color(_ red: Double, _ green: Double, _ blue: Double, _ alpha: Double = 1) -> Color {
        Color(red: red / 255, green: green / 255, blue: blue / 255, opacity: alpha)
    }
}
