@testable import BarTune
import Foundation
import XCTest

final class AudioLyricsAlignerTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bartune-audio-sync-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    func testTokenizeLinePreservesExactText() {
        let line = "Hello, world! Don't stop."
        let tokens = LyricsAudioAligner.tokenizeLine(line)
        XCTAssertEqual(tokens.map(\.display).joined(), line)
        XCTAssertEqual(tokens.map(\.normalized), ["hello", "world", "dont", "stop"])
    }

    func testAlignGeneratesWordTimestampsAndInterpolatesGaps() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "We are the champions"),
        ]
        // Recognize "We" and "champions" — "are" and "the" should be interpolated smoothly in between.
        let recognized = [
            RecognizedAudioWord(text: "we", startTime: 10.5, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "champions", startTime: 12.0, duration: 0.8, confidence: 0.95),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized)
        XCTAssertEqual(result.matchedLineCount, 1)
        XCTAssertEqual(result.matchedWordCount, 2)
        XCTAssertEqual(result.lines.count, 1)

        let aligned = result.lines[0]
        XCTAssertEqual(aligned.words.count, 4)
        XCTAssertEqual(aligned.words.map(\.text).joined(), "We are the champions")
        XCTAssertEqual(aligned.timestamp, 10.5, accuracy: 0.01)
        XCTAssertEqual(aligned.words[0].timestamp, 10.5, accuracy: 0.01)
        XCTAssertEqual(aligned.words[3].timestamp, 12.0, accuracy: 0.01)
        // Interpolated words must remain strictly monotonic between anchor 0 and anchor 3.
        XCTAssertGreaterThan(aligned.words[1].timestamp, aligned.words[0].timestamp)
        XCTAssertGreaterThan(aligned.words[2].timestamp, aligned.words[1].timestamp)
        XCTAssertLessThan(aligned.words[2].timestamp, aligned.words[3].timestamp)
    }

    func testAlignComputesMedianOffsetAndShiftsUnsungLines() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "First line here"),
            LyricLine(id: 1, timestamp: 15.0, text: "Second line now"),
            LyricLine(id: 2, timestamp: 30.0, text: "Future unsung line"),
        ]
        // Actual audio is shifted +2.0s later than fetched LRC.
        let recognized = [
            RecognizedAudioWord(text: "first", startTime: 12.0, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "line", startTime: 12.4, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "here", startTime: 12.8, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "second", startTime: 17.0, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "line", startTime: 17.4, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "now", startTime: 17.8, duration: 0.3, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized)
        XCTAssertEqual(result.matchedLineCount, 2)
        XCTAssertNotNil(result.medianOffset)
        XCTAssertEqual(result.medianOffset ?? 0, 2.0, accuracy: 0.05)
        // Future unsung line should also be shifted by the +2.0s median offset.
        XCTAssertEqual(result.lines[2].timestamp, 32.0, accuracy: 0.05)
    }

    /// Heard words from SiM's "The Rumbling", where "things" was stretched past the next line's first "I".
    func testLineStartingInsideTheStretchedLastWordOfTheLineBeforeStillAligns() throws {
        let lines = [
            LyricLine(id: 0, timestamp: 20.68, text: "All I ever wanted to do was do right things"),
            LyricLine(id: 1, timestamp: 24.43, text: "I never wanted to be the king, I swear"),
        ]
        let heard: [(String, Double, Double)] = [
            ("All", 21.20, 0.16), ("I", 21.40, 0.13), ("ever", 21.56, 0.35), ("wanted", 21.94, 0.48),
            ("to", 22.56, 0.15), ("do", 22.74, 0.17), ("was", 22.94, 0.16), ("do", 23.16, 0.17),
            ("right", 23.36, 0.50), ("things", 23.97, 0.56),
            ("I", 24.09, 0.43), ("never", 24.81, 0.41), ("wanted", 25.25, 0.36), ("to", 25.65, 0.13),
            ("be", 25.85, 0.39), ("the", 26.27, 0.22), ("king,", 26.51, 0.51), ("I", 27.11, 0.56),
            ("swear", 27.69, 3.64),
        ]
        let recognized = heard.map { RecognizedAudioWord(text: $0.0, startTime: $0.1, duration: $0.2, confidence: 0.1) }

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(result.lines[1].timestamp, 24.09, accuracy: 0.01)
        // The first line gives up its overlapping tail instead of the second line losing its match.
        let first = result.lines[0]
        let firstEnd = first.timestamp + (first.duration ?? 0)
        XCTAssertEqual(firstEnd, 24.09, accuracy: 0.01)
        let lastWord = try XCTUnwrap(first.words.last)
        XCTAssertLessThanOrEqual(lastWord.timestamp + (lastWord.duration ?? 0), 24.09 + 0.001)
    }

    func testLineStartingWithin50msOfPreviousLastWordStillAligns() throws {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "love you"),
            LyricLine(id: 1, timestamp: 12.0, text: "now"),
        ]
        let recognized = [
            RecognizedAudioWord(text: "love", startTime: 10.0, duration: 0.4, confidence: 0.9),
            RecognizedAudioWord(text: "you", startTime: 11.90, duration: 0.50, confidence: 0.9),
            RecognizedAudioWord(text: "now", startTime: 11.94, duration: 0.40, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(result.lines[1].timestamp, 11.94, accuracy: 0.005)
        let first = result.lines[0]
        XCTAssertEqual(first.timestamp + (first.duration ?? 0), 11.94, accuracy: 0.005)
        let lastWord = try XCTUnwrap(first.words.last)
        XCTAssertEqual(lastWord.timestamp + (lastWord.duration ?? 0), 11.94, accuracy: 0.005)
    }

    func testAudioSyncedLyricsCacheDiscardsRemovedEngineRecords() throws {
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        for removedEngine in ["appleSpeech", "whisper"] {
            let trackId = "spotify:track:\(removedEngine)"
            cache.save(
                AudioSyncedLyricsRecord(
                    trackId: trackId,
                    engine: .lyricsAlignment,
                    syncedAt: Date(),
                    medianOffset: 0.1,
                    alignedLineCount: 1,
                    lines: [LyricLine(id: 0, timestamp: 1.0, text: "Line")]
                )
            )
            let url = cache.fileURL(forCacheKey: LyricsDiskCache.cacheKey(for: trackId))
            let json = try String(contentsOf: url, encoding: .utf8)
            try json
                .replacingOccurrences(of: "\"lyricsAlignment\"", with: "\"\(removedEngine)\"")
                .write(to: url, atomically: true, encoding: .utf8)

            XCTAssertNil(cache.load(trackId: trackId))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testAudioSyncedLyricsCacheRoundTripAndClear() {
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let lines = [
            LyricLine(
                id: 0,
                timestamp: 1.25,
                duration: 2.0,
                text: "Synced line",
                words: [
                    WordTimestamp(timestamp: 1.25, duration: 0.9, text: "Synced "),
                    WordTimestamp(timestamp: 2.15, duration: 1.1, text: "line"),
                ]
            ),
        ]
        let record = AudioSyncedLyricsRecord(
            trackId: "spotify:track:sync-test",
            engine: .lyricsAlignment,
            syncedAt: Date(timeIntervalSince1970: 1_700_000_000),
            medianOffset: 0.4,
            alignedLineCount: 1,
            lines: lines
        )

        cache.save(record)
        let loaded = cache.load(trackId: "spotify:track:sync-test")
        XCTAssertEqual(loaded, record)
        XCTAssertEqual(cache.stats().count, 1)
        XCTAssertGreaterThan(cache.stats().bytes, 0)

        cache.remove(trackId: "spotify:track:sync-test")
        XCTAssertNil(cache.load(trackId: "spotify:track:sync-test"))

        cache.save(record)
        cache.clear()
        XCTAssertEqual(cache.stats().count, 0)
    }

    @MainActor
    func testLyricsStatePersistsAudioSyncSettings() throws {
        let suiteName = "bartune.test.audiosync.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        XCTAssertEqual(state.audioSyncEngine, .off)

        state.audioSyncEngine = .lyricsAlignment

        let reloaded = LyricsState(userDefaults: ud)
        XCTAssertEqual(reloaded.audioSyncEngine, .lyricsAlignment)
    }

    @MainActor
    func testCachedTrackSkipsLiveResyncAndAppliesCachedWordTimestamps() throws {
        let suiteName = "bartune.test.cachedskip.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        state.audioSyncEngine = .lyricsAlignment

        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let track = TrackInfo(
            id: "spotify:track:already-cached",
            title: "Cached Song",
            artist: "Artist",
            album: "Album",
            duration: 180,
            artworkURL: nil
        )
        let rawLines = [LyricLine(id: 0, timestamp: 10.0, text: "Hello world")]
        let cachedLines = [
            LyricLine(
                id: 0,
                timestamp: 10.4,
                duration: 1.8,
                text: "Hello world",
                words: [
                    WordTimestamp(timestamp: 10.4, duration: 0.8, text: "Hello "),
                    WordTimestamp(timestamp: 11.2, duration: 1.0, text: "world"),
                ]
            ),
        ]
        cache.save(
            AudioSyncedLyricsRecord(
                trackId: track.id,
                engine: .lyricsAlignment,
                syncedAt: Date(),
                medianOffset: 0.4,
                alignedLineCount: 1,
                lines: cachedLines
            )
        )

        state.setTrack(track, lyrics: rawLines)
        let manager = AudioSyncManager(state: state, cache: cache)
        manager.handleTrackLoaded(track: track, rawLines: rawLines)

        XCTAssertFalse(manager.isLiveSyncActive)
        XCTAssertEqual(state.audioSyncStatus, .cached(.lyricsAlignment))
        XCTAssertEqual(state.rawLyricLines, cachedLines)
    }

    func testAlignReplacesTextWithTranscribedWordsWhenEnabled() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, duration: 2.5, text: "Actual written words"),
        ]
        let recognized = [
            RecognizedAudioWord(text: "actual", startTime: 10.1, duration: 0.4, confidence: 0.92),
            RecognizedAudioWord(text: "sung", startTime: 10.6, duration: 0.4, confidence: 0.90),
            RecognizedAudioWord(text: "words", startTime: 11.1, duration: 0.5, confidence: 0.95),
        ]

        let result = LyricsAudioAligner.align(
            lines: lines,
            recognizedWords: recognized,
            replaceTextWithTranscription: true
        )

        XCTAssertEqual(result.matchedLineCount, 1)
        XCTAssertEqual(result.lines[0].text, "actual sung words")
        XCTAssertEqual(result.lines[0].words.count, 3)
        XCTAssertEqual(result.lines[0].words[0].timestamp, 10.1, accuracy: 0.01)
        XCTAssertEqual(result.lines[0].words[2].timestamp, 11.1, accuracy: 0.01)
    }

    func testOverlaySyncBadgeMapsStatusesCorrectly() {
        XCTAssertNil(AudioSyncStatus.idle.overlayBadge)
        XCTAssertNil(AudioSyncStatus.permissionRequired("Needed").overlayBadge)
        XCTAssertNil(AudioSyncStatus.unavailable("Missing").overlayBadge)

        let cachedBadge = AudioSyncStatus.cached(.lyricsAlignment).overlayBadge
        XCTAssertEqual(cachedBadge?.text, "Synced")
        XCTAssertEqual(cachedBadge?.isSynced, true)

        let listeningBadge = AudioSyncStatus.syncing(engine: .lyricsAlignment, alignedLines: 0, totalLines: 10).overlayBadge
        XCTAssertEqual(listeningBadge?.text, "Listening")
        XCTAssertEqual(listeningBadge?.isSynced, false)

        let syncingBadge = AudioSyncStatus.syncing(engine: .lyricsAlignment, alignedLines: 3, totalLines: 10).overlayBadge
        XCTAssertEqual(syncingBadge?.text, "Syncing")
        XCTAssertEqual(syncingBadge?.isSynced, false)
    }

    @MainActor
    func testLyricsStatePersistsReplaceWithTranscriptionSetting() throws {
        let suiteName = "bartune.test.replacetranscript.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        XCTAssertFalse(state.replaceLyricsWithTranscription)

        state.replaceLyricsWithTranscription = true
        let reloaded = LyricsState(userDefaults: ud)
        XCTAssertTrue(reloaded.replaceLyricsWithTranscription)
    }

    @MainActor
    func testLyricsStatePersistsShowSyncBadgeSetting() throws {
        let suiteName = "bartune.test.syncbadge.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        XCTAssertTrue(state.showSyncBadge)

        state.showSyncBadge = false
        let reloaded = LyricsState(userDefaults: ud)
        XCTAssertFalse(reloaded.showSyncBadge)
    }

    func testDetectsSpeechLocaleFromLyricsLanguage() {
        let jaLines = [LyricLine(id: 0, timestamp: 1.0, text: "闇夜を駆け抜けて どこへ向かう")]
        XCTAssertEqual(LyricsLanguageDetector.detectSpeechLocale(for: jaLines).identifier, "ja-JP")

        let koLines = [LyricLine(id: 0, timestamp: 1.0, text: "사랑해요 오늘 밤 별이 빛나")]
        XCTAssertEqual(LyricsLanguageDetector.detectSpeechLocale(for: koLines).identifier, "ko-KR")

        let zhLines = [LyricLine(id: 0, timestamp: 1.0, text: "天青色等烟雨而我在等你")]
        XCTAssertEqual(LyricsLanguageDetector.detectSpeechLocale(for: zhLines).identifier, "zh-CN")

        let enLines = [LyricLine(id: 0, timestamp: 1.0, text: "We are the champions my friend")]
        XCTAssertEqual(LyricsLanguageDetector.detectSpeechLocale(for: enLines).identifier, "en-US")
    }

    // MARK: - #139: Japanese recognizer output arrives as characters or whole phrases

    /// Per-character tokens for synthesized Japanese speech.
    private let japaneseCharacterTokens: [(String, Double, Double)] = [
        ("見", 0.00, 0.18), ("つ", 0.18, 0.31), ("け", 0.31, 0.39), ("出", 0.39, 0.52), ("して", 0.52, 0.86),
        ("く", 0.86, 0.92), ("れた", 0.92, 1.19), ("忘", 2.38, 2.51), ("れる", 2.51, 2.92), ("こと", 2.92, 3.18),
        ("ない", 3.18, 3.44), ("君", 3.44, 3.64), ("の", 3.64, 3.84), ("笑", 3.84, 3.97), ("顔", 3.97, 4.30),
    ]

    func testAlignsJapaneseLinesFromPerCharacterWords() {
        let lines = [
            LyricLine(id: 0, timestamp: 20.3, text: "見つけ出してくれた"),
            LyricLine(id: 1, timestamp: 22.6, text: "忘れることない 君の笑顔"),
        ]
        let recognized = japaneseCharacterTokens.map {
            RecognizedAudioWord(text: $0.0, startTime: 20.0 + $0.1, duration: $0.2 - $0.1, confidence: 0.9)
        }

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized)

        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(result.lines[0].timestamp, 20.0, accuracy: 0.01)
        XCTAssertEqual(result.lines[1].timestamp, 22.38, accuracy: 0.01)
        XCTAssertEqual(result.lines[1].words.first(where: { $0.text.hasPrefix("君") })?.timestamp ?? 0, 23.44, accuracy: 0.01)
    }

    func testAlignsJapaneseLineFromOneApplePhraseSegment() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "楽しいことばかり"),
            LyricLine(id: 1, timestamp: 14.0, text: "溢れ出す涙"),
        ]
        let recognized = [
            RecognizedAudioWord(text: "楽しいことばかり", startTime: 10.4, duration: 2.0, confidence: 0.6),
            RecognizedAudioWord(text: "溢れ出す涙", startTime: 14.3, duration: 1.5, confidence: 0.6),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized)

        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(result.lines[0].timestamp, 10.4, accuracy: 0.01)
    }

    func testSpeechLocaleFollowsTheMajorityLanguageOfMixedLyrics() {
        let mostlyEnglish = [
            "\"Do you believe a world of happy endings?\"",
            "Even when the road seems long",
            "Every breath you take will lead you closer to",
            "君の夢が叶うまで",
        ].enumerated().map { LyricLine(id: $0.offset, timestamp: Double($0.offset) * 4, text: $0.element) }
        XCTAssertEqual(LyricsLanguageDetector.detectSpeechLocale(for: mostlyEnglish).identifier, "en-US")

        let mostlyJapanese = [
            "Hello, my friend",
            "見つけ出してくれた 救い出してくれた",
            "忘れることない 君の笑顔",
        ].enumerated().map { LyricLine(id: $0.offset, timestamp: Double($0.offset) * 4, text: $0.element) }
        XCTAssertEqual(LyricsLanguageDetector.detectSpeechLocale(for: mostlyJapanese).identifier, "ja-JP")
    }

    func testTokenizesAndAlignsJapaneseLyricsWithoutSpaces() {
        let text = "闇夜を駆け抜けて"
        let tokens = LyricsAudioAligner.tokenizeLine(text)
        XCTAssertGreaterThan(tokens.count, 1)
        XCTAssertEqual(tokens.map(\.display).joined(), text)

        let lines = [LyricLine(id: 0, timestamp: 5.0, text: text)]
        let recognized = tokens.enumerated().map { idx, tok in
            RecognizedAudioWord(
                text: tok.display,
                startTime: 5.2 + Double(idx) * 0.4,
                duration: 0.35,
                confidence: 0.9
            )
        }
        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized)
        XCTAssertEqual(result.matchedLineCount, 1)
        XCTAssertEqual(result.lines[0].words.map(\.text).joined(), text)
    }

    @MainActor
    func testSkipsLiveSyncWhenTrackAlreadyHasWordLevelTimestamps() throws {
        let suiteName = "bartune.test.wordsyncskip.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        state.audioSyncEngine = .lyricsAlignment
        state.replaceLyricsWithTranscription = false

        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let track = TrackInfo(
            id: "spotify:track:yrc-already-synced",
            title: "YRC Track",
            artist: "Artist",
            album: "Album",
            duration: 180,
            artworkURL: nil
        )
        let yrcLines = [
            LyricLine(
                id: 0,
                timestamp: 1.0,
                duration: 2.0,
                text: "Hello world",
                words: [
                    WordTimestamp(timestamp: 1.0, duration: 0.9, text: "Hello "),
                    WordTimestamp(timestamp: 1.9, duration: 1.1, text: "world"),
                ]
            ),
        ]

        state.setTrack(track, lyrics: yrcLines)
        let manager = AudioSyncManager(state: state, cache: cache)
        manager.handleTrackLoaded(track: track, rawLines: yrcLines)

        XCTAssertFalse(manager.isLiveSyncActive)
        XCTAssertEqual(state.audioSyncStatus, .cached(.lyricsAlignment))
    }

    func testTranscriptionOverwriteRejectsUnrelatedExternalSpeech() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, duration: 2.5, text: "We are the champions"),
        ]
        let unrelatedVoice = [
            RecognizedAudioWord(text: "checking", startTime: 10.1, duration: 0.4, confidence: 0.95),
            RecognizedAudioWord(text: "pipeline", startTime: 10.6, duration: 0.4, confidence: 0.95),
            RecognizedAudioWord(text: "status", startTime: 11.1, duration: 0.4, confidence: 0.95),
        ]

        let result = LyricsAudioAligner.align(
            lines: lines,
            recognizedWords: unrelatedVoice,
            replaceTextWithTranscription: true
        )

        XCTAssertEqual(result.matchedLineCount, 0)
        // Transcript-only mode must omit unmatched/unrelated lines instead of falling back to static text.
        XCTAssertTrue(result.lines.isEmpty)
    }

    func testTargetBundleIdentifiersMapToActiveMediaPlayer() {
        XCTAssertEqual(AudioSyncManager.targetBundleIdentifiers(for: "spotify:track:123"), ["com.spotify.client"])
        XCTAssertEqual(AudioSyncManager.targetBundleIdentifiers(for: "music:abc"), ["com.apple.Music"])
        XCTAssertEqual(
            AudioSyncManager.targetBundleIdentifiers(for: "browser:music.youtube.com:xyz", sourceBundleId: "com.google.Chrome"),
            ["com.google.Chrome"]
        )
        XCTAssertTrue(AudioSyncManager.targetBundleIdentifiers(for: "unknown:1").isEmpty)
    }

    func testSafariTrackTargetsOnlySafari() throws {
        let sep = "\u{1F}"
        let payload = [
            "BROWSER",
            "playing",
            "browser:music.youtube.com:Night Dancer|imase",
            "Night Dancer",
            "imase",
            "",
            "210.0",
            "15.0",
            "",
        ].joined(separator: sep)

        let monitor = BrowserMediaMonitor(
            listTabs: { browser in
                if browser.bundleId == "com.apple.Safari" {
                    return [BrowserTabDescriptor(windowIndex: 1, tabIndex: 1, url: "https://music.youtube.com/watch?v=abc")]
                }
                return []
            },
            probeTab: { browser, _ in
                browser.bundleId == "com.apple.Safari" ? payload : nil
            }
        )

        let snapshot = monitor.poll(runningBundleIds: ["com.google.Chrome", "com.apple.Safari"])
        let track = try XCTUnwrap(snapshot?.track)
        XCTAssertEqual(track.sourceBundleId, "com.apple.Safari")
        XCTAssertEqual(AudioSyncManager.targetBundleIdentifiers(for: track), ["com.apple.Safari"])
    }

    func testSingleMatchedLineDoesNotShiftGlobalOffset() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "First line here"),
            LyricLine(id: 1, timestamp: 30.0, text: "Future unsung line"),
        ]
        // Only a single line matches +6.0s away — must NOT shift the entire song.
        let recognized = [
            RecognizedAudioWord(text: "first", startTime: 16.0, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "line", startTime: 16.4, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "here", startTime: 16.8, duration: 0.3, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized)
        XCTAssertNil(result.medianOffset)
        XCTAssertEqual(result.lines[1].timestamp, 30.0, accuracy: 0.01)
    }

    func testCachedRecordReliabilityRejectsSingleLinePartialMatchAndOutlierOffsets() {
        let lines = [
            LyricLine(id: 0, timestamp: 1.0, text: "Line one"),
            LyricLine(id: 1, timestamp: 5.0, text: "Line two"),
            LyricLine(id: 2, timestamp: 9.0, text: "Line three"),
        ]

        let singleLinePartial = AudioSyncedLyricsRecord(
            trackId: "spotify:track:partial",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: 0.2,
            alignedLineCount: 1,
            lines: lines
        )
        XCTAssertFalse(singleLinePartial.isReliable)

        let outlierOffset = AudioSyncedLyricsRecord(
            trackId: "spotify:track:outlier",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: 9.85,
            alignedLineCount: 3,
            lines: lines
        )
        XCTAssertFalse(outlierOffset.isReliable)

        let singleLineTranscriptOnly = AudioSyncedLyricsRecord(
            trackId: "spotify:track:transcript-partial",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: 0.1,
            alignedLineCount: 1,
            sourceLineCount: lines.count,
            lines: [lines[0]]
        )
        XCTAssertFalse(singleLineTranscriptOnly.isReliable)

        let reliable = AudioSyncedLyricsRecord(
            trackId: "spotify:track:good",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: -0.45,
            alignedLineCount: 2,
            sourceLineCount: lines.count,
            lines: lines
        )
        XCTAssertTrue(reliable.isReliable)

        let duplicateTimestamp = AudioSyncedLyricsRecord(
            trackId: "spotify:track:dup",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: nil,
            alignedLineCount: 3,
            lines: [
                LyricLine(id: 0, timestamp: 13.49, text: "Yeah, yeah"),
                LyricLine(id: 1, timestamp: 13.49, text: "Yeah, yeah"),
            ]
        )
        XCTAssertFalse(duplicateTimestamp.isReliable)
    }

    func testAlignPreventsCrossLineWordBleedAndOverlappingTimestamps() {
        let lines = [
            LyricLine(id: 0, timestamp: 9.20, text: "We found each other"),
            LyricLine(id: 1, timestamp: 14.50, text: "I helped you out of a broken place"),
            LyricLine(id: 2, timestamp: 19.87, text: "You gave me comfort"),
        ]
        // Stray early hallucination at 3.67s + "you" sung during line 2 at 15.39s.
        let recognized = [
            RecognizedAudioWord(text: "we", startTime: 3.67, duration: 0.25, confidence: 0.8),
            RecognizedAudioWord(text: "found", startTime: 4.10, duration: 0.25, confidence: 0.8),
            RecognizedAudioWord(text: "i", startTime: 14.30, duration: 0.20, confidence: 0.9),
            RecognizedAudioWord(text: "helped", startTime: 14.70, duration: 0.30, confidence: 0.9),
            RecognizedAudioWord(text: "you", startTime: 15.39, duration: 0.25, confidence: 0.9),
            RecognizedAudioWord(text: "out", startTime: 15.80, duration: 0.25, confidence: 0.9),
            RecognizedAudioWord(text: "broken", startTime: 17.50, duration: 0.35, confidence: 0.9),
            RecognizedAudioWord(text: "place", startTime: 18.10, duration: 0.40, confidence: 0.9),
            RecognizedAudioWord(text: "you", startTime: 19.75, duration: 0.25, confidence: 0.9),
            RecognizedAudioWord(text: "gave", startTime: 20.15, duration: 0.30, confidence: 0.9),
            RecognizedAudioWord(text: "me", startTime: 20.55, duration: 0.20, confidence: 0.9),
            RecognizedAudioWord(text: "comfort", startTime: 21.00, duration: 0.50, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized)
        // Line 0 must NOT be pulled back to 3.67s.
        XCTAssertGreaterThan(result.lines[0].timestamp, 8.0)
        // Line 2 must NOT steal "you" from line 1 at 15.39s or overlap line 1.
        XCTAssertGreaterThan(result.lines[2].timestamp, 19.0)
        XCTAssertGreaterThan(result.lines[2].timestamp, result.lines[1].timestamp + 1.0)
    }

    func testHeldLastWordDoesNotHideTheNextLinesFirstWord() {
        // "you" is held up to the moment "now" is sung: its end touches the next line's first word.
        let lines = [
            LyricLine(id: 0, timestamp: 86.0, text: "love you"),
            LyricLine(id: 1, timestamp: 92.0, text: "now your out all night"),
        ]
        let recognized = [
            RecognizedAudioWord(text: "love", startTime: 86.17, duration: 0.40, confidence: 0.9),
            RecognizedAudioWord(text: "you", startTime: 86.57, duration: 5.37, confidence: 0.9),
            RecognizedAudioWord(text: "now", startTime: 91.94, duration: 0.14, confidence: 0.9),
            RecognizedAudioWord(text: "your", startTime: 92.12, duration: 0.16, confidence: 0.9),
            RecognizedAudioWord(text: "out", startTime: 92.32, duration: 0.12, confidence: 0.9),
            RecognizedAudioWord(text: "all", startTime: 92.60, duration: 0.08, confidence: 0.9),
            RecognizedAudioWord(text: "night", startTime: 92.70, duration: 0.44, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized, regroupsCJKWords: false)
        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(result.lines[1].timestamp, 91.94, accuracy: 0.001)
    }

    func testWordBeforeThePreviousLinesEndDoesNotHideALaterEligibleOne() {
        // "now" is heard at 11.9 s, inside the held "you", and again at 12.2 s; only the second may start line 1.
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "love you"),
            LyricLine(id: 1, timestamp: 12.0, text: "now"),
        ]
        let recognized = [
            RecognizedAudioWord(text: "love", startTime: 10.0, duration: 0.4, confidence: 0.9),
            RecognizedAudioWord(text: "you", startTime: 10.5, duration: 1.5, confidence: 0.9),
            RecognizedAudioWord(text: "now", startTime: 11.9, duration: 0.2, confidence: 0.9),
            RecognizedAudioWord(text: "now", startTime: 12.2, duration: 0.2, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized, regroupsCJKWords: false)
        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(result.lines[1].timestamp, 12.2, accuracy: 0.001)
    }

    func testAlignEnforcesMonotonicOrderAcrossFallbackLinesAndConsumedWordBoundaries() {
        // Line 0 matches at 11.2s, while unmatched line 1 has raw timestamp 11.0s.
        let fallbackLines = [
            LyricLine(id: 0, timestamp: 10.0, text: "alpha beta"),
            LyricLine(id: 1, timestamp: 11.0, text: "unmatched second line"),
        ]
        let fallbackRecognized = [
            RecognizedAudioWord(text: "alpha", startTime: 11.2, duration: 0.2, confidence: 0.9),
            RecognizedAudioWord(text: "beta", startTime: 11.5, duration: 0.2, confidence: 0.9),
        ]
        let fallbackResult = LyricsAudioAligner.align(lines: fallbackLines, recognizedWords: fallbackRecognized)
        XCTAssertGreaterThan(fallbackResult.lines[1].timestamp, fallbackResult.lines[0].timestamp)

        // Boundary word at 12.2s must not be consumed by both line 0 and line 1.
        let boundaryLines = [
            LyricLine(id: 0, timestamp: 10.0, text: "alpha beta"),
            LyricLine(id: 1, timestamp: 12.0, text: "beta gamma"),
        ]
        let boundaryRecognized = [
            RecognizedAudioWord(text: "alpha", startTime: 10.0, duration: 0.2, confidence: 0.9),
            RecognizedAudioWord(text: "beta", startTime: 12.2, duration: 0.2, confidence: 0.9),
            RecognizedAudioWord(text: "gamma", startTime: 12.6, duration: 0.2, confidence: 0.9),
        ]
        let boundaryResult = LyricsAudioAligner.align(lines: boundaryLines, recognizedWords: boundaryRecognized)
        XCTAssertGreaterThan(boundaryResult.lines[1].timestamp, boundaryResult.lines[0].timestamp)
        if let firstLastWord = boundaryResult.lines[0].words.last,
           let secondFirstWord = boundaryResult.lines[1].words.first {
            XCTAssertGreaterThanOrEqual(secondFirstWord.timestamp, firstLastWord.timestamp + (firstLastWord.duration ?? 0))
        }
    }

    func testAlignFallbackLineRespectsPreviousLineEnd() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, duration: 1.0, text: "alpha"),
            LyricLine(id: 1, timestamp: 11.0, duration: 1.0, text: "unmatched first"),
            LyricLine(id: 2, timestamp: 12.0, duration: 1.0, text: "unmatched second"),
        ]
        let recognized = [
            RecognizedAudioWord(text: "alpha", startTime: 11.2, duration: 0.2, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized)
        let firstEnd = result.lines[0].timestamp + (result.lines[0].duration ?? 0)
        let secondEnd = result.lines[1].timestamp + (result.lines[1].duration ?? 0)

        XCTAssertGreaterThanOrEqual(result.lines[1].timestamp, firstEnd)
        XCTAssertGreaterThanOrEqual(result.lines[2].timestamp, secondEnd)
    }

    func testCachedRecordReliabilityRejectsIncompleteTranscriptCache() {
        let twoMatchedLines = [
            LyricLine(id: 0, timestamp: 1.0, text: "First matched line"),
            LyricLine(id: 1, timestamp: 5.0, text: "Second matched line"),
        ]

        // Transcript-only mode omits unmatched lines; 2 matched lines of a 40-line song must NOT be reliable.
        let partialTranscript = AudioSyncedLyricsRecord(
            trackId: "spotify:track:partial-transcript-2-of-40",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: 0.1,
            alignedLineCount: 2,
            sourceLineCount: 40,
            lines: twoMatchedLines
        )
        XCTAssertFalse(partialTranscript.isReliable)

        // Complete transcript covering all source lines remains reliable.
        let completeTranscript = AudioSyncedLyricsRecord(
            trackId: "spotify:track:complete-transcript",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: 0.1,
            alignedLineCount: 2,
            sourceLineCount: 2,
            lines: twoMatchedLines
        )
        XCTAssertTrue(completeTranscript.isReliable)

        // Legacy cache (sourceLineCount == nil) with fewer lines than raw source must be rejected when validated.
        let legacyPartial = AudioSyncedLyricsRecord(
            trackId: "spotify:track:legacy-partial",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: 0.1,
            alignedLineCount: 2,
            sourceLineCount: nil,
            lines: twoMatchedLines
        )
        XCTAssertFalse(legacyPartial.isReliable(expectedSourceLineCount: 10))
        XCTAssertTrue(legacyPartial.isReliable(expectedSourceLineCount: 2))
    }

    @MainActor
    func testAlignClampsBlankFallbackLinesMonotonically() throws {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "alpha beta"),
            LyricLine(id: 1, timestamp: 11.0, text: ""),
            LyricLine(id: 2, timestamp: 11.05, text: "   "),
            LyricLine(id: 3, timestamp: 14.0, text: "gamma delta"),
        ]
        let recognized = [
            RecognizedAudioWord(text: "alpha", startTime: 11.2, duration: 0.2, confidence: 0.9),
            RecognizedAudioWord(text: "beta", startTime: 11.5, duration: 0.2, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized)
        XCTAssertEqual(result.lines.count, 4)

        let firstEnd = result.lines[0].timestamp + (result.lines[0].duration ?? 0)
        XCTAssertGreaterThanOrEqual(result.lines[1].timestamp, firstEnd)
        XCTAssertGreaterThan(result.lines[1].timestamp, result.lines[0].timestamp)
        XCTAssertGreaterThan(result.lines[2].timestamp, result.lines[1].timestamp)
        XCTAssertGreaterThan(result.lines[3].timestamp, result.lines[2].timestamp)

        // Binary search in LyricsState must select line 0 at 11.25s instead of the blank line.
        let suiteName = "bartune.test.blankmonotonic.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        let track = TrackInfo(
            id: "spotify:track:blank-monotonic",
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 180,
            artworkURL: nil
        )
        state.setTrack(track, lyrics: result.lines)
        state.updatePlayback(isPlaying: true, position: 11.25)
        XCTAssertEqual(state.currentLineId, 0)
        XCTAssertEqual(state.currentText, "alpha beta")
    }

    func testAlignWordInterpolationStaysMonotonicInTightAndOverlappingGaps() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "We are the champions"),
        ]

        // Tight gap: 0.04s between "we" end (10.20) and "champions" start (10.24) for 2 missing words.
        let tightRecognized = [
            RecognizedAudioWord(text: "we", startTime: 10.0, duration: 0.2, confidence: 0.9),
            RecognizedAudioWord(text: "champions", startTime: 10.24, duration: 0.5, confidence: 0.95),
        ]
        let tightResult = LyricsAudioAligner.align(lines: lines, recognizedWords: tightRecognized)
        let tightWords = tightResult.lines[0].words
        XCTAssertEqual(tightWords.count, 4)
        for idx in 0..<(tightWords.count - 1) {
            XCTAssertLessThanOrEqual(tightWords[idx].timestamp, tightWords[idx + 1].timestamp + 0.0001)
        }
        // Interpolated words must not extend past the following word's start.
        XCTAssertLessThanOrEqual(tightWords[1].timestamp + (tightWords[1].duration ?? 0), tightWords[2].timestamp + 0.0001)
        XCTAssertLessThanOrEqual(tightWords[2].timestamp + (tightWords[2].duration ?? 0), tightWords[3].timestamp + 0.0001)

        // Overlapping anchors: "we" ends at 10.35 while "champions" starts at 10.20.
        let overlappingRecognized = [
            RecognizedAudioWord(text: "we", startTime: 10.0, duration: 0.35, confidence: 0.9),
            RecognizedAudioWord(text: "champions", startTime: 10.20, duration: 0.5, confidence: 0.95),
        ]
        let overlapResult = LyricsAudioAligner.align(lines: lines, recognizedWords: overlappingRecognized)
        let overlapWords = overlapResult.lines[0].words
        XCTAssertEqual(overlapWords.count, 4)
        for idx in 0..<(overlapWords.count - 1) {
            XCTAssertLessThanOrEqual(overlapWords[idx].timestamp, overlapWords[idx + 1].timestamp + 0.0001)
        }
        XCTAssertLessThanOrEqual(overlapWords[2].timestamp + (overlapWords[2].duration ?? 0), overlapWords[3].timestamp + 0.0001)
        // The first anchor's recognized duration must be capped by the next word's start.
        XCTAssertLessThanOrEqual(overlapWords[0].timestamp + (overlapWords[0].duration ?? 0), overlapWords[1].timestamp + 0.0001)
    }

    func testCachedRecordReliabilityRejectsOutOfOrderBlankLines() {
        // Caches written before blank lines were clamped can hold a blank marker behind the previous lyric.
        let record = AudioSyncedLyricsRecord(
            trackId: "spotify:track:legacy-blank-order",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: 0.2,
            alignedLineCount: 2,
            sourceLineCount: 2,
            lines: [
                LyricLine(id: 0, timestamp: 10.0, text: "first lyric"),
                LyricLine(id: 1, timestamp: 9.0, text: ""),
                LyricLine(id: 2, timestamp: 14.0, text: "second lyric"),
            ]
        )
        XCTAssertFalse(record.isReliable)
    }

    func testAlignKeepsRecognizedStartAfterClampedBlankLine() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "alpha"),
            LyricLine(id: 1, timestamp: 10.1, text: ""),
            LyricLine(id: 2, timestamp: 10.45, text: "beta"),
        ]
        let recognized = [
            RecognizedAudioWord(text: "alpha", startTime: 10.0, duration: 0.4, confidence: 0.9),
            RecognizedAudioWord(text: "beta", startTime: 10.45, duration: 0.3, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized)
        XCTAssertEqual(result.lines.count, 3)
        XCTAssertEqual(result.matchedLineCount, 2)
        XCTAssertGreaterThan(result.lines[1].timestamp, result.lines[0].timestamp)
        XCTAssertGreaterThan(result.lines[2].timestamp, result.lines[1].timestamp)
        // The blank marker keeps order without imposing full lyric spacing on the next recognized line.
        XCTAssertEqual(result.lines[2].timestamp, 10.45, accuracy: 0.001)
    }

    @MainActor
    func testOfflineRecoveryUsesCachedAudioSyncedLyricsWhenRawLyricsEvicted() throws {
        let suiteName = "bartune.test.offlinerecovery.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        state.audioSyncEngine = .lyricsAlignment

        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let track = TrackInfo(
            id: "spotify:track:offline-synced-recovery",
            title: "Night Run",
            artist: "Artist",
            album: "Album",
            duration: 180,
            artworkURL: nil
        )
        let cachedLines = [
            LyricLine(
                id: 0,
                timestamp: 5.0,
                duration: 2.0,
                text: "闇夜を駆け抜けて",
                words: [
                    WordTimestamp(timestamp: 5.0, duration: 1.0, text: "闇夜を"),
                    WordTimestamp(timestamp: 6.0, duration: 1.0, text: "駆け抜けて"),
                ]
            ),
            LyricLine(
                id: 1,
                timestamp: 9.0,
                duration: 2.0,
                text: "どこへ向かう",
                words: [
                    WordTimestamp(timestamp: 9.0, duration: 1.0, text: "どこへ"),
                    WordTimestamp(timestamp: 10.0, duration: 1.0, text: "向かう"),
                ]
            ),
        ]
        cache.save(
            AudioSyncedLyricsRecord(
                trackId: track.id,
                engine: .lyricsAlignment,
                syncedAt: Date(),
                medianOffset: 0.2,
                alignedLineCount: 2,
                sourceLineCount: 2,
                lines: cachedLines
            )
        )

        // Simulate raw lyrics evicted from disk cache while offline.
        state.romanizeJapanese = true
        state.setTrack(track, lyrics: [])
        XCTAssertFalse(state.hasLyrics)

        let manager = AudioSyncManager(state: state, cache: cache)
        manager.handleTrackLoaded(track: track, rawLines: [])

        XCTAssertFalse(manager.isLiveSyncActive)
        XCTAssertEqual(state.audioSyncStatus, .cached(.lyricsAlignment))
        XCTAssertEqual(state.rawLyricLines, cachedLines)
        XCTAssertTrue(state.hasLyrics)
        state.updatePlayback(isPlaying: true, position: 5.5)
        XCTAssertEqual(state.currentLineId, 0)
        XCTAssertFalse(state.currentText.isEmpty)
        XCTAssertNotEqual(state.currentText, cachedLines[0].text)

        // When engine is .off, offline cache recovery must not run.
        state.audioSyncEngine = .off
        state.setTrack(track, lyrics: [])
        manager.handleTrackLoaded(track: track, rawLines: [])
        XCTAssertEqual(state.audioSyncStatus, .idle)
        XCTAssertFalse(state.hasLyrics)

        // Unreliable surviving cache (e.g. partial transcript) must be evicted rather than applied offline.
        state.audioSyncEngine = .lyricsAlignment
        cache.save(
            AudioSyncedLyricsRecord(
                trackId: track.id,
                engine: .lyricsAlignment,
                syncedAt: Date(),
                medianOffset: 0.2,
                alignedLineCount: 2,
                sourceLineCount: 20,
                lines: cachedLines
            )
        )
        state.setTrack(track, lyrics: [])
        manager.handleTrackLoaded(track: track, rawLines: [])
        XCTAssertEqual(state.audioSyncStatus, .idle)
        XCTAssertFalse(state.hasLyrics)
        XCTAssertNil(cache.load(trackId: track.id))
    }

    // MARK: - #113: Transcription overwrite requires ordered overlap and trims unrelated speech

    func testTranscriptionOverwriteRejectsSingleCommonWordWithUnrelatedSpeech() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, duration: 3.0, text: "We are the champions"),
        ]
        let mixedWindow = [
            RecognizedAudioWord(text: "checking", startTime: 9.8, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "the", startTime: 10.2, duration: 0.2, confidence: 0.9),
            RecognizedAudioWord(text: "server", startTime: 10.5, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "status", startTime: 10.9, duration: 0.3, confidence: 0.9),
        ]

        let tokens = LyricsAudioAligner.tokenizeLine(lines[0].text)
        XCTAssertFalse(LyricsAudioAligner.transcriptionMatchesLine(lineTokens: tokens, recognized: mixedWindow))

        let result = LyricsAudioAligner.align(
            lines: lines,
            recognizedWords: mixedWindow,
            replaceTextWithTranscription: true
        )
        XCTAssertEqual(result.matchedLineCount, 0)
        XCTAssertTrue(result.lines.isEmpty)
    }

    func testTranscriptionOverwriteRequiresOrderedOverlap() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, duration: 3.0, text: "We are the champions"),
        ]
        let reversedSpeech = [
            RecognizedAudioWord(text: "champions", startTime: 10.1, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "the", startTime: 10.5, duration: 0.2, confidence: 0.9),
            RecognizedAudioWord(text: "are", startTime: 10.8, duration: 0.2, confidence: 0.9),
            RecognizedAudioWord(text: "we", startTime: 11.1, duration: 0.2, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(
            lines: lines,
            recognizedWords: reversedSpeech,
            replaceTextWithTranscription: true
        )
        XCTAssertEqual(result.matchedLineCount, 0)
        XCTAssertTrue(result.lines.isEmpty)
    }

    func testTranscriptionOverwriteKeepsOnlyMatchedSpanAndStripsSurroundingSpeech() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, duration: 3.5, text: "We are gonna shine tonight"),
        ]
        let recognized = [
            RecognizedAudioWord(text: "unrelated", startTime: 9.6, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "talk", startTime: 9.95, duration: 0.25, confidence: 0.9),
            RecognizedAudioWord(text: "we", startTime: 10.3, duration: 0.2, confidence: 0.95),
            RecognizedAudioWord(text: "are", startTime: 10.6, duration: 0.2, confidence: 0.95),
            RecognizedAudioWord(text: "going", startTime: 10.9, duration: 0.25, confidence: 0.9),
            RecognizedAudioWord(text: "to", startTime: 11.2, duration: 0.15, confidence: 0.9),
            RecognizedAudioWord(text: "shine", startTime: 11.4, duration: 0.3, confidence: 0.95),
            RecognizedAudioWord(text: "tonight", startTime: 11.8, duration: 0.4, confidence: 0.95),
            RecognizedAudioWord(text: "outro", startTime: 12.3, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "chatter", startTime: 12.7, duration: 0.3, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(
            lines: lines,
            recognizedWords: recognized,
            replaceTextWithTranscription: true
        )
        XCTAssertEqual(result.matchedLineCount, 1)
        XCTAssertEqual(result.lines.count, 1)
        XCTAssertEqual(result.lines[0].text, "we are going to shine tonight")
        XCTAssertEqual(result.lines[0].timestamp, 10.3, accuracy: 0.01)
        XCTAssertFalse(result.lines[0].text.contains("unrelated"))
        XCTAssertFalse(result.lines[0].text.contains("outro"))
        XCTAssertFalse(result.lines[0].text.contains("chatter"))
    }

    func testTranscriptionOverwriteSingleWordLineKeepsOnlyMatchedWord() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, duration: 2.0, text: "Hello"),
        ]
        let recognized = [
            RecognizedAudioWord(text: "unrelated", startTime: 9.7, duration: 0.2, confidence: 0.9),
            RecognizedAudioWord(text: "hello", startTime: 10.1, duration: 0.3, confidence: 0.95),
            RecognizedAudioWord(text: "chatter", startTime: 10.6, duration: 0.3, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(
            lines: lines,
            recognizedWords: recognized,
            replaceTextWithTranscription: true
        )
        XCTAssertEqual(result.matchedLineCount, 1)
        XCTAssertEqual(result.lines[0].text, "hello")
        XCTAssertEqual(result.lines[0].timestamp, 10.1, accuracy: 0.01)
    }

    func testTranscriptionOverwriteTrimsSurroundingSpeechOnCJKVariation() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, duration: 3.0, text: "闇夜を駆け抜けて"),
        ]
        let recognized = [
            RecognizedAudioWord(text: "えっと", startTime: 9.7, duration: 0.2, confidence: 0.9),
            RecognizedAudioWord(text: "闇夜", startTime: 10.1, duration: 0.4, confidence: 0.95),
            RecognizedAudioWord(text: "を", startTime: 10.5, duration: 0.2, confidence: 0.95),
            RecognizedAudioWord(text: "駆け抜けた", startTime: 10.8, duration: 0.6, confidence: 0.92),
            RecognizedAudioWord(text: "あの", startTime: 11.6, duration: 0.2, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(
            lines: lines,
            recognizedWords: recognized,
            replaceTextWithTranscription: true
        )
        XCTAssertEqual(result.matchedLineCount, 1)
        XCTAssertEqual(result.lines[0].text, "闇夜 を 駆け抜けた")
        XCTAssertFalse(result.lines[0].text.contains("えっと"))
        XCTAssertFalse(result.lines[0].text.contains("あの"))
    }

    func testTranscriptionOverwriteUsesEligibleSpanWhenFullerSpanStartsTooLate() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, duration: 8.0, text: "We are the champions"),
        ]
        let recognized = [
            RecognizedAudioWord(text: "we", startTime: 10.1, duration: 0.15, confidence: 0.9),
            RecognizedAudioWord(text: "are", startTime: 10.3, duration: 0.15, confidence: 0.9),
            RecognizedAudioWord(text: "we", startTime: 14.2, duration: 0.15, confidence: 0.9),
            RecognizedAudioWord(text: "are", startTime: 14.4, duration: 0.15, confidence: 0.9),
            RecognizedAudioWord(text: "the", startTime: 14.6, duration: 0.15, confidence: 0.9),
            RecognizedAudioWord(text: "champions", startTime: 14.8, duration: 0.4, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(
            lines: lines,
            recognizedWords: recognized,
            replaceTextWithTranscription: true
        )
        XCTAssertEqual(result.matchedLineCount, 1)
        XCTAssertEqual(result.lines.first?.text, "we are")
        XCTAssertEqual(result.lines.first?.timestamp ?? -1, 10.1, accuracy: 0.01)
    }

    func testTranscriptionOverwriteRejectsCharacterOnlyMatchOnSpacedLyricsWithCJKWord() {
        let tokens = LyricsAudioAligner.tokenizeLine("I   am   daydreaming   夢")
        let recognized = [
            RecognizedAudioWord(text: "daydreaming", startTime: 10.1, duration: 0.5, confidence: 0.9),
        ]

        XCTAssertNil(LyricsAudioAligner.matchedTranscriptionSpan(lineTokens: tokens, recognized: recognized))
    }

    func testTranscriptionOverwriteRejectsCharacterOnlyMatchOnSpacedLyrics() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, duration: 3.0, text: "I am dreaming"),
        ]
        let recognized = [
            RecognizedAudioWord(text: "dreaming", startTime: 10.1, duration: 0.5, confidence: 0.9),
        ]

        let tokens = LyricsAudioAligner.tokenizeLine(lines[0].text)
        XCTAssertNil(LyricsAudioAligner.matchedTranscriptionSpan(lineTokens: tokens, recognized: recognized))

        let result = LyricsAudioAligner.align(
            lines: lines,
            recognizedWords: recognized,
            replaceTextWithTranscription: true
        )
        XCTAssertEqual(result.matchedLineCount, 0)
        XCTAssertTrue(result.lines.isEmpty)
    }

    func testLyricTokenWordsAreMatchedAsTheyAreWithoutJoiningAdjacentLines() {
        // Lyrics Alignment returns each lyric token at its own time; joined into one katakana run,
        // "モラリティ" and "ダーリン" would no longer match either line.
        let lines = [
            LyricLine(id: 0, timestamp: 24.0, text: "モラリティ"),
            LyricLine(id: 1, timestamp: 25.5, text: "ダーリンベイビーダーリン"),
        ]
        let words = [(24.59, "モラ"), (24.91, "リ"), (25.23, "ティ"), (26.25, "ダーリン"), (26.71, "ベイビー"), (27.13, "ダーリン")]
            .map { RecognizedAudioWord(text: $0.1, startTime: $0.0, duration: 0.3, confidence: 0.1) }

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: words, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(result.lines.last?.timestamp ?? 0, 26.25, accuracy: 0.01)
    }
}
