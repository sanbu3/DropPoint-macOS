import AppKit
import QuickLookUI
import SwiftUI

@MainActor
private final class QuickLookPreviewController: NSObject, @preconcurrency QLPreviewPanelDataSource {
    private var urls: [URL] = []
    private weak var owner: ShelfWindowController?
    private var keyMonitor: Any?

    func show(_ url: URL, for owner: ShelfWindowController) {
        guard url.isFileURL, let panel = QLPreviewPanel.shared() else { return }
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
        guard urls.indices.contains(index) else { return nil }
        return urls[index] as NSURL
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

struct ShelfHoverPasteTargetState {
    private(set) var target: ObjectIdentifier?

    @discardableResult
    mutating func update(_ identifier: ObjectIdentifier, isInside: Bool) -> Bool {
        let wasAvailable = target != nil
        if isInside {
            target = identifier
        } else if target == identifier {
            target = nil
        }
        return wasAvailable != (target != nil)
    }
}

@MainActor
final class ShelfWindowManager {
    let settings: AppSettings
    let inputMonitoringPermission: InputMonitoringPermissionService
    var onInternalDragActivityChanged: ((Bool) -> Void)?
    var onPasteHoverAvailabilityChanged: ((Bool) -> Void)?
    private(set) var internalDragCount = 0

    private var shelves: [ShelfWindowController] = []
    private var settingsWindowController: NSWindowController?
    private let quickLookPreviewController = QuickLookPreviewController()
    private var emptyAutoCloseTimers: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var idleSnapTimers: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var postDropSnapTimers: [ObjectIdentifier: DispatchWorkItem] = [:]
    private var transientIDs = Set<ObjectIdentifier>()
    private var shakeGeneratedIDs = Set<ObjectIdentifier>()
    private var closedHistory: [[URL]] = []
    private var pasteTargetState = ShelfHoverPasteTargetState()

    init(
        settings: AppSettings,
        inputMonitoringPermission: InputMonitoringPermissionService
    ) {
        self.settings = settings
        self.inputMonitoringPermission = inputMonitoringPermission
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
        let controller = spawn(forcePosition: .cursor, transient: true)
        shakeGeneratedIDs.insert(ObjectIdentifier(controller))
        return controller
    }

    func finishExternalFileDrag() {
        let endedDragIDs = shakeGeneratedIDs
        guard !endedDragIDs.isEmpty else { return }
        let dropLocation = NSEvent.mouseLocation

        for controller in shelves {
            let identifier = ObjectIdentifier(controller)
            guard endedDragIDs.contains(identifier) else { continue }

            if controller.window?.frame.contains(dropLocation) == true {
                // Browser image drops may clear isDropTargeted and finish their
                // asynchronous pasteboard delivery after the global mouse-up.
                // Releasing inside this shelf is sufficient proof of intent.
                shakeGeneratedIDs.remove(identifier)
                continue
            }

            shakeGeneratedIDs.remove(identifier)
            if controller.store.items.isEmpty {
                controller.closeAnimated()
            }
        }
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
        let controller = makeShelf()
        let screen = targetScreen(for: resolvedPosition)
        let placementArea: NSRect
        switch source {
        case .manual:
            placementArea = screen?.visibleFrame ?? NSRect(origin: .zero, size: ShelfGeometry.compactSize)
        case .watchedDirectory, .screenshot:
            placementArea = ShelfGeometry.dockingArea(in: screen?.visibleFrame ?? NSRect(origin: .zero, size: ShelfGeometry.compactSize))
        }
        let base = ShelfGeometry.origin(
            for: resolvedPosition,
            in: placementArea,
            cursor: NSEvent.mouseLocation
        )
        let origin = cascadedOrigin(from: base, in: placementArea)
        shelves.append(controller)
        controller.show(at: origin, activating: false)
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
    }

    private func scheduleEmptyAutoClose(_ controller: ShelfWindowController) {
        cancelEmptyAutoClose(controller)
        let timeout = settings.emptyShelfTimeout
        guard timeout > 0, !controller.store.keepsEmptyShelfAfterOptionClear else { return }
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
            guard !controller.store.isDraggingOut, !controller.store.isDropTargeted,
                  !controller.store.isOptionClearActive, !controller.store.isDismissGestureActive else {
                self.scheduleIdleSnap(controller)
                return
            }
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

    private func schedulePostDropSnap(_ controller: ShelfWindowController) {
        cancelPostDropSnap(controller)
        guard settings.autoSnapAfterDrop else { return }

        let identifier = ObjectIdentifier(controller)
        let workItem = DispatchWorkItem { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.postDropSnapTimers.removeValue(forKey: identifier)
            guard self.settings.autoSnapAfterDrop,
                  self.shelves.contains(where: { $0 === controller }),
                  controller.window?.isVisible == true else { return }
            self.snapAfterDrop(controller)
        }
        postDropSnapTimers[identifier] = workItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, settings.autoSnapAfterDropDelay),
            execute: workItem
        )
    }

    private func cancelPostDropSnap(_ controller: ShelfWindowController) {
        postDropSnapTimers.removeValue(forKey: ObjectIdentifier(controller))?.cancel()
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
            for controller in shelves {
                controller.showExistingAnimated(activating: false)
            }
        }
    }

