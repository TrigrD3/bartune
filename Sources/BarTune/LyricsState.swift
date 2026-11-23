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

    /// AppKit counterpart of `font(size:weight:)`, used to measure glyph positions with CoreText.
    func nsFont(size: Double, weight: FontWeightOption) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: weight.nsWeight)
        let design: NSFontDescriptor.SystemDesign? = switch self {
        case .sfRounded: .rounded
        case .sfSerif: .serif
        case .sfMono: .monospaced
        default: nil
        }
        if let design, let descriptor = system.fontDescriptor.withDesign(design) {
            return NSFont(descriptor: descriptor, size: size) ?? system
        }
        let customName: String? = switch self {
        case .avenirNext: "Avenir Next"
        case .helveticaNeue: "Helvetica Neue"
        case .futura: "Futura"
        case .georgia: "Georgia"
        default: nil
        }
        guard let customName else { return system }
        let descriptor = NSFontDescriptor(fontAttributes: [
            .family: customName,
            .traits: [NSFontDescriptor.TraitKey.weight: weight.nsWeight.rawValue],
        ])
        return NSFont(descriptor: descriptor, size: size) ?? system
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

    var nsWeight: NSFont.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        case .bold: return .bold
        }
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

enum LineTransitionStyle: String, CaseIterable, Identifiable {
    case subtle
    case slide
    case blurFade
    case pop
    case push
    case none

    var id: String { rawValue }

    var title: String {
        switch self {
        case .subtle: return "Subtle"
        case .slide: return "Slide"
        case .blurFade: return "Blur Fade"
        case .pop: return "Pop"
        case .push: return "Push"
        case .none: return "None"
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

enum LyricsColorPreset: String, CaseIterable, Identifiable {
    case matchTheme
    case goldenHour
    case electricCyan
    case mintNeon
    case roseQuartz
    case pureWhite
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matchTheme: return "Match Theme"
        case .goldenHour: return "Golden Hour"
        case .electricCyan: return "Electric Cyan"
        case .mintNeon: return "Mint Neon"
        case .roseQuartz: return "Rose Quartz"
        case .pureWhite: return "Pure White"
        case .custom: return "Custom Color"
        }
    }

    func resolvedColor(fallback: Color, customHex: String) -> Color {
        switch self {
        case .matchTheme: return fallback
        case .goldenHour: return Color(red: 1.0, green: 0.78, blue: 0.30)
        case .electricCyan: return Color(red: 0.20, green: 0.90, blue: 1.0)
        case .mintNeon: return Color(red: 0.30, green: 0.95, blue: 0.65)
        case .roseQuartz: return Color(red: 1.0, green: 0.48, blue: 0.68)
        case .pureWhite: return .white
        case .custom:
            return HexColorCoder.color(from: customHex) ?? fallback
        }
    }
}

enum HexColorCoder {
    static func color(from hex: String) -> Color? {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6, let value = UInt64(cleaned, radix: 16) else { return nil }
        let r = Double((value >> 16) & 0xFF) / 255.0
        let g = Double((value >> 8) & 0xFF) / 255.0
        let b = Double(value & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b)
    }

