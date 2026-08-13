import Carbon.HIToolbox
import Foundation

@MainActor
final class GlobalHotKeyMonitor {
    var onMainShortcut: (() -> Void)?
    var onClipboardShortcut: (() -> Void)?
    var onRestoreShortcut: (() -> Void)?

    private var eventHandler: EventHandlerRef?
    private var mainHotKey: EventHotKeyRef?
    private var clipboardHotKey: EventHotKeyRef?
    private var restoreHotKey: EventHotKeyRef?

    func start() {
        guard eventHandler == nil else { return }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData -> OSStatus in
                guard let event, let userData else { return OSStatus(eventNotHandledErr) }
                var hotKeyID = EventHotKeyID()
                let status = GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )
                guard status == noErr else { return status }
                let monitor = Unmanaged<GlobalHotKeyMonitor>.fromOpaque(userData).takeUnretainedValue()
                Task { @MainActor in monitor.handle(hotKeyID.id) }
                return noErr
            },
            1,
            &eventType,
            Unmanaged.passUnretained(self).toOpaque(),
            &eventHandler
        )

        let signature = fourCharacterCode("DPNT")
        let mainID = EventHotKeyID(signature: signature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_Tab),
            UInt32(shiftKey),
            mainID,
            GetApplicationEventTarget(),
            0,
            &mainHotKey
        )

        let clipboardID = EventHotKeyID(signature: signature, id: 2)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_A),
            UInt32(shiftKey | optionKey),
            clipboardID,
            GetApplicationEventTarget(),
            0,
            &clipboardHotKey
        )

        let restoreID = EventHotKeyID(signature: signature, id: 3)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            UInt32(cmdKey | shiftKey),
            restoreID,
            GetApplicationEventTarget(),
            0,
            &restoreHotKey
        )
    }

    func stop() {
        if let mainHotKey { UnregisterEventHotKey(mainHotKey) }
        if let clipboardHotKey { UnregisterEventHotKey(clipboardHotKey) }
        if let restoreHotKey { UnregisterEventHotKey(restoreHotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        mainHotKey = nil
        clipboardHotKey = nil
        restoreHotKey = nil
        eventHandler = nil
    }

    private func handle(_ id: UInt32) {
        if id == 1 { onMainShortcut?() }
        else if id == 2 { onClipboardShortcut?() }
        else if id == 3 { onRestoreShortcut?() }
    }

    private func fourCharacterCode(_ value: String) -> OSType {
        value.utf8.prefix(4).reduce(0) { ($0 << 8) | OSType($1) }
    }
}
