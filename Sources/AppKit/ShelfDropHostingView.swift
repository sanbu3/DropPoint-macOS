import AppKit
import SwiftUI

@MainActor
final class ShelfDropHostingView: NSHostingView<AnyView> {
    weak var store: ShelfStore?
    var onTwoFingerTap: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private var shelfTrackingArea: NSTrackingArea?
    private var touchSequenceStartedAt: TimeInterval?
    private var initialTouchPositions: [ObjectIdentifier: NSPoint] = [:]
    private var maximumTouchCount = 0
    private var touchSequenceMoved = false
    private var windowDragTracker = ShelfWindowDragTracker()

    init(store: ShelfStore) {
        self.store = store
        super.init(
            rootView: AnyView(
                ShelfView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        )
        allowedTouchTypes = [.indirect]
    }

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(FileDropImporter.readableTypes)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let shelfTrackingArea { removeTrackingArea(shelfTrackingArea) }
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        shelfTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        let hasFiles = store?.items.isEmpty == false
        switch ShelfPointerInteractionPolicy.backgroundMouseDown(
            clickCount: event.clickCount,
            hasFiles: hasFiles
        ) {
        case .moveShelf:
            guard let window else { return }
            windowDragTracker.begin(
                mouseLocationOnScreen: window.convertPoint(toScreen: event.locationInWindow),
                windowOrigin: window.frame.origin
            )
        case .clearShelf:
            store?.clear()
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window,
              let origin = windowDragTracker.windowOrigin(
                for: window.convertPoint(toScreen: event.locationInWindow)
              ) else { return }
        window.setFrameOrigin(origin)
    }

    override func mouseUp(with event: NSEvent) {
        windowDragTracker.end()
        super.mouseUp(with: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let store else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(ShelfContextMenuFactory.make(for: store), with: event, for: self)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isReturningDrag(sender) { return .copy }
        store?.updateDropTargeted(hasFileURLs(sender))
        return store?.isDropTargeted == true ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isReturningDrag(sender) { return .copy }
        let hasFiles = hasFileURLs(sender)
        store?.updateDropTargeted(hasFiles)
        return hasFiles ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard !draggingRemainsInsideShelf(sender) else { return }
        store?.updateDropTargeted(false)
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        store?.updateDropTargeted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        if isReturningDrag(sender) {
            store?.acceptInternalDragReturn()
            store?.updateDropTargeted(false)
            return true
        }
        let accepted = FileDropImporter.importFiles(from: sender.draggingPasteboard) { [weak store] event in
            switch event {
            case .imported(let urls): store?.add(urls: urls)
            case .failed(let message): store?.onDropFailed?(message)
            }
        }
        if accepted { store?.onDropAccepted?() }
        store?.updateDropTargeted(false)
        return accepted
    }

    override func touchesBegan(with event: NSEvent) {
        super.touchesBegan(with: event)
        if touchSequenceStartedAt == nil {
            touchSequenceStartedAt = event.timestamp
            initialTouchPositions.removeAll(keepingCapacity: true)
            maximumTouchCount = 0
            touchSequenceMoved = false
        }
        updateTouchSequence(with: event)
    }

    override func touchesMoved(with event: NSEvent) {
        super.touchesMoved(with: event)
        updateTouchSequence(with: event)
    }

    override func touchesCancelled(with event: NSEvent) {
        super.touchesCancelled(with: event)
        resetTouchSequence()
    }

    override func touchesEnded(with event: NSEvent) {
        super.touchesEnded(with: event)
        updateTouchSequence(with: event)
        guard event.touches(matching: .touching, in: self).isEmpty else { return }

        let duration = event.timestamp - (touchSequenceStartedAt ?? event.timestamp)
        let recognized = maximumTouchCount == 2
            && !touchSequenceMoved
            && duration <= 0.45
        resetTouchSequence()
        if recognized { onTwoFingerTap?() }
    }

    private func hasFileURLs(_ sender: NSDraggingInfo) -> Bool {
        FileDropImporter.canImport(from: sender.draggingPasteboard)
    }

    private func isReturningDrag(_ sender: NSDraggingInfo) -> Bool {
        guard let source = sender.draggingSource as? DragPassThroughNSView,
              let store else { return false }
        return source.dropStore === store
    }

    private func updateTouchSequence(with event: NSEvent) {
        let touches = event.touches(matching: .any, in: self)
        let touchingCount = event.touches(matching: .touching, in: self).count
        maximumTouchCount = max(maximumTouchCount, touchingCount)
        if maximumTouchCount > 2 { touchSequenceMoved = true }

        for touch in touches {
            let identifier = ObjectIdentifier(touch.identity as AnyObject)
            let position = touch.normalizedPosition
            if let initial = initialTouchPositions[identifier] {
                let distance = hypot(position.x - initial.x, position.y - initial.y)
                if distance > 0.025 { touchSequenceMoved = true }
            } else {
                initialTouchPositions[identifier] = position
            }
        }
    }

    private func resetTouchSequence() {
        touchSequenceStartedAt = nil
        initialTouchPositions.removeAll(keepingCapacity: true)
        maximumTouchCount = 0
        touchSequenceMoved = false
    }

    /// A child drop destination can disappear when SwiftUI changes the shelf's
    /// drag presentation. That also produces `draggingExited`, even though the
    /// pointer never left the shelf window. Only a physical window exit should
    /// clear the shared targeting state.
    private func draggingRemainsInsideShelf(_ sender: NSDraggingInfo?) -> Bool {
        guard let sender, let contentView = window?.contentView else { return true }
        let point = contentView.convert(sender.draggingLocation, from: nil)
        return contentView.bounds.contains(point)
    }

}
