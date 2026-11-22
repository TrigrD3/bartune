import Foundation
import AppKit

private final class CompiledScriptBox: @unchecked Sendable {
    private let source: String
    private var script: NSAppleScript?

    init(source: String) {
        self.source = source
    }

    func execute() -> String? {
        if script == nil {
            script = NSAppleScript(source: source)
        }
        var error: NSDictionary?
        let result = script?.executeAndReturnError(&error)
        return (error == nil) ? result?.stringValue : nil
    }
}

enum PlaybackCommand: Sendable, Equatable {
    case playPause
    case nextTrack
    case previousTrack
    case seek(Double)
}

struct PlaybackSnapshot {
    let isRunning: Bool
    let isPlaying: Bool
    let track: TrackInfo?
    let position: Double
    var playbackRate: Double = 1.0

    func position(after elapsed: TimeInterval) -> Double {
        guard isPlaying else { return position }
        return position + max(0, elapsed) * playbackRate
    }
}

@MainActor
final class SpotifyMonitor {
    struct Dependencies: Sendable {
        var runningBundleIds: @Sendable () -> Set<String>
        var executeNativeScript: @Sendable () -> String?
        var pollBrowser: @Sendable (Set<String>, Bool) -> PlaybackSnapshot?
        var executeTransportScript: @Sendable (String) -> Void

        static func live() -> Dependencies {
            let spotifyScript = CompiledScriptBox(source: SpotifyMonitor.scriptSource)
            let browserMonitor = BrowserMediaMonitor()
            return Dependencies(
                runningBundleIds: {
                    Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
                },
                executeNativeScript: {
                    spotifyScript.execute()
                },
                pollBrowser: { runningBundleIds, includeYouTubeVideos in
                    browserMonitor.poll(runningBundleIds: runningBundleIds, includeYouTubeVideos: includeYouTubeVideos)
                },
                executeTransportScript: { source in
                    if let script = NSAppleScript(source: source) {
                        var error: NSDictionary?
                        script.executeAndReturnError(&error)
                    }
                }
            )
        }
    }

    var onUpdate: ((PlaybackSnapshot) -> Void)?

    private let dependencies: Dependencies
    private var pollTimer: Timer?
    private var interpolationTimer: Timer?
    private var lastSnapshot: PlaybackSnapshot?
    private var lastPollDate: Date = .now
    private var lowCPUMode: Bool = true
    private var browserMusicEnabled: Bool = true
    private var browserYouTubeVideosEnabled: Bool = false
    private var isStarted: Bool = false
    private var browserPollGeneration: UInt64 = 0
    private var pollSequence: UInt64 = 0
    private var activePollToken: UInt64?
    private var needsFollowUpPoll: Bool = false
    private var lastNativeTrackId: String?
    private var consecutiveIdlePolls: Int = 0
    private let scriptQueue = DispatchQueue(label: "com.arya.bartune.applescript", qos: .utility)

    var isPolling: Bool { activePollToken != nil }

    private var spotifyObserver: NSObjectProtocol?
    private var musicObserver: NSObjectProtocol?

    private nonisolated static let spotifyBlock = """
    if application "Spotify" is running then
        tell application "Spotify"
            set pState to player state as string
            if pState is "playing" then
                set tId to "spotify:" & (id of current track as string)
                set tName to name of current track as string
                set tArtist to artist of current track as string
                set tAlbum to album of current track as string
                set tDur to duration of current track as string
                set tPos to player position as string
                set tArt to ""
                try
                    set tArt to artwork url of current track as string
                end try
                return "SPOTIFY" & sep & pState & sep & tId & sep & tName & sep & tArtist & sep & tAlbum & sep & tDur & sep & tPos & sep & tArt
            end if
        end tell
    end if
    """

    private nonisolated static let musicBlock = """
    if application "Music" is running then
        tell application "Music"
            set pState to player state as string
            if pState is "playing" then
                set tId to "music:" & (persistent ID of current track as string)
                set tName to name of current track as string
                set tArtist to artist of current track as string
                set tAlbum to album of current track as string
                set tDur to duration of current track as string
                set tPos to player position as string
                return "MUSIC" & sep & pState & sep & tId & sep & tName & sep & tArtist & sep & tAlbum & sep & tDur & sep & tPos & sep & ""
            end if
        end tell
    end if
    """

