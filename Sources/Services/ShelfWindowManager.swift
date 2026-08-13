import AppKit
import QuickLookUI
import SwiftUI

@MainActor
private final class QuickLookPreviewController: NSObject, @preconcurrency QLPreviewPanelDataSource {
    private var urls: [URL] = []
    private weak var owner: ShelfWindowController?
    private var keyMonitor: Any?

    func show(_ url: URL, for owner: ShelfWindowController) {
        guard FileManager.default.fileExists(atPath: url.path),
              let panel = QLPreviewPanel.shared() else { return }
        self.owner = owner
        urls = [url]
        panel.dataSource = self
        panel.reloadData()
        panel.currentPreviewItemIndex = 0
        installKeyMonitor()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func isShowing(for owner: ShelfWindowController) -> Bool {
        guard self.owner === owner else { return false }
        guard QLPreviewPanel.sharedPreviewPanelExists(),
              QLPreviewPanel.shared()?.isVisible == true else {
            resetOwnership()
            return false
        }
        return true
    }

    func close(ifOwnedBy owner: ShelfWindowController) {
        guard self.owner === owner else { return }
        if QLPreviewPanel.sharedPreviewPanelExists() {
            QLPreviewPanel.shared()?.orderOut(nil)
        }
        resetOwnership()
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        urls.count
    }

    func previewPanel(
        _ panel: QLPreviewPanel!,
        previewItemAt index: Int
    ) -> (any QLPreviewItem)! {
        urls[index] as NSURL
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  QLPreviewPanel.sharedPreviewPanelExists(),
                  event.window === QLPreviewPanel.shared(),
                  event.keyCode == 49,
                  event.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
            else { return event }

            let ownerWindow = self.owner?.window
            if let owner = self.owner {
                self.close(ifOwnedBy: owner)
            }
            ownerWindow?.makeKeyAndOrderFront(nil)
            return nil
        }
    }

    private func resetOwnership() {
        owner = nil
        urls.removeAll()
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
        if QLPreviewPanel.sharedPreviewPanelExists() {
            QLPreviewPanel.shared()?.dataSource = nil
        }
    }
}

private final class DropPointSettingsWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

enum ShelfCreationSource {
    case manual
    case watchedDirectory
    case screenshot

    func position(default defaultPosition: ShelfPosition) -> ShelfPosition {
        switch self {
        case .manual: return defaultPosition
        case .watchedDirectory, .screenshot: return .topRight
        }
    }
}

@MainActor
final class ShelfWindowManager {
    let settings: AppSettings
    var statusFrameProvider: (() -> NSRect?)?
    var onInternalDragActivityChanged: ((Bool) -> Void)?
    private(set) var internalDragCount = 0

    private var shelves: [ShelfWindowController] = []
    private var pendingShelf: ShelfWindowController?
    private weak var presentedQuickShelf: ShelfWindowController?
    private var settingsWindowController: NSWindowController?
    private let quickLookPreviewController = QuickLookPreviewController()
    private var quickCleanupWorkItem: DispatchWorkItem?
    private var emptyAutoCloseTimers: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var idleSnapTimers: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var transientIDs = Set<ObjectIdentifier>()
    private var closedHistory: [[URL]] = []

    init(settings: AppSettings) {
        self.settings = settings
        debugLog("SNAP: ShelfWindowManager init")
    }

    var hasShelves: Bool { !shelves.isEmpty }
    var isInternalDragActive: Bool { internalDragCount > 0 }
    var canRestoreLastClosedShelf: Bool { !closedHistory.isEmpty }

    @discardableResult
    func spawnFromShake() -> ShelfWindowController? {
        guard ShelfActivationPolicy.allowsShakeSpawn(hasOpenShelf: hasShelves) else {
            return nil
        }
        return spawn(forcePosition: .cursor, transient: true)
    }

