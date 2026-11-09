import AppKit
import XCTest
@testable import DropPoint

@MainActor
final class ReleaseRegressionTests: XCTestCase {
    func testReleasingLeftCommandDoesNotLeaveAPhantomChord() throws {
        let monitor = DoubleCommandMonitor()
        var triggers = 0
        monitor.onTrigger = { triggers += 1 }
        let start = Date(timeIntervalSince1970: 100)
        func send(_ keyCode: UInt16, _ rawFlags: UInt, _ time: TimeInterval) throws {
            let event = try XCTUnwrap(NSEvent.keyEvent(
                with: .flagsChanged, location: .zero, modifierFlags: .init(rawValue: rawFlags),
                timestamp: time, windowNumber: 0, context: nil,
                characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: keyCode
            ))
            monitor.handle(event, timestamp: start.addingTimeInterval(time))
        }
        let command = NSEvent.ModifierFlags.command.rawValue
        try send(55, command | 0x08, 0)      // Left down.
        try send(54, command | 0x08 | 0x10, 0.1) // Both down.
        XCTAssertEqual(triggers, 1)
        try send(55, command | 0x10, 0.2)   // Left released while right remains down.
        try send(54, 0, 0.3)               // Right released.
        try send(54, command | 0x10, 2)     // Right alone must not capture.
        XCTAssertEqual(triggers, 1)
    }

    func testTwoCapturesOfSameWindowInSameSecondKeepBothImages() throws {
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ))
        let image = try XCTUnwrap(bitmap.cgImage)
        var files: [URL] = []
        defer { Set(files).forEach { try? FileManager.default.removeItem(at: $0) } }
        let title = "DropPoint-regression-\(UUID().uuidString)"
        for _ in 0..<2 {
            files.append(try WindowScreenshotService.savePNG(
                image, appName: "Fixture", windowTitle: title,
                timestamp: Date(timeIntervalSince1970: 1234)
            ))
        }
        XCTAssertNotEqual(files[0], files[1], "Captures must not overwrite an earlier shelf reference")
        XCTAssertTrue(files.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    func testUpgradePreservesExplicitDockAndLaunchPreferences() throws {
        let suite = "droppoint-upgrade-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(false, forKey: "showInDock")
        defaults.set(false, forKey: "spawnOnLaunch")
        let first = AppSettings(defaults: defaults)
        XCTAssertFalse(first.showInDock)
        XCTAssertFalse(first.spawnOnLaunch)
        let second = AppSettings(defaults: defaults)
        XCTAssertFalse(second.showInDock)
        XCTAssertFalse(second.spawnOnLaunch)
    }
    func testRelaunchHelperWaitsForOldProcessAndPreservesLiteralPaths() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("App with spaces ' $ literal.app")
        let opener = directory.appendingPathComponent("test opener")
        try "#!/bin/sh\n/usr/bin/touch \"$2\"\n".write(to: opener, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: opener.path)
        let oldProcess = Process()
        oldProcess.executableURL = URL(fileURLWithPath: "/bin/sleep")
        oldProcess.arguments = ["0.3"]
        try oldProcess.run()
        let helper = AppRelaunchService.makeHelper(
            waitingFor: oldProcess.processIdentifier, applicationURL: marker, openerURL: opener
        )
        try helper.run()
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        oldProcess.waitUntilExit()
        helper.waitUntilExit()
        XCTAssertEqual(helper.terminationStatus, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

}
