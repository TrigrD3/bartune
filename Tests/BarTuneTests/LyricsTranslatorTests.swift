@testable import BarTune
import XCTest

final class LyricsTranslatorTests: XCTestCase {
    func testParsesGoogleTranslateSinglePayload() throws {
        let json = """
        [[["Hello world\\n","こんにちは世界\\n",null,null,10],["Good night","おやすみ",null,null,10]],null,"ja"]
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let parsed = LyricsTranslationParser.parseTranslatedText(from: data)
        XCTAssertEqual(parsed, "Hello world\nGood night")
    }

    func testAppliesTranslatedLinesPreservingTimestamps() {
        let original = [
            LyricLine(
                id: 0,
                timestamp: 10.0,
                duration: 3.5,
                text: "こんにちは世界",
                words: [WordTimestamp(timestamp: 10.0, duration: 1.5, text: "こんにちは")]
            ),
            LyricLine(id: 1, timestamp: 14.0, duration: 2.0, text: "♪"),
        ]
        let applied = LyricsTranslationParser.applyTranslatedLines(["Hello world", ""], to: original)
        XCTAssertEqual(applied.count, 2)
        XCTAssertEqual(applied[0].text, "Hello world")
        XCTAssertEqual(applied[0].timestamp, 10.0, accuracy: 0.001)
        XCTAssertEqual(applied[0].duration, 3.5)
        XCTAssertTrue(applied[0].words.isEmpty)
        XCTAssertEqual(applied[1].text, "♪")
    }

    @MainActor
    func testTranslateLyricsToggleSwitchesDisplayedLine() throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        state.romanizeJapanese = false
        let track = TrackInfo(id: "tr:1", title: "Song", artist: "Artist", album: "", duration: 120, artworkURL: nil)
        let original = [LyricLine(id: 0, timestamp: 1.0, duration: 4.0, text: "おはよう")]
        let translated = [LyricLine(id: 0, timestamp: 1.0, duration: 4.0, text: "Good morning")]

        state.setTrack(track, lyrics: original)
        state.updatePlayback(isPlaying: true, position: 2.0)
        XCTAssertEqual(state.currentText, "おはよう")

        state.setTranslatedLines(translated)
        XCTAssertEqual(state.currentText, "おはよう") // Toggle is off by default

        state.translateLyrics = true
        XCTAssertEqual(state.currentText, "Good morning")

        state.translateLyrics = false
        XCTAssertEqual(state.currentText, "おはよう")
    }
}
