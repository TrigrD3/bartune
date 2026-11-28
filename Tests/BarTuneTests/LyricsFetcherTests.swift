@testable import BarTune
import XCTest

final class LyricsFetcherTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTuneLyricsFetcherTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    private let sampleTrack = TrackInfo(
        id: "spotify:track:netease-yrc-test",
        title: "Dawn",
        artist: "Iris",
        album: "Daybreak",
        duration: 200.0,
        artworkURL: nil
    )

    func testNetEaseRequestsDisableCookiesAndUseLyricV1Endpoint() async throws {
        let recordedRequests = LockedRequests()
        let diskCache = LyricsDiskCache(directory: tempDir, maxEntries: 10)

        let fetcher = LyricsFetcher(diskCache: diskCache) { request in
            recordedRequests.append(request)
            let url = try XCTUnwrap(request.url)

            if url.host == "music.163.com", url.path == "/api/search/get" {
                let json = """
                {
                  "result": {
                    "songs": [
                      {
                        "id": 42,
                        "name": "Dawn",
                        "duration": 200000,
                        "artists": [{"name": "Iris"}]
                      }
                    ]
                  }
                }
                """
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (Data(json.utf8), response)
            }

            if url.host == "music.163.com", url.path == "/api/song/lyric/v1" {
                let json = #"""
                {
                  "code": 200,
                  "lrc": {
                    "version": 1,
                    "lyric": "{\"t\":0,\"c\":[{\"tx\":\"作词 : Iris\"}]}\n[00:01.00]Hello"
                  },
                  "yrc": {
                    "version": 1,
                    "lyric": "{\"t\":0,\"c\":[{\"tx\":\"作词 : Iris\"}]}\n[1000,2000](1000,1000,0)Hel(2000,1000,0)lo"
                  }
                }
                """#
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (Data(json.utf8), response)
            }

            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        }

        let lines = await fetcher.fetchLyrics(for: sampleTrack)

        XCTAssertEqual(lines.count, 1)
        let firstLine = try XCTUnwrap(lines.first)
        XCTAssertEqual(firstLine.text, "Hello")
        XCTAssertEqual(firstLine.words.map(\.text), ["Hel", "lo"])

        let requests = recordedRequests.all()
        let netEaseRequests = requests.filter { $0.url?.host == "music.163.com" }
        XCTAssertEqual(netEaseRequests.map { $0.url?.path }, ["/api/search/get", "/api/song/lyric/v1"])
        XCTAssertTrue(
            netEaseRequests.allSatisfy { !$0.httpShouldHandleCookies },
            "NetEase requests must disable cookies so NMTID is never persisted or sent"
        )
        let lyricRequest = try XCTUnwrap(netEaseRequests.last)
        XCTAssertEqual(lyricRequest.url?.query, "id=42&lv=1&yv=1")
    }

    func testPreFixDiskCacheEntryTriggersRefetchAndUpgradesToWordTimedYRC() async throws {
        let diskCache = LyricsDiskCache(directory: tempDir, maxEntries: 10)
        let plainLines = [LyricLine(id: 0, timestamp: 1.0, text: "Old plain")]
        diskCache.save(
            trackId: sampleTrack.id,
            lines: plainLines,
            title: sampleTrack.title,
            artist: sampleTrack.artist,
            cacheVersion: nil
        )
        XCTAssertNil(diskCache.loadEntry(trackId: sampleTrack.id)?.cacheVersion)

        let recordedRequests = LockedRequests()
        let fetcher = LyricsFetcher(diskCache: diskCache) { request in
            recordedRequests.append(request)
            let url = try XCTUnwrap(request.url)

            if url.host == "music.163.com", url.path == "/api/search/get" {
                let json = """
                {"result":{"songs":[{"id":42,"name":"Dawn","duration":200000,"artists":[{"name":"Iris"}]}]}}
                """
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (Data(json.utf8), response)
            }
            if url.host == "music.163.com", url.path == "/api/song/lyric/v1" {
                let json = """
                {"yrc":{"lyric":"[1000,2000](1000,1000,0)Up(2000,1000,0)graded"}}
                """
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (Data(json.utf8), response)
            }
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        }

        let upgraded = await fetcher.fetchLyrics(for: sampleTrack)
        XCTAssertEqual(upgraded.map(\.text), ["Upgraded"])
        XCTAssertEqual(upgraded.first?.words.map(\.text), ["Up", "graded"])
        XCTAssertFalse(recordedRequests.all().isEmpty)

        let savedEntry = try XCTUnwrap(diskCache.loadEntry(trackId: sampleTrack.id))
        XCTAssertEqual(savedEntry.cacheVersion, CachedLyricsEntry.currentCacheVersion)
        XCTAssertEqual(savedEntry.lines.first?.words.map(\.text), ["Up", "graded"])
    }

    func testPostFixDiskCacheEntryWithEmptyWordsShortCircuitsWithoutRefetch() async {
        let diskCache = LyricsDiskCache(directory: tempDir, maxEntries: 10)
        let plainLines = [LyricLine(id: 0, timestamp: 1.0, text: "Plain cached")]
        diskCache.save(
            trackId: sampleTrack.id,
            lines: plainLines,
            title: sampleTrack.title,
            artist: sampleTrack.artist,
            cacheVersion: CachedLyricsEntry.currentCacheVersion
        )

        let recordedRequests = LockedRequests()
        let fetcher = LyricsFetcher(diskCache: diskCache) { request in
            recordedRequests.append(request)
            throw URLError(.notConnectedToInternet)
        }

        let loaded = await fetcher.fetchLyrics(for: sampleTrack)
        XCTAssertEqual(loaded, plainLines)
        XCTAssertTrue(recordedRequests.all().isEmpty, "Post-fix cached entries without YRC words must not re-fetch")
    }

    func testPreFixDiskCacheUpgradeTransientFailureReturnsFallbackWithoutBumpingCacheVersion() async throws {
        let diskCache = LyricsDiskCache(directory: tempDir, maxEntries: 10)
        let plainLines = [LyricLine(id: 0, timestamp: 1.0, text: "Fallback line")]
        diskCache.save(
            trackId: sampleTrack.id,
            lines: plainLines,
            title: sampleTrack.title,
            artist: sampleTrack.artist,
            cacheVersion: nil
        )

        let recordedRequests = LockedRequests()
        let failingFetcher = LyricsFetcher(diskCache: diskCache) { request in
            recordedRequests.append(request)
            throw URLError(.notConnectedToInternet)
        }

        let result = await failingFetcher.lookupLyrics(for: sampleTrack)
        XCTAssertEqual(result, plainLines)
        XCTAssertFalse(recordedRequests.all().isEmpty)

        let diskEntryAfterFailure = try XCTUnwrap(diskCache.loadEntry(trackId: sampleTrack.id))
        XCTAssertNil(
            diskEntryAfterFailure.cacheVersion,
            "Transient network failures must not bump cacheVersion on pre-fix disk entries"
        )
        XCTAssertEqual(diskEntryAfterFailure.lines, plainLines)

        // Once network recovers, a later play should still attempt and complete the YRC upgrade.
        let recoveringFetcher = LyricsFetcher(diskCache: diskCache) { request in
            let url = try XCTUnwrap(request.url)
            if url.host == "music.163.com", url.path == "/api/search/get" {
                let json = """
                {"result":{"songs":[{"id":42,"name":"Dawn","duration":200000,"artists":[{"name":"Iris"}]}]}}
                """
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (Data(json.utf8), response)
            }
            if url.host == "music.163.com", url.path == "/api/song/lyric/v1" {
                let json = """
                {"yrc":{"lyric":"[1000,2000](1000,1000,0)Recov(2000,1000,0)ered"}}
                """
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (Data(json.utf8), response)
            }
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        }

        let upgraded = await recoveringFetcher.fetchLyrics(for: sampleTrack)
        XCTAssertEqual(upgraded.map(\.text), ["Recovered"])
        XCTAssertEqual(upgraded.first?.words.map(\.text), ["Recov", "ered"])
        XCTAssertEqual(diskCache.loadEntry(trackId: sampleTrack.id)?.cacheVersion, CachedLyricsEntry.currentCacheVersion)
    }

    func testPreFixDiskCacheEntryWithoutYRCOnNetworkStampsCacheVersionOnce() async {
        let diskCache = LyricsDiskCache(directory: tempDir, maxEntries: 10)
        let plainLines = [LyricLine(id: 0, timestamp: 1.0, text: "Plain LRCLIB")]
        diskCache.save(
            trackId: sampleTrack.id,
            lines: plainLines,
            title: sampleTrack.title,
            artist: sampleTrack.artist,
            cacheVersion: nil
        )

        let firstRequests = LockedRequests()
        let firstFetcher = LyricsFetcher(diskCache: diskCache) { request in
            firstRequests.append(request)
            let url = try XCTUnwrap(request.url)
            if url.host == "lrclib.net", url.path == "/api/get" {
                let json = #"{"syncedLyrics":"[00:01.00]Plain LRCLIB","trackName":"Dawn","artistName":"Iris","duration":200}"#
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (Data(json.utf8), response)
            }
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        }

        let fetched = await firstFetcher.fetchLyrics(for: sampleTrack)
        XCTAssertEqual(fetched.map(\.text), ["Plain LRCLIB"])
        XCTAssertFalse(firstRequests.all().isEmpty)
        XCTAssertEqual(diskCache.loadEntry(trackId: sampleTrack.id)?.cacheVersion, CachedLyricsEntry.currentCacheVersion)

        let secondRequests = LockedRequests()
        let secondFetcher = LyricsFetcher(diskCache: diskCache) { request in
            secondRequests.append(request)
            throw URLError(.notConnectedToInternet)
        }
        let cachedAgain = await secondFetcher.fetchLyrics(for: sampleTrack)
        XCTAssertEqual(cachedAgain.map(\.text), ["Plain LRCLIB"])
        XCTAssertTrue(secondRequests.all().isEmpty)
    }
}

private final class LockedRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        defer { lock.unlock() }
        requests.append(request)
    }

    func all() -> [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
}
