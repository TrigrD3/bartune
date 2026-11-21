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
                engine: .appleSpeech,
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
        XCTAssertEqual(modern.syncEngine, .appleSpeech)

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
}
