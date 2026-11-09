import AppKit
import SwiftUI

private final class PermissionGuidePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Non-activating companion to System Settings. Window geometry is read without
/// requesting Accessibility or Screen Recording; only Input Monitoring is guided.
@MainActor
final class PermissionGuideWindowController: NSWindowController, NSWindowDelegate {
    private let permission: InputMonitoringPermissionService
    private let onClose: () -> Void
    private var pollTask: Task<Void, Never>?
    private var shownAt = Date()
    private var missingSince: Date?
    private var lastRefresh = Date.distantPast
    private var hasClosed = false

    init(permission: InputMonitoringPermissionService, onClose: @escaping () -> Void) {
        self.permission = permission
        self.onClose = onClose
        let panel = PermissionGuidePanel(
            contentRect: NSRect(x: 0, y: 0, width: 340, height: 112),
            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
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
        let hosting = NSHostingView(rootView: PermissionGuideView(
            permission: permission, onClose: { [weak panel] in panel?.close() }
        ))
        hosting.focusRingType = .none
        hosting.sizingOptions = []
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        hosting.layer?.cornerRadius = 18
        hosting.layer?.masksToBounds = true
        panel.contentView = hosting
        super.init(window: panel)
        panel.delegate = self
    }

    required init?(coder: NSCoder) { nil }

    func show() {
        shownAt = Date()
        missingSince = nil
        permission.openSystemSettings()
        updatePosition()
        pollTask?.cancel()
        pollTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { break }
                guard !Task.isCancelled else { break }
                self?.tick()
            }
        }
    }

    private func tick() {
        guard !hasClosed else { return }
        if Date().timeIntervalSince(lastRefresh) >= 1 {
            lastRefresh = Date()
            permission.refresh()
        }
        // Never tear down an AppKit dragging source from a timer callback.
        guard !containsActiveDrag(window?.contentView) else { return }
        if permission.state == .active || Date().timeIntervalSince(shownAt) > 120 {
            close()
            return
        }
        updatePosition()
    }

    private func updatePosition() {
        guard let window else { return }
        guard let settingsFrame = systemSettingsFrame() else {
            window.orderOut(nil)
            if missingSince == nil { missingSince = Date() }
            if Date().timeIntervalSince(missingSince!) > 6 { close() }
            return
        }
        missingSince = nil
        let screens = NSScreen.screens
        let screen = screens.max { a, b in
            a.frame.intersection(settingsFrame).size.area < b.frame.intersection(settingsFrame).size.area
        } ?? NSScreen.main
        guard let area = screen?.visibleFrame else { return }
        let size = window.frame.size
        // Prefer beneath Settings; use its right edge when vertical space is tight.
        var origin = NSPoint(x: settingsFrame.midX - size.width / 2, y: settingsFrame.minY - size.height - 10)
        if origin.y < area.minY {
            origin = NSPoint(x: settingsFrame.maxX + 10, y: settingsFrame.midY - size.height / 2)
            if origin.x + size.width > area.maxX {
                origin = NSPoint(x: settingsFrame.minX - size.width - 10, y: settingsFrame.midY - size.height / 2)
            }
        }
        origin.x = min(max(origin.x, area.minX + 8), area.maxX - size.width - 8)
        origin.y = min(max(origin.y, area.minY + 8), area.maxY - size.height - 8)
        if window.frame.origin != origin { window.setFrameOrigin(origin) }
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
            return NSRect(x: rect.minX, y: mainTop - rect.maxY, width: rect.width, height: rect.height)
        }
        return nil
    }

    private func containsActiveDrag(_ view: NSView?) -> Bool {
        guard let view else { return false }
        if let icon = view as? PermissionAppDragView, icon.isDragging { return true }
        return view.subviews.contains { containsActiveDrag($0) }
    }

    override func close() {
        guard !containsActiveDrag(window?.contentView) else { return }
        super.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !hasClosed else { return }
        hasClosed = true
        pollTask?.cancel()
        pollTask = nil
        // Release the owning controller after the window's delegate callback.
        Task { @MainActor [onClose] in onClose() }
    }

    deinit { pollTask?.cancel() }
}

private extension NSSize {
    var area: CGFloat { max(0, width) * max(0, height) }
}
