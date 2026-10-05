import SwiftUI

/// An instruction bubble outside the file surface, pointing back to the shelf.
struct OptionClearHintView: View {
    @Environment(\.colorScheme) private var colorScheme
    let attachedAbove: Bool

    private var palette: ShelfPalette { ShelfPalette(dark: colorScheme == .dark, focused: true) }

    var body: some View {
        let bubble = ShelfHintBubble(attachedAbove: attachedAbove)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("继续按住 ⌥")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(palette.ink)
                Spacer(minLength: 0)
                Text("1.2 秒")
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .foregroundStyle(palette.danger)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(palette.danger.opacity(0.10), in: Capsule())
            }
            Text("松开取消 · 清空后保留文件架")
                .font(.system(size: 10))
                .foregroundStyle(palette.muted)
                .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(attachedAbove ? .bottom : .top, ShelfHintBubble.tailHeight)
        .background {
            bubble.fill(.ultraThinMaterial)
                .overlay {
                    bubble.fill(LinearGradient(
                        colors: [.white.opacity(colorScheme == .dark ? 0.06 : 0.36), palette.accent.opacity(0.04)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                }
                .overlay(bubble.stroke(palette.highlight, lineWidth: 1))
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("继续按住 Option，满一点二秒清空内容并保留文件架。松开取消。")
        .allowsHitTesting(false)
    }
}

private struct ShelfHintBubble: Shape {
    static let tailHeight: CGFloat = 9
    let attachedAbove: Bool

    func path(in rect: CGRect) -> Path {
        let top = rect.minY + (attachedAbove ? 0 : Self.tailHeight)
        let bottom = rect.maxY - (attachedAbove ? Self.tailHeight : 0)
        let radius = min(18, (bottom - top) / 2, rect.width / 2)
        let center = rect.midX
        var path = Path()
        path.move(to: CGPoint(x: rect.minX + radius, y: top))
        if !attachedAbove {
            path.addLine(to: CGPoint(x: center - 9, y: top))
            path.addLine(to: CGPoint(x: center - 2, y: rect.minY + 2))
            path.addQuadCurve(to: CGPoint(x: center + 2, y: rect.minY + 2), control: CGPoint(x: center, y: rect.minY))
            path.addLine(to: CGPoint(x: center + 9, y: top))
        }
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: top))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: top + radius), control: CGPoint(x: rect.maxX, y: top))
        path.addLine(to: CGPoint(x: rect.maxX, y: bottom - radius))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - radius, y: bottom), control: CGPoint(x: rect.maxX, y: bottom))
        if attachedAbove {
            path.addLine(to: CGPoint(x: center + 9, y: bottom))
            path.addLine(to: CGPoint(x: center + 2, y: rect.maxY - 2))
            path.addQuadCurve(to: CGPoint(x: center - 2, y: rect.maxY - 2), control: CGPoint(x: center, y: rect.maxY))
            path.addLine(to: CGPoint(x: center - 9, y: bottom))
        }
        path.addLine(to: CGPoint(x: rect.minX + radius, y: bottom))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: bottom - radius), control: CGPoint(x: rect.minX, y: bottom))
        path.addLine(to: CGPoint(x: rect.minX, y: top + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: top), control: CGPoint(x: rect.minX, y: top))
        path.closeSubpath()
        return path
    }
}
