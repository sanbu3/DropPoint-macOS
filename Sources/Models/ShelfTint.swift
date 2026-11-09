import AppKit
import SwiftUI

/// Colour identity for a shelf. Pinned shelves keep their tint so they stay
/// recognisable in the menu bar and the DropPoint window.
enum ShelfTint: String, Codable, CaseIterable, Identifiable, Sendable {
    case blue
    case purple
    case pink
    case orange
    case green
    case graphite

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue: "蓝色"
        case .purple: "紫色"
        case .pink: "粉色"
        case .orange: "橙色"
        case .green: "绿色"
        case .graphite: "石墨"
        }
    }

    func color(dark: Bool) -> Color {
        let components = components(dark: dark)
        return Color(
            red: components.red / 255,
            green: components.green / 255,
            blue: components.blue / 255
        )
    }

    var nsColor: NSColor {
        let components = components(dark: false)
        return NSColor(
            srgbRed: components.red / 255,
            green: components.green / 255,
            blue: components.blue / 255,
            alpha: 1
        )
    }

    private func components(dark: Bool) -> (red: Double, green: Double, blue: Double) {
        switch (self, dark) {
        case (.blue, false): (48, 112, 207)
        case (.blue, true): (113, 169, 255)
        case (.purple, false): (122, 90, 248)
        case (.purple, true): (168, 140, 255)
        case (.pink, false): (209, 67, 130)
        case (.pink, true): (255, 143, 184)
        case (.orange, false): (196, 113, 22)
        case (.orange, true): (255, 179, 92)
        case (.green, false): (39, 138, 83)
        case (.green, true): (107, 213, 154)
        case (.graphite, false): (96, 105, 120)
        case (.graphite, true): (179, 185, 196)
        }
    }
}

extension ShelfTint {
    static let fallbackName = "文件架"
}
