@testable import BarTune
import XCTest

final class SpotifyMonitorTests: XCTestCase {
    private func run(_ source: String) throws -> String? {
        let script = try XCTUnwrap(NSAppleScript(source: source))
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        XCTAssertNil(error)
        return result.stringValue
    }

    func testDeniedPlayerDoesNotAbortLaterPlayers() throws {
        let source = SpotifyMonitor.nativePlayerScriptSource(playerBlocks: [
            #"error "Not authorized to send Apple events to Spotify." number -1743"#,
            #"return "MUSIC" & sep & "playing""#,
        ])
        XCTAssertEqual(try run(source), "MUSIC\u{1F}playing")
    }

    func testFirstPlayingPlayerKeepsPriority() throws {
        let source = SpotifyMonitor.nativePlayerScriptSource(playerBlocks: [
            #"return "SPOTIFY""#,
            #"return "MUSIC""#,
        ])
        XCTAssertEqual(try run(source), "SPOTIFY")
        XCTAssertEqual(try run(SpotifyMonitor.nativePlayerScriptSource(playerBlocks: [])), "IDLE")
    }

    func testBrowserSnapshotNeverTargetsNativeTransport() {
        let runningSets: [Set<String>] = [
            ["com.apple.Music"],
            ["com.spotify.client"],
            ["com.spotify.client", "com.apple.Music"],
        ]
        for command in [PlaybackCommand.playPause, .nextTrack, .previousTrack] {
            for running in runningSets {
                XCTAssertNil(SpotifyMonitor.transportScriptSource(
                    for: command,
                    activeTrackId: "browser:www.youtube.com:Example|A",
                    runningBundleIds: running
                ))
            }
        }
    }

    func testNativeTracksRouteToTheirOwnPlayer() {
        let both: Set<String> = ["com.spotify.client", "com.apple.Music"]
        XCTAssertEqual(
            SpotifyMonitor.transportScriptSource(for: .nextTrack, activeTrackId: "music:ABC", runningBundleIds: both),
            "tell application \"Music\" to next track"
        )
        XCTAssertEqual(
            SpotifyMonitor.transportScriptSource(for: .playPause, activeTrackId: "spotify:track:1", runningBundleIds: both),
            "tell application \"Spotify\" to playpause"
        )
    }

    func testAcceptedBrowserSnapshotFiltersStandardYouTubeIndependentlyOfYouTubeMusic() {
        let ytTrack = TrackInfo(
            id: "browser:www.youtube.com:Video Title|Channel|v:abc",
            title: "Video Title",
            artist: "Channel",
            album: "",
            duration: 300,
            artworkURL: nil,
            sourceBundleId: "com.google.Chrome"
        )
        let ytSnap = PlaybackSnapshot(isRunning: true, isPlaying: true, track: ytTrack, position: 12)

        let ytMusicTrack = TrackInfo(
            id: "browser:music.youtube.com:Night Dancer|imase|v:xyz",
            title: "Night Dancer",
            artist: "imase",
            album: "Bonsai",
            duration: 210,
            artworkURL: nil,
            sourceBundleId: "com.google.Chrome"
        )
        let ytMusicSnap = PlaybackSnapshot(isRunning: true, isPlaying: true, track: ytMusicTrack, position: 15)

        XCTAssertNil(
            SpotifyMonitor.acceptedBrowserSnapshot(ytSnap, browserMusicEnabled: true, includeYouTubeVideos: false)
        )
        XCTAssertNotNil(
            SpotifyMonitor.acceptedBrowserSnapshot(ytSnap, browserMusicEnabled: true, includeYouTubeVideos: true)
        )
        XCTAssertEqual(
            SpotifyMonitor.acceptedBrowserSnapshot(ytMusicSnap, browserMusicEnabled: true, includeYouTubeVideos: false)?.track?.id,
            ytMusicTrack.id
        )
        XCTAssertNil(
            SpotifyMonitor.acceptedBrowserSnapshot(ytMusicSnap, browserMusicEnabled: false, includeYouTubeVideos: true)
        )
    }

    // MARK: - #116: Browser Music opt-out invalidates pending browser polls and blocks lookups

    @MainActor
    func testDisablingBrowserMusicInvalidatesPendingPollClearsSnapshotAndSkipsLookup() async throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTuneMonitor116-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let state = LyricsState(userDefaults: ud)
        state.browserMusicEnabled = true

        let pollGate = DispatchSemaphore(value: 0)
        let pollEntered = expectation(description: "Browser poll started and suspended")
        let pollFinished = expectation(description: "Browser poll closure returned")
        let pollCountBox = MonitorLockedBox(0)
        let fetchCountBox = MonitorLockedBox(0)

        let browserTrack = TrackInfo(
            id: "browser:music.youtube.com:Night Dancer|imase|v:abc123",
            title: "Night Dancer",
            artist: "imase",
            album: "Bonsai",
            duration: 210,
            artworkURL: nil,
            sourceBundleId: "com.google.Chrome"
        )
        let browserSnap = PlaybackSnapshot(
            isRunning: true,
            isPlaying: true,
            track: browserTrack,
            position: 12.0
        )

