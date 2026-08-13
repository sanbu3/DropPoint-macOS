import AppKit
import SwiftUI

struct FileDragSourceView: NSViewRepresentable {
    let items: [ShelfItem]
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: ((Bool, Bool) -> Void)?

    func makeNSView(context: Context) -> DragSourceNSView {
        let view = DragSourceNSView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: DragSourceNSView, context: Context) {
        update(nsView)
    }

    private func update(_ view: DragSourceNSView) {
        view.items = items
        view.onClick = onClick
        view.onDragBegan = onDragBegan
        view.onDragEnded = onDragEnded
    }
}

final class DragSourceNSView: NSView, NSDraggingSource {
    var items: [ShelfItem] = []
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: ((Bool, Bool) -> Void)?

    private var mouseDownEvent: NSEvent?
    private var startedDrag = false
    private var keepOpen = false

    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        startedDrag = false
        keepOpen = event.modifierFlags.contains(.shift)
        onClick?(event.modifierFlags)
    }

    override func mouseDragged(with event: NSEvent) {
        guard !startedDrag, !items.isEmpty else { return }
        startedDrag = true
        onDragBegan?()

        let point = convert(event.locationInWindow, from: nil)
        let draggingItems = items.enumerated().map { index, item -> NSDraggingItem in
            let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let offset = CGFloat(min(index, 2)) * 5
            let frame = NSRect(
                x: point.x - 38 + offset,
                y: point.y - 38 - offset,
                width: 76,
                height: 76
            )
            draggingItem.setDraggingFrame(frame, contents: item.image)
            return draggingItem
        }
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    override func mouseUp(with event: NSEvent) {
        mouseDownEvent = nil
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        if context == .outsideApplication { return .copy }
        return .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { true }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        onDragEnded?(!operation.isEmpty, keepOpen)
        startedDrag = false
        keepOpen = false
    }
}
