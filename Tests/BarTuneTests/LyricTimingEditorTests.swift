@testable import BarTune
import XCTest

final class LyricTimingSessionTests: XCTestCase {
    func testLineStampingInOrderAndUndo() {
        var session = LyricTimingSession()
        session.replaceWithPlainText("First line\nSecond line\nThird line")
        XCTAssertEqual(session.lines.count, 3)
        XCTAssertFalse(session.stamp(at: 5.0), "stamping must do nothing when stampingMode is .off")

        session.beginLinePass()
        XCTAssertTrue(session.stamp(at: 12.3))
        XCTAssertTrue(session.stamp(at: 16.8))
        XCTAssertEqual(session.nextLineIndex, 2)
        XCTAssertEqual(session.lines[0].timestamp, 12.3)
        XCTAssertEqual(session.lines[1].timestamp, 16.8)
        XCTAssertNil(session.lines[2].timestamp)

        XCTAssertTrue(session.undoLastStamp())
        XCTAssertEqual(session.nextLineIndex, 1)
        XCTAssertNil(session.lines[1].timestamp)
        XCTAssertEqual(session.lines[0].timestamp, 12.3)

        XCTAssertTrue(session.stamp(at: 17.0))
        XCTAssertTrue(session.stamp(at: 21.5))
        XCTAssertEqual(session.nextLineIndex, 3)
        XCTAssertFalse(session.stamp(at: 25.0), "stamping past the last line returns false")
    }

    func testWordStampingInOrderAndUndo() {
        var session = LyricTimingSession()
        session.replaceWithPlainText("Hello bright world")
        session.beginWordPass(forLine: 0)

        XCTAssertEqual(session.lines[0].words.map(\.text), ["Hello ", "bright ", "world"])
        XCTAssertTrue(session.stamp(at: 10.0))
        XCTAssertTrue(session.stamp(at: 10.6))
        XCTAssertEqual(session.lines[0].timestamp, 10.0, "first word stamp sets unstamped line start")
        XCTAssertEqual(session.nextWordIndex, 2)

        XCTAssertTrue(session.undoLastStamp())
        XCTAssertEqual(session.nextWordIndex, 1)
        XCTAssertNil(session.lines[0].words[1].timestamp)

        XCTAssertTrue(session.stamp(at: 10.7))
        XCTAssertTrue(session.stamp(at: 11.4))
        XCTAssertFalse(session.stamp(at: 12.0))
    }

    func testWordSplittingForSpacedAndCJKText() {
        XCTAssertEqual(
            LyricTimingSession.splitWords(for: "  We are the champions  "),
            ["We ", "are ", "the ", "champions"]
        )
        XCTAssertEqual(
            LyricTimingSession.splitWords(for: "夢ならば"),
            ["夢", "な", "ら", "ば"]
        )
        XCTAssertEqual(
            LyricTimingSession.splitWords(for: "사랑해"),
            ["사", "랑", "해"]
        )
        XCTAssertEqual(
            LyricTimingSession.splitWords(for: "Hello"),
            ["Hello"]
        )
        XCTAssertEqual(
            LyricTimingSession.splitWords(for: "   "),
            []
        )
    }

    func testDurationDerivationForLinesAndWords() {
        var session = LyricTimingSession()
        session.replaceWithPlainText("Alpha beta gamma\nSecond line only\nFinal line")
        session.beginLinePass()
        XCTAssertTrue(session.stamp(at: 10.0))
        XCTAssertTrue(session.stamp(at: 15.0))
        XCTAssertTrue(session.stamp(at: 20.0))
        XCTAssertTrue(session.stampLineEnd(at: 24.5, forLine: 2))

        session.beginWordPass(forLine: 0)
        XCTAssertTrue(session.stamp(at: 10.0))
        XCTAssertTrue(session.stamp(at: 11.2))
        XCTAssertTrue(session.stamp(at: 12.5))

        let built = session.buildLyricLines()
        XCTAssertEqual(built.count, 3)

        // Line 0 runs to Line 1's start (15.0), and its last word runs to Line 0's end (15.0).
        XCTAssertEqual(built[0].timestamp, 10.0, accuracy: 0.001)
        XCTAssertEqual(built[0].duration ?? 0, 5.0, accuracy: 0.001)
        XCTAssertEqual(built[0].words.count, 3)
        XCTAssertEqual(built[0].words[0].duration ?? 0, 1.2, accuracy: 0.001)
        XCTAssertEqual(built[0].words[1].duration ?? 0, 1.3, accuracy: 0.001)
        XCTAssertEqual(built[0].words[2].duration ?? 0, 2.5, accuracy: 0.001)

        // Line 1 has no word stamps, so words must remain empty.
        XCTAssertEqual(built[1].duration ?? 0, 5.0, accuracy: 0.001)
        XCTAssertTrue(built[1].words.isEmpty)

        // Line 2 uses its explicit end stamp (24.5 - 20.0 = 4.5).
        XCTAssertEqual(built[2].duration ?? 0, 4.5, accuracy: 0.001)
    }

