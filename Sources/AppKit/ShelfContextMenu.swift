import AppKit

@MainActor
enum ShelfContextMenuFactory {
    static func make(for store: ShelfStore, iconRows: Bool = false) -> NSMenu {
        let handler = ShelfContextMenuHandler(store: store)
        let menu = RetainedShelfMenu(handler: handler)

        configure(menu)
        let hasSelection = !store.selectedItems.isEmpty && !store.isClosed && !store.isClearing && !store.isPullClearing

        func actionItem(_ action: ShelfAction) -> NSMenuItem {
            let item = item(title: action.title, symbol: action.systemImage,
                            selector: #selector(ShelfContextMenuHandler.performAction(_:)), handler: handler)
            item.representedObject = action.rawValue
            item.isEnabled = hasSelection
            return item
        }
        func appendGroup(_ items: [NSMenuItem], keepingLabels: Bool = false) {
            guard !items.isEmpty else { return }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            guard iconRows, !keepingLabels else {
                items.forEach(menu.addItem)
                return
            }
            var row: [NSMenuItem] = []
            func flushRow() {
                guard !row.isEmpty else { return }
                menu.addItem(iconRow(row, in: menu))
                row.removeAll()
            }
            for item in items {
                if item.submenu != nil || item.image == nil {
                    flushRow()
                    menu.addItem(item)
                } else {
                    row.append(item)
                }
            }
            flushRow()
        }

        if store.instantActionsEnabled {
            let enabled = store.enabledActions
            var viewing = enabled.filter { [.open, .reveal].contains($0) }.map(actionItem)
            let preview = item(title: "快速查看", symbol: "eye",
                               selector: #selector(ShelfContextMenuHandler.previewFiles), handler: handler)
            preview.isEnabled = hasSelection
            viewing.append(preview)
            if hasSelection, store.selectedItems.count == 1 {
                let rename = item(title: "重命名项目…", symbol: "pencil",
                                  selector: #selector(ShelfContextMenuHandler.renameSelectedItem), handler: handler)
                viewing.append(rename)
            }
            if hasSelection, let openWith = openWithMenu(for: store, handler: handler) {
                viewing.append(openWith)
            }
            appendGroup(viewing)
            appendGroup(enabled.filter { [.airDrop, .messages, .mail].contains($0) }.map(actionItem))
            appendGroup(enabled.filter { [.copyPaths, .copyTo, .moveTo].contains($0) }.map(actionItem))
            appendGroup(enabled.filter { [.compressImages, .resizeImages, .createPDF, .archive].contains($0) }.map(actionItem))

            if !store.customActions.isEmpty {
                let parent = NSMenuItem(title: "自定义操作", action: nil, keyEquivalent: "")
                parent.image = symbol("bolt")
                let submenu = NSMenu(title: "自定义操作")
                configure(submenu)
                for action in store.customActions {
                    let item = item(title: action.name, symbol: action.kind.systemImage,
                                    selector: #selector(ShelfContextMenuHandler.performCustomAction(_:)), handler: handler)
                    item.representedObject = action.id.uuidString
                    item.isEnabled = hasSelection
                    submenu.addItem(item)
                }
                parent.submenu = submenu
                appendGroup([parent])
            }
            appendGroup(enabled.filter { $0 == .trash }.map(actionItem), keepingLabels: true)
        }

        var identityItems: [NSMenuItem] = []
        let renameShelf = item(title: "重命名文件架…", symbol: "pencil",
                               selector: #selector(ShelfContextMenuHandler.renameShelf), handler: handler)
        identityItems.append(renameShelf)
        let colors = NSMenuItem(title: "文件架颜色", action: nil, keyEquivalent: "")
        colors.image = symbol("paintpalette")
        let colorItems = ShelfTint.allCases.map { tint in
            let colorItem = NSMenuItem(title: tint.title,
                                       action: #selector(ShelfContextMenuHandler.setTint(_:)),
                                       keyEquivalent: "")
            colorItem.target = handler
            colorItem.representedObject = tint.rawValue
            colorItem.image = tintSwatch(tint)
            colorItem.state = tint == store.tint ? .on : .off
            return colorItem
        }
        let pin = item(
            title: store.isPinned ? "取消固定文件架" : "固定文件架",
            symbol: store.isPinned ? "pin.slash" : "pin",
            selector: #selector(ShelfContextMenuHandler.togglePin),
            handler: handler
        )
        identityItems.append(pin)
        appendGroup(identityItems)
        if iconRows {
            menu.addItem(iconRow(colorItems, in: menu, title: "文件架颜色"))
        } else {
            let colorMenu = NSMenu(title: "文件架颜色")
            configure(colorMenu)
            colorItems.forEach(colorMenu.addItem)
            colors.submenu = colorMenu
            menu.insertItem(colors, at: menu.numberOfItems - 1)
        }

        let clear = item(title: "清空文件架", symbol: "clear",
                         selector: #selector(ShelfContextMenuHandler.clearShelf), handler: handler)
        clear.isEnabled = !store.items.isEmpty && !store.isClosed && !store.isClearing && !store.isPullClearing
        let hide = item(title: "隐藏文件架", symbol: "rectangle.compress.vertical",
                        selector: #selector(ShelfContextMenuHandler.hideShelf), handler: handler)
        hide.isEnabled = !store.isClosed
        var shelfItems: [NSMenuItem] = []
        if store.isExpanded {
            let remove = item(title: "从文件架移除", symbol: "minus.circle",
                              selector: #selector(ShelfContextMenuHandler.removeSelection), handler: handler)
            remove.isEnabled = hasSelection
            shelfItems.append(remove)
            let up = item(title: "上移", symbol: "arrow.up",
                          selector: #selector(ShelfContextMenuHandler.moveSelectionUp), handler: handler)
            up.isEnabled = hasSelection
            shelfItems.append(up)
            let down = item(title: "下移", symbol: "arrow.down",
                            selector: #selector(ShelfContextMenuHandler.moveSelectionDown), handler: handler)
            down.isEnabled = hasSelection
            shelfItems.append(down)
        }
        if iconRows {
            shelfItems.append(hide)
            appendGroup(shelfItems)
            menu.addItem(clear)
            menu.addItem(.separator())
            let allActions = NSMenuItem(title: "所有操作", action: nil, keyEquivalent: "")
            allActions.image = symbol("list.bullet")
            allActions.submenu = make(for: store)
            menu.addItem(allActions)
        } else {
            shelfItems.append(contentsOf: [clear, hide])
            appendGroup(shelfItems)
        }
        return menu
    }

    private static func iconRow(
        _ commands: [NSMenuItem], in menu: NSMenu, title: String = "快捷操作"
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.view = ShelfMenuIconRow(commands: commands, menu: menu)
        return item
    }

    private static func openWithMenu(
        for store: ShelfStore,
        handler: ShelfContextMenuHandler
    ) -> NSMenuItem? {
        guard let url = store.selectedItems.first?.url else { return nil }
        let applications = NSWorkspace.shared
            .urlsForApplications(toOpen: url)
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        guard !applications.isEmpty else { return nil }
        let parent = NSMenuItem(title: "打开方式", action: nil, keyEquivalent: "")
        parent.image = symbol("arrow.up.forward.app")
        let submenu = NSMenu(title: "打开方式")
        configure(submenu)
        for application in applications.prefix(12) {
            let appItem = NSMenuItem(
                title: application.deletingPathExtension().lastPathComponent,
                action: #selector(ShelfContextMenuHandler.openWith(_:)),
                keyEquivalent: ""
            )
            appItem.target = handler
            appItem.representedObject = application
            let icon = NSWorkspace.shared.icon(forFile: application.path)
            icon.size = NSSize(width: 16, height: 16)
            appItem.image = icon
            submenu.addItem(appItem)
        }
        parent.submenu = submenu
        return parent
    }

    private static func tintSwatch(_ tint: ShelfTint) -> NSImage {
        let image = NSImage(size: NSSize(width: 14, height: 14))
        image.lockFocus()
        tint.nsColor.setFill()
        NSBezierPath(ovalIn: NSRect(x: 1, y: 1, width: 12, height: 12)).fill()
        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private static func configure(_ menu: NSMenu) {
        // Keep AppKit tracking, keyboard navigation and submenu behavior intact.
        menu.font = .systemFont(ofSize: 14)
        menu.minimumWidth = 230
        menu.autoenablesItems = false
    }

    private static func symbol(_ name: String) -> NSImage? {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .regular))
        image?.size = NSSize(width: 18, height: 18)
        return image
    }

    private static func item(title: String, symbol name: String, selector: Selector,
                             handler: ShelfContextMenuHandler) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.image = symbol(name)
        item.target = handler
        return item
    }

}

/// Keep native menu tracking while using ordinary controls for icon rows.
@MainActor
final class ShelfMenuIconRow: NSView {
    let commands: [NSMenuItem]
    private weak var owningMenu: NSMenu?

    init(commands: [NSMenuItem], menu: NSMenu) {
        self.commands = commands
        owningMenu = menu
        let buttonSize: CGFloat = 33
        let gap: CGFloat = 4
        let inset: CGFloat = 9
        super.init(frame: NSRect(x: 0, y: 0, width: 2 * inset + CGFloat(commands.count) * (buttonSize + gap) - gap, height: 37))
        for (index, command) in commands.enumerated() {
            let button = NSButton(frame: NSRect(x: inset + CGFloat(index) * (buttonSize + gap), y: 2, width: buttonSize, height: buttonSize))
            button.title = ""
            button.image = command.image
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleProportionallyDown
            button.bezelStyle = .texturedRounded
            button.showsBorderOnlyWhileMouseInside = command.state != .on
            button.setButtonType(.momentaryPushIn)
            button.toolTip = command.title
            button.setAccessibilityLabel(command.title)
            if command.state == .on { button.setAccessibilityValue("已选中") }
            button.isEnabled = command.isEnabled
            button.tag = index
            button.target = self
            button.action = #selector(activate(_:))
            addSubview(button)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    @objc private func activate(_ button: NSButton) {
        guard commands.indices.contains(button.tag) else { return }
        let command = commands[button.tag]
        guard command.isEnabled, let action = command.action, let target = command.target else { return }
        owningMenu?.cancelTracking()
        // Run modal operations after AppKit has unwound menu tracking.
        DispatchQueue.main.async {
            NSApp.sendAction(action, to: target, from: command)
        }
    }
}

@MainActor
private final class RetainedShelfMenu: NSMenu {
    let handler: ShelfContextMenuHandler

    init(handler: ShelfContextMenuHandler) {
        self.handler = handler
        super.init(title: "文件架操作")
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

@MainActor
private final class ShelfContextMenuHandler: NSObject {
    let store: ShelfStore

    init(store: ShelfStore) {
        self.store = store
    }

    @objc func performAction(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let action = ShelfAction(rawValue: rawValue) else { return }
        store.perform(action)
    }

    @objc func performCustomAction(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String,
              let action = store.customActions.first(where: { $0.id.uuidString == id }) else { return }
        store.perform(action)
    }

    @objc func removeSelection() { store.removeSelected() }
    @objc func previewFiles() { _ = store.previewSelection() }
    @objc func clearShelf() { store.clear() }
    @objc func hideShelf() { store.onCollapse?() }
    @objc func renameSelectedItem() { store.promptRenameSelected() }
    @objc func renameShelf() { store.promptRenameShelf() }
    @objc func togglePin() { store.requestPinToggle() }
    @objc func moveSelectionUp() { store.moveSelectedItems(by: -1) }
    @objc func moveSelectionDown() { store.moveSelectedItems(by: 1) }

    @objc func setTint(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let tint = ShelfTint(rawValue: rawValue) else { return }
        store.setTint(tint)
    }

    @objc func openWith(_ sender: NSMenuItem) {
        guard let application = sender.representedObject as? URL else { return }
        let urls = store.selectedItems.map(\.url)
        for url in urls {
            NSWorkspace.shared.open(
                [url],
                withApplicationAt: application,
                configuration: NSWorkspace.OpenConfiguration()
            ) { _, error in
                if let error {
                    NSLog("DropPoint: open with failed: %@", error.localizedDescription)
                }
            }
        }
    }
}
