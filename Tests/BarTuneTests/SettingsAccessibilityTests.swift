@testable import BarTune
import XCTest

final class SettingsAccessibilityTests: XCTestCase {
    func testSliderAndStepperLabelsAreNonEmptyAndDescriptive() {
        let labels = [
            SettingsAccessibility.spotlightWidthLabel,
            SettingsAccessibility.backgroundOpacityLabel,
            SettingsAccessibility.barCornerRadiusLabel,
            SettingsAccessibility.fontSizeLabel,
            SettingsAccessibility.lineTransitionSpeedLabel,
            SettingsAccessibility.visualizerWidthLabel,
            SettingsAccessibility.timingOffsetLabel,
        ]
        for label in labels {
            XCTAssertFalse(label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        XCTAssertEqual(Set(labels).count, labels.count)
        XCTAssertEqual(SettingsAccessibility.timingOffsetLabel, "Timing Offset")
    }

    func testSliderValueFormattersMatchUnits() {
        XCTAssertEqual(SettingsAccessibility.pointsValue(96), "96 pt")
        XCTAssertEqual(SettingsAccessibility.pointsValue(24), "24 pt")
        XCTAssertEqual(SettingsAccessibility.decimalPointsValue(13.5), "13.5 pt")
        XCTAssertEqual(SettingsAccessibility.percentageValue(0.82), "82%")
        XCTAssertEqual(SettingsAccessibility.secondsValue(0.25), "0.25 s")
    }

    func testTimingOffsetValueFormatsSignedAndZeroOffsets() {
        XCTAssertEqual(SettingsAccessibility.timingOffsetValue(0.35), "+0.35s")
        XCTAssertEqual(SettingsAccessibility.timingOffsetValue(-0.40), "-0.40s")
        XCTAssertEqual(SettingsAccessibility.timingOffsetValue(0.0), "0.00s")
        XCTAssertEqual(SettingsAccessibility.timingOffsetValue(-0.0001), "0.00s")
    }

    func testCacheActionLabelsIncludeSongTitleAndFallbackWhenBlank() {
        XCTAssertEqual(
            SettingsAccessibility.inspectCachedSongLabel(title: "Midnight City"),
            "Inspect lyrics for Midnight City"
        )
        XCTAssertEqual(
            SettingsAccessibility.revealCachedSongLabel(title: "Midnight City"),
            "Reveal Midnight City in Finder"
        )
        XCTAssertEqual(
            SettingsAccessibility.deleteCachedSongLabel(title: "Midnight City"),
            "Delete cached lyrics for Midnight City"
        )

        XCTAssertEqual(SettingsAccessibility.inspectCachedSongLabel(title: "   "), "Inspect cached lyrics")
        XCTAssertEqual(SettingsAccessibility.revealCachedSongLabel(title: ""), "Reveal cached file in Finder")
        XCTAssertEqual(SettingsAccessibility.deleteCachedSongLabel(title: "\n"), "Delete cached lyrics")
    }

    func testUpdateAvailableBadgeAndSidebarVersionLabels() {
        XCTAssertEqual(SettingsAccessibility.updateAvailableLabel, "Update available")
        XCTAssertEqual(
            SettingsAccessibility.sidebarVersionLabel(version: "v0.10.0", hasAvailableUpdate: false),
            "v0.10.0"
        )
        XCTAssertEqual(
            SettingsAccessibility.sidebarVersionLabel(version: "v0.10.0", hasAvailableUpdate: true),
            "v0.10.0, Update available"
        )
    }
}
