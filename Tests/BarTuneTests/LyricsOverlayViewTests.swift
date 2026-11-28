@testable import BarTune
import XCTest

@MainActor
final class LyricsOverlayViewTests: XCTestCase {
    func testOverflowingLineScrollsFromStartWhenKaraokeHighlightIsDisabled() throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        state.karaokeAnimationEnabled = false

        let track = TrackInfo(
            id: "overlay:1",
            title: "Long Line Track",
            artist: "Artist",
            album: "",
            duration: 120,
            artworkURL: nil
        )
        let line = LyricLine(
            id: 0,
            timestamp: 10.0,
            duration: 10.0,
            text: "This is a very long lyric line that overflows the narrow menu bar strip"
        )
        state.setTrack(track, lyrics: [line])
        state.updatePlayback(isPlaying: true, position: 10.0)

        let textWidth: CGFloat = 400
        let availableWidth: CGFloat = 160

        XCTAssertFalse(
            KaraokeLineView.isTimelinePaused(
                isPlaying: true,
                karaokeEnabled: state.karaokeAnimationEnabled,
                textWidth: textWidth,
                availableWidth: availableWidth
            ),
            "Timeline must stay active while an overflowing line is playing even with karaoke highlight off"
        )

        let startProgress = KaraokeLineView.scrollProgress(
            state: state,
            at: state.playbackAnchorDate,
            karaokeEnabled: state.karaokeAnimationEnabled
        )
        let startOffset = KaraokeLineView.scrollOffset(
            progress: startProgress,
            textWidth: textWidth,
            availableWidth: availableWidth
        )
        XCTAssertEqual(startProgress, 0.0, accuracy: 0.001)
        XCTAssertEqual(startOffset, 0.0, accuracy: 0.01)

        let midProgress = KaraokeLineView.scrollProgress(
            state: state,
            at: state.playbackAnchorDate.addingTimeInterval(5.0),
            karaokeEnabled: state.karaokeAnimationEnabled
        )
        let midOffset = KaraokeLineView.scrollOffset(
            progress: midProgress,
            textWidth: textWidth,
            availableWidth: availableWidth
        )
        // At 50% of 400pt width with 160pt container: -(0.5 * 400 - 160 * 0.45) = -128.0
        XCTAssertEqual(midProgress, 0.5, accuracy: 0.001)
        XCTAssertEqual(midOffset, -128.0, accuracy: 0.01)

        // When karaoke is off and text fits inside the strip, timeline should pause to save CPU.
        XCTAssertTrue(
            KaraokeLineView.isTimelinePaused(
                isPlaying: true,
                karaokeEnabled: false,
                textWidth: 120,
                availableWidth: availableWidth
            )
        )
        // When playback is paused, timeline must always pause.
        XCTAssertTrue(
            KaraokeLineView.isTimelinePaused(
                isPlaying: false,
                karaokeEnabled: false,
                textWidth: textWidth,
                availableWidth: availableWidth
            )
        )
    }

    func testSweepFrameIntervalRunsAt20FpsInHighPrecisionAnd8FpsInLowCPU() {
        XCTAssertEqual(KaraokeLineView.sweepFrameInterval(lowCPUMode: false), 1.0 / 20.0, accuracy: 0.0001)
        XCTAssertEqual(KaraokeLineView.sweepFrameInterval(lowCPUMode: true), 1.0 / 8.0, accuracy: 0.0001)
    }

    func testActiveWordPopSkipsZeroStrengthAndZeroSpan() {
        let active = LyricsState.WordPop(start: 0.2, end: 0.6, strength: 0.5)
        let zeroStrength = LyricsState.WordPop(start: 0.2, end: 0.6, strength: 0.0)
        let nearZeroStrength = LyricsState.WordPop(start: 0.2, end: 0.6, strength: 0.0005)
        let zeroSpan = LyricsState.WordPop(start: 0.4, end: 0.4, strength: 0.8)

        XCTAssertEqual(KaraokeLineView.activeWordPop(active), active)
        XCTAssertNil(KaraokeLineView.activeWordPop(zeroStrength))
        XCTAssertNil(KaraokeLineView.activeWordPop(nearZeroStrength))
        XCTAssertNil(KaraokeLineView.activeWordPop(zeroSpan))
        XCTAssertNil(KaraokeLineView.activeWordPop(nil))
    }
}
