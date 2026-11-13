import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var settings: AppSettings = {
        let environment = ProcessInfo.processInfo.environment
        if environment["DROPPOINT_SNAPSHOT_DIR"] != nil,
           let defaults = UserDefaults(suiteName: "io.github.sanbu3.droppoint.snapshots") {
            defaults.removePersistentDomain(forName: "io.github.sanbu3.droppoint.snapshots")
            defaults.set(false, forKey: "spawnOnLaunch")
            defaults.set(true, forKey: "didEnableWindowModeV2")
            return AppSettings(defaults: defaults)
        }
        return AppSettings()
    }()
    private(set) var inputMonitoringPermission = InputMonitoringPermissionService()
    private(set) var screenRecordingPermission = ScreenRecordingPermissionService()
    private var manager: ShelfWindowManager!
    private var statusBar: StatusBarController!
    private var hotKeys: GlobalHotKeyMonitor!
    private var dragMonitor: ExternalFileDragMonitor!
    private var doubleCommandMonitor: DoubleCommandMonitor!
    private var directoryWatcher: DirectoryWatcher!
    private var screenshotWatcher: DirectoryWatcher!
    private var pendingOpenURLs: [URL] = []
    private var openBatchWorkItem: DispatchWorkItem?
    private let diagnosticsWatchdog = MainRunLoopWatchdog()

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDiagnostics.record("application-start")
        if #available(macOS 27, *) { AppDiagnostics.record("native-shelf-routing-compatibility-enabled", category: "Window") }
        diagnosticsWatchdog.start()
        AppDiagnostics.record("permission-initial-state", category: "Permission", fields: [
            "input": String(describing: inputMonitoringPermission.state),
            "screen": String(describing: screenRecordingPermission.state)])
        #if DEBUG
        if let appearance = ProcessInfo.processInfo.environment["DROPPOINT_SNAPSHOT_APPEARANCE"] {
            NSApp.appearance = NSAppearance(named: appearance == "light" ? .aqua : .darkAqua)
        }
        #endif
        Task.detached(priority: .utility) { FileDropImporter.cleanupStaleImports() }
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)

        manager = ShelfWindowManager(
            settings: settings,
            inputMonitoringPermission: inputMonitoringPermission,
            screenRecordingPermission: screenRecordingPermission
        )
        statusBar = StatusBarController(settings: settings, manager: manager)
        statusBar.setVisible(settings.showMenuBarIcon || !settings.showInDock)

        settings.onChange = { [weak self] in
            guard let self else { return }
            self.manager.updateAlwaysOnTop()
            self.manager.updateDragAction(self.settings.dragAction)
            self.manager.updateInteractions()
            self.dragMonitor.shakeActivationEnabled = self.settings.shakeActivationEnabled
            self.dragMonitor.modifierActivationEnabled = self.settings.modifierActivationEnabled
            self.dragMonitor.activationModifier = self.settings.activationModifier
            self.dragMonitor.sensitivity = self.settings.shakeSensitivity
            self.doubleCommandMonitor.isEnabled = self.settings.doubleCommandScreenshotEnabled
            self.directoryWatcher.fileCategory = self.settings.watchedFileCategory
            self.updateAutomaticCollectionWatchPaths()
            NSApp.setActivationPolicy(self.settings.showInDock ? .regular : .accessory)
            self.statusBar.setVisible(self.settings.showMenuBarIcon || !self.settings.showInDock)
            self.statusBar.refresh()
        }

        hotKeys = GlobalHotKeyMonitor()
        hotKeys.onMainShortcut = { [weak self] in
            guard let self else { return }
            if self.settings.shortcutAction == .toggle { self.manager.toggleShelves() }
            else { self.manager.spawn() }
        }
        hotKeys.onClipboardShortcut = { [weak self] in
            Task { @MainActor [weak self] in
                let urls = await ClipboardService.fileURLs()
                if !urls.isEmpty { self?.manager.spawn(urls: urls) }
            }
        }
        hotKeys.onRestoreShortcut = { [weak self] in
            self?.manager.restoreLastClosedShelf()
        }
        hotKeys.onHoveredShelfPasteShortcut = { [weak self] in
            self?.manager.pasteClipboardIntoHoveredShelf()
        }
        hotKeys.onHoveredShelfPreviewShortcut = { [weak self] in
            self?.manager.previewHoveredShelf()
        }
        manager.onPasteHoverAvailabilityChanged = { [weak self] available in
            self?.hotKeys.setHoveredShelfShortcutsEnabled(available)
        }
        hotKeys.start()
        if let errorMessage = hotKeys.registrationErrorMessage,
           ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            DispatchQueue.main.async { [weak self] in
                self?.showHotKeyRegistrationError(errorMessage)
            }
        }

        dragMonitor = ExternalFileDragMonitor()
        dragMonitor.shakeActivationEnabled = settings.shakeActivationEnabled
        dragMonitor.modifierActivationEnabled = settings.modifierActivationEnabled
        dragMonitor.activationModifier = settings.activationModifier
        dragMonitor.sensitivity = settings.shakeSensitivity
        dragMonitor.shouldIgnore = { [weak manager] in manager?.isInternalDragActive == true }
        dragMonitor.onModifierActivation = { [weak manager] in
            manager?.spawn(forcePosition: .cursor, transient: true)
        }
        dragMonitor.onShake = { [weak manager] in
            manager?.spawnFromShake()
        }
        dragMonitor.onFileDragEnd = { [weak manager] in
            manager?.finishExternalFileDrag()
        }
        dragMonitor.start()

        doubleCommandMonitor = DoubleCommandMonitor()
        doubleCommandMonitor.isEnabled = settings.doubleCommandScreenshotEnabled
        doubleCommandMonitor.onTrigger = { [weak self] in
            AppDiagnostics.record("capture-triggered", category: "Capture", fields: ["source": "both-command-keys"])
            self?.manager.captureNearestWindowToShelf()
        }
        doubleCommandMonitor.start()

        directoryWatcher = DirectoryWatcher()
        directoryWatcher.onError = { message in NSLog("DropPoint: %@", message) }
        directoryWatcher.onNewFiles = { [weak manager] urls in
            manager?.spawn(urls: urls, source: .watchedDirectory)
        }
        directoryWatcher.fileCategory = settings.watchedFileCategory

        screenshotWatcher = DirectoryWatcher()
        screenshotWatcher.onError = { message in NSLog("DropPoint: %@", message) }
        screenshotWatcher.ignoresReappearingFiles = true
        screenshotWatcher.fileFilter = { ScreenshotFileDetector.includes($0) }
        screenshotWatcher.onNewFiles = { [weak manager] urls in
            manager?.spawn(urls: urls, source: .screenshot)
        }

        updateAutomaticCollectionWatchPaths()
        directoryWatcher.start()
        screenshotWatcher.start()

        manager.onInternalDragActivityChanged = { [weak self] active in
            self?.directoryWatcher.setIgnoringChangesFromInternalDrag(active)
            self?.screenshotWatcher.setIgnoringChangesFromInternalDrag(active)
        }

        #if DEBUG
        let demoURLs = ProcessInfo.processInfo.environment["DROPPOINT_DEMO_FILES"]?
            .split(separator: ":")
            .map { URL(fileURLWithPath: String($0)) } ?? []
        if ProcessInfo.processInfo.environment["DROPPOINT_DEMO_DROP_GUIDE"] == "1" {
            let demoShelf = manager.spawn()
            demoShelf.store.updateDropTargeted(true, actions: ShelfStore.actionsForDrag(imagesOnly: true))
        } else if !demoURLs.isEmpty {
            let demoShelf = manager.spawn(urls: demoURLs)
            if ProcessInfo.processInfo.environment["DROPPOINT_DEMO_EXPANDED"] == "1",
               demoShelf.store.items.count > 1 {
                demoShelf.store.toggleExpanded()
            }
            if let countText = ProcessInfo.processInfo.environment["DROPPOINT_DEMO_SELECTED_COUNT"],
               let count = Int(countText),
               count > 1 {
                demoShelf.store.selectedIDs = Set(demoShelf.store.items.prefix(count).map(\.id))
            }
        }
        else if settings.spawnOnLaunch { manager.spawn() }
        #else
        if settings.spawnOnLaunch { manager.spawn() }
        #endif

        #if DEBUG
        let environment = ProcessInfo.processInfo.environment
        if let snapshotPath = environment["DROPPOINT_SNAPSHOT_DIR"] {
            let demoPaths = environment["DROPPOINT_DEMO_FILES"]?
                .split(separator: ":")
                .map { String($0) } ?? []
            manager.prepareDebugSnapshotContent(paths: demoPaths)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.manager.writeDebugSnapshots(to: URL(fileURLWithPath: snapshotPath))
                NSApp.terminate(nil)
            }
        }
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        AppDiagnostics.record("application-terminate-normal")
        diagnosticsWatchdog.stop()
        hotKeys?.stop()
        doubleCommandMonitor?.stop()
        dragMonitor?.stop()
        directoryWatcher?.stop()
        screenshotWatcher?.stop()
        AppDiagnostics.writer.flush()
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        AppDiagnostics.record("application-active")
        inputMonitoringPermission.refresh()
        screenRecordingPermission.refresh()
    }

    func showSettings() {
        manager?.showSettings()
    }

    func newShelf() {
        manager?.spawn()
    }

    func captureNearestWindow() {
        manager?.captureNearestWindowToShelf()
    }

    func newShelfFromClipboard() {
        Task { @MainActor [weak self] in
            let urls = await ClipboardService.fileURLs()
            if !urls.isEmpty { self?.manager?.spawn(urls: urls) }
            else { NSSound.beep() }
        }
    }

    func toggleShelves() {
        manager?.toggleShelves()
    }

    func closeAllShelves() {
        manager?.closeAll()
    }

    func restoreLastClosedShelf() {
        manager?.restoreLastClosedShelf()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if manager?.hasShelves == true {
            manager?.toggleShelves()
        } else {
            manager?.spawn()
        }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        AppDiagnostics.record("application-open-files", fields: ["count": String(urls.count)])
        enqueueOpenURLs(urls)
        application.reply(toOpenOrPrint: .success)
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        enqueueOpenURLs(filenames.map { URL(fileURLWithPath: $0) })
        sender.reply(toOpenOrPrint: .success)
    }

    /// LaunchServices can deliver one callback per file when several files are
    /// opened together. Batch them briefly so a multi-file open creates one
    /// shelf instead of several single-item shelves.
    private func enqueueOpenURLs(_ urls: [URL]) {
        let fileURLs = urls.filter(\.isFileURL)
        guard !fileURLs.isEmpty else { return }
        for url in fileURLs {
            let standardized = url.standardizedFileURL
            guard !pendingOpenURLs.contains(where: { $0.standardizedFileURL == standardized }) else { continue }
            pendingOpenURLs.append(standardized)
        }
        openBatchWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let batch = self.pendingOpenURLs
            self.pendingOpenURLs.removeAll()
            self.openBatchWorkItem = nil
            guard !batch.isEmpty else { return }
            self.manager?.spawn(urls: batch)
        }
        openBatchWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: item)
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let newShelf = NSMenuItem(
            title: "新建浮动文件架",
            action: #selector(showShelfFromDock),
            keyEquivalent: ""
        )
        newShelf.target = self
        menu.addItem(newShelf)
        let toggle = NSMenuItem(
            title: "显示/隐藏文件架",
            action: #selector(toggleShelvesFromDock),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)
        let settingsItem = NSMenuItem(
            title: "设置…",
            action: #selector(showSettingsFromDock),
            keyEquivalent: ""
        )
        settingsItem.target = self
        menu.addItem(settingsItem)
        return menu
    }

    @objc private func showShelfFromDock() {
        manager.spawn()
    }

    @objc private func toggleShelvesFromDock() {
        manager.toggleShelves()
    }

    @objc private func showSettingsFromDock() {
        manager.showSettings()
    }

    private func updateAutomaticCollectionWatchPaths() {
        guard let desktopURL = FileManager.default.urls(
            for: .desktopDirectory,
            in: .userDomainMask
        ).first else {
            directoryWatcher.watchPaths = settings.watchedDirectories
            screenshotWatcher.watchPaths = []
            return
        }

        let desktopPath = normalizedPath(desktopURL.path)
        if settings.screenshotDetectionEnabled {
            directoryWatcher.watchPaths = settings.watchedDirectories.filter {
                normalizedPath($0) != desktopPath
            }
            screenshotWatcher.watchPaths = [desktopURL.path]
        } else {
            directoryWatcher.watchPaths = settings.watchedDirectories
            screenshotWatcher.watchPaths = []
        }
    }

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private func showHotKeyRegistrationError(_ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "部分全局快捷键不可用"
        alert.informativeText = detail
        alert.addButton(withTitle: "好")
        alert.runModal()
    }
}
