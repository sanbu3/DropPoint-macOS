import AppKit
import Carbon.HIToolbox
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

    func testShakeActivationDoesNotRequirePriming() {
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

final class ShelfHoverPasteTargetStateTests: XCTestCase {
    func testLeavingAnOlderShelfDoesNotClearTheCurrentPasteTarget() {
        var state = ShelfHoverPasteTargetState()
        let firstObject = NSObject()
        let secondObject = NSObject()
        let first = ObjectIdentifier(firstObject)
        let second = ObjectIdentifier(secondObject)

        XCTAssertTrue(state.update(first, isInside: true))
        XCTAssertFalse(state.update(second, isInside: true))
        XCTAssertFalse(state.update(first, isInside: false))
        XCTAssertEqual(state.target, second)
        XCTAssertTrue(state.update(second, isInside: false))
        XCTAssertNil(state.target)
    }
}

final class HoveredShelfShortcutBindingTests: XCTestCase {
    func testHoveringAShelfClaimsPasteAndUnmodifiedSpace() {
        XCTAssertEqual(
            GlobalHotKeyMonitor.hoveredShelfShortcutBindings,
            [
                .init(action: .paste, keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey)),
                .init(action: .preview, keyCode: UInt32(kVK_Space), modifiers: 0),
            ]
        )
    }
}

@MainActor
final class ExternalFileDragMonitorTests: XCTestCase {
    func testPollingRecognizesPasteboardPublishedAfterMouseDragEvent() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let monitor = ExternalFileDragMonitor(dragPasteboard: pasteboard)
        monitor.beginPotentialDrag(at: .zero)

        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png))
        monitor.samplePasteboard(
            mouseButtonPressed: true,
            mouseLocation: NSPoint(x: 12, y: 0)
        )

        XCTAssertTrue(monitor.activeFileDrag)
    }

    func testPollingCanCompleteShakeActivationWithoutMoreDragEvents() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let monitor = ExternalFileDragMonitor(dragPasteboard: pasteboard)
        monitor.sensitivity = .high
        var shakeCount = 0
        monitor.onShake = { shakeCount += 1 }
        monitor.beginPotentialDrag(at: .zero)
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png))

        for x in [100.0, 108.0, 101.0, 109.0] {
            monitor.samplePasteboard(
                mouseButtonPressed: true,
                mouseLocation: NSPoint(x: x, y: 0)
            )
        }

        XCTAssertEqual(shakeCount, 1)
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

@MainActor
final class ClipboardServiceTests: XCTestCase {
    func testPlainTextFilePathsBecomeShelfURLs() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let first = URL(fileURLWithPath: #filePath)
        let second = first.deletingLastPathComponent()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString("\(first.path)\n\(second.path)", forType: .string))

        let urls = await ClipboardService.fileURLs(from: pasteboard)
        XCTAssertEqual(
            Set(urls.map(\.standardizedFileURL)),
            Set([first.standardizedFileURL, second.standardizedFileURL])
        )
    }
}

