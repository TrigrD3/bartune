@testable import BarTune
import Combine
import XCTest

@MainActor
final class LyricsStatePerformanceTests: XCTestCase {
    func testUpdatePlaybackDoesNotEmitObjectWillChangeWithinSameLine() {
        let state = LyricsState()
        let track = TrackInfo(
            id: "perf:track",
            title: "Test Song",
            artist: "Test Artist",
            album: "",
            duration: 180,
            artworkURL: nil
        )
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, duration: 5.0, text: "First line"),
            LyricLine(id: 1, timestamp: 15.0, duration: 5.0, text: "Second line"),
        ]
        state.setTrack(track, lyrics: lines)
        // Enter playing state on line 0
        state.updatePlayback(isPlaying: true, position: 10.2)

        var changeCount = 0
        let cancellable = state.objectWillChange.sink { _ in
            changeCount += 1
        }
        defer { cancellable.cancel() }

        // Simulate 100 interpolation ticks within the same lyric line
        for step in 1...100 {
            let pos = 10.2 + Double(step) * 0.04
            state.updatePlayback(isPlaying: true, position: pos)
        }

        XCTAssertEqual(
            changeCount,
            0,
            "updatePlayback must not fire objectWillChange when isPlaying and currentLineId are unchanged"
        )
    }

    func testRepeatedIdleUpdatesDoNotEmitObjectWillChange() {
        let state = LyricsState()
        state.updatePlayback(isPlaying: false, position: 0)

        var changeCount = 0
        let cancellable = state.objectWillChange.sink { _ in
            changeCount += 1
        }
        defer { cancellable.cancel() }

        for _ in 0..<50 {
            state.updatePlayback(isPlaying: false, position: 0)
        }

        XCTAssertEqual(changeCount, 0, "Repeated idle polls must not trigger SwiftUI redraws")
    }

    func testChapterResolutionAndLiveProgressStayFast() {
        let sep = "\u{1F}"
        let gs = "\u{1D}"
        let rs = "\u{1E}"
        let chapters = (0..<50).map { idx in
            let sec = idx * 200
            let mins = sec / 60
            let rem = sec % 60
            return String(format: "%d:%02d%@%02d. Artist %d - Song %d", mins, rem, rs, idx + 1, idx, idx)
        }.joined(separator: gs)

        let payload = [
            "BROWSER",
            "playing",
            "browser:www.youtube.com:Big Compilation|Curator",
            "Big Compilation",
            "Curator",
            "",
            "10000.0",
            "4510.0",
            "",
            chapters,
        ].joined(separator: sep)

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<100 {
            let snap = BrowserMediaParser.parsePayload(payload)
            XCTAssertNotNil(snap)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        XCTAssertLessThan(elapsed, 0.5, "100 chapter payload parses should stay well under 0.5s")
    }

    func testMarqueeScrollCalculatorStaysZeroWhenTextFitsAndScrollsWhenOverflowing() {
        XCTAssertEqual(MarqueeScrollCalculator.offset(at: 5.0, textWidth: 100, containerWidth: 140), 0)
        XCTAssertEqual(MarqueeScrollCalculator.offset(at: 1.0, textWidth: 200, containerWidth: 140), 0)
        let scrolled = MarqueeScrollCalculator.offset(at: 2.6, textWidth: 200, containerWidth: 140, speed: 24.0, pauseDuration: 1.6)
        XCTAssertEqual(scrolled, -24.0, accuracy: 0.01)
    }
}