        let monitorDeps = SpotifyMonitor.Dependencies(
            runningBundleIds: { ["com.google.Chrome"] },
            executeNativeScript: { "IDLE" },
            pollBrowser: { _, _ in
                let call = pollCountBox.withLock { value -> Int in
                    value += 1
                    return value
                }
                if call == 1 {
                    pollEntered.fulfill()
                    pollGate.wait()
                    pollFinished.fulfill()
                }
                return browserSnap
            },
            executeTransportScript: { _ in }
        )
        let monitor = SpotifyMonitor(dependencies: monitorDeps)

        let fetcher = LyricsFetcher(diskCache: LyricsDiskCache(directory: tempDir, maxEntries: 10)) { request in
            fetchCountBox.withLock { $0 += 1 }
            let url = try XCTUnwrap(request.url)
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        }

        let delegate = AppDelegate(
            state: state,
            spotifyMonitor: monitor,
            lyricsFetcher: fetcher,
            audioSyncManager: AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir))
        )
        delegate.startPlaybackMonitoring()
        defer { delegate.stopPlaybackMonitoring() }

        await fulfillment(of: [pollEntered], timeout: 2.0)

        // Seed an active browser track via handlePlaybackUpdate to verify opt-out clears active playback too,
        // and disable Browser Music while the background poll is still suspended.
        state.browserMusicEnabled = false
        monitor.setBrowserMusicEnabled(false)

        var publishedAfterOptOut: [PlaybackSnapshot] = []
        monitor.onUpdate = { snap in
            publishedAfterOptOut.append(snap)
            delegate.handlePlaybackUpdate(snap)
        }

        pollGate.signal()
        await fulfillment(of: [pollFinished], timeout: 2.0)

        let pollSettled = await monitorWaitUntil { !monitor.isPolling }
        XCTAssertTrue(pollSettled)
        await delegate.waitForPendingFetch()

        XCTAssertTrue(
            publishedAfterOptOut.allSatisfy { $0.track == nil && !$0.isPlaying },
            "Stale pending browser poll must never publish a browser track after Browser Music is turned off"
        )
        XCTAssertEqual(fetchCountBox.withLock { $0 }, 0, "Stale browser poll must not trigger lyrics lookups")
        XCTAssertFalse(state.isPlaying)
        XCTAssertEqual(state.trackSummary, "Not Playing")

        // Also verify AppDelegate drops any browser snapshot that arrives after Browser Music is already false.
        delegate.handlePlaybackUpdate(browserSnap)
        await delegate.waitForPendingFetch()
        XCTAssertEqual(fetchCountBox.withLock { $0 }, 0)
        XCTAssertFalse(state.isPlaying)
    }

    @MainActor
    func testDisablingBrowserMusicClearsActiveBrowserSnapshotAndBlocksInFlightLookupPublish() async throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTuneMonitor116Active-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let state = LyricsState(userDefaults: ud)
        state.browserMusicEnabled = true

        let browserTrack = TrackInfo(
            id: "browser:music.youtube.com:Night Dancer|imase|v:abc123",
            title: "Night Dancer",
            artist: "imase",
            album: "Bonsai",
            duration: 210,
            artworkURL: nil,
            sourceBundleId: "com.google.Chrome"
        )
        let activeSnap = PlaybackSnapshot(isRunning: true, isPlaying: true, track: browserTrack, position: 10.0)

        let pollCountBox = MonitorLockedBox(0)
        let secondPollGate = DispatchSemaphore(value: 0)
        let firstPollDone = expectation(description: "First poll emitted active browser track")
        let secondPollEntered = expectation(description: "Second poll suspended")

        let monitorDeps = SpotifyMonitor.Dependencies(
            runningBundleIds: { ["com.google.Chrome"] },
            executeNativeScript: { "IDLE" },
            pollBrowser: { _, _ in
                let call = pollCountBox.withLock { value -> Int in
                    value += 1
                    return value
                }
                if call == 2 {
                    secondPollEntered.fulfill()
                    secondPollGate.wait()
                }
                return activeSnap
            },
            executeTransportScript: { _ in }
        )
        let monitor = SpotifyMonitor(dependencies: monitorDeps)

        var emittedSnapshots: [PlaybackSnapshot] = []
        var fulfilledFirstPoll = false
        monitor.onUpdate = { snap in
            emittedSnapshots.append(snap)
            if !fulfilledFirstPoll, snap.track?.id == browserTrack.id {
                fulfilledFirstPoll = true
                firstPollDone.fulfill()
            }
        }

        monitor.poll()
        await fulfillment(of: [firstPollDone], timeout: 2.0)

        // Start a second poll and suspend it, then disable Browser Music.
        monitor.poll()
        await fulfillment(of: [secondPollEntered], timeout: 2.0)

        emittedSnapshots.removeAll()
        monitor.setBrowserMusicEnabled(false)

        XCTAssertEqual(emittedSnapshots.count, 1, "Disabling Browser Music must immediately clear the active browser snapshot")
        XCTAssertEqual(emittedSnapshots.first?.isRunning, false)
        XCTAssertNil(emittedSnapshots.first?.track)

        secondPollGate.signal()
        let pollSettled = await monitorWaitUntil { !monitor.isPolling }
        XCTAssertTrue(pollSettled)
        XCTAssertTrue(emittedSnapshots.allSatisfy { $0.track == nil && !$0.isPlaying })

        // Separately verify AppDelegate does not publish in-flight fetched lyrics if Browser Music was disabled mid-fetch.
        let fetchStarted = expectation(description: "Lyrics fetch started")
        let lrclibCompleted = expectation(description: "LRCLIB response returned")
        let fetchGate = MonitorAsyncGate()
        state.browserMusicEnabled = true
        let fetcher = LyricsFetcher(diskCache: LyricsDiskCache(directory: tempDir, maxEntries: 10)) { request in
            let url = try XCTUnwrap(request.url)
            if url.host == "music.163.com" {
                fetchStarted.fulfill()
                await fetchGate.wait()
            }
            if url.host == "lrclib.net", url.path == "/api/get" {
                let json = #"{"syncedLyrics":"[00:01.00]Browser line","trackName":"Night Dancer","artistName":"imase","duration":210}"#
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                lrclibCompleted.fulfill()
                return (Data(json.utf8), response)
            }
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        }
        let delegate = AppDelegate(
            state: state,
            spotifyMonitor: monitor,
            lyricsFetcher: fetcher,
            audioSyncManager: AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir))
        )
        defer { delegate.stopPlaybackMonitoring() }
        delegate.handlePlaybackUpdate(activeSnap)
        await fulfillment(of: [fetchStarted], timeout: 2.0)

        state.browserMusicEnabled = false
        await fetchGate.open()
        await fulfillment(of: [lrclibCompleted], timeout: 2.0)
        await delegate.waitForPendingFetch()

        XCTAssertTrue(state.rawLyricLines.isEmpty, "In-flight lyrics fetch must not publish after Browser Music is turned off")
        XCTAssertFalse(state.hasLyrics)
    }

    @MainActor
    func testStalePollReleasedAfterBrowserMusicIsReEnabledPublishesOnlyFreshTrack() async {
        let staleTrack = TrackInfo(
            id: "browser:music.youtube.com:Old Song|Old Artist|v:stale",
            title: "Old Song",
            artist: "Old Artist",
            album: "",
            duration: 200,
            artworkURL: nil,
            sourceBundleId: "com.google.Chrome"
        )
        let freshTrack = TrackInfo(
            id: "browser:music.youtube.com:Night Dancer|imase|v:fresh",
            title: "Night Dancer",
            artist: "imase",
            album: "Bonsai",
            duration: 210,
            artworkURL: nil,
            sourceBundleId: "com.google.Chrome"
        )

        let pollCountBox = MonitorLockedBox(0)
        let pollGate = DispatchSemaphore(value: 0)
        let stalePollEntered = expectation(description: "Stale browser poll suspended")
        let monitorDeps = SpotifyMonitor.Dependencies(
            runningBundleIds: { ["com.google.Chrome"] },
            executeNativeScript: { "IDLE" },
            pollBrowser: { _, _ in
                let call = pollCountBox.withLock { value -> Int in
                    value += 1
                    return value
                }
                if call == 1 {
                    stalePollEntered.fulfill()
                    pollGate.wait()
                    return PlaybackSnapshot(isRunning: true, isPlaying: true, track: staleTrack, position: 5.0)
                }
                return PlaybackSnapshot(isRunning: true, isPlaying: true, track: freshTrack, position: 1.0)
            },
            executeTransportScript: { _ in }
        )
        let monitor = SpotifyMonitor(dependencies: monitorDeps)
        var publishedTrackIds: [String] = []
        monitor.onUpdate = { snap in
            if let trackId = snap.track?.id {
                publishedTrackIds.append(trackId)
            }
        }

        monitor.start(browserMusicEnabled: true)
        defer { monitor.stop() }
        await fulfillment(of: [stalePollEntered], timeout: 2.0)

        // Toggle Browser Music off and back on while the old poll is still suspended.
        monitor.setBrowserMusicEnabled(false)
        monitor.setBrowserMusicEnabled(true)
        pollGate.signal()

        let freshPublished = await monitorWaitUntil { publishedTrackIds.contains(freshTrack.id) }
        XCTAssertTrue(freshPublished)
        XCTAssertFalse(
            publishedTrackIds.contains(staleTrack.id),
            "A poll started before Browser Music was turned off must not publish after it is turned back on"
        )
    }

    @MainActor
    private func monitorWaitUntil(timeout: TimeInterval = 2.0, _ condition: () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                return false
            }
            await Task.yield()
        }
        return true
    }
}

private actor MonitorAsyncGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        for waiter in pending {
            waiter.resume()
        }
    }
}

private final class MonitorLockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
