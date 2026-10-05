import SwiftUI

private struct ShelfFocusRingModifier<S: Shape>: ViewModifier {
    @Environment(\.controlActiveState) private var controlActiveState

    let shape: S
    let color: Color
    let showsFocus: Bool

    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .focusable()
            .focused($isFocused)
            .focusEffectDisabled()
            .overlay {
                shape
                    .stroke(
                        color.opacity(showsFocus && isFocused && controlActiveState == .key ? 0.9 : 0),
                        lineWidth: 2
                    )
                    .padding(-2)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func shelfFocusRing<S: Shape>(_ shape: S, color: Color, showsFocus: Bool = true) -> some View {
        modifier(ShelfFocusRingModifier(shape: shape, color: color, showsFocus: showsFocus))
    }
}
