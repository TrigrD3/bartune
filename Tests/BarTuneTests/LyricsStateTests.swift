@testable import BarTune
import Combine
import XCTest

@MainActor
final class LyricsStateTests: XCTestCase {
    private func makeIsolatedState() throws -> (LyricsState, UserDefaults, String) {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (LyricsState(userDefaults: ud), ud, suiteName)
    }

    func testDirectTrackSwitchToEmptyLyricsClearsPreviousLyric() throws {
        let (state, ud, suiteName) = try makeIsolatedState()
        defer { ud.removePersistentDomain(forName: suiteName) }

        let trackA = TrackInfo(
            id: "track:a",
            title: "Song A",
            artist: "Artist A",
            album: "",
            duration: 180,
            artworkURL: nil
        )
        let trackB = TrackInfo(
            id: "track:b",
            title: "Instrumental B",
            artist: "Artist B",
            album: "",
            duration: 200,
            artworkURL: nil
        )

        state.setTrack(trackA, lyrics: [
            LyricLine(id: 0, timestamp: 1.0, duration: 4.0, text: "Song A lyric"),
        ])
        state.updatePlayback(isPlaying: true, position: 2.0)
        XCTAssertEqual(state.currentText, "Song A lyric")
        XCTAssertEqual(state.currentLineId, 0)
        XCTAssertEqual(state.activeLine?.text, "Song A lyric")
        XCTAssertTrue(state.shouldShowOverlay)

        // Direct switch to a playing track with no lyrics (fetching or instrumental)
        state.setTrack(trackB, lyrics: [])
        state.updatePlayback(isPlaying: true, position: 1.5)

        XCTAssertEqual(state.currentText, "")
        XCTAssertEqual(state.currentLineId, -1)
        XCTAssertNil(state.activeLine)
        XCTAssertEqual(state.activeLineNextTimestamp, 0.0)
        XCTAssertEqual(state.lineProgress, 0.0)
        XCTAssertFalse(state.shouldShowOverlay)
    }

    func testDirectTrackSwitchWithMatchingLineIdDisplaysNewTrackLyric() throws {
        let (state, ud, suiteName) = try makeIsolatedState()
        defer { ud.removePersistentDomain(forName: suiteName) }

        let trackA = TrackInfo(
            id: "track:a",
            title: "Song A",
            artist: "Artist A",
            album: "",
            duration: 180,
            artworkURL: nil
        )
        let trackB = TrackInfo(
            id: "track:b",
            title: "Song B",
            artist: "Artist B",
            album: "",
            duration: 200,
            artworkURL: nil
        )

        state.setTrack(trackA, lyrics: [
            LyricLine(id: 0, timestamp: 1.0, duration: 4.0, text: "Song A opening"),
        ])
        state.updatePlayback(isPlaying: true, position: 2.0)
        XCTAssertEqual(state.currentText, "Song A opening")

        // Switch directly to Track B whose first line reuses id 0
        state.setTrack(trackB, lyrics: [
            LyricLine(id: 0, timestamp: 1.0, duration: 4.0, text: "Song B opening"),
        ])
        state.updatePlayback(isPlaying: true, position: 2.0)

        XCTAssertEqual(state.currentText, "Song B opening")
        XCTAssertEqual(state.activeLine?.text, "Song B opening")
        XCTAssertEqual(state.currentLineId, 0)
    }

    func testTrackSwitchThroughEmptyFetchThenMatchingLineIdDisplaysNewLyric() throws {
        let (state, ud, suiteName) = try makeIsolatedState()
        defer { ud.removePersistentDomain(forName: suiteName) }

        let trackA = TrackInfo(
            id: "track:a",
            title: "Song A",
            artist: "Artist A",
            album: "",
            duration: 180,
            artworkURL: nil
        )
        let trackB = TrackInfo(
            id: "track:b",
            title: "Song B",
            artist: "Artist B",
            album: "",
            duration: 200,
            artworkURL: nil
        )

        state.setTrack(trackA, lyrics: [
            LyricLine(id: 0, timestamp: 1.0, duration: 4.0, text: "Song A opening"),
        ])
        state.updatePlayback(isPlaying: true, position: 2.0)
        XCTAssertEqual(state.currentText, "Song A opening")

        // AppDelegate installs new track with empty lyrics while fetching
        state.setTrack(trackB, lyrics: [])
        state.updatePlayback(isPlaying: true, position: 1.2)
        XCTAssertEqual(state.currentText, "")
        XCTAssertEqual(state.currentLineId, -1)

        // Lyrics arrive with matching numeric line ID 0
        state.setTrack(trackB, lyrics: [
            LyricLine(id: 0, timestamp: 1.0, duration: 5.0, text: "Song B opening"),
        ])
        state.updatePlayback(isPlaying: true, position: 1.5)
        XCTAssertEqual(state.currentText, "Song B opening")
        XCTAssertEqual(state.activeLine?.text, "Song B opening")
    }

    func testPlayingEmptyLyricsDoesNotEmitRepeatedObjectWillChange() throws {
        let (state, ud, suiteName) = try makeIsolatedState()
        defer { ud.removePersistentDomain(forName: suiteName) }

        let track = TrackInfo(
            id: "track:inst",
            title: "Instrumental",
            artist: "Artist",
            album: "",
            duration: 180,
            artworkURL: nil
        )
        state.setTrack(track, lyrics: [])
        state.updatePlayback(isPlaying: true, position: 1.0)

        var changeCount = 0
        let cancellable = state.objectWillChange.sink { _ in
            changeCount += 1
        }
        defer { cancellable.cancel() }

        for step in 1...50 {
            state.updatePlayback(isPlaying: true, position: 1.0 + Double(step) * 0.1)
        }

        XCTAssertEqual(changeCount, 0, "Repeated ticks on an instrumental track must not trigger SwiftUI redraws")
    }
}
