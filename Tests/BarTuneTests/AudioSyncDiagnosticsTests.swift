@testable import BarTune
import XCTest

final class AudioSyncDiagnosticsTests: XCTestCase {
    private func word(_ text: String, _ start: Double) -> RecognizedAudioWord {
        RecognizedAudioWord(text: text, startTime: start, duration: 0.3, confidence: 0.8)
    }

    func testAppendedWordsKeepOnlyTheNewestUpToTheCap() {
        var diagnostics = AudioSyncDiagnostics(engine: .lyricsAlignment, trackDescription: "A — B")
        let first = (0..<150).map { word("a\($0)", Double($0)) }
        let second = (150..<260).map { word("b\($0)", Double($0)) }

        diagnostics.record(words: first, replacing: false)
        diagnostics.record(words: second, replacing: false)

        XCTAssertEqual(diagnostics.resultCount, 2)
        XCTAssertEqual(diagnostics.totalRecognizedWords, 260)
        XCTAssertEqual(diagnostics.recentWords.count, AudioSyncDiagnostics.maxStoredWords)
        XCTAssertEqual(diagnostics.recentWords.first?.text, "a60")
        XCTAssertEqual(diagnostics.recentWords.last?.text, "b259")
    }

    func testReplacingWordsResetsTheTotal() {
        var diagnostics = AudioSyncDiagnostics(engine: .lyricsAlignment, trackDescription: "A — B")
        diagnostics.record(words: [word("one", 1), word("two", 2), word("three", 3)], replacing: true)
        diagnostics.record(words: [word("one", 1), word("two", 2)], replacing: true)

        XCTAssertEqual(diagnostics.totalRecognizedWords, 2)
        XCTAssertEqual(diagnostics.recentWords.map(\.text), ["one", "two"])
    }

    func testAlignmentMarksMatchedLinesAndReportListsThem() {
        let lines = [
            LyricLine(id: 0, timestamp: 10, text: "Hello world from test"),
            LyricLine(id: 1, timestamp: 15, text: "Second line of lyrics"),
        ]
        let words = [word("hello", 10.4), word("world", 10.8), word("from", 11.1), word("test", 11.5)]
        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: words)
        var diagnostics = AudioSyncDiagnostics(engine: .lyricsAlignment, trackDescription: "Artist — Song")
        diagnostics.localeIdentifier = "en-US"

        diagnostics.record(words: words, replacing: true)
        diagnostics.record(alignment: result, sourceLines: lines)

        XCTAssertEqual(result.matchedLineIDs, [0])
        XCTAssertEqual(diagnostics.lineResults.map(\.matched), [true, false])
        XCTAssertEqual(diagnostics.lineResults[0].alignedTimestamp, 10.4, accuracy: 0.001)
        let report = diagnostics.report()
        XCTAssertTrue(report.contains("Locale: en-US"))
        XCTAssertTrue(report.contains("Lines matched: 1/2"))
        XCTAssertTrue(report.contains("✓ 10.00s → 10.40s  Hello world from test"))
        XCTAssertTrue(report.contains("· 15.00s → 15.00s  Second line of lyrics"))
        XCTAssertTrue(report.contains("10.40s  hello  (0.80)"))
        XCTAssertEqual(
            diagnostics.formattedLineResults(),
            "✓ 10.00s → 10.40s  Hello world from test\n· 15.00s → 15.00s  Second line of lyrics"
        )
    }
}
