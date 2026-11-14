import AppKit
import SwiftUI

/// Transparent overlay that lets the window be dragged by its background and
/// remains a reliable drop destination while SwiftUI swaps shelf animations.
struct DragPassThroughOverlay: NSViewRepresentable {
    let store: ShelfStore

    func makeNSView(context: Context) -> DragPassThroughNSView {
        let view = DragPassThroughNSView()
        view.dropStore = store
        return view
    }

    func updateNSView(_ nsView: DragPassThroughNSView, context: Context) {
        nsView.dropStore = store
    }
}

/// A reliable AppKit-backed grab area for moving a borderless shelf. SwiftUI's
/// background hit testing can otherwise change when file content is inserted.
struct ShelfWindowDragOverlay: NSViewRepresentable {
    let store: ShelfStore

    func makeNSView(context: Context) -> DragPassThroughNSView {
        let view = DragPassThroughNSView()
        update(view)
        return view
    }

    func updateNSView(_ nsView: DragPassThroughNSView, context: Context) {
        update(nsView)
    }

    private func update(_ view: DragPassThroughNSView) {
        view.dropStore = store
        view.onBackgroundDoubleClick = store.clear
        view.contextMenuProvider = { ShelfContextMenuFactory.make(for: store) }
    }
}

/// Overlay variant that initiates a file drag-out session.
struct FileDragOutOverlay: NSViewRepresentable {
    let store: ShelfStore
    var itemsProvider: () -> [ShelfItem]
    var dragAction: DragDefaultAction = .copy
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: ((NSDragOperation, Bool) -> Void)?
    var contextMenuProvider: (() -> NSMenu)?

    func makeNSView(context: Context) -> DragPassThroughNSView {
        let view = DragPassThroughNSView()
        view.dropStore = store
        view.itemsProvider = itemsProvider
        view.dragAction = dragAction
        view.onFileClick = onClick
        view.onFileDoubleClick = onDoubleClick
        view.onDragBegan = onDragBegan
        view.onDragOutEnded = onDragEnded
        view.contextMenuProvider = contextMenuProvider
        view.mouseDownCanMove = false
        return view
    }

    func updateNSView(_ nsView: DragPassThroughNSView, context: Context) {
        nsView.dropStore = store
        nsView.itemsProvider = itemsProvider
        nsView.dragAction = dragAction
        nsView.onFileClick = onClick
        nsView.onFileDoubleClick = onDoubleClick
        nsView.onDragBegan = onDragBegan
        nsView.onDragOutEnded = onDragEnded
        nsView.contextMenuProvider = contextMenuProvider
    }
}

struct DragOutGestureState {
    private(set) var hasStartedDrag = false
    private(set) var isMouseDown = false
    private var didActivateSession = false

    mutating func mouseDown() {
        hasStartedDrag = false
        isMouseDown = true
        didActivateSession = false
    }

    mutating func claimDragStart() -> Bool {
        guard isMouseDown, !hasStartedDrag else { return false }
        hasStartedDrag = true
        return true
    }

    mutating func draggingSessionWillBegin() -> Bool {
        guard hasStartedDrag, isMouseDown else { return false }
        didActivateSession = true
        return true
    }

    mutating func draggingSessionEnded() -> Bool {
        // AppKit can deliver one last mouseDragged before mouseUp. The gate
        // therefore belongs to the physical mouse sequence, not the session.
        defer {
            isMouseDown = false
            didActivateSession = false
        }
        return didActivateSession
    }

    mutating func mouseUp() {
        isMouseDown = false
    }
}

enum ShelfFileDragIntent: Equatable {
    case dragFiles
    case moveShelf
}

enum ShelfBackgroundMouseDownAction: Equatable {
    case moveShelf
    case clearShelf
}

struct ShelfWindowDragTracker {
    private var initialMouseLocationOnScreen: NSPoint?
    private var initialWindowOrigin: NSPoint?

    var isActive: Bool {
        initialMouseLocationOnScreen != nil && initialWindowOrigin != nil
    }

    mutating func begin(mouseLocationOnScreen: NSPoint, windowOrigin: NSPoint) {
        initialMouseLocationOnScreen = mouseLocationOnScreen
        initialWindowOrigin = windowOrigin
    }

