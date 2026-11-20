import AppKit
import Combine
import Foundation
import ServiceManagement
import SwiftUI

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

enum ThemeMode: String, CaseIterable, Identifiable {
    case system = "system"
    case albumAccent = "albumAccent"
    case albumTint = "albumTint"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "System"
        case .albumAccent: return "Album Accent"
        case .albumTint: return "Album Tint"
        }
    }

    var description: String {
        switch self {
        case .system:
            return "Matches your standard macOS menu bar appearance."
        case .albumAccent:
            return "Highlights sung lyrics and equalizer bars using the current album's vibrant color."
        case .albumTint:
            return "Tints the menu bar strip with the current album's color palette."
        }
    }
}

enum FontOption: String, CaseIterable, Identifiable {
    case sfPro = "sfPro"
    case sfRounded = "sfRounded"
    case sfSerif = "sfSerif"
    case sfMono = "sfMono"
    case avenirNext = "avenirNext"
    case helveticaNeue = "helveticaNeue"
    case futura = "futura"
    case georgia = "georgia"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sfPro: return "SF Pro (System)"
        case .sfRounded: return "SF Rounded"
        case .sfSerif: return "New York (Serif)"
        case .sfMono: return "SF Mono"
        case .avenirNext: return "Avenir Next"
        case .helveticaNeue: return "Helvetica Neue"
        case .futura: return "Futura"
        case .georgia: return "Georgia"
        }
    }

    func font(size: Double, weight: FontWeightOption) -> Font {
        switch self {
        case .sfPro:
            return .system(size: size, weight: weight.swiftUIWeight, design: .default)
        case .sfRounded:
            return .system(size: size, weight: weight.swiftUIWeight, design: .rounded)
        case .sfSerif:
            return .system(size: size, weight: weight.swiftUIWeight, design: .serif)
        case .sfMono:
            return .system(size: size, weight: weight.swiftUIWeight, design: .monospaced)
        case .avenirNext:
            return .custom("Avenir Next", size: size).weight(weight.swiftUIWeight)
        case .helveticaNeue:
            return .custom("Helvetica Neue", size: size).weight(weight.swiftUIWeight)
        case .futura:
            return .custom("Futura", size: size).weight(weight.swiftUIWeight)
        case .georgia:
            return .custom("Georgia", size: size).weight(weight.swiftUIWeight)
        }
    }
}

enum FontWeightOption: String, CaseIterable, Identifiable {
    case regular = "regular"
    case medium = "medium"
    case semibold = "semibold"
    case bold = "bold"

    var id: String { rawValue }

    var title: String {
        rawValue.capitalized
    }

    var swiftUIWeight: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
    }
}

enum VisualizerStyle: String, CaseIterable, Identifiable {
    case bars
    case wave
    case dots
    case vinyl
    case note

    var id: String { rawValue }

    var title: String {
        switch self {
        case .bars: return "Bars"
        case .wave: return "Wave"
        case .dots: return "Dots"
        case .vinyl: return "Vinyl"
        case .note: return "Note"
        }
    }
}

@MainActor
final class LyricsState: ObservableObject {
    private enum Keys {
        static let hoverMode = "bartune.hoverMode"
        static let spotlightWidth = "bartune.spotlightWidth"
        static let karaokeEnabled = "bartune.karaokeEnabled"
        static let showEqualizer = "bartune.showEqualizer"
        static let animateVisualizer = "bartune.animateVisualizer"
        static let visualizerStyle = "bartune.visualizerStyle"
        static let visualizerWidth = "bartune.visualizerWidth"
        static let fontSize = "bartune.fontSize"
        static let backgroundOpacity = "bartune.backgroundOpacity"
        static let themeMode = "bartune.themeMode"
        static let fontOption = "bartune.fontOption"
        static let fontWeight = "bartune.fontWeight"
        static let romanizeJapanese = "bartune.romanizeJapanese"
        static let romanizeKorean = "bartune.romanizeKorean"
        static let romanizeChinese = "bartune.romanizeChinese"
        static let lowCPUMode = "bartune.lowCPUMode"
        static let browserMusicEnabled = "bartune.browserMusicEnabled"
        static let trackOffsets = "bartune.trackOffsets"
    }

    private static let maxStoredOffsets = 500

