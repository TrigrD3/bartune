import SwiftUI
import AppKit

private enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case appearance
    case visualizer
    case lyricsSync
    case cache

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .appearance: return "Appearance"
        case .visualizer: return "Visualizer"
        case .lyricsSync: return "Lyrics & Sync"
        case .cache: return "Offline Cache"
        }
    }

    var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .appearance: return "paintbrush"
        case .visualizer: return "waveform"
        case .lyricsSync: return "music.note.list"
        case .cache: return "internaldrive"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var state: LyricsState
    @State private var selectedTab: SettingsTab = .general
    @State private var cachedSongCount: Int = 0
    @State private var cachedBytes: Int64 = 0

    var body: some View {
        HStack(spacing: 0) {
            List(SettingsTab.allCases, selection: $selectedTab) { tab in
                Label(tab.title, systemImage: tab.systemImage)
                    .tag(tab)
            }
            .listStyle(.sidebar)
            .frame(width: 168)

            Divider()

            Group {
                switch selectedTab {
                case .general:
                    generalTab
                case .appearance:
                    appearanceTab
                case .visualizer:
                    visualizerTab
                case .lyricsSync:
                    lyricsSyncTab
                case .cache:
                    cacheTab
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 580, height: 440)
    }

    private var generalTab: some View {
        Form {
            Section("Hover Behavior") {
                Picker("When hovering left menu bar", selection: $state.hoverMode) {
                    ForEach(HoverMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                Text(state.hoverMode.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if state.hoverMode == .spotlight {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Spotlight Width")
                            Spacer()
                            Text("\(Int(state.spotlightWidth)) pt")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $state.spotlightWidth, in: 36...180, step: 4)
                    }
                }
            }

            Section("Media Sources") {
                Toggle("Browser Music (YouTube Music, etc.)", isOn: $state.browserMusicEnabled)
                Text(
                    "Reads playback from Chrome, Arc, Brave, Edge, or Safari when Spotify and Apple Music are idle. "
                        + "Requires \"Allow JavaScript from Apple Events\" in your browser."
                )
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Launch BarTune at Login", isOn: $state.launchAtLogin)
            }
        }
        .formStyle(.grouped)
    }

    private var appearanceTab: some View {
        Form {
            Section("Color Theme") {
                Picker("Theme", selection: $state.themeMode) {
                    ForEach(ThemeMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)

                HStack(spacing: 8) {
                    Text(state.themeMode.description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if let colors = state.albumColors {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(Color(nsColor: colors.accentNSColor))
                                .frame(width: 12, height: 12)
                            Circle()
                                .fill(Color(nsColor: colors.backdropNSColor))
                                .frame(width: 12, height: 12)
                        }
                        .help("Current album colors")
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Background Opacity")
                        Spacer()
                        Text("\(Int(state.backgroundOpacity * 100))%")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $state.backgroundOpacity, in: 0.70...1.0, step: 0.02)
                }
            }

            Section("Typography & Effects") {
                Picker("Font", selection: $state.fontOption) {
                    ForEach(FontOption.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }

                Picker("Weight", selection: $state.fontWeight) {
                    ForEach(FontWeightOption.allCases) { weight in
                        Text(weight.title).tag(weight)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Font Size")
                        Spacer()
                        Text(String(format: "%.1f pt", state.fontSize))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $state.fontSize, in: 11...15, step: 0.5)
                }

                Toggle("Karaoke Sweep Highlight", isOn: $state.karaokeAnimationEnabled)
            }
        }
        .formStyle(.grouped)
    }

    private var visualizerTab: some View {
        Form {
            Section("Preview") {
                VisualizerPreviewStrip(
                    state: state,
                    isAnimating: selectedTab == .visualizer && state.animateVisualizer
                )
                .padding(.vertical, 4)
            }

            Section("Visualizer") {
                Toggle("Show Visualizer", isOn: $state.showEqualizer)

                if state.showEqualizer {
                    Toggle("Animate Visualizer", isOn: $state.animateVisualizer)

                    Picker("Style", selection: $state.visualizerStyle) {
                        ForEach(VisualizerStyle.allCases) { style in
                            Text(style.title).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Visualizer Width")
                            Spacer()
                            Text("\(Int(state.visualizerWidth)) pt")
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $state.visualizerWidth, in: 12...44, step: 2)
                    }
                }

                Text("Lightweight animated indicator (no macOS System Audio Recording permission required).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var lyricsSyncTab: some View {
        Form {
            Section("Romanization") {
                Toggle("Japanese → Romaji", isOn: $state.romanizeJapanese)
                Toggle("Korean → Romanized", isOn: $state.romanizeKorean)
                Toggle("Chinese → Pinyin", isOn: $state.romanizeChinese)
            }

            Section("Performance & Sync") {
                Picker("Karaoke Precision", selection: $state.lowCPUMode) {
                    Text("Low CPU (Standard)").tag(true)
                    Text("High Precision (30fps)").tag(false)
                }
                .pickerStyle(.segmented)

                Text(state.lowCPUMode
                     ? "Lightweight karaoke sweep for lower CPU usage (event-driven sync is always active)."
                     : "30fps karaoke sweep for smoother word-by-word highlighting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    Text("Timing Offset")
                    Spacer()
                    let sign = state.offsetSeconds > 0 ? "+" : ""
                    Text(String(format: "%@%.1fs", sign, state.offsetSeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                    Stepper("", value: $state.offsetSeconds, in: -5.0...5.0, step: 0.2)
                        .labelsHidden()
                    Button("Reset") {
                        state.offsetSeconds = 0.0
                    }
                    .disabled(abs(state.offsetSeconds) < 0.01)
                }

                Text("Timing offsets are saved automatically per track.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var cacheTab: some View {
        Form {
            Section("Offline Lyrics Cache") {
                HStack {
                    Text("Cached Songs")
                    Spacer()
                    Text(cachedCountLabel)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Storage Used")
                    Spacer()
                    Text(formattedCacheSize)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                Picker("Cache Limit", selection: $state.lyricsCacheLimit) {
                    ForEach(LyricsCacheLimit.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .onChange(of: state.lyricsCacheLimit) { _ in
                    refreshCacheStats()
                }

                HStack {
                    Button("Reveal in Finder") {
                        let dir = LyricsDiskCache.default.directory
                        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(dir)
                    }
                    Spacer()
                    Button("Refresh") {
                        refreshCacheStats()
                    }
                    Button("Clear Cache", role: .destructive) {
                        LyricsDiskCache.default.clear()
                        refreshCacheStats()
                    }
                    .disabled(cachedSongCount == 0)
                }

                Text(cacheFooterText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshCacheStats()
        }
    }

    private var cachedCountLabel: String {
        if state.lyricsCacheLimit == .unlimited {
            return "\(cachedSongCount)"
        }
        return "\(cachedSongCount) / \(state.lyricsCacheLimit.rawValue)"
    }

    private var cacheFooterText: String {
        if state.lyricsCacheLimit == .unlimited {
            return "Fetched lyrics are stored locally with no limit so repeat plays load instantly and work offline."
        }
        return "Fetched lyrics are stored locally so repeat plays load instantly and work offline. "
            + "Oldest entries are pruned automatically once the \(state.lyricsCacheLimit.title) limit is reached."
    }

    private var formattedCacheSize: String {
        guard cachedBytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: cachedBytes, countStyle: .file)
    }

    private func refreshCacheStats() {
        let stats = LyricsDiskCache.default.stats()
        cachedSongCount = stats.count
        cachedBytes = stats.bytes
    }
}

private struct VisualizerPreviewStrip: View {
    @ObservedObject var state: LyricsState
    let isAnimating: Bool

    private var backdropColor: Color {
        if state.themeMode == .albumTint, let colors = state.albumColors {
            return Color(nsColor: colors.backdropNSColor).opacity(state.backgroundOpacity)
        }
        return Color(nsColor: .windowBackgroundColor).opacity(state.backgroundOpacity)
    }

    private var equalizerColor: Color {
        if state.themeMode != .system, let colors = state.albumColors {
            return Color(nsColor: colors.accentNSColor)
        }
        return Color.accentColor
    }

    private var textColor: Color {
        switch state.themeMode {
        case .system:
            return Color.primary
        case .albumAccent:
            if let colors = state.albumColors {
                return Color(nsColor: colors.accentNSColor)
            }
            return Color.primary
        case .albumTint:
            return Color.white
        }
    }

    private var previewText: String {
        state.currentText.isEmpty ? "Now playing in your menu bar" : state.currentText
    }

    var body: some View {
        ZStack(alignment: .leading) {
            backdropColor

            HStack(spacing: 7) {
                if state.showEqualizer {
                    EqualizerIconView(
                        isPlaying: isAnimating,
                        tint: equalizerColor,
                        lowCPUMode: true,
                        style: state.visualizerStyle,
                        width: state.visualizerWidth
                    )
                }

                Text(previewText)
                    .font(state.fontOption.font(size: state.fontSize, weight: state.fontWeight))
                    .foregroundStyle(textColor)
                    .lineLimit(1)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .animation(.easeInOut(duration: 0.2), value: state.showEqualizer)
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let state: LyricsState
    private var window: NSWindow?

    init(state: LyricsState) {
        self.state = state
        super.init()
    }

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(state: state))
        let win = NSWindow(contentViewController: hosting)
        win.title = "BarTune Settings"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win
    }

    func windowWillClose(_ notification: Notification) {
        window?.contentViewController = nil
        window = nil
    }
}
