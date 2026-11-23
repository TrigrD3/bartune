@testable import BarTune
import XCTest

final class LyricsCacheTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTuneCacheTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    func testSavesAndLoadsLyricsWithWordTimestamps() {
        let cache = LyricsDiskCache(directory: tempDir, maxEntries: 10)
        let lines = [
            LyricLine(
                id: 0,
                timestamp: 12.5,
                duration: 3.2,
                text: "Hello world",
                words: [
                    WordTimestamp(timestamp: 12.5, duration: 1.4, text: "Hello "),
                    WordTimestamp(timestamp: 13.9, duration: 1.8, text: "world"),
                ]
            ),
        ]

        XCTAssertNil(cache.load(trackId: "spotify:track:abc"))
        cache.save(trackId: "spotify:track:abc", lines: lines)

        let loaded = cache.load(trackId: "spotify:track:abc")
        XCTAssertEqual(loaded, lines)
    }

    func testPrunesOldestEntriesWhenExceedingCap() {
        let cache = LyricsDiskCache(directory: tempDir, maxEntries: 2)
        let sample = [LyricLine(id: 0, timestamp: 1.0, text: "Line")]

        cache.save(trackId: "track-1", lines: sample)
        Thread.sleep(forTimeInterval: 0.02)
        cache.save(trackId: "track-2", lines: sample)
        Thread.sleep(forTimeInterval: 0.02)
        cache.save(trackId: "track-3", lines: sample)

        XCTAssertNil(cache.load(trackId: "track-1"))
        XCTAssertNotNil(cache.load(trackId: "track-2"))
        XCTAssertNotNil(cache.load(trackId: "track-3"))
    }

    func testUnlimitedCacheDoesNotPruneAndManualPruneTrimsToNewLimit() {
        let cache = LyricsDiskCache(directory: tempDir, maxEntries: 0)
        let sample = [LyricLine(id: 0, timestamp: 1.0, text: "Line")]

        cache.save(trackId: "track-1", lines: sample)
        Thread.sleep(forTimeInterval: 0.02)
        cache.save(trackId: "track-2", lines: sample)
        Thread.sleep(forTimeInterval: 0.02)
        cache.save(trackId: "track-3", lines: sample)

        XCTAssertEqual(cache.stats().count, 3)

        cache.prune(to: 1)
        XCTAssertEqual(cache.stats().count, 1)
        XCTAssertNil(cache.load(trackId: "track-1"))
        XCTAssertNil(cache.load(trackId: "track-2"))
        XCTAssertNotNil(cache.load(trackId: "track-3"))
    }

    @MainActor
    func testLowerCacheLimitWaitsForConfirmationBeforePersistingOrPruning() async throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(LyricsCacheLimit.unlimited.rawValue, forKey: LyricsDiskCache.limitDefaultsKey)
        let state = LyricsState(userDefaults: defaults)
        let cache = LyricsDiskCache(directory: tempDir, maxEntries: 0)
        let sample = [LyricLine(id: 0, timestamp: 1.0, text: "Line")]
        for index in 0..<102 {
            cache.save(trackId: "track-\(index)", lines: sample)
        }
        let allFiles = try Set(FileManager.default.contentsOfDirectory(atPath: tempDir.path))

        await state.requestCacheLimit(.songs100, cache: cache)
        XCTAssertEqual(state.pendingCacheLimit, CacheLimitChange(limit: .songs100, removalCount: 2))
        XCTAssertEqual(state.lyricsCacheLimit, .unlimited, "The limit must not change before confirmation")
        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: tempDir.path)), allFiles)

        state.cancelCacheLimitChange()
        XCTAssertNil(state.pendingCacheLimit)
        XCTAssertEqual(state.lyricsCacheLimit, .unlimited)
        XCTAssertEqual(LyricsDiskCache.configuredMaxEntries(from: defaults), 0)
        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: tempDir.path)), allFiles)

        await state.requestCacheLimit(.songs100, cache: cache)
        let change = try XCTUnwrap(state.pendingCacheLimit)
        await state.confirmCacheLimitChange(change, cache: cache)
        XCTAssertNil(state.pendingCacheLimit)
        XCTAssertEqual(state.lyricsCacheLimit, .songs100)
        XCTAssertEqual(LyricsDiskCache.configuredMaxEntries(from: defaults), 100)
        XCTAssertEqual(cache.stats().count, 100)

        // Raising the limit deletes nothing, so it applies without asking.
        await state.requestCacheLimit(.songs250, cache: cache)
        XCTAssertNil(state.pendingCacheLimit)
        XCTAssertEqual(state.lyricsCacheLimit, .songs250)
        XCTAssertEqual(cache.stats().count, 100)
    }

    @MainActor
    func testConfirmedCacheLimitAsksAgainWhenASongWasSavedMeanwhile() async throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(LyricsCacheLimit.unlimited.rawValue, forKey: LyricsDiskCache.limitDefaultsKey)
        let state = LyricsState(userDefaults: defaults)
        let cache = LyricsDiskCache(directory: tempDir, maxEntries: 0)
        let sample = [LyricLine(id: 0, timestamp: 1.0, text: "Line")]
        for index in 0..<102 {
            cache.save(trackId: "track-\(index)", lines: sample)
        }

        await state.requestCacheLimit(.songs100, cache: cache)
        let stale = try XCTUnwrap(state.pendingCacheLimit)
        cache.save(trackId: "track-saved-while-asking", lines: sample)

        await state.confirmCacheLimitChange(stale, cache: cache)
        XCTAssertEqual(state.pendingCacheLimit, CacheLimitChange(limit: .songs100, removalCount: 3))
        XCTAssertEqual(state.lyricsCacheLimit, .unlimited, "A stale count must not be confirmed")
        XCTAssertEqual(cache.stats().count, 103)

        let fresh = try XCTUnwrap(state.pendingCacheLimit)
        await state.confirmCacheLimitChange(fresh, cache: cache)
        XCTAssertNil(state.pendingCacheLimit)
        XCTAssertEqual(state.lyricsCacheLimit, .songs100)
        XCTAssertEqual(cache.stats().count, 100)
    }

    @MainActor
    func testLatestCacheLimitSelectionWinsOverAnEarlierScan() async throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(LyricsCacheLimit.unlimited.rawValue, forKey: LyricsDiskCache.limitDefaultsKey)
        let state = LyricsState(userDefaults: defaults)
        let cache = LyricsDiskCache(directory: tempDir, maxEntries: 0)
        let sample = [LyricLine(id: 0, timestamp: 1.0, text: "Line")]
        for index in 0..<102 {
            cache.save(trackId: "track-\(index)", lines: sample)
        }

        // Pick 100 songs, then switch back to Unlimited before that scan finishes.
        let earlier = Task { await state.requestCacheLimit(.songs100, cache: cache) }
        await Task.yield()
        await state.requestCacheLimit(.unlimited, cache: cache)
        await earlier.value

        XCTAssertNil(state.pendingCacheLimit, "An earlier selection must not ask after a later one")
        XCTAssertEqual(state.lyricsCacheLimit, .unlimited)
        XCTAssertEqual(cache.stats().count, 102)
    }

    @MainActor
    func testLaterCacheLimitSelectionWinsOverAPendingConfirmation() async throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(LyricsCacheLimit.unlimited.rawValue, forKey: LyricsDiskCache.limitDefaultsKey)
        let state = LyricsState(userDefaults: defaults)
        let cache = LyricsDiskCache(directory: tempDir, maxEntries: 0)
        let sample = [LyricLine(id: 0, timestamp: 1.0, text: "Line")]
        for index in 0..<102 {
            cache.save(trackId: "track-\(index)", lines: sample)
        }

        await state.requestCacheLimit(.songs100, cache: cache)
        let change = try XCTUnwrap(state.pendingCacheLimit)
        // Confirm, then pick Unlimited while the confirmation is still recounting.
        let confirmation = Task { await state.confirmCacheLimitChange(change, cache: cache) }
        while state.pendingCacheLimit != nil {
            await Task.yield()
        }
        await state.requestCacheLimit(.unlimited, cache: cache)
        await confirmation.value

        XCTAssertEqual(state.lyricsCacheLimit, .unlimited)
        XCTAssertEqual(LyricsDiskCache.configuredMaxEntries(from: defaults), 0)
        XCTAssertEqual(cache.stats().count, 102)
    }

    func testClearRemovesAllCachedLyrics() {
        let cache = LyricsDiskCache(directory: tempDir, maxEntries: 10)
        let sample = [LyricLine(id: 0, timestamp: 1.0, text: "Line")]
        cache.save(trackId: "track-a", lines: sample)
        cache.save(trackId: "track-b", lines: sample)

        let before = cache.stats()
        XCTAssertEqual(before.count, 2)
        XCTAssertGreaterThan(before.bytes, 0)

        cache.clear()

        let after = cache.stats()
        XCTAssertEqual(after.count, 0)
        XCTAssertEqual(after.bytes, 0)
        XCTAssertNil(cache.load(trackId: "track-a"))
        XCTAssertNil(cache.load(trackId: "track-b"))
    }

    @MainActor
    func testPerTrackTimingOffsetsPersistAcrossTrackSwitches() throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        let trackA = TrackInfo(id: "yt:a", title: "Song A", artist: "Artist A", album: "", duration: 200, artworkURL: nil)
        let trackB = TrackInfo(id: "yt:b", title: "Song B", artist: "Artist B", album: "", duration: 210, artworkURL: nil)

        state.setTrack(trackA, lyrics: [])
        state.offsetSeconds = 1.4

        state.setTrack(trackB, lyrics: [])
        XCTAssertEqual(state.offsetSeconds, 0.0, accuracy: 0.001)
        state.offsetSeconds = -0.8

        // Switch back to Track A -> restores +1.4s
        state.setTrack(trackA, lyrics: [])
        XCTAssertEqual(state.offsetSeconds, 1.4, accuracy: 0.001)

        // New LyricsState reading same UserDefaults restores Track B's -0.8s
        let reloaded = LyricsState(userDefaults: ud)
        reloaded.setTrack(trackB, lyrics: [])
        XCTAssertEqual(reloaded.offsetSeconds, -0.8, accuracy: 0.001)
    }

    func testListEntriesSupportsMetadataLegacyFilesAndAudioSyncStatus() throws {
        let baseDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bartune-list-tests-\(UUID().uuidString)", isDirectory: true)
        let lyricsDir = baseDir.appendingPathComponent("lyrics", isDirectory: true)
        let syncDir = baseDir.appendingPathComponent("sync", isDirectory: true)
        try FileManager.default.createDirectory(at: lyricsDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: baseDir) }

        let cache = LyricsDiskCache(directory: lyricsDir, maxEntries: 100)
        let syncCache = AudioSyncedLyricsCache(directory: syncDir)

        let lines = [LyricLine(id: 0, timestamp: 1.0, text: "First lyric")]
        cache.save(trackId: "spotify:track:modern", lines: lines, title: "Yoru ni Kakeru", artist: "YOASOBI")
        syncCache.save(
            AudioSyncedLyricsRecord(
                trackId: "spotify:track:modern",
                engine: .lyricsAlignment,
                syncedAt: Date(),
                medianOffset: 0.1,
                alignedLineCount: 1,
                lines: lines
            )
        )

        let legacyKey = LyricsDiskCache.cacheKey(for: "spotify:track:legacy")
        let legacyLines = [LyricLine(id: 0, timestamp: 2.0, text: "Legacy opening line")]
        let legacyData = try JSONEncoder().encode(legacyLines)
        try legacyData.write(to: lyricsDir.appendingPathComponent("\(legacyKey).json"))

        let entries = cache.listEntries(audioSyncCache: syncCache)
        XCTAssertEqual(entries.count, 2)

        let modern = try XCTUnwrap(entries.first { $0.trackId == "spotify:track:modern" })
        XCTAssertEqual(modern.title, "Yoru ni Kakeru")
        XCTAssertEqual(modern.artist, "YOASOBI")
        XCTAssertEqual(modern.syncEngine, .lyricsAlignment)

        let legacy = try XCTUnwrap(entries.first { $0.cacheKey == legacyKey })
        XCTAssertEqual(legacy.title, "Legacy opening line")
        XCTAssertEqual(legacy.artist, "")
        XCTAssertNil(legacy.syncEngine)

        cache.removeByCacheKey(legacyKey)
        XCTAssertEqual(cache.listEntries(audioSyncCache: syncCache).count, 1)

        let modernKey = LyricsDiskCache.cacheKey(for: "spotify:track:modern")
        XCTAssertTrue(FileManager.default.fileExists(atPath: cache.fileURL(forCacheKey: modernKey).path))
        XCTAssertEqual(cache.loadByCacheKey(modernKey)?.title, "Yoru ni Kakeru")
    }

    func testFailedLookupDoesNotMaskLaterDiskHit() async {
        let diskCache = LyricsDiskCache(directory: tempDir, maxEntries: 10)
        let expected = [LyricLine(id: 0, timestamp: 1, text: "Found")]

        // Case 1: HTTP 503 from all providers must not negative-cache in memory.
        let track503 = TrackInfo(
            id: "spotify:track:failed-503",
            title: "Offline Song",
            artist: "Artist",
            album: "Album",
            duration: 180,
            artworkURL: nil
        )
        let fetcher503 = LyricsFetcher(diskCache: diskCache) { request in
            let response = try XCTUnwrap(try HTTPURLResponse(
                url: XCTUnwrap(request.url),
                statusCode: 503,
                httpVersion: nil,
                headerFields: nil
            ))
            return (Data(), response)
        }

        let first503 = await fetcher503.fetchLyrics(for: track503)
        XCTAssertTrue(first503.isEmpty)

        diskCache.save(trackId: track503.id, lines: expected, title: track503.title, artist: track503.artist)
        let retried503 = await fetcher503.fetchLyrics(for: track503)
        XCTAssertEqual(retried503, expected)

        // Case 2: Cancelled lookup must not negative-cache in memory.
        let trackCancelled = TrackInfo(
            id: "spotify:track:cancelled",
            title: "Skipped Song",
            artist: "Artist",
            album: "Album",
            duration: 180,
            artworkURL: nil
        )
        let fetcherCancelled = LyricsFetcher(diskCache: diskCache) { _ in
            throw CancellationError()
        }

        let firstCancelled = await fetcherCancelled.fetchLyrics(for: trackCancelled)
        XCTAssertTrue(firstCancelled.isEmpty)

        diskCache.save(trackId: trackCancelled.id, lines: expected, title: trackCancelled.title, artist: trackCancelled.artist)
        let retriedCancelled = await fetcherCancelled.fetchLyrics(for: trackCancelled)
        XCTAssertEqual(retriedCancelled, expected)
    }

    @MainActor
    func testPlaybackRetriesLyricsAfterTransientFailureButNotAfterConfirmedMiss() async throws {
        final class Network: @unchecked Sendable {
            private let lock = NSLock()
            private var attempts = 0
            let firstAttemptError: URLError?

            init(firstAttemptError: URLError?) {
                self.firstAttemptError = firstAttemptError
            }

            var attemptCount: Int {
                lock.lock()
                defer { lock.unlock() }
                return attempts
            }

            func respond(to request: URLRequest) throws -> (Data, URLResponse) {
                let url = try XCTUnwrap(request.url)
                lock.lock()
                if url.host == "music.163.com", url.path == "/api/search/get" { attempts += 1 }
                let attempt = attempts
                lock.unlock()
                // The first lookup fails (offline or confirmed miss); every later one finds lyrics.
                if attempt == 1, let firstAttemptError { throw firstAttemptError }
                let found = attempt > 1 && url.path == "/api/get"
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: found ? 200 : 404, httpVersion: nil, headerFields: nil))
                let json = #"{"syncedLyrics":"[00:01.00]Back online"}"#
                return (found ? Data(json.utf8) : Data(), response)
            }
        }

        func play(_ network: Network, trackId: String) async throws -> [LyricLine] {
            let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
            defer { defaults.removePersistentDomain(forName: suiteName) }
            let state = LyricsState(userDefaults: defaults)
            let fetcher = LyricsFetcher(diskCache: LyricsDiskCache(directory: tempDir, maxEntries: 10)) {
                try network.respond(to: $0)
            }
            let app = AppDelegate(
                state: state,
                lyricsFetcher: fetcher,
                lyricsRetryDelays: [.zero],
                audioSyncCache: AudioSyncedLyricsCache(directory: tempDir.appendingPathComponent("audio-sync", isDirectory: true))
            )
            let track = TrackInfo(id: trackId, title: "Dawn", artist: "Iris", album: "", duration: 200, artworkURL: nil)
            app.handlePlaybackUpdate(PlaybackSnapshot(isRunning: true, isPlaying: true, track: track, position: 30))
            await app.fetchTask?.value
            return state.rawLyricLines
        }

        let offline = Network(firstAttemptError: URLError(.notConnectedToInternet))
        let recovered = try await play(offline, trackId: "spotify:track:offline-then-online")
        XCTAssertEqual(recovered.map(\.text), ["Back online"], "Lyrics must load once the network recovers mid-song")
        XCTAssertEqual(offline.attemptCount, 2)

        let missing = Network(firstAttemptError: nil)
        let confirmedMiss = try await play(missing, trackId: "spotify:track:no-lyrics")
        XCTAssertTrue(confirmedMiss.isEmpty, "A confirmed miss must not be retried")
        XCTAssertEqual(missing.attemptCount, 1)
    }

    @MainActor
    func testTransientLyricsFailureStillShowsCachedAudioSyncRecord() async throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        let syncCache = AudioSyncedLyricsCache(directory: tempDir.appendingPathComponent("sync", isDirectory: true))
        let track = TrackInfo(id: "spotify:track:cached-sync-offline", title: "Dusk", artist: "Iris", album: "", duration: 200, artworkURL: nil)
        let cachedLines = [LyricLine(id: 0, timestamp: 1, text: "Cached line")]
        syncCache.save(
            AudioSyncedLyricsRecord(
                trackId: track.id,
                engine: .lyricsAlignment,
                syncedAt: Date(),
                medianOffset: 0,
                alignedLineCount: 1,
                sourceLineCount: 1,
                lines: cachedLines
            )
        )
        let fetcher = LyricsFetcher(
            diskCache: LyricsDiskCache(directory: tempDir.appendingPathComponent("lyrics", isDirectory: true), maxEntries: 10)
        ) { _ in throw URLError(.notConnectedToInternet) }
        let app = AppDelegate(state: state, lyricsFetcher: fetcher, lyricsRetryDelays: [.seconds(3600)], audioSyncCache: syncCache)

        app.handlePlaybackUpdate(PlaybackSnapshot(isRunning: true, isPlaying: true, track: track, position: 2))
        for _ in 0..<200 where state.rawLyricLines.isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        app.fetchTask?.cancel()
        await app.fetchTask?.value

        XCTAssertEqual(state.rawLyricLines.map(\.text), ["Cached line"], "A cached audio sync record must show while lookups fail")
        XCTAssertEqual(state.audioSyncStatus, .cached(.lyricsAlignment))
    }

    func testCancelledLookupStopsEarlyAndRetriesWhenOnline() async {
        final class StubState: @unchecked Sendable {
            private let lock = NSLock()
            var shouldCancel = true
            var requestedHosts: [String] = []

            func recordAndCheckCancel(host: String) -> Bool {
                lock.lock()
                defer { lock.unlock() }
                requestedHosts.append(host)
                return shouldCancel
            }

            func setOnline() {
                lock.lock()
                defer { lock.unlock() }
                shouldCancel = false
            }

            func hosts() -> [String] {
                lock.lock()
                defer { lock.unlock() }
                return requestedHosts
            }
        }

        let diskCache = LyricsDiskCache(directory: tempDir, maxEntries: 10)
        let stubState = StubState()
        let track = TrackInfo(
            id: "spotify:track:cancel-then-online",
            title: "Dawn",
            artist: "Iris",
            album: "Album",
            duration: 200,
            artworkURL: nil
        )

        let fetcher = LyricsFetcher(diskCache: diskCache) { request in
            let url = try XCTUnwrap(request.url)
            let host = url.host ?? ""
            if stubState.recordAndCheckCancel(host: host) {
                throw URLError(.cancelled)
            }
            if url.path == "/api/get" {
                let json = #"{"syncedLyrics":"[00:01.00]Online lyric","trackName":"Dawn","artistName":"Iris","duration":200}"#
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (Data(json.utf8), response)
            }
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        }

        let cancelledResult = await fetcher.fetchLyrics(for: track)
        XCTAssertTrue(cancelledResult.isEmpty)
        XCTAssertEqual(stubState.hosts(), ["music.163.com"], "Cancellation should stop before falling through to LRCLIB")

        stubState.setOnline()
        let onlineResult = await fetcher.fetchLyrics(for: track)
        XCTAssertEqual(onlineResult.map(\.text), ["Online lyric"])
    }

    func testSettingsDeletionInvalidatesWarmLyrics() async throws {
        let diskCache = LyricsDiskCache(directory: tempDir, maxEntries: 10)
        let syncCache = AudioSyncedLyricsCache(directory: tempDir.appendingPathComponent("sync", isDirectory: true))
        let offline: LyricsFetcher.DataLoader = { _ in throw URLError(.notConnectedToInternet) }
        let fetcher = LyricsFetcher(diskCache: diskCache, dataLoader: offline)
        let translator = LyricsTranslator(diskCache: diskCache, dataLoader: offline)
        let remover = OfflineCacheRemover(
            fetcher: fetcher,
            translator: translator,
            lyricsCache: diskCache,
            syncCache: syncCache
        )
        let track = TrackInfo(id: "spotify:track:wrong-match", title: "Song", artist: "Artist", album: "", duration: 180, artworkURL: nil)
        let controlTrack = TrackInfo(id: "spotify:track:control", title: "Control", artist: "Other", album: "", duration: 190, artworkURL: nil)
        let source = [LyricLine(id: 0, timestamp: 1, text: "source")]
        let controlSource = [LyricLine(id: 0, timestamp: 1, text: "control source")]
        let translationKey = LyricsTranslator.cacheKey(trackId: track.id, targetLanguage: .english, lines: source)
        let controlTranslationKey = LyricsTranslator.cacheKey(trackId: controlTrack.id, targetLanguage: .english, lines: controlSource)

        func seed(_ text: String) {
            diskCache.save(trackId: track.id, lines: [LyricLine(id: 0, timestamp: 1, text: text)], title: track.title, artist: track.artist)
            diskCache.save(trackId: translationKey, lines: [LyricLine(id: 0, timestamp: 1, text: "\(text) en")])
            syncCache.save(
                AudioSyncedLyricsRecord(
                    trackId: track.id,
                    engine: .lyricsAlignment,
                    syncedAt: Date(),
                    medianOffset: 0,
                    alignedLineCount: 1,
                    sourceLineCount: 1,
                    lines: [LyricLine(id: 0, timestamp: 1, text: text)]
                )
            )
        }

        diskCache.save(
            trackId: controlTrack.id,
            lines: controlSource,
            title: controlTrack.title,
            artist: controlTrack.artist
        )
        diskCache.save(
            trackId: controlTranslationKey,
            lines: [LyricLine(id: 0, timestamp: 1, text: "control en")]
        )
        syncCache.save(
            AudioSyncedLyricsRecord(
                trackId: controlTrack.id,
                engine: .lyricsAlignment,
                syncedAt: Date(),
                medianOffset: 0,
                alignedLineCount: 1,
                sourceLineCount: 1,
                lines: controlSource
            )
        )

        // Single-row deletion.
        seed("old")
        _ = await fetcher.fetchLyrics(for: track)
        _ = await translator.translate(lines: source, trackId: track.id, targetLanguage: .english)
        let song = try XCTUnwrap(diskCache.listEntries(audioSyncCache: syncCache).first { $0.trackId == track.id })
        await remover.remove(song)

        XCTAssertNil(diskCache.load(trackId: track.id))
        XCTAssertNil(diskCache.load(trackId: translationKey), "Manual removal must delete derived translation files on disk")
        XCTAssertNil(syncCache.load(trackId: track.id), "Manual removal must delete audio sync records on disk")
        let fallbackAfterRemove = await translator.translate(lines: source, trackId: track.id, targetLanguage: .english)
        XCTAssertEqual(fallbackAfterRemove, source)
        XCTAssertNotNil(diskCache.load(trackId: controlTrack.id))
        XCTAssertNotNil(diskCache.load(trackId: controlTranslationKey))
        XCTAssertNotNil(syncCache.load(trackId: controlTrack.id))

        // Single-row deletion of legacy song without trackId must keep control song's disk translation.
        let legacyTrackId = "spotify:track:legacy-single"
        let legacyKey = LyricsDiskCache.cacheKey(for: legacyTrackId)
        let legacyData = try JSONEncoder().encode([LyricLine(id: 0, timestamp: 1, text: "legacy")])
        try legacyData.write(to: diskCache.fileURL(forCacheKey: legacyKey))
        let legacySummary = try XCTUnwrap(diskCache.listEntries(audioSyncCache: syncCache).first { $0.cacheKey == legacyKey })
        await remover.remove(legacySummary)
        XCTAssertNil(diskCache.loadByCacheKey(legacyKey))
        XCTAssertNotNil(diskCache.load(trackId: controlTranslationKey), "Removing a legacy row must not wipe other songs' translations")

        seed("new")
        let afterRemove = await fetcher.fetchLyrics(for: track)
        let translatedAfterRemove = await translator.translate(lines: source, trackId: track.id, targetLanguage: .english)
        XCTAssertEqual(afterRemove.map(\.text), ["new"])
        XCTAssertEqual(translatedAfterRemove.map(\.text), ["new en"])

        // Clear All.
        await remover.removeAll()
        seed("newer")
        let afterClear = await fetcher.fetchLyrics(for: track)
        let translatedAfterClear = await translator.translate(lines: source, trackId: track.id, targetLanguage: .english)
        XCTAssertEqual(afterClear.map(\.text), ["newer"])
        XCTAssertEqual(translatedAfterClear.map(\.text), ["newer en"])
    }

    func testAutomaticEvictionDeletesDerivedTranslationAndPreservesControlSong() {
        let lyricsDir = tempDir.appendingPathComponent("lyrics", isDirectory: true)
        let syncDir = tempDir.appendingPathComponent("sync", isDirectory: true)
        let syncCache = AudioSyncedLyricsCache(directory: syncDir)
        let diskCache = LyricsDiskCache(directory: lyricsDir, maxEntries: 1, audioSyncCache: syncCache)

        let track1 = TrackInfo(id: "spotify:track:evict-1", title: "Old Song", artist: "Artist 1", album: "", duration: 180, artworkURL: nil)
        let track2 = TrackInfo(id: "spotify:track:keep-2", title: "New Song", artist: "Artist 2", album: "", duration: 200, artworkURL: nil)
        let lines1 = [LyricLine(id: 0, timestamp: 1.0, text: "Old line")]
        let lines2 = [LyricLine(id: 0, timestamp: 1.0, text: "New line")]
        let trKey1 = LyricsTranslator.cacheKey(trackId: track1.id, targetLanguage: .english, lines: lines1)
        let trKey2 = LyricsTranslator.cacheKey(trackId: track2.id, targetLanguage: .english, lines: lines2)

        diskCache.save(trackId: track1.id, lines: lines1, title: track1.title, artist: track1.artist)
        diskCache.save(trackId: trKey1, lines: [LyricLine(id: 0, timestamp: 1.0, text: "Old translated")])
        syncCache.save(
            AudioSyncedLyricsRecord(
                trackId: track1.id,
                engine: .lyricsAlignment,
                syncedAt: Date(),
                medianOffset: 0,
                alignedLineCount: 1,
                sourceLineCount: 1,
                lines: lines1
            )
        )
        Thread.sleep(forTimeInterval: 0.02)
        diskCache.save(trackId: track2.id, lines: lines2, title: track2.title, artist: track2.artist)
        diskCache.save(trackId: trKey2, lines: [LyricLine(id: 0, timestamp: 1.0, text: "New translated")])
        syncCache.save(
            AudioSyncedLyricsRecord(
                trackId: track2.id,
                engine: .lyricsAlignment,
                syncedAt: Date(),
                medianOffset: 0,
                alignedLineCount: 1,
                sourceLineCount: 1,
                lines: lines2
            )
        )

        XCTAssertNil(diskCache.load(trackId: track1.id), "Oldest song raw lyrics should be evicted")
        XCTAssertNil(diskCache.load(trackId: trKey1), "Evicted song translation must also be removed")
        XCTAssertNil(syncCache.load(trackId: track1.id), "Evicted song audio sync record must also be removed")
        XCTAssertNotNil(diskCache.load(trackId: track2.id), "Control song raw lyrics must remain")
        XCTAssertNotNil(diskCache.load(trackId: trKey2), "Control song translation must remain")
        XCTAssertNotNil(syncCache.load(trackId: track2.id), "Control song audio sync record must remain")
        XCTAssertEqual(diskCache.stats().count, 1)
        XCTAssertEqual(diskCache.listEntries(audioSyncCache: syncCache).map(\.trackId), [track2.id])
    }

    func testMemoryCachesEvictOldEntries() async {
        let diskCache = LyricsDiskCache(directory: tempDir, maxEntries: 0)
        let offline: LyricsFetcher.DataLoader = { _ in throw URLError(.notConnectedToInternet) }
        let fetcher = LyricsFetcher(diskCache: diskCache, memoryCapacity: 2, dataLoader: offline)
        let translator = LyricsTranslator(diskCache: diskCache, memoryCapacity: 2, dataLoader: offline)
        let source = [LyricLine(id: 0, timestamp: 1, text: "source")]

        func seed(_ id: String, _ text: String) {
            diskCache.save(trackId: id, lines: [LyricLine(id: 0, timestamp: 1, text: text)], title: id, artist: "Artist")
            diskCache.save(
                trackId: LyricsTranslator.cacheKey(trackId: id, targetLanguage: .english, lines: source),
                lines: [LyricLine(id: 0, timestamp: 1, text: "\(text) en")]
            )
        }
        func track(_ id: String) -> TrackInfo {
            TrackInfo(id: id, title: id, artist: "Artist", album: "", duration: 180, artworkURL: nil)
        }

        for id in ["a", "b", "c"] {
            seed(id, "old")
            _ = await fetcher.fetchLyrics(for: track(id))
            _ = await translator.translate(lines: source, trackId: id, targetLanguage: .english)
        }
        seed("a", "new")

        let raw = await fetcher.fetchLyrics(for: track("a"))
        let translated = await translator.translate(lines: source, trackId: "a", targetLanguage: .english)
        XCTAssertEqual(raw.map(\.text), ["new"])
        XCTAssertEqual(translated.map(\.text), ["new en"])
    }

    @MainActor
    func testOfflineCacheStatsLoadOffMainThread() async {
        final class ThreadFlag: @unchecked Sendable {
            var ranOnMain = true
        }
        let flag = ThreadFlag()
        let model = OfflineCacheStatsModel {
            flag.ranOnMain = Thread.isMainThread
            return OfflineCacheSnapshot(cachedSongCount: 7)
        }

        await model.refresh().value

        XCTAssertFalse(flag.ranOnMain)
        XCTAssertEqual(model.snapshot.cachedSongCount, 7)
    }

    @MainActor
    func testOfflineCacheStatsIgnoreSupersededRefresh() async {
        final class Loads: @unchecked Sendable {
            private let lock = NSLock()
            private var count = 0
            let gate = DispatchSemaphore(value: 0)

            func next() -> Int {
                lock.lock()
                defer { lock.unlock() }
                count += 1
                return count
            }
        }
        let loads = Loads()
        let firstStarted = expectation(description: "first load started")
        let model = OfflineCacheStatsModel {
            let call = loads.next()
            if call == 1 {
                firstStarted.fulfill()
                loads.gate.wait()
            }
            return OfflineCacheSnapshot(cachedSongCount: call)
        }

        let stale = model.refresh()
        await fulfillment(of: [firstStarted], timeout: 5)
        await model.refresh().value
        loads.gate.signal()
        await stale.value

        XCTAssertEqual(model.snapshot.cachedSongCount, 2)
    }
}