    func windowOrigin(for mouseLocationOnScreen: NSPoint) -> NSPoint? {
        guard let initialMouseLocationOnScreen, let initialWindowOrigin else { return nil }
        return NSPoint(
            x: initialWindowOrigin.x + mouseLocationOnScreen.x - initialMouseLocationOnScreen.x,
            y: initialWindowOrigin.y + mouseLocationOnScreen.y - initialMouseLocationOnScreen.y
        )
    }

    mutating func end() {
        initialMouseLocationOnScreen = nil
        initialWindowOrigin = nil
    }
}

enum ShelfPointerInteractionPolicy {
    static func fileDragIntent(modifiers: NSEvent.ModifierFlags) -> ShelfFileDragIntent {
        modifiers.contains(.control) ? .moveShelf : .dragFiles
    }

    static func backgroundMouseDown(
        clickCount: Int,
        hasFiles: Bool
    ) -> ShelfBackgroundMouseDownAction {
        clickCount >= 2 && hasFiles ? .clearShelf : .moveShelf
    }
}

final class DragPassThroughNSView: NSView {
    weak var dropStore: ShelfStore?
    var itemsProvider: (() -> [ShelfItem])?
    var dragAction: DragDefaultAction = .copy
    var onFileClick: ((NSEvent.ModifierFlags) -> Void)?
    var onFileDoubleClick: (() -> Void)?
    var onBackgroundDoubleClick: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragOutEnded: ((NSDragOperation, Bool) -> Void)?
    var contextMenuProvider: (() -> NSMenu)?

    var mouseDownCanMove: Bool = true
    override var mouseDownCanMoveWindow: Bool { mouseDownCanMove }

