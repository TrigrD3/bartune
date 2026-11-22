@testable import BarTune
import XCTest

final class SettingsDisclosureTests: XCTestCase {
    func testBrowserMediaDisclosureIdentifiesExternalLyricsRecipientsAndFields() {
        let disclosure = SettingsView.browserMediaDisclosure.lowercased()
        XCTAssertTrue(disclosure.contains("netease"))
        XCTAssertTrue(disclosure.contains("music.163.com"))
        XCTAssertTrue(disclosure.contains("lrclib"))
        XCTAssertTrue(disclosure.contains("lrclib.net"))
        XCTAssertTrue(disclosure.contains("title"))
        XCTAssertTrue(disclosure.contains("artist"))
        XCTAssertTrue(disclosure.contains("album"))
        XCTAssertTrue(disclosure.contains("duration"))
        XCTAssertTrue(disclosure.contains("youtube.com/watch"))
    }

    func testTranslationDisclosureIdentifiesGoogleTranslateAndSentFields() {
        let disclosure = SettingsView.translationDisclosure.lowercased()
        XCTAssertTrue(disclosure.contains("google translate"))
        XCTAssertTrue(disclosure.contains("translate.googleapis.com"))
        XCTAssertTrue(disclosure.contains("lyric"))
        XCTAssertTrue(disclosure.contains("target language"))
    }
}
