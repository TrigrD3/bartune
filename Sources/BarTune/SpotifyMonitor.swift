import Foundation
import AppKit

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
    private var isStarted: Bool = false

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

    private let compiledScript: NSAppleScript?

    init() {
        self.compiledScript = NSAppleScript(source: Self.scriptSource)
    }

    func setLowCPUMode(_ enabled: Bool) {
        guard lowCPUMode != enabled else { return }
        lowCPUMode = enabled
        if isStarted {
            scheduleTimers()
        }
    }

    func start(lowCPUMode: Bool = true) {
        stop()
        self.lowCPUMode = lowCPUMode
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

    private func scheduleTimers() {
        pollTimer?.invalidate()
        // Always event-driven via DistributedNotificationCenter; light 3.0s drift check only.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }

        updateInterpolationTimer(isPlaying: lastSnapshot?.isPlaying ?? false)
    }

    private func updateInterpolationTimer(isPlaying: Bool) {
        if !isPlaying {
            // Pause interpolation completely when idle/paused -> ~0% CPU
            interpolationTimer?.invalidate()
            interpolationTimer = nil
            return
        }

        let desiredInterval: TimeInterval = lowCPUMode ? 0.12 : 0.033
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
        guard let script = compiledScript else { return }

        let pollStart = Date()
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        let pollEnd = Date()
        // Midpoint compensates for AppleScript round-trip execution latency (~40-80ms)
        let now = Date(timeIntervalSince1970: (pollStart.timeIntervalSince1970 + pollEnd.timeIntervalSince1970) / 2.0)

        guard error == nil, let raw = result.stringValue, raw != "IDLE" else {
            let snapshot = PlaybackSnapshot(isRunning: false, isPlaying: false, track: nil, position: 0)
            lastSnapshot = snapshot
            lastPollDate = now
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

    static func parseLocaleDouble(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.replacingOccurrences(of: ",", with: ".")
        return Double(normalized)
    }
}
