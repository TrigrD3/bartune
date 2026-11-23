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

    func testRemovedEnginesReadAsOff() throws {
        let (_, ud, suiteName) = try makeIsolatedState()
        defer { ud.removePersistentDomain(forName: suiteName) }
        ud.set("appleSpeech", forKey: "bartune.audioSyncEngine")
        XCTAssertEqual(LyricsState(userDefaults: ud).audioSyncEngine, .off)

        ud.set("whisper", forKey: "bartune.audioSyncEngine")
        XCTAssertEqual(LyricsState(userDefaults: ud).audioSyncEngine, .off)
        XCTAssertEqual(AudioSyncEngine.allCases, [.off, .lyricsAlignment])
    }

    func testPersistedPreferencesWriteOnlyToInjectedUserDefaultsSuite() throws {
        let standard = UserDefaults.standard
        let trackedKeys = [
            "bartune.hoverMode",
            "bartune.spotlightWidth",
            "bartune.themeMode",
            "bartune.fontOption",
            "bartune.fontWeight",
            "bartune.karaokeEnabled",
            "bartune.showEqualizer",
            "bartune.animateVisualizer",
            "bartune.visualizerStyle",
            "bartune.visualizerColorTheme",
            "bartune.visualizerWidth",
            "bartune.fontSize",
            "bartune.backgroundOpacity",
            "bartune.romanizeJapanese",
            "bartune.romanizeKorean",
            "bartune.romanizeChinese",
            "bartune.translateLyrics",
            "bartune.translationLanguage",
            "bartune.lowCPUMode",
            "bartune.browserMusicEnabled",
            "bartune.browserYouTubeVideosEnabled",
            "bartune.audioSyncEngine",
            "bartune.replaceLyricsWithTranscription",
            "bartune.showSyncBadge",
            "bartune.lyricsColorPreset",
            "bartune.customLyricsColorHex",
            "bartune.karaokeGlowEnabled",
            "bartune.barCornerRadius",
            "bartune.showTrackTitle",
        ]
        let sentinel = "__bartune_test_sentinel__"
        var originalStandard: [String: Any] = [:]
        for key in trackedKeys {
            if let existing = standard.object(forKey: key) {
                originalStandard[key] = existing
            }
            standard.set(sentinel, forKey: key)
        }
        defer {
            for key in trackedKeys {
                if let previous = originalStandard[key] {
                    standard.set(previous, forKey: key)
                } else {
                    standard.removeObject(forKey: key)
                }
            }
        }

        let (state, ud, suiteName) = try makeIsolatedState()
        defer { ud.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(state.browserMusicEnabled)
        XCTAssertFalse(state.browserYouTubeVideosEnabled)

        state.hoverMode = .hideAll
        state.spotlightWidth = 112.0
        state.themeMode = .albumTint
        state.fontOption = .sfMono
        state.fontWeight = .bold
        state.karaokeAnimationEnabled = false
        state.showEqualizer = false
        state.animateVisualizer = false
        state.visualizerStyle = .wave
        state.visualizerColorTheme = .sunset
        state.visualizerWidth = 34.0
        state.fontSize = 14.5
        state.backgroundOpacity = 0.82
        state.romanizeJapanese = false
        state.romanizeKorean = false
        state.romanizeChinese = false
        state.translateLyrics = true
        state.translationLanguage = .spanish
        state.lowCPUMode = false
        state.browserMusicEnabled = false
        state.browserYouTubeVideosEnabled = true
        state.audioSyncEngine = .lyricsAlignment
        state.replaceLyricsWithTranscription = true
        state.showSyncBadge = false
        state.lyricsColorPreset = .electricCyan
        state.customLyricsColorHex = "#123456"
        state.karaokeGlowEnabled = true
        state.barCornerRadius = 11.0
        state.showTrackTitle = false

        for key in trackedKeys {
            XCTAssertEqual(
                standard.string(forKey: key),
                sentinel,
                "Setting \(key) must not write to UserDefaults.standard when an isolated suite is injected"
            )
        }

        let reloaded = LyricsState(userDefaults: ud)
        XCTAssertEqual(reloaded.hoverMode, .hideAll)
        XCTAssertEqual(reloaded.spotlightWidth, 112.0, accuracy: 0.01)
        XCTAssertEqual(reloaded.themeMode, .albumTint)
        XCTAssertEqual(reloaded.fontOption, .sfMono)
        XCTAssertEqual(reloaded.fontWeight, .bold)
        XCTAssertFalse(reloaded.karaokeAnimationEnabled)
        XCTAssertFalse(reloaded.showEqualizer)
        XCTAssertFalse(reloaded.animateVisualizer)
        XCTAssertEqual(reloaded.visualizerStyle, .wave)
        XCTAssertEqual(reloaded.visualizerColorTheme, .sunset)
        XCTAssertEqual(reloaded.visualizerWidth, 34.0, accuracy: 0.01)
        XCTAssertEqual(reloaded.fontSize, 14.5, accuracy: 0.01)
        XCTAssertEqual(reloaded.backgroundOpacity, 0.82, accuracy: 0.01)
        XCTAssertFalse(reloaded.romanizeJapanese)
        XCTAssertFalse(reloaded.romanizeKorean)
        XCTAssertFalse(reloaded.romanizeChinese)
        XCTAssertTrue(reloaded.translateLyrics)
        XCTAssertEqual(reloaded.translationLanguage, .spanish)
        XCTAssertFalse(reloaded.lowCPUMode)
        XCTAssertFalse(reloaded.browserMusicEnabled)
        XCTAssertTrue(reloaded.browserYouTubeVideosEnabled)
        XCTAssertEqual(reloaded.audioSyncEngine, .lyricsAlignment)
        XCTAssertTrue(reloaded.replaceLyricsWithTranscription)
        XCTAssertFalse(reloaded.showSyncBadge)
        XCTAssertEqual(reloaded.lyricsColorPreset, .electricCyan)
        XCTAssertEqual(reloaded.customLyricsColorHex, "#123456")
        XCTAssertTrue(reloaded.karaokeGlowEnabled)
        XCTAssertEqual(reloaded.barCornerRadius, 11.0, accuracy: 0.01)
        XCTAssertFalse(reloaded.showTrackTitle)
    }

    func testLongIntroShowsOverlayBeforeFirstLyricLine() throws {
        let (state, ud, suiteName) = try makeIsolatedState()
        defer { ud.removePersistentDomain(forName: suiteName) }

        let track = TrackInfo(
            id: "track:long-intro",
            title: "Long Intro",
            artist: "Artist",
            album: "",
            duration: 240,
            artworkURL: nil
        )
        state.setTrack(track, lyrics: [
            LyricLine(id: 0, timestamp: 30.0, duration: 4.0, text: "First sung line"),
        ])
        state.updatePlayback(isPlaying: true, position: 1.0)

        XCTAssertEqual(state.currentText, "♪")
        XCTAssertEqual(state.currentLineId, -1)
        XCTAssertNil(state.activeLine)
        XCTAssertTrue(state.shouldShowOverlay)

        state.updatePlayback(isPlaying: true, position: 30.2)
        XCTAssertEqual(state.currentText, "First sung line")
        XCTAssertEqual(state.currentLineId, 0)
        XCTAssertTrue(state.shouldShowOverlay)

        state.updatePlayback(isPlaying: false, position: 30.2)
        XCTAssertFalse(state.shouldShowOverlay)
    }
}
