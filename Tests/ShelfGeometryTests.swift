import AppKit
import XCTest
@testable import DropPoint

final class ShelfGeometryTests: XCTestCase {
    func testFixedPositionsRespectWorkAreaOrigin() {
        let area = NSRect(x: 100, y: 80, width: 1200, height: 800)
        let cursor = NSPoint(x: 500, y: 500)
        XCTAssertEqual(
            ShelfGeometry.origin(for: .topRight, in: area, cursor: cursor),
            NSPoint(x: 1102, y: 673)
        )
        XCTAssertEqual(
            ShelfGeometry.origin(for: .bottomLeft, in: area, cursor: cursor),
            NSPoint(x: 100, y: 80)
        )
    }

    func testCursorPlacementDoesNotCoverPointer() {
        let area = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let cursor = NSPoint(x: 500, y: 300)
        let origin = ShelfGeometry.origin(for: .cursor, in: area, cursor: cursor)
        XCTAssertEqual(origin, NSPoint(x: 401, y: 336))
    }

    func testSnapUsesAllFourVisibleEdges() {
        let area = NSRect(x: 10, y: 20, width: 1000, height: 700)
        let frame = NSRect(x: 18, y: 30, width: 198, height: 207)
        XCTAssertEqual(
            ShelfGeometry.snappedOrigin(frame: frame, in: area),
            NSPoint(x: 10, y: 20)
        )
    }

    func testQuickShelfStaysBelowTheStatusItemAndInsideTheVisibleFrame() {
        let area = NSRect(x: 100, y: 80, width: 1200, height: 800)
        let statusFrame = NSRect(x: 1180, y: 888, width: 24, height: 24)

        XCTAssertEqual(
            ShelfGeometry.quickShelfOrigin(statusFrame: statusFrame, in: area),
            NSPoint(x: 1093, y: 665)
        )
    }

    func testExpandedWindowKeepsNearestScreenEdges() {
        let area = NSRect(x: 100, y: 80, width: 1200, height: 800)
        let expanded = ShelfGeometry.expandedSize

        XCTAssertEqual(
            ShelfGeometry.resizedOrigin(
                frame: NSRect(x: 100, y: 673, width: 198, height: 207),
                targetSize: expanded,
                in: area
            ),
            NSPoint(x: 100, y: 490)
        )
        XCTAssertEqual(
            ShelfGeometry.resizedOrigin(
                frame: NSRect(x: 1102, y: 673, width: 198, height: 207),
                targetSize: expanded,
                in: area
            ),
            NSPoint(x: 868, y: 490)
        )
        XCTAssertEqual(
            ShelfGeometry.resizedOrigin(
                frame: NSRect(x: 100, y: 80, width: 198, height: 207),
                targetSize: expanded,
                in: area
            ),
            NSPoint(x: 100, y: 80)
        )
        XCTAssertEqual(
            ShelfGeometry.resizedOrigin(
                frame: NSRect(x: 1102, y: 80, width: 198, height: 207),
                targetSize: expanded,
                in: area
            ),
            NSPoint(x: 868, y: 80)
        )
    }

    func testCenteredWindowExpandsAroundItsCenter() {
        let area = NSRect(x: 100, y: 80, width: 1200, height: 800)
        let compact = NSRect(x: 601, y: 376.5, width: 198, height: 207)

        XCTAssertEqual(
            ShelfGeometry.resizedOrigin(
                frame: compact,
                targetSize: ShelfGeometry.expandedSize,
                in: area
            ),
            NSPoint(x: 484, y: 285)
        )
    }

    func testExpandedShelfUsesCompactInspectionSize() {
        XCTAssertEqual(ShelfGeometry.expandedSize, NSSize(width: 432, height: 390))
    }

