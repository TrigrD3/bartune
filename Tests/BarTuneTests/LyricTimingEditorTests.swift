@testable import BarTune
import Combine
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

    func testExplicitLineEndPreservedAcrossSaveAndReopenWhenEqualToNextLineStart() {
        var session = LyricTimingSession(lines: [
            LyricLine(id: 0, timestamp: 10.0, text: "Line A"),
            LyricLine(id: 1, timestamp: 15.0, text: "Line B"),
        ])
        session.setLineEndTimestamp(at: 0, to: 15.0)
        let built = session.buildLyricLines()
        let explicitEnds = session.explicitEndLineIndices
        XCTAssertEqual(explicitEnds, [0])

        var reopened = LyricTimingSession(lines: built, explicitEndIndices: explicitEnds)
        XCTAssertEqual(reopened.lines[0].endTimestamp, 15.0)
        reopened.setLineTimestamp(at: 1, to: 17.0)
        let rebuilt = reopened.buildLyricLines()
        XCTAssertEqual(rebuilt[0].duration ?? 0, 5.0, accuracy: 0.001, "explicit end at 15s must not stretch when B moves to 17s")
    }

    func testWordPassKeepsImportedTimestampsWhenOnlySpacingDiffers() {
        var session = LyricTimingSession(lines: [
            LyricLine(id: 0, timestamp: 10.0, text: "Wait  for me", words: [
                WordTimestamp(timestamp: 10.0, duration: 0.4, text: "Wait  "),
                WordTimestamp(timestamp: 10.5, duration: 0.3, text: "for "),
                WordTimestamp(timestamp: 10.9, duration: 0.5, text: "me"),
            ]),
        ])
        session.beginWordPass(forLine: 0)
        XCTAssertEqual(session.lines[0].words.map(\.timestamp), [10.0, 10.5, 10.9])
    }

    func testUndoLineStampRestoresResolvedRowIndexAfterEarlierLineDeleted() {
        var session = LyricTimingSession()
        session.replaceWithPlainText("A\nB\nC")
        session.beginLinePass(from: 1)
        XCTAssertTrue(session.stamp(at: 12.0))
        session.deleteLine(at: 0)
        XCTAssertTrue(session.undoLastStamp())
        XCTAssertEqual(session.nextLineIndex, 0, "cursor must point at B (now index 0), not stale index 1")
        XCTAssertNil(session.lines[0].timestamp)
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
            LyricSourceResolver.resolve(choice: nil, customLines: custom, fetchedLines: fetched, audioSyncEngine: .off),
            .useDefault(fetched)
        )

        // Explicit choices are respected.
        XCTAssertEqual(
            LyricSourceResolver.resolve(choice: .defaultSource, customLines: custom, fetchedLines: fetched, audioSyncEngine: .lyricsAlignment),
            .useDefault(fetched)
        )
        XCTAssertEqual(
            LyricSourceResolver.resolve(choice: .custom, customLines: custom, fetchedLines: fetched, audioSyncEngine: .lyricsAlignment),
            .useCustom(custom)
        )
        XCTAssertEqual(
            LyricSourceResolver.resolve(choice: .automatic, customLines: custom, fetchedLines: fetched, audioSyncEngine: .lyricsAlignment),
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

    func testSkippedSyncStatusExplainsPerSongOverride() {
        let lines = [LyricLine(id: 0, timestamp: 5.0, text: "Line")]

        XCTAssertEqual(
            ResolvedLyricAction.useDefault(lines).skippedSyncStatus(audioSyncEngine: .lyricsAlignment),
            .offForTrack(.defaultSource)
        )
        XCTAssertEqual(
            ResolvedLyricAction.useCustom(lines).skippedSyncStatus(audioSyncEngine: .lyricsAlignment),
            .offForTrack(.custom)
        )
        XCTAssertNil(ResolvedLyricAction.useAutomatic(lines).skippedSyncStatus(audioSyncEngine: .lyricsAlignment))
        // With the engine off globally, nothing is overridden.
        XCTAssertEqual(ResolvedLyricAction.useDefault(lines).skippedSyncStatus(audioSyncEngine: .off), .idle)

        let status = AudioSyncStatus.offForTrack(.defaultSource)
        XCTAssertEqual(status.label, "Off for this song (Default lyrics selected)")
        XCTAssertFalse(status.allowsResync)
        XCTAssertNil(status.overlayBadge)
        XCTAssertTrue(AudioSyncStatus.idle.allowsResync)
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
            trackId: track.id, engine: .lyricsAlignment, syncedAt: savedDate, medianOffset: 0.1,
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
        try customStore.remove(trackId: track.id)
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

        let chromeSeek = try XCTUnwrap(BrowserMediaMonitor.commandScriptSource(
            for: .seek(12.5),
            browser: chrome,
            tab: tab,
            expectedURL: tab.url,
            chapterStart: 300.0
        ))
        XCTAssertTrue(chromeSeek.contains("m.currentTime = 312.500"))
        XCTAssertTrue(chromeSeek.contains("__barTuneActiveMedia"))
        XCTAssertTrue(chromeSeek.contains("location.href !== 'https://music.youtube.com/watch?v=abc'"))
        XCTAssertTrue(chromeSeek.contains("execute tab 2 of window 1 javascript"))

        let safariPlayPause = try XCTUnwrap(BrowserMediaMonitor.commandScriptSource(for: .playPause, browser: safari, tab: tab))
        XCTAssertTrue(safariPlayPause.contains("m.paused ? m.play() : m.pause()"))
        XCTAssertTrue(safariPlayPause.contains("do JavaScript"))

        // Targeted editor seeks strip the monitor's outer "spotify:" prefix and never fall back to another player.
        let guardedSpotify = try XCTUnwrap(SpotifyMonitor.transportScriptSource(
            for: .seek(12.5),
            activeTrackId: "spotify:spotify:track:abc",
            runningBundleIds: ["com.spotify.client"],
            expectedTrackId: "spotify:spotify:track:abc"
        ))
        XCTAssertTrue(guardedSpotify.contains("id of current track as string) is \"spotify:track:abc\""))

        let musicExitedNoFallback = SpotifyMonitor.transportScriptSource(
            for: .seek(12.5),
            activeTrackId: "",
            runningBundleIds: ["com.spotify.client"],
            expectedTrackId: "music:12345"
        )
        XCTAssertNil(musicExitedNoFallback, "editor seek for Music must not fall back to Spotify")
    }

    @MainActor
    func testEditorRetainsSessionWhenPlaybackPausesAndTrackClears() async throws {
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
            onSelectSource: { _, _, _ in [] },
            onSaveCustom: { _, _, _ in throw CustomLyricsStoreError.emptyLyrics },
            onDeleteCustom: {
                deletedTrackIds.append($0.id)
                return []
            }
        )
        await model.customRecordLoad?.value
        XCTAssertEqual(model.activeTrack?.id, track.id)
        XCTAssertEqual(model.session.lines.count, 1)
        XCTAssertFalse(model.hasUnsavedEdits)

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

        // Unstamped lines mark draft dirty, block prepareCustomSave, and report line numbers.
        model.session.addLine(after: 0, text: "Unstamped second line")
        XCTAssertTrue(model.hasUnsavedEdits)
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
        state.audioSyncEngine = .lyricsAlignment

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
                chunkDurationSeconds: 12.0,
                launchLyricsAligner: { _, _ in nil }
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
        XCTAssertEqual(customStore.load(trackId: track.id)?.explicitEndLineIndices, [])
        XCTAssertEqual(state.lyricSourceChoice(for: track.id), .custom)
        XCTAssertEqual(state.rawLyricLines, customLines)
        XCTAssertEqual(state.audioSyncStatus, .offForTrack(.custom))

        // Switching to Default restores fetched lines and keeps audio sync off for this song, even on re-sync.
        appDelegate.selectLyricSource(.defaultSource, for: track, customLines: customLines)
        XCTAssertEqual(state.lyricSourceChoice(for: track.id), .defaultSource)
        XCTAssertEqual(state.rawLyricLines, fetchedLines)
        XCTAssertEqual(state.audioSyncStatus, .offForTrack(.defaultSource))
        state.onResyncCurrentTrack?()
        XCTAssertEqual(state.audioSyncStatus, .offForTrack(.defaultSource))

        // Switching back to Custom and deleting Custom falls back to fetched lyrics.
        appDelegate.selectLyricSource(.custom, for: track, customLines: customLines)
        XCTAssertEqual(state.rawLyricLines, customLines)
        try appDelegate.deleteCustomLyrics(for: track)
        XCTAssertNil(customStore.load(trackId: track.id))
        XCTAssertNil(state.lyricSourceChoice(for: track.id))
        XCTAssertEqual(state.rawLyricLines, fetchedLines)

        // When playback moves to a different browser for the same track ID, selecting Automatic
        // with the editor's stale TrackInfo must apply the latest loaded track's sourceBundleId.
        let movedBrowserTrack = TrackInfo(
            id: track.id,
            title: track.title,
            artist: track.artist,
            album: track.album,
            duration: track.duration,
            artworkURL: track.artworkURL,
            sourceBundleId: "com.apple.Safari"
        )
        appDelegate.handlePlaybackUpdate(PlaybackSnapshot(isRunning: true, isPlaying: true, track: movedBrowserTrack, position: 15.0))
        await appDelegate.waitForPendingFetch()
        appDelegate.selectLyricSource(.automatic, for: track, customLines: nil)
        XCTAssertEqual(state.currentTrack?.sourceBundleId, "com.apple.Safari")
    }

    @MainActor
    func testEditorModelCachesRomajiAndMirrorsPlaybackState() async throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("custom-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let state = LyricsState(userDefaults: ud)
        state.romanizeJapanese = false
        let track = TrackInfo(id: "spotify:track:romaji", title: "Track", artist: "Artist", album: "", duration: 120, artworkURL: nil)
        state.setTrack(track, lyrics: [LyricLine(id: 0, timestamp: 1.0, text: "夢を見る")])

        let model = LyricTimingEditorModel(
            state: state,
            customLyricsStore: CustomLyricsStore(directory: tempDir),
            onSeek: { _, _ in },
            onTogglePlayPause: { _ in },
            onSelectSource: { _, _, _ in [] },
            onSaveCustom: { _, _, _ in },
            onDeleteCustom: { _ in [] }
        )
        await model.customRecordLoad?.value

        XCTAssertFalse(model.isPlaying)
        XCTAssertFalse(model.romanizeJapanese)
        XCTAssertNil(model.romanizedLinePreview(for: "夢を見る"))

        state.updatePlayback(isPlaying: false, position: 12.5)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.pausedPlaybackPosition, 12.5, accuracy: 0.01)

        // Browser pause clears currentTrack and sends position 0; editor must keep the paused playhead position.
        state.setTrack(nil, lyrics: [])
        state.updatePlayback(isPlaying: false, position: 0.0)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.pausedPlaybackPosition, 12.5, accuracy: 0.01)

        state.setTrack(track, lyrics: [LyricLine(id: 0, timestamp: 1.0, text: "夢を見る")])
        state.updatePlayback(isPlaying: true, position: 1.5)
        state.romanizeJapanese = true
        try await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertTrue(model.isPlaying)
        XCTAssertTrue(model.romanizeJapanese)
        let firstPreview = model.romanizedLinePreview(for: "夢を見る")
        XCTAssertNotNil(firstPreview)
        XCTAssertEqual(model.romanizedLinePreview(for: "夢を見る"), firstPreview)
        let words = [EditableWord(text: "夢"), EditableWord(text: "を")]
        XCTAssertEqual(model.romanizedWordPreviews(for: words).count, 2)

        // Korean Romaja & Chinese Pinyin previews
        let koPreview = LyricTimingSession.romanizedPreview(forLine: "사랑해", japanese: false, korean: true, chinese: false)
        XCTAssertNotNil(koPreview)
        XCTAssertNotEqual(koPreview, "사랑해")
        let zhPreview = LyricTimingSession.romanizedPreview(
            forLine: "我爱你",
            japanese: true,
            korean: false,
            chinese: true,
            preferChineseForHan: true
        )
        XCTAssertNotNil(zhPreview)
        XCTAssertNotEqual(zhPreview, "我爱你")
    }

    func testTimelineLayoutMathConvertsCoordinatesAndClampsValues() {
        // Nonzero viewport origin round-trips identically to ViewportTimelineCanvas and hit-testing.
        let xAt15 = TimelineLayoutMath.viewportX(forTime: 15.0, viewportStart: 10.0, pixelsPerSecond: 60.0)
        XCTAssertEqual(xAt15, 300.0, accuracy: 0.001)
        XCTAssertEqual(
            TimelineLayoutMath.time(forViewportX: xAt15, viewportStart: 10.0, pixelsPerSecond: 60.0),
            15.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TimelineLayoutMath.time(forViewportX: -900.0, viewportStart: 5.0, pixelsPerSecond: 60.0),
            0.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TimelineLayoutMath.followedViewportStart(playhead: 50.0, visibleDuration: 20.0, maxStart: 100.0),
            40.0,
            accuracy: 0.001
        )
        XCTAssertEqual(TimelineLayoutMath.clampedShiftedStart(original: 2.0, deltaSeconds: -5.0), 0.0, accuracy: 0.001)

        // Vocal height shaping suppresses floor below threshold and scales loud peaks cleanly.
        XCTAssertEqual(
            TimelineLayoutMath.shapedVocalHeight(db: -50.0, minDB: -45.0, maxDB: -10.0, halfHeight: 40.0),
            0.0,
            accuracy: 0.001
        )
        XCTAssertEqual(
            TimelineLayoutMath.shapedVocalHeight(db: -10.0, minDB: -45.0, maxDB: -10.0, halfHeight: 40.0),
            36.8,
            accuracy: 0.01
        )

        // Overlapping word blocks hit-test front-to-back (matching draw order) at a nonzero viewportStart.
        let crowdedLine = EditableLine(
            text: "a b",
            timestamp: 10.0,
            endTimestamp: 12.0,
            words: [
                EditableWord(text: "a ", timestamp: 10.0),
                EditableWord(text: "b", timestamp: 10.1),
            ]
        )
        // At 60 px/s with viewportStart=10.0: word 0 spans [0, 20], word 1 spans [6, 26]; x=10 overlaps both.
        let wordHit = TimelineLayoutMath.hitTestWord(
            at: CGPoint(x: 10.0, y: 80.0),
            line: crowdedLine,
            lineEnd: 12.0,
            viewportStart: 10.0,
            pixelsPerSecond: 60.0
        )
        XCTAssertEqual(wordHit?.wordIndex, 1)

        // Overlapping line blocks also hit-test front-to-back, returning actual end (not display minimum).
        let overlappingLines = [
            EditableLine(text: "first", timestamp: 10.0, endTimestamp: 10.2),
            EditableLine(text: "second", timestamp: 10.1, endTimestamp: 10.3),
        ]
        let lineHit = TimelineLayoutMath.hitTestLine(
            at: CGPoint(x: 10.0, y: 40.0),
            lines: overlappingLines,
            viewportStart: 10.0,
            pixelsPerSecond: 60.0
        )
        XCTAssertEqual(lineHit?.index, 1)
        XCTAssertEqual(lineHit?.actualEnd ?? -1, 10.3, accuracy: 0.001)

        // Anti-phase stereo (mid = 0, side = 0.5 -> L = +0.5, R = -0.5) still produces full-mix outer peaks.
        var envelope = VocalEnvelope()
        envelope.append(
            mid: Array(repeating: Float(0.0), count: 1600),
            side: Array(repeating: Float(0.5), count: 1600),
            sampleRate: 16000,
            startTime: 40.0,
            rate: 1.0
        )
        XCTAssertEqual(envelope.segments.first?.maxPeaks.first ?? 0, 0.5, accuracy: 0.001)
        XCTAssertEqual(envelope.segments.first?.minPeaks.first ?? 0, -0.5, accuracy: 0.001)
        let total = TimelineLayoutMath.totalDuration(maxLineEnd: 14.0, trackDuration: 20.0, vocalEnvelope: envelope)
        XCTAssertGreaterThan(total, 44.0)
    }

    @MainActor
    func testEditorReloadsWhenLyricsArriveAsynchronouslyForNewTrack() async throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("custom-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let state = LyricsState(userDefaults: ud)
        let trackA = TrackInfo(id: "spotify:track:a", title: "Song A", artist: "Artist", album: "", duration: 120, artworkURL: nil)
        let trackB = TrackInfo(id: "spotify:track:b", title: "Song B", artist: "Artist", album: "", duration: 150, artworkURL: nil)
        state.setTrack(trackA, lyrics: [LyricLine(id: 0, timestamp: 1.0, text: "First song")])

        let model = LyricTimingEditorModel(
            state: state,
            customLyricsStore: CustomLyricsStore(directory: tempDir),
            onSeek: { _, _ in },
            onTogglePlayPause: { _ in },
            onSelectSource: { _, _, _ in [] },
            onSaveCustom: { _, _, _ in },
            onDeleteCustom: { _ in [] }
        )
        await model.customRecordLoad?.value
        XCTAssertEqual(model.session.lines.map(\.text), ["First song"])

        // New track starts with empty lyrics while fetch runs asynchronously.
        let switched = expectation(description: "Editor switched to the second track")
        let trackObserver = model.$activeTrack.first { $0?.id == trackB.id }.sink { _ in switched.fulfill() }
        defer { trackObserver.cancel() }
        state.setTrack(trackB, lyrics: [])
        await fulfillment(of: [switched], timeout: 5)
        await model.customRecordLoad?.value
        XCTAssertEqual(model.activeTrack?.id, trackB.id)
        XCTAssertTrue(model.session.lines.isEmpty)

        // Fetched lyrics arrive for the same track ID.
        let loaded = expectation(description: "Editor loaded both fetched lines")
        let linesObserver = model.$session.first { $0.lines.count == 2 }.sink { _ in loaded.fulfill() }
        defer { linesObserver.cancel() }
        state.setTrack(trackB, lyrics: [
            LyricLine(id: 0, timestamp: 2.0, text: "Second song line 1"),
            LyricLine(id: 1, timestamp: 5.0, text: "Second song line 2"),
        ])
        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertEqual(model.session.lines.map(\.text), ["Second song line 1", "Second song line 2"])
    }

    @MainActor
    func testEditorLoopModeAndBrowserSkipCommands() async throws {
        let chrome = BrowserMediaMonitor.BrowserTarget(bundleId: "com.google.Chrome", appName: "Google Chrome", isSafari: false)
        let tab = BrowserTabDescriptor(windowIndex: 1, tabIndex: 1, url: "https://music.youtube.com/watch?v=test")
        let nextScript = try XCTUnwrap(BrowserMediaMonitor.commandScriptSource(for: .nextTrack, browser: chrome, tab: tab))
        XCTAssertTrue(nextScript.contains(".next-button"))
        let prevScript = try XCTUnwrap(BrowserMediaMonitor.commandScriptSource(for: .previousTrack, browser: chrome, tab: tab))
        XCTAssertTrue(prevScript.contains(".previous-button"))

        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("custom-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let state = LyricsState(userDefaults: ud)
        let track = TrackInfo(id: "spotify:track:loop", title: "Loop Song", artist: "Artist", album: "", duration: 120, artworkURL: nil)
        state.setTrack(track, lyrics: [
            LyricLine(id: 0, timestamp: 10.0, duration: 4.0, text: "Loop me"),
            LyricLine(id: 1, timestamp: 14.0, duration: 4.0, text: "Next line"),
        ])
        state.updatePlayback(isPlaying: true, position: 10.0)

        var soughtTimes: [Double] = []
        let model = LyricTimingEditorModel(
            state: state,
            customLyricsStore: CustomLyricsStore(directory: tempDir),
            onSeek: { _, pos in soughtTimes.append(pos) },
            onTogglePlayPause: { _ in },
            onSelectSource: { _, _, _ in [] },
            onSaveCustom: { _, _, _ in },
            onDeleteCustom: { _ in [] }
        )
        await model.customRecordLoad?.value

        XCTAssertEqual(model.loopMode, .off)
        model.cycleLoopMode()
        XCTAssertEqual(model.loopMode, .line)
        XCTAssertEqual(model.activeLoopRange(), 10.0...14.0)

        let t0 = Date()
        model.checkLoop(at: 14.1, now: t0)
        XCTAssertEqual(soughtTimes, [10.0])
        // Cooldown prevents spamming repeated seeks immediately.
        model.checkLoop(at: 14.2, now: t0.addingTimeInterval(0.1))
        XCTAssertEqual(soughtTimes, [10.0])

        model.cycleLoopMode()
        XCTAssertEqual(model.loopMode, .song)
        XCTAssertEqual(model.activeLoopRange(), 0.0...119.4)
        model.cycleLoopMode()
        XCTAssertEqual(model.loopMode, .off)
        XCTAssertNil(model.activeLoopRange())
    }

    @MainActor
    func testSyncPlayingHighlightFollowsActiveLineAndWord() async throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("custom-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let state = LyricsState(userDefaults: ud)
        let track = TrackInfo(id: "spotify:track:follow", title: "Follow", artist: "Artist", album: "", duration: 120, artworkURL: nil)
        let lines = [
            LyricLine(id: 0, timestamp: 1.0, duration: 4.0, text: "First line"),
            LyricLine(
                id: 1,
                timestamp: 10.0,
                duration: 4.0,
                text: "Hello world",
                words: [
                    WordTimestamp(timestamp: 10.0, duration: 1.0, text: "Hello "),
                    WordTimestamp(timestamp: 11.2, duration: 1.5, text: "world"),
                ]
            ),
        ]
        state.setTrack(track, lyrics: lines)
        state.updatePlayback(isPlaying: true, position: 1.0)

        let model = LyricTimingEditorModel(
            state: state,
            customLyricsStore: CustomLyricsStore(directory: tempDir),
            onSeek: { _, _ in },
            onTogglePlayPause: { _ in },
            onSelectSource: { _, _, _ in [] },
            onSaveCustom: { _, _, _ in },
            onDeleteCustom: { _ in [] }
        )
        await model.customRecordLoad?.value

        model.syncPlayingHighlight(at: 11.5)
        XCTAssertEqual(model.playingLineId, model.session.lines[1].id)
        XCTAssertEqual(model.selectedLineId, model.session.lines[1].id)
        XCTAssertEqual(model.playingWordId, model.session.lines[1].words[1].id)

        // When followPlayback is off, playingLineId updates but selectedLineId stays put.
        model.followPlayback = false
        model.syncPlayingHighlight(at: 2.0)
        XCTAssertEqual(model.playingLineId, model.session.lines[0].id)
        XCTAssertEqual(model.selectedLineId, model.session.lines[1].id)
    }

    @MainActor
    func testTranslateLinePreservesImportedWordDurationsAndLoopTargetStaysPinned() async throws {
        var session = LyricTimingSession(lines: [
            LyricLine(
                id: 0,
                timestamp: 10.0,
                duration: 4.0,
                text: "Hello world",
                words: [
                    WordTimestamp(timestamp: 10.0, duration: 0.35, text: "Hello "),
                    WordTimestamp(timestamp: 12.0, duration: 1.8, text: "world"),
                ]
            ),
        ])
        session.translateLine(
            at: 0,
            originStart: 10.0,
            originEnd: 14.0,
            originWordTimestamps: [10.0, 12.0],
            delta: 2.5
        )
        XCTAssertEqual(session.lines[0].timestamp ?? -1, 12.5, accuracy: 0.001)
        XCTAssertEqual(session.lines[0].endTimestamp ?? -1, 16.5, accuracy: 0.001)
        XCTAssertEqual(session.lines[0].words[0].timestamp ?? -1, 12.5, accuracy: 0.001)
        XCTAssertEqual(session.lines[0].words[0].preservedDuration ?? -1, 0.35, accuracy: 0.001)
        XCTAssertEqual(session.lines[0].words[1].timestamp ?? -1, 14.5, accuracy: 0.001)
        XCTAssertEqual(session.lines[0].words[1].preservedDuration ?? -1, 1.8, accuracy: 0.001)

        // Word duration helper respects preservedDuration over gaps/defaults.
        XCTAssertEqual(
            TimelineLayoutMath.wordDuration(
                word: session.lines[0].words[0],
                wordStart: 12.5,
                nextWordStart: 14.5,
                lineEnd: 16.5
            ),
            0.35,
            accuracy: 0.001
        )

        // Merged Japanese readings collapse consumed tokens without duplicating raw kana.
        let jpWords = [EditableWord(text: "固まっ"), EditableWord(text: "て")]
        let jpSpans = LyricTimingSession.displayWordSpans(for: jpWords, japanese: true, korean: false, chinese: false)
        XCTAssertEqual(jpSpans.count, 1)
        let firstJapaneseSpan = try XCTUnwrap(jpSpans.first)
        XCTAssertEqual(firstJapaneseSpan.sourceRange, 0...1)
        XCTAssertFalse(firstJapaneseSpan.label.contains("て"))

        // Unromanized CJK words preserve source spacing without inserting spaces between characters.
        let rawCJK = [EditableWord(text: "夢"), EditableWord(text: "を"), EditableWord(text: "見"), EditableWord(text: "る")]
        let rawCJKSpans = LyricTimingSession.displayWordSpans(for: rawCJK, japanese: false, korean: false, chinese: false)
        XCTAssertEqual(rawCJKSpans.map(\.previewText).joined(), "夢を見る")

        // Chapter skip navigation picks adjacent chapters and falls back at ends.
        XCTAssertEqual(
            BrowserMediaMonitor.chapterSkipTarget(command: .nextTrack, chapterStart: 0.0, chapterStarts: [0.0, 180.0, 360.0]),
            180.0
        )
        XCTAssertEqual(
            BrowserMediaMonitor.chapterSkipTarget(command: .previousTrack, chapterStart: 360.0, chapterStarts: [0.0, 180.0, 360.0]),
            180.0
        )
        XCTAssertNil(
            BrowserMediaMonitor.chapterSkipTarget(command: .nextTrack, chapterStart: 360.0, chapterStarts: [0.0, 180.0, 360.0])
        )
        XCTAssertNil(
            BrowserMediaMonitor.chapterSkipTarget(command: .previousTrack, chapterStart: 0.0, chapterStarts: [0.0, 180.0, 360.0])
        )

        // Out-of-order lines pick greatest timestamp <= pos; line loop keeps selectedLineId pinned.
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("custom-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let state = LyricsState(userDefaults: ud)
        state.romanizeJapanese = true
        state.romanizeChinese = true
        let track = TrackInfo(
            id: "browser:www.youtube.com:mix|v:abc:ch:0",
            title: "Chapter 1",
            artist: "Artist",
            album: "",
            duration: 20.0,
            artworkURL: nil
        )
        state.setTrack(track, lyrics: [
            LyricLine(id: 0, timestamp: 10.0, duration: 3.0, text: "Later first"),
            LyricLine(id: 1, timestamp: 5.0, duration: 3.0, text: "Earlier second"),
        ])
        state.updatePlayback(isPlaying: true, position: 11.0)

        var soughtTargets: [Double] = []
        var skippedTrackIds: [String] = []
        let model = LyricTimingEditorModel(
            state: state,
            customLyricsStore: CustomLyricsStore(directory: tempDir),
            onSeek: { _, pos in soughtTargets.append(pos) },
            onTogglePlayPause: { _ in },
            onPreviousTrack: { skippedTrackIds.append("prev:\($0)") },
            onNextTrack: { skippedTrackIds.append("next:\($0)") },
            onSelectSource: { _, _, _ in [] },
            onSaveCustom: { _, _, _ in },
            onDeleteCustom: { _ in [] }
        )
        await model.customRecordLoad?.value
        model.syncPlayingHighlight(at: 11.0)
        XCTAssertEqual(model.playingLineId, model.session.lines[0].id)

        // Scrub previews keep LyricsState's shared playback clock untouched and clamp inside chapter duration.
        let anchorBeforeScrub = state.playbackAnchorPosition
        model.previewScrub(to: 35.0)
        XCTAssertEqual(state.playbackAnchorPosition, anchorBeforeScrub, accuracy: 0.001)
        XCTAssertEqual(model.currentEditorPlaybackPosition(), 19.5, accuracy: 0.001)
        XCTAssertTrue(soughtTargets.isEmpty)
        model.endScrub(commit: true)
        XCTAssertEqual(soughtTargets, [19.5])

        // Skip commands bind to the displayed track ID and ignore stale IDs.
        model.nextTrack(expectedTrackId: "spotify:track:stale")
        XCTAssertTrue(skippedTrackIds.isEmpty)
        model.nextTrack(expectedTrackId: track.id)
        XCTAssertEqual(skippedTrackIds, ["next:\(track.id)"])

        // While looping a selected line, follow playback must not overwrite selectedLineId.
        model.selectedLineId = model.session.lines[1].id
        model.loopMode = .line
        model.syncPlayingHighlight(at: 11.5)
        XCTAssertEqual(model.selectedLineId, model.session.lines[1].id)

        // Pasting Chinese lyrics updates preview language so Han lines produce Pinyin.
        model.pastePlainLyrics("我爱你\n永远")
        let pinyin = try XCTUnwrap(model.romanizedLinePreview(for: "我爱你"))
        XCTAssertTrue(pinyin.lowercased().contains("wo"), "expected Chinese Pinyin, got \(pinyin)")
    }

    @MainActor
    func testAutomaticRefreshDefersDuringFieldEditAndRespectsLanguageAndWordEnds() async throws {
        // Han-only line on a Japanese track (preferChineseForHan == false) must not produce Mandarin pinyin.
        XCTAssertNil(
            LyricTimingSession.romanizedPreview(
                forLine: "未来",
                japanese: false,
                korean: false,
                chinese: true,
                preferChineseForHan: false
            )
        )

        // Korean timed syllables keep word boundaries intact without inserting spaces between syllables.
        let koSyllables = [EditableWord(text: "사"), EditableWord(text: "랑 "), EditableWord(text: "해")]
        let koSpans = LyricTimingSession.displayWordSpans(for: koSyllables, japanese: false, korean: true, chinese: false)
        XCTAssertEqual(koSpans.map(\.previewText).joined(), "sarang hae")

        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("custom-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let state = LyricsState(userDefaults: ud)
        state.audioSyncEngine = .lyricsAlignment
        let track = TrackInfo(id: "spotify:track:r2", title: "R2", artist: "Artist", album: "", duration: 120, artworkURL: nil)
        let initialLines = [
            LyricLine(
                id: 0,
                timestamp: 10.0,
                text: "First",
                words: [
                    WordTimestamp(timestamp: 10.0, duration: 0.35, text: "Hi "),
                    WordTimestamp(timestamp: 12.0, duration: 0.5, text: "there"),
                ]
            ),
            LyricLine(id: 1, timestamp: 5.0, text: "Earlier out-of-order"),
            LyricLine(id: 2, timestamp: 20.0, text: "Later"),
        ]
        state.setTrack(track, lyrics: initialLines)
        state.updatePlayback(isPlaying: true, position: 10.1)

        var sought: [Double] = []
        let model = LyricTimingEditorModel(
            state: state,
            customLyricsStore: CustomLyricsStore(directory: tempDir),
            onSeek: { _, pos in sought.append(pos) },
            onTogglePlayPause: { _ in },
            onSelectSource: { _, _, _ in [] },
            onSaveCustom: { _, _, _ in },
            onDeleteCustom: { _ in [] }
        )
        await model.customRecordLoad?.value

        // Implicit line end for out-of-order rows uses next strictly later timestamp (20.0), not row 1 (5.0).
        model.selectedLineId = model.session.lines[0].id
        model.loopMode = .line
        XCTAssertEqual(model.activeLoopRange(), 10.0...20.0)

        // Scrubbing past loop upperBound must not fire a real seek during preview.
        model.previewScrub(to: 25.0)
        model.checkLoop(at: 25.0)
        XCTAssertTrue(sought.isEmpty)
        model.endScrub(commit: false)

        // Playing-word badge clears during rest past a word's preservedDuration.
        model.syncPlayingHighlight(at: 10.2)
        XCTAssertEqual(model.playingWordId, model.session.lines[0].words[0].id)
        model.syncPlayingHighlight(at: 11.2)
        XCTAssertNil(model.playingWordId)

        // Field editing defers automatic refresh so an active TimestampField draft is not destroyed.
        let originalRowId = model.session.lines[0].id
        model.beginFieldEdit()
        state.applyAudioSyncedLines([
            LyricLine(id: 0, timestamp: 10.5, text: "First"),
            LyricLine(id: 1, timestamp: 5.5, text: "Earlier out-of-order"),
            LyricLine(id: 2, timestamp: 20.5, text: "Later"),
        ])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.session.lines[0].id, originalRowId)
        XCTAssertEqual(model.session.lines[0].timestamp ?? -1, 10.0, accuracy: 0.001)

        // Once field editing ends without edits, the deferred refresh applies cleanly.
        model.endFieldEdit()
        XCTAssertEqual(model.session.lines[0].timestamp ?? -1, 10.5, accuracy: 0.001)
    }

    @MainActor
    func testRound3InvariantsPinSelectionBoundLoopsAndAlignExportWithPreview() async throws {
        // Disabled Chinese romanization on a Han track must NOT fall back to Japanese readings.
        XCTAssertNil(
            LyricTimingSession.romanizedPreview(
                forLine: "我爱你",
                japanese: true,
                korean: false,
                chinese: false,
                preferChineseForHan: true
            )
        )

        // Standalone space token in timed words preserves whitespace in both raw and romanized previews.
        let spacedTokens = [EditableWord(text: "Hello"), EditableWord(text: " "), EditableWord(text: "world")]
        let spacedSpans = LyricTimingSession.displayWordSpans(for: spacedTokens, japanese: false, korean: false, chinese: false)
        XCTAssertEqual(spacedSpans.map(\.previewText).joined(), "Hello world")

        let spacedKo = [EditableWord(text: "사랑"), EditableWord(text: " "), EditableWord(text: "해")]
        let spacedKoSpans = LyricTimingSession.displayWordSpans(for: spacedKo, japanese: false, korean: true, chinese: false)
        XCTAssertEqual(spacedKoSpans.map(\.previewText).joined(), "sarang hae")

        // Out-of-order export uses the same playback-order implicit line end as preview (10 -> 15, not 20).
        let outOfOrderSession = LyricTimingSession(lines: [
            LyricLine(id: 0, timestamp: 10.0, text: "Ten"),
            LyricLine(id: 1, timestamp: 20.0, text: "Twenty"),
            LyricLine(id: 2, timestamp: 15.0, text: "Fifteen"),
        ])
        let builtOutOfOrder = outOfOrderSession.buildLyricLines()
        XCTAssertEqual(builtOutOfOrder[0].duration ?? 0, 5.0, accuracy: 0.001)

        // Unbounded final line with a single manually stamped word exports nil duration (not fabricated 0.45s).
        var manualFinal = LyricTimingSession(editableLines: [
            EditableLine(text: "Final", timestamp: 10.0, endTimestamp: nil, words: [EditableWord(text: "Final", timestamp: 10.0)]),
        ])
        let finalLine = try XCTUnwrap(manualFinal.buildLyricLines().first)
        let finalWord = try XCTUnwrap(finalLine.words.first)
        XCTAssertNil(finalLine.duration)
        XCTAssertNil(finalWord.duration)
        manualFinal.stopStamping()

        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("custom-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let state = LyricsState(userDefaults: ud)
        state.audioSyncEngine = .off
        state.romanizeJapanese = true
        state.romanizeChinese = true
        let track = TrackInfo(id: "spotify:track:r3", title: "R3", artist: "Artist", album: "", duration: 120.0, artworkURL: nil)
        // Word-bearing line IS the final line (no later line after it) so word-based extension is exercised directly.
        state.setTrack(track, lyrics: [
            LyricLine(id: 0, timestamp: 10.0, text: "Intro"),
            LyricLine(
                id: 1,
                timestamp: 60.0,
                text: "Long final words",
                words: [
                    WordTimestamp(timestamp: 60.0, duration: 1.0, text: "Long "),
                    WordTimestamp(timestamp: 65.0, duration: 0.5, text: "words"),
                ]
            ),
        ])
        state.updatePlayback(isPlaying: true, position: 60.5)

        var previousTrackRequests: [String] = []
        let model = LyricTimingEditorModel(
            state: state,
            customLyricsStore: CustomLyricsStore(directory: tempDir),
            onSeek: { _, _ in },
            onTogglePlayPause: { _ in },
            onPreviousTrack: { previousTrackRequests.append($0) },
            onSelectSource: { _, _, _ in [] },
            onSaveCustom: { _, _, _ in },
            onDeleteCustom: { _ in [] }
        )
        await model.customRecordLoad?.value

        // Final line with words past +3s stays highlighted at 65.2s; selection stays pinned while editing a field.
        model.selectedLineId = model.session.lines[0].id
        model.beginFieldEdit()
        XCTAssertTrue(model.hasPendingChanges)
        model.syncPlayingHighlight(at: 65.2)
        XCTAssertEqual(model.playingLineId, model.session.lines[1].id)
        XCTAssertEqual(model.playingWordId, model.session.lines[1].words[1].id)
        XCTAssertEqual(model.selectedLineId, model.session.lines[0].id, "selectedLineId must stay pinned while editing a field")
        model.endFieldEdit()

        // Line starting within the track's final 0.6s leaves looping inactive instead of looping earlier audio.
        model.session.setLineTimestamp(at: 1, to: 119.7)
        model.selectedLineId = model.session.lines[1].id
        model.loopMode = .line
        XCTAssertNil(model.activeLoopRange())
        // Line starting before the safety margin (119.0s) clamps cleanly to 119.0...119.4.
        model.session.setLineTimestamp(at: 1, to: 119.0)
        XCTAssertEqual(model.activeLoopRange(), 119.0...119.4)
        model.loopMode = .off

        // Moving a word past the paused playhead immediately clears its playing badge.
        state.updatePlayback(isPlaying: false, position: 65.2)
        try await Task.sleep(nanoseconds: 40_000_000)
        model.session.setLineTimestamp(at: 1, to: 60.0)
        XCTAssertEqual(model.playingWordId, model.session.lines[1].words[1].id)
        model.session.setWordTimestamp(lineIndex: 1, wordIndex: 1, to: 66.0)
        XCTAssertNil(model.playingWordId)

        // Reset clean session via loadCurrentTrack, then verify Automatic <-> Default source refreshes both ways.
        model.loadCurrentTrack()
        state.audioSyncEngine = .lyricsAlignment
        state.applyAudioSyncedLines([
            LyricLine(id: 0, timestamp: 10.2, text: "Intro"),
            LyricLine(id: 1, timestamp: 60.2, text: "Long final words"),
        ])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.selectedSource, .automatic)
        XCTAssertEqual(model.session.lines[0].timestamp ?? -1, 10.2, accuracy: 0.001)

        state.audioSyncEngine = .off
        state.setTrack(track, lyrics: [
            LyricLine(id: 0, timestamp: 10.0, text: "Intro"),
            LyricLine(id: 1, timestamp: 60.0, text: "Long final words"),
        ])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.selectedSource, .defaultSource)
        XCTAssertEqual(model.session.lines[0].timestamp ?? -1, 10.0, accuracy: 0.001)

        // Inline edits on an empty session recompute preview language for Chinese lyrics.
        model.deleteLine(at: 1)
        model.deleteLine(at: 0)
        let added = model.addLine(after: nil)
        model.updateLineText(at: added, to: "我爱你")
        let pinyin = try XCTUnwrap(model.romanizedLinePreview(for: "我爱你"))
        XCTAssertTrue(pinyin.lowercased().contains("wo"), "expected Chinese Pinyin after inline edit, got \(pinyin)")

        // External track change (e.g. menu bar skip) while playing must NOT discard unsaved draft; it freezes A at its last playing position.
        state.updatePlayback(isPlaying: true, position: 42.25)
        try await Task.sleep(nanoseconds: 40_000_000)
        model.syncPlayingHighlight(at: 42.25)
        let nextTrack = TrackInfo(id: "spotify:track:next-external", title: "Next Song", artist: "Artist", album: "", duration: 180, artworkURL: nil)
        state.setTrack(nextTrack, lyrics: [LyricLine(id: 0, timestamp: 1.0, text: "Next lyrics")])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.activeTrack?.id, track.id)
        XCTAssertEqual(model.pendingNewTrack?.id, nextTrack.id)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.currentEditorPlaybackPosition(), 42.25, accuracy: 0.01)
        XCTAssertEqual(model.session.lines.first?.text, "我爱你")

        // Skipping while dirty never auto-discards the draft on a subsequent track change; explicit confirmation is required.
        state.setTrack(track, lyrics: [LyricLine(id: 0, timestamp: 1.0, text: "Original")])
        try await Task.sleep(nanoseconds: 50_000_000)
        model.previousTrack(expectedTrackId: track.id)
        XCTAssertEqual(previousTrackRequests, [track.id])
        model.updateLineText(at: 0, to: "Edited again")
        state.setTrack(nextTrack, lyrics: [LyricLine(id: 0, timestamp: 1.0, text: "Next lyrics")])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.activeTrack?.id, track.id, "track change while dirty must retain draft until explicitly confirmed")
        XCTAssertEqual(model.pendingNewTrack?.id, nextTrack.id)

        // Valid in-range seek targets inside the final 500 ms stay reachable verbatim; only >= duration clamps.
        XCTAssertEqual(model.clampedSeekPosition(119.85), 119.85, accuracy: 0.001)
        XCTAssertEqual(model.clampedSeekPosition(120.5), 119.5, accuracy: 0.001)

        // Explicitly loading current track switches cleanly and clears pendingNewTrack.
        model.loadCurrentTrack()
        await model.customRecordLoad?.value
        XCTAssertEqual(model.activeTrack?.id, nextTrack.id)
        XCTAssertNil(model.pendingNewTrack)

        // Turning Audio Sync OFF on a song with empty Default lyrics still reloads a clean editor to empty Default.
        state.audioSyncEngine = .lyricsAlignment
        state.applyAudioSyncedLines([LyricLine(id: 0, timestamp: 1.5, text: "Synced only")])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.selectedSource, .automatic)
        XCTAssertEqual(model.session.lines.count, 1)

        state.audioSyncEngine = .off
        state.setTrack(nextTrack, lyrics: [])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.selectedSource, .defaultSource)
        XCTAssertTrue(model.session.lines.isEmpty)

        // Exact playback durations preserve 50 ms and 0 ms imported word durations without stretching.
        let shortWord = EditableWord(text: "hi", timestamp: 5.0, preservedDuration: 0.05)
        let zeroWord = EditableWord(text: "x", timestamp: 5.0, preservedDuration: 0.0)
        XCTAssertEqual(TimelineLayoutMath.wordDuration(word: shortWord, wordStart: 5.0, nextWordStart: 8.0), 0.05, accuracy: 0.001)
        XCTAssertEqual(TimelineLayoutMath.wordDuration(word: zeroWord, wordStart: 5.0, nextWordStart: 5.0, lineEnd: 10.0), 0.0, accuracy: 0.001)

        // Measured karaoke preview boundaries reflect proportional font widths ("WWW " is much wider than "iii").
        let boundaries = LyricTimingEditorModel.measureWordBoundaries(pieces: ["WWW ", "iii"])
        XCTAssertEqual(boundaries.count, 3)
        XCTAssertGreaterThan(boundaries[1], 0.70)

        // Translating a line with a short 50 ms explicit duration preserves its exact 50 ms span.
        var shortSession = LyricTimingSession(editableLines: [
            EditableLine(text: "Short", timestamp: 10.0, endTimestamp: 10.05),
        ])
        shortSession.translateLine(at: 0, originStart: 10.0, originEnd: 10.05, originWordTimestamps: [], delta: 2.0)
        XCTAssertEqual(shortSession.lines[0].timestamp ?? -1, 12.0, accuracy: 0.001)
        XCTAssertEqual(shortSession.lines[0].endTimestamp ?? -1, 12.05, accuracy: 0.001)

        // Chapter skip script validates live currentTime inside the exact half-open chapter interval [180, 360).
        let plan = try XCTUnwrap(
            BrowserMediaMonitor.chapterSkipPlan(command: .nextTrack, chapterStart: 180.0, chapterStarts: [0.0, 180.0, 360.0])
        )
        let chrome = BrowserMediaMonitor.BrowserTarget(bundleId: "com.google.Chrome", appName: "Google Chrome", isSafari: false)
        let tab = BrowserTabDescriptor(windowIndex: 1, tabIndex: 1, url: "https://www.youtube.com/watch?v=mix")
        let skipScript = BrowserMediaMonitor.chapterSkipScriptSource(plan: plan, browser: chrome, tab: tab, expectedURL: tab.url)
        XCTAssertTrue(skipScript.contains("m.currentTime < 180.000"))
        XCTAssertTrue(skipScript.contains("m.currentTime >= 360.000"))
        XCTAssertTrue(skipScript.contains("m.currentTime = 360.000"))
    }

    @MainActor
    func testRound2FixesGuardRetainedDraftSkipsRateScaledLoopAudioSyncSourceRefreshAndFinalFallback() async throws {
        let suiteName = "com.bartune.tests.r2.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("custom-r2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = CustomLyricsStore(directory: tempDir)
        let state = LyricsState(userDefaults: ud)
        state.audioSyncEngine = .off
        let trackA = TrackInfo(id: "spotify:track:r2-a", title: "Track A", artist: "Artist", album: "", duration: 120, artworkURL: nil)
        let trackB = TrackInfo(id: "spotify:track:r2-b", title: "Track B", artist: "Artist", album: "", duration: 120, artworkURL: nil)
        let trackC = TrackInfo(id: "spotify:track:r2-c", title: "Track C", artist: "Artist", album: "", duration: 120, artworkURL: nil)
        state.setTrack(trackA, lyrics: [LyricLine(id: 0, timestamp: 50.0, text: "Only final line")])

        var skipCalls: [(String, String)] = []
        var seekCalls: [Double] = []
        let model = LyricTimingEditorModel(
            state: state,
            customLyricsStore: store,
            onSeek: { _, pos in seekCalls.append(pos) },
            onTogglePlayPause: { _ in },
            onPreviousTrack: { skipCalls.append(("prev", $0)) },
            onNextTrack: { skipCalls.append(("next", $0)) },
            onSelectSource: { _, _, _ in state.rawLyricLines },
            onSaveCustom: { _, _, _ in },
            onDeleteCustom: { _ in [] }
        )
        await model.customRecordLoad?.value

        // 1. Final line with no explicit duration/words matches overlay's 4.5 s fallback while exporting nil duration.
        model.selectedLineId = model.session.lines.first?.id
        model.syncPlayingHighlight(at: 54.0)
        XCTAssertEqual(model.playingHighlight.playingLineId, model.session.lines.first?.id)
        model.loopMode = .line
        XCTAssertEqual(model.activeLoopRange(), 50.0...54.5)
        let firstLine = try XCTUnwrap(model.session.buildLyricLines().first)
        XCTAssertNil(firstLine.duration)

        // Entering line loop while playback precedes the selected line immediately seeks to its start.
        seekCalls.removeAll()
        model.loopMode = .off
        model.followPlayback = false
        state.updatePlayback(isPlaying: true, position: 10.0, playbackRate: 1.0)
        try await Task.sleep(nanoseconds: 40_000_000)
        model.loopMode = .line
        XCTAssertEqual(seekCalls, [50.0])
        model.checkLoop(at: 10.0, now: Date().addingTimeInterval(1.0))
        XCTAssertEqual(seekCalls, [50.0, 50.0])
        model.loopMode = .off

        // 2. Song/line loop safety margin scales with playbackRate (4x -> 2.4 s track-time margin = 0.6 s wall time).
        state.updatePlayback(isPlaying: true, position: 10.0, playbackRate: 4.0)
        model.loopMode = .song
        XCTAssertEqual(model.activeLoopRange(), 0.0...117.6)
        model.loopMode = .line
        model.session.setLineTimestamp(at: 0, to: 117.0)
        XCTAssertEqual(model.activeLoopRange(), 117.0...117.6)
        model.session.setLineTimestamp(at: 0, to: 118.0)
        XCTAssertNil(model.activeLoopRange())
        state.updatePlayback(isPlaying: false, position: 10.0, playbackRate: 1.0)
        model.loopMode = .off

        // 3. Changing audioSyncEngine updates source picker immediately on a clean editor even with no raw-line change.
        model.loadCurrentTrack()
        XCTAssertEqual(model.selectedSource, .defaultSource)
        state.audioSyncEngine = .lyricsAlignment
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.selectedSource, .automatic)

        // Paused/idle editor (state.currentTrack == nil) still allows track skips targeting the retained activeTrack.
        state.setTrack(nil, lyrics: [])
        try await Task.sleep(nanoseconds: 40_000_000)
        model.nextTrack(expectedTrackId: trackA.id)
        model.previousTrack(expectedTrackId: trackA.id)
        XCTAssertEqual(skipCalls.count, 2)
        skipCalls.removeAll()
        state.setTrack(trackA, lyrics: [LyricLine(id: 0, timestamp: 50.0, text: "Only final line")])
        try await Task.sleep(nanoseconds: 40_000_000)

        // Dirty draft blocks automatic source refresh on engine toggle.
        model.updateLineText(at: 0, to: "Unsaved edit on A")
        state.audioSyncEngine = .off
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.selectedSource, .automatic)
        XCTAssertEqual(model.session.lines.first?.text, "Unsaved edit on A")

        // 4. Retained draft for A while B is playing rejects skip commands and never discards A on B -> C.
        state.setTrack(trackB, lyrics: [LyricLine(id: 0, timestamp: 1.0, text: "Track B")])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.activeTrack?.id, trackA.id)
        XCTAssertEqual(model.pendingNewTrack?.id, trackB.id)

        model.nextTrack(expectedTrackId: trackA.id)
        model.previousTrack(expectedTrackId: trackA.id)
        XCTAssertTrue(skipCalls.isEmpty)

        state.setTrack(trackC, lyrics: [LyricLine(id: 0, timestamp: 1.0, text: "Track C")])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.activeTrack?.id, trackA.id, "unrelated B -> C change must never discard retained draft A")
        XCTAssertEqual(model.pendingNewTrack?.id, trackC.id)
        XCTAssertEqual(model.session.lines.first?.text, "Unsaved edit on A")

        // 5. Equal-start manual words derive duration matching buildLyricLines() (lineEnd - start), while explicit 0 s is preserved.
        let manualWord = EditableWord(text: "same ", timestamp: 5.0, preservedDuration: nil)
        XCTAssertEqual(TimelineLayoutMath.wordDuration(word: manualWord, wordStart: 5.0, nextWordStart: 5.0, lineEnd: 8.0), 3.0, accuracy: 0.001)
        let importedZero = EditableWord(text: "zero ", timestamp: 5.0, preservedDuration: 0.0)
        XCTAssertEqual(TimelineLayoutMath.wordDuration(word: importedZero, wordStart: 5.0, nextWordStart: 5.0, lineEnd: 8.0), 0.0, accuracy: 0.001)

        // 6. Browser skips and seeks revalidate recording identity (title/artist + duration/mediaId) and chapter intervals.
        let chrome = BrowserMediaMonitor.BrowserTarget(bundleId: "com.google.Chrome", appName: "Google Chrome", isSafari: false)
        let webTab = BrowserTabDescriptor(windowIndex: 1, tabIndex: 1, url: "https://open.spotify.com/")
        let spotifyTarget = BrowserMediaMonitor.ActiveBrowserTarget(
            browser: chrome,
            tab: webTab,
            trackId: "browser:open.spotify.com:Song A|Artist A|d:245",
            expectedURL: webTab.url,
            chapterStart: 0.0,
            chapterStarts: [],
            expectedMediaTitle: "Song A",
            expectedMediaArtist: "Artist A",
            expectedRoundedDuration: 245
        )
        let webNext = try XCTUnwrap(BrowserMediaMonitor.guardedCommandScriptSource(for: .nextTrack, target: spotifyTarget))
        XCTAssertTrue(webNext.contains("location.href !== 'https://open.spotify.com/'"))
        XCTAssertTrue(webNext.contains("liveTitle !== 'Song A'"))
        XCTAssertTrue(webNext.contains("liveArtist !== 'Artist A'"))
        XCTAssertTrue(webNext.contains("Math.round(m.duration) !== 245"))

        let webSeek = try XCTUnwrap(BrowserMediaMonitor.guardedCommandScriptSource(for: .seek(12.0), target: spotifyTarget))
        XCTAssertTrue(webSeek.contains("liveTitle !== 'Song A'"))
        XCTAssertTrue(webSeek.contains("Math.round(m.duration) !== 245"))
        XCTAssertTrue(webSeek.contains("m.currentTime = 12.000"))

        let ytTab = BrowserTabDescriptor(windowIndex: 1, tabIndex: 2, url: "https://www.youtube.com/watch?v=mix")
        let firstChapter = BrowserMediaMonitor.ActiveBrowserTarget(
            browser: chrome,
            tab: ytTab,
            trackId: "browser:www.youtube.com:mix:ch:0",
            expectedURL: ytTab.url,
            chapterStart: 0.0,
            chapterStarts: [0.0, 180.0, 360.0]
        )
        let firstPrev = try XCTUnwrap(BrowserMediaMonitor.guardedCommandScriptSource(for: .previousTrack, target: firstChapter))
        XCTAssertTrue(firstPrev.contains("m.currentTime < 0.000 || m.currentTime >= 180.000"))
        XCTAssertTrue(firstPrev.contains("ytp-prev-button"))

        let chapterSeek = try XCTUnwrap(BrowserMediaMonitor.guardedCommandScriptSource(for: .seek(5.0), target: firstChapter))
        XCTAssertTrue(chapterSeek.contains("m.currentTime < 0.000 || m.currentTime >= 180.000"))
        XCTAssertTrue(chapterSeek.contains("m.currentTime = 5.000"))

        let lastChapter = BrowserMediaMonitor.ActiveBrowserTarget(
            browser: chrome,
            tab: ytTab,
            trackId: "browser:www.youtube.com:mix:ch:360",
            expectedURL: ytTab.url,
            chapterStart: 360.0,
            chapterStarts: [0.0, 180.0, 360.0]
        )
        let lastNext = try XCTUnwrap(BrowserMediaMonitor.guardedCommandScriptSource(for: .nextTrack, target: lastChapter))
        XCTAssertTrue(lastNext.contains("m.currentTime < 360.000"))
        XCTAssertTrue(lastNext.contains("ytp-next-button"))

        // 7. Going idle (currentTrack == nil) clears pendingNewTrack banner while preserving dirty draft A.
        state.setTrack(nil, lyrics: [])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNil(model.pendingNewTrack)
        XCTAssertEqual(model.activeTrack?.id, trackA.id)
        XCTAssertEqual(model.session.lines.first?.text, "Unsaved edit on A")

        // 8. Short 1 s line loop at 4x playback repeats after its 250 ms wall duration instead of waiting 450 ms.
        state.setTrack(trackA, lyrics: [
            LyricLine(id: 0, timestamp: 10.0, duration: 1.0, text: "Short line"),
            LyricLine(id: 1, timestamp: 12.0, duration: 2.0, text: "Later"),
        ])
        model.loadCurrentTrack()
        model.selectedLineId = model.session.lines.first?.id
        state.updatePlayback(isPlaying: true, position: 10.2, playbackRate: 4.0)
        try await Task.sleep(nanoseconds: 40_000_000)
        // Re-anchor inside [10.0, 11.0) right before entering line loop so entry never seeks even under CI load.
        state.playbackAnchorPosition = 10.2
        state.playbackAnchorDate = Date()
        seekCalls.removeAll()
        model.loopMode = .line
        XCTAssertTrue(seekCalls.isEmpty, "entering line loop inside range must not trigger an entry seek")
        let t0 = Date()
        model.checkLoop(at: 11.05, now: t0)
        XCTAssertEqual(seekCalls, [10.0])
        // Still unacknowledged at +250 ms: does not stack another seek before the player responds.
        model.checkLoop(at: 11.05, now: t0.addingTimeInterval(0.25))
        XCTAssertEqual(seekCalls, [10.0])
        // Once the player jumps back into [10.0, 11.0), the next pass repeats right after the 250 ms wall duration.
        model.checkLoop(at: 10.05, now: t0.addingTimeInterval(0.26))
        model.checkLoop(at: 11.05, now: t0.addingTimeInterval(0.27))
        XCTAssertEqual(seekCalls, [10.0, 10.0])
        model.loopMode = .off

        // 9. Partial saved word pass does not cover full line text (so preview keeps full line text),
        // and resizing a sub-200 ms line preserves sub-200 ms precision.
        let partialLine = EditableLine(
            text: "one two three",
            timestamp: 10.0,
            words: [EditableWord(text: "one ", timestamp: 10.0)]
        )
        XCTAssertFalse(LyricTimingEditorModel.wordsCoverFullLineText(partialLine))
        let completeLine = EditableLine(
            text: "one two",
            timestamp: 10.0,
            words: [EditableWord(text: "one ", timestamp: 10.0), EditableWord(text: "two", timestamp: 10.5)]
        )
        XCTAssertTrue(LyricTimingEditorModel.wordsCoverFullLineText(completeLine))
        XCTAssertEqual(
            TimelineLayoutMath.clampedResizedEnd(lineStart: 10.0, originEnd: 10.05, deltaSeconds: -0.01),
            10.04,
            accuracy: 0.0001
        )

        // 10. Confirmed track switch is bound to both draft and destination track IDs (returning to A cancels it).
        state.setTrack(trackA, lyrics: [LyricLine(id: 0, timestamp: 10.0, text: "Draft A")])
        model.loadCurrentTrack()
        model.updateLineText(at: 0, to: "Edited A")
        state.setTrack(trackB, lyrics: [LyricLine(id: 0, timestamp: 1.0, text: "Track B")])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.pendingNewTrack?.id, trackB.id)
        // Playback returns to A before the user clicks Discard & Load for B.
        state.setTrack(trackA, lyrics: [LyricLine(id: 0, timestamp: 10.0, text: "Draft A")])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertFalse(model.loadConfirmedTrack(expectedDraftId: trackA.id, expectedDestinationId: trackB.id))
        XCTAssertEqual(model.session.lines.first?.text, "Edited A", "returning to A must not discard A's draft")

        // 11. Deferred alignment refresh during a clean stamping pass applies once stamping stops.
        state.audioSyncEngine = .lyricsAlignment
        state.setTrack(trackA, lyrics: [LyricLine(id: 0, timestamp: 10.0, text: "Original")])
        model.loadCurrentTrack()
        model.session.beginLinePass(from: 0)
        state.applyAudioSyncedLines([LyricLine(id: 0, timestamp: 10.75, text: "Original")])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.session.lines.first?.timestamp ?? -1, 10.0, accuracy: 0.001, "deferred while stamping")
        model.session.stopStamping()
        XCTAssertEqual(model.session.lines.first?.timestamp ?? -1, 10.75, accuracy: 0.001, "applies once clean pass ends")

        // 12. Short 200 ms line loops only through its actual end (10.2 s), not inflated to 10.4 s.
        state.setTrack(trackA, lyrics: [
            LyricLine(id: 0, timestamp: 10.0, text: "Quick"),
            LyricLine(id: 1, timestamp: 10.2, text: "Next"),
        ])
        model.loadCurrentTrack()
        model.selectedLineId = model.session.lines.first?.id
        model.loopMode = .line
        XCTAssertEqual(model.activeLoopRange(), 10.0...10.2)
        model.loopMode = .off

        // 13. Right-to-left karaoke preview boundaries advance monotonically 0 -> 1 from the RTL leading edge.
        let rtlBoundaries = LyricTimingEditorModel.measureWordBoundaries(pieces: ["שלום ", "עולם"])
        XCTAssertEqual(rtlBoundaries.count, 3)
        XCTAssertEqual(rtlBoundaries[0], 0.0, accuracy: 0.001)
        XCTAssertGreaterThan(rtlBoundaries[1], 0.25)
        XCTAssertLessThan(rtlBoundaries[1], 0.85)
        XCTAssertEqual(rtlBoundaries[2], 1.0, accuracy: 0.001)
        XCTAssertTrue(LyricTimingEditorModel.isRightToLeftLine("שלום עולם"))
        XCTAssertFalse(LyricTimingEditorModel.isRightToLeftLine("Hello world"))

        // 14. Leaving the draft track stops active live stamping; timeline drag pins selectedLineId under Follow;
        // translateWord preserves imported duration; derivedLineEnd preserves exact 0 ms and 50 ms word durations.
        state.setTrack(trackA, lyrics: [
            LyricLine(id: 0, timestamp: 10.0, text: "First"),
            LyricLine(id: 1, timestamp: 20.0, text: "Second"),
        ])
        model.loadCurrentTrack()
        model.followPlayback = true
        state.updatePlayback(isPlaying: true, position: 10.5)
        try await Task.sleep(nanoseconds: 40_000_000)
        model.selectedLineId = model.session.lines[1].id
        model.beginTimelineDrag()
        model.syncPlayingHighlight(at: 10.8)
        XCTAssertEqual(model.selectedLineId, model.session.lines[1].id, "timeline drag must pin selectedLineId")
        model.endTimelineDrag()

        model.updateLineText(at: 0, to: "Dirty for stamp")
        model.session.beginLinePass(from: 0)
        state.setTrack(trackB, lyrics: [LyricLine(id: 0, timestamp: 1.0, text: "B")])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.session.stampingMode, .off, "live stamping must stop when another track becomes pending")

        var wordSession = LyricTimingSession(editableLines: [
            EditableLine(
                text: "Short rest",
                timestamp: 10.0,
                words: [
                    EditableWord(text: "Short ", timestamp: 10.0, preservedDuration: 0.05),
                    EditableWord(text: "rest", timestamp: 16.0, preservedDuration: 0.0),
                ]
            ),
        ])
        wordSession.translateWord(lineIndex: 0, wordIndex: 0, to: 10.2)
        XCTAssertEqual(wordSession.lines[0].words[0].timestamp ?? -1, 10.2, accuracy: 0.001)
        XCTAssertEqual(wordSession.lines[0].words[0].preservedDuration ?? -1, 0.05, accuracy: 0.001)
        let exactFinalEnd = LyricTimingSession.derivedLineEnd(
            for: wordSession.lines[0],
            nextLaterStart: nil,
            fallbackDuration: TimelineLayoutMath.finalLineFallbackDuration
        )
        XCTAssertEqual(exactFinalEnd ?? -1, 16.0, accuracy: 0.001, "0 s preservedDuration must not add 450 ms fallback")

        // 15. Carbon review guards: stampNow ignores Space while editing a field, in-memory partial word passes
        // do not claim complete timed words, and selectSource(.automatic) preserves its statusMessage across ticks.
        state.audioSyncEngine = .lyricsAlignment
        let autoLines = [LyricLine(id: 0, timestamp: 10.0, text: "one two three")]
        state.setTrack(trackA, lyrics: autoLines)
        let statusModel = LyricTimingEditorModel(
            state: state,
            customLyricsStore: store,
            onSeek: { _, _ in },
            onTogglePlayPause: { _ in },
            onSelectSource: { track, _, _ in
                state.setTrack(track, lyrics: autoLines)
                return autoLines
            },
            onSaveCustom: { _, _, _ in },
            onDeleteCustom: { _ in [] }
        )
        await statusModel.customRecordLoad?.value
        statusModel.selectSource(.automatic)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(statusModel.statusMessage, "Switched to Automatic.")

        statusModel.session.beginWordPass(forLine: 0)
        statusModel.beginFieldEdit()
        statusModel.stampNow()
        XCTAssertNil(statusModel.session.lines[0].words[0].timestamp, "stampNow must be ignored while editing a field")
        statusModel.endFieldEdit()

        statusModel.session.setWordTimestamp(lineIndex: 0, wordIndex: 0, to: 10.0)
        XCTAssertFalse(
            LyricTimingEditorModel.hasCompleteTimedWords(statusModel.session.lines[0]),
            "in-memory partial word pass must not trigger word-only preview sweep"
        )
        statusModel.session.setWordTimestamp(lineIndex: 0, wordIndex: 1, to: 10.5)
        statusModel.session.setWordTimestamp(lineIndex: 0, wordIndex: 2, to: 11.0)
        XCTAssertTrue(LyricTimingEditorModel.hasCompleteTimedWords(statusModel.session.lines[0]))
    }

    @MainActor
    func testCodeRabbitEditorRegressions() async throws {
        // 1. Mixed-script romanized display spans preserve leading whitespace on the next content token
        // while keeping unspaced Hangul syllables joined.
        let mixedLeadingSpace = [EditableWord(text: "Hello"), EditableWord(text: " world "), EditableWord(text: "사랑")]
        let mixedSpans = LyricTimingSession.displayWordSpans(for: mixedLeadingSpace, japanese: false, korean: true, chinese: false)
        XCTAssertEqual(mixedSpans.map(\.previewText).joined(), "Hello world sarang")
        let joinedHangul = [EditableWord(text: "사"), EditableWord(text: "랑")]
        let joinedSpans = LyricTimingSession.displayWordSpans(for: joinedHangul, japanese: false, korean: true, chinese: false)
        XCTAssertEqual(joinedSpans.map(\.previewText).joined(), "sarang")

        // 2. Drawing and hit-testing share the same horizontal visibility check for minimum-width blocks.
        let viewportStart = 10.0
        let pps = 60.0
        let peekingWordLine = EditableLine(
            text: "hi",
            timestamp: 9.8,
            words: [EditableWord(text: "hi", timestamp: 9.8, preservedDuration: 0.05)]
        )
        let peekingRect = TimelineLayoutMath.wordBlockRect(
            start: 9.8,
            duration: 0.05,
            viewportStart: viewportStart,
            pixelsPerSecond: pps
        )
        XCTAssertTrue(TimelineLayoutMath.isBlockVisible(peekingRect, viewportWidth: 400))
        XCTAssertNotNil(
            TimelineLayoutMath.hitTestWord(
                at: CGPoint(x: 4, y: 80),
                line: peekingWordLine,
                lineEnd: 9.85,
                viewportStart: viewportStart,
                pixelsPerSecond: pps
            )
        )
        let offscreenWordLine = EditableLine(
            text: "hi",
            timestamp: 9.5,
            words: [EditableWord(text: "hi", timestamp: 9.5, preservedDuration: 0.05)]
        )
        let offscreenRect = TimelineLayoutMath.wordBlockRect(
            start: 9.5,
            duration: 0.05,
            viewportStart: viewportStart,
            pixelsPerSecond: pps
        )
        XCTAssertFalse(TimelineLayoutMath.isBlockVisible(offscreenRect, viewportWidth: 400))
        XCTAssertNil(
            TimelineLayoutMath.hitTestWord(
                at: CGPoint(x: -15, y: 80),
                line: offscreenWordLine,
                lineEnd: 9.55,
                viewportStart: viewportStart,
                pixelsPerSecond: pps
            )
        )

        let suiteName = "com.bartune.tests.coderabbit.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("custom-cr-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let store = CustomLyricsStore(directory: tempDir)
        let state = LyricsState(userDefaults: ud)
        state.audioSyncEngine = .lyricsAlignment
        let trackA = TrackInfo(id: "spotify:track:cr-a", title: "Track A", artist: "Artist", album: "", duration: 120, artworkURL: nil)
        let trackB = TrackInfo(id: "spotify:track:cr-b", title: "Track B", artist: "Artist", album: "", duration: 120, artworkURL: nil)
        state.setTrack(trackA, lyrics: [LyricLine(id: 0, timestamp: 10.0, text: "Original A")])
        state.updatePlayback(isPlaying: true, position: 20.0)

        let envelopeSubject = PassthroughSubject<String, Never>()
        var savedPayloads: [[LyricLine]] = []
        var failNextSave = false
        let model = LyricTimingEditorModel(
            state: state,
            customLyricsStore: store,
            onSeek: { _, _ in },
            onTogglePlayPause: { _ in },
            onSelectSource: { _, _, _ in state.rawLyricLines },
            onSaveCustom: { track, lines, explicitEnds in
                if failNextSave {
                    throw CustomLyricsStoreError.emptyLyrics
                }
                savedPayloads.append(lines)
                try store.save(CustomLyricsRecord(
                    trackId: track.id,
                    title: track.title,
                    artist: track.artist,
                    savedAt: Date(),
                    lines: lines,
                    explicitEndLineIndices: explicitEnds
                ))
                state.setLyricSourceChoice(.custom, for: track.id)
                state.setTrack(track, lyrics: lines)
            },
            onDeleteCustom: { _ in [] },
            vocalEnvelopeDidChange: envelopeSubject.eraseToAnyPublisher()
        )
        await model.customRecordLoad?.value

        // 3a. Failing save on a clean stamping pass ends stamping, automatically recovers the deferred
        // 14.5 s refresh once isCommittingSave clears, and keeps the save error visible.
        model.session.beginLinePass(from: 0)
        state.applyAudioSyncedLines([LyricLine(id: 0, timestamp: 14.5, text: "Original A")])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.session.lines[0].timestamp ?? -1, 10.0, accuracy: 0.001)

        failNextSave = true
        let pendingFailed = try XCTUnwrap(model.prepareCustomSave())
        XCTAssertFalse(model.commitCustomSave(pendingFailed))
        XCTAssertEqual(model.session.lines[0].timestamp ?? -1, 14.5, accuracy: 0.001)
        XCTAssertTrue(try XCTUnwrap(model.statusMessage).contains("Could not save Custom timing"))

        // Failing save on a dirty draft preserves the user's unsaved draft even with a pending refresh.
        model.session.setLineTimestamp(at: 0, to: 11.25)
        model.session.beginLinePass(from: 0)
        state.applyAudioSyncedLines([LyricLine(id: 0, timestamp: 14.9, text: "Original A")])
        try await Task.sleep(nanoseconds: 50_000_000)
        let pendingDirtyFailed = try XCTUnwrap(model.prepareCustomSave())
        XCTAssertFalse(model.commitCustomSave(pendingDirtyFailed))
        XCTAssertEqual(model.session.lines[0].timestamp ?? -1, 11.25, accuracy: 0.001)
        model.loadCurrentTrack()

        // 3b. Separate successful-save case: deferred 15.25 s update must not reload mid-save,
        // and saving commits the prepared 14.9 s draft cleanly.
        failNextSave = false
        model.session.beginLinePass(from: 0)
        state.applyAudioSyncedLines([LyricLine(id: 0, timestamp: 15.25, text: "Original A")])
        try await Task.sleep(nanoseconds: 50_000_000)
        let pending = try XCTUnwrap(model.prepareCustomSave())
        XCTAssertTrue(model.commitCustomSave(pending))
        XCTAssertEqual(savedPayloads.last?.first?.timestamp ?? -1, 14.9, accuracy: 0.001)
        XCTAssertEqual(model.session.lines[0].timestamp ?? -1, 14.9, accuracy: 0.001)
        XCTAssertFalse(model.hasUnsavedEdits)
        XCTAssertEqual(model.selectedSource, .custom)

        // 4. Scrub previews must not overwrite lastPlayingPosition if playback changes tracks mid-scrub.
        state.updatePlayback(isPlaying: true, position: 20.0)
        try await Task.sleep(nanoseconds: 40_000_000)
        model.syncPlayingHighlight(at: 20.0)
        model.updateLineText(at: 0, to: "Dirty A")
        model.previewScrub(to: 80.0)
        state.setTrack(trackB, lyrics: [LyricLine(id: 0, timestamp: 1.0, text: "Track B")])
        state.updatePlayback(isPlaying: false, position: 3.0)
        try await Task.sleep(nanoseconds: 50_000_000)
        model.endScrub(commit: false)
        XCTAssertEqual(model.activeTrack?.id, trackA.id)
        XCTAssertEqual(model.pausedPlaybackPosition, 20.0, accuracy: 0.05, "scrub preview 80 s must not leak into frozen draft position")

        // 5. Confirming the switch to paused track B loads B's paused playhead (3.0 s), not A's (20.0 s).
        XCTAssertTrue(model.loadConfirmedTrack(expectedDraftId: trackA.id, expectedDestinationId: trackB.id))
        await model.customRecordLoad?.value
        XCTAssertEqual(model.activeTrack?.id, trackB.id)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.currentEditorPlaybackPosition(), 3.0, accuracy: 0.05)

        // 6. Publishing a vocal envelope update while paused increments vocalEnvelopeVersion for the active track only.
        let versionBefore = model.vocalEnvelopeVersion
        envelopeSubject.send(trackA.id)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(model.vocalEnvelopeVersion, versionBefore, "unrelated track envelope updates must be ignored")
        envelopeSubject.send(trackB.id)
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertGreaterThan(model.vocalEnvelopeVersion, versionBefore)
    }

    @MainActor
    func testDeferredAudioSyncRefreshAppliesAfterUndoingDirtyDraft() async throws {
        let suiteName = "com.bartune.tests.undo-refresh.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: tempDir)
        }
        let state = LyricsState(userDefaults: defaults)
        let store = CustomLyricsStore(directory: tempDir)
        let track = TrackInfo(id: "undo-refresh", title: "Undo Refresh", artist: "Artist", album: "", duration: 120, artworkURL: nil)
        state.setTrack(track, lyrics: [LyricLine(id: 0, timestamp: 10.0, text: "Line A")])

        let model = LyricTimingEditorModel(
            state: state,
            customLyricsStore: store,
            onSeek: { _, _ in },
            onTogglePlayPause: { _ in },
            onSelectSource: { _, _, _ in state.rawLyricLines },
            onSaveCustom: { _, _, _ in },
            onDeleteCustom: { _ in state.rawLyricLines }
        )
        await model.customRecordLoad?.value
        XCTAssertEqual(model.session.lines[0].timestamp ?? -1, 10.0, accuracy: 0.001)

        // Make an unsaved edit, then deliver a fresh audio-sync update while dirty.
        model.session.setLineTimestamp(at: 0, to: 11.5)
        XCTAssertTrue(model.hasUnsavedEdits)
        state.applyAudioSyncedLines([LyricLine(id: 0, timestamp: 14.25, text: "Line A")])
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(model.session.lines[0].timestamp ?? -1, 11.5, accuracy: 0.001, "dirty edit must be preserved")

        // Undoing back to the baseline makes the draft clean again and must pick up the deferred update.
        model.session.setLineTimestamp(at: 0, to: 10.0)
        await model.customRecordLoad?.value
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertFalse(model.hasUnsavedEdits)
        XCTAssertEqual(model.session.lines[0].timestamp ?? -1, 14.25, accuracy: 0.001)
    }

    func testTimelineLinePlaybackStateUsesActualDurationNotVisualFloor() {
        // An imported 100 ms line keeps a 350 ms minimum visual block width for selection,
        // while live active/sweep math uses its real 100 ms duration.
        let rect = TimelineLayoutMath.lineBlockRect(start: 10.0, duration: 0.1, viewportStart: 0.0, pixelsPerSecond: 100.0)
        XCTAssertEqual(rect.width, 35.0, accuracy: 0.001)

        let mid = TimelineLayoutMath.linePlaybackState(start: 10.0, end: 10.1, playheadTime: 10.05)
        XCTAssertTrue(mid.isActive)
        XCTAssertEqual(mid.sweepFraction, 0.5, accuracy: 0.001)

        let atEnd = TimelineLayoutMath.linePlaybackState(start: 10.0, end: 10.1, playheadTime: 10.1)
        XCTAssertTrue(atEnd.isActive)
        XCTAssertEqual(atEnd.sweepFraction, 1.0, accuracy: 0.001)

        let pastEnd = TimelineLayoutMath.linePlaybackState(start: 10.0, end: 10.1, playheadTime: 10.15)
        XCTAssertFalse(pastEnd.isActive)
        XCTAssertEqual(pastEnd.sweepFraction, 1.0, accuracy: 0.001)
    }
}

private final class NoopAudioCapture: AudioCaptureProviding {
    var onAudioSamples: (@Sendable (CapturedAudio) -> Void)?
    func start(targetBundleIds: Set<String>, sampleRate: Int) {}
    func stop() {}
}
