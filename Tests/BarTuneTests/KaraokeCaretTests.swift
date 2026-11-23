@testable import BarTune
import XCTest

@MainActor
final class KaraokeCaretTests: XCTestCase {
    private let line = LyricLine(
        id: 0,
        timestamp: 10,
        duration: 4,
        text: "one two",
        words: [
            WordTimestamp(timestamp: 10, duration: 1, text: "one "),
            WordTimestamp(timestamp: 12, duration: 1, text: "two"),
        ]
    )

    func testCaretIsSolidWhileAWordIsSung() {
        XCTAssertFalse(LyricsState.isWaitingForWord(line: line, nextTimestamp: 15, position: 10.5))
        XCTAssertFalse(LyricsState.isWaitingForWord(line: line, nextTimestamp: 15, position: 12.2))
    }

    func testCaretBlinksBetweenWordsAndAroundTheLine() {
        XCTAssertTrue(LyricsState.isWaitingForWord(line: line, nextTimestamp: 15, position: 9.5), "before first word")
        XCTAssertTrue(LyricsState.isWaitingForWord(line: line, nextTimestamp: 15, position: 11.5), "gap between words")
        XCTAssertTrue(LyricsState.isWaitingForWord(line: line, nextTimestamp: 15, position: 13.5), "after last word")
    }

    func testLineTimedLyricsBlinkOnlyOnceTheSweepFinishes() {
        let plain = LyricLine(id: 1, timestamp: 10, duration: 2, text: "plain line", words: [])
        XCTAssertFalse(LyricsState.isWaitingForWord(line: plain, nextTimestamp: 13, position: 11))
        XCTAssertTrue(LyricsState.isWaitingForWord(line: plain, nextTimestamp: 13, position: 12.5))
    }

    func testFinishedOverflowingLineScrollsTheCaretIntoView() {
        let textWidth: CGFloat = 400
        let availableWidth: CGFloat = 200
        let offset = KaraokeLineView.scrollOffset(
            progress: 1,
            textWidth: textWidth,
            availableWidth: availableWidth,
            trailingInset: KaraokeLineView.caretWidth
        )
        let caretRightEdge = textWidth + KaraokeLineView.caretWidth + offset
        XCTAssertLessThanOrEqual(caretRightEdge, availableWidth + 0.001)
    }

    func testTypingCaretSettingPersists() throws {
        let suiteName = "bartune.test.caret.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        XCTAssertFalse(state.typingCaretEnabled)
        state.typingCaretEnabled = true

        XCTAssertTrue(LyricsState(userDefaults: ud).typingCaretEnabled)
    }
}
