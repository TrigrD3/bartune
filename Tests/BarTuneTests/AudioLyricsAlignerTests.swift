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

    func testWhisperJSONParserMergesSubwordsAndSkipsSpecialTokens() throws {
        let json = """
        {
          "transcription": [
            {
              "offsets": { "from": 0, "to": 2500 },
              "text": " Hello world",
              "tokens": [
                { "text": "[_BEG_]", "offsets": { "from": 0, "to": 0 }, "p": 1.0 },
                { "text": " Hel", "offsets": { "from": 200, "to": 450 }, "p": 0.8 },
                { "text": "lo", "offsets": { "from": 450, "to": 700 }, "p": 0.9 },
                { "text": " world", "offsets": { "from": 800, "to": 1400 }, "p": 0.95 },
                { "text": "[BLANK_AUDIO]", "offsets": { "from": 1500, "to": 2000 }, "p": 0.5 }
              ]
            }
          ]
        }
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let words = WhisperJSONParser.parse(data: data, chunkStartTime: 10.0)
        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words[0].text, "Hello")
        XCTAssertEqual(words[0].startTime, 10.2, accuracy: 0.001)
        XCTAssertEqual(words[0].duration, 0.5, accuracy: 0.001)
        XCTAssertEqual(words[1].text, "world")
        XCTAssertEqual(words[1].startTime, 10.8, accuracy: 0.001)
        XCTAssertEqual(words[1].duration, 0.6, accuracy: 0.001)
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
            engine: .whisper,
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

    func testWhisperModelLocatorDiscoversAndDeduplicatesSharedModels() throws {
        let fakeHome = tempDir.appendingPathComponent("home", isDirectory: true)
        let sharedDir = fakeHome.appendingPathComponent(".cache/whisper", isDirectory: true)
        let hfDir = fakeHome.appendingPathComponent(".cache/huggingface/hub/models--ggerganov--whisper.cpp/snapshots/abc", isDirectory: true)
        try FileManager.default.createDirectory(at: sharedDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: hfDir, withIntermediateDirectories: true)

        let tinyModel = sharedDir.appendingPathComponent("ggml-tiny.bin")
        let baseModel = hfDir.appendingPathComponent("ggml-base.bin")
        let symlinkDuplicate = hfDir.appendingPathComponent("ggml-tiny.bin")
        try Data(repeating: 1, count: 64).write(to: tinyModel)
        try Data(repeating: 2, count: 128).write(to: baseModel)
        try FileManager.default.createSymbolicLink(at: symlinkDuplicate, withDestinationURL: tinyModel)

        let models = WhisperModelLocator.discoverModels(
            customPath: nil,
            environment: [:],
            homeDirectory: fakeHome
        )

        let names = Set(models.map(\.name))
        XCTAssertEqual(names, ["ggml-tiny.bin", "ggml-base.bin"])
        // Symlink duplicate pointing to ggml-tiny.bin must be deduplicated.
        XCTAssertEqual(models.count, 2)
    }

    func testWAVEncoderHeaderAndSize() {
        let samples: [Float] = [0.0, 0.5, -0.5, 1.0]
        let wav = WAVEncoder.encodeMono16BitPCM(samples: samples, sampleRate: 16000)
        XCTAssertEqual(wav.count, 44 + samples.count * 2)
        XCTAssertEqual(String(data: wav.prefix(4), encoding: .ascii), "RIFF")
        XCTAssertEqual(String(data: wav.subdata(in: 8..<12), encoding: .ascii), "WAVE")
    }

    @MainActor
    func testLyricsStatePersistsAudioSyncSettings() throws {
        let suiteName = "bartune.test.audiosync.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        XCTAssertEqual(state.audioSyncEngine, .off)
        XCTAssertEqual(state.whisperModelPath, "")

        state.audioSyncEngine = .whisper
        state.whisperModelPath = "/tmp/ggml-base.bin"

        let reloaded = LyricsState(userDefaults: ud)
        XCTAssertEqual(reloaded.audioSyncEngine, .whisper)
        XCTAssertEqual(reloaded.whisperModelPath, "/tmp/ggml-base.bin")
    }

    @MainActor
    func testCachedTrackSkipsLiveResyncAndAppliesCachedWordTimestamps() throws {
        let suiteName = "bartune.test.cachedskip.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        state.audioSyncEngine = .whisper

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
                engine: .whisper,
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
        XCTAssertEqual(state.audioSyncStatus, .cached(.whisper))
        XCTAssertEqual(state.rawLyricLines, cachedLines)
    }

    func testAlignReplacesTextWithTranscribedWordsWhenEnabled() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, duration: 2.5, text: "Original written words"),
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

        let cachedBadge = AudioSyncStatus.cached(.whisper).overlayBadge
        XCTAssertEqual(cachedBadge?.text, "Synced")
        XCTAssertEqual(cachedBadge?.isSynced, true)

        let listeningBadge = AudioSyncStatus.syncing(engine: .appleSpeech, alignedLines: 0, totalLines: 10).overlayBadge
        XCTAssertEqual(listeningBadge?.text, "Listening")
        XCTAssertEqual(listeningBadge?.isSynced, false)

        let syncingBadge = AudioSyncStatus.syncing(engine: .whisper, alignedLines: 3, totalLines: 10).overlayBadge
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
        state.audioSyncEngine = .appleSpeech
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
        XCTAssertEqual(state.audioSyncStatus, .cached(.appleSpeech))
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
        XCTAssertTrue(AudioSyncManager.targetBundleIdentifiers(for: "browser:yt:xyz").contains("com.google.Chrome"))
        XCTAssertTrue(AudioSyncManager.targetBundleIdentifiers(for: "unknown:1").isEmpty)
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

    func testWhisperModelPresetsProvideValidDownloadURLs() {
        XCTAssertEqual(WhisperModelPreset.allCases.count, 4)
        for preset in WhisperModelPreset.allCases {
            XCTAssertTrue(preset.downloadURL.absoluteString.hasSuffix(preset.rawValue))
        }
    }

    func testCachedRecordReliabilityRejectsSingleLinePartialMatchAndOutlierOffsets() {
        let lines = [
            LyricLine(id: 0, timestamp: 1.0, text: "Line one"),
            LyricLine(id: 1, timestamp: 5.0, text: "Line two"),
            LyricLine(id: 2, timestamp: 9.0, text: "Line three"),
        ]

        let singleLinePartial = AudioSyncedLyricsRecord(
            trackId: "spotify:track:partial",
            engine: .appleSpeech,
            syncedAt: Date(),
            medianOffset: 0.2,
            alignedLineCount: 1,
            lines: lines
        )
        XCTAssertFalse(singleLinePartial.isReliable)

        let outlierOffset = AudioSyncedLyricsRecord(
            trackId: "spotify:track:outlier",
            engine: .appleSpeech,
            syncedAt: Date(),
            medianOffset: 9.85,
            alignedLineCount: 3,
            lines: lines
        )
        XCTAssertFalse(outlierOffset.isReliable)

        let singleLineTranscriptOnly = AudioSyncedLyricsRecord(
            trackId: "spotify:track:transcript-partial",
            engine: .whisper,
            syncedAt: Date(),
            medianOffset: 0.1,
            alignedLineCount: 1,
            sourceLineCount: lines.count,
            lines: [lines[0]]
        )
        XCTAssertFalse(singleLineTranscriptOnly.isReliable)

        let reliable = AudioSyncedLyricsRecord(
            trackId: "spotify:track:good",
            engine: .whisper,
            syncedAt: Date(),
            medianOffset: -0.45,
            alignedLineCount: 2,
            sourceLineCount: lines.count,
            lines: lines
        )
        XCTAssertTrue(reliable.isReliable)
    }
}
