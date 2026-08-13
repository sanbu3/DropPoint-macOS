import SwiftUI

struct CompactFileShelfView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let store: ShelfStore
    let palette: ShelfPalette

    private var pullProgress: CGFloat {
        min(max(store.dismissGestureProgress, 0), 1)
    }

    private var fadeProgress: CGFloat {
        min(max((pullProgress - 0.66) / 0.34, 0), 1)
    }

    var body: some View {
        ZStack {
            fileStack
                .frame(width: 92, height: 94)
                .position(x: 99, y: 95)
                .offset(y: 55 * pullProgress)
                .scaleEffect(1 - 0.14 * fadeProgress, anchor: .bottom)
                .opacity(store.isDraggingOut ? 0 : 1 - fadeProgress)

            itemChip
                .position(x: 99, y: 173)
                .opacity(1 - min(max((pullProgress - 0.82) / 0.18, 0), 1))
        }
        .allowsHitTesting(!store.isDismissGestureActive && !store.isPullClearing)
        .animation(
            reduceMotion || store.isDismissGestureActive
                ? nil
                : .smooth(duration: 0.18),
            value: pullProgress
        )
    }

    private var fileStack: some View {
        ZStack {
            ForEach(Array(store.visibleItems.enumerated()).reversed(), id: \.element.id) { index, item in
                Image(nsImage: item.image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 76, height: 76)
                    .clipShape(.rect(cornerRadius: item.isThumbnail ? 11 : 0))
                    .shadow(color: .black.opacity(0.18), radius: 3, y: 3)
                    .rotationEffect(.degrees(index == 1 ? -7 : (index == 2 ? 7 : 0)), anchor: .bottom)
                    .offset(x: index == 1 ? -9 : (index == 2 ? 9 : 0), y: index == 0 ? 0 : (index == 1 ? 2 : 3))
                    .zIndex(Double(3 - index))
                    .allowsHitTesting(false)
            }
        }
        .frame(width: 92, height: 94)
        .contentShape(Rectangle())
    }

    private var itemChip: some View {
        Button {
            store.toggleExpanded()
        } label: {
            HStack(spacing: 2) {
                if store.items.count == 1 {
                    MarqueeFileName(text: store.summary, width: 81)
                } else {
                    Text(store.summary)
                        .lineLimit(1)
                }
                if store.items.count > 1 {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                }
            }
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .foregroundStyle(palette.ink)
            .padding(.horizontal, 10)
            .frame(minWidth: store.items.count > 1 ? 47 : nil, minHeight: 28, maxHeight: 28)
            .fixedSize(horizontal: true, vertical: false)
            .background(palette.control, in: Capsule())
            .overlay(Capsule().stroke(palette.edge, lineWidth: 1))
            .shadow(color: .white.opacity(0.22), radius: 0, y: 1)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .disabled(store.items.count <= 1)
        .help(store.summary)
    }
}

private struct MarqueeFileName: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let text: String
    let width: CGFloat

    @State private var textWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var animationTask: Task<Void, Never>?

    var body: some View {
        Text(text)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .background {
                GeometryReader { proxy in
                    Color.clear.preference(key: MarqueeWidthKey.self, value: proxy.size.width)
                }
            }
            .offset(x: offset)
            .frame(width: width, alignment: .leading)
            .clipped()
            .onPreferenceChange(MarqueeWidthKey.self) { measuredWidth in
                textWidth = measuredWidth
                restartAnimation()
            }
            .onChange(of: text) { restartAnimation() }
            .onChange(of: reduceMotion) { restartAnimation() }
            .onDisappear { animationTask?.cancel() }
            .accessibilityLabel(text)
    }

    private func restartAnimation() {
        animationTask?.cancel()
        offset = 0
        let travel = max(0, textWidth - width)
        guard travel > 2, !reduceMotion else { return }
        animationTask = Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(850))
            } catch { return }
            guard !Task.isCancelled else { return }
            withAnimation(
                .linear(duration: max(2.4, Double(travel / 24)))
                .repeatForever(autoreverses: true)
            ) {
                offset = -travel
            }
        }
    }
}

private struct MarqueeWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
