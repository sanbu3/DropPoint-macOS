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

    var statusFrame: NSRect? {
        guard let button = statusItem.button, let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
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

    @objc private func newShelf() { manager.spawn() }
    @objc private func toggleShelves() { manager.toggleShelves() }
    @objc private func closeAll() { manager.closeAll() }
    @objc private func showSettings() { manager.showSettings() }
    @objc private func restoreLastClosed() { manager.restoreLastClosedShelf() }

    @objc private func clipboardShelf() {
        let urls = ClipboardService.fileURLs()
        if !urls.isEmpty { manager.spawn(urls: urls) }
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
