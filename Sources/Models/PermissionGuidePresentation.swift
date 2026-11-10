import AppKit
import Observation

@MainActor @Observable
final class PermissionGuidePresentation {
    enum Phase: Equatable { case idle, dragging, waiting, retry, complete(requiresRelaunch: Bool) }
    private(set) var phase: Phase = .idle
    private(set) var isDragging = false
    private var waitingSince: TimeInterval?
    var hasConfirmedGrant: Bool { if case .complete = phase { true } else { false } }

    func beginDrag() {
        guard !hasConfirmedGrant else { return }
        isDragging = true
        phase = .dragging
    }
    func endDrag(accepted: Bool, now: TimeInterval) {
        isDragging = false
        guard !hasConfirmedGrant else { return }
        phase = accepted ? .waiting : .retry
        waitingSince = accepted ? now : nil
    }
    func refresh(permission: InputMonitoringPermissionService.State, now: TimeInterval) {
        if permission != .notGranted {
            phase = .complete(requiresRelaunch: permission == .requiresRelaunch)
        } else if hasConfirmedGrant {
            phase = .idle
        } else if phase == .waiting, let waitingSince, now - waitingSince > 8 {
            phase = .retry
        }
    }
}

enum PermissionGuideGeometry {
    static let height: CGFloat = 100
    /// System Settings uses a fixed 246 pt sidebar and 20 pt content insets.
    static func frame(settings: NSRect, visible: NSRect, sidebarWidth: CGFloat = 246) -> NSRect {
        let inset: CGFloat = 20
        let width = min(max(280, settings.width - sidebarWidth - inset * 2), visible.width - 16)
        let x = min(max(settings.minX + sidebarWidth + inset, visible.minX + 8), visible.maxX - width - 8)
        let y = max(visible.minY + 8, min(settings.minY - height - 10, visible.maxY - height - 8))
        return NSRect(x: x, y: y, width: width, height: height)
    }
}