    @Published var currentText: String = ""
    @Published var currentLineId: Int = -1
    @Published var lineProgress: Double = 0.0
    @Published var activeLine: LyricLine? = nil
    @Published var activeLineNextTimestamp: Double = 0.0
    var playbackAnchorPosition: Double = 0.0
    var playbackAnchorDate: Date = .now
    @Published var cursorLocalX: CGFloat? = nil
    @Published var trackSummary: String = "Not Playing"
    @Published var isPlaying: Bool = false
    @Published var isEnabled: Bool = true
    @Published var hasLyrics: Bool = false
    @Published var offsetSeconds: Double = 0.0 {
        didSet {
            guard !isRestoringOffset, let trackId = currentTrackId else { return }
            if abs(offsetSeconds) < 0.01 {
                trackOffsets.removeValue(forKey: trackId)
            } else {
                trackOffsets[trackId] = offsetSeconds
                if trackOffsets.count > Self.maxStoredOffsets, let victim = trackOffsets.keys.first {
                    trackOffsets.removeValue(forKey: victim)
                }
            }
            userDefaults.set(trackOffsets, forKey: Keys.trackOffsets)
        }
    }
    @Published var albumColors: ExtractedAlbumColors? = nil

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

    @Published var themeMode: ThemeMode {
        didSet { UserDefaults.standard.set(themeMode.rawValue, forKey: Keys.themeMode) }
    }

    @Published var fontOption: FontOption {
        didSet { UserDefaults.standard.set(fontOption.rawValue, forKey: Keys.fontOption) }
    }

    @Published var fontWeight: FontWeightOption {
        didSet { UserDefaults.standard.set(fontWeight.rawValue, forKey: Keys.fontWeight) }
    }

    @Published var karaokeAnimationEnabled: Bool {
        didSet { UserDefaults.standard.set(karaokeAnimationEnabled, forKey: Keys.karaokeEnabled) }
    }

    @Published var showEqualizer: Bool {
        didSet { userDefaults.set(showEqualizer, forKey: Keys.showEqualizer) }
    }

    @Published var animateVisualizer: Bool {
        didSet { userDefaults.set(animateVisualizer, forKey: Keys.animateVisualizer) }
    }

    @Published var visualizerStyle: VisualizerStyle {
        didSet { UserDefaults.standard.set(visualizerStyle.rawValue, forKey: Keys.visualizerStyle) }
    }

