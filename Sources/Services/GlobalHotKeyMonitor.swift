import Carbon.HIToolbox
import Foundation

@MainActor
final class GlobalHotKeyMonitor {
    enum HoveredShelfShortcutAction: Equatable {
        case paste
        case preview
    }

    struct HoveredShelfShortcutBinding: Equatable {
        let action: HoveredShelfShortcutAction
        let keyCode: UInt32
        let modifiers: UInt32
    }

    static let hoveredShelfShortcutBindings = [
        HoveredShelfShortcutBinding(
            action: .paste,
            keyCode: UInt32(kVK_ANSI_V),
            modifiers: UInt32(cmdKey)
        ),
        HoveredShelfShortcutBinding(
            action: .preview,
            keyCode: UInt32(kVK_Space),
            modifiers: 0
        ),
    ]

    var onMainShortcut: (() -> Void)?
    var onClipboardShortcut: (() -> Void)?
    var onRestoreShortcut: (() -> Void)?
    var onHoveredShelfPasteShortcut: (() -> Void)?
    var onHoveredShelfPreviewShortcut: (() -> Void)?

    private var eventHandler: EventHandlerRef?
    private var mainHotKey: EventHotKeyRef?
    private var clipboardHotKey: EventHotKeyRef?
    private var restoreHotKey: EventHotKeyRef?
    private var hoveredShelfPasteHotKey: EventHotKeyRef?
    private var hoveredShelfPreviewHotKey: EventHotKeyRef?
    private(set) var registrationErrors: [String] = []

    var registrationErrorMessage: String? {
        registrationErrors.isEmpty ? nil : registrationErrors.joined(separator: "\n")
    }

    func start() {
        guard eventHandler == nil else { return }
        registrationErrors.removeAll()

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        let handlerStatus = InstallEventHandler(
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
        guard handlerStatus == noErr else {
            registrationErrors.append("无法安装快捷键事件处理器（错误 \(handlerStatus)）")
            return
        }

        let signature = fourCharacterCode("DPNT")
        let mainID = EventHotKeyID(signature: signature, id: 1)
        let mainStatus = RegisterEventHotKey(
            UInt32(kVK_Tab),
            UInt32(shiftKey),
            mainID,
            GetApplicationEventTarget(),
            0,
            &mainHotKey
        )
        if mainStatus != noErr {
            registrationErrors.append("Shift+Tab 已被其他应用占用（错误 \(mainStatus)）")
        }

        let clipboardID = EventHotKeyID(signature: signature, id: 2)
        let clipboardStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_A),
            UInt32(shiftKey | optionKey),
            clipboardID,
            GetApplicationEventTarget(),
            0,
            &clipboardHotKey
        )
        if clipboardStatus != noErr {
            registrationErrors.append("⌥⇧A 已被其他应用占用（错误 \(clipboardStatus)）")
        }

        let restoreID = EventHotKeyID(signature: signature, id: 3)
        let restoreStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_T),
            UInt32(cmdKey | shiftKey),
            restoreID,
            GetApplicationEventTarget(),
            0,
            &restoreHotKey
        )
        if restoreStatus != noErr {
            registrationErrors.append("⇧⌘T 已被其他应用占用（错误 \(restoreStatus)）")
        }
    }

    func stop() {
        if let mainHotKey { UnregisterEventHotKey(mainHotKey) }
        if let clipboardHotKey { UnregisterEventHotKey(clipboardHotKey) }
        if let restoreHotKey { UnregisterEventHotKey(restoreHotKey) }
        if let hoveredShelfPasteHotKey { UnregisterEventHotKey(hoveredShelfPasteHotKey) }
        if let hoveredShelfPreviewHotKey { UnregisterEventHotKey(hoveredShelfPreviewHotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
        mainHotKey = nil
        clipboardHotKey = nil
        restoreHotKey = nil
        hoveredShelfPasteHotKey = nil
        hoveredShelfPreviewHotKey = nil
        eventHandler = nil
    }

    func setHoveredShelfShortcutsEnabled(_ enabled: Bool) {
        if !enabled {
            if let hoveredShelfPasteHotKey { UnregisterEventHotKey(hoveredShelfPasteHotKey) }
            if let hoveredShelfPreviewHotKey { UnregisterEventHotKey(hoveredShelfPreviewHotKey) }
            hoveredShelfPasteHotKey = nil
            hoveredShelfPreviewHotKey = nil
            return
        }
        guard eventHandler != nil else { return }

        let bindings = Self.hoveredShelfShortcutBindings
        if hoveredShelfPasteHotKey == nil {
            let pasteID = EventHotKeyID(signature: fourCharacterCode("DPNT"), id: 4)
            let status = RegisterEventHotKey(
                bindings[0].keyCode,
                bindings[0].modifiers,
                pasteID,
                GetApplicationEventTarget(),
                0,
                &hoveredShelfPasteHotKey
            )
            if status != noErr { hoveredShelfPasteHotKey = nil }
        }
        if hoveredShelfPreviewHotKey == nil {
            let previewID = EventHotKeyID(signature: fourCharacterCode("DPNT"), id: 5)
            let status = RegisterEventHotKey(
                bindings[1].keyCode,
                bindings[1].modifiers,
                previewID,
                GetApplicationEventTarget(),
                0,
                &hoveredShelfPreviewHotKey
            )
            if status != noErr { hoveredShelfPreviewHotKey = nil }
        }
    }

    private func handle(_ id: UInt32) {
        if id == 1 { onMainShortcut?() }
        else if id == 2 { onClipboardShortcut?() }
        else if id == 3 { onRestoreShortcut?() }
        else if id == 4 { onHoveredShelfPasteShortcut?() }
        else if id == 5 { onHoveredShelfPreviewShortcut?() }
    }

    private func fourCharacterCode(_ value: String) -> OSType {
        value.utf8.prefix(4).reduce(0) { ($0 << 8) | OSType($1) }
    }
}
