import AppKit
import SwiftUI

private final class PermissionGuidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PermissionGuideWindowController: NSWindowController, NSWindowDelegate {
    private let permission: InputMonitoringPermissionService
    private let onClose: () -> Void
    private let onAuthorizationCompleted: () -> Void
    private let presentation = PermissionGuidePresentation()
    private let now: () -> TimeInterval
    private let openSettings: () -> Void
    private let closeSettings: (pid_t?) -> Void
    private var pollTask: Task<Void, Never>?
    private var shownAt: TimeInterval = 0
    private var missingSince: TimeInterval?
    private var completedAt: TimeInterval?
    private var settingsPID: pid_t?
    private var hasClosed = false
    private var closeRequested = false

    init(permission: InputMonitoringPermissionService,
         onAuthorizationCompleted: @escaping () -> Void = {},
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         openSettings: (() -> Void)? = nil,
         closeSettings: ((pid_t?) -> Void)? = nil,
         onClose: @escaping () -> Void) {
        self.permission = permission
        self.onClose = onClose
        self.onAuthorizationCompleted = onAuthorizationCompleted
        self.now = now
        self.openSettings = openSettings ?? { permission.openSystemSettings() }
        self.closeSettings = closeSettings ?? { pid in
            guard let pid, let app = NSRunningApplication(processIdentifier: pid),
                  app.bundleIdentifier == "com.apple.systempreferences" else { return }
            let accepted = app.terminate()
            AppDiagnostics.record("permission-settings-close-requested", category: "Permission", fields: ["accepted": String(accepted)])
        }
        let panel = PermissionGuidePanel(contentRect: NSRect(x: 0, y: 0, width: 468, height: PermissionGuideGeometry.height),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovableByWindowBackground = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.level = .floating
        panel.title = "DropPoint 输入监控"
        super.init(window: panel)
        let hosting = NSHostingView(rootView: PermissionGuideView(presentation: presentation,
            onClose: { [weak self] in self?.closeRequested = true }))
        hosting.focusRingType = .none
        hosting.sizingOptions = []
        hosting.autoresizingMask = [.width, .height]
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.cornerRadius = 18
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
        panel.delegate = self
    }
    required init?(coder: NSCoder) { nil }

    func show() {
        guard !hasClosed else { return }
        shownAt = now()
        missingSince = nil
        permission.refresh()
        if permission.state == .notGranted { openSettings() }
        AppDiagnostics.record("permission-guide-shown", category: "Permission", fields: ["state": String(describing: permission.state)])
        updatePosition(now: shownAt)
        tick()
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(200)) } catch { break }
                guard !Task.isCancelled else { break }
                self?.tick()
            }
        }
    }
    func tick() {
        guard !hasClosed else { return }
        let now = now()
        permission.refresh()
        presentation.refresh(permission: permission.state, now: now)
        // Keep the native source and its window alive through AppKit's end callback.
        guard !presentation.isDragging else { return }
        if closeRequested { close(); return }
        if presentation.hasConfirmedGrant {
            if completedAt == nil {
                completedAt = now
                AppDiagnostics.record("permission-guide-grant-confirmed", category: "Permission", fields: ["state": String(describing: permission.state)])
            }
            if now - (completedAt ?? now) >= 0.7 {
                let pid = settingsPID
                close()
                onAuthorizationCompleted()
                closeSettings(pid)
            }
            return
        }
        completedAt = nil
        if now - shownAt > 120 { close(); return }
        updatePosition(now: now)
    }
    private func updatePosition(now: TimeInterval) {
        guard let window else { return }
        guard let settingsFrame = systemSettingsFrame() else {
            window.orderOut(nil)
            if missingSince == nil { missingSince = now }
            if now - (missingSince ?? now) > 6 { close() }
            return
        }
        missingSince = nil
        let screen = NSScreen.screens.max {
            max(0, $0.frame.intersection(settingsFrame).width) * max(0, $0.frame.intersection(settingsFrame).height)
            < max(0, $1.frame.intersection(settingsFrame).width) * max(0, $1.frame.intersection(settingsFrame).height)
        } ?? NSScreen.main
        guard let visible = screen?.visibleFrame else { return }
        let frame = PermissionGuideGeometry.frame(settings: settingsFrame, visible: visible)
        if window.frame != frame { window.setFrame(frame, display: true) }
        window.orderFrontRegardless()
    }
    private func systemSettingsFrame() -> NSRect? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.systempreferences").first,
              !app.isHidden,
              let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let mainTop = NSScreen.screens.first?.frame.maxY else { return nil }
        for info in windows {
            guard (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == app.processIdentifier,
                  (info[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary), rect.width > 400, rect.height > 300 else { continue }
            settingsPID = app.processIdentifier
            return NSRect(x: rect.minX, y: mainTop - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }
    override func close() {
        guard !presentation.isDragging else { closeRequested = true; return }
        super.close()
    }
    func windowWillClose(_ notification: Notification) {
        guard !hasClosed else { return }
        hasClosed = true
        pollTask?.cancel()
        pollTask = nil
        AppDiagnostics.record("permission-guide-closed", category: "Permission", fields: ["authorized": String(presentation.hasConfirmedGrant)])
        Task { @MainActor [onClose] in onClose() }
    }
    deinit { pollTask?.cancel() }
}
