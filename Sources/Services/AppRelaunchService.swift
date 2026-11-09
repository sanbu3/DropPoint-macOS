import AppKit

@MainActor
enum AppRelaunchService {
    /// Wait for the old process to exit before registering the next process's
    /// global hotkeys. Paths stay separate shell arguments, including spaces.
    static func makeHelper(
        waitingFor pid: Int32,
        applicationURL: URL,
        openerURL: URL = URL(fileURLWithPath: "/usr/bin/open")
    ) -> Process {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", """
        attempt=0
        while /bin/kill -0 "$1" 2>/dev/null; do
            attempt=$((attempt + 1))
            if [ "$attempt" -ge 150 ]; then exit 1; fi
            /bin/sleep 0.1
        done
        exec "$3" -n "$2"
        """, "DropPointRelaunch", String(pid), applicationURL.path, openerURL.path]
        helper.standardOutput = FileHandle.nullDevice
        helper.standardError = FileHandle.nullDevice
        return helper
    }

    static func relaunch(beforeTermination: () -> Void = {}) {
        let helper = makeHelper(
            waitingFor: ProcessInfo.processInfo.processIdentifier,
            applicationURL: Bundle.main.bundleURL
        )
        do {
            try helper.run()
            beforeTermination()
            NSApp.terminate(nil)
        } catch {
            let alert = NSAlert()
            alert.messageText = "无法重新启动 DropPoint"
            alert.informativeText = "请从菜单退出后重新打开应用。\n\(error.localizedDescription)"
            alert.runModal()
        }
    }
}