    func closeAll() { shelves.forEach { $0.closeAnimated() } }

    func restoreLastClosedShelf() {
        guard let urls = closedHistory.popLast(), !urls.isEmpty else { return }
        spawn(urls: urls)
    }

    func pasteClipboardIntoHoveredShelf() {
        guard let controller = hoveredShelfController() else { return }
        Task { @MainActor [weak self, weak controller] in
            let urls = await ClipboardService.fileURLs()
            guard let self, let controller, self.shelves.contains(where: { $0 === controller }) else { return }
            guard !urls.isEmpty else { NSSound.beep(); return }
            controller.store.add(urls: urls)
            self.cancelEmptyAutoClose(controller)
            self.scheduleIdleSnap(controller)
        }
    }

    func previewHoveredShelf() {
        guard let controller = hoveredShelfController() else { return }
        if quickLookPreviewController.isShowing(for: controller) {
            quickLookPreviewController.close(ifOwnedBy: controller)
            return
        }
        guard controller.store.previewSelection() else {
            NSSound.beep()
            return
        }
        scheduleIdleSnap(controller)
    }

    func updateAlwaysOnTop() {
        shelves.forEach { $0.setAlwaysOnTop(settings.alwaysOnTop) }
    }

    func updateDragAction(_ action: DragDefaultAction) {
        shelves.forEach { $0.store.dragAction = action }
    }

    func updateInteractions() {
        shelves.forEach { applySettings(to: $0.store) }
        shelves.forEach(scheduleIdleSnap)
    }

