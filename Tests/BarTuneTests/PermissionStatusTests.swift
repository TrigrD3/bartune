import ApplicationServices
@testable import BarTune
import Speech
import XCTest

final class PermissionStatusTests: XCTestCase {
    func testMapsScreenCaptureState() {
        XCTAssertEqual(PermissionAuthorizationState.fromScreenCapture(true), .granted)
        XCTAssertTrue(PermissionAuthorizationState.fromScreenCapture(true).isGranted)
        XCTAssertEqual(PermissionAuthorizationState.fromScreenCapture(false), .notRequested)
        XCTAssertFalse(PermissionAuthorizationState.fromScreenCapture(false).isGranted)
    }

    func testMapsSpeechRecognitionStatuses() {
        XCTAssertEqual(PermissionAuthorizationState.fromSpeechStatus(.authorized), .granted)
        XCTAssertEqual(PermissionAuthorizationState.fromSpeechStatus(.notDetermined), .notRequested)
        XCTAssertEqual(PermissionAuthorizationState.fromSpeechStatus(.denied), .denied)
        XCTAssertEqual(PermissionAuthorizationState.fromSpeechStatus(.restricted), .denied)
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
