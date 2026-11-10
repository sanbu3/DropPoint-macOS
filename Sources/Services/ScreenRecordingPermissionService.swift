import AppKit
import CoreGraphics
import Observation

@MainActor
@Observable
final class ScreenRecordingPermissionService {
    enum State: Equatable {
        case notGranted
        case requiresRelaunch
        case active
    }

    var onWillRelaunch: (() -> Void)?

    private let wasGrantedAtLaunch: Bool
    private(set) var state: State {
        didSet {
            if oldValue != state { AppDiagnostics.record("screen-recording-state", category: "Permission", fields: ["state": String(describing: state)]) }
        }
    }

    init() {
        let granted = CGPreflightScreenCaptureAccess()
        wasGrantedAtLaunch = granted
        state = granted ? .active : .notGranted
    }

    func refresh() {
        guard CGPreflightScreenCaptureAccess() else {
            state = .notGranted
            return
        }
        state = wasGrantedAtLaunch ? .active : .requiresRelaunch
    }

    func requestAccess() {
        _ = CGRequestScreenCaptureAccess()
        refresh()
    }

    func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture",
        ]
        for value in candidates {
            if let url = URL(string: value), NSWorkspace.shared.open(url) { return }
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/System Settings.app"))
    }

    func performPrimaryAction() {
        switch state {
        case .notGranted: requestAccess()
        case .requiresRelaunch: relaunch()
        case .active: openSystemSettings()
        }
    }

    func relaunch() {
        AppRelaunchService.relaunch { onWillRelaunch?() }
    }

    var title: String {
        switch state {
        case .notGranted: "允许截取最近窗口"
        case .requiresRelaunch: "屏幕录制需要重新启动"
        case .active: "屏幕录制已启用"
        }
    }

    var detail: String {
        switch state {
        case .notGranted:
            "用于双 Command 截图。授权后，DropPoint 只会截取你触发命令时附近的窗口。"
        case .requiresRelaunch:
            "系统已记录权限。重新启动 DropPoint 后才能截取窗口。"
        case .active:
            "双 Command 可以截取最近的窗口并放入文件架。"
        }
    }

    var buttonTitle: String {
        switch state {
        case .notGranted: "授权…"
        case .requiresRelaunch: "重新启动"
        case .active: "管理…"
        }
    }
}
