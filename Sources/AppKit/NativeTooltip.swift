import AppKit
import SwiftUI

/// macOS 27's SwiftUI TooltipBridge can dereference a stale responder when a
/// shelf becomes key. A native tooltip has no SwiftUI responder lookup.
struct NativeTooltip: NSViewRepresentable {
    let text: String
    func makeNSView(context: Context) -> NativeTooltipView {
        let view = NativeTooltipView()
        view.toolTip = text
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: NativeTooltipView, context: Context) {
        if view.toolTip != text { view.toolTip = text }
    }
    static func dismantleNSView(_ view: NativeTooltipView, coordinator: ()) { view.toolTip = nil }
}

final class NativeTooltipView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

extension View {
    @ViewBuilder
    func dropPointHelp(_ text: String) -> some View {
        if #available(macOS 27, *) {
            background(NativeTooltip(text: text).allowsHitTesting(false))
                .accessibilityHint(Text(text))
        } else {
            help(text)
        }
    }
}