    @Published var visualizerWidth: Double {
        didSet { UserDefaults.standard.set(visualizerWidth, forKey: Keys.visualizerWidth) }
    }

    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize) }
    }

    @Published var backgroundOpacity: Double {
        didSet { UserDefaults.standard.set(backgroundOpacity, forKey: Keys.backgroundOpacity) }
    }

    @Published var romanizeJapanese: Bool {
        didSet {
            UserDefaults.standard.set(romanizeJapanese, forKey: Keys.romanizeJapanese)
            refreshCurrentLineText()
        }
    }

    @Published var romanizeKorean: Bool {
        didSet {
            userDefaults.set(romanizeKorean, forKey: Keys.romanizeKorean)
            refreshCurrentLineText()
        }
    }

    @Published var romanizeChinese: Bool {
        didSet {
            userDefaults.set(romanizeChinese, forKey: Keys.romanizeChinese)
            refreshCurrentLineText()
        }
    }

    @Published var lowCPUMode: Bool {
        didSet { userDefaults.set(lowCPUMode, forKey: Keys.lowCPUMode) }
    }

    @Published var browserMusicEnabled: Bool {
        didSet { userDefaults.set(browserMusicEnabled, forKey: Keys.browserMusicEnabled) }
    }

    @Published var launchAtLogin: Bool = false {
        didSet {
            guard !isSyncingLaunchAtLogin else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                isSyncingLaunchAtLogin = true
                launchAtLogin = (SMAppService.mainApp.status == .enabled)
                isSyncingLaunchAtLogin = false
            }
        }
    }

    var shouldShowOverlay: Bool {
        isEnabled && isPlaying && !currentText.isEmpty
    }

    private let userDefaults: UserDefaults
    private var rawLines: [LyricLine] = []
    private var romanizedLines: [LyricLine] = []
    private var koreanRomanizedLines: [LyricLine] = []
    private var chineseRomanizedLines: [LyricLine] = []
    private var isJapaneseSong: Bool = false
    private var isKoreanSong: Bool = false
    private var isChineseSong: Bool = false
    private var currentTrackId: String?
    private var trackOffsets: [String: Double] = [:]
    private var isRestoringOffset: Bool = false
    private var isSyncingLaunchAtLogin: Bool = false

    private var activeLines: [LyricLine] {
        if romanizeJapanese && isJapaneseSong {
            return romanizedLines
        }
        if romanizeKorean && isKoreanSong {
            return koreanRomanizedLines
        }
        if romanizeChinese && isChineseSong {
            return chineseRomanizedLines
        }
        return rawLines
    }

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        let ud = userDefaults

        if let raw = ud.string(forKey: Keys.hoverMode), let parsed = HoverMode(rawValue: raw) {
            self.hoverMode = parsed
        } else {
            self.hoverMode = .spotlight
        }

        let storedWidth = ud.double(forKey: Keys.spotlightWidth)
        self.spotlightWidth = storedWidth > 0 ? storedWidth : 68.0

        if let raw = ud.string(forKey: Keys.themeMode), let parsed = ThemeMode(rawValue: raw) {
            self.themeMode = parsed
        } else {
            self.themeMode = .albumAccent
        }

        if let raw = ud.string(forKey: Keys.fontOption), let parsed = FontOption(rawValue: raw) {
            self.fontOption = parsed
        } else {
            self.fontOption = .sfPro
        }

        if let raw = ud.string(forKey: Keys.fontWeight), let parsed = FontWeightOption(rawValue: raw) {
            self.fontWeight = parsed
        } else {
            self.fontWeight = .medium
        }

        self.karaokeAnimationEnabled = ud.object(forKey: Keys.karaokeEnabled) as? Bool ?? true
        self.showEqualizer = ud.object(forKey: Keys.showEqualizer) as? Bool ?? true
        self.animateVisualizer = ud.object(forKey: Keys.animateVisualizer) as? Bool ?? true
        if let raw = ud.string(forKey: Keys.visualizerStyle), let parsed = VisualizerStyle(rawValue: raw) {
            self.visualizerStyle = parsed
        } else {
            self.visualizerStyle = .bars
        }

        let storedVisWidth = ud.double(forKey: Keys.visualizerWidth)
        self.visualizerWidth = storedVisWidth > 0 ? storedVisWidth : 20.0

        let storedFont = ud.double(forKey: Keys.fontSize)
        self.fontSize = storedFont > 0 ? storedFont : 13.0

        let storedOpacity = ud.double(forKey: Keys.backgroundOpacity)
        self.backgroundOpacity = storedOpacity > 0 ? storedOpacity : 0.96

        self.romanizeJapanese = ud.object(forKey: Keys.romanizeJapanese) as? Bool ?? true
        self.romanizeKorean = ud.object(forKey: Keys.romanizeKorean) as? Bool ?? true
        self.romanizeChinese = ud.object(forKey: Keys.romanizeChinese) as? Bool ?? true
        self.lowCPUMode = ud.object(forKey: Keys.lowCPUMode) as? Bool ?? true
        self.browserMusicEnabled = ud.object(forKey: Keys.browserMusicEnabled) as? Bool ?? true
        self.trackOffsets = ud.dictionary(forKey: Keys.trackOffsets) as? [String: Double] ?? [:]

        self.isSyncingLaunchAtLogin = true
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
        self.isSyncingLaunchAtLogin = false
    }

    func setTrack(_ track: TrackInfo?, lyrics: [LyricLine]) {
        let previousTrackId = currentTrackId
        currentTrackId = track?.id
        if currentTrackId != previousTrackId {
            isRestoringOffset = true
            offsetSeconds = currentTrackId.flatMap { trackOffsets[$0] } ?? 0.0
            isRestoringOffset = false
        }

        rawLines = lyrics
        isJapaneseSong = JapaneseRomanizer.isJapaneseTrack(lyrics)
        isKoreanSong = KoreanRomanizer.isKoreanTrack(lyrics)
        isChineseSong = ChineseRomanizer.isChineseTrack(lyrics)
        if isJapaneseSong {
            romanizedLines = Self.romanizeLines(lyrics, using: JapaneseRomanizer.romanizeLine)
        } else {
            romanizedLines = []
        }
        if isKoreanSong {
            koreanRomanizedLines = Self.romanizeLines(lyrics, using: KoreanRomanizer.romanizeLine)
        } else {
            koreanRomanizedLines = []
        }
        if isChineseSong {
            chineseRomanizedLines = Self.romanizeLines(lyrics, using: ChineseRomanizer.romanizeLine)
        } else {
            chineseRomanizedLines = []
        }

        hasLyrics = !lyrics.isEmpty
        if let track {
            trackSummary = "\(track.artist) — \(track.title)"
        } else {
            trackSummary = "Not Playing"
            currentText = ""
            currentLineId = -1
            lineProgress = 0.0
            albumColors = nil
        }
    }

    private static func romanizeLines(_ lyrics: [LyricLine], using transform: (String) -> String) -> [LyricLine] {
        lyrics.map { line in
            if !line.words.isEmpty {
                let romWords = line.words.map { w in
                    WordTimestamp(
                        timestamp: w.timestamp,
                        duration: w.duration,
                        text: transform(w.text) + " "
                    )
                }
                let joined = romWords.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                return LyricLine(
                    id: line.id,
                    timestamp: line.timestamp,
                    duration: line.duration,
                    text: joined,
                    words: romWords
                )
            }
            return LyricLine(
                id: line.id,
                timestamp: line.timestamp,
                duration: line.duration,
                text: transform(line.text)
            )
        }
    }

    private func refreshCurrentLineText() {
        guard currentLineId >= 0 else { return }
        if let line = activeLines.first(where: { $0.id == currentLineId }) {
            currentText = line.text.isEmpty ? "♪" : line.text
        }
    }

    func updatePlayback(isPlaying: Bool, position: Double) {
        if self.isPlaying != isPlaying {
            self.isPlaying = isPlaying
        }
        playbackAnchorPosition = position
        playbackAnchorDate = Date()
        let lines = activeLines
        guard isPlaying, !lines.isEmpty else {
            if !isPlaying {
                if !currentText.isEmpty { currentText = "" }
                if currentLineId != -1 { currentLineId = -1 }
                if activeLine != nil { activeLine = nil }
                if lineProgress != 0.0 { lineProgress = 0.0 }
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
            let nextTimestamp: Double = (idx + 1 < lines.count)
                ? lines[idx + 1].timestamp
                : (line.timestamp + 4.5)

            if line.id != currentLineId {
                currentLineId = line.id
                currentText = displayText
                activeLine = line
                activeLineNextTimestamp = nextTimestamp
            }
        } else if currentLineId != -1 {
            currentLineId = -1
            currentText = "♪"
            activeLine = nil
            lineProgress = 0.0
        }
    }

    func liveProgress(at date: Date) -> Double {
        guard isPlaying, let line = activeLine else { return 0.0 }
        let elapsedSinceAnchor = max(0.0, date.timeIntervalSince(playbackAnchorDate))
        let effectivePos = playbackAnchorPosition + elapsedSinceAnchor + offsetSeconds
        return Self.computeLineProgress(line: line, nextTimestamp: activeLineNextTimestamp, position: effectivePos)
    }

    static func computeLineProgress(line: LyricLine, nextTimestamp: Double, position: Double) -> Double {
        let rawDuration = max(0.4, nextTimestamp - line.timestamp)
        if !line.words.isEmpty {
            return computeWordProgress(
                words: line.words,
                position: position,
                lineEnd: line.duration.map { line.timestamp + $0 } ?? nextTimestamp
            )
        }
        let effectiveDuration: Double
        if let exactDur = line.duration {
            effectiveDuration = max(0.4, exactDur)
        } else if rawDuration <= 10.0 {
            effectiveDuration = max(0.5, rawDuration * 0.90)
        } else {
            let breakCap = max(4.5, Double(max(1, line.text.count)) * 0.16)
            effectiveDuration = min(rawDuration * 0.85, breakCap)
        }
        let elapsed = max(0.0, position - line.timestamp)
        return min(1.0, max(0.0, elapsed / effectiveDuration))
    }

    private static func computeWordProgress(
        words: [WordTimestamp],
        position: Double,
        lineEnd: Double
    ) -> Double {
        let totalChars = max(1, words.reduce(0) { $0 + $1.text.count })
        var charsBefore = 0

        for (i, word) in words.enumerated() {
            let wordStart = word.timestamp
            let fallbackEnd = (i + 1 < words.count) ? words[i + 1].timestamp : lineEnd
            let wordEnd = word.duration.map { wordStart + $0 } ?? fallbackEnd
            let wordChars = word.text.count

            if position < wordStart {
                return Double(charsBefore) / Double(totalChars)
            } else if position < wordEnd {
                let wordDur = max(0.04, wordEnd - wordStart)
                let frac = min(1.0, max(0.0, (position - wordStart) / wordDur))
                return (Double(charsBefore) + Double(wordChars) * frac) / Double(totalChars)
            }
            charsBefore += wordChars
        }
        return 1.0
    }
}