    func testNudgeClampingAndOutOfOrderWarningsWithoutSilentReordering() {
        var session = LyricTimingSession(lines: [
            LyricLine(id: 0, timestamp: 0.05, text: "Opening line", words: [
                WordTimestamp(timestamp: 0.05, duration: 0.5, text: "Opening "),
                WordTimestamp(timestamp: 0.55, duration: 0.5, text: "line"),
            ]),
            LyricLine(id: 1, timestamp: 5.0, text: "Second line"),
        ])

        session.nudgeLine(at: 0, by: -0.1)
        XCTAssertEqual(session.lines[0].timestamp, 0.0)
        XCTAssertEqual(session.lines[0].words[0].timestamp, 0.0)
        XCTAssertEqual(session.lines[0].words[1].timestamp ?? 0, 0.5, accuracy: 0.001)

        session.nudgeWord(lineIndex: 0, wordIndex: 0, by: -0.1)
        XCTAssertEqual(session.lines[0].words[0].timestamp, 0.0)

        // Pushing line 0 past line 1 warns without reordering lines.
        session.setLineTimestamp(at: 0, to: 8.0)
        XCTAssertEqual(session.lines.map(\.text), ["Opening line", "Second line"])
        XCTAssertEqual(session.outOfOrderLineIndices(), [1])
        XCTAssertTrue(session.hasOutOfOrderWarnings)
    }

    func testTimeParsingSupportsMinutesSecondsAndCommaDecimals() {
        XCTAssertEqual(LyricTimingSession.parseTime("1:23.45"), 83.45)
        XCTAssertEqual(LyricTimingSession.parseTime("1:23,45"), 83.45)
        XCTAssertEqual(LyricTimingSession.parseTime("42.5"), 42.5)
        XCTAssertNil(LyricTimingSession.parseTime("-1.0"))
        XCTAssertNil(LyricTimingSession.parseTime("1:75.0"))
        XCTAssertEqual(LyricTimingSession.formatTime(83.45), "1:23.45")
    }

    func testRomanizedPreviewsForJapaneseLinesAndWords() {
        let preview = LyricTimingSession.romanizedPreview(forLine: "さよなら、僕らは目を覚ます")
        XCTAssertNotNil(preview)
        XCTAssertFalse(JapaneseRomanizer.containsJapaneseOrCJK(preview ?? ""))
        XCTAssertNil(LyricTimingSession.romanizedPreview(forLine: "Hello world"))

        let words = [EditableWord(text: "固まっ"), EditableWord(text: "て")]
        let wordPreviews = LyricTimingSession.romanizedWordPreviews(for: words)
        XCTAssertEqual(wordPreviews.count, 2)
        XCTAssertTrue(wordPreviews.joined().contains("katamatte"))

        let latinWords = [EditableWord(text: "Hello "), EditableWord(text: "world")]
        XCTAssertEqual(LyricTimingSession.romanizedWordPreviews(for: latinWords), ["", ""])
    }

