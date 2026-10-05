import SwiftUI

/// A short instruction tab attached to the handle, outside the file surface.
struct OptionClearHintView: View {
    @Environment(\.colorScheme) private var colorScheme
    let attachedAbove: Bool

    private var palette: ShelfPalette { ShelfPalette(dark: colorScheme == .dark, focused: true) }

    var body: some View {
        VStack(spacing: 0) {
            if !attachedAbove { connector }
            HStack(spacing: 8) {
                Text("⌥")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 26, height: 28)
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(palette.danger.opacity(0.4)))
                VStack(alignment: .leading, spacing: 3) {
                    Text("继续按住 · 1.2 秒清空")
                        .font(.system(size: 11, weight: .semibold))
                    Text("松开取消 · 保留文件架")
                        .font(.system(size: 10))
                        .foregroundStyle(palette.ink.opacity(0.72))
                }
            }
            .foregroundStyle(palette.danger)
            .padding(.horizontal, 9)
            .frame(height: 46)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(palette.highlight))
            .padding(.horizontal, 4)
            if attachedAbove { connector }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: attachedAbove ? .bottom : .top)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("继续按住 Option，满一点二秒清空内容并保留文件架。松开取消。")
        .allowsHitTesting(false)
    }

    private var connector: some View {
        Rectangle()
            .fill(palette.danger.opacity(0.45))
            .frame(width: 1, height: 10)
    }
}