    // A shelf commonly sits above another active app. Keep the initial
    // mouse-down/drag sequence intact instead of consuming it for activation.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private var dragOutGesture = DragOutGestureState()
    private var windowDragTracker = ShelfWindowDragTracker()
    private var dragKeepOpen = false
    // Deliberately retain the source and window until AppKit's end callback.
    // SwiftUI may replace/remove this representable while a drag is in flight.
    private struct DragLease {
        let source: DragPassThroughNSView
        let window: NSWindow?
        let keepOpen: Bool
        let action: DragDefaultAction
        let onBegan: (() -> Void)?
        let onEnded: ((NSDragOperation, Bool) -> Void)?
    }
    private var dragLease: DragLease?
    private var dragOutMouseDownPoint: NSPoint = .zero
    private let dragOutThreshold: CGFloat = 5

    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(FileDropImporter.readableTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        draggingUpdated(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let dropStore else { return [] }
        if isReturningDrag(sender, to: dropStore) { return .copy }
        guard dropStore.updateExternalDrop(sender) else { return [] }
        dropStore.collapseDragActions()
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard !draggingRemainsInsideShelf(sender) else { return }
        dropStore?.scheduleDropTargetExit()
    }

    override func draggingEnded(_ sender: NSDraggingInfo) {
        dropStore?.updateDropTargeted(false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let dropStore else { return false }
        if isReturningDrag(sender, to: dropStore) {
            dropStore.acceptInternalDragReturn()
            dropStore.updateDropTargeted(false)
            return true
        }
        return acceptExternalPasteboard(sender.draggingPasteboard)
    }

    @discardableResult
    func acceptExternalPasteboard(_ pasteboard: NSPasteboard) -> Bool {
        guard let dropStore else { return false }
        return ShelfDropCoordinator.accept(pasteboard, into: dropStore)
    }

    override func mouseDown(with event: NSEvent) {
        guard itemsProvider != nil else {
            handleBackgroundMouseDown(event)
            return
        }
        if ShelfPointerInteractionPolicy.fileDragIntent(modifiers: event.modifierFlags) == .moveShelf {
            beginWindowDrag(with: event)
            return
        }
        dragOutGesture.mouseDown()
        dragKeepOpen = event.modifierFlags.contains(.shift)
        dragOutMouseDownPoint = convert(event.locationInWindow, from: nil)
        if event.clickCount >= 2 {
            onFileDoubleClick?()
        } else {
            onFileClick?(event.modifierFlags)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        if windowDragTracker.isActive {
            continueWindowDrag(with: event)
            return
        }
        guard dropStore?.isClosed != true, !dragOutGesture.hasStartedDrag,
              let items = itemsProvider?(), !items.isEmpty else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - dragOutMouseDownPoint.x
        let dy = current.y - dragOutMouseDownPoint.y
        guard dx * dx + dy * dy > dragOutThreshold * dragOutThreshold else { return }
        guard dragOutGesture.claimDragStart() else { return }

        let point = convert(event.locationInWindow, from: nil)
        let draggingItems = items.enumerated().map { index, item -> NSDraggingItem in
            let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let offset = CGFloat(min(index, 2)) * 5
            let frame = NSRect(x: point.x - 38 + offset, y: point.y - 38 - offset, width: 76, height: 76)
            draggingItem.setDraggingFrame(frame, contents: item.image)
            return draggingItem
        }
        dragLease = DragLease(source: self, window: window, keepOpen: dragKeepOpen,
                              action: dragAction, onBegan: onDragBegan, onEnded: onDragOutEnded)
        let session = beginDraggingSession(with: draggingItems, event: event, source: self)
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenuProvider?() else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseUp(with event: NSEvent) {
        windowDragTracker.end()
        dragOutGesture.mouseUp()
        dragKeepOpen = false
        dragOutMouseDownPoint = .zero
    }

    private func handleBackgroundMouseDown(_ event: NSEvent) {
        let hasFiles = dropStore?.items.isEmpty == false
        switch ShelfPointerInteractionPolicy.backgroundMouseDown(
            clickCount: event.clickCount,
            hasFiles: hasFiles
        ) {
        case .moveShelf:
            beginWindowDrag(with: event)
        case .clearShelf:
            onBackgroundDoubleClick?()
        }
    }

    private func beginWindowDrag(with event: NSEvent) {
        guard let window else { return }
        windowDragTracker.begin(
            mouseLocationOnScreen: window.convertPoint(toScreen: event.locationInWindow),
            windowOrigin: window.frame.origin
        )
    }

    private func continueWindowDrag(with event: NSEvent) {
        guard let window,
              let origin = windowDragTracker.windowOrigin(
                for: window.convertPoint(toScreen: event.locationInWindow)
              ) else { return }
        window.setFrameOrigin(origin)
    }

    private func draggingRemainsInsideShelf(_ sender: NSDraggingInfo?) -> Bool {
        guard let sender, let contentView = window?.contentView else { return false }
        let point = contentView.convert(sender.draggingLocation, from: nil)
        return contentView.bounds.contains(point)
    }

    private func isReturningDrag(_ sender: NSDraggingInfo, to store: ShelfStore) -> Bool {
        guard let source = sender.draggingSource as? DragPassThroughNSView else { return false }
        return source.dropStore === store
    }

}

// MARK: - DraggingSource (for drag-out)

extension DragPassThroughNSView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, willBeginAt screenPoint: NSPoint) {
        let shouldActivate = dragOutGesture.draggingSessionWillBegin()
        if shouldActivate {
            dragLease?.onBegan?()
        } else {
            session.animatesToStartingPositionsOnCancelOrFail = false
            hideLateDraggingItems(in: session)
            postReleaseForLateDraggingSession(at: screenPoint)
        }
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        let flags = NSEvent.modifierFlags
        if flags.contains(.option) { return .copy }
        if flags.contains(.command) { return .move }
        return (dragLease?.action ?? dragAction) == .move ? .move : .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { false }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let didActivate = dragOutGesture.draggingSessionEnded()
        let lease = dragLease
        dragLease = nil
        withExtendedLifetime(lease) {
            if didActivate, let lease {
                lease.onEnded?(operation, lease.keepOpen)
            }
        }
        dragKeepOpen = false
    }

    private func postReleaseForLateDraggingSession(at screenPoint: NSPoint) {
        guard let window else { return }
        let location = window.convertPoint(fromScreen: screenPoint)
        guard let release = NSEvent.mouseEvent(
            with: .leftMouseUp,
            location: location,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 1,
            pressure: 0
        ) else { return }
        NSApp.postEvent(release, atStart: true)
    }

    private func hideLateDraggingItems(in session: NSDraggingSession) {
        let transparentImage = NSImage(size: NSSize(width: 1, height: 1))
        session.enumerateDraggingItems(
            options: [],
            for: self,
            classes: [NSURL.self],
            searchOptions: [:]
        ) { draggingItem, _, _ in
            draggingItem.setDraggingFrame(draggingItem.draggingFrame, contents: transparentImage)
        }
    }
}