    func testImportedWordDurationsArePreservedUntilRetimed() {
        var session = LyricTimingSession(lines: [
            LyricLine(id: 0, timestamp: 10.0, duration: 5.0, text: "Alpha beta", words: [
                WordTimestamp(timestamp: 10.0, duration: 0.3, text: "Alpha "),
                WordTimestamp(timestamp: 12.0, duration: 0.4, text: "beta"),
            ]),
        ])

        // Unrelated edit (or no word edit) preserves exact imported durations.
        let preserved = session.buildLyricLines()
        XCTAssertEqual(preserved[0].words[0].duration ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(preserved[0].words[1].duration ?? 0, 0.4, accuracy: 0.001)

        // Retiming word 0 clears its preserved duration so it derives to word 1's start.
        session.nudgeWord(lineIndex: 0, wordIndex: 0, by: 0.1)
        let retimed = session.buildLyricLines()
        XCTAssertEqual(retimed[0].words[0].timestamp, 10.1, accuracy: 0.001)
        XCTAssertEqual(retimed[0].words[0].duration ?? 0, 1.9, accuracy: 0.001)
        XCTAssertEqual(retimed[0].words[1].duration ?? 0, 0.4, accuracy: 0.001)
    }

    func testUndoStampPreservesLaterTextEditsAndAddedLines() {
        var session = LyricTimingSession()
        session.replaceWithPlainText("First\nSecond")
        session.beginLinePass()
        XCTAssertTrue(session.stamp(at: 10.0))

        // Edit line 1's text and add line 2 after stamping line 0.
        session.updateLineText(at: 1, to: "Second edited")
        session.addLine(after: 1, text: "Third added")

        XCTAssertTrue(session.undoLastStamp())
        XCTAssertNil(session.lines[0].timestamp, "stamped timestamp must be undone")
        XCTAssertEqual(session.lines.count, 3, "added line must survive undo")
        XCTAssertEqual(session.lines[1].text, "Second edited", "later text edit must survive undo")
        XCTAssertEqual(session.lines[2].text, "Third added")
    }

    func testUnstampedLineNumbersIdentifyRemainingLines() {
        var session = LyricTimingSession()
        session.replaceWithPlainText("Line one\nLine two\nLine three")
        session.beginLinePass()
        XCTAssertTrue(session.stamp(at: 5.0))
        XCTAssertEqual(session.unstampedLineNumbers, [2, 3])
    }
}

final class CustomLyricsStoreAndSourceResolverTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTuneCustomLyricsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testSourceResolutionWithChoiceAndWithoutChoice() {
        let fetched = [LyricLine(id: 0, timestamp: 5.0, text: "Fetched line")]
        let custom = [LyricLine(id: 0, timestamp: 5.4, text: "Custom line")]

        // No choice keeps today's behaviour: Automatic when engine != .off, Default when .off.
        XCTAssertEqual(
            LyricSourceResolver.resolve(choice: nil, customLines: custom, fetchedLines: fetched, audioSyncEngine: .lyricsAlignment),
            .useAutomatic(fetched)
        )
        XCTAssertEqual(
            LyricSourceResolver.resolve(choice: nil, customLines: custom, fetchedLines: fetched, audioSyncEngine: .whisper),
            .useAutomatic(fetched)
        )
        XCTAssertEqual(
            LyricSourceResolver.resolve(choice: nil, customLines: custom, fetchedLines: fetched, audioSyncEngine: .off),
            .useDefault(fetched)
        )

        // Explicit choices are respected.
        XCTAssertEqual(
            LyricSourceResolver.resolve(choice: .defaultSource, customLines: custom, fetchedLines: fetched, audioSyncEngine: .whisper),
            .useDefault(fetched)
        )
        XCTAssertEqual(
            LyricSourceResolver.resolve(choice: .custom, customLines: custom, fetchedLines: fetched, audioSyncEngine: .whisper),
            .useCustom(custom)
        )
        XCTAssertEqual(
            LyricSourceResolver.resolve(choice: .automatic, customLines: custom, fetchedLines: fetched, audioSyncEngine: .whisper),
            .useAutomatic(fetched)
        )

        // Missing custom lyrics falls back cleanly when .custom was previously selected.
        XCTAssertEqual(
            LyricSourceResolver.resolve(choice: .custom, customLines: nil, fetchedLines: fetched, audioSyncEngine: .lyricsAlignment),
            .useAutomatic(fetched)
        )
        XCTAssertEqual(
            LyricSourceResolver.resolve(choice: .custom, customLines: nil, fetchedLines: fetched, audioSyncEngine: .off),
            .useDefault(fetched)
        )
    }