@MainActor
final class FileDropImporterTests: XCTestCase {
    func testRawDraggedImageBecomesARealPNGFile() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 24, height: 24).fill()
        image.unlockFocus()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([image]))

        let received = expectation(description: "import delivered")
        var imported: [URL] = []
        XCTAssertTrue(FileDropImporter.importFiles(from: pasteboard) { event in
            if case .imported(let urls) = event { imported = urls }
            received.fulfill()
        })
        await fulfillment(of: [received], timeout: 5)
        let url = try XCTUnwrap(imported.first)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(url.pathExtension.lowercased(), "png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testDirectJPEGDragIsRegisteredRecognizedAndImported() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 24, height: 24))
        image.lockFocus()
        NSColor.systemPink.setFill()
        NSRect(x: 0, y: 0, width: 24, height: 24).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let jpeg = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
        let jpegType = NSPasteboard.PasteboardType("public.jpeg")
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setData(jpeg, forType: jpegType))

        XCTAssertTrue(FileDropImporter.readableTypes.contains(jpegType))
        XCTAssertTrue(FileDropImporter.canImport(from: pasteboard))
        let received = expectation(description: "import delivered")
        var imported: [URL] = []
        XCTAssertTrue(FileDropImporter.importFiles(from: pasteboard) { event in
            if case .imported(let urls) = event { imported = urls }
            received.fulfill()
        })
        await fulfillment(of: [received], timeout: 5)
        let url = try XCTUnwrap(imported.first)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(url.pathExtension.lowercased(), "png")
    }

    func testDraggedWebElementBecomesAWebLocationFile() async throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let sourceURL = "https://www.douyin.com/video/123456"
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.setString(sourceURL, forType: .URL))

        XCTAssertTrue(FileDropImporter.canImport(from: pasteboard))
        let received = expectation(description: "import delivered")
        var imported: [URL] = []
        XCTAssertTrue(FileDropImporter.importFiles(from: pasteboard) { event in
            if case .imported(let urls) = event { imported = urls }
            received.fulfill()
        })
        await fulfillment(of: [received], timeout: 5)
        let url = try XCTUnwrap(imported.first)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertEqual(url.pathExtension.lowercased(), "webloc")
        let data = try Data(contentsOf: url)
        let plist = try XCTUnwrap(
            PropertyListSerialization.propertyList(from: data, format: nil) as? [String: String]
        )
        XCTAssertEqual(plist["URL"], sourceURL)
    }

    func testStaleImportedDirectoriesAreRemovedWithoutTouchingRecentOnes() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropPointImportCleanupTests-\(UUID().uuidString)")
        let stale = root.appendingPathComponent("stale", isDirectory: true)
        let recent = root.appendingPathComponent("recent", isDirectory: true)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let now = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-9 * 24 * 60 * 60)],
            ofItemAtPath: stale.path
        )
        FileDropImporter.cleanupStaleImports(rootDirectory: root, now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
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

    func testExistingActionPreferencesGainImageCompressionOnlyOnce() throws {
        let suiteName = "DropPointNativeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set([ShelfAction.copyPaths.rawValue], forKey: "enabledActions")

        let migrated = AppSettings(defaults: defaults)
        XCTAssertEqual(migrated.enabledActions, [.copyPaths, .compressImages])

        migrated.enabledActions = [.copyPaths]
        let restored = AppSettings(defaults: defaults)
        XCTAssertEqual(restored.enabledActions, [.copyPaths])
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
        let ready = expectation(description: "directory baseline ready")
        watcher.onReady = { ready.fulfill() }
        watcher.start()
        defer { watcher.stop() }
        await fulfillment(of: [ready], timeout: 3)

        try Data("added".utf8).write(to: added)
        await fulfillment(of: [received], timeout: 4)

        XCTAssertEqual(
            Set(reported.map(\.standardizedFileURL)),
            Set([added.standardizedFileURL])
        )
    }

    func testWatcherFlushesWhileFilesContinueArriving() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropPointBusyWatcherTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let watcher = DirectoryWatcher()
        watcher.watchPaths = [directory.path]
        let received = expectation(description: "busy directory still flushes")
        watcher.onNewFiles = { urls in
            if !urls.isEmpty { received.fulfill() }
        }
        let ready = expectation(description: "directory baseline ready")
        watcher.onReady = { ready.fulfill() }
        watcher.start()
        defer { watcher.stop() }
        await fulfillment(of: [ready], timeout: 3)

        let writer = Task {
            for index in 0..<8 {
                let file = directory.appendingPathComponent("file-\(index).txt")
                try Data("\(index)".utf8).write(to: file)
                try await Task.sleep(for: .milliseconds(300))
            }
        }
        await fulfillment(of: [received], timeout: 2.1)
        writer.cancel()
    }
}

