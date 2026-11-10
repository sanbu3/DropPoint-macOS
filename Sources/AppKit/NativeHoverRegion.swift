import AppKit
import SwiftUI

/// Native tracking avoids the SwiftUI HoverEventDispatcher path implicated in
/// macOS 27 crash reports, while retaining hover styling for custom controls.
struct NativeHoverRegion: NSViewRepresentable {
    let onChange: (Bool) -> Void
    func makeNSView(context: Context) -> NativeHoverTrackingView {
        let view = NativeHoverTrackingView()
        view.onChange = onChange
        return view
    }
    func updateNSView(_ view: NativeHoverTrackingView, context: Context) { view.onChange = onChange }
    static func dismantleNSView(_ view: NativeHoverTrackingView, coordinator: ()) { view.onChange = nil }
}

final class NativeHoverTrackingView: NSView {
    var onChange: ((Bool) -> Void)?
    private var area: NSTrackingArea?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let next = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(next)
        area = next
    }
    override func mouseEntered(with event: NSEvent) { onChange?(true) }
    override func mouseExited(with event: NSEvent) { onChange?(false) }
}
