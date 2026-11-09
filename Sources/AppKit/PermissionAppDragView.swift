import AppKit
import SwiftUI

struct PermissionAppIcon: NSViewRepresentable {
    func makeNSView(context: Context) -> PermissionAppDragView { PermissionAppDragView() }
    func updateNSView(_ view: PermissionAppDragView, context: Context) {}
}

/// Publish the application bundle itself, not an icon image or a text URL.
final class PermissionAppDragView: NSImageView, NSDraggingSource {
    var onDragEnded: (() -> Void)?
    private var start: NSPoint?
    private var dragLease: (PermissionAppDragView, NSWindow?)?
    var isDragging: Bool { dragLease != nil }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 52, height: 52))
        image = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        imageScaling = .scaleProportionallyUpOrDown
        toolTip = "将 DropPoint 拖入系统设置的应用列表"
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel("DropPoint 应用图标，可拖入输入监控列表")
    }

    required init?(coder: NSCoder) { nil }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { start = event.locationInWindow }
    override func mouseUp(with event: NSEvent) { start = nil }
    override func mouseDragged(with event: NSEvent) {
        guard dragLease == nil, let start,
              hypot(event.locationInWindow.x - start.x, event.locationInWindow.y - start.y) > 4 else { return }
        self.start = nil
        let item = NSDraggingItem(pasteboardWriter: Bundle.main.bundleURL as NSURL)
        item.setDraggingFrame(bounds, contents: image)
        dragLease = (self, window)
        let session = beginDraggingSession(with: [item], event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragLease = nil
        onDragEnded?()
    }
}
