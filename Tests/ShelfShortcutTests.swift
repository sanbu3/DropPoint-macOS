import AppKit
import Carbon.HIToolbox
import XCTest
@testable import DropPoint

@MainActor
final class ShelfShortcutTests: XCTestCase {
    func testRecordsModifiedKeyAndRestoresItFromPreferences() throws {
        let event = try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control, .option],
            timestamp: 0, windowNumber: 0, context: nil,
            characters: "k", charactersIgnoringModifiers: "k",
            isARepeat: false, keyCode: UInt16(kVK_ANSI_K)
        ))
        let shortcut = try XCTUnwrap(ShelfShortcut(event: event))
        XCTAssertEqual(shortcut.label, "⌃⌥K")
        XCTAssertEqual(shortcut.modifiers, UInt32(controlKey | optionKey))
        XCTAssertFalse(shortcut.conflictsWithApp)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString))
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.shelfShortcut, .standard)
        settings.shelfShortcut = shortcut
        XCTAssertEqual(AppSettings(defaults: defaults).shelfShortcut, shortcut)
    }

    func testZIPArtworkIsBundledAndPlayable() throws {
        let artwork = try XCTUnwrap(ShelfArtworkPlayer.artwork(named: "ZIP File Icon"))
        XCTAssertGreaterThan(artwork.frames.count, 10)
        XCTAssertEqual(artwork.duration, 1.3, accuracy: 0.03)
    }
}
