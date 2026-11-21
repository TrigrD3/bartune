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
        let cacheKey = "\(trackId):tr:en"

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
        let cacheKey = "\(trackId):tr:en"

        let first = await translator.translate(lines: source, trackId: trackId, targetLanguage: .english)
        XCTAssertEqual(first.last, source.last, "Failed trailing batch must preserve original word-timed line")
        XCTAssertNil(diskCache.load(trackId: cacheKey), "Partially failed translation must not be cached")

        let second = await translator.translate(lines: source, trackId: trackId, targetLanguage: .english)
        XCTAssertEqual(second.count, 26)
        XCTAssertEqual(second.last?.text, "EN:linea 25")
        XCTAssertEqual(diskCache.load(trackId: cacheKey)?.count, 26)
    }
}
