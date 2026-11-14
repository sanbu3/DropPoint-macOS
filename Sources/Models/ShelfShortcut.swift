import AppKit
import Carbon.HIToolbox

struct ShelfShortcut: Codable, Equatable {
    let keyCode: UInt32
    let modifiers: UInt32
    let label: String

    static let standard = Self(keyCode: UInt32(kVK_Tab), modifiers: UInt32(shiftKey), label: "⇧Tab")

    init(keyCode: UInt32, modifiers: UInt32, label: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.label = label
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        let key = event.charactersIgnoringModifiers?.uppercased() ?? ""
        guard !event.isARepeat, !flags.isEmpty, !key.isEmpty else { return nil }
        let special: [Int: String] = [
            kVK_Tab: "Tab", kVK_Space: "空格", kVK_Return: "↩", kVK_Delete: "⌫",
            kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓"
        ]
        guard special[Int(event.keyCode)] != nil ||
              key.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) && !(0xF700...0xF8FF).contains($0.value) })
        else { return nil }
        let mapping: [(NSEvent.ModifierFlags, Int, String)] = [
            (.control, controlKey, "⌃"), (.option, optionKey, "⌥"),
            (.shift, shiftKey, "⇧"), (.command, cmdKey, "⌘")
        ]
        let active = mapping.filter { flags.contains($0.0) }
        self.init(keyCode: UInt32(event.keyCode), modifiers: active.reduce(0) { $0 | UInt32($1.1) },
                  label: active.map { $0.2 }.joined() + (special[Int(event.keyCode)] ?? key))
    }

    var conflictsWithApp: Bool {
        switch (Int(keyCode), Int(modifiers)) {
        case (kVK_ANSI_A, shiftKey | optionKey), (kVK_ANSI_T, cmdKey | shiftKey),
             (kVK_ANSI_S, cmdKey | shiftKey), (kVK_ANSI_N, cmdKey | shiftKey),
             (kVK_ANSI_V, cmdKey), (kVK_ANSI_W, cmdKey), (kVK_ANSI_Comma, cmdKey):
            true
        default: false
        }
    }
}
