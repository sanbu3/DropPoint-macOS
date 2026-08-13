import AppKit

@MainActor
enum ShelfContextMenuFactory {
    static func make(for store: ShelfStore) -> NSMenu {
        let handler = ShelfContextMenuHandler(store: store)
        let menu = RetainedShelfMenu(handler: handler)

        if store.instantActionsEnabled {
            for action in store.enabledActions {
                let item = NSMenuItem(
                    title: action.title,
                    action: #selector(ShelfContextMenuHandler.performAction(_:)),
                    keyEquivalent: ""
                )
                item.image = NSImage(systemSymbolName: action.systemImage, accessibilityDescription: nil)
                item.representedObject = action.rawValue
                item.target = handler
                menu.addItem(item)
            }

            if !store.customActions.isEmpty {
                let parent = NSMenuItem(title: "自定义操作", action: nil, keyEquivalent: "")
                let submenu = NSMenu()
                for action in store.customActions {
                    let item = NSMenuItem(
                        title: action.name,
                        action: #selector(ShelfContextMenuHandler.performCustomAction(_:)),
                        keyEquivalent: ""
                    )
                    item.representedObject = action.id.uuidString
                    item.target = handler
                    submenu.addItem(item)
                }
                parent.submenu = submenu
                menu.addItem(parent)
            }
            menu.addItem(.separator())
        }

        let clear = NSMenuItem(
            title: "清除全部文件",
            action: #selector(ShelfContextMenuHandler.clearShelf),
            keyEquivalent: ""
        )
        clear.target = handler
        menu.addItem(clear)

        let hide = NSMenuItem(
            title: "隐藏文件架",
            action: #selector(ShelfContextMenuHandler.hideShelf),
            keyEquivalent: ""
        )
        hide.target = handler
        menu.addItem(hide)
        return menu
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

    @objc func clearShelf() { store.clear() }
    @objc func hideShelf() { store.onCollapse?() }
}
