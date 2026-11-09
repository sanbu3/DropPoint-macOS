import AppKit
import CoreGraphics
import XCTest
@testable import DropPoint

@MainActor
final class WindowScreenshotSmokeTests: XCTestCase {
    func testRepeatedWindowCaptureWhenAlreadyAuthorized() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            throw XCTSkip("屏幕录制尚未授权；不在测试中请求或修改权限。")
        }
        for _ in 0..<3 {
            let capture = try await WindowScreenshotService.captureNearestWindow()
            XCTAssertGreaterThan(capture.image.width, 100)
            XCTAssertGreaterThan(capture.image.height, 80)
        }
    }
}