    nonisolated static func nativePlayerScriptSource(playerBlocks: [String]) -> String {
        // Each player gets its own try so one app's Automation denial doesn't abort the rest.
        let blocks = playerBlocks.map { "try\n\($0)\nend try" }
        return (["set sep to character id 31"] + blocks + ["return \"IDLE\""]).joined(separator: "\n")
    }

    private nonisolated static let scriptSource = nativePlayerScriptSource(playerBlocks: [spotifyBlock, musicBlock])

    init(dependencies: Dependencies = .live()) {
        self.dependencies = dependencies
    }

    func setLowCPUMode(_ enabled: Bool) {
        guard lowCPUMode != enabled else { return }
        lowCPUMode = enabled
        if isStarted {
            scheduleTimers()
        }
    }

    func setBrowserMusicEnabled(_ enabled: Bool) {
        guard browserMusicEnabled != enabled else { return }
        browserMusicEnabled = enabled
        if !enabled {
            browserPollGeneration &+= 1
            if lastSnapshot?.track?.id.hasPrefix("browser:") == true {
                let idleSnapshot = PlaybackSnapshot(isRunning: false, isPlaying: false, track: nil, position: 0)
                lastSnapshot = idleSnapshot
                lastPollDate = .now
                if isStarted {
                    updatePollTimer(isPlaying: false)
                }
                updateInterpolationTimer(isPlaying: false)
                onUpdate?(idleSnapshot)
            }
        }
        if isStarted {
            poll()
        }
    }

    func setBrowserYouTubeVideosEnabled(_ enabled: Bool) {
        guard browserYouTubeVideosEnabled != enabled else { return }
        browserYouTubeVideosEnabled = enabled
        if !enabled, let trackId = lastSnapshot?.track?.id, BrowserMediaParser.isStandardYouTubeTrackId(trackId) {
            let idle = PlaybackSnapshot(isRunning: false, isPlaying: false, track: nil, position: 0)
            lastSnapshot = idle
            updatePollTimer(isPlaying: false)
            updateInterpolationTimer(isPlaying: false)
            onUpdate?(idle)
        }
        if isStarted {
            poll()
        }
    }

    func sendCommand(_ command: PlaybackCommand) {
        let runningBundleIds = dependencies.runningBundleIds()
        let activeTrackId = lastSnapshot?.track?.id ?? ""

        let scriptSource = Self.transportScriptSource(
            for: command,
            activeTrackId: activeTrackId,
            lastNativeTrackId: lastNativeTrackId,
            runningBundleIds: runningBundleIds
        )
        let executeTransportScript = dependencies.executeTransportScript

        scriptQueue.async { [weak self] in
            if let source = scriptSource {
                executeTransportScript(source)
            }

            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
    }

    nonisolated static func transportScriptSource(
        for command: PlaybackCommand,
        activeTrackId: String,
        lastNativeTrackId: String? = nil,
        runningBundleIds: Set<String>
    ) -> String? {
        // Browser tabs can't be controlled yet; never fall back to a native player that isn't displayed.
        guard !activeTrackId.hasPrefix("browser:") else { return nil }
        let verb: String
        switch command {
        case .playPause: verb = "playpause"
        case .nextTrack: verb = "next track"
        case .previousTrack: verb = "previous track"
        case let .seek(seconds):
            let clamped = (seconds.isFinite && seconds > 0) ? seconds : 0.0
            let formatted = String(format: "%.3f", locale: Locale(identifier: "en_US_POSIX"), clamped)
            verb = "set player position to \(formatted)"
        }
        if activeTrackId.hasPrefix("music:"), runningBundleIds.contains("com.apple.Music") {
            return "tell application \"Music\" to \(verb)"
        }
        if activeTrackId.hasPrefix("spotify:"), runningBundleIds.contains("com.spotify.client") {
            return "tell application \"Spotify\" to \(verb)"
        }
        if let lastNativeTrackId {
            if lastNativeTrackId.hasPrefix("music:"), runningBundleIds.contains("com.apple.Music") {
                return "tell application \"Music\" to \(verb)"
            }
            if lastNativeTrackId.hasPrefix("spotify:"), runningBundleIds.contains("com.spotify.client") {
                return "tell application \"Spotify\" to \(verb)"
            }
        }
        if !runningBundleIds.contains("com.spotify.client") && runningBundleIds.contains("com.apple.Music") {
            return "tell application \"Music\" to \(verb)"
        }
        if runningBundleIds.contains("com.spotify.client") {
            return "tell application \"Spotify\" to \(verb)"
        }
        return nil
    }

    func start(lowCPUMode: Bool = true, browserMusicEnabled: Bool = true, browserYouTubeVideosEnabled: Bool = false) {
        stop()
        self.lowCPUMode = lowCPUMode
        self.browserMusicEnabled = browserMusicEnabled
        self.browserYouTubeVideosEnabled = browserYouTubeVideosEnabled
        self.isStarted = true

        // Event-driven playback notifications from Spotify and Apple Music
        let dnc = DistributedNotificationCenter.default()
        spotifyObserver = dnc.addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
        musicObserver = dnc.addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }

        poll()
        scheduleTimers()
    }

