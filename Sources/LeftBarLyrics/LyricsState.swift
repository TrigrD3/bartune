import Foundation
import Combine

@MainActor
final class LyricsState: ObservableObject {
    @Published var currentText: String = ""
    @Published var currentLineId: Int = -1
    @Published var lineProgress: Double = 0.0
    @Published var cursorLocalX: CGFloat? = nil
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
            lineProgress = 0.0
        }
    }

    func updatePlayback(isPlaying: Bool, position: Double) {
        self.isPlaying = isPlaying
        guard isPlaying, !lines.isEmpty else {
            if !isPlaying {
                currentText = ""
                currentLineId = -1
                lineProgress = 0.0
            }
            return
        }

        let effectivePos = position + offsetSeconds
        var matchedIndex: Int?

        // Binary search for the latest line with timestamp <= effectivePos
        var lo = 0
        var hi = lines.count - 1
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].timestamp <= effectivePos {
                matchedIndex = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }

        if let idx = matchedIndex {
            let line = lines[idx]
            let displayText = line.text.isEmpty ? "♪" : line.text

            // Compute singing duration for smooth karaoke fill
            let rawDuration: Double
            if idx + 1 < lines.count {
                rawDuration = max(0.4, lines[idx + 1].timestamp - line.timestamp)
            } else {
                rawDuration = 4.5
            }

            // Cap fill duration on long instrumental gaps so words still sweep at a natural singing pace
            let estimatedSingDuration = max(2.2, Double(displayText.count) * 0.11)
            let effectiveDuration = min(rawDuration, estimatedSingDuration)
            let elapsed = max(0.0, effectivePos - line.timestamp)
            let progress = min(1.0, max(0.0, elapsed / effectiveDuration))

            if line.id != currentLineId {
                currentLineId = line.id
                currentText = displayText
            }
            lineProgress = progress
        } else if currentLineId != -1 {
            currentLineId = -1
            currentText = "♪"
            lineProgress = 0.0
        }
    }
}