@MainActor
final class ShelfActionServiceTests: XCTestCase {
    func testImageCompressionMeetsTargetByAdjustingQualityAndDimensions() throws {
        let width = 700
        let height = 700
        var pixels = Data(count: width * height * 4)
        pixels.withUnsafeMutableBytes { rawBuffer in
            guard let bytes = rawBuffer.bindMemory(to: UInt8.self).baseAddress else { return }
            var state: UInt32 = 0x1234_5678
            for offset in stride(from: 0, to: width * height * 4, by: 4) {
                state = state &* 1_664_525 &+ 1_013_904_223
                bytes[offset] = UInt8(truncatingIfNeeded: state >> 16)
                bytes[offset + 1] = UInt8(truncatingIfNeeded: state >> 8)
                bytes[offset + 2] = UInt8(truncatingIfNeeded: state)
                bytes[offset + 3] = 255
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: pixels as CFData))
        let image = try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ))
        let targetBytes = 45 * 1_024

        let result = try ImageCompressionService.compress(
            image: image,
            originalByteCount: pixels.count,
            targetBytes: targetBytes
        )

        XCTAssertTrue(result.didMeetTarget)
        XCTAssertLessThanOrEqual(result.data.count, targetBytes)
        XCTAssertLessThan(result.pixelWidth, width)
        XCTAssertEqual(Array(result.data.prefix(2)), [0xFF, 0xD8])
    }

    func testImageCompressionRejectsTargetsBelowTenKilobytes() throws {
        let provider = try XCTUnwrap(CGDataProvider(data: Data(repeating: 255, count: 16 * 16 * 4) as CFData))
        let image = try XCTUnwrap(CGImage(
            width: 16,
            height: 16,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: 16 * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))

        XCTAssertThrowsError(try ImageCompressionService.compress(
            image: image,
            targetBytes: 9 * 1_024
        ))
    }

    func testPDFComposerSkipsUnreadableImagesWithoutUsingSparsePageIndexes() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropPointPDFTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let invalid = directory.appendingPathComponent("01-invalid.png")
        let valid = directory.appendingPathComponent("02-valid.png")
        try Data("not an image".utf8).write(to: invalid)
        let image = NSImage(size: NSSize(width: 32, height: 24))
        image.lockFocus()
        NSColor.systemOrange.setFill()
        NSRect(x: 0, y: 0, width: 32, height: 24).fill()
        image.unlockFocus()
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: valid)

        let document = ImagePDFComposer.makeDocument(from: [invalid, valid])

        XCTAssertEqual(document.pageCount, 1)
    }

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
            XCTAssertEqual(succeeded, [source.standardizedFileURL])
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

    func testBatchCopyReportsSuccessfulFilesWhenAnotherFileFails() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropPointPartialActionTests-\(UUID().uuidString)")
        let sourceDirectory = root.appendingPathComponent("Source")
        let destinationDirectory = root.appendingPathComponent("Destination")
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let valid = sourceDirectory.appendingPathComponent("valid.txt")
        let missing = sourceDirectory.appendingPathComponent("missing.txt")
        try Data("valid".utf8).write(to: valid)
        let completed = expectation(description: "partial copy completed")
        let action = CustomShelfAction(
            name: "复制到测试目录",
            kind: .copyTo,
            destinationPath: destinationDirectory.path
        )

        ShelfActionService.perform(action, urls: [missing, valid]) { succeeded in
            XCTAssertEqual(succeeded, [valid.standardizedFileURL])
            completed.fulfill()
        }
        await fulfillment(of: [completed], timeout: 4)

        XCTAssertTrue(FileManager.default.fileExists(
            atPath: destinationDirectory.appendingPathComponent("valid.txt").path
        ))
    }
}