    func testCustomStoreRoundTripAndIsolationFromCacheClearPruneAndRemover() async throws {
        let customDir = tempDir.appendingPathComponent("custom-lyrics", isDirectory: true)
        let lyricsCacheDir = tempDir.appendingPathComponent("lyrics-cache", isDirectory: true)
        let syncCacheDir = tempDir.appendingPathComponent("audio-sync", isDirectory: true)

        let customStore = CustomLyricsStore(directory: customDir)
        let syncCache = AudioSyncedLyricsCache(directory: syncCacheDir)
        let lyricsCache = LyricsDiskCache(directory: lyricsCacheDir, maxEntries: 10, audioSyncCache: syncCache)

        let track = TrackInfo(id: "spotify:track:custom-1", title: "Starlight", artist: "Nova", album: "", duration: 210, artworkURL: nil)
        let fetchedLines = [LyricLine(id: 0, timestamp: 10.0, text: "Fetched starlight")]
        let customLines = [
            LyricLine(
                id: 0,
                timestamp: 10.25,
                duration: 3.0,
                text: "Custom starlight",
                words: [
                    WordTimestamp(timestamp: 10.25, duration: 1.25, text: "Custom "),
                    WordTimestamp(timestamp: 11.50, duration: 1.75, text: "starlight"),
                ]
            ),
        ]
        let savedDate = Date(timeIntervalSince1970: 1_750_000_000)
        let customRecord = CustomLyricsRecord(
            trackId: track.id,
            title: track.title,
            artist: track.artist,
            savedAt: savedDate,
            lines: customLines
        )

        try customStore.save(customRecord)
        lyricsCache.save(trackId: track.id, lines: fetchedLines)
        syncCache.save(AudioSyncedLyricsRecord(
            trackId: track.id, engine: .whisper, syncedAt: savedDate, medianOffset: 0.1,
            alignedLineCount: 1, sourceLineCount: 1, lines: fetchedLines
        ))

        let loaded = customStore.load(trackId: track.id)
        XCTAssertEqual(loaded, customRecord)

        // Pruning and clearing the lyrics cache must never delete custom lyrics.
        lyricsCache.prune(to: 0)
        XCTAssertEqual(customStore.load(trackId: track.id), customRecord)
        lyricsCache.clear()
        XCTAssertEqual(customStore.load(trackId: track.id), customRecord)

        // OfflineCacheRemover must leave custom lyrics alone too.
        lyricsCache.save(trackId: track.id, lines: fetchedLines)
        let fetcher = LyricsFetcher(diskCache: lyricsCache)
        let translator = LyricsTranslator(diskCache: lyricsCache)
        let remover = OfflineCacheRemover(
            fetcher: fetcher,
            translator: translator,
            lyricsCache: lyricsCache,
            syncCache: syncCache
        )
        let cachedSongs = lyricsCache.listEntries(audioSyncCache: syncCache)
        if let song = cachedSongs.first {
            await remover.remove(song)
        }
        XCTAssertEqual(customStore.load(trackId: track.id), customRecord)
        await remover.removeAll()
        XCTAssertEqual(customStore.load(trackId: track.id), customRecord)

        // Explicit deletion removes only the custom record.
        customStore.remove(trackId: track.id)
        XCTAssertNil(customStore.load(trackId: track.id))
    }

    func testSeekTransportScriptFormatsPOSIXSecondsAndDisablesBrowsers() throws {
        let spotify = SpotifyMonitor.transportScriptSource(
            for: .seek(83.456),
            activeTrackId: "spotify:track:abc",
            runningBundleIds: ["com.spotify.client"]
        )
        XCTAssertEqual(spotify, "tell application \"Spotify\" to set player position to 83.456")

        let music = SpotifyMonitor.transportScriptSource(
            for: .seek(-4.2),
            activeTrackId: "music:track:def",
            runningBundleIds: ["com.apple.Music"]
        )
        XCTAssertEqual(music, "tell application \"Music\" to set player position to 0.000")

        let browser = SpotifyMonitor.transportScriptSource(
            for: .seek(15.0),
            activeTrackId: "browser:ytm:xyz",
            runningBundleIds: ["com.spotify.client", "com.apple.Music"]
        )
        XCTAssertNil(browser, "browser tracks must not seek a native player")

        let chrome = BrowserMediaMonitor.BrowserTarget(bundleId: "com.google.Chrome", appName: "Google Chrome", isSafari: false)
        let safari = BrowserMediaMonitor.BrowserTarget(bundleId: "com.apple.Safari", appName: "Safari", isSafari: true)
        let tab = BrowserTabDescriptor(windowIndex: 1, tabIndex: 2, url: "https://music.youtube.com/watch?v=abc")

        let chromeSeek = try XCTUnwrap(BrowserMediaMonitor.commandScriptSource(for: .seek(42.5), browser: chrome, tab: tab))
        XCTAssertTrue(chromeSeek.contains("m.currentTime = 42.500"))
        XCTAssertTrue(chromeSeek.contains("execute tab 2 of window 1 javascript"))

        let safariPlayPause = try XCTUnwrap(BrowserMediaMonitor.commandScriptSource(for: .playPause, browser: safari, tab: tab))
        XCTAssertTrue(safariPlayPause.contains("m.paused ? m.play() : m.pause()"))
        XCTAssertTrue(safariPlayPause.contains("do JavaScript"))

        // Targeted editor seeks verify the player's current track and never fall back to another player.
        let guardedSpotify = try XCTUnwrap(SpotifyMonitor.transportScriptSource(
            for: .seek(12.5),
            activeTrackId: "spotify:track:abc",
            runningBundleIds: ["com.spotify.client"],
            expectedTrackId: "spotify:track:abc"
        ))
        XCTAssertTrue(guardedSpotify.contains("id of current track as string"))
        XCTAssertTrue(guardedSpotify.contains("spotify:track:abc"))

        let musicExitedNoFallback = SpotifyMonitor.transportScriptSource(
            for: .seek(12.5),
            activeTrackId: "",
            runningBundleIds: ["com.spotify.client"],
            expectedTrackId: "music:12345"
        )
        XCTAssertNil(musicExitedNoFallback, "editor seek for Music must not fall back to Spotify")
    }

