import AppKit
import SwiftUI
import WebKit

struct AnimatedSVGView: NSViewRepresentable {
    let name: String
    var animationEnabled = true
    var pauseAfterCycle = false
    var randomRestart = false
    var onReady: (() -> Void)?

    func makeCoordinator() -> Coordinator {
        let coordinator = Coordinator()
        coordinator.onReady = onReady
        return coordinator
    }

    func makeNSView(context: Context) -> NonInteractiveSVGWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()

        let webView = NonInteractiveSVGWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.underPageBackgroundColor = .clear
        webView.setValue(false, forKey: "drawsBackground")
        webView.setAccessibilityElement(false)

        loadSVG(in: webView, coordinator: context.coordinator)
        return webView
    }

    func updateNSView(_ webView: NonInteractiveSVGWebView, context: Context) {
        guard let url = resourceURL else { return }
        if context.coordinator.loadedURL != url {
            loadSVG(in: webView, coordinator: context.coordinator)
        } else {
            context.coordinator.setAnimationEnabled(animationEnabled, in: webView)
        }
    }

    static func dismantleNSView(_ webView: NonInteractiveSVGWebView, coordinator: Coordinator) {
        coordinator.stopAnimation(in: webView)
        webView.stopLoading()
        webView.navigationDelegate = nil
    }

    private var resourceURL: URL? {
        Bundle.main.url(forResource: name, withExtension: "svg")
    }

    private func loadSVG(in webView: WKWebView, coordinator: Coordinator) {
        guard let url = resourceURL,
              let svg = try? String(contentsOf: url, encoding: .utf8) else { return }
        coordinator.loadedURL = url
        coordinator.animationEnabled = animationEnabled
        coordinator.pauseAfterCycle = pauseAfterCycle
        coordinator.randomRestart = randomRestart
        coordinator.isLoaded = false
        let document = """
        <!doctype html>
        <html>
        <head>
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <style>
            html, body { width: 100%; height: 100%; margin: 0; overflow: hidden; background: transparent; }
            body > svg { display: block; width: 100%; height: 100%; }
          </style>
        </head>
        <body>\(svg)</body>
        </html>
        """
        webView.loadHTMLString(document, baseURL: url.deletingLastPathComponent())
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var loadedURL: URL?
        var animationEnabled = true
        var pauseAfterCycle = false
        var randomRestart = false
        var isLoaded = false
        var onReady: (() -> Void)?

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            isLoaded = true
            applyAnimationState(in: webView)
            // Navigation completion precedes WebKit's first painted frame.
            webView.callAsyncJavaScript(
                "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));",
                arguments: [:], in: nil, in: .page
            ) { [weak self] _ in
                self?.onReady?()
            }
        }

        func setAnimationEnabled(_ enabled: Bool, in webView: WKWebView) {
            guard animationEnabled != enabled else { return }
            animationEnabled = enabled
            guard isLoaded else { return }
            applyAnimationState(in: webView)
        }

        func stopAnimation(in webView: WKWebView) {
            webView.evaluateJavaScript(
                "window.__dropPointAnimation?.stop?.(); document.querySelector('svg')?.pauseAnimations()"
            )
        }

        private func applyAnimationState(in webView: WKWebView) {
            let cycle = pauseAfterCycle
            let rand = randomRestart
            let enabled = animationEnabled
            let script = """
            (function() {
                var svg = document.querySelector('svg');
                if (!svg) return;
                var previous = window.__dropPointAnimation;
                if (previous && previous.stop) previous.stop();

                var state = {
                    enabled: \(enabled),
                    timers: [],
                    stop: function() {
                        state.enabled = false;
                        state.timers.forEach(clearTimeout);
                        state.timers = [];
                        svg.pauseAnimations();
                    }
                };
                window.__dropPointAnimation = state;

                function later(action, delay) {
                    var timer = setTimeout(function() {
                        state.timers = state.timers.filter(function(value) { return value !== timer; });
                        if (state.enabled) action();
                    }, delay);
                    state.timers.push(timer);
                }
                function play() {
                    if (!state.enabled) return;
                    svg.setCurrentTime(0);
                    svg.unpauseAnimations();
                }
                function pause() { svg.pauseAnimations(); }

                if (!state.enabled) {
                    pause();
                    return;
                }

                if (\(rand)) {
                    play();
                    var dur = 3.0;
                    function cycle() {
                        pause();
                        var delay = 3000 + Math.random() * 5000;
                        later(function() {
                            play();
                            later(cycle, dur * 1000);
                        }, delay);
                    }
                    later(cycle, dur * 1000);
                } else if (\(cycle)) {
                    play();
                    later(pause, 3000);
                } else {
                    svg.unpauseAnimations();
                }
            })();
            """
            webView.evaluateJavaScript(script)
        }
    }
}

final class NonInteractiveSVGWebView: WKWebView {
    override var acceptsFirstResponder: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
    }

    required init?(coder: NSCoder) {
        nil
    }
}

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
        guard !hasStartedDrag else { return false }
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
    private var dragOutMouseDownPoint: NSPoint = .zero
    private let dragOutThreshold: CGFloat = 5

    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(FileDropImporter.readableTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let dropStore else { return [] }
        if isReturningDrag(sender, to: dropStore) { return .copy }
        let acceptsFiles = FileDropImporter.canImport(from: sender.draggingPasteboard)
        dropStore.updateDropTargeted(acceptsFiles)
        return acceptsFiles ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let dropStore else { return [] }
        if isReturningDrag(sender, to: dropStore) { return .copy }
        let acceptsFiles = FileDropImporter.canImport(from: sender.draggingPasteboard)
        dropStore.updateDropTargeted(acceptsFiles)
        return acceptsFiles ? .copy : []
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        guard !draggingRemainsInsideShelf(sender) else { return }
        dropStore?.updateDropTargeted(false)
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
        let accepted = FileDropImporter.importFiles(from: pasteboard) { [weak dropStore] event in
            switch event {
            case .imported(let urls): dropStore?.add(urls: urls)
            case .failed(let message): dropStore?.onDropFailed?(message)
            }
        }
        if accepted { dropStore.onDropAccepted?() }
        dropStore.updateDropTargeted(false)
        return accepted
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
        guard !dragOutGesture.hasStartedDrag, let items = itemsProvider?(), !items.isEmpty else { return }
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
        guard let sender, let contentView = window?.contentView else { return true }
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
            onDragBegan?()
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
        return dragAction == .move ? .move : .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { false }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        let didActivate = dragOutGesture.draggingSessionEnded()
        if didActivate {
            onDragOutEnded?(operation, dragKeepOpen)
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