    func testExpandedShelfHeightTracksVisibleRows() {
        XCTAssertEqual(ShelfGeometry.expandedSize(itemCount: 2), NSSize(width: 336, height: 224))
        XCTAssertEqual(ShelfGeometry.expandedSize(itemCount: 3), NSSize(width: 432, height: 224))
        XCTAssertEqual(ShelfGeometry.expandedSize(itemCount: 4).height, 344)
        XCTAssertEqual(ShelfGeometry.expandedSize(itemCount: 7).height, 390)
    }

    func testIdleSnapIncludesAnEmptyShelf() {
        XCTAssertTrue(ShelfIdlePolicy.shouldSchedule(delay: 15))
        XCTAssertFalse(ShelfIdlePolicy.shouldSchedule(delay: 0))
    }

    func testWatchedDirectoryShelvesAlwaysUseTopRight() {
        XCTAssertEqual(
            ShelfCreationSource.watchedDirectory.position(default: .cursor),
            .topRight
        )
    }

    func testDockedShelvesKeepTenPointsFromTheVisibleScreenEdges() {
        let visibleFrame = NSRect(x: 0, y: 0, width: 1000, height: 700)
        let dockingArea = ShelfGeometry.dockingArea(in: visibleFrame)

        XCTAssertEqual(dockingArea, NSRect(x: 10, y: 10, width: 980, height: 680))
        XCTAssertEqual(
            ShelfGeometry.origin(for: .topRight, in: dockingArea, cursor: .zero),
            NSPoint(x: 792, y: 483)
        )
    }

    func testNewShelvesChooseAVisibleNonOverlappingSlot() {
        let area = NSRect(x: 0, y: 0, width: 900, height: 700)
        let preferred = ShelfGeometry.origin(for: .topRight, in: area, cursor: .zero)
        let occupied = NSRect(origin: preferred, size: ShelfGeometry.compactSize)
        let next = ShelfGeometry.nonOverlappingOrigin(
            preferred: preferred,
            in: area,
            occupiedFrames: [occupied]
        )

        XCTAssertFalse(NSRect(origin: next, size: ShelfGeometry.compactSize).intersects(occupied))
        XCTAssertTrue(area.contains(NSRect(origin: next, size: ShelfGeometry.compactSize)))
    }
}

final class ExternalDragActivationStateTests: XCTestCase {
    func testShakeOnlyCreatesAShelfWhenNoUnclosedShelfExists() {
        XCTAssertTrue(ShelfActivationPolicy.allowsShakeSpawn(hasOpenShelf: false))
        XCTAssertTrue(ShelfActivationPolicy.allowsShakeSpawn(hasOpenShelf: true))
    }

    func testModifierCanActivateAfterTheDragHasAlreadyStarted() {
        var state = ExternalDragActivationState()

        XCTAssertFalse(state.activateForModifier(false))
        XCTAssertTrue(state.activateForModifier(true))
        XCTAssertFalse(state.activateForModifier(true), "A drag may create only one file shelf")
    }

    func testShakeActivationDoesNotRequireAQuickShelfFirst() {
        var state = ExternalDragActivationState()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let positions: [CGFloat] = [100, 140, 90, 145, 85, 150]
        var activated = false

        for (index, position) in positions.enumerated() {
            activated = state.activateForShake(
                x: position,
                date: start.addingTimeInterval(Double(index) * 0.05),
                sensitivity: .medium
            ) || activated
        }

        XCTAssertTrue(activated)
        XCTAssertTrue(state.didActivate)
    }

    func testHighSensitivityRecognizesASmallQuickShake() {
        var state = ExternalDragActivationState()
        let start = Date(timeIntervalSinceReferenceDate: 1_000)
        let positions: [CGFloat] = [100, 108, 101, 109]

        let activated = positions.enumerated().reduce(false) { result, sample in
            state.activateForShake(
                x: sample.element,
                date: start.addingTimeInterval(Double(sample.offset) * 0.05),
                sensitivity: .high
            ) || result
        }

        XCTAssertTrue(activated)
    }

    func testResetAllowsTheNextDragToActivate() {
        var state = ExternalDragActivationState()
        XCTAssertTrue(state.activateForModifier(true))
        state.reset()
        XCTAssertTrue(state.activateForModifier(true))
    }
}