@MainActor
final class ShelfStoreTests: XCTestCase {
    func testExpandedShelfWithNoSelectionHasNoSelectedItems() throws {
        let first = URL(fileURLWithPath: #filePath)
        let second = first.deletingLastPathComponent()
        let store = ShelfStore()
        XCTAssertEqual(store.add(urls: [first, second]), 2)
        store.toggleExpanded()
        store.selectedIDs.removeAll()

        XCTAssertTrue(store.selectedItems.isEmpty)
    }

    func testSuccessfulCopyDragKeepsItemsOnShelf() throws {
        let file = URL(fileURLWithPath: #filePath)
        let store = ShelfStore()
        store.reduceMotion = true
        store.dragAction = .copy
        XCTAssertEqual(store.add(urls: [file]), 1)

        store.beginInternalDrag()
        store.finishInternalDrag(operation: .copy, keepOpen: false)

        XCTAssertEqual(store.items.map(\.url), [file.standardizedFileURL])
        XCTAssertFalse(store.isDraggingOut)
    }

    func testSuccessfulMoveDragRemovesItemsFromShelf() throws {
        let file = URL(fileURLWithPath: #filePath)
        let store = ShelfStore()
        store.reduceMotion = true
        store.dragAction = .move
        XCTAssertEqual(store.add(urls: [file]), 1)

        store.beginInternalDrag()
        store.finishInternalDrag(operation: .move, keepOpen: false)

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(store.isDraggingOut)
    }

    func testMoveDragWithKeepOpenRemovesAReferenceWhenTheSourceMoved() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DropPointMovedReferenceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("moved.txt")
        try Data("move".utf8).write(to: file)

        let store = ShelfStore()
        store.reduceMotion = true
        XCTAssertEqual(store.add(urls: [file]), 1)

        store.beginInternalDrag()
        try FileManager.default.removeItem(at: file)
        store.finishInternalDrag(operation: .move, keepOpen: true)
        try await Task.sleep(for: .milliseconds(200))

        XCTAssertTrue(store.items.isEmpty)
        XCTAssertFalse(store.isDraggingOut)
    }

    func testMoveDragRemovesTheOriginalSelectionEvenIfSelectionChanges() {
        let first = URL(fileURLWithPath: #filePath)
        let second = first.deletingLastPathComponent()
        let store = ShelfStore()
        store.add(urls: [first, second])
        store.toggleExpanded()
        store.selectedIDs = [first.standardizedFileURL.path]
        store.beginInternalDrag()
        store.selectedIDs = [second.standardizedFileURL.path]
        store.finishInternalDrag(operation: .move, keepOpen: false)
        XCTAssertEqual(store.items.map(\.url), [second.standardizedFileURL])
        XCTAssertFalse(store.isDraggingOut)
    }

    func testCancelledDragKeepsItemsAndRestoresStableState() throws {
        let file = URL(fileURLWithPath: #filePath)
        let store = ShelfStore()
        store.reduceMotion = true
        XCTAssertEqual(store.add(urls: [file]), 1)

        store.beginInternalDrag()
        store.finishInternalDrag(operation: [], keepOpen: false)

        XCTAssertEqual(store.items.map(\.url), [file.standardizedFileURL])
        XCTAssertFalse(store.isDraggingOut)
    }

    func testInternalDropBackNeverRemovesItemsForMoveAction() throws {
        let file = URL(fileURLWithPath: #filePath)
        let store = ShelfStore()
        store.reduceMotion = true
        store.dragAction = .move
        XCTAssertEqual(store.add(urls: [file]), 1)

        store.beginInternalDrag()
        store.acceptInternalDragReturn()
        store.finishInternalDrag(operation: .move, keepOpen: false)

        XCTAssertEqual(store.items.map(\.url), [file.standardizedFileURL])
        XCTAssertFalse(store.isDraggingOut)
    }

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

    func testPullAndKeyboardClearCannotStartOverlappingAnimations() async throws {
        let store = ShelfStore()
        store.reduceMotion = false
        store.add(urls: [URL(fileURLWithPath: #filePath)])
        var emptyTransitions = 0
        store.onEmptied = { emptyTransitions += 1 }
        store.clearFromPullGesture()
        store.clear()
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(emptyTransitions, 1)
        XCTAssertFalse(store.isClearing)
        XCTAssertFalse(store.isPullClearing)
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

final class DragOutGestureStateTests: XCTestCase {
    func testTrailingMouseDraggedCannotStartASecondSessionBeforeMouseUp() {
        var state = DragOutGestureState()

        state.mouseDown()
        XCTAssertTrue(state.claimDragStart())
        _ = state.draggingSessionEnded()

        XCTAssertFalse(state.claimDragStart())

        state.mouseUp()
        state.mouseDown()
        XCTAssertTrue(state.claimDragStart())
    }

    func testReleaseBeforeDraggingSessionBeginsRejectsLateSession() {
        var state = DragOutGestureState()

        state.mouseDown()
        XCTAssertTrue(state.claimDragStart())
        state.mouseUp()

        XCTAssertFalse(state.draggingSessionWillBegin())
        XCTAssertFalse(state.draggingSessionEnded())
    }

    func testActiveSessionNotifiesBeginAndEndExactlyOnce() {
        var state = DragOutGestureState()

        state.mouseDown()
        XCTAssertTrue(state.claimDragStart())
        XCTAssertTrue(state.draggingSessionWillBegin())
        XCTAssertTrue(state.draggingSessionEnded())
        XCTAssertFalse(state.draggingSessionEnded())

        XCTAssertFalse(state.claimDragStart())
    }
}

final class ShelfPointerInteractionPolicyTests: XCTestCase {
    func testControlDragFromAFileMovesTheShelfWithoutStealingNormalFileDrag() {
        XCTAssertEqual(
            ShelfPointerInteractionPolicy.fileDragIntent(modifiers: [.control]),
            .moveShelf
        )
        XCTAssertEqual(
            ShelfPointerInteractionPolicy.fileDragIntent(modifiers: []),
            .dragFiles
        )
    }

    func testOnlyABackgroundDoubleClickWithFilesRequestsClear() {
        XCTAssertEqual(
            ShelfPointerInteractionPolicy.backgroundMouseDown(clickCount: 2, hasFiles: true),
            .clearShelf
        )
        XCTAssertEqual(
            ShelfPointerInteractionPolicy.backgroundMouseDown(clickCount: 1, hasFiles: true),
            .moveShelf
        )
        XCTAssertEqual(
            ShelfPointerInteractionPolicy.backgroundMouseDown(clickCount: 2, hasFiles: false),
            .moveShelf
        )
    }
}

final class ShelfWindowDragTrackerTests: XCTestCase {
    func testDragTranslatesTheWindowByTheScreenPointerDelta() throws {
        var tracker = ShelfWindowDragTracker()
        tracker.begin(
            mouseLocationOnScreen: NSPoint(x: 100, y: 100),
            windowOrigin: NSPoint(x: 50, y: 60)
        )

        let origin = try XCTUnwrap(
            tracker.windowOrigin(for: NSPoint(x: 135, y: 80))
        )

        XCTAssertEqual(origin, NSPoint(x: 85, y: 40))
    }

    func testEndingADragStopsWindowMovement() {
        var tracker = ShelfWindowDragTracker()
        tracker.begin(mouseLocationOnScreen: .zero, windowOrigin: .zero)
        tracker.end()

        XCTAssertFalse(tracker.isActive)
        XCTAssertNil(tracker.windowOrigin(for: NSPoint(x: 20, y: 20)))
    }
}

@MainActor
final class DropAcceptanceTests: XCTestCase {
    func testDragOverlayAcceptsTheFirstMouseFromAnInactiveWindow() {
        let view = DragPassThroughNSView()

        XCTAssertTrue(view.acceptsFirstMouse(for: nil))
    }

    func testOverlayNotifiesAcceptanceBeforeImportSettles() throws {
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 16, height: 16))
        image.lockFocus()
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: 16, height: 16).fill()
        image.unlockFocus()
        pasteboard.clearContents()
        XCTAssertTrue(pasteboard.writeObjects([image]))

        let store = ShelfStore()
        var acceptedCount = 0
        store.onDropAccepted = { acceptedCount += 1 }
        let view = DragPassThroughNSView()
        view.dropStore = store

        XCTAssertTrue(view.acceptExternalPasteboard(pasteboard))
        XCTAssertEqual(acceptedCount, 1)
    }
}

@MainActor
final class ShelfWindowRepositionTests: XCTestCase {
    func testCursorRepositionUsesActualWindowSizes() {
        let workArea = NSRect(x: 0, y: 0, width: 1200, height: 800)
        let sizes = [
            NSSize(width: 520, height: 420),
            NSSize(width: 520, height: 420),
        ]
        let origins = ShelfWindowManager.repositionedOrigins(
            base: NSPoint(x: 560, y: 360),
            in: workArea,
            windowSizes: sizes
        )
        let frames = zip(origins, sizes).map(NSRect.init(origin:size:))

        XCTAssertEqual(frames.count, 2)
        XCTAssertFalse(frames[0].intersects(frames[1]))
        XCTAssertTrue(frames.allSatisfy { workArea.contains($0) })
    }
}

@MainActor
final class ShelfWindowAppearanceTests: XCTestCase {
    func testAppearanceAnimationScalesUniformlyFromTheCenterWithoutMagnifying() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("Appearance animation is disabled when Reduce Motion is enabled")
        }

        let controller = ShelfWindowController(store: ShelfStore(), alwaysOnTop: false)
        defer { controller.close() }

        controller.show(at: .zero, activating: false)

        let animation = try XCTUnwrap(
            controller.window?.contentView?.layer?.animation(forKey: "dropPointAppear")
                as? CAAnimationGroup
        )
        let properties = (animation.animations ?? []).compactMap { $0 as? CABasicAnimation }
        XCTAssertTrue(properties.contains { $0.keyPath == "opacity" })
        XCTAssertTrue(properties.allSatisfy { $0.duration == animation.duration })
        if controller.window?.backingScaleFactor == 1 {
            XCTAssertFalse(properties.contains { $0.keyPath == "transform.scale" })
        }
        XCTAssertEqual(controller.window?.contentView?.layer?.anchorPoint, CGPoint(x: 0.5, y: 0.5))
    }

    func testDismissAnimationShrinksUniformlyTowardTheCenter() throws {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            throw XCTSkip("Dismiss animation is disabled when Reduce Motion is enabled")
        }

        let controller = ShelfWindowController(store: ShelfStore(), alwaysOnTop: false)
        defer { controller.close() }
        controller.show(at: .zero, activating: false)
        controller.window?.contentView?.layer?.removeAllAnimations()

        controller.orderOutAnimated()

        if controller.window?.backingScaleFactor == 1 {
            XCTAssertNil(controller.window?.contentView?.layer?.animation(forKey: "dropPointDisappear"))
            return
        }

        let animation = try XCTUnwrap(
            controller.window?.contentView?.layer?.animation(forKey: "dropPointDisappear")
                as? CAKeyframeAnimation
        )
        XCTAssertEqual(animation.keyPath, "transform.scale")
        XCTAssertEqual(controller.window?.contentView?.layer?.anchorPoint, CGPoint(x: 0.5, y: 0.5))
        assertScaleValuesEqual(scaleValues(in: animation), [1, 0.99, 0.96], accuracy: 0.0001)
    }

    func testReopeningDuringDismissDoesNotLetOldCompletionHideTheWindow() async throws {
        let controller = ShelfWindowController(store: ShelfStore(), alwaysOnTop: false)
        defer { controller.close() }
        controller.show(at: .zero, activating: false)
        controller.orderOutAnimated()
        controller.showExistingAnimated(activating: false)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(controller.window?.isVisible, true)
        XCTAssertEqual(controller.window?.alphaValue ?? 0, 1, accuracy: 0.01)
    }

    private func scaleValues(in animation: CAKeyframeAnimation) -> [CGFloat] {
        (animation.values ?? []).compactMap { value in
            guard let number = value as? NSNumber else { return nil }
            return CGFloat(truncating: number)
        }
    }

    private func assertScaleValuesEqual(
        _ actual: [CGFloat],
        _ expected: [CGFloat],
        accuracy: CGFloat,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (actualValue, expectedValue) in zip(actual, expected) {
            XCTAssertEqual(
                actualValue,
                expectedValue,
                accuracy: accuracy,
                file: file,
                line: line
            )
        }
    }
}

final class OptionHoldClearGestureTests: XCTestCase {
    func testSinglePressNeverArmsEvenWhenHeld() {
        var gesture = OptionHoldClearGesture()
        XCTAssertFalse(gesture.update(optionPressed: true, timestamp: 1, doubleClickInterval: 0.5))
        XCTAssertEqual(gesture.progress(at: 5), 0)
    }

    func testSecondPressFillsForExactlyOnePointTwoSeconds() {
        var gesture = OptionHoldClearGesture()
        _ = gesture.update(optionPressed: true, timestamp: 1, doubleClickInterval: 0.5)
        _ = gesture.update(optionPressed: false, timestamp: 1.1, doubleClickInterval: 0.5)
        XCTAssertTrue(gesture.update(optionPressed: true, timestamp: 1.3, doubleClickInterval: 0.5))
        XCTAssertEqual(gesture.progress(at: 1.9), 0.5, accuracy: 0.001)
        XCTAssertLessThan(gesture.progress(at: 2.49), 1)
        XCTAssertEqual(gesture.progress(at: 2.5), 1, accuracy: 0.001)
    }

    func testEarlyReleaseCancelsAndRequiresANewDoublePress() {
        var gesture = OptionHoldClearGesture()
        _ = gesture.update(optionPressed: true, timestamp: 1, doubleClickInterval: 0.5)
        _ = gesture.update(optionPressed: false, timestamp: 1.1, doubleClickInterval: 0.5)
        _ = gesture.update(optionPressed: true, timestamp: 1.3, doubleClickInterval: 0.5)
        XCTAssertFalse(gesture.update(optionPressed: false, timestamp: 1.7, doubleClickInterval: 0.5))
        XCTAssertEqual(gesture.progress(at: 4), 0)
        XCTAssertFalse(gesture.update(optionPressed: true, timestamp: 1.8, doubleClickInterval: 0.5))
    }

    func testSlowDoublePressAndLongFirstPressDoNotArm() {
        var gesture = OptionHoldClearGesture()
        _ = gesture.update(optionPressed: true, timestamp: 1, doubleClickInterval: 0.5)
        _ = gesture.update(optionPressed: false, timestamp: 1.1, doubleClickInterval: 0.5)
        XCTAssertFalse(gesture.update(optionPressed: true, timestamp: 2, doubleClickInterval: 0.5))
        _ = gesture.update(optionPressed: false, timestamp: 3, doubleClickInterval: 0.5)
        XCTAssertFalse(gesture.update(optionPressed: true, timestamp: 3.1, doubleClickInterval: 0.5))
    }

    func testDuplicateModifierEventsCannotArmOrRestartTheHold() {
        var gesture = OptionHoldClearGesture()
        _ = gesture.update(optionPressed: true, timestamp: 1, doubleClickInterval: 0.5)
        XCTAssertFalse(gesture.update(optionPressed: true, timestamp: 1.1, doubleClickInterval: 0.5))
        _ = gesture.update(optionPressed: false, timestamp: 1.2, doubleClickInterval: 0.5)
        _ = gesture.update(optionPressed: true, timestamp: 1.3, doubleClickInterval: 0.5)
        XCTAssertTrue(gesture.update(optionPressed: true, timestamp: 1.8, doubleClickInterval: 0.5))
        XCTAssertEqual(gesture.progress(at: 1.9), 0.5, accuracy: 0.001)
    }

    func testFocusOrVisibilityResetCannotFinishAnOldHold() {
        var gesture = OptionHoldClearGesture()
        _ = gesture.update(optionPressed: true, timestamp: 1, doubleClickInterval: 0.5)
        _ = gesture.update(optionPressed: false, timestamp: 1.1, doubleClickInterval: 0.5)
        _ = gesture.update(optionPressed: true, timestamp: 1.3, doubleClickInterval: 0.5)
        gesture.reset()
        XCTAssertEqual(gesture.progress(at: 5), 0)
        XCTAssertFalse(gesture.update(optionPressed: true, timestamp: 5.1, doubleClickInterval: 0.5))
    }
}

@MainActor
final class InteractionSafetyTests: XCTestCase {
    func testOptionHoldPresentationInBothAppearancesAndShelfModes() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DropPoint-OptionClear-Visuals")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for dark in [false, true] {
            for expanded in [false, true] {
                let store = ShelfStore()
                store.reduceMotion = true
                store.autoCollapseExpanded = false
                let controller = ShelfWindowController(store: store, alwaysOnTop: false)
                store.add(urls: [URL(fileURLWithPath: #filePath), URL(fileURLWithPath: #filePath).deletingLastPathComponent()])
                store.isExpanded = expanded
                if expanded { controller.setExpanded(true) }
                let window = try XCTUnwrap(controller.window)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                let backdrop = NSWindow(contentRect: window.frame.insetBy(dx: -24, dy: -24), styleMask: [.borderless], backing: .buffered, defer: false)
                backdrop.backgroundColor = dark ? .black : .white
                backdrop.isReleasedWhenClosed = false
                backdrop.orderFront(nil)
                // Render a fixed presentation state. Window-server focus changes are
                // exercised by gesture tests separately and must not cancel this fixture.
                window.delegate = nil
                (controller.panel as? ShelfPanel)?.onGestureEvent = nil
                controller.showExistingAnimated(activating: false)
                store.isFocused = true
                store.isOptionClearActive = true
                store.optionClearProgress = 0.55
                try await Task.sleep(for: .milliseconds(250))
                XCTAssertTrue(store.isOptionClearActive)
                XCTAssertEqual(store.optionClearProgress, 0.55, accuracy: 0.001)
                let view = try XCTUnwrap(window.contentView)
                view.layoutSubtreeIfNeeded()
                let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: directory.appendingPathComponent("\(dark ? "dark" : "light")-\(expanded ? "expanded" : "compact").png"))
                XCTAssertFalse(window.hasShadow)
                XCTAssertFalse(window.isOpaque)
                window.delegate = controller
                controller.close()
                backdrop.close()
            }
        }
    }

    func testCompressionTargetRejectsNonFiniteOverflowAndTinyInputs() {
        for value in [Double.nan, .infinity, -.infinity, -1, 0, 9, Double.greatestFiniteMagnitude, Double(Int.max)] {
            XCTAssertNil(ShelfActionService.compressionTargetBytes(value: value, multiplier: 1_024))
        }
        XCTAssertEqual(ShelfActionService.compressionTargetBytes(value: 800, multiplier: 1_024), 819_200)
        XCTAssertEqual(ShelfActionService.compressionTargetBytes(value: 1, multiplier: 1_048_576), 1_048_576)
    }

    func testTimedOutArchiverStopsWithoutWaitingIndefinitely() async throws {
        let result = try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sleep")
            process.arguments = ["10"]
            let error = try ShelfActionService.runProcess(process, timeout: 0.05)
            return (error, process.isRunning)
        }.value
        XCTAssertNotNil(result.0)
        XCTAssertFalse(result.1)
    }

    func testOptionClearPreservesEmptyShelfAndOriginalFiles() throws {
        let url = URL(fileURLWithPath: #filePath)
        let store = ShelfStore()
        store.reduceMotion = true
        store.add(urls: [url])
        store.clearKeepingEmptyShelf()
        XCTAssertTrue(store.items.isEmpty)
        XCTAssertTrue(store.keepsEmptyShelfAfterOptionClear)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        store.add(urls: [url])
        XCTAssertFalse(store.keepsEmptyShelfAfterOptionClear)
    }

    func testClosedShelfRejectsLateImportResults() {
        let store = ShelfStore()
        store.cancelPendingWork()
        XCTAssertEqual(store.add(urls: [URL(fileURLWithPath: #filePath)]), 0)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testMissingFilesAreRemovedAfterBackgroundValidation() async throws {
        let store = ShelfStore()
        let failed = expectation(description: "missing file reported")
        store.onDropFailed = { _ in failed.fulfill() }
        store.add(urls: [FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)])
        await fulfillment(of: [failed], timeout: 3)
        XCTAssertTrue(store.items.isEmpty)
    }

    func testClosingDuringClearCancelsPendingAnimation() async throws {
        let store = ShelfStore()
        store.reduceMotion = false
        store.add(urls: [URL(fileURLWithPath: #filePath)])
        store.clear()
        store.cancelPendingWork()
        try await Task.sleep(for: .milliseconds(320))
        XCTAssertFalse(store.isClearing)
        XCTAssertEqual(store.items.count, 1)
    }

    func testStoppingWatcherDropsPendingDelivery() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let watcher = DirectoryWatcher()
        watcher.watchPaths = [directory.path]
        let ready = expectation(description: "watcher ready")
        watcher.onReady = { ready.fulfill() }
        let delivered = expectation(description: "no delivery after stop")
        delivered.isInverted = true
        watcher.onNewFiles = { _ in delivered.fulfill() }
        watcher.start()
        await fulfillment(of: [ready], timeout: 3)
        try Data("new".utf8).write(to: directory.appendingPathComponent("new.txt"))
        try await Task.sleep(for: .milliseconds(100))
        watcher.stop()
        await fulfillment(of: [delivered], timeout: 1.7)
    }
}
