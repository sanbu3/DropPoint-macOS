import AppKit
import SwiftUI
import WebKit

struct AnimatedSVGView: NSViewRepresentable {
    let name: String
    var animationEnabled = true
    var pauseAfterCycle = false
    var randomRestart = false

    func makeCoordinator() -> Coordinator {
        Coordinator()
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

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation?) {
            isLoaded = true
            applyAnimationState(in: webView)
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

/// Overlay variant that initiates a file drag-out session.
struct FileDragOutOverlay: NSViewRepresentable {
    let store: ShelfStore
    var itemsProvider: () -> [ShelfItem]
    var dragAction: DragDefaultAction = .copy
    var onClick: ((NSEvent.ModifierFlags) -> Void)?
    var onDoubleClick: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragEnded: ((Bool, Bool) -> Void)?
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

final class DragPassThroughNSView: NSView {
    weak var dropStore: ShelfStore?
    var itemsProvider: (() -> [ShelfItem])?
    var dragAction: DragDefaultAction = .copy
    var onFileClick: ((NSEvent.ModifierFlags) -> Void)?
    var onFileDoubleClick: (() -> Void)?
    var onDragBegan: (() -> Void)?
    var onDragOutEnded: ((Bool, Bool) -> Void)?
    var contextMenuProvider: (() -> NSMenu)?

    var mouseDownCanMove: Bool = true
    override var mouseDownCanMoveWindow: Bool { mouseDownCanMove }

    private var dragOutStarted = false
    private var dragKeepOpen = false
    private var dragOutMouseDownPoint: NSPoint = .zero
    private let dragOutThreshold: CGFloat = 5

    override func hitTest(_ point: NSPoint) -> NSView? { self }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        registerForDraggedTypes(FileDropImporter.readableTypes)
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let dropStore, !dropStore.isDraggingOut else { return [] }
        let acceptsFiles = FileDropImporter.canImport(from: sender.draggingPasteboard)
        if acceptsFiles {
            activateShelfWindow()
        }
        dropStore.updateDropTargeted(acceptsFiles)
        return acceptsFiles ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let dropStore, !dropStore.isDraggingOut else { return [] }
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
        guard let dropStore, !dropStore.isDraggingOut else { return false }
        let accepted = FileDropImporter.importFiles(from: sender.draggingPasteboard) { [weak dropStore] urls in
            dropStore?.add(urls: urls)
        }
        dropStore.updateDropTargeted(false)
        return accepted
    }

    override func mouseDown(with event: NSEvent) {
        guard itemsProvider != nil else {
            window?.performDrag(with: event)
            return
        }
        dragKeepOpen = event.modifierFlags.contains(.shift)
        dragOutMouseDownPoint = convert(event.locationInWindow, from: nil)
        if event.clickCount >= 2 {
            onFileDoubleClick?()
        } else {
            onFileClick?(event.modifierFlags)
        }
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragOutStarted, let items = itemsProvider?(), !items.isEmpty else { return }
        let current = convert(event.locationInWindow, from: nil)
        let dx = current.x - dragOutMouseDownPoint.x
        let dy = current.y - dragOutMouseDownPoint.y
        guard dx * dx + dy * dy > dragOutThreshold * dragOutThreshold else { return }
        dragOutStarted = true
        onDragBegan?()

        let point = convert(event.locationInWindow, from: nil)
        let draggingItems = items.enumerated().map { index, item -> NSDraggingItem in
            let draggingItem = NSDraggingItem(pasteboardWriter: item.url as NSURL)
            let offset = CGFloat(min(index, 2)) * 5
            let frame = NSRect(x: point.x - 38 + offset, y: point.y - 38 - offset, width: 76, height: 76)
            draggingItem.setDraggingFrame(frame, contents: item.image)
            return draggingItem
        }
        beginDraggingSession(with: draggingItems, event: event, source: self)
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu = contextMenuProvider?() else {
            super.rightMouseDown(with: event)
            return
        }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }

    override func mouseUp(with event: NSEvent) {
        dragOutStarted = false
        dragKeepOpen = false
        dragOutMouseDownPoint = .zero
    }

    private func activateShelfWindow() {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func draggingRemainsInsideShelf(_ sender: NSDraggingInfo?) -> Bool {
        guard let sender, let contentView = window?.contentView else { return true }
        let point = contentView.convert(sender.draggingLocation, from: nil)
        return contentView.bounds.contains(point)
    }

}

// MARK: - DraggingSource (for drag-out)

extension DragPassThroughNSView: NSDraggingSource {
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        if context == .outsideApplication { return .copy }
        let flags = NSEvent.modifierFlags
        if flags.contains(.option) { return .copy }
        if flags.contains(.command) { return .move }
        return dragAction == .move ? .move : .copy
    }

    func ignoreModifierKeys(for session: NSDraggingSession) -> Bool { false }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        onDragOutEnded?(!operation.isEmpty, dragKeepOpen)
        dragOutStarted = false
        dragKeepOpen = false
    }
}
