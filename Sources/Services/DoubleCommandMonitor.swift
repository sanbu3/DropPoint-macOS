import AppKit
import CoreGraphics
import IOKit.hidsystem

/// Detects the left + right Command chord. Global flags-changed events require
/// Input Monitoring, which DropPoint already asks for; a local monitor makes
/// the chord work while a shelf is active even if global monitoring is denied.
@MainActor
final class DoubleCommandMonitor {
    var onTrigger: (() -> Void)?
    var isEnabled = true

    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var chord = DoubleCommandChordState()

    func start() {
        guard globalMonitor == nil, localMonitor == nil else { return }
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            Task { @MainActor in self?.handle(event) }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.handle(event)
            return event
        }
    }

    func stop() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
        chord.release()
    }

    func handle(_ event: NSEvent, timestamp: Date = Date()) {
        guard isEnabled else {
            chord.release()
            return
        }
        // The aggregate .command flag stays set when either side is released.
        // Read Apple's device-specific flags as a complete snapshot instead of
        // retaining side booleans across events that can be missed.
        let raw = event.modifierFlags.rawValue
        let leftMask = UInt(NX_DEVICELCMDKEYMASK)
        let rightMask = UInt(NX_DEVICERCMDKEYMASK)
        let hasDeviceFlags = raw & (leftMask | rightMask) != 0
        let commandDown = event.modifierFlags.contains(.command)
        let left = commandDown && (hasDeviceFlags
            ? raw & leftMask != 0
            : CGEventSource.keyState(.combinedSessionState, key: 55))
        let right = commandDown && (hasDeviceFlags
            ? raw & rightMask != 0
            : CGEventSource.keyState(.combinedSessionState, key: 54))
        if chord.update(leftCommand: left, rightCommand: right, timestamp: timestamp) {
            onTrigger?()
        }
    }
}

/// Pure chord timing so the edge trigger and cooldown are testable without
/// relying on physical Command keys.
struct DoubleCommandChordState {
    static let cooldown: TimeInterval = 0.8

    private var isHeld = false
    private var lastTriggeredAt: Date?

    mutating func update(leftCommand: Bool, rightCommand: Bool, timestamp: Date) -> Bool {
        let both = leftCommand && rightCommand
        guard both else {
            isHeld = false
            return false
        }
        guard !isHeld else { return false }
        isHeld = true
        if let lastTriggeredAt,
           timestamp.timeIntervalSince(lastTriggeredAt) < Self.cooldown {
            return false
        }
        lastTriggeredAt = timestamp
        return true
    }

    mutating func release() {
        isHeld = false
    }
}
