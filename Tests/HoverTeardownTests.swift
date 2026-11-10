import AppKit
import XCTest
@testable import DropPoint

@MainActor
final class HoverTeardownTests: XCTestCase {
    func testTrailingEnteredAndExitedEventsCannotUpdateAClosedShelf() throws {
        let store = ShelfStore()
        let controller = ShelfWindowController(store: store, alwaysOnTop: false)
        let host = try XCTUnwrap(controller.window?.contentView as? ShelfDropHostingView)
        var callbacks: [Bool] = []
        host.onHoverChanged = { callbacks.append($0) }
        controller.show(at: .zero, activating: false)
        controller.close()
        let entered = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseEntered, location: .zero,
            modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil))
        let exited = try XCTUnwrap(NSEvent.enterExitEvent(with: .mouseExited, location: .zero,
            modifierFlags: [], timestamp: 2, windowNumber: 0, context: nil, eventNumber: 0,
            trackingNumber: 0, userData: nil))
        host.mouseEntered(with: entered)
        host.mouseExited(with: exited)
        XCTAssertTrue(callbacks.isEmpty, "teardown must stop ALL hover events, not only mouseMoved")
    }
}
