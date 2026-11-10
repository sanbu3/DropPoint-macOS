import AppKit
import SwiftUI

/// On macOS 27 the renderer never participates in mouse routing. A plain
/// AppKit container owns that boundary, including AppKit's context hit tests.
final class ShelfRenderingView: NSHostingView<AnyView> {
    override var acceptsFirstResponder: Bool {
        if #available(macOS 27, *) { false } else { super.acceptsFirstResponder }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        if #available(macOS 27, *) { nil } else { super.hitTest(point) }
    }
    override func mouseMoved(with event: NSEvent) { if #unavailable(macOS 27) { super.mouseMoved(with: event) } }
    override func mouseEntered(with event: NSEvent) { if #unavailable(macOS 27) { super.mouseEntered(with: event) } }
    override func mouseExited(with event: NSEvent) { if #unavailable(macOS 27) { super.mouseExited(with: event) } }
}
