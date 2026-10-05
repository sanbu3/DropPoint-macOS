import AppKit

@MainActor
enum ShelfContextMenuFactory {
    static func make(for store: ShelfStore) -> NSMenu {
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
        func appendGroup(_ items: [NSMenuItem]) {
            guard !items.isEmpty else { return }
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            items.forEach(menu.addItem)
        }

        if store.instantActionsEnabled {
            let enabled = store.enabledActions
            var viewing = enabled.filter { [.open, .reveal].contains($0) }.map(actionItem)
            let preview = item(title: "快速查看", symbol: "eye",
                               selector: #selector(ShelfContextMenuHandler.previewFiles), handler: handler)
            preview.isEnabled = hasSelection
            viewing.append(preview)
            appendGroup(viewing)
            appendGroup(enabled.filter { [.airDrop, .messages, .mail].contains($0) }.map(actionItem))
            appendGroup(enabled.filter { [.copyPaths, .copyTo, .moveTo].contains($0) }.map(actionItem))
            appendGroup(enabled.filter { [.compressImages, .createPDF, .archive].contains($0) }.map(actionItem))

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
            appendGroup(enabled.filter { $0 == .trash }.map(actionItem))
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
        }
        shelfItems.append(contentsOf: [clear, hide])
        appendGroup(shelfItems)
        return menu
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
}
