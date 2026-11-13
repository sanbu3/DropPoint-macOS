import AppKit
import SwiftUI
import XCTest
@testable import DropPoint

@MainActor
final class NativeShelfRoutingTests: XCTestCase {
    func testExternalDragActionsSurviveTheTransitionOutOfTheShelf() async throws {
        let store = ShelfStore()
        let controller = ShelfWindowController(store: store, alwaysOnTop: true)
        defer { controller.close() }
        let screen = try XCTUnwrap(NSScreen.main)
        controller.show(at: NSPoint(x: screen.visibleFrame.midX, y: screen.visibleFrame.midY), activating: false)
        store.updateDropTargeted(true)
        let panel = try XCTUnwrap(controller.dragActionsPanel)
        let targets = try XCTUnwrap(panel.contentView as? ShelfDragActionsView)
        XCTAssertEqual(panel.frame.maxY, controller.window?.frame.minY)
        XCTAssertEqual(targets.action(at: NSPoint(x: 22, y: 22)), .archive)
        XCTAssertEqual(targets.action(at: NSPoint(x: 76, y: 22)), .compressImages)
        XCTAssertEqual(targets.action(at: NSPoint(x: 130, y: 22)), .resizeImages)
        XCTAssertNil(targets.action(at: NSPoint(x: 49, y: 22)))

        store.scheduleDropTargetExit()
        store.updateDropTargeted(true)
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(controller.dragActionsPanel === panel)

        store.scheduleDropTargetExit()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertNil(controller.dragActionsPanel)
        XCTAssertFalse(panel.isVisible)
    }

    func testShelfBackgroundNeverFallsBackToSwiftUIHitTestingOnMacOS27() throws {
        guard #available(macOS 27, *) else { throw XCTSkip("macOS 27 route") }
        let controller = ShelfWindowController(store: ShelfStore(), alwaysOnTop: false)
        defer { controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        controller.show(at: .zero, activating: false)
        root.layoutSubtreeIfNeeded()
        for p in [NSPoint(x: 2, y: 80), NSPoint(x: 190, y: 80), NSPoint(x: 99, y: 155)] {
            let hit = try XCTUnwrap(root.hitTest(root.convert(p, to: root.superview)))
            XCTAssertFalse(hit is NSHostingView<AnyView>, "background must be owned by AppKit")
        }
    }
    func testNativeControlsRemainClickableAfterDropExpansionAndSelection() async throws {
        guard #available(macOS 27, *) else { throw XCTSkip("macOS 27 route") }
        let store = ShelfStore()
        store.reduceMotion = true
        let controller = ShelfWindowController(store: store, alwaysOnTop: false)
        defer { controller.close() }
        let root = try XCTUnwrap(controller.window?.contentView)
        store.onExpansionChanged = { [weak controller] in controller?.setExpanded($0) }
        controller.show(at: .zero, activating: false)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = ["a.txt", "b.txt"].map { directory.appendingPathComponent($0) }
        for file in files { try Data("fixture".utf8).write(to: file) }
        store.add(urls: files)
        func buttons(in view: NSView) -> [ShelfNativeButton] {
            (view as? ShelfNativeButton).map { [$0] } ?? view.subviews.flatMap { buttons(in: $0) }
        }
        func button(_ label: String) throws -> ShelfNativeButton {
            root.layoutSubtreeIfNeeded()
            let button = try XCTUnwrap(buttons(in: root).first { $0.identifier?.rawValue == label })
            let center = button.convert(NSPoint(x: button.bounds.midX, y: button.bounds.midY), to: root.superview)
            let hit = root.hitTest(center)
            XCTAssertTrue(hit === button, "native control must outrank background: \(label), frame=\(button.convert(button.bounds, to: root)), root=\(root.bounds), hit=\(String(describing: hit)), identifier=\(String(describing: hit?.identifier))")
            return button
        }
        try await Task.sleep(for: .milliseconds(150))
        try button("展开文件列表").performClick(nil)
        XCTAssertTrue(store.isExpanded)
        try await Task.sleep(for: .milliseconds(200))
        try button("全选").performClick(nil)
        XCTAssertEqual(store.selectedIDs.count, 2)
        try await Task.sleep(for: .milliseconds(100))
        try button("取消全选").performClick(nil)
        XCTAssertTrue(store.selectedIDs.isEmpty)
        XCTAssertNotNil(try button("更多操作").menuProvider?())
        try button("收起文件列表").performClick(nil)
        XCTAssertFalse(store.isExpanded)
        try await Task.sleep(for: .milliseconds(200))
        var closed = false
        store.onClose = { closed = true }
        try button("关闭文件架").performClick(nil)
        XCTAssertTrue(closed)
    }

}
