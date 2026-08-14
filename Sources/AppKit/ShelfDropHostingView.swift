import AppKit
import SwiftUI

@MainActor
final class ShelfDropHostingView: NSHostingView<AnyView> {
    weak var store: ShelfStore?
    var onTwoFingerTap: (() -> Void)?

    private var touchSequenceStartedAt: TimeInterval?
    private var initialTouchPositions: [ObjectIdentifier: NSPoint] = [:]
    private var maximumTouchCount = 0
    private var touchSequenceMoved = false

    init(store: ShelfStore) {
        self.store = store
        super.init(
            rootView: AnyView(
                ShelfView(store: store)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            )
        )
        acceptsTouchEvents = true
    }

    required init(rootView: AnyView) {
        super.init(rootView: rootView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var mouseDownCanMoveWindow: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(FileDropImporter.readableTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard store?.isDraggingOut != true else { return [] }
        activateShelfWindow()
        store?.updateDropTargeted(hasFileURLs(sender))
        return store?.isDropTargeted == true ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard store?.isDraggingOut != true else { return [] }
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
        let accepted = FileDropImporter.importFiles(from: sender.draggingPasteboard) { [weak store] urls in
            store?.add(urls: urls)
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

    private func activateShelfWindow() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func hasFileURLs(_ sender: NSDraggingInfo) -> Bool {
        FileDropImporter.canImport(from: sender.draggingPasteboard)
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