    @discardableResult
    func spawn(
        urls: [URL] = [],
        forcePosition: ShelfPosition? = nil,
        transient: Bool = false,
        source: ShelfCreationSource = .manual
    ) -> ShelfWindowController {
        if transient {
            closeEmptyShelves()
        }
        let resolvedPosition = forcePosition ?? source.position(default: settings.shelfPosition)
        let controller = makeShelf(presentation: .standard, pending: false)
        let screen = targetScreen(for: resolvedPosition)
        let placementArea: NSRect
        switch source {
        case .manual:
            placementArea = screen.visibleFrame
        case .watchedDirectory, .screenshot:
            placementArea = ShelfGeometry.dockingArea(in: screen.visibleFrame)
        }
        let base = ShelfGeometry.origin(
            for: resolvedPosition,
            in: placementArea,
            cursor: NSEvent.mouseLocation
        )
        let origin = cascadedOrigin(from: base, in: placementArea)
        shelves.append(controller)
        controller.show(at: origin, activating: true)
        if !urls.isEmpty { controller.store.add(urls: urls) }
        if transient {
            transientIDs.insert(ObjectIdentifier(controller))
            debugLog("SNAP: spawned transient")
        }
        scheduleIdleSnap(controller)
        scheduleEmptyAutoClose(controller)
        return controller
    }

    private func closeEmptyShelves() {
        for controller in shelves where controller.store.items.isEmpty {
            controller.closeAnimated()
        }
        if let pending = pendingShelf, pending.store.items.isEmpty {
            pending.closeAnimated()
            pendingShelf = nil
        }
    }

