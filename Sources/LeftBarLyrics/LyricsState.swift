import Foundation
import Combine

enum HoverMode: String, CaseIterable, Identifiable {
    case spotlight = "spotlight"
    case hideAll = "hideAll"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .spotlight: return "Cursor Spotlight"
        case .hideAll: return "Hide Entire Bar"
        }
    }

    var description: String {
        switch self {
        case .spotlight:
            return "Reveals only the menu item under your cursor while keeping the rest of the lyrics visible."
        case .hideAll:
            return "Fades out the entire lyrics strip on hover to reveal File, Edit, View, Window, and Help."
        }
    }
}

@MainActor
final class LyricsState: ObservableObject {
    private enum Keys {
        static let hoverMode = "leftbar.hoverMode"
        static let spotlightWidth = "leftbar.spotlightWidth"
        static let karaokeEnabled = "leftbar.karaokeEnabled"
        static let showEqualizer = "leftbar.showEqualizer"
        static let fontSize = "leftbar.fontSize"
        static let backgroundOpacity = "leftbar.backgroundOpacity"
    }

    @Published var currentText: String = ""
    @Published var currentLineId: Int = -1
    @Published var lineProgress: Double = 0.0
    @Published var cursorLocalX: CGFloat? = nil
    @Published var trackSummary: String = "Not Playing"
    @Published var isPlaying: Bool = false
    @Published var isEnabled: Bool = true
    @Published var hasLyrics: Bool = false
    @Published var offsetSeconds: Double = 0.0

    // Persisted user settings
    @Published var hoverMode: HoverMode {
        didSet {
            UserDefaults.standard.set(hoverMode.rawValue, forKey: Keys.hoverMode)
            if hoverMode == .hideAll {
                cursorLocalX = nil
            }
        }
    }

    @Published var spotlightWidth: Double {
        didSet { UserDefaults.standard.set(spotlightWidth, forKey: Keys.spotlightWidth) }
    }

    @Published var karaokeAnimationEnabled: Bool {
        didSet { UserDefaults.standard.set(karaokeAnimationEnabled, forKey: Keys.karaokeEnabled) }
    }

    @Published var showEqualizer: Bool {
        didSet { UserDefaults.standard.set(showEqualizer, forKey: Keys.showEqualizer) }
    }

    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize) }
    }

    @Published var backgroundOpacity: Double {
        didSet { UserDefaults.standard.set(backgroundOpacity, forKey: Keys.backgroundOpacity) }
    }

    var shouldShowOverlay: Bool {
        isEnabled && isPlaying && !currentText.isEmpty
    }

    private var lines: [LyricLine] = []
    private var currentTrackId: String?

    init() {
        let ud = UserDefaults.standard
        if let rawMode = ud.string(forKey: Keys.hoverMode),
           let parsed = HoverMode(rawValue: rawMode) {
            self.hoverMode = parsed
        } else {
            self.hoverMode = .spotlight
        }

        let storedWidth = ud.double(forKey: Keys.spotlightWidth)
        self.spotlightWidth = storedWidth > 0 ? storedWidth : 68.0

        self.karaokeAnimationEnabled = ud.object(forKey: Keys.karaokeEnabled) as? Bool ?? true
        self.showEqualizer = ud.object(forKey: Keys.showEqualizer) as? Bool ?? true

        let storedFont = ud.double(forKey: Keys.fontSize)
        self.fontSize = storedFont > 0 ? storedFont : 13.0

        let storedOpacity = ud.double(forKey: Keys.backgroundOpacity)
        self.backgroundOpacity = storedOpacity > 0 ? storedOpacity : 0.96
    }

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

            let rawDuration: Double
            if idx + 1 < lines.count {
                rawDuration = max(0.4, lines[idx + 1].timestamp - line.timestamp)
            } else {
                rawDuration = 4.5
            }

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
