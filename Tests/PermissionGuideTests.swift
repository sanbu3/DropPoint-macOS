import AppKit
import XCTest
@testable import DropPoint

@MainActor
final class PermissionGuideTests: XCTestCase {
    func testScreenRecordingReportsPendingRelaunchAndRevocation() {
        var granted = false
        let permission = ScreenRecordingPermissionService(preflight: { granted })
        XCTAssertEqual(permission.state, .notGranted)

        granted = true
        permission.refresh()
        XCTAssertEqual(permission.state, .requiresRelaunch)
        let relaunched = ScreenRecordingPermissionService(preflight: { granted })
        XCTAssertEqual(relaunched.state, .active)

        granted = false
        relaunched.refresh()
        XCTAssertEqual(relaunched.state, .notGranted)
    }

    func testGuideAlignsWithSettingsRightContentAtNormalAndWideSizes() {
        for width: CGFloat in [668, 754, 920] {
            let settings = NSRect(x: 100, y: 300, width: width, height: 600)
            let frame = PermissionGuideGeometry.frame(settings: settings, visible: NSRect(x: 0, y: 0, width: 1800, height: 1200))
            XCTAssertEqual(frame.minX, settings.minX + 266)
            XCTAssertEqual(frame.maxX, settings.maxX - 20)
            XCTAssertEqual(frame.maxY, settings.minY - 10)
        }
    }
    func testGuideStaysVisibleOnNegativeOriginDisplayAndAtBottomEdge() {
        let visible = NSRect(x: -1600, y: -400, width: 1600, height: 1000)
        let frame = PermissionGuideGeometry.frame(settings: NSRect(x: -1400, y: -350, width: 754, height: 650), visible: visible)
        XCTAssertTrue(visible.contains(frame))
        XCTAssertEqual(frame.width, 468)
    }
    func testDroppedIconNeverMeansPermissionIsAlreadyGranted() {
        let model = PermissionGuidePresentation()
        model.beginDrag()
        model.endDrag(accepted: true, now: 0)
        model.refresh(permission: .notGranted, now: 1)
        XCTAssertEqual(model.phase, .waiting)
        XCTAssertFalse(model.hasConfirmedGrant)
        model.refresh(permission: .notGranted, now: 9)
        XCTAssertEqual(model.phase, .retry)
        model.refresh(permission: .requiresRelaunch, now: 10)
        XCTAssertEqual(model.phase, .complete(requiresRelaunch: true))
        model.refresh(permission: .notGranted, now: 11)
        XCTAssertFalse(model.hasConfirmedGrant)
    }
    func testGrantAfterLaunchClosesGuideAndBothSettingsExactlyOnce() {
        var allowed = false
        var time: TimeInterval = 0
        var appSettingsClosed = 0
        var systemSettingsClosed = 0
        let permission = InputMonitoringPermissionService(preflight: { allowed })
        let guide = PermissionGuideWindowController(permission: permission,
            onAuthorizationCompleted: { appSettingsClosed += 1 }, now: { time },
            openSettings: {}, closeSettings: { _ in systemSettingsClosed += 1 }, onClose: {})
        guide.show()
        XCTAssertEqual(appSettingsClosed, 0)
        allowed = true
        time = 1
        guide.tick()
        XCTAssertEqual(permission.state, .requiresRelaunch)
        XCTAssertEqual(systemSettingsClosed, 0, "show confirmation before closing")
        time = 2
        guide.tick()
        guide.tick()
        XCTAssertEqual(appSettingsClosed, 1)
        XCTAssertEqual(systemSettingsClosed, 1)
    }
}
