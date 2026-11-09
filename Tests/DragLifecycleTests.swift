import AppKit
import XCTest
@testable import DropPoint

@MainActor
final class DragLifecycleTests: XCTestCase {
    func testDragCannotStartWithoutMouseDown() {
        var gesture = DragOutGestureState()
        XCTAssertFalse(gesture.claimDragStart())
        gesture.mouseDown()
        gesture.mouseUp()
        XCTAssertFalse(gesture.claimDragStart())
    }

    func testClosingStoreBalancesActiveDragExactlyOnce() {
        let store = ShelfStore()
        var transitions: [Bool] = []
        store.onInternalDragStateChanged = { transitions.append($0) }
        store.add(urls: [URL(fileURLWithPath: #filePath)])
        store.beginInternalDrag()
        store.cancelPendingWork()
        store.cancelPendingWork()
        store.finishInternalDrag(operation: .move, keepOpen: false)
        XCTAssertEqual(transitions, [true, false])
        XCTAssertFalse(store.isDraggingOut)
        XCTAssertEqual(store.items.count, 1, "a late drag completion must not mutate a closed shelf")
    }

    func testClosedShelfRejectsPasteboardBeforeAcceptingIt() {
        let store = ShelfStore()
        store.cancelPendingWork()
        var accepted = false
        store.onDropAccepted = { accepted = true }
        let destination = DragPassThroughNSView()
        destination.dropStore = store
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([URL(fileURLWithPath: #filePath) as NSURL])
        XCTAssertFalse(destination.acceptExternalPasteboard(pasteboard))
        XCTAssertFalse(accepted)
    }

    func testClosedWindowCannotBeShownAgain() {
        let controller = ShelfWindowController(store: ShelfStore(), alwaysOnTop: false)
        controller.show(at: .zero, activating: false)
        controller.close()
        controller.showExistingAnimated(activating: false)
        XCTAssertFalse(controller.window?.isVisible ?? false)
    }

    func testCloseWaitsForDragCompletion() async throws {
        let store = ShelfStore()
        let controller = ShelfWindowController(store: store, alwaysOnTop: false)
        var closedCount = 0
        controller.onClosed = { _ in closedCount += 1 }
        controller.show(at: .zero, activating: false)
        store.add(urls: [URL(fileURLWithPath: #filePath)])
        store.beginInternalDrag()
        controller.close()
        XCTAssertEqual(closedCount, 0, "keep the AppKit drag source alive until the session ends")
        XCTAssertFalse(store.isClosed)
        store.finishInternalDrag(operation: .copy, keepOpen: false)
        try await Task.sleep(for: .milliseconds(350))
        XCTAssertEqual(closedCount, 1)
        XCTAssertTrue(store.isClosed)
        XCTAssertFalse(controller.window?.isVisible ?? false)
    }

    func testCloseDuringHideStillClosesTheWindow() async throws {
        let controller = ShelfWindowController(store: ShelfStore(), alwaysOnTop: false)
        controller.show(at: .zero, activating: false)
        controller.orderOutAnimated()
        controller.closeAnimated()
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(controller.store.isClosed)
    }

    func testShowingDuringCloseDoesNotResurrectTheShelf() async throws {
        let controller = ShelfWindowController(store: ShelfStore(), alwaysOnTop: false)
        controller.show(at: .zero, activating: false)
        controller.closeAnimated()
        controller.showExistingAnimated(activating: false)
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertTrue(controller.store.isClosed)
        XCTAssertFalse(controller.window?.isVisible ?? false)
    }

    func testFailedImportCannotPresentAnAlertAfterClosing() async throws {
        let store = ShelfStore()
        let failure = expectation(description: "closed shelf ignores failed import")
        failure.isInverted = true
        store.onDropFailed = { _ in failure.fulfill() }
        let destination = DragPassThroughNSView()
        destination.dropStore = store
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.writeObjects([FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) as NSURL])
        XCTAssertTrue(destination.acceptExternalPasteboard(pasteboard))
        store.cancelPendingWork()
        await fulfillment(of: [failure], timeout: 0.5)
        XCTAssertTrue(store.items.isEmpty)
    }
}
