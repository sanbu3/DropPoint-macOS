import AppKit
import CoreGraphics
import Observation

@MainActor
@Observable
final class InputMonitoringPermissionService {
    typealias State = SystemPermissionState

    var onShowGuide: (() -> Void)?
    var onWillRelaunch: (() -> Void)?

    @ObservationIgnored private let preflight: () -> Bool
    private let wasGrantedAtLaunch: Bool
    private(set) var state: State {
        didSet {
            if oldValue != state { AppDiagnostics.record("input-monitoring-state", category: "Permission", fields: ["state": String(describing: state)]) }
        }
    }

    init(preflight: @escaping () -> Bool = { CGPreflightListenEventAccess() }) {
        self.preflight = preflight
        let granted = preflight()
        wasGrantedAtLaunch = granted
        state = granted ? .active : .notGranted
    }

    func refresh() {
        guard preflight() else {
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
        AppDiagnostics.record("input-monitoring-open-settings", category: "Permission")
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
        AppRelaunchService.relaunch { onWillRelaunch?() }
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
        case .notGranted:
            if let onShowGuide { onShowGuide() } else { requestAccess() }
        case .requiresRelaunch: relaunch()
        case .active: openSystemSettings()
        }
    }
}
