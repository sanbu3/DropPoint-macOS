import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private(set) var settings = AppSettings()
    private var manager: ShelfWindowManager!
    private var statusBar: StatusBarController!
    private var hotKeys: GlobalHotKeyMonitor!
    private var dragMonitor: ExternalFileDragMonitor!
    private var directoryWatcher: DirectoryWatcher!
    private var screenshotWatcher: DirectoryWatcher!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(settings.showInDock ? .regular : .accessory)

        manager = ShelfWindowManager(settings: settings)
        statusBar = StatusBarController(settings: settings, manager: manager)
        manager.statusFrameProvider = { [weak statusBar] in statusBar?.statusFrame }
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
            let urls = ClipboardService.fileURLs()
            if !urls.isEmpty { self?.manager.spawn(urls: urls) }
        }
        hotKeys.onRestoreShortcut = { [weak self] in
            self?.manager.restoreLastClosedShelf()
        }
        hotKeys.start()

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
        dragMonitor.start()

        directoryWatcher = DirectoryWatcher()
        directoryWatcher.onNewFiles = { [weak manager] urls in
            manager?.spawn(urls: urls, source: .watchedDirectory)
        }
        directoryWatcher.fileCategory = settings.watchedFileCategory

        screenshotWatcher = DirectoryWatcher()
        screenshotWatcher.fileFilter = ScreenshotFileDetector.includes
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
            demoShelf.store.isDropTargeted = true
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotKeys?.stop()
        dragMonitor?.stop()
        directoryWatcher?.stop()
        screenshotWatcher?.stop()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !manager.hasShelves { manager.spawn() }
        else { manager.toggleShelves() }
        return true
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let newShelf = NSMenuItem(
            title: "新建文件架",
            action: #selector(showShelfFromDock),
            keyEquivalent: ""
        )
        newShelf.target = self
        menu.addItem(newShelf)
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
}
