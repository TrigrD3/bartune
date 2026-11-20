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

enum PlaybackCommand: Sendable {
    case playPause
    case nextTrack
    case previousTrack
}

struct PlaybackSnapshot {
    let isRunning: Bool
    let isPlaying: Bool
    let track: TrackInfo?
    let position: Double
}

@MainActor
final class SpotifyMonitor {
    var onUpdate: ((PlaybackSnapshot) -> Void)?

    private var pollTimer: Timer?
    private var interpolationTimer: Timer?
    private var lastSnapshot: PlaybackSnapshot?
    private var lastPollDate: Date = .now
    private var lowCPUMode: Bool = true
    private var browserMusicEnabled: Bool = true
    private var isStarted: Bool = false
    private var isPolling: Bool = false
    private var consecutiveIdlePolls: Int = 0
    private let browserMonitor = BrowserMediaMonitor()
    private let scriptQueue = DispatchQueue(label: "com.arya.bartune.applescript", qos: .utility)

    private var spotifyObserver: NSObjectProtocol?
    private var musicObserver: NSObjectProtocol?

    private static let scriptSource = """
    set sep to character id 31
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
    return "IDLE"
    """

    private let spotifyScript = CompiledScriptBox(source: SpotifyMonitor.scriptSource)

    init() {}

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
        if isStarted {
            poll()
        }
    }

    func sendCommand(_ command: PlaybackCommand) {
        let runningBundleIds = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        let activeTrackId = lastSnapshot?.track?.id ?? ""

        scriptQueue.async { [weak self] in
            let scriptSource: String?
            if activeTrackId.hasPrefix("music:")
                || (!runningBundleIds.contains("com.spotify.client") && runningBundleIds.contains("com.apple.Music")) {
                let verb = switch command {
                case .playPause: "playpause"
                case .nextTrack: "next track"
                case .previousTrack: "previous track"
                }
                scriptSource = "tell application \"Music\" to \(verb)"
            } else if runningBundleIds.contains("com.spotify.client") {
                let verb = switch command {
                case .playPause: "playpause"
                case .nextTrack: "next track"
                case .previousTrack: "previous track"
                }
                scriptSource = "tell application \"Spotify\" to \(verb)"
            } else {
                scriptSource = nil
            }

            if let source = scriptSource, let script = NSAppleScript(source: source) {
                var error: NSDictionary?
                script.executeAndReturnError(&error)
            }

            Task { @MainActor [weak self] in
                self?.poll()
            }
        }
    }

    func start(lowCPUMode: Bool = true, browserMusicEnabled: Bool = true) {
        stop()
        self.lowCPUMode = lowCPUMode
        self.browserMusicEnabled = browserMusicEnabled
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

    private func poll() {
        guard !isPolling else { return }
        isPolling = true
        let allowBrowser = browserMusicEnabled
        let runningBundleIds = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )
        let hasNativePlayer = !runningBundleIds.isDisjoint(with: Self.nativePlayerBundleIds)
        let browserMonitor = self.browserMonitor
        let spotifyScript = self.spotifyScript

        scriptQueue.async { [weak self] in
            let pollStart = Date()
            let raw: String? = hasNativePlayer ? spotifyScript.execute() : "IDLE"
            let pollEnd = Date()
            // Midpoint compensates for AppleScript round-trip execution latency (~40-80ms)
            let now = Date(timeIntervalSince1970: (pollStart.timeIntervalSince1970 + pollEnd.timeIntervalSince1970) / 2.0)

            var browserSnap: PlaybackSnapshot?
            var browserNow = now
            if (raw == nil || raw == "IDLE") && allowBrowser {
                let bStart = Date()
                browserSnap = browserMonitor.poll(runningBundleIds: runningBundleIds)
                let bEnd = Date()
                browserNow = Date(timeIntervalSince1970: (bStart.timeIntervalSince1970 + bEnd.timeIntervalSince1970) / 2.0)
            }

            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.isPolling = false }
                self.handlePollResult(raw: raw, now: now, browserSnap: browserSnap, browserNow: browserNow)
            }
        }
    }

    private func handlePollResult(raw: String?, now: Date, browserSnap: PlaybackSnapshot?, browserNow: Date) {
        guard let raw, raw != "IDLE" else {
            if let browserSnap {
                lastSnapshot = browserSnap
                lastPollDate = browserNow
                updatePollTimer(isPlaying: browserSnap.isPlaying)
                updateInterpolationTimer(isPlaying: browserSnap.isPlaying)
                onUpdate?(browserSnap)
                return
            }
            let snapshot = PlaybackSnapshot(isRunning: false, isPlaying: false, track: nil, position: 0)
            lastSnapshot = snapshot
            lastPollDate = now
            updatePollTimer(isPlaying: false)
            updateInterpolationTimer(isPlaying: false)
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

        let snapshot = PlaybackSnapshot(
            isRunning: true,
            isPlaying: isPlaying,
            track: track,
            position: positionSec
        )
        lastSnapshot = snapshot
        lastPollDate = now
        updatePollTimer(isPlaying: isPlaying)
        updateInterpolationTimer(isPlaying: isPlaying)
        onUpdate?(snapshot)
    }

    private func emitInterpolated() {
        guard let snap = lastSnapshot, snap.isPlaying, let track = snap.track else { return }
        let elapsed = Date().timeIntervalSince(lastPollDate)
        let interpolated = PlaybackSnapshot(
            isRunning: snap.isRunning,
            isPlaying: snap.isPlaying,
            track: track,
            position: snap.position + elapsed
        )
        onUpdate?(interpolated)
    }

    nonisolated static func parseLocaleDouble(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }
}
