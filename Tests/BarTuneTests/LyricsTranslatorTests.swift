@testable import BarTune
import XCTest

final class LyricsTranslatorTests: XCTestCase {
    func testParsesGoogleTranslateSinglePayload() throws {
        let json = """
        [[["Hello world\\n","こんにちは世界\\n",null,null,10],["Good night","おやすみ",null,null,10]],null,"ja"]
        """
        let data = try XCTUnwrap(json.data(using: .utf8))
        let parsed = LyricsTranslationParser.parseTranslatedText(from: data)
        XCTAssertEqual(parsed, "Hello world\nGood night")
    }

    func testAppliesTranslatedLinesPreservingTimestamps() {
        let original = [
            LyricLine(
                id: 0,
                timestamp: 10.0,
                duration: 3.5,
                text: "こんにちは世界",
                words: [WordTimestamp(timestamp: 10.0, duration: 1.5, text: "こんにちは")]
            ),
            LyricLine(id: 1, timestamp: 14.0, duration: 2.0, text: "♪"),
        ]
        let applied = LyricsTranslationParser.applyTranslatedLines(["Hello world", ""], to: original)
        XCTAssertEqual(applied.count, 2)
        XCTAssertEqual(applied[0].text, "Hello world")
        XCTAssertEqual(applied[0].timestamp, 10.0, accuracy: 0.001)
        XCTAssertEqual(applied[0].duration, 3.5)
        XCTAssertTrue(applied[0].words.isEmpty)
        XCTAssertEqual(applied[1].text, "♪")
    }

    @MainActor
    func testTranslateLyricsToggleSwitchesDisplayedLine() throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        state.romanizeJapanese = false
        let track = TrackInfo(id: "tr:1", title: "Song", artist: "Artist", album: "", duration: 120, artworkURL: nil)
        let original = [LyricLine(id: 0, timestamp: 1.0, duration: 4.0, text: "おはよう")]
        let translated = [LyricLine(id: 0, timestamp: 1.0, duration: 4.0, text: "Good morning")]

        state.setTrack(track, lyrics: original)
        state.updatePlayback(isPlaying: true, position: 2.0)
        XCTAssertEqual(state.currentText, "おはよう")

        state.setTranslatedLines(translated)
        XCTAssertEqual(state.currentText, "おはよう") // Toggle is off by default

        state.translateLyrics = true
        XCTAssertEqual(state.currentText, "Good morning")