final class AnimationResourceTests: XCTestCase {
    func testAnimatedSVGResourcesAreBundledWithLoopingTimelines() throws {
        for name in ["Cat_in_Box", "Empty Box"] {
            let url = try XCTUnwrap(Bundle.main.url(forResource: name, withExtension: "svg"))
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(source.contains("<animate"))
            XCTAssertTrue(source.contains("repeatCount=\"indefinite\""))
        }
    }
}

final class ClipboardServiceTests: XCTestCase {
    func testPlainTextFilePathsBecomeShelfURLs() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let first = URL(fileURLWithPath: #filePath)
        let second = first.deletingLastPathComponent()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("\(first.path)\n\(second.path)", forType: .string))

        XCTAssertEqual(
            Set(ClipboardService.fileURLs(from: pasteboard).map(\.standardizedFileURL)),
            Set([first.standardizedFileURL, second.standardizedFileURL])
        )
    }
}

@MainActor
final class FileDropImporterTests: XCTestCase {
    func testRawDraggedImageBecomesARealPNGFile() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 24, height: 24).fill()
        image.unlockFocus()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([image]))

        var imported: [URL] = []
        XCTAssertTrue(FileDropImporter.importFiles(from: pasteboard) { imported = $0 })
        let url = try XCTUnwrap(imported.first)
        XCTAssertEqual(url.pathExtension.lowercased(), "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }
}

final class WatchedFileCategoryTests: XCTestCase {
    func testImageAndDocumentCategoriesStayCoarseGrained() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropPointCategoryTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let image = directory.appendingPathComponent("Screenshot.png")
        let document = directory.appendingPathComponent("Notes.txt")
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: image)
        try Data("notes".utf8).write(to: document)

        XCTAssertTrue(WatchedFileCategory.screenshots.includes(image))
        XCTAssertFalse(WatchedFileCategory.screenshots.includes(document))
        XCTAssertTrue(WatchedFileCategory.documents.includes(document))
        XCTAssertFalse(WatchedFileCategory.documents.includes(image))
    }

    func testSensitivityNamesExplainRequiredGestureStrength() {
        XCTAssertEqual(ShakeSensitivity.high.title, "高敏感 · 轻微晃动")
        XCTAssertEqual(ShakeSensitivity.medium.title, "中度敏感 · 稍微晃动")
        XCTAssertEqual(ShakeSensitivity.low.title, "微弱敏感 · 剧烈晃动")
    }
}

@MainActor
final class AppSettingsTests: XCTestCase {
    func testApplyingOneDraftChangePersistsAndNotifiesOnce() throws {
        let suiteName = "DropPointNativeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        var notifications = 0
        settings.onChange = { notifications += 1 }

        var draft = SettingsDraft(settings)
        draft.alwaysOnTop.toggle()
        settings.apply(draft)

        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(defaults.bool(forKey: "alwaysOnTop"), draft.alwaysOnTop)

        settings.apply(draft)
        XCTAssertEqual(notifications, 1, "Applying an identical draft should be a no-op")
    }

    func testActionPreferencesRoundTripThroughUserDefaults() throws {
        let suiteName = "DropPointNativeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let settings = AppSettings(defaults: defaults)
        var draft = SettingsDraft(settings)
        draft.enabledActions = [.copyPaths, .archive, .trash]
        draft.customActions = [
            CustomShelfAction(
                name: "复制到测试目录",
                kind: .copyTo,
                destinationPath: "/tmp/DropPointTests"
            ),
        ]
        draft.shakeActivationEnabled = false
        draft.activationModifier = .option
        draft.watchedFileCategory = .screenshots
        draft.idleSnapDelay = .thirtySeconds
        settings.apply(draft)

        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.enabledActions, draft.enabledActions)
        XCTAssertEqual(restored.customActions, draft.customActions)
        XCTAssertFalse(restored.shakeActivationEnabled)
        XCTAssertEqual(restored.activationModifier, .option)
        XCTAssertEqual(restored.watchedFileCategory, .screenshots)
        XCTAssertEqual(restored.idleSnapDelay, .thirtySeconds)
    }
}

