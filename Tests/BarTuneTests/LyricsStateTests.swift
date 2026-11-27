@testable import BarTune
import AppKit
import Combine
import XCTest

@MainActor
final class LyricsStateTests: XCTestCase {
    private func makeIsolatedState() throws -> (LyricsState, UserDefaults, String) {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        return (LyricsState(userDefaults: ud), ud, suiteName)
    }

    func testOutputLatencyDelaysDisplayWithoutChangingTrackPosition() throws {
        let (state, ud, suiteName) = try makeIsolatedState()
        defer { ud.removePersistentDomain(forName: suiteName) }

        XCTAssertTrue(state.compensateOutputLatency)
        XCTAssertEqual(state.outputLatencySeconds, 0)
        let sample = Date(timeIntervalSinceNow: 60)
        let lead = LyricLine(id: 0, timestamp: 1, duration: 1, text: "Lead", words: [
            WordTimestamp(timestamp: 1.875, duration: 0.125, text: "Lead"),
        ])
        let next = LyricLine(id: 1, timestamp: 2.1, text: "Next")
        let font = NSFont.systemFont(ofSize: 14)
        state.lineTransitionStartsEarly = false
        state.setTrack(nil, lyrics: [lead, next])
        state.offsetSeconds = 0.2
        state.outputLatencySeconds = 0.4
        state.updatePlayback(isPlaying: true, position: 2, playbackRate: 2, sampledAt: sample)

        XCTAssertEqual(state.activeLine, lead)
        XCTAssertEqual(state.liveProgress(at: sample, font: font), 0)
        XCTAssertTrue(state.liveIsWaitingForWord(at: sample))
        XCTAssertNil(state.liveWordPop(at: sample, font: font))
        XCTAssertEqual(state.liveProgress(at: sample.addingTimeInterval(0.05), font: font), 0)
        // At 2×, the word starts 0.1625 s before the sample without compensation.
        // A 0.4 s hardware delay moves its onset to 0.2375 s after the sample.
        let duringWord = sample.addingTimeInterval(0.25)
        XCTAssertEqual(state.liveProgress(at: duringWord, font: font), 0.2, accuracy: 1e-5)
        XCTAssertFalse(state.liveIsWaitingForWord(at: duringWord))
        XCTAssertEqual(try XCTUnwrap(state.liveWordPop(at: duringWord, font: font)).strength, 0.3125, accuracy: 1e-5)
        XCTAssertEqual(state.currentPlaybackPosition(at: duringWord), 2.5, accuracy: 1e-5)

        state.compensateOutputLatency = false
        XCTAssertEqual(state.activeLine, next)
        XCTAssertFalse(LyricsState(userDefaults: ud).compensateOutputLatency)
        state.compensateOutputLatency = true
        XCTAssertEqual(state.activeLine, lead)
        state.outputLatencySeconds = 0.04
        XCTAssertEqual(state.activeLine, next)
        XCTAssertEqual(state.currentPlaybackPosition(at: duringWord), 2.5, accuracy: 1e-5)
    }

    func testLyricReplacementUsesCompensatedDisplayPosition() throws {
        let (state, ud, suiteName) = try makeIsolatedState()
        defer { ud.removePersistentDomain(forName: suiteName) }

        let first = LyricLine(id: 0, timestamp: 1, text: "First")
        let second = LyricLine(id: 1, timestamp: 2, text: "Second")
        state.setTrack(nil, lyrics: [first, second])
        state.translateLyrics = true
        state.lineTransitionStartsEarly = false
        state.outputLatencySeconds = 0.4
        state.updatePlayback(isPlaying: true, position: 2.2, sampledAt: Date(timeIntervalSinceNow: 60))

        let translation = LyricLine(id: 0, timestamp: 1, text: "Translated first")
        state.setTranslatedLines([translation])
        XCTAssertEqual(state.currentText, translation.text)
        state.setTranslatedLines([])
        XCTAssertEqual(state.currentText, first.text)

        let resyncedFirst = LyricLine(id: 0, timestamp: 1.2, text: first.text)
        state.applyAudioSyncedLines([resyncedFirst, second])
        XCTAssertEqual(state.activeLine, resyncedFirst)
        XCTAssertEqual(state.rawLyricLines, [resyncedFirst, second])
    }

