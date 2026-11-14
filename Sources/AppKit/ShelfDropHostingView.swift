import AppKit
import SwiftUI

@MainActor
final class ShelfDropHostingView: NSView {
    let renderingView: ShelfRenderingView
    override var isFlipped: Bool { true }
    weak var store: ShelfStore?
    var onTwoFingerTap: (() -> Void)?
    var onHoverChanged: ((Bool) -> Void)?

    private var shelfTrackingArea: NSTrackingArea?
    private var isTearingDown = false
    private var touchSequenceStartedAt: TimeInterval?
    private var initialTouchPositions: [ObjectIdentifier: NSPoint] = [:]
    private var maximumTouchCount = 0
    private var touchSequenceMoved = false
    private var windowDragTracker = ShelfWindowDragTracker()

    init(store: ShelfStore) {
        self.store = store
        renderingView = ShelfRenderingView(rootView: AnyView(
            ShelfView(store: store).frame(maxWidth: .infinity, maxHeight: .infinity)))
        super.init(frame: .zero)
        renderingView.sizingOptions = []
        renderingView.autoresizingMask = [.width, .height]
        renderingView.wantsLayer = true
        renderingView.layer?.backgroundColor = NSColor.clear.cgColor
        addSubview(renderingView)
        allowedTouchTypes = [.indirect]
    }

    override func layout() {
        super.layout()
        renderingView.frame = bounds
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let localPoint = convert(point, from: superview)
        guard bounds.contains(localPoint) else { return nil }
        guard !isTearingDown, store?.isClosed != true else { return nil }
        if #available(macOS 27, *) {
            // Do not call NSHostingView.hitTest, even as a fallback. Context
            // hit-testing in macOS 27 also bypasses the old hosting override.
            return nativeDestination(at: localPoint) ?? self
        }
        return super.hitTest(point)
    }

    private func nativeDestination(at point: NSPoint) -> NSView? {
        var best: (view: NSView, priority: Int)?
        func visit(_ view: NSView) {
            guard !view.isHidden, view.alphaValue > 0 else { return }
            let local = view.convert(point, from: self)
            guard view.bounds.contains(local), view.visibleRect.contains(local) else { return }
            let priority: Int
            if view is ShelfNativeButton { priority = 100 }
            else if view is ShelfNativeTitleView { priority = 90 }
            else if let drag = view as? DragPassThroughNSView, drag.dropStore === store {
                priority = drag.itemsProvider == nil ? 30 : 80
            } else if view is NSScrollView { priority = 20 }
            else { priority = 0 }
            if priority > 0, priority > (best?.priority ?? 0) { best = (view, priority) }
            for child in view.subviews.reversed() { visit(child) }
        }
        for child in subviews.reversed() { visit(child) }
        return best?.view
    }

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

    /// Stop hover dispatch before SwiftUI dismantles the shelf's responder
    /// tree. macOS 27 (beta) can use-after-free in NSHostingView hover
    /// hit-testing when a trailing mouseMoved arrives during window teardown.
    func prepareForTeardown() {
        isTearingDown = true
        AppDiagnostics.record("hover-tracking-stopped", category: "Window", fields: ["shelf": store?.diagnosticID ?? "unknown"])
        if let shelfTrackingArea {
            removeTrackingArea(shelfTrackingArea)
            self.shelfTrackingArea = nil
        }
    }

    override func mouseMoved(with event: NSEvent) {
        guard !isTearingDown else { return }
        // On macOS 27 this bridge is present in the fatal HoverEventDispatcher
        // stack. Custom controls use native tracking regions instead.
        if #available(macOS 27, *) { return }
        super.mouseMoved(with: event)
    }

    override func mouseEntered(with event: NSEvent) {
        guard !isTearingDown, store?.isClosed != true else { return }
        if #unavailable(macOS 27) { super.mouseEntered(with: event) }
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        guard !isTearingDown, store?.isClosed != true else { return }
        if #unavailable(macOS 27) { super.mouseExited(with: event) }
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
        NSMenu.popUpContextMenu(ShelfContextMenuFactory.make(for: store, iconRows: true), with: event, for: self)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        if isReturningDrag(sender) { return .copy }
        guard let store, store.updateExternalDrop(sender) else { return [] }
        store.targetedDragAction = nil
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard !draggingRemainsInsideShelf(sender) else { return }
        store?.scheduleDropTargetExit()
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
        guard let store else { return false }
        return ShelfDropCoordinator.accept(sender.draggingPasteboard, into: store)
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
        guard let sender, let contentView = window?.contentView else { return false }
        let point = contentView.convert(sender.draggingLocation, from: nil)
        return contentView.bounds.contains(point)
    }

}