    func showSettings() {
        if let window = settingsWindowController?.window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let view = SettingsView(
            settings: settings,
            inputMonitoringPermission: inputMonitoringPermission,
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
        window.hasShadow = false
        window.isMovableByWindowBackground = true
        let hostingView = NSHostingView(rootView: view)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
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
        guard let screen = window.screen ?? targetScreen(for: .cursor) else { return }
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

    private func makeShelf() -> ShelfWindowController {
        let store = ShelfStore()
        applySettings(to: store)
        let controller = ShelfWindowController(
            store: store,
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
        store.onPreviewRequested = { [weak self, weak controller] url in
            guard let self, let controller else { return }
            self.quickLookPreviewController.show(url, for: controller)
        }
        store.onDropAccepted = { [weak self, weak controller] in
            guard let self, let controller else { return }
            let identifier = ObjectIdentifier(controller)
            self.cancelEmptyAutoClose(controller)
            self.transientIDs.remove(identifier)
            self.shakeGeneratedIDs.remove(identifier)
        }
        store.onDropFailed = { [weak self, weak controller] message in
            guard let self, let controller else { return }
            self.scheduleEmptyAutoClose(controller)
            self.showError(title: "无法接收拖入内容", detail: message, window: controller.window)
        }
        store.onDropSettled = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.cancelEmptyAutoClose(controller)
            self.scheduleIdleSnap(controller)
            let identifier = ObjectIdentifier(controller)
            self.transientIDs.remove(identifier)
            self.shakeGeneratedIDs.remove(identifier)
            self.schedulePostDropSnap(controller)
        }
        store.onEmptied = { [weak self, weak controller] in
            guard let self, let controller else { return }
            self.scheduleEmptyAutoClose(controller)
        }
        store.onInternalDragStateChanged = { [weak self] began in
            guard let self else { return }
            let wasActive = self.isInternalDragActive
            self.internalDragCount = max(0, self.internalDragCount + (began ? 1 : -1))
            let isActive = self.isInternalDragActive
            if isActive != wasActive {
                self.onInternalDragActivityChanged?(isActive)
            }
        }
        controller.onClosed = { [weak self] controller in self?.remove(controller) }
        controller.isPreviewActive = { [weak self, weak controller] in
            guard let self, let controller else { return false }
            return self.quickLookPreviewController.isShowing(for: controller)
        }
        controller.onWillDismiss = { [weak self] controller in
            guard let self else { return }
            self.clearPasteTarget(controller)
            self.quickLookPreviewController.close(ifOwnedBy: controller)
        }
        controller.onSnapRequested = { [weak self] controller in self?.snap(controller) }
        controller.onImmediateSnapRequested = { [weak self] controller in
            self?.snapAfterDrop(controller)
        }
        controller.onInteraction = { [weak self] controller in self?.scheduleIdleSnap(controller) }
        controller.onHoverChanged = { [weak self] controller, isInside in
            self?.updatePasteTarget(controller, isInside: isInside)
        }
        return controller
    }

    private func updatePasteTarget(_ controller: ShelfWindowController, isInside: Bool) {
        let changed = pasteTargetState.update(ObjectIdentifier(controller), isInside: isInside)
        if changed { onPasteHoverAvailabilityChanged?(pasteTargetState.target != nil) }
    }

    private func clearPasteTarget(_ controller: ShelfWindowController? = nil) {
        guard let target = pasteTargetState.target else { return }
        if let controller, ObjectIdentifier(controller) != target { return }
        if pasteTargetState.update(target, isInside: false) {
            onPasteHoverAvailabilityChanged?(false)
        }
    }

    private func hoveredShelfController() -> ShelfWindowController? {
        guard let target = pasteTargetState.target,
              let controller = shelves.first(where: { ObjectIdentifier($0) == target }),
              controller.window?.isVisible == true,
              controller.window?.frame.contains(NSEvent.mouseLocation) == true else {
            clearPasteTarget()
            return nil
        }
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

    private func remove(_ controller: ShelfWindowController) {
        clearPasteTarget(controller)
        let urls = controller.store.items.map(\.url)
        if !urls.isEmpty {
            closedHistory.append(urls)
            if closedHistory.count > 10 { closedHistory.removeFirst() }
        }
        cancelEmptyAutoClose(controller)
        cancelIdleSnap(controller)
        cancelPostDropSnap(controller)
        let identifier = ObjectIdentifier(controller)
        transientIDs.remove(identifier)
        shakeGeneratedIDs.remove(identifier)
        shelves.removeAll { $0 === controller }
    }

    private func targetScreen(for position: ShelfPosition) -> NSScreen? {
        if position == .cursor {
            let cursor = NSEvent.mouseLocation
            return NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.screens.first ?? NSScreen.main
        }
        return NSScreen.screens.first ?? NSScreen.main
    }

    private func cascadedOrigin(from base: NSPoint, in workArea: NSRect) -> NSPoint {
        ShelfGeometry.nonOverlappingOrigin(
            preferred: base,
            in: workArea,
            occupiedFrames: shelves.compactMap(\.window?.frame)
        )
    }

    private func repositionNearCursor() {
        guard let screen = targetScreen(for: .cursor) else { return }
        let base = ShelfGeometry.origin(
            for: .cursor,
            in: screen.visibleFrame,
            cursor: NSEvent.mouseLocation
        )
        let origins = Self.repositionedOrigins(
            base: base,
            in: screen.visibleFrame,
            windowSizes: shelves.map { $0.window?.frame.size ?? ShelfGeometry.compactSize }
        )
        for (controller, point) in zip(shelves, origins) {
            controller.window?.setFrameOrigin(point)
        }
    }

    static func repositionedOrigins(
        base: NSPoint,
        in workArea: NSRect,
        windowSizes: [NSSize]
    ) -> [NSPoint] {
        var occupiedFrames: [NSRect] = []
        return windowSizes.map { size in
            let point = ShelfGeometry.nonOverlappingOrigin(
                preferred: base,
                size: size,
                in: workArea,
                occupiedFrames: occupiedFrames
            )
            occupiedFrames.append(NSRect(origin: point, size: size))
            return point
        }
    }

    private func debugLog(_ message: String) {
        guard settings.debug else { return }
        if let data = (message + "\n").data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
    }

    private func showError(title: String, detail: String, window: NSWindow?) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        if let window { alert.beginSheetModal(for: window) }
        else { alert.runModal() }
    }
}
