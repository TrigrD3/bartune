@testable import BarTune
import SwiftUI
import XCTest

final class AppearanceSettingsTests: XCTestCase {
    func testHexColorCoderRoundTripAndInvalidFallback() {
        XCTAssertNotNil(HexColorCoder.color(from: "#FF8800"))
        XCTAssertNotNil(HexColorCoder.color(from: "00CCFF"))
        XCTAssertNil(HexColorCoder.color(from: "not-a-color"))

        let hex = HexColorCoder.hex(from: Color(red: 1.0, green: 0.5, blue: 0.0))
        XCTAssertEqual(hex, "#FF8000")
    }

    @MainActor
    func testLyricsStatePersistsExpandedAppearanceSettings() throws {
        let suiteName = "bartune.test.appearance.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        XCTAssertEqual(state.lyricsColorPreset, .matchTheme)
        XCTAssertFalse(state.karaokeGlowEnabled)
        XCTAssertEqual(state.barCornerRadius, 6.0, accuracy: 0.01)
        XCTAssertTrue(state.showTrackTitle)

        state.lyricsColorPreset = .custom
        state.customLyricsColorHex = "#33FFAA"
        state.karaokeGlowEnabled = true
        state.barCornerRadius = 10.0
        state.showTrackTitle = false

        let reloaded = LyricsState(userDefaults: ud)
        XCTAssertEqual(reloaded.lyricsColorPreset, .custom)
        XCTAssertEqual(reloaded.customLyricsColorHex, "#33FFAA")
        XCTAssertTrue(reloaded.karaokeGlowEnabled)
        XCTAssertEqual(reloaded.barCornerRadius, 10.0, accuracy: 0.01)
        XCTAssertFalse(reloaded.showTrackTitle)
    }
}
