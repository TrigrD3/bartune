import Foundation
import Combine

@MainActor
final class LyricsState: ObservableObject {
    @Published var currentText: String = ""
    @Published var currentLineId: Int = -1
    @Published var trackSummary: String = "Not Playing"
    @Published var isPlaying: Bool = false
    @Published var isEnabled: Bool = true
    @Published var hasLyrics: Bool = false
    @Published var offsetSeconds: Double = 0.0

    var shouldShowOverlay: Bool {
        isEnabled && isPlaying && !currentText.isEmpty
    }

    private var lines: [LyricLine] = []
    private var currentTrackId: String?

    func setTrack(_ track: TrackInfo?, lyrics: [LyricLine]) {
        currentTrackId = track?.id
        lines = lyrics
        hasLyrics = !lyrics.isEmpty
        if let track {
            trackSummary = "\(track.artist) — \(track.title)"
        } else {
            trackSummary = "Not Playing"
            currentText = ""
            currentLineId = -1
        }
    }

    func updatePlayback(isPlaying: Bool, position: Double) {
        self.isPlaying = isPlaying
        guard isPlaying, !lines.isEmpty else {
            if !isPlaying {
                currentText = ""
                currentLineId = -1
            }
            return
        }

        let effectivePos = position + offsetSeconds
        var matched: LyricLine?

        // Binary search for the latest line with timestamp <= effectivePos
        var lo = 0
        var hi = lines.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].timestamp <= effectivePos {
                matched = lines[mid]
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }

        if let line = matched {
            if line.id != currentLineId {
                currentLineId = line.id
                currentText = line.text.isEmpty ? "♪" : line.text
            }
        } else if currentLineId != -1 {
            currentLineId = -1
            currentText = "♪"
        }
    }
}
