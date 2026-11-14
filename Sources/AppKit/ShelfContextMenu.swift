import AppKit

@MainActor
enum ShelfContextMenuFactory {
    static func make(for store: ShelfStore, isContextMenu: Bool = true) -> NSMenu {
        let handler = ShelfContextMenuHandler(store: store)
        let menu = RetainedShelfMenu(handler: handler)

        configure(menu)
        let hasSelection = !store.selectedItems.isEmpty && !store.isClosed && !store.isClearing && !store.isPullClearing

        func shows(_ option: ShelfMenuOption) -> Bool {
            !isContextMenu || !store.hiddenShelfMenuOptions.contains(option)
        }

        func actionItem(_ action: ShelfAction) -> NSMenuItem {
            let item = item(title: action.title, symbol: action.systemImage,
                            selector: #selector(ShelfContextMenuHandler.performAction(_:)), handler: handler)
            item.representedObject = action.rawValue
            item.isEnabled = hasSelection
            return item
        }
        func appendGroup(_ items: [NSMenuItem]) {
            guard !items.isEmpty else { return }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            items.forEach(menu.addItem)
        }

        if store.instantActionsEnabled {
            let enabled = store.enabledActions
            var viewing = enabled.filter { [.open, .reveal].contains($0) }.map(actionItem)
            if shows(.preview) {
                let preview = item(title: ShelfMenuOption.preview.title, symbol: ShelfMenuOption.preview.systemImage,
                                   selector: #selector(ShelfContextMenuHandler.previewFiles), handler: handler)
                preview.isEnabled = hasSelection
                viewing.append(preview)
            }
            if shows(.renameItem), hasSelection, store.selectedItems.count == 1 {
                let rename = item(title: "重命名项目…", symbol: "pencil",
                                  selector: #selector(ShelfContextMenuHandler.renameSelectedItem), handler: handler)
                viewing.append(rename)
            }
            if shows(.openWith), hasSelection, let openWith = openWithMenu(for: store, handler: handler) {
                viewing.append(openWith)
            }
            appendGroup(viewing)
            appendGroup(enabled.filter { [.airDrop, .messages, .mail].contains($0) }.map(actionItem))
            appendGroup(enabled.filter { [.copyPaths, .copyTo, .moveTo, .groupInFolder].contains($0) }.map(actionItem))
            appendGroup(enabled.filter { [.compressImages, .resizeImages, .createPDF, .archive].contains($0) }.map(actionItem))

            if shows(.customActions), !store.customActions.isEmpty {
                let parent = NSMenuItem(title: "自定义操作", action: nil, keyEquivalent: "")
                setImage(symbol("bolt"), on: parent)
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
            appendGroup(enabled.filter { $0 == .trash }.map(actionItem))
        }

        let renameShelf = item(title: "重命名文件架…", symbol: "pencil",
                               selector: #selector(ShelfContextMenuHandler.renameShelf), handler: handler)
        let colors = NSMenuItem(title: "文件架颜色", action: nil, keyEquivalent: "")
        setImage(symbol("paintpalette"), on: colors)
        let colorItems = ShelfTint.allCases.map { tint in
            let colorItem = NSMenuItem(title: tint.title,
                                       action: #selector(ShelfContextMenuHandler.setTint(_:)),
                                       keyEquivalent: "")
            colorItem.target = handler
            colorItem.representedObject = tint.rawValue
            setImage(tintSwatch(tint), on: colorItem)
            colorItem.state = tint == store.tint ? .on : .off
            return colorItem
        }
        let pin = item(
            title: store.isPinned ? "取消固定文件架" : "固定文件架",
            symbol: store.isPinned ? "pin.slash" : "pin",
            selector: #selector(ShelfContextMenuHandler.togglePin),
            handler: handler
        )
        let colorMenu = NSMenu(title: "文件架颜色")
        configure(colorMenu)
        colorItems.forEach(colorMenu.addItem)
        colors.submenu = colorMenu
        appendGroup([
            shows(.renameShelf) ? renameShelf : nil,
            shows(.colors) ? colors : nil,
            shows(.pin) ? pin : nil
        ].compactMap { $0 })

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
            if shows(.remove) { shelfItems.append(remove) }
            let up = item(title: "上移", symbol: "arrow.up",
                          selector: #selector(ShelfContextMenuHandler.moveSelectionUp), handler: handler)
            up.isEnabled = hasSelection
            if shows(.moveUp) { shelfItems.append(up) }
            let down = item(title: "下移", symbol: "arrow.down",
                            selector: #selector(ShelfContextMenuHandler.moveSelectionDown), handler: handler)
            down.isEnabled = hasSelection
            if shows(.moveDown) { shelfItems.append(down) }
        }
        if shows(.clear) { shelfItems.append(clear) }
        if shows(.hide) { shelfItems.append(hide) }
        appendGroup(shelfItems)
        return menu
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
        setImage(symbol("arrow.up.forward.app"), on: parent)
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
            setImage(icon, on: appItem)
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

    private static func setImage(_ image: NSImage?, on item: NSMenuItem) {
        item.image = image
        if #available(macOS 27.0, *) {
            item.preferredImageVisibility = .visible
        }
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
        setImage(symbol(name), on: item)
        item.target = handler
        return item
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
        if action == .groupInFolder {
            // Let AppKit finish tracking the context menu before another menu opens.
            DispatchQueue.main.async { [store] in store.perform(action) }
        } else {
            store.perform(action)
        }
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