    func testClockErrorIsTheOverlayClockMinusThePositionReportedAtTheSampleTime() throws {
        let (state, ud, suiteName) = try makeIsolatedState()
        defer { ud.removePersistentDomain(forName: suiteName) }

        state.updatePlayback(isPlaying: true, position: 42.0, playbackRate: 1.5)
        let anchor = state.playbackAnchorDate
        // 2 s after the anchor the clock reads 45.0; the player reported 44.94 at that moment.
        let error = try XCTUnwrap(state.clockError(reportedPosition: 44.94, at: anchor.addingTimeInterval(2)))
        XCTAssertEqual(error, 0.06, accuracy: 1e-9)

        state.updatePlayback(isPlaying: false, position: 45.0)
        XCTAssertNil(state.clockError(reportedPosition: 45.0, at: Date()))
    }

    func testPlaybackClockAnchorsAtWhenThePlayerReportedThePosition() throws {
        let (state, ud, suiteName) = try makeIsolatedState()
        defer { ud.removePersistentDomain(forName: suiteName) }

        // Spotify reported 30.0 s at a poll's midpoint 0.06 s ago; the clock must already read ~30.06.
        let sampledAt = Date().addingTimeInterval(-0.06)
        state.updatePlayback(isPlaying: true, position: 30.0, sampledAt: sampledAt)
        XCTAssertEqual(state.playbackAnchorDate, sampledAt)
        XCTAssertEqual(try XCTUnwrap(state.clockError(reportedPosition: 30.0, at: sampledAt)), 0, accuracy: 1e-9)

        // A later poll that agrees with the clock leaves it running.
        let nextSample = sampledAt.addingTimeInterval(3)
        state.updatePlayback(isPlaying: true, position: 33.01, sampledAt: nextSample)
        XCTAssertEqual(state.playbackAnchorDate, sampledAt)
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
            "bartune.isolateVocals",
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
        XCTAssertFalse(state.isolateVocals)
        state.isolateVocals = true
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
        XCTAssertTrue(reloaded.isolateVocals)
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

    // MARK: - Romanized lines timed by syllable

    /// The displayed text of `line`, shown after `before` (other lines of the same song).
    private func romanizedText(of line: LyricLine, after before: [LyricLine] = [], set enable: (LyricsState) -> Void) throws -> String {
        let (state, ud, suiteName) = try makeIsolatedState()
        defer { ud.removePersistentDomain(forName: suiteName) }
        enable(state)
        state.applyAudioSyncedLines(before + [line])
        state.updatePlayback(isPlaying: true, position: line.timestamp + 0.1)
        return state.currentText
    }

    private func syllableLine(_ text: String, _ tokens: [String]) -> LyricLine {
        LyricLine(id: 0, timestamp: 10.0, text: text, words: tokens.enumerated().map { index, token in
            WordTimestamp(timestamp: 10.0 + Double(index) * 0.2, duration: 0.2, text: token)
        })
    }

    func testRomajiKeepsALatinWordTimedBySyllableWhole() throws {
        // A Japanese track (one line has kana) shows every line romanized, English lines included.
        let japanese = LyricLine(id: 0, timestamp: 2.0, text: "まだ消えない未来")
        var line = syllableLine("I'd sacrifice an angel", ["I'd ", "sa", "cri", "fice ", "an ", "an", "gel"])
        line = LyricLine(id: 1, timestamp: line.timestamp, text: line.text, words: line.words)
        let text = try romanizedText(of: line, after: [japanese]) { $0.romanizeJapanese = true }
        XCTAssertEqual(text, "I'd sacrifice an angel")
    }

    func testKoreanRomanizationKeepsAWordTimedBySyllableWhole() throws {
        let line = syllableLine("사랑해 너를", ["사", "랑", "해 ", "너", "를"])
        let text = try romanizedText(of: line) { $0.romanizeKorean = true }
        XCTAssertEqual(text.split(separator: " ").count, 2, text)
    }

    func testPinyinKeepsASpaceAfterEachCharacterTimedOnItsOwn() throws {
        let line = syllableLine("我爱你", ["我", "爱", "你"])
        let text = try romanizedText(of: line) { $0.romanizeChinese = true }
        XCTAssertEqual(text.split(separator: " ").count, 3, text)
    }
}
