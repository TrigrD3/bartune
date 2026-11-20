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

    private static let scriptSource = """
    if application "Spotify" is running then
        tell application "Spotify"
            set pState to player state as string
            if pState is "stopped" then
                return "STOPPED"
            end if
            set tId to id of current track as string
            set tName to name of current track as string
            set tArtist to artist of current track as string
            set tAlbum to album of current track as string
            set tDur to duration of current track as string
            set tPos to player position as string
            set sep to character id 31
            return "RUNNING" & sep & pState & sep & tId & sep & tName & sep & tArtist & sep & tAlbum & sep & tDur & sep & tPos
        end tell
    else
        return "NOT_RUNNING"
    end if
    """

    private let compiledScript: NSAppleScript?

    init() {
        self.compiledScript = NSAppleScript(source: Self.scriptSource)
    }

    func start() {
        stop()
        poll()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.poll()
            }
        }

        interpolationTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.emitInterpolated()
            }
        }
    }

    func stop() {
        pollTimer?.invalidate()
        pollTimer = nil
        interpolationTimer?.invalidate()
        interpolationTimer = nil
    }

    private func poll() {
        guard let script = compiledScript else { return }

        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        let now = Date()

        guard error == nil, let raw = result.stringValue else {
            let snapshot = PlaybackSnapshot(isRunning: false, isPlaying: false, track: nil, position: 0)
            lastSnapshot = snapshot
            lastPollDate = now
            onUpdate?(snapshot)
            return
        }

        if raw == "NOT_RUNNING" {
            let snapshot = PlaybackSnapshot(isRunning: false, isPlaying: false, track: nil, position: 0)
            lastSnapshot = snapshot
            lastPollDate = now
            onUpdate?(snapshot)
            return
        }

        if raw == "STOPPED" {
            let snapshot = PlaybackSnapshot(isRunning: true, isPlaying: false, track: nil, position: 0)
            lastSnapshot = snapshot
            lastPollDate = now
            onUpdate?(snapshot)
            return
        }

        let parts = raw.components(separatedBy: "\u{1F}")
        guard parts.count >= 8, parts[0] == "RUNNING" else { return }

        let isPlaying = parts[1].lowercased() == "playing"
        let trackId = parts[2]
        let title = parts[3]
        let artist = parts[4]
        let album = parts[5]

        // Locale-safe decimal parsing: AppleScript `as string` uses `,` in locales like en_ID, de_DE, uk_UA.
        let durationMs = Self.parseLocaleDouble(parts[6]) ?? 0
        let positionSec = Self.parseLocaleDouble(parts[7]) ?? 0

        let track = TrackInfo(
            id: trackId,
            title: title,
            artist: artist,
            album: album,
            duration: durationMs / 1000.0
        )

        let snapshot = PlaybackSnapshot(
            isRunning: true,
            isPlaying: isPlaying,
            track: track,
            position: positionSec
        )
        lastSnapshot = snapshot
        lastPollDate = now
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
