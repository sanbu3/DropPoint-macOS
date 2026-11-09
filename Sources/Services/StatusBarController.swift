import AppKit

@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    let settings: AppSettings
    let manager: ShelfWindowManager

    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private lazy var menu: NSMenu = {
        NSMenu()
    }()

    init(settings: AppSettings, manager: ShelfWindowManager) {
        self.settings = settings
        self.manager = manager
        super.init()
        configureStatusItem()
        rebuildMenu()
    }

    func refresh() { rebuildMenu() }

    func setVisible(_ visible: Bool) {
        statusItem.isVisible = visible
    }

    private func configureStatusItem() {
        guard let button = statusItem.button else { return }
        if let url = Bundle.main.url(
            forResource: "DropPointLogo",
            withExtension: "svg"
        ), let image = NSImage(contentsOf: url) {
            image.size = NSSize(width: 15, height: 15)
            image.isTemplate = true
            button.image = image
        } else {
            button.image = NSImage(systemSymbolName: "shippingbox", accessibilityDescription: "DropPoint")
        }
        button.imageScaling = .scaleProportionallyDown
        button.imagePosition = .imageOnly
        button.toolTip = "DropPoint"
        menu.delegate = self
        statusItem.menu = menu
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        let newShelf = item(
            "新建文件架",
            action: #selector(newShelf),
            keyEquivalent: settings.shortcutAction == .spawn ? "\t" : "",
            modifiers: settings.shortcutAction == .spawn ? [.shift] : []
        )
        menu.addItem(newShelf)
        menu.addItem(item("截取最近窗口（双 Command）", action: #selector(captureWindow)))
        let clipboard = item(
            "从剪贴板创建文件架",
            action: #selector(clipboardShelf),
            keyEquivalent: "a",
            modifiers: [.option, .shift]
        )
        menu.addItem(clipboard)
        let restore = item(
            "恢复上一次关闭的内容",
            action: #selector(restoreLastClosed),
            keyEquivalent: "t",
            modifiers: [.command, .shift]
        )
        restore.isEnabled = manager.canRestoreLastClosedShelf
        menu.addItem(restore)
        menu.addItem(item(
            "显示/隐藏文件架",
            action: #selector(toggleShelves),
            keyEquivalent: settings.shortcutAction == .toggle ? "\t" : "",
            modifiers: settings.shortcutAction == .toggle ? [.shift] : []
        ))
        menu.addItem(item("关闭所有文件架", action: #selector(closeAll)))
        menu.addItem(.separator())
        addPinnedShelvesMenu()
        addRecentShelvesMenu()
        menu.addItem(.separator())
        menu.addItem(item(
            "设置…",
            action: #selector(showSettings),
            keyEquivalent: ",",
            modifiers: [.command]
        ))
        menu.addItem(.separator())
        menu.addItem(item("关于 DropPoint", action: #selector(showAbout)))
        let quit = NSMenuItem(title: "退出 DropPoint", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }

    private func item(
        _ title: String,
        action: Selector,
        keyEquivalent: String = "",
        modifiers: NSEvent.ModifierFlags = []
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        item.keyEquivalentModifierMask = modifiers
        return item
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }

    private func addPinnedShelvesMenu() {
        let parent = NSMenuItem(title: "固定文件架", action: nil, keyEquivalent: "")
        parent.image = symbol("pin")
        let submenu = NSMenu(title: "固定文件架")
        if settings.pinnedShelves.isEmpty {
            let empty = NSMenuItem(title: "暂无固定文件架", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for shelf in settings.pinnedShelves.prefix(10) {
                let item = NSMenuItem(
                    title: "\(shelf.displayName)（\(shelf.itemCount) 项）",
                    action: #selector(restorePinnedMenuItem(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = shelf.id.uuidString
                item.image = swatch(shelf.tint)
                submenu.addItem(item)
            }
            submenu.addItem(.separator())
            let clearPinned = NSMenuItem(
                title: "清除全部固定记录",
                action: #selector(clearPinnedShelves),
                keyEquivalent: ""
            )
            clearPinned.target = self
            submenu.addItem(clearPinned)
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func addRecentShelvesMenu() {
        let parent = NSMenuItem(title: "最近关闭", action: nil, keyEquivalent: "")
        parent.image = symbol("clock.arrow.circlepath")
        let submenu = NSMenu(title: "最近关闭")
        if settings.recentShelves.isEmpty {
            let empty = NSMenuItem(title: "暂无历史", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for shelf in settings.recentShelves.prefix(8) {
                let item = NSMenuItem(
                    title: "\(shelf.displayName)（\(shelf.subtitle)）",
                    action: #selector(restoreRecentMenuItem(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = shelf.id.uuidString
                item.image = swatch(shelf.tint)
                submenu.addItem(item)
            }
            submenu.addItem(.separator())
            let clearRecent = NSMenuItem(
                title: "清空最近关闭",
                action: #selector(clearRecentShelves),
                keyEquivalent: ""
            )
            clearRecent.target = self
            submenu.addItem(clearRecent)
        }
        parent.submenu = submenu
        menu.addItem(parent)
    }

    private func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .regular))
        image?.size = NSSize(width: 15, height: 15)
        return image
    }

    private func swatch(_ tint: ShelfTint) -> NSImage {
        let image = NSImage(size: NSSize(width: 12, height: 12))
        image.lockFocus()
        tint.nsColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 10, height: 10)).fill()
        image.unlockFocus()
        return image
    }

    @objc private func newShelf() { manager.spawn() }
    @objc private func captureWindow() { manager.captureNearestWindowToShelf() }

    @objc private func clearPinnedShelves() {
        manager.clearAllPinnedShelves()
        refresh()
    }

    @objc private func clearRecentShelves() {
        manager.clearRecentShelves()
        refresh()
    }

    @objc private func restorePinnedMenuItem(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let id = UUID(uuidString: value),
              let shelf = settings.pinnedShelves.first(where: { $0.id == id }) else { return }
        manager.restorePinnedShelf(shelf)
    }

    @objc private func restoreRecentMenuItem(_ sender: NSMenuItem) {
        guard let value = sender.representedObject as? String,
              let id = UUID(uuidString: value),
              let shelf = settings.recentShelves.first(where: { $0.id == id }) else { return }
        manager.restoreRecentShelf(shelf)
    }
    @objc private func toggleShelves() { manager.toggleShelves() }
    @objc private func closeAll() { manager.closeAll() }
    @objc private func showSettings() { manager.showSettings() }
    @objc private func restoreLastClosed() { manager.restoreLastClosedShelf() }

    @objc private func clipboardShelf() {
        Task { @MainActor [weak self] in
            let urls = await ClipboardService.fileURLs()
            if !urls.isEmpty { self?.manager.spawn(urls: urls) }
        }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        let version = Bundle.main.object(
            forInfoDictionaryKey: "CFBundleShortVersionString"
        ) as? String ?? "1.4.1"
        alert.messageText = "DropPoint \(version)"
        alert.informativeText = "适用于 macOS 的原生临时文件架。"
        alert.addButton(withTitle: "确定")
        alert.runModal()
    }
}
