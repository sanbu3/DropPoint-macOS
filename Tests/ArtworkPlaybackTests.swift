import AppKit
import XCTest
@testable import DropPoint

@MainActor
final class ArtworkPlaybackTests: XCTestCase {
    func testOriginalArtworkContainsDistinctFullSizeFramesWithOriginalTiming() throws {
        for (name, size, seconds) in [("Cat_in_Box", 224, 2.97), ("Empty Box", 304, 4.037)] {
            let artwork = try XCTUnwrap(ShelfArtworkPlayer.artwork(named: name))
            XCTAssertGreaterThan(artwork.frames.count, 40)
            XCTAssertTrue(artwork.frames.allSatisfy { $0.width == size && $0.height == size })
            XCTAssertEqual(artwork.duration, seconds, accuracy: 0.005)
            XCTAssertEqual(artwork.keyTimes.first?.doubleValue, 0)
            let first = try XCTUnwrap(artwork.frames.first?.dataProvider?.data) as Data
            XCTAssertTrue(artwork.frames.dropFirst().contains { ($0.dataProvider?.data as Data?) != first })
        }
    }

    func testShelfHostAlwaysClipsItsNativeLayerToTheSameRoundedSurface() throws {
        let store = ShelfStore()
        let controller = ShelfWindowController(store: store, alwaysOnTop: false)
        defer { controller.close() }
        let host = try XCTUnwrap(controller.window?.contentView)
        XCTAssertFalse(controller.window?.isOpaque ?? true)
        XCTAssertFalse(controller.window?.hasShadow ?? true)
        XCTAssertEqual(host.layer?.cornerRadius, 25)
        XCTAssertEqual(host.layer?.masksToBounds, true)
        controller.show(at: .zero, activating: false)
        store.toggleExpanded()
        XCTAssertEqual(host.layer?.cornerRadius, 25)
        XCTAssertEqual(host.layer?.masksToBounds, true)
    }
}
