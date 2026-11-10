import AppKit
import SwiftUI
import XCTest
@testable import DropPoint

@MainActor
final class NativeTooltipTests: XCTestCase {
    func testNativeTooltipRemainsNonInteractiveAndCanBeCleared() {
        let view = NativeTooltipView(frame: NSRect(x: 0, y: 0, width: 100, height: 30))
        view.toolTip = "关闭文件架"
        XCTAssertEqual(view.toolTip, "关闭文件架")
        XCTAssertNil(view.hitTest(NSPoint(x: 20, y: 10)))
        NativeTooltip.dismantleNSView(view, coordinator: ())
        XCTAssertNil(view.toolTip)
    }
    func testMacOS27ControlHelpUsesANativeTooltipView() throws {
        guard #available(macOS 27, *) else { throw XCTSkip("compatibility path applies to macOS 27") }
        let host = NSHostingView(rootView: Button("Fixture") {}.dropPointHelp("fixture tooltip").frame(width: 180, height: 60))
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 180, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        panel.contentView = host
        panel.isReleasedWhenClosed = false
        panel.orderFrontRegardless()
        defer { panel.close() }
        host.layoutSubtreeIfNeeded()
        host.displayIfNeeded()
        func find(_ view: NSView) -> NativeTooltipView? {
            if let tip = view as? NativeTooltipView { return tip }
            return view.subviews.compactMap(find).first
        }
        XCTAssertEqual(try XCTUnwrap(find(host)).toolTip, "fixture tooltip")
    }
    func testFocusChangesDuringShelfPresentationUpdatesUseNativeTooltips() async throws {
        guard #available(macOS 27, *) else { throw XCTSkip("macOS 27 compatibility path") }
        let store = ShelfStore()
        let controller = ShelfWindowController(store: store, alwaysOnTop: false)
        let window = try XCTUnwrap(controller.window)
        let host = try XCTUnwrap(window.contentView)
        let other = NSWindow(contentRect: NSRect(x: 250, y: 100, width: 100, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: false)
        other.isReleasedWhenClosed = false
        defer { controller.close(); other.close() }
        controller.show(at: .zero, activating: true)
        for index in 0..<20 {
            store.updateDropTargeted(index % 2 == 0)
            host.layoutSubtreeIfNeeded()
            other.makeKeyAndOrderFront(nil)
            window.makeKeyAndOrderFront(nil)
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertFalse(store.isClosed)
        XCTAssertTrue(window.isVisible)
    }

}
