import SwiftUI

@main
struct DropPointApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建浮动文件架") { appDelegate.newShelf() }
                    .keyboardShortcut("n", modifiers: .command)
                Button("从剪贴板新建文件架") { appDelegate.newShelfFromClipboard() }
                    .keyboardShortcut("n", modifiers: [.command, .shift])
                Button("截取最近窗口") { appDelegate.captureNearestWindow() }
                    .keyboardShortcut("6", modifiers: [.command, .shift])
            }

            CommandGroup(replacing: .appSettings) {
                Button("设置…") { appDelegate.showSettings() }
                    .keyboardShortcut(",", modifiers: .command)
            }

            CommandMenu("文件架") {
                Button("显示/隐藏文件架") { appDelegate.toggleShelves() }
                    .keyboardShortcut("s", modifiers: [.command, .shift])
                Button("恢复上次关闭的文件架") { appDelegate.restoreLastClosedShelf() }
                    .keyboardShortcut("t", modifiers: [.command, .shift])
                Divider()
                Button("关闭所有文件架") { appDelegate.closeAllShelves() }
            }
        }
    }
}