    func stop() {
        isStarted = false
        activePollToken = nil
        needsFollowUpPoll = false
        browserPollGeneration &+= 1
        lastSnapshot = nil
        lastNativeTrackId = nil
        pollTimer?.invalidate()
        pollTimer = nil
        interpolationTimer?.invalidate()
        interpolationTimer = nil

        let dnc = DistributedNotificationCenter.default()
        if let obs = spotifyObserver { dnc.removeObserver(obs); spotifyObserver = nil }
        if let obs = musicObserver { dnc.removeObserver(obs); musicObserver = nil }
    }

    private static let nativePlayerBundleIds: Set<String> = [
        "com.spotify.client",
        "com.apple.Music",
    ]

    private func scheduleTimers() {
        updatePollTimer(isPlaying: lastSnapshot?.isPlaying ?? false)
        updateInterpolationTimer(isPlaying: lastSnapshot?.isPlaying ?? false)
    }

    private func updatePollTimer(isPlaying: Bool) {
        // Event-driven via DistributedNotificationCenter; progressively back off when idle (5s -> 8s).
        let desiredInterval: TimeInterval
        if isPlaying {
            consecutiveIdlePolls = 0
            desiredInterval = 3.0
        } else {
            consecutiveIdlePolls += 1
            desiredInterval = consecutiveIdlePolls >= 3 ? 8.0 : 5.0
        }
        if let existing = pollTimer, abs(existing.timeInterval - desiredInterval) < 0.05 {
            return
        }
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: desiredInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }
    }

    private func updateInterpolationTimer(isPlaying: Bool) {
        if !isPlaying {
            // Pause interpolation completely when idle/paused -> ~0% CPU
            interpolationTimer?.invalidate()
            interpolationTimer = nil
            return
        }

        // Only drives line-boundary transitions; smooth sweep is rendered
        // directly inside KaraokeLineView via TimelineView without @Published churn.
        let desiredInterval: TimeInterval = lowCPUMode ? 0.25 : 0.08
        if let existing = interpolationTimer, abs(existing.timeInterval - desiredInterval) < 0.005 {
            return
        }

        interpolationTimer?.invalidate()
        interpolationTimer = Timer.scheduledTimer(withTimeInterval: desiredInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.emitInterpolated()
            }
        }
    }

    func poll() {
        guard activePollToken == nil else {
            if isStarted {
                needsFollowUpPoll = true
            }
            return
        }
        pollSequence &+= 1
        let token = pollSequence
        activePollToken = token
        let allowBrowser = browserMusicEnabled
        let includeYouTubeVideos = browserYouTubeVideosEnabled
        let requestBrowserGeneration = browserPollGeneration
        let runningBundleIds = dependencies.runningBundleIds()
        let hasNativePlayer = !runningBundleIds.isDisjoint(with: Self.nativePlayerBundleIds)
        let executeNativeScript = dependencies.executeNativeScript
        let pollBrowser = dependencies.pollBrowser

        scriptQueue.async { [weak self] in
            let pollStart = Date()
            let raw: String? = hasNativePlayer ? executeNativeScript() : "IDLE"
            let pollEnd = Date()
            // Midpoint compensates for AppleScript round-trip execution latency (~40-80ms)
            let now = Date(timeIntervalSince1970: (pollStart.timeIntervalSince1970 + pollEnd.timeIntervalSince1970) / 2.0)

            var browserSnap: PlaybackSnapshot?
            var browserNow = now
            if (raw == nil || raw == "IDLE") && allowBrowser {
                let bStart = Date()
                browserSnap = pollBrowser(runningBundleIds, includeYouTubeVideos)
                let bEnd = Date()
                browserNow = Date(timeIntervalSince1970: (bStart.timeIntervalSince1970 + bEnd.timeIntervalSince1970) / 2.0)
            }

            Task { @MainActor [weak self] in
                guard let self, self.activePollToken == token else { return }
                self.activePollToken = nil
                let shouldRepoll = self.needsFollowUpPoll
                self.needsFollowUpPoll = false
                let filteredBrowserSnap = Self.acceptedBrowserSnapshot(
                    browserSnap,
                    browserMusicEnabled: self.browserMusicEnabled,
                    includeYouTubeVideos: self.browserYouTubeVideosEnabled
                )
                self.handlePollResult(
                    raw: raw,
                    now: now,
                    browserSnap: filteredBrowserSnap,
                    browserNow: browserNow,
                    browserPollGeneration: requestBrowserGeneration
                )
                if shouldRepoll, self.isStarted {
                    self.poll()
                }
            }
        }
    }

    nonisolated static func acceptedBrowserSnapshot(
        _ snapshot: PlaybackSnapshot?,
        browserMusicEnabled: Bool,
        includeYouTubeVideos: Bool
    ) -> PlaybackSnapshot? {
        guard browserMusicEnabled, let snapshot else { return nil }
        if !includeYouTubeVideos,
           let trackId = snapshot.track?.id,
           BrowserMediaParser.isStandardYouTubeTrackId(trackId) {
            return nil
        }
        return snapshot
    }

    private func handlePollResult(
        raw: String?,
        now: Date,
        browserSnap: PlaybackSnapshot?,
        browserNow: Date,
        browserPollGeneration: UInt64
    ) {
        guard let raw, raw != "IDLE" else {
            let validBrowserSnap = (browserMusicEnabled && browserPollGeneration == self.browserPollGeneration)
                ? browserSnap
                : nil
            if let validBrowserSnap {
                lastSnapshot = validBrowserSnap
                lastPollDate = browserNow
                if isStarted {
                    updatePollTimer(isPlaying: validBrowserSnap.isPlaying)
                    updateInterpolationTimer(isPlaying: validBrowserSnap.isPlaying)
                }
                onUpdate?(validBrowserSnap)
                return
            }
            let snapshot = PlaybackSnapshot(isRunning: false, isPlaying: false, track: nil, position: 0)
            lastSnapshot = snapshot
            lastPollDate = now
            if isStarted {
                updatePollTimer(isPlaying: false)
                updateInterpolationTimer(isPlaying: false)
            }
            onUpdate?(snapshot)
            return
        }

        let parts = raw.components(separatedBy: "\u{1F}")
        guard parts.count >= 8 else { return }

        let source = parts[0]
        let isPlaying = parts[1].lowercased() == "playing"
        let trackId = parts[2]
        let title = parts[3]
        let artist = parts[4]
        let album = parts[5]

        let rawDuration = Self.parseLocaleDouble(parts[6]) ?? 0
        let durationSec = (source == "SPOTIFY") ? (rawDuration / 1000.0) : rawDuration
        let positionSec = Self.parseLocaleDouble(parts[7]) ?? 0
        let artworkURL = parts.count >= 9 && !parts[8].isEmpty ? parts[8] : nil

        let track = TrackInfo(
            id: trackId,
            title: title,
            artist: artist,
            album: album,
            duration: durationSec,
            artworkURL: artworkURL
        )
        if trackId.hasPrefix("music:") || trackId.hasPrefix("spotify:") {
            lastNativeTrackId = trackId
        }

        let snapshot = PlaybackSnapshot(
            isRunning: true,
            isPlaying: isPlaying,
            track: track,
            position: positionSec
        )
        lastSnapshot = snapshot
        lastPollDate = now
        if isStarted {
            updatePollTimer(isPlaying: isPlaying)
            updateInterpolationTimer(isPlaying: isPlaying)
        }
        onUpdate?(snapshot)
    }

    private func emitInterpolated() {
        guard let snap = lastSnapshot, snap.isPlaying, let track = snap.track else { return }
        if track.id.hasPrefix("browser:") && !browserMusicEnabled {
            return
        }
        let elapsed = Date().timeIntervalSince(lastPollDate)
        let interpolated = PlaybackSnapshot(
            isRunning: snap.isRunning,
            isPlaying: snap.isPlaying,
            track: track,
            position: snap.position(after: elapsed),
            playbackRate: snap.playbackRate
        )
        onUpdate?(interpolated)
    }

    nonisolated static func parseLocaleDouble(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }
}
