import AppKit
import CoreGraphics
import Observation

@MainActor
@Observable
final class InputMonitoringPermissionService {
    enum State: Equatable {
        case notGranted
        case requiresRelaunch
        case active
    }

    private let wasGrantedAtLaunch: Bool
    private(set) var state: State

    init() {
        let granted = CGPreflightListenEventAccess()
        wasGrantedAtLaunch = granted
        state = granted ? .active : .notGranted
    }

    func refresh() {
        guard CGPreflightListenEventAccess() else {
            state = .notGranted
            return
        }
        state = wasGrantedAtLaunch ? .active : .requiresRelaunch
    }

    func requestAccess() {
        if !CGRequestListenEventAccess() {
            openSystemSettings()
        }
        refresh()
    }

    func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ListenEvent",
        ]
        for value in candidates {
            if let url = URL(string: value), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(
            at: Bundle.main.bundleURL,
            configuration: configuration
        ) { _, error in
            guard error == nil else { return }
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }

    var title: String {
        switch state {
        case .notGranted: "启用晃动与按键唤出"
        case .requiresRelaunch: "需要重新启动 DropPoint"
        case .active: "输入监控已启用"
        }
    }

    var detail: String {
        switch state {
        case .notGranted:
            "允许 DropPoint 在拖动文件时识别晃动和修饰键；不授权仍可使用全局快捷键和菜单栏。"
        case .requiresRelaunch:
            "系统已记录权限。重新启动后，当前进程才能稳定使用拖动唤出。"
        case .active:
            "拖动文件时可使用晃动或修饰键创建文件架。"
        }
    }

    var buttonTitle: String {
        switch state {
        case .notGranted: "启用…"
        case .requiresRelaunch: "重新启动"
        case .active: "管理…"
        }
    }

    func performPrimaryAction() {
        switch state {
        case .notGranted: requestAccess()
        case .requiresRelaunch: relaunch()
        case .active: openSystemSettings()
        }
    }
}