    static func hex(from color: Color) -> String {
        let nsColor = NSColor(color).usingColorSpace(.sRGB) ?? NSColor.white
        let r = Int(round(max(0, min(1, nsColor.redComponent)) * 255.0))
        let g = Int(round(max(0, min(1, nsColor.greenComponent)) * 255.0))
        let b = Int(round(max(0, min(1, nsColor.blueComponent)) * 255.0))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

enum VisualizerColorTheme: String, CaseIterable, Identifiable {
    case matchTheme
    case systemAccent
    case neonCyan
    case sunset
    case emerald
    case monochrome

    var id: String { rawValue }

    var title: String {
        switch self {
        case .matchTheme: return "Match Theme"
        case .systemAccent: return "System Accent"
        case .neonCyan: return "Neon Cyan"
        case .sunset: return "Sunset"
        case .emerald: return "Emerald"
        case .monochrome: return "Monochrome"
        }
    }

    func resolvedColor(fallback: Color) -> Color {
        switch self {
        case .matchTheme: return fallback
        case .systemAccent: return Color.accentColor
        case .neonCyan: return Color(red: 0.15, green: 0.85, blue: 0.98)
        case .sunset: return Color(red: 1.0, green: 0.48, blue: 0.32)
        case .emerald: return Color(red: 0.22, green: 0.86, blue: 0.56)
        case .monochrome: return Color.primary
        }
    }
}

enum LyricsCacheLimit: Int, CaseIterable, Identifiable {
    case songs100 = 100
    case songs250 = 250
    case songs500 = 500
    case songs1000 = 1000
    case songs2500 = 2500
    case unlimited = 0

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .songs100: return "100 songs"
        case .songs250: return "250 songs"
        case .songs500: return "500 songs"
        case .songs1000: return "1,000 songs"
        case .songs2500: return "2,500 songs"
        case .unlimited: return "Unlimited"
        }
    }
}

/// A lower cache limit waiting for the user to confirm the songs it would delete.
struct CacheLimitChange: Equatable {
    let limit: LyricsCacheLimit
    let removalCount: Int
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
        static let lineTransitionStyle = "bartune.lineTransitionStyle"
        static let lineTransitionDuration = "bartune.lineTransitionDuration"
        static let lineTransitionStartsEarly = "bartune.lineTransitionStartsEarly"
        static let wordPopEnabled = "bartune.wordPopEnabled"
        static let typingCaretEnabled = "bartune.typingCaretEnabled"
        static let visualizerColorTheme = "bartune.visualizerColorTheme"
        static let visualizerWidth = "bartune.visualizerWidth"
        static let fontSize = "bartune.fontSize"
        static let backgroundOpacity = "bartune.backgroundOpacity"
        static let themeMode = "bartune.themeMode"
        static let fontOption = "bartune.fontOption"
        static let fontWeight = "bartune.fontWeight"
        static let romanizeJapanese = "bartune.romanizeJapanese"
        static let romanizeKorean = "bartune.romanizeKorean"
        static let romanizeChinese = "bartune.romanizeChinese"
        static let translateLyrics = "bartune.translateLyrics"
        static let translationLanguage = "bartune.translationLanguage"
        static let lowCPUMode = "bartune.lowCPUMode"
        static let browserMusicEnabled = "bartune.browserMusicEnabled"
        static let browserYouTubeVideosEnabled = "bartune.browserYouTubeVideosEnabled"
        static let trackOffsets = "bartune.trackOffsets"
        static let trackLyricSources = "bartune.trackLyricSources"
        static let audioSyncEngine = "bartune.audioSyncEngine"
        static let replaceLyricsWithTranscription = "bartune.replaceLyricsWithTranscription"
        static let showSyncBadge = "bartune.showSyncBadge"
        static let lyricsColorPreset = "bartune.lyricsColorPreset"
        static let customLyricsColorHex = "bartune.customLyricsColorHex"
        static let karaokeGlowEnabled = "bartune.karaokeGlowEnabled"
        static let barCornerRadius = "bartune.barCornerRadius"
        static let showTrackTitle = "bartune.showTrackTitle"
    }

    private static let maxStoredOffsets = 500

    @Published var currentText: String = ""
    @Published var currentLineId: Int = -1
    @Published var lineProgress: Double = 0.0
    @Published var activeLine: LyricLine? = nil
    @Published var activeLineNextTimestamp: Double = 0.0
    var playbackAnchorPosition: Double = 0.0
    var playbackAnchorDate: Date = .now
    var playbackRate: Double = 1.0
    @Published var cursorLocalX: CGFloat? = nil
    @Published var trackSummary: String = "Not Playing"
    @Published private(set) var currentTrack: TrackInfo? = nil
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
    @Published var audioSyncStatus: AudioSyncStatus = .idle
    var onResyncCurrentTrack: (() -> Void)?

    // Persisted user settings
    @Published var hoverMode: HoverMode {
        didSet {
            userDefaults.set(hoverMode.rawValue, forKey: Keys.hoverMode)
            if hoverMode == .hideAll {
                cursorLocalX = nil
            }
        }
    }

    @Published var spotlightWidth: Double {
        didSet { userDefaults.set(spotlightWidth, forKey: Keys.spotlightWidth) }
    }

    @Published var themeMode: ThemeMode {
        didSet { userDefaults.set(themeMode.rawValue, forKey: Keys.themeMode) }
    }

    @Published var fontOption: FontOption {
        didSet { userDefaults.set(fontOption.rawValue, forKey: Keys.fontOption) }
    }

    @Published var fontWeight: FontWeightOption {
        didSet { userDefaults.set(fontWeight.rawValue, forKey: Keys.fontWeight) }
    }

    @Published var karaokeAnimationEnabled: Bool {
        didSet { userDefaults.set(karaokeAnimationEnabled, forKey: Keys.karaokeEnabled) }
    }

    @Published var showEqualizer: Bool {
        didSet { userDefaults.set(showEqualizer, forKey: Keys.showEqualizer) }
    }

    @Published var animateVisualizer: Bool {
        didSet { userDefaults.set(animateVisualizer, forKey: Keys.animateVisualizer) }
    }

    @Published var visualizerStyle: VisualizerStyle {
        didSet { userDefaults.set(visualizerStyle.rawValue, forKey: Keys.visualizerStyle) }
    }

    static let lineTransitionDurationRange: ClosedRange<Double> = 0.15...0.6

    @Published var lineTransitionStyle: LineTransitionStyle {
        didSet { userDefaults.set(lineTransitionStyle.rawValue, forKey: Keys.lineTransitionStyle) }
    }

    /// Seconds one line takes to replace the previous one.
    @Published var lineTransitionDuration: Double {
        didSet {
            let range = Self.lineTransitionDurationRange
            if !range.contains(lineTransitionDuration) {
                lineTransitionDuration = min(range.upperBound, max(range.lowerBound, lineTransitionDuration))
            }
            userDefaults.set(lineTransitionDuration, forKey: Keys.lineTransitionDuration)
        }
    }

