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

    func testAudioCapturePermissionInfoUsesProcessTapOnMacOS14_2Plus() {
        let idle = AudioCapturePermissionInfo.resolve(
            usesProcessTap: true,
            screenCaptureGranted: false,
            processTapPermission: .unknown,
            audioSyncStatus: .idle
        )
        XCTAssertEqual(idle.title, "System Audio Recording")
        XCTAssertEqual(idle.settingsURL, "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")
        XCTAssertEqual(idle.state, .requestedOnUse)
        XCTAssertFalse(idle.state.isGranted)

        let granted = AudioCapturePermissionInfo.resolve(
            usesProcessTap: true,
            screenCaptureGranted: false,
            processTapPermission: .granted,
            audioSyncStatus: .syncing(engine: .lyricsAlignment, alignedLines: 2, totalLines: 10)
        )
        XCTAssertEqual(granted.state, .granted)
        XCTAssertTrue(granted.state.isGranted)

        let denied = AudioCapturePermissionInfo.resolve(
            usesProcessTap: true,
            screenCaptureGranted: true,
            processTapPermission: .denied,
            audioSyncStatus: .permissionRequired("Could not create audio process tap")
        )
        XCTAssertEqual(denied.state, .denied)
    }

    func testAudioCapturePermissionInfoFallsBackToScreenCaptureOnMacOS13() {
        let notGranted = AudioCapturePermissionInfo.resolve(
            usesProcessTap: false,
            screenCaptureGranted: false,
            processTapPermission: .granted,
            audioSyncStatus: .idle
        )
        XCTAssertEqual(notGranted.title, "Screen & System Audio")
        XCTAssertEqual(notGranted.settingsURL, "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        XCTAssertEqual(notGranted.state, .notRequested)

        let granted = AudioCapturePermissionInfo.resolve(
            usesProcessTap: false,
            screenCaptureGranted: true,
            processTapPermission: .unknown,
            audioSyncStatus: .idle
        )
        XCTAssertEqual(granted.state, .granted)
    }

    func testAudioCapturePermissionInfoTreatsSilenceAsUnverified() {
        let info = AudioCapturePermissionInfo.resolve(
            usesProcessTap: true,
            screenCaptureGranted: false,
            processTapPermission: .granted,
            audioSyncStatus: .processTapNoAudioWarning
        )

        XCTAssertEqual(info.state, .unverified)
    }

    func testAudioCapturePermissionInfoKeepsConfirmedDenialAcrossTrackStatuses() {
        let info = AudioCapturePermissionInfo.resolve(
            usesProcessTap: true,
            screenCaptureGranted: false,
            processTapPermission: .denied,
            audioSyncStatus: .cached(.lyricsAlignment)
        )

        XCTAssertEqual(info.state, .denied)
        XCTAssertFalse(info.state.isGranted)
    }
}