    @MainActor
    func testEditorRetainsSessionWhenPlaybackPausesAndTrackClears() throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }
        let state = LyricsState(userDefaults: ud)
        let customStore = CustomLyricsStore(directory: tempDir.appendingPathComponent("custom-pause", isDirectory: true))
        let track = TrackInfo(id: "browser:ytm:pause", title: "Paused Song", artist: "Artist", album: "", duration: 180, artworkURL: nil)
        let lines = [LyricLine(id: 0, timestamp: 5.0, text: "Stay visible")]
        state.setTrack(track, lyrics: lines)

        var deletedTrackIds: [String] = []
        let model = LyricTimingEditorModel(
            state: state,
            customLyricsStore: customStore,
            onSeek: { _, _ in },
            onTogglePlayPause: { _ in },
            onSelectSource: { _, _ in },
            onSaveCustom: { _, _ in throw CustomLyricsStoreError.emptyLyrics },
            onDeleteCustom: { deletedTrackIds.append($0.id) }
        )
        XCTAssertEqual(model.activeTrack?.id, track.id)
        XCTAssertEqual(model.session.lines.count, 1)

        // Pausing a browser track clears state.currentTrack, but the editor must stay open with its session.
        state.setTrack(nil, lyrics: [])
        model.loadCurrentTrack()
        XCTAssertEqual(model.activeTrack?.id, track.id)
        XCTAssertEqual(model.session.lines.count, 1)

        // Save error must keep draft and not switch source to .custom.
        let pending = try XCTUnwrap(model.prepareCustomSave())
        XCTAssertFalse(model.commitCustomSave(pending))
        XCTAssertFalse(model.hasCustomLyrics)
        XCTAssertNotEqual(model.selectedSource, .custom)

        // Unstamped lines block prepareCustomSave and report line numbers.
        model.session.addLine(after: 0, text: "Unstamped second line")
        XCTAssertNil(model.prepareCustomSave())
        XCTAssertTrue(try XCTUnwrap(model.statusMessage).contains("2"))

        // Deleting with a stale captured track must not delete the active track.
        let otherTrack = TrackInfo(id: "spotify:track:other", title: "Other", artist: "Other", album: "", duration: 120, artworkURL: nil)
        model.deleteCustomLyrics(for: otherTrack)
        XCTAssertTrue(deletedTrackIds.isEmpty)
    }

    @MainActor
    func testOutOfOrderCustomLinesStillSelectCorrectActiveLineDuringPlayback() throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }
        let state = LyricsState(userDefaults: ud)
        let track = TrackInfo(id: "spotify:track:unsorted", title: "Unsorted", artist: "Art", album: "", duration: 120, artworkURL: nil)
        let unsorted = [
            LyricLine(id: 0, timestamp: 20.0, text: "Later timestamp first"),
            LyricLine(id: 1, timestamp: 10.0, text: "Earlier timestamp second"),
        ]
        state.setTrack(track, lyrics: unsorted)
        state.updatePlayback(isPlaying: true, position: 15.0)

        XCTAssertEqual(state.currentLineId, 1)
        XCTAssertEqual(state.currentText, "Earlier timestamp second")
        XCTAssertEqual(state.activeLineNextTimestamp, 20.0, accuracy: 0.001)
    }

    @MainActor
    func testCurrentPlaybackPositionExcludesSyncOffset() throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }
        let state = LyricsState(userDefaults: ud)
        let track = TrackInfo(id: "spotify:track:pos", title: "Pos", artist: "Art", album: "", duration: 180, artworkURL: nil)
        state.setTrack(track, lyrics: [LyricLine(id: 0, timestamp: 10.0, text: "Line")])
        state.offsetSeconds = 1.5
        state.updatePlayback(isPlaying: true, position: 25.0, playbackRate: 1.0)
        let halfSecondLater = state.playbackAnchorDate.addingTimeInterval(0.5)

        XCTAssertEqual(state.currentPlaybackPosition(at: halfSecondLater), 25.5, accuracy: 0.001)
    }

    @MainActor
    func testAppDelegateAppliesCustomSourceAndRespectsChoiceOnEngineChange() async throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        state.audioSyncEngine = .whisper

        let customStore = CustomLyricsStore(directory: tempDir.appendingPathComponent("custom", isDirectory: true))
        let lyricsCache = LyricsDiskCache(directory: tempDir.appendingPathComponent("lyrics", isDirectory: true))
        let syncCache = AudioSyncedLyricsCache(directory: tempDir.appendingPathComponent("sync", isDirectory: true))

        let track = TrackInfo(id: "spotify:track:wired", title: "Wired", artist: "Band", album: "", duration: 200, artworkURL: nil)
        let fetchedLines = [LyricLine(id: 0, timestamp: 10.0, text: "Fetched line")]
        lyricsCache.save(trackId: track.id, lines: fetchedLines)

        let audioSyncManager = AudioSyncManager(
            state: state,
            cache: syncCache,
            dependencies: AudioSyncManager.Dependencies(
                capture: NoopAudioCapture(),
                hasScreenCaptureAccess: { false },
                requestScreenCaptureAccess: {},
                locateWhisperServer: { nil },
                resolveWhisperModelPath: { _ in nil },
                launchWhisper: { _, _ in nil },
                whisperChunkDurationSeconds: 12.0
            )
        )
        let appDelegate = AppDelegate(
            state: state,
            lyricsFetcher: LyricsFetcher(diskCache: lyricsCache),
            audioSyncManager: audioSyncManager,
            audioSyncCache: syncCache,
            customLyricsStore: customStore
        )

        appDelegate.handlePlaybackUpdate(PlaybackSnapshot(isRunning: true, isPlaying: true, track: track, position: 12.0))
        await appDelegate.waitForPendingFetch()
        XCTAssertEqual(state.rawLyricLines, fetchedLines)

        // Saving Custom switches per-song choice to .custom, applies Custom lines, and stops audio sync.
        let customLines = [LyricLine(id: 0, timestamp: 10.4, duration: 4.0, text: "Hand-timed line")]
        try appDelegate.saveCustomLyrics(customLines, for: track)
        XCTAssertEqual(state.lyricSourceChoice(for: track.id), .custom)
        XCTAssertEqual(state.rawLyricLines, customLines)
        XCTAssertEqual(state.audioSyncStatus, .idle)

        // Switching to Default restores fetched lines and keeps audio sync idle.
        appDelegate.selectLyricSource(.defaultSource, for: track)
        XCTAssertEqual(state.lyricSourceChoice(for: track.id), .defaultSource)
        XCTAssertEqual(state.rawLyricLines, fetchedLines)
        XCTAssertEqual(state.audioSyncStatus, .idle)

        // Switching back to Custom and deleting Custom falls back to fetched lyrics.
        appDelegate.selectLyricSource(.custom, for: track)
        XCTAssertEqual(state.rawLyricLines, customLines)
        appDelegate.deleteCustomLyrics(for: track)
        XCTAssertNil(customStore.load(trackId: track.id))
        XCTAssertNil(state.lyricSourceChoice(for: track.id))
        XCTAssertEqual(state.rawLyricLines, fetchedLines)
    }
}

private final class NoopAudioCapture: AudioCaptureProviding {
    var onAudioSamples: ((CapturedAudio) -> Void)?
    func start(targetBundleIds: Set<String>) {}
    func stop() {}
}