    /// Changes line one transition early, so the new line is in place when its singing starts.
    @Published var lineTransitionStartsEarly: Bool {
        didSet { userDefaults.set(lineTransitionStartsEarly, forKey: Keys.lineTransitionStartsEarly) }
    }

    @Published var wordPopEnabled: Bool {
        didSet { userDefaults.set(wordPopEnabled, forKey: Keys.wordPopEnabled) }
    }

    @Published var typingCaretEnabled: Bool {
        didSet { userDefaults.set(typingCaretEnabled, forKey: Keys.typingCaretEnabled) }
    }

    private var lineTransitionLead: Double {
        lineTransitionStartsEarly && lineTransitionStyle != .none ? lineTransitionDuration : 0
    }

    @Published var visualizerColorTheme: VisualizerColorTheme {
        didSet { userDefaults.set(visualizerColorTheme.rawValue, forKey: Keys.visualizerColorTheme) }
    }

    @Published var visualizerWidth: Double {
        didSet { userDefaults.set(visualizerWidth, forKey: Keys.visualizerWidth) }
    }

    @Published var fontSize: Double {
        didSet { userDefaults.set(fontSize, forKey: Keys.fontSize) }
    }

    @Published var backgroundOpacity: Double {
        didSet { userDefaults.set(backgroundOpacity, forKey: Keys.backgroundOpacity) }
    }

