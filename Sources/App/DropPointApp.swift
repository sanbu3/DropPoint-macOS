import SwiftUI

@main
struct DropPointApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            SettingsView(
                settings: appDelegate.settings,
                onDismiss: { NSApp.keyWindow?.close() }
            )
        }
    }
}