        state.translateLyrics = false
        XCTAssertEqual(state.currentText, "おはよう")
    }

    func testFailedWordTimedBatchPreservesSourceAndRetries() async {
        final class StubState: @unchecked Sendable {
            private let lock = NSLock()
            var callCount = 0

            func nextCall() -> Int {
                lock.lock()
                defer { lock.unlock() }
                callCount += 1
                return callCount
            }
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTuneTranslatorTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let diskCache = LyricsDiskCache(directory: tempDir, maxEntries: 10)
        let stubState = StubState()
        let translator = LyricsTranslator(diskCache: diskCache) { request in
            let url = try XCTUnwrap(request.url)
            if stubState.nextCall() == 1 {
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil))
                return (Data(), response)
            }
            let json = #"[[["hello","hola",null,null,10]],null,"es"]"#
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(json.utf8), response)
        }

        let source = [
            LyricLine(
                id: 0,
                timestamp: 1.0,
                duration: 2.0,
                text: "hola",
                words: [WordTimestamp(timestamp: 1.0, duration: 2.0, text: "hola")]
            ),
        ]
        let trackId = "spotify:track:hola"
        let cacheKey = LyricsTranslator.cacheKey(trackId: trackId, targetLanguage: .english, lines: source)

        let first = await translator.translate(lines: source, trackId: trackId, targetLanguage: .english)
        XCTAssertEqual(first, source, "Failed batch must preserve original word-timed lines verbatim")
        XCTAssertNil(diskCache.load(trackId: cacheKey), "Failed translation must not be written to disk cache")

        let second = await translator.translate(lines: source, trackId: trackId, targetLanguage: .english)
        XCTAssertEqual(second.map(\.text), ["hello"])
        XCTAssertEqual(diskCache.load(trackId: cacheKey)?.map(\.text), ["hello"])
    }

    func testPartialBatchFailureDoesNotCacheHalfTranslatedResult() async {
        final class StubState: @unchecked Sendable {
            private let lock = NSLock()
            var callCount = 0

            func nextCall() -> Int {
                lock.lock()
                defer { lock.unlock() }
                callCount += 1
                return callCount
            }
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTuneTranslatorPartialTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let diskCache = LyricsDiskCache(directory: tempDir, maxEntries: 10)
        let stubState = StubState()

        let translator = LyricsTranslator(diskCache: diskCache) { request in
            let url = try XCTUnwrap(request.url)
            let call = stubState.nextCall()
            // First attempt: batch 1 (25 lines) succeeds, batch 2 (1 line) fails with 503.
            // Second attempt: batch 3 (25 lines) and batch 4 (1 line) both succeed.
            if call == 2 {
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil))
                return (Data(), response)
            }
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let query = components?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
            let inputLines = query.components(separatedBy: "\n")
            let translated = inputLines.map { "EN:\($0)" }.joined(separator: "\n")
            let escaped = translated.replacingOccurrences(of: "\n", with: "\\n")
            let json = #"[[["\#(escaped)","src",null,null,10]],null,"es"]"#
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(json.utf8), response)
        }

        let source = (0..<26).map { index in
            LyricLine(
                id: index,
                timestamp: Double(index),
                duration: 1.0,
                text: "linea \(index)",
                words: [WordTimestamp(timestamp: Double(index), duration: 1.0, text: "linea \(index)")]
            )
        }
        let trackId = "spotify:track:partial"
        let cacheKey = LyricsTranslator.cacheKey(trackId: trackId, targetLanguage: .english, lines: source)

        let first = await translator.translate(lines: source, trackId: trackId, targetLanguage: .english)
        XCTAssertEqual(first.last, source.last, "Failed trailing batch must preserve original word-timed line")
        XCTAssertNil(diskCache.load(trackId: cacheKey), "Partially failed translation must not be cached")

        let second = await translator.translate(lines: source, trackId: trackId, targetLanguage: .english)
        XCTAssertEqual(second.count, 26)
        XCTAssertEqual(second.last?.text, "EN:linea 25")
        XCTAssertEqual(diskCache.load(trackId: cacheKey)?.count, 26)
    }

    @MainActor
    func testFailedBatchLinesKeepWordTimingOnScreen() async throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTuneTranslatorWordTimingTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // The first batch (25 lines) translates; the second batch (1 line) fails.
        let translator = LyricsTranslator(diskCache: LyricsDiskCache(directory: tempDir, maxEntries: 10)) { request in
            let url = try XCTUnwrap(request.url)
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "q" }?.value ?? ""
            let inputLines = query.components(separatedBy: "\n")
            guard inputLines.count > 1 else {
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil))
                return (Data(), response)
            }
            let escaped = inputLines.map { "EN:\($0)" }.joined(separator: "\\n")
            let json = #"[[["\#(escaped)","src",null,null,10]],null,"es"]"#
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(json.utf8), response)
        }
        let source = (0..<26).map { index in
            LyricLine(
                id: index,
                timestamp: Double(index),
                duration: 1.0,
                text: "linea \(index)",
                words: [
                    WordTimestamp(timestamp: Double(index), duration: 0.5, text: "linea "),
                    WordTimestamp(timestamp: Double(index) + 0.5, duration: 0.5, text: "\(index)"),
                ]
            )
        }
        let track = TrackInfo(id: "spotify:track:word-timing", title: "Song", artist: "Artist", album: "", duration: 26, artworkURL: nil)
        let state = LyricsState(userDefaults: defaults)
        state.setTrack(track, lyrics: source)
        state.translateLyrics = true

        let translated = await translator.translate(lines: source, trackId: track.id, targetLanguage: .english)
        XCTAssertTrue(state.setTranslatedLines(translated, sourceLines: source))

        state.updatePlayback(isPlaying: true, position: 0.2)
        XCTAssertEqual(state.activeLine?.text, "EN:linea 0")
        state.updatePlayback(isPlaying: true, position: 25.2)
        XCTAssertEqual(state.activeLine?.text, "linea 25")
        XCTAssertEqual(state.activeLine?.words, source.last?.words, "A line shown untranslated must keep its word cues")
    }

    @MainActor
    func testFailedTranslationOfJapaneseSongShowsSourceLinesNotRomaji() async throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTuneTranslatorJapaneseFallbackTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Every batch fails, so the translator hands back the source lines unchanged.
        let translator = LyricsTranslator(diskCache: LyricsDiskCache(directory: tempDir, maxEntries: 10)) { request in
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 503, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        }
        let source = [
            LyricLine(
                id: 0,
                timestamp: 0,
                duration: 2,
                text: "こんにちは世界",
                words: [
                    WordTimestamp(timestamp: 0, duration: 1, text: "こんにちは"),
                    WordTimestamp(timestamp: 1, duration: 1, text: "世界"),
                ]
            ),
            LyricLine(id: 1, timestamp: 2, duration: 2, text: "ありがとう"),
        ]
        let track = TrackInfo(id: "spotify:track:japanese-fallback", title: "Song", artist: "Artist", album: "", duration: 4, artworkURL: nil)
        let state = LyricsState(userDefaults: defaults)
        state.romanizeJapanese = true
        state.setTrack(track, lyrics: source)
        state.translateLyrics = true

        let translated = await translator.translate(lines: source, trackId: track.id, targetLanguage: .english)
        XCTAssertEqual(translated, source)
        XCTAssertTrue(state.setTranslatedLines(translated, sourceLines: source))

        state.updatePlayback(isPlaying: true, position: 0.5)
        XCTAssertEqual(state.activeLine?.text, "こんにちは世界", "A failed translation must fall back to the source lines")
        XCTAssertEqual(state.activeLine?.words, source[0].words)

        // Audio sync shifts the source timing; the fallback must survive it.
        state.applyAudioSyncedLines(source.map {
            LyricLine(id: $0.id, timestamp: $0.timestamp + 0.5, duration: $0.duration, text: $0.text, words: $0.words)
        })
        state.updatePlayback(isPlaying: true, position: 2.7)
        XCTAssertEqual(state.activeLine?.text, "ありがとう")
    }

    func testCacheReusesTranslationOnlyForMatchingSourceText() async {
        final class StubState: @unchecked Sendable {
            private let lock = NSLock()
            var callCount = 0

            func nextCall() {
                lock.lock()
                defer { lock.unlock() }
                callCount += 1
            }
        }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTuneTranslatorSourceKeyTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let stubState = StubState()
        let translator = LyricsTranslator(diskCache: LyricsDiskCache(directory: tempDir, maxEntries: 10)) { request in
            stubState.nextCall()
            let url = try XCTUnwrap(request.url)
            let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            let query = components?.queryItems?.first(where: { $0.name == "q" })?.value ?? ""
            let json = #"[[["EN:\#(query)","src",null,null,10]],null,"es"]"#
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
            return (Data(json.utf8), response)
        }

        let trackId = "spotify:track:source-key"
        let original = [LyricLine(id: 0, timestamp: 1.0, duration: 2.0, text: "hola")]
        let retimed = [LyricLine(id: 0, timestamp: 1.5, duration: 2.5, text: "hola")]
        let replaced = [LyricLine(id: 0, timestamp: 1.5, duration: 2.5, text: "adios")]

        let first = await translator.translate(lines: original, trackId: trackId, targetLanguage: .english)
        XCTAssertEqual(first.map(\.text), ["EN:hola"])

        let timingOnly = await translator.translate(lines: retimed, trackId: trackId, targetLanguage: .english)
        XCTAssertEqual(timingOnly.map(\.text), ["EN:hola"])
        XCTAssertEqual(stubState.callCount, 1, "Timing-only changes must reuse the cached translation")

        let changed = await translator.translate(lines: replaced, trackId: trackId, targetLanguage: .english)
        XCTAssertEqual(changed.map(\.text), ["EN:adios"], "Changed source text must not reuse another source's translation")
        XCTAssertEqual(stubState.callCount, 2)
    }

    @MainActor
    func testActiveTranslationUsesAlignedBoundaries() throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let track = TrackInfo(id: "tr:sync", title: "Song", artist: "Artist", album: "", duration: 120, artworkURL: nil)
        let original = [
            LyricLine(id: 0, timestamp: 1.0, duration: 3.0, text: "一"),
            LyricLine(id: 1, timestamp: 5.0, duration: 3.0, text: "二"),
        ]
        let translated = [
            LyricLine(id: 0, timestamp: 1.0, duration: 3.0, text: "One"),
            LyricLine(id: 1, timestamp: 5.0, duration: 3.0, text: "Two"),
        ]
        let aligned = [
            LyricLine(id: 0, timestamp: 1.0, duration: 4.5, text: "一"),
            LyricLine(id: 1, timestamp: 8.0, duration: 3.5, text: "二"),
        ]

        // Case 1: translation arrives before audio alignment
        let state = LyricsState(userDefaults: ud)
        state.romanizeJapanese = false
        state.romanizeChinese = false
        state.translateLyrics = true
        state.setTrack(track, lyrics: original)
        state.offsetSeconds = 0.0
        state.setTranslatedLines(translated)
        state.applyAudioSyncedLines(aligned)

        state.updatePlayback(isPlaying: true, position: 6.0)
        XCTAssertEqual(state.currentText, "One")
        XCTAssertEqual(state.activeLine?.timestamp, 1.0)
        XCTAssertEqual(state.activeLine?.duration, 4.5)

        state.updatePlayback(isPlaying: true, position: 8.0)
        XCTAssertEqual(state.currentText, "Two")
        XCTAssertEqual(state.activeLine?.timestamp, 8.0)
        XCTAssertEqual(state.activeLine?.duration, 3.5)

        // Case 2: translation arrives after audio alignment (e.g. cached or in-flight with old timestamps)
        let stateAfter = LyricsState(userDefaults: ud)
        stateAfter.romanizeJapanese = false
        stateAfter.romanizeChinese = false
        stateAfter.translateLyrics = true
        stateAfter.setTrack(track, lyrics: original)
        stateAfter.offsetSeconds = 0.0
        stateAfter.applyAudioSyncedLines(aligned)
        stateAfter.setTranslatedLines(translated)

        stateAfter.updatePlayback(isPlaying: true, position: 6.0)
        XCTAssertEqual(stateAfter.currentText, "One")
        XCTAssertEqual(stateAfter.activeLine?.timestamp, 1.0)
        XCTAssertEqual(stateAfter.activeLine?.duration, 4.5)

        stateAfter.updatePlayback(isPlaying: true, position: 8.0)
        XCTAssertEqual(stateAfter.currentText, "Two")
        XCTAssertEqual(stateAfter.activeLine?.timestamp, 8.0)
        XCTAssertEqual(stateAfter.activeLine?.duration, 3.5)
    }

    @MainActor
    func testAudioSyncTranscriptionReplacementDropsStaleTranslation() throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let track = TrackInfo(id: "tr:replace", title: "Song", artist: "Artist", album: "", duration: 120, artworkURL: nil)
        let original = [
            LyricLine(id: 0, timestamp: 1.0, duration: 3.0, text: "一"),
            LyricLine(id: 1, timestamp: 5.0, duration: 3.0, text: "二"),
        ]
        let translated = [
            LyricLine(id: 0, timestamp: 1.0, duration: 3.0, text: "One"),
            LyricLine(id: 1, timestamp: 5.0, duration: 3.0, text: "Two"),
        ]
        let replacedSecond = [
            LyricLine(id: 0, timestamp: 1.0, duration: 4.0, text: "一"),
            LyricLine(id: 1, timestamp: 8.0, duration: 3.0, text: "Transcribed line"),
        ]

        let state = LyricsState(userDefaults: ud)
        state.romanizeJapanese = false
        state.romanizeChinese = false
        state.translateLyrics = true
        state.setTrack(track, lyrics: original)
        state.setTranslatedLines(translated)
        state.applyAudioSyncedLines(replacedSecond)

        state.updatePlayback(isPlaying: true, position: 2.0)
        XCTAssertEqual(state.currentText, "One")

        state.updatePlayback(isPlaying: true, position: 8.5)
        XCTAssertEqual(state.currentText, "Transcribed line")

        // A later alignment restoring the original text must restore the genuine translation,
        // not display the earlier replacement fallback as if it were a translation.
        let restored = [
            LyricLine(id: 0, timestamp: 1.0, duration: 4.0, text: "一"),
            LyricLine(id: 1, timestamp: 8.0, duration: 3.0, text: "二"),
        ]
        state.applyAudioSyncedLines(restored)
        state.updatePlayback(isPlaying: true, position: 8.5)
        XCTAssertEqual(state.currentText, "Two")
    }

    @MainActor
    func testSetTranslatedLinesRejectsStaleSourceTextButAcceptsTimingOnlyChanges() throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let track = TrackInfo(id: "tr:stale", title: "Song", artist: "Artist", album: "", duration: 120, artworkURL: nil)
        let original = [
            LyricLine(id: 0, timestamp: 1.0, duration: 3.0, text: "一"),
            LyricLine(id: 1, timestamp: 5.0, duration: 3.0, text: "二"),
        ]
        let translated = [
            LyricLine(id: 0, timestamp: 1.0, duration: 3.0, text: "One"),
            LyricLine(id: 1, timestamp: 5.0, duration: 3.0, text: "Two"),
        ]

        // Timing-only change while translation was in flight must still apply the translation.
        let timingOnly = [
            LyricLine(id: 0, timestamp: 1.5, duration: 3.5, text: "一"),
            LyricLine(id: 1, timestamp: 6.0, duration: 3.5, text: "二"),
        ]
        let state = LyricsState(userDefaults: ud)
        state.romanizeJapanese = false
        state.romanizeChinese = false
        state.translateLyrics = true
        state.setTrack(track, lyrics: original)
        state.applyAudioSyncedLines(timingOnly)
        XCTAssertTrue(state.setTranslatedLines(translated, sourceLines: original))
        state.updatePlayback(isPlaying: true, position: 6.5)
        XCTAssertEqual(state.currentText, "Two")
        XCTAssertEqual(state.activeLine?.timestamp, 6.0)

        // Text replacement while translation was in flight must be rejected.
        let replaced = [
            LyricLine(id: 0, timestamp: 1.5, duration: 3.5, text: "一"),
            LyricLine(id: 1, timestamp: 6.0, duration: 3.5, text: "Transcribed line"),
        ]
        let stateStale = LyricsState(userDefaults: ud)
        stateStale.romanizeJapanese = false
        stateStale.romanizeChinese = false
        stateStale.translateLyrics = true
        stateStale.setTrack(track, lyrics: original)
        stateStale.applyAudioSyncedLines(replaced)
        XCTAssertFalse(stateStale.setTranslatedLines(translated, sourceLines: original))
        stateStale.updatePlayback(isPlaying: true, position: 6.5)
        XCTAssertEqual(stateStale.currentText, "Transcribed line")
    }
}