    @Published var romanizeJapanese: Bool {
        didSet {
            userDefaults.set(romanizeJapanese, forKey: Keys.romanizeJapanese)
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

    @Published var translateLyrics: Bool {
        didSet {
            userDefaults.set(translateLyrics, forKey: Keys.translateLyrics)
            refreshCurrentLineText()
        }
    }

    @Published var translationLanguage: TranslationLanguage {
        didSet {
            userDefaults.set(translationLanguage.rawValue, forKey: Keys.translationLanguage)
            translatedLines = []
            translationsById = [:]
            refreshCurrentLineText()
        }
    }

    @Published var lowCPUMode: Bool {
        didSet { userDefaults.set(lowCPUMode, forKey: Keys.lowCPUMode) }
    }

    @Published var browserMusicEnabled: Bool {
        didSet { userDefaults.set(browserMusicEnabled, forKey: Keys.browserMusicEnabled) }
    }

    @Published var browserYouTubeVideosEnabled: Bool {
        didSet { userDefaults.set(browserYouTubeVideosEnabled, forKey: Keys.browserYouTubeVideosEnabled) }
    }

    @Published var audioSyncEngine: AudioSyncEngine {
        didSet { userDefaults.set(audioSyncEngine.rawValue, forKey: Keys.audioSyncEngine) }
    }

    @Published var replaceLyricsWithTranscription: Bool {
        didSet { userDefaults.set(replaceLyricsWithTranscription, forKey: Keys.replaceLyricsWithTranscription) }
    }

    @Published var showSyncBadge: Bool {
        didSet { userDefaults.set(showSyncBadge, forKey: Keys.showSyncBadge) }
    }

    @Published var lyricsColorPreset: LyricsColorPreset {
        didSet { userDefaults.set(lyricsColorPreset.rawValue, forKey: Keys.lyricsColorPreset) }
    }

    @Published var customLyricsColorHex: String {
        didSet { userDefaults.set(customLyricsColorHex, forKey: Keys.customLyricsColorHex) }
    }

    @Published var karaokeGlowEnabled: Bool {
        didSet { userDefaults.set(karaokeGlowEnabled, forKey: Keys.karaokeGlowEnabled) }
    }

    @Published var barCornerRadius: Double {
        didSet { userDefaults.set(barCornerRadius, forKey: Keys.barCornerRadius) }
    }

    @Published var showTrackTitle: Bool {
        didSet { userDefaults.set(showTrackTitle, forKey: Keys.showTrackTitle) }
    }

    @Published var lyricsCacheLimit: LyricsCacheLimit {
        didSet { userDefaults.set(lyricsCacheLimit.rawValue, forKey: LyricsDiskCache.limitDefaultsKey) }
    }

    @Published private(set) var pendingCacheLimit: CacheLimitChange?
    private var cacheLimitRequestID = 0

    /// Applies a limit that deletes nothing; a limit below the cached song count waits in `pendingCacheLimit`.
    func requestCacheLimit(_ limit: LyricsCacheLimit, cache: LyricsDiskCache = .default) async {
        // The latest selection wins over an earlier one still scanning the cache.
        cacheLimitRequestID += 1
        let requestID = cacheLimitRequestID
        pendingCacheLimit = nil
        guard limit != lyricsCacheLimit else { return }
        if limit != .unlimited {
            let count = await Task.detached(priority: .utility) { cache.stats().count }.value
            guard requestID == cacheLimitRequestID else { return }
            if count > limit.rawValue {
                pendingCacheLimit = CacheLimitChange(limit: limit, removalCount: count - limit.rawValue)
                return
            }
        }
        lyricsCacheLimit = limit
    }

    func cancelCacheLimitChange() {
        pendingCacheLimit = nil
    }

    func confirmCacheLimitChange(_ change: CacheLimitChange, cache: LyricsDiskCache = .default) async {
        pendingCacheLimit = nil
        let requestID = cacheLimitRequestID
        // A song saved while the alert was open changes how many the prune removes, so ask again.
        let count = await Task.detached(priority: .utility) { cache.stats().count }.value
        guard requestID == cacheLimitRequestID else { return }
        let removalCount = count - change.limit.rawValue
        if removalCount > 0, removalCount != change.removalCount {
            pendingCacheLimit = CacheLimitChange(limit: change.limit, removalCount: removalCount)
            return
        }
        lyricsCacheLimit = change.limit
        await Task.detached(priority: .utility) { cache.prune(to: change.limit.rawValue) }.value
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
    private var rawLinesAreSortedByTimestamp: Bool = true
    private var romanizedLines: [LyricLine] = []
    private var koreanRomanizedLines: [LyricLine] = []
    private var chineseRomanizedLines: [LyricLine] = []
    private struct TranslationEntry {
        let sourceText: String
        let translatedText: String
    }

    private var translatedLines: [LyricLine] = []
    private var translationsById: [Int: TranslationEntry] = [:]
    private var isJapaneseSong: Bool = false
    private var isKoreanSong: Bool = false
    private var isChineseSong: Bool = false
    private var currentTrackId: String?
    private var trackOffsets: [String: Double] = [:]
    private var trackLyricSources: [String: String] = [:]
    private var isRestoringOffset: Bool = false
    private var isSyncingLaunchAtLogin: Bool = false

    var rawLyricLines: [LyricLine] { rawLines }

    private var activeLines: [LyricLine] {
        if translateLyrics && !translatedLines.isEmpty {
            return translatedLines
        }
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
        self.lineTransitionStyle = ud.string(forKey: Keys.lineTransitionStyle)
            .flatMap(LineTransitionStyle.init(rawValue:)) ?? .subtle
        let savedDuration = ud.object(forKey: Keys.lineTransitionDuration) as? Double ?? 0.28
        self.lineTransitionDuration = min(
            Self.lineTransitionDurationRange.upperBound,
            max(Self.lineTransitionDurationRange.lowerBound, savedDuration)
        )
        self.lineTransitionStartsEarly = ud.object(forKey: Keys.lineTransitionStartsEarly) as? Bool ?? false
        self.wordPopEnabled = ud.object(forKey: Keys.wordPopEnabled) as? Bool ?? false
        self.typingCaretEnabled = ud.object(forKey: Keys.typingCaretEnabled) as? Bool ?? false
        if let raw = ud.string(forKey: Keys.visualizerStyle), let parsed = VisualizerStyle(rawValue: raw) {
            self.visualizerStyle = parsed
        } else {
            self.visualizerStyle = .bars
        }

        if let raw = ud.string(forKey: Keys.visualizerColorTheme),
           let parsed = VisualizerColorTheme(rawValue: raw) {
            self.visualizerColorTheme = parsed
        } else {
            self.visualizerColorTheme = .matchTheme
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
        self.translateLyrics = ud.object(forKey: Keys.translateLyrics) as? Bool ?? false
        if let rawLang = ud.string(forKey: Keys.translationLanguage),
           let parsedLang = TranslationLanguage(rawValue: rawLang) {
            self.translationLanguage = parsedLang
        } else {
            self.translationLanguage = .english
        }
        self.lowCPUMode = ud.object(forKey: Keys.lowCPUMode) as? Bool ?? true
        self.browserMusicEnabled = ud.object(forKey: Keys.browserMusicEnabled) as? Bool ?? true
        self.browserYouTubeVideosEnabled = ud.object(forKey: Keys.browserYouTubeVideosEnabled) as? Bool ?? false
        if let rawEngine = ud.string(forKey: Keys.audioSyncEngine),
           let parsedEngine = AudioSyncEngine(rawValue: rawEngine) {
            self.audioSyncEngine = parsedEngine
        } else {
            self.audioSyncEngine = .off
        }
        self.replaceLyricsWithTranscription = ud.object(forKey: Keys.replaceLyricsWithTranscription) as? Bool ?? false
        self.showSyncBadge = ud.object(forKey: Keys.showSyncBadge) as? Bool ?? true
        if let rawPreset = ud.string(forKey: Keys.lyricsColorPreset),
           let parsedPreset = LyricsColorPreset(rawValue: rawPreset) {
            self.lyricsColorPreset = parsedPreset
        } else {
            self.lyricsColorPreset = .matchTheme
        }
        self.customLyricsColorHex = ud.string(forKey: Keys.customLyricsColorHex) ?? "#FFD166"
        self.karaokeGlowEnabled = ud.object(forKey: Keys.karaokeGlowEnabled) as? Bool ?? false
        self.barCornerRadius = ud.object(forKey: Keys.barCornerRadius) as? Double ?? 6.0
        self.showTrackTitle = ud.object(forKey: Keys.showTrackTitle) as? Bool ?? true
        let storedLimit = LyricsDiskCache.configuredMaxEntries(from: ud)
        self.lyricsCacheLimit = LyricsCacheLimit(rawValue: storedLimit) ?? .songs1000
        self.trackOffsets = ud.dictionary(forKey: Keys.trackOffsets) as? [String: Double] ?? [:]
        self.trackLyricSources = ud.dictionary(forKey: Keys.trackLyricSources) as? [String: String] ?? [:]

        self.isSyncingLaunchAtLogin = true
        self.launchAtLogin = (SMAppService.mainApp.status == .enabled)
        self.isSyncingLaunchAtLogin = false
    }

    func lyricSourceChoice(for trackId: String) -> TrackLyricSource? {
        trackLyricSources[trackId].flatMap(TrackLyricSource.init(rawValue:))
    }

    func setLyricSourceChoice(_ choice: TrackLyricSource?, for trackId: String) {
        if let choice {
            trackLyricSources[trackId] = choice.rawValue
            if trackLyricSources.count > Self.maxStoredOffsets,
               let victim = trackLyricSources.keys.first(where: { $0 != trackId }) {
                trackLyricSources.removeValue(forKey: victim)
            }
        } else {
            trackLyricSources.removeValue(forKey: trackId)
        }
        userDefaults.set(trackLyricSources, forKey: Keys.trackLyricSources)
    }

    /// Current playback position in track seconds without the per-track sync offset, used for manual stamping.
    func currentPlaybackPosition(at date: Date = Date()) -> Double {
        let elapsed = isPlaying ? max(0.0, date.timeIntervalSince(playbackAnchorDate)) : 0.0
        return max(0.0, playbackAnchorPosition + elapsed * playbackRate)
    }

    func refreshActiveLineForCurrentPosition(at date: Date = Date()) {
        guard isPlaying, !activeLines.isEmpty else { return }
        syncActiveLine(for: currentPlaybackPosition(at: date) + offsetSeconds, in: activeLines)
    }

    func setTrack(_ track: TrackInfo?, lyrics: [LyricLine]) {
        let previousTrackId = currentTrackId
        currentTrack = track
        currentTrackId = track?.id
        if currentTrackId != previousTrackId {
            isRestoringOffset = true
            offsetSeconds = currentTrackId.flatMap { trackOffsets[$0] } ?? 0.0
            isRestoringOffset = false
        }

        rawLines = lyrics
        rawLinesAreSortedByTimestamp = Self.areTimestampsNonDecreasing(lyrics)
        translatedLines = []
        translationsById = [:]
        clearActiveLineState()
        isJapaneseSong = JapaneseRomanizer.isJapaneseTrack(lyrics)
        isKoreanSong = KoreanRomanizer.isKoreanTrack(lyrics)
        isChineseSong = ChineseRomanizer.isChineseTrack(lyrics)
        if isJapaneseSong {
            romanizedLines = Self.romanizeLines(
                lyrics,
                using: JapaneseRomanizer.romanizeLine,
                wordSpans: JapaneseRomanizer.romanizeWordSpans
            )
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
            albumColors = nil
        }
    }

    private func clearActiveLineState() {
        if !currentText.isEmpty { currentText = "" }
        if currentLineId != -1 { currentLineId = -1 }
        if activeLine != nil { activeLine = nil }
        if activeLineNextTimestamp != 0.0 { activeLineNextTimestamp = 0.0 }
        if lineProgress != 0.0 { lineProgress = 0.0 }
    }

    /// `wordSpans` romanizes a timed line's words in context and reports the source word range merged
    /// into each output word; without it each word is romanized alone with its original timing.
    private static func romanizeLines(
        _ lyrics: [LyricLine],
        using transform: (String) -> String,
        wordSpans: (([String]) -> [JapaneseRomanizer.RomanizedWordSpan])? = nil
    ) -> [LyricLine] {
        lyrics.map { line in
            if !line.words.isEmpty {
                let romWords: [WordTimestamp] = if let wordSpans {
                    wordSpans(line.words.map(\.text)).compactMap { span in
                        guard !span.text.isEmpty else { return nil }
                        let first = line.words[span.sourceRange.lowerBound]
                        let duration: Double?
                        if span.sourceRange.lowerBound == span.sourceRange.upperBound {
                            duration = first.duration
                        } else {
                            let last = line.words[span.sourceRange.upperBound]
                            if let lastDuration = last.duration {
                                duration = max(0, last.timestamp + lastDuration - first.timestamp)
                            } else if span.sourceRange.upperBound + 1 < line.words.count {
                                duration = max(0, line.words[span.sourceRange.upperBound + 1].timestamp - first.timestamp)
                            } else {
                                duration = nil
                            }
                        }
                        return WordTimestamp(
                            timestamp: first.timestamp,
                            duration: duration,
                            text: span.text + " "
                        )
                    }
                } else {
                    line.words.map { w in
                        let text = transform(w.text)
                        return WordTimestamp(
                            timestamp: w.timestamp,
                            duration: w.duration,
                            text: text.isEmpty ? "" : text + " "
                        )
                    }
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

    @discardableResult
    func setTranslatedLines(_ lines: [LyricLine], sourceLines: [LyricLine]? = nil) -> Bool {
        if let sourceLines, !Self.translationSourceMatches(sourceLines, rawLines) {
            return false
        }
        guard !lines.isEmpty else {
            translationsById = [:]
            translatedLines = []
            if isPlaying {
                syncActiveLine(for: extrapolatedPlaybackPosition() + offsetSeconds, in: activeLines)
            } else {
                refreshCurrentLineText()
            }
            return true
        }
        guard !rawLines.isEmpty else {
            translationsById = [:]
            translatedLines = lines
            if isPlaying {
                syncActiveLine(for: extrapolatedPlaybackPosition() + offsetSeconds, in: activeLines)
            } else {
                refreshCurrentLineText()
            }
            return true
        }

        let translatedById = Dictionary(
            lines.map { ($0.id, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var entries: [Int: TranslationEntry] = [:]
        for source in rawLines {
            if let match = translatedById[source.id] {
                entries[source.id] = TranslationEntry(
                    sourceText: source.text,
                    translatedText: match.text
                )
            }
        }
        translationsById = entries
        translatedLines = Self.projectTranslatedLines(entries, onto: rawLines)
        if isPlaying {
            syncActiveLine(for: extrapolatedPlaybackPosition() + offsetSeconds, in: activeLines)
        } else {
            refreshCurrentLineText()
        }
        return true
    }

    func applyAudioSyncedLines(_ lines: [LyricLine]) {
        guard !lines.isEmpty else { return }
        rawLines = lines
        rawLinesAreSortedByTimestamp = Self.areTimestampsNonDecreasing(lines)
        hasLyrics = true
        isJapaneseSong = JapaneseRomanizer.isJapaneseTrack(lines)
        isKoreanSong = KoreanRomanizer.isKoreanTrack(lines)
        isChineseSong = ChineseRomanizer.isChineseTrack(lines)
        romanizedLines = isJapaneseSong
            ? Self.romanizeLines(
                lines,
                using: JapaneseRomanizer.romanizeLine,
                wordSpans: JapaneseRomanizer.romanizeWordSpans
            )
            : []
        koreanRomanizedLines = isKoreanSong
            ? Self.romanizeLines(lines, using: KoreanRomanizer.romanizeLine)
            : []
        chineseRomanizedLines = isChineseSong
            ? Self.romanizeLines(lines, using: ChineseRomanizer.romanizeLine)
            : []
        if !translationsById.isEmpty {
            translatedLines = Self.projectTranslatedLines(
                translationsById,
                onto: lines
            )
        }
        if isPlaying {
            syncActiveLine(for: extrapolatedPlaybackPosition() + offsetSeconds, in: activeLines)
        } else {
            refreshCurrentLineText()
        }
    }

    private static func translationSourceMatches(_ lhs: [LyricLine], _ rhs: [LyricLine]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { $0.id == $1.id && $0.text == $1.text }
    }

    /// Re-projects genuine translated text onto the latest source timestamps/durations by line ID.
    /// Falls back to the source line for display without mutating stored translations when its source text changed.
    private static func projectTranslatedLines(
        _ entries: [Int: TranslationEntry],
        onto sourceLines: [LyricLine]
    ) -> [LyricLine] {
        guard !entries.isEmpty, !sourceLines.isEmpty else { return [] }

        var retainedTranslation = false
        let projected: [LyricLine] = sourceLines.map { source in
            guard let entry = entries[source.id], entry.sourceText == source.text else {
                return source
            }
            retainedTranslation = true
            // A line the translator left unchanged (e.g. its batch failed) keeps the source line and word timing.
            guard entry.translatedText != source.text else { return source }
            return LyricLine(
                id: source.id,
                timestamp: source.timestamp,
                duration: source.duration,
                text: entry.translatedText,
                words: []
            )
        }
        return retainedTranslation ? projected : []
    }

    private func refreshCurrentLineText() {
        guard currentLineId >= 0 else { return }
        let lines = activeLines
        if let idx = lines.firstIndex(where: { $0.id == currentLineId }) {
            let line = lines[idx]
            currentText = line.text.isEmpty ? "♪" : line.text
            activeLine = line
            activeLineNextTimestamp = (idx + 1 < lines.count)
                ? lines[idx + 1].timestamp
                : (line.timestamp + 4.5)
        }
    }

    /// Position reports closer than this to the running clock are poll jitter, not seeks.
    static let clockDeadband: Double = 0.075

    func extrapolatedPlaybackPosition(at date: Date = Date()) -> Double {
        let elapsed = isPlaying ? max(0.0, date.timeIntervalSince(playbackAnchorDate)) : 0.0
        return playbackAnchorPosition + elapsed * playbackRate
    }

    /// How far ahead of the player the overlay's clock was when the player reported `reportedPosition`;
    /// nil while paused.
    func clockError(reportedPosition: Double, at date: Date) -> Double? {
        isPlaying ? extrapolatedPlaybackPosition(at: date) - reportedPosition : nil
    }

    /// `sampledAt` is when the player reported `position`, if earlier than now (a poll's midpoint):
    /// anchoring at the time the update arrives instead would leave the clock that far behind.
    func updatePlayback(isPlaying: Bool, position: Double, playbackRate: Double = 1.0, sampledAt: Date? = nil) {
        let now = sampledAt ?? Date()
        let predicted = extrapolatedPlaybackPosition(at: now)
        let keepsClock = isPlaying && self.isPlaying
            && playbackRate == self.playbackRate
            && abs(position - predicted) < Self.clockDeadband
        if self.isPlaying != isPlaying {
            self.isPlaying = isPlaying
        }
        if !keepsClock {
            playbackAnchorPosition = position
            playbackAnchorDate = now
        }
        self.playbackRate = playbackRate
        let lines = activeLines
        guard isPlaying, !lines.isEmpty else {
            clearActiveLineState()
            return
        }

        syncActiveLine(for: position + offsetSeconds, in: lines)
    }

    private static func areTimestampsNonDecreasing(_ lines: [LyricLine]) -> Bool {
        guard lines.count > 1 else { return true }
        for idx in 1..<lines.count where lines[idx].timestamp < lines[idx - 1].timestamp {
            return false
        }
        return true
    }

    private func syncActiveLine(for effectivePos: Double, in lines: [LyricLine]) {
        guard !lines.isEmpty else {
            clearActiveLineState()
            return
        }

        var matchedIndex: Int?
        let selectionPos = effectivePos + lineTransitionLead

        if rawLinesAreSortedByTimestamp {
            var lo = 0
            var hi = lines.count - 1
            while lo <= hi {
                let mid = (lo + hi) / 2
                if lines[mid].timestamp <= selectionPos {
                    matchedIndex = mid
                    lo = mid + 1
                } else {
                    hi = mid - 1
                }
            }
        } else {
            var bestTimestamp = -Double.infinity
            for (index, candidate) in lines.enumerated() where candidate.timestamp <= selectionPos {
                if candidate.timestamp >= bestTimestamp {
                    bestTimestamp = candidate.timestamp
                    matchedIndex = index
                }
            }
        }

        if let idx = matchedIndex {
            let line = lines[idx]
            let displayText = line.text.isEmpty ? "♪" : line.text
            let nextTimestamp: Double = if rawLinesAreSortedByTimestamp {
                (idx + 1 < lines.count)
                    ? lines[idx + 1].timestamp
                    : (line.timestamp + 4.5)
            } else {
                lines
                    .map(\.timestamp)
                    .filter { $0 > line.timestamp }
                    .min() ?? (line.timestamp + 4.5)
            }

            if line.id != currentLineId
                || currentText != displayText
                || activeLine != line
                || activeLineNextTimestamp != nextTimestamp {
                if currentLineId != line.id { currentLineId = line.id }
                if currentText != displayText { currentText = displayText }
                if activeLine != line { activeLine = line }
                if activeLineNextTimestamp != nextTimestamp { activeLineNextTimestamp = nextTimestamp }
            }
        } else if currentLineId != -1 || currentText != "♪" {
            if currentLineId != -1 { currentLineId = -1 }
            if currentText != "♪" { currentText = "♪" }
            if activeLine != nil { activeLine = nil }
            if activeLineNextTimestamp != 0.0 { activeLineNextTimestamp = 0.0 }
            if lineProgress != 0.0 { lineProgress = 0.0 }
        }
    }

    struct WordPop: Equatable {
        /// The popping word's span, as shares of the rendered line width.
        let start: Double
        let end: Double
        /// 0...1: rises over `attack` seconds from the word's start, then fades over `release`.
        let strength: Double
    }

    /// The word sung most recently and how strongly it pops at `position`; nil before the first word
    /// or when `boundaries` (`words.count + 1` values) don't describe the words.
    static func wordPop(
        words: [WordTimestamp],
        boundaries: [Double],
        position: Double,
        attack: Double = 0.08,
        release: Double = 0.32
    ) -> WordPop? {
        guard boundaries.count == words.count + 1,
              let index = words.lastIndex(where: { $0.timestamp <= position })
        else { return nil }
        let elapsed = position - words[index].timestamp
        let strength = elapsed < attack ? elapsed / attack : max(0, 1 - (elapsed - attack) / release)
        return WordPop(start: boundaries[index], end: boundaries[index + 1], strength: strength)
    }

    /// The word popping now on the active line, for the overlay; nil without measured word positions.
    func liveWordPop(at date: Date, font: NSFont) -> WordPop? {
        guard isPlaying, let line = activeLine, let boundaries = wordBoundaries(for: line, font: font) else { return nil }
        let elapsedSinceAnchor = max(0.0, date.timeIntervalSince(playbackAnchorDate))
        let position = playbackAnchorPosition + elapsedSinceAnchor * playbackRate + offsetSeconds
        return Self.wordPop(words: line.words, boundaries: boundaries, position: position)
    }

    /// True when no word is being sung at `position` (the typing caret blinks then).
    static func isWaitingForWord(line: LyricLine, nextTimestamp: Double, position: Double) -> Bool {
        guard !line.words.isEmpty else {
            return position < line.timestamp
                || computeLineProgress(line: line, nextTimestamp: nextTimestamp, position: position) >= 1
        }
        let lineEnd = line.duration.map { line.timestamp + $0 } ?? nextTimestamp
        for (i, word) in line.words.enumerated() {
            let fallbackEnd = (i + 1 < line.words.count) ? line.words[i + 1].timestamp : lineEnd
            let wordEnd = word.duration.map { word.timestamp + $0 } ?? fallbackEnd
            if position >= word.timestamp, position < wordEnd { return false }
        }
        return true
    }

    func liveIsWaitingForWord(at date: Date) -> Bool {
        guard isPlaying, let line = activeLine else { return true }
        let elapsedSinceAnchor = max(0.0, date.timeIntervalSince(playbackAnchorDate))
        let position = playbackAnchorPosition + elapsedSinceAnchor * playbackRate + offsetSeconds
        return Self.isWaitingForWord(line: line, nextTimestamp: activeLineNextTimestamp, position: position)
    }

    private struct BoundaryKey: Equatable {
        let line: LyricLine
        let fontName: String
        let fontSize: CGFloat
    }

    private var boundaryCache: (key: BoundaryKey, fractions: [Double]?)?

    /// `font` is the overlay's font; with it, the edge moves through measured glyph positions.
    func liveProgress(at date: Date, font: NSFont? = nil) -> Double {
        guard isPlaying, let line = activeLine else { return 0.0 }
        let elapsedSinceAnchor = max(0.0, date.timeIntervalSince(playbackAnchorDate))
        let effectivePos = playbackAnchorPosition + elapsedSinceAnchor * playbackRate + offsetSeconds
        let boundaries = font.flatMap { wordBoundaries(for: line, font: $0) }
        return Self.computeLineProgress(
            line: line,
            nextTimestamp: activeLineNextTimestamp,
            position: effectivePos,
            boundaries: boundaries
        )
    }

    private func wordBoundaries(for line: LyricLine, font: NSFont) -> [Double]? {
        guard !line.words.isEmpty else { return nil }
        let key = BoundaryKey(line: line, fontName: font.fontName, fontSize: font.pointSize)
        if let cached = boundaryCache, cached.key == key {
            return cached.fractions
        }
        let fractions = Self.wordBoundaryFractions(words: line.words, lineText: line.text, font: font)
        boundaryCache = (key, fractions)
        return fractions
    }

    /// Share of the rendered line width at each word boundary (`words.count + 1` values), measured with
    /// CoreText; nil when the words don't spell out the line text.
    static func wordBoundaryFractions(words: [WordTimestamp], lineText: String, font: NSFont) -> [Double]? {
        guard !words.isEmpty, !lineText.isEmpty else { return nil }
        let joined = words.map(\.text).joined()
        let leadingTrimLength: Int
        if joined == lineText {
            leadingTrimLength = 0
        } else if joined.trimmingCharacters(in: .whitespacesAndNewlines) == lineText {
            let trimmedRange = (joined as NSString).range(of: lineText)
            guard trimmedRange.location != NSNotFound else { return nil }
            leadingTrimLength = trimmedRange.location
        } else {
            return nil
        }
        let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: lineText, attributes: [.font: font]))
        let width = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        guard width > 0 else { return nil }
        let length = (lineText as NSString).length
        var fractions: [Double] = [0]
        var rawIndex = 0
        for word in words {
            rawIndex += (word.text as NSString).length
            let index = min(length, max(0, rawIndex - leadingTrimLength))
            let offset = Double(CTLineGetOffsetForStringIndex(ctLine, index, nil)) / width
            fractions.append(min(1, max(fractions[fractions.count - 1], offset)))
        }
        return fractions
    }

    static func computeLineProgress(
        line: LyricLine,
        nextTimestamp: Double,
        position: Double,
        boundaries: [Double]? = nil
    ) -> Double {
        let rawDuration = max(0.4, nextTimestamp - line.timestamp)
        if !line.words.isEmpty {
            return computeWordProgress(
                words: line.words,
                position: position,
                lineEnd: line.duration.map { line.timestamp + $0 } ?? nextTimestamp,
                boundaries: boundaries
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
        lineEnd: Double,
        boundaries: [Double]?
    ) -> Double {
        let totalChars = max(1, words.reduce(0) { $0 + $1.text.count })
        let measured = boundaries.flatMap { $0.count == words.count + 1 ? $0 : nil }
        var charsBefore = 0

        func edge(word index: Int, fraction: Double) -> Double {
            if let measured {
                return measured[index] + (measured[index + 1] - measured[index]) * fraction
            }
            return (Double(charsBefore) + Double(words[index].text.count) * fraction) / Double(totalChars)
        }

        for (i, word) in words.enumerated() {
            let wordStart = word.timestamp
            let fallbackEnd = (i + 1 < words.count) ? words[i + 1].timestamp : lineEnd
            let wordEnd = word.duration.map { wordStart + $0 } ?? fallbackEnd

            if position < wordStart {
                return edge(word: i, fraction: 0)
            } else if position < wordEnd {
                let wordDur = max(0.04, wordEnd - wordStart)
                let frac = min(1.0, max(0.0, (position - wordStart) / wordDur))
                return edge(word: i, fraction: frac)
            }
            charsBefore += word.text.count
        }
        return 1.0
    }
}
