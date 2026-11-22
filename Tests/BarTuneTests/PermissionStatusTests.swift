import ApplicationServices
@testable import BarTune
import XCTest

final class PermissionStatusTests: XCTestCase {
    func testMapsScreenCaptureState() {
        XCTAssertEqual(PermissionAuthorizationState.fromScreenCapture(true), .granted)
        XCTAssertTrue(PermissionAuthorizationState.fromScreenCapture(true).isGranted)
        XCTAssertEqual(PermissionAuthorizationState.fromScreenCapture(false), .notRequested)
        XCTAssertFalse(PermissionAuthorizationState.fromScreenCapture(false).isGranted)
    }

    func testMapsAutomationStatuses() {
        XCTAssertEqual(PermissionAuthorizationState.fromAutomationStatus(noErr), .granted)
        XCTAssertEqual(PermissionAuthorizationState.fromAutomationStatus(OSStatus(errAEEventNotPermitted)), .denied)
        XCTAssertEqual(PermissionAuthorizationState.fromAutomationStatus(OSStatus(procNotFound)), .targetNotRunning)
        XCTAssertEqual(
            PermissionAuthorizationState.fromAutomationStatus(OSStatus(errAEEventWouldRequireUserConsent)),
            .notRequested
        )
    }
}
