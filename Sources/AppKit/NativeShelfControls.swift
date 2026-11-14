import AppKit
import SwiftUI

/// Invisible AppKit interaction surface over the existing SwiftUI artwork.
/// The shelf's root routes to these controls without asking SwiftUI to hit-test.
struct NativeShelfAction: NSViewRepresentable {
    let label: String
    var enabled = true
    var menu: (() -> NSMenu)?
    var hover: ((Bool) -> Void)?
    let action: () -> Void

    func makeNSView(context: Context) -> ShelfNativeButton {
        let button = ShelfNativeButton()
        button.setButtonType(.momentaryChange)
        button.isBordered = false
        button.title = ""
        button.focusRingType = .none
        button.target = button
        button.action = #selector(ShelfNativeButton.activate)
        updateNSView(button, context: context)
        return button
    }
    func updateNSView(_ button: ShelfNativeButton, context: Context) {
        button.actionBody = action
        button.hoverBody = hover
        button.menuProvider = menu
        button.isEnabled = enabled && context.environment.isEnabled
        button.toolTip = label
        button.setAccessibilityLabel(label)
        button.identifier = NSUserInterfaceItemIdentifier(label)
    }
    static func dismantleNSView(_ button: ShelfNativeButton, coordinator: ()) {
        button.actionBody = nil
        button.hoverBody = nil
        button.menuProvider = nil
    }
}

final class ShelfNativeButton: NSButton {
    var hoverBody: ((Bool) -> Void)?
    private var hoverArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) { hoverBody?(isEnabled) }
    override func mouseExited(with event: NSEvent) { hoverBody?(false) }

    var actionBody: (() -> Void)?
    var menuProvider: (() -> NSMenu)?
    override var acceptsFirstResponder: Bool { isEnabled }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    @objc func activate() {
        guard isEnabled else { return }
        if let menu = menuProvider?() { menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.maxY), in: self) }
        else { actionBody?() }
    }
    override func draw(_ dirtyRect: NSRect) {
        // SwiftUI draws the face. Draw only native pressed/focus feedback here.
        if isHighlighted {
            NSColor.controlAccentColor.withAlphaComponent(0.12).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: bounds.height / 2, yRadius: bounds.height / 2).fill()
        }
        if window?.firstResponder === self {
            NSColor.controlAccentColor.withAlphaComponent(0.8).setStroke()
            let ring = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
            ring.lineWidth = 1.5
            ring.stroke()
        }
    }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return true }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return true }
}

struct NativeShelfTitle: NSViewRepresentable {
    let rename: () -> Void
    func makeNSView(context: Context) -> ShelfNativeTitleView { let view = ShelfNativeTitleView(); view.rename = rename; return view }
    func updateNSView(_ view: ShelfNativeTitleView, context: Context) { view.rename = rename }
}
final class ShelfNativeTitleView: NSView {
    var rename: (() -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 { rename?() }
        else { window?.performDrag(with: event) }
    }
}

extension View {
    @ViewBuilder
    func nativeShelfAction(_ label: String, enabled: Bool = true, hover: ((Bool) -> Void)? = nil, action: @escaping () -> Void) -> some View {
        if #available(macOS 27, *) {
            accessibilityHidden(true).overlay(NativeShelfAction(label: label, enabled: enabled, hover: hover, action: action))
        } else { onHover { hover?($0 && enabled) } }
    }
    @ViewBuilder
    func nativeShelfMenu(_ label: String, menu: @escaping () -> NSMenu) -> some View {
        if #available(macOS 27, *) {
            accessibilityHidden(true).overlay(NativeShelfAction(label: label, menu: menu, action: {}))
        } else { self }
    }
    @ViewBuilder
    func nativeShelfRename(_ rename: @escaping () -> Void) -> some View {
        if #available(macOS 27, *) { overlay(NativeShelfTitle(rename: rename)) }
        else { self }
    }
}