    private func scheduleEmptyAutoClose(_ controller: ShelfWindowController) {
        cancelEmptyAutoClose(controller)
        let timeout = settings.emptyShelfTimeout
        guard timeout > 0 else { return }
        let workItem = DispatchWorkItem { [weak self, weak controller] in
            guard let self, let controller,
                  controller.store.items.isEmpty,
                  self.shelves.contains(where: { $0 === controller }) else { return }
            controller.closeAnimated()
        }
        emptyAutoCloseTimers[ObjectIdentifier(controller)] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: workItem)
    }

    private func cancelEmptyAutoClose(_ controller: ShelfWindowController) {
        if let item = emptyAutoCloseTimers.removeValue(forKey: ObjectIdentifier(controller)) {
            item.cancel()
        }
    }

    private func scheduleIdleSnap(_ controller: ShelfWindowController) {
        cancelIdleSnap(controller)
        let delay = settings.idleSnapDelay.seconds
        guard ShelfIdlePolicy.shouldSchedule(delay: delay) else { return }
        let workItem = DispatchWorkItem { [weak self, weak controller] in
            guard let self, let controller,
                  self.shelves.contains(where: { $0 === controller }) else { return }
            self.idleSnapTimers.removeValue(forKey: ObjectIdentifier(controller))
            self.snapToTopRight(controller)
            if controller.store.items.isEmpty {
                self.scheduleEmptyAutoClose(controller)
            }
        }
        idleSnapTimers[ObjectIdentifier(controller)] = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelIdleSnap(_ controller: ShelfWindowController) {
        idleSnapTimers.removeValue(forKey: ObjectIdentifier(controller))?.cancel()
    }

    func toggleShelves() {
        guard !shelves.isEmpty else {
            spawn()
            return
        }
        let shouldHide = shelves.contains { $0.window?.isVisible == true }
        if shouldHide {
            shelves.forEach { $0.orderOutAnimated() }
        } else {
            if settings.shelfPosition == .cursor { repositionNearCursor() }
            for (index, controller) in shelves.enumerated() {
                controller.showExistingAnimated(activating: index == shelves.count - 1)
            }
        }
    }

    func closeAll() { shelves.forEach { $0.closeAnimated() } }

    func restoreLastClosedShelf() {
        guard let urls = closedHistory.popLast(), !urls.isEmpty else { return }
        spawn(urls: urls)
    }

    func updateAlwaysOnTop() {
        shelves.forEach { $0.setAlwaysOnTop(settings.alwaysOnTop) }
    }

    func updateDragAction(_ action: DragDefaultAction) {
        shelves.forEach { $0.store.dragAction = action }
        pendingShelf?.store.dragAction = action
    }

    func updateInteractions() {
        shelves.forEach { applySettings(to: $0.store) }
        if let pendingShelf { applySettings(to: pendingShelf.store) }
        shelves.forEach(scheduleIdleSnap)
    }

    func prepareQuickShelf() {
        guard pendingShelf == nil else { return }
        pendingShelf = makeShelf(presentation: .tray, pending: true)
    }

    func presentQuickShelf() {
        guard !isInternalDragActive else { return }
        quickCleanupWorkItem?.cancel()
        prepareQuickShelf()
        guard let controller = pendingShelf else { return }
        let statusFrame = statusFrameProvider?()
        let screen = statusFrame.flatMap { frame in
            let center = NSPoint(x: frame.midX, y: frame.midY)
            return NSScreen.screens.first(where: { $0.frame.contains(center) })
        } ?? targetScreen(for: .cursor)
        let origin = statusFrame.map {
            ShelfGeometry.quickShelfOrigin(statusFrame: $0, in: screen.visibleFrame)
        } ?? ShelfGeometry.origin(
            for: .cursor,
            in: screen.visibleFrame,
            cursor: NSEvent.mouseLocation
        )
        presentedQuickShelf = controller
        controller.show(at: origin, activating: false)
    }

    func endQuickShelfSession() {
        guard let candidate = presentedQuickShelf else { return }
        quickCleanupWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self, weak candidate] in
            guard let self, let candidate,
                  self.pendingShelf === candidate,
                  self.presentedQuickShelf === candidate else { return }
            candidate.orderOutAnimated()
            self.presentedQuickShelf = nil
        }
        quickCleanupWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: item)
    }

    func showSettings() {
        if let window = settingsWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(
            settings: settings,
            onDismiss: { [weak self] in self?.settingsWindowController?.window?.close() }
        )
        let window = DropPointSettingsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 640),
            styleMask: [.borderless, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "DropPoint 设置"
        window.minSize = NSSize(width: 820, height: 560)
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        let hostingView = NSHostingView(rootView: view)
        hostingView.wantsLayer = true
        hostingView.layer?.cornerRadius = 20
        hostingView.layer?.masksToBounds = true
        window.contentView = hostingView
        window.center()
        window.isReleasedWhenClosed = false
        let controller = NSWindowController(window: window)
        settingsWindowController = controller
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func snap(_ controller: ShelfWindowController) {
        guard let window = controller.window, let screen = window.screen else { return }
        let dockingArea = ShelfGeometry.dockingArea(in: screen.visibleFrame)
        let origin = ShelfGeometry.snappedOrigin(frame: window.frame, in: dockingArea)
        guard origin != window.frame.origin else { return }
        controller.move(to: origin, duration: 0.16)
    }

    private func snapAfterDrop(_ controller: ShelfWindowController) {
        guard let window = controller.window else { return }
        let screen = window.screen ?? targetScreen(for: .cursor)
        let dockingArea = ShelfGeometry.dockingArea(in: screen.visibleFrame)
        let position: ShelfPosition = settings.snapCorner == .topLeft ? .topLeft : .topRight
        let preferred = ShelfGeometry.origin(
            for: position,
            in: dockingArea,
            cursor: NSEvent.mouseLocation,
            size: window.frame.size
        )
        let origin = ShelfGeometry.nonOverlappingOrigin(
            preferred: preferred,
            size: window.frame.size,
            in: dockingArea,
            occupiedFrames: shelves.compactMap { other in
                guard other !== controller, other.window?.isVisible == true else { return nil }
                return other.window?.frame
            }
        )
        guard origin != window.frame.origin else { return }
        controller.move(to: origin, duration: 0.34)
    }

    private func snapToTopRight(_ controller: ShelfWindowController) {
        guard let window = controller.window, let screen = window.screen else { return }
        let dockingArea = ShelfGeometry.dockingArea(in: screen.visibleFrame)
        let preferred = ShelfGeometry.origin(
            for: .topRight,
            in: dockingArea,
            cursor: NSEvent.mouseLocation,
            size: window.frame.size
        )
        let origin = ShelfGeometry.nonOverlappingOrigin(
            preferred: preferred,
            size: window.frame.size,
            in: dockingArea,
            occupiedFrames: shelves.compactMap { other in
                guard other !== controller, other.window?.isVisible == true else { return nil }
                return other.window?.frame
            }
        )
        controller.move(to: origin, duration: 0.34)
    }

    private func makeShelf(
        presentation: ShelfPresentation,
        pending: Bool
    ) -> ShelfWindowController {
        let store = ShelfStore(presentation: presentation)
        applySettings(to: store)
        let controller = ShelfWindowController(
            store: store,
            isPending: pending,
            alwaysOnTop: settings.alwaysOnTop
        )
        store.onClose = { [weak controller] in controller?.closeAnimated() }
        store.onCollapse = { [weak controller] in controller?.orderOutAnimated() }
        store.onExpansionChanged = { [weak self, weak controller] expanded in
            guard let controller else { return }
            if !expanded {
                self?.quickLookPreviewController.close(ifOwnedBy: controller)
            }
            controller.setExpanded(expanded)
        }
        store.onItemCountChanged = { [weak controller] count in
            controller?.updateExpandedSize(for: count)
        }
        store.onQuickCommit = { [weak self, weak controller] in
            guard let controller else { return }
            self?.commitQuickShelf(controller)
        }
        store.onPreviewRequested = { [weak self, weak controller] url in
            guard let self, let controller else { return }
            self.quickLookPreviewController.show(url, for: controller)
        }
        store.onDropSettled = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.cancelEmptyAutoClose(controller)
            self.scheduleIdleSnap(controller)
            self.transientIDs.remove(ObjectIdentifier(controller))
            DispatchQueue.main.async { [weak self, weak controller] in
                guard let self, let controller else { return }
                self.snapAfterDrop(controller)
            }
        }
        store.onEmptied = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.scheduleEmptyAutoClose(controller)
        }
        store.onInternalDragStateChanged = { [weak self, weak controller] began in
            guard let self else { return }
            let wasActive = self.isInternalDragActive
            self.internalDragCount = max(0, self.internalDragCount + (began ? 1 : -1))
            let isActive = self.isInternalDragActive
            if isActive != wasActive {
                self.onInternalDragActivityChanged?(isActive)
            }
            if began {
                controller?.beginDragGhost()
            } else {
                controller?.endDragGhost()
            }
        }
        controller.onClosed = { [weak self] controller in self?.remove(controller) }
        controller.isPreviewActive = { [weak self, weak controller] in
            guard let self, let controller else { return false }
            return self.quickLookPreviewController.isShowing(for: controller)
        }
        controller.onWillDismiss = { [weak self] controller in
            self?.quickLookPreviewController.close(ifOwnedBy: controller)
        }
        controller.onSnapRequested = { [weak self] controller in self?.snap(controller) }
        controller.onInteraction = { [weak self] controller in self?.scheduleIdleSnap(controller) }
        return controller
    }

    private func applySettings(to store: ShelfStore) {
        store.dragAction = settings.dragAction
        store.doubleClickAction = settings.doubleClickAction
        store.autoCollapseExpanded = settings.autoCollapseExpanded
        store.focusShelfOnShow = settings.focusShelfOnShow
        store.instantActionsEnabled = settings.instantActionsEnabled
        store.enabledActions = settings.enabledActions
        store.customActions = settings.customActions
    }

    private func commitQuickShelf(_ controller: ShelfWindowController) {
        guard pendingShelf === controller else { return }
        quickCleanupWorkItem?.cancel()
        controller.store.presentation = .standard
        controller.setAlwaysOnTop(settings.alwaysOnTop)
        shelves.append(controller)
        pendingShelf = nil
        presentedQuickShelf = nil
        prepareQuickShelf()
    }

    private func remove(_ controller: ShelfWindowController) {
        let urls = controller.store.items.map(\.url)
        if !urls.isEmpty {
            closedHistory.append(urls)
            if closedHistory.count > 10 { closedHistory.removeFirst() }
        }
        cancelEmptyAutoClose(controller)
        cancelIdleSnap(controller)
        transientIDs.remove(ObjectIdentifier(controller))
        shelves.removeAll { $0 === controller }
        if pendingShelf === controller { pendingShelf = nil }
        if presentedQuickShelf === controller { presentedQuickShelf = nil }
    }

    private func targetScreen(for position: ShelfPosition) -> NSScreen {
        if position == .cursor {
            let cursor = NSEvent.mouseLocation
            return NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.screens[0]
        }
        return NSScreen.screens.first ?? NSScreen.main!
    }

    private func cascadedOrigin(from base: NSPoint, in workArea: NSRect) -> NSPoint {
        ShelfGeometry.nonOverlappingOrigin(
            preferred: base,
            in: workArea,
            occupiedFrames: shelves.compactMap(\.window?.frame)
        )
    }

    private func repositionNearCursor() {
        let screen = targetScreen(for: .cursor)
        let base = ShelfGeometry.origin(
            for: .cursor,
            in: screen.visibleFrame,
            cursor: NSEvent.mouseLocation
        )
        var occupiedFrames: [NSRect] = []
        for controller in shelves {
            let point = ShelfGeometry.nonOverlappingOrigin(
                preferred: base,
                in: screen.visibleFrame,
                occupiedFrames: occupiedFrames
            )
            controller.window?.setFrameOrigin(point)
            occupiedFrames.append(NSRect(origin: point, size: ShelfGeometry.compactSize))
        }
    }

    private func debugLog(_ message: String) {
        if let data = (message + "\n").data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }
}