@MainActor
final class DirectoryWatcherTests: XCTestCase {
    func testWatcherReportsOnlyFilesAddedAfterStartup() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropPointWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let existing = directory.appendingPathComponent("existing.txt")
        let added = directory.appendingPathComponent("added.txt")
        try Data("existing".utf8).write(to: existing)

        let watcher = DirectoryWatcher()
        watcher.watchPaths = [directory.path]
        let received = expectation(description: "new file reported")
        var reported: [URL] = []
        watcher.onNewFiles = { urls in
            reported.append(contentsOf: urls)
            received.fulfill()
        }
        watcher.start()
        defer { watcher.stop() }

        try Data("added".utf8).write(to: added)
        await fulfillment(of: [received], timeout: 4)

        XCTAssertEqual(
            Set(reported.map(\.standardizedFileURL)),
            Set([added.standardizedFileURL])
        )
    }
}

@MainActor
final class ShelfActionServiceTests: XCTestCase {
    func testCopyPathsWritesEverySelectedPathToThePasteboard() throws {
        let first = URL(fileURLWithPath: #filePath)
        let second = first.deletingLastPathComponent()

        ShelfActionService.perform(.copyPaths, urls: [first, second])

        XCTAssertEqual(
            NSPasteboard.general.string(forType: .string),
            [first.standardizedFileURL.path, second.standardizedFileURL.path]
                .joined(separator: "\n")
        )
    }

    func testCustomCopyActionDoesNotOverwriteAnExistingFile() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropPointActionTests-\(UUID().uuidString)")
        let sourceDirectory = root.appendingPathComponent("Source")
        let destinationDirectory = root.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let source = sourceDirectory.appendingPathComponent("report.txt")
        let existing = destinationDirectory.appendingPathComponent("report.txt")
        try Data("new".utf8).write(to: source)
        try Data("existing".utf8).write(to: existing)

        let completed = expectation(description: "copy completed")
        let action = CustomShelfAction(
            name: "复制到测试目录",
            kind: .copyTo,
            destinationPath: destinationDirectory.path
        )
        ShelfActionService.perform(action, urls: [source]) { succeeded in
            XCTAssertTrue(succeeded)
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 4)

        XCTAssertEqual(try String(contentsOf: existing, encoding: .utf8), "existing")
        XCTAssertEqual(
            try String(
                contentsOf: destinationDirectory.appendingPathComponent("report 2.txt"),
                encoding: .utf8
            ),
            "new"
        )
    }
}

@MainActor
final class ShelfStoreTests: XCTestCase {
    func testClearPreservesFilesAddedDuringTheClearAnimation() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropPointNativeTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let original = directory.appendingPathComponent("original.txt")
        let addedDuringClear = directory.appendingPathComponent("new.txt")
        try Data("original".utf8).write(to: original)
        try Data("new".utf8).write(to: addedDuringClear)

        let store = ShelfStore()
        XCTAssertEqual(store.add(urls: [original]), 1)
        store.clear()
        XCTAssertEqual(store.add(urls: [addedDuringClear]), 1)

        try await Task.sleep(for: .milliseconds(320))
        XCTAssertEqual(store.items.map(\.url), [addedDuringClear.standardizedFileURL])
        XCTAssertFalse(store.isClearing)
    }

    func testRepeatedClearRequestsProduceOneEmptyTransition() async throws {
        let file = URL(fileURLWithPath: #filePath)
        let store = ShelfStore()
        var emptyTransitions = 0
        store.onEmptied = { emptyTransitions += 1 }

        XCTAssertEqual(store.add(urls: [file]), 1)
        store.clear()
        store.clear()

        try await Task.sleep(for: .milliseconds(320))
        XCTAssertEqual(emptyTransitions, 1)
        XCTAssertTrue(store.items.isEmpty)
    }
}
