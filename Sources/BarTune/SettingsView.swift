import AppKit
import ApplicationServices
import Combine
import CoreGraphics
import Darwin
import Speech
import SwiftUI
import UniformTypeIdentifiers

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
    @State private var syncedSongCount: Int = 0
    @State private var syncedBytes: Int64 = 0
    @State private var cachedSongs: [CachedSongSummary] = []
    @State private var cacheSearchQuery: String = ""
    @State private var inspectingSong: CachedSongSummary?
    @State private var songPendingDeletion: CachedSongSummary?
    @State private var showClearCacheConfirmation: Bool = false
    @State private var discoveredModels: [DiscoveredWhisperModel] = []
    @State private var whisperCLIFound: Bool = false
    @State private var isDownloadingModel: Bool = false
    @State private var modelDownloadError: String?
    @State private var selectedDownloadPreset: WhisperModelPreset = .base
    @State private var metricsTracker = ResourceMetricsTracker()
    @State private var permissions = AppPermissionsSnapshot.empty
    private let resourceTimer = Timer.publish(every: 2.0, on: .main, in: .common).autoconnect()

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

            Section("Permissions") {
                permissionRow(
                    title: "Screen & System Audio",
                    status: permissions.screenAudio,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                )
                permissionRow(
                    title: "Speech Recognition",
                    status: permissions.speechRecognition,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition"
                )
                permissionRow(
                    title: "Spotify Automation",
                    status: permissions.spotifyAutomation,
                    settingsURL: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation"
                )

                HStack {
                    Text("macOS Privacy & Security permissions used for playback tracking and audio sync.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Refresh") {
                        refreshPermissions()
                    }
                    .controlSize(.small)
                }
            }

            Section("App Performance") {
                HStack {
                    Text("CPU Usage")
                    Spacer()
                    Text(String(
                        format: "%.1f%% (avg %.1f%%)",
                        metricsTracker.latestCPUPercent,
                        metricsTracker.averageCPUPercent
                    ))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Memory Usage")
                    Spacer()
                    let currentMem = ByteCountFormatter.string(
                        fromByteCount: Int64(metricsTracker.latestMemoryBytes),
                        countStyle: .memory
                    )
                    let avgMem = ByteCountFormatter.string(
                        fromByteCount: Int64(metricsTracker.averageMemoryBytes),
                        countStyle: .memory
                    )
                    Text("\(currentMem) (avg \(avgMem))")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Averaged over \(metricsTracker.sampleCount) \(metricsTracker.sampleCount == 1 ? "sample" : "samples")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Reset Average") {
                        metricsTracker.reset()
                        refreshResourceMetrics()
                    }
                    .controlSize(.small)
                    .disabled(metricsTracker.sampleCount <= 1)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshResourceMetrics()
            refreshPermissions()
        }
        .onReceive(resourceTimer) { _ in
            if selectedTab == .general {
                refreshResourceMetrics()
            }
        }
    }

    private var appearanceTab: some View {
        Form {
            Section("Preview") {
                VisualizerPreviewStrip(
                    state: state,
                    isAnimating: selectedTab == .appearance && state.animateVisualizer
                )
                .padding(.vertical, 4)
            }

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

                Picker("Sung Text Color", selection: $state.lyricsColorPreset) {
                    ForEach(LyricsColorPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }

                if state.lyricsColorPreset == .custom {
                    ColorPicker(
                        "Custom Highlight Color",
                        selection: Binding(
                            get: { HexColorCoder.color(from: state.customLyricsColorHex) ?? .yellow },
                            set: { state.customLyricsColorHex = HexColorCoder.hex(from: $0) }
                        ),
                        supportsOpacity: false
                    )
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

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Bar Corner Radius")
                        Spacer()
                        Text("\(Int(state.barCornerRadius)) pt")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    Slider(value: $state.barCornerRadius, in: 0...12, step: 1)
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
                Toggle("Sung Text Glow", isOn: $state.karaokeGlowEnabled)
                Toggle("Show Track Title in Bar", isOn: $state.showTrackTitle)
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

                    Picker("Color", selection: $state.visualizerColorTheme) {
                        ForEach(VisualizerColorTheme.allCases) { theme in
                            Text(theme.title).tag(theme)
                        }
                    }

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
            Section("Translation") {
                Toggle("Translate Lyrics", isOn: $state.translateLyrics)

                if state.translateLyrics {
                    Picker("Target Language", selection: $state.translationLanguage) {
                        ForEach(TranslationLanguage.allCases) { lang in
                            Text(lang.title).tag(lang)
                        }
                    }
                }

                Text("Translations are cached locally in Offline Cache for instant repeat playback.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Romanization") {
                Toggle("Japanese → Romaji", isOn: $state.romanizeJapanese)
                Toggle("Korean → Romanized", isOn: $state.romanizeKorean)
                Toggle("Chinese → Pinyin", isOn: $state.romanizeChinese)
            }

            Section("Audio Karaoke Sync") {
                Picker("Sync Engine", selection: $state.audioSyncEngine) {
                    ForEach(AudioSyncEngine.allCases) { engine in
                        Text(engine.title).tag(engine)
                    }
                }
                .pickerStyle(.segmented)

                Text(state.audioSyncEngine.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if state.audioSyncEngine != .off {
                    Toggle("Show Sync Badge in Lyrics Bar", isOn: $state.showSyncBadge)

                    Toggle("Replace Lyrics with Transcribed Audio", isOn: $state.replaceLyricsWithTranscription)

                    Text(
                        "Permanently saves the words recognized from audio (e.g. actual Japanese pronunciation) into the sync cache so repeat plays load with zero recalculation."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)

                    HStack {
                        Text("Status")
                        Spacer()
                        Text(state.audioSyncStatus.label)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    HStack {
                        if case .permissionRequired = state.audioSyncStatus {
                            Button("Open Privacy Settings") {
                                if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        Spacer()
                        Button("Re-sync Current Track") {
                            state.onResyncCurrentTrack?()
                        }
                        .disabled(!state.hasLyrics)
                    }
                }

                if state.audioSyncEngine == .whisper {
                    HStack {
                        Text("whisper-cli")
                        Spacer()
                        Text(whisperCLIFound ? "Installed" : "Not found (brew install whisper-cpp)")
                            .font(.caption)
                            .foregroundStyle(whisperCLIFound ? Color.secondary : Color.orange)
                    }

                    if !discoveredModels.isEmpty {
                        Picker("Shared Model", selection: $state.whisperModelPath) {
                            Text("Auto (\(discoveredModels.first?.name ?? "None"))").tag("")
                            ForEach(discoveredModels) { model in
                                Text("\(model.name) (\(model.formattedSize) · \(model.sourceLabel))")
                                    .tag(model.path)
                            }
                        }
                    } else {
                        HStack {
                            Text("Shared Model")
                            Spacer()
                            Text("None found")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Picker("Download Model", selection: $selectedDownloadPreset) {
                        ForEach(WhisperModelPreset.allCases) { preset in
                            Text(preset.title).tag(preset)
                        }
                    }

                    HStack {
                        Button("Choose Existing…") {
                            chooseExistingWhisperModel()
                        }
                        Button("Rescan") {
                            refreshWhisperDiscovery()
                        }
                        Spacer()
                        if isDownloadingModel {
                            ProgressView()
                                .controlSize(.small)
                            Text("Downloading…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Button("Download Selected") {
                                downloadSelectedWhisperModel()
                            }
                        }
                    }

                    if let err = modelDownloadError {
                        Text(err)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }

                    Text(
                        "Automatically reuses existing GGML models from ~/.cache/whisper, ~/.cache/huggingface, and Homebrew. "
                            + "Downloads are saved to ~/.cache/whisper so other apps can share them."
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
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
        .onAppear {
            refreshWhisperDiscovery()
        }
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

                HStack {
                    Text("Audio-Synced Tracks")
                    Spacer()
                    Text("\(syncedSongCount) (\(formattedSyncedSize))")
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
                        refreshCacheStats()
                        if cachedSongCount > 0 || syncedSongCount > 0 {
                            showClearCacheConfirmation = true
                        }
                    }
                    .disabled(cachedSongCount == 0 && syncedSongCount == 0)
                }

                Text(cacheFooterText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Cached Songs (\(filteredCachedSongs.count))") {
                if cachedSongs.isEmpty {
                    Text("No cached songs yet. Songs appear here automatically as you play them.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    TextField("Filter cached songs…", text: $cacheSearchQuery)
                        .textFieldStyle(.roundedBorder)

                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(filteredCachedSongs) { song in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(song.title)
                                            .font(.callout.weight(.medium))
                                            .lineLimit(1)
                                            .truncationMode(.tail)
                                        HStack(spacing: 6) {
                                            if !song.artist.isEmpty {
                                                Text(song.artist)
                                                    .lineLimit(1)
                                                    .truncationMode(.tail)
                                            }
                                            Text("\(song.lineCount) lines")
                                            Text("·")
                                            Text(ByteCountFormatter.string(fromByteCount: song.sizeBytes, countStyle: .file))
                                        }
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    }

                                    Spacer(minLength: 4)

                                    if let engine = song.syncEngine {
                                        Label(engine.title, systemImage: "checkmark.circle.fill")
                                            .font(.caption2.weight(.medium))
                                            .foregroundStyle(.green)
                                            .padding(.horizontal, 6)
                                            .padding(.vertical, 2)
                                            .background(Capsule().fill(Color.green.opacity(0.14)))
                                    }

                                    Button {
                                        inspectingSong = song
                                    } label: {
                                        Image(systemName: "doc.text")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Inspect cached file & lyrics")

                                    Button {
                                        revealCachedSongInFinder(song)
                                    } label: {
                                        Image(systemName: "folder")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Reveal file in Finder")

                                    Button(role: .destructive) {
                                        songPendingDeletion = song
                                    } label: {
                                        Image(systemName: "trash")
                                            .font(.caption)
                                    }
                                    .buttonStyle(.borderless)
                                    .help("Remove from cache")
                                }
                                .padding(.vertical, 2)
                                Divider()
                            }
                        }
                    }
                    .frame(height: 170)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            refreshCacheStats()
        }
        .sheet(item: $inspectingSong) { song in
            CachedSongFileSheet(song: song)
        }
        .alert("Clear Offline Cache?", isPresented: $showClearCacheConfirmation) {
            Button("Clear All Cache", role: .destructive) {
                Task {
                    await Task.detached(priority: .utility) {
                        LyricsDiskCache.default.clear()
                        AudioSyncedLyricsCache.default.clear()
                    }.value
                    refreshCacheStats()
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This will permanently delete \(cachedSongCount) cached "
                    + "\(cachedSongCount == 1 ? "song" : "songs") and \(syncedSongCount) audio-synced "
                    + "\(syncedSongCount == 1 ? "track" : "tracks") from disk."
            )
        }
        .alert(
            "Remove Cached Song?",
            isPresented: Binding(
                get: { songPendingDeletion != nil },
                set: { if !$0 { songPendingDeletion = nil } }
            ),
            presenting: songPendingDeletion
        ) { song in
            Button("Remove", role: .destructive) {
                deleteCachedSong(song)
                songPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                songPendingDeletion = nil
            }
        } message: { song in
            let label = song.artist.isEmpty ? song.title : "\(song.title) — \(song.artist)"
            Text("This will permanently delete the cached lyrics and audio sync data for \"\(label)\".")
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

    private var formattedSyncedSize: String {
        guard syncedBytes > 0 else { return "0 KB" }
        return ByteCountFormatter.string(fromByteCount: syncedBytes, countStyle: .file)
    }

    private var filteredCachedSongs: [CachedSongSummary] {
        let query = cacheSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return cachedSongs }
        return cachedSongs.filter {
            $0.title.lowercased().contains(query) || $0.artist.lowercased().contains(query)
        }
    }

    private func revealCachedSongInFinder(_ song: CachedSongSummary) {
        let lyricsURL = LyricsDiskCache.default.fileURL(forCacheKey: song.cacheKey)
        let syncURL = AudioSyncedLyricsCache.default.fileURL(forCacheKey: song.cacheKey)
        var urls: [URL] = []
        if FileManager.default.fileExists(atPath: lyricsURL.path) {
            urls.append(lyricsURL)
        }
        if FileManager.default.fileExists(atPath: syncURL.path) {
            urls.append(syncURL)
        }
        if !urls.isEmpty {
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }

    private func deleteCachedSong(_ song: CachedSongSummary) {
        LyricsDiskCache.default.removeByCacheKey(song.cacheKey)
        AudioSyncedLyricsCache.default.removeByCacheKey(song.cacheKey)
        refreshCacheStats()
    }

    private func refreshCacheStats() {
        let stats = LyricsDiskCache.default.stats()
        cachedSongCount = stats.count
        cachedBytes = stats.bytes
        let syncStats = AudioSyncedLyricsCache.default.stats()
        syncedSongCount = syncStats.count
        syncedBytes = syncStats.bytes
        cachedSongs = LyricsDiskCache.default.listEntries(audioSyncCache: .default)
    }

    private func refreshWhisperDiscovery() {
        whisperCLIFound = WhisperModelLocator.locateWhisperCLI() != nil
        discoveredModels = WhisperModelLocator.discoverModels(customPath: state.whisperModelPath)
    }

    private func chooseExistingWhisperModel() {
        let panel = NSOpenPanel()
        panel.title = "Choose Existing Whisper GGML Model"
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "bin") ?? .data]
        if panel.runModal() == .OK, let url = panel.url {
            state.whisperModelPath = url.path
            refreshWhisperDiscovery()
        }
    }

    private func downloadSelectedWhisperModel() {
        let preset = selectedDownloadPreset
        isDownloadingModel = true
        modelDownloadError = nil
        Task {
            do {
                let url = try await AudioSyncManager.downloadSharedModel(preset)
                await MainActor.run {
                    isDownloadingModel = false
                    state.whisperModelPath = url.path
                    refreshWhisperDiscovery()
                }
            } catch {
                await MainActor.run {
                    isDownloadingModel = false
                    modelDownloadError = error.localizedDescription
                }
            }
        }
    }

    private func refreshResourceMetrics() {
        let metrics = AppResourceMetrics.sample()
        metricsTracker.record(cpuPercent: metrics.cpuPercent, memoryBytes: metrics.memoryBytes)
    }

    private func refreshPermissions() {
        permissions = AppPermissionsChecker.current()
    }

    private func permissionRow(title: String, status: PermissionAuthorizationState, settingsURL: String) -> some View {
        HStack(spacing: 8) {
            Text(title)
            Spacer()
            Label(status.title, systemImage: status.symbolName)
                .font(.caption.weight(.medium))
                .foregroundStyle(status.isGranted ? Color.green : Color.orange)
            if !status.isGranted {
                Button("Open") {
                    if let url = URL(string: settingsURL) {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
    }
}

enum PermissionAuthorizationState: Equatable, Sendable {
    case granted
    case notRequested
    case denied
    case targetNotRunning

    var isGranted: Bool { self == .granted }

    var title: String {
        switch self {
        case .granted: return "Granted"
        case .notRequested: return "Not Granted"
        case .denied: return "Denied"
        case .targetNotRunning: return "App Idle"
        }
    }

    var symbolName: String {
        switch self {
        case .granted: return "checkmark.circle.fill"
        case .notRequested, .targetNotRunning: return "exclamationmark.circle"
        case .denied: return "xmark.circle.fill"
        }
    }

    static func fromScreenCapture(_ granted: Bool) -> PermissionAuthorizationState {
        granted ? .granted : .notRequested
    }

    static func fromSpeechStatus(_ status: SFSpeechRecognizerAuthorizationStatus) -> PermissionAuthorizationState {
        switch status {
        case .authorized: return .granted
        case .notDetermined: return .notRequested
        case .denied, .restricted: return .denied
        @unknown default: return .notRequested
        }
    }

    static func fromAutomationStatus(_ status: OSStatus) -> PermissionAuthorizationState {
        switch status {
        case noErr:
            return .granted
        case OSStatus(errAEEventNotPermitted):
            return .denied
        case OSStatus(procNotFound):
            return .targetNotRunning
        default:
            return .notRequested
        }
    }
}

struct AppPermissionsSnapshot: Equatable, Sendable {
    let screenAudio: PermissionAuthorizationState
    let speechRecognition: PermissionAuthorizationState
    let spotifyAutomation: PermissionAuthorizationState

    static let empty = AppPermissionsSnapshot(
        screenAudio: .notRequested,
        speechRecognition: .notRequested,
        spotifyAutomation: .targetNotRunning
    )
}

private enum AppPermissionsChecker {
    static func current() -> AppPermissionsSnapshot {
        let screenAudio = PermissionAuthorizationState.fromScreenCapture(CGPreflightScreenCaptureAccess())
        let speech = PermissionAuthorizationState.fromSpeechStatus(SFSpeechRecognizer.authorizationStatus())
        let automation = checkAutomation(bundleIdentifier: "com.spotify.client")
        return AppPermissionsSnapshot(
            screenAudio: screenAudio,
            speechRecognition: speech,
            spotifyAutomation: automation
        )
    }

    private static func checkAutomation(bundleIdentifier: String) -> PermissionAuthorizationState {
        guard let target = NSAppleEventDescriptor(bundleIdentifier: bundleIdentifier).aeDesc else {
            return .notRequested
        }
        let status = AEDeterminePermissionToAutomateTarget(
            target,
            AEEventClass(typeWildCard),
            AEEventID(typeWildCard),
            false
        )
        return PermissionAuthorizationState.fromAutomationStatus(status)
    }
}

private struct CachedSongFileSheet: View {
    let song: CachedSongSummary
    @Environment(\.dismiss) private var dismiss

    private var fileURL: URL {
        LyricsDiskCache.default.fileURL(forCacheKey: song.cacheKey)
    }

    private var syncFileURL: URL {
        AudioSyncedLyricsCache.default.fileURL(forCacheKey: song.cacheKey)
    }

    private var lines: [LyricLine] {
        if let syncedData = try? Data(contentsOf: syncFileURL),
           let record = try? JSONDecoder().decode(AudioSyncedLyricsRecord.self, from: syncedData),
           !record.lines.isEmpty {
            return record.lines
        }
        return LyricsDiskCache.default.loadByCacheKey(song.cacheKey)?.lines ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(song.title)
                        .font(.headline)
                        .lineLimit(1)
                    if !song.artist.isEmpty {
                        Text(song.artist)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button("Reveal in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Lyrics file: \(fileURL.lastPathComponent)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if let engine = song.syncEngine {
                    Text("Audio-synced via \(engine.title): \(syncFileURL.lastPathComponent)")
                        .font(.caption.monospaced())
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                }
            }

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    ForEach(lines) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(formatTimestamp(line.timestamp))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 54, alignment: .leading)
                            Text(line.text.isEmpty ? "♪" : line.text)
                                .font(.callout)
                                .textSelection(.enabled)
                            Spacer(minLength: 0)
                            if !line.words.isEmpty {
                                Text("\(line.words.count)w")
                                    .font(.caption2.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 520, height: 380)
    }

    private func formatTimestamp(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let mins = Int(clamped) / 60
        let secs = clamped - Double(mins * 60)
        return String(format: "%02d:%05.2f", mins, secs)
    }
}

struct ResourceMetricsTracker: Equatable {
    private(set) var sampleCount: Int = 0
    private(set) var latestCPUPercent: Double = 0
    private(set) var latestMemoryBytes: UInt64 = 0
    private var totalCPUPercent: Double = 0
    private var totalMemoryBytes: Double = 0

    var averageCPUPercent: Double {
        guard sampleCount > 0 else { return 0 }
        return totalCPUPercent / Double(sampleCount)
    }

    var averageMemoryBytes: UInt64 {
        guard sampleCount > 0 else { return 0 }
        return UInt64((totalMemoryBytes / Double(sampleCount)).rounded())
    }

    mutating func record(cpuPercent: Double, memoryBytes: UInt64) {
        sampleCount += 1
        latestCPUPercent = cpuPercent
        latestMemoryBytes = memoryBytes
        totalCPUPercent += cpuPercent
        totalMemoryBytes += Double(memoryBytes)
    }

    mutating func reset() {
        sampleCount = 0
        latestCPUPercent = 0
        latestMemoryBytes = 0
        totalCPUPercent = 0
        totalMemoryBytes = 0
    }
}

private enum AppResourceMetrics {
    static func sample() -> (cpuPercent: Double, memoryBytes: UInt64) {
        (cpuPercent: currentCPUPercent(), memoryBytes: currentMemoryBytes())
    }

    private static func currentMemoryBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard status == KERN_SUCCESS else { return 0 }
        return info.phys_footprint
    }

    private static func currentCPUPercent() -> Double {
        var threads: thread_act_array_t?
        var threadCount: mach_msg_type_number_t = 0
        guard task_threads(mach_task_self_, &threads, &threadCount) == KERN_SUCCESS,
              let threadList = threads
        else { return 0 }

        defer {
            let size = vm_size_t(Int(threadCount) * MemoryLayout<thread_t>.size)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: threadList), size)
        }

        var totalCPU = 0.0
        for i in 0..<Int(threadCount) {
            var info = thread_basic_info()
            var count = mach_msg_type_number_t(THREAD_INFO_MAX)
            let status = withUnsafeMutablePointer(to: &info) { ptr in
                ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                    thread_info(threadList[i], thread_flavor_t(THREAD_BASIC_INFO), intPtr, &count)
                }
            }
            if status == KERN_SUCCESS && (info.flags & TH_FLAGS_IDLE) == 0 {
                totalCPU += (Double(info.cpu_usage) / Double(TH_USAGE_SCALE)) * 100.0
            }
        }
        return totalCPU
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
        let themeFallback: Color = if state.themeMode != .system, let colors = state.albumColors {
            Color(nsColor: colors.accentNSColor)
        } else {
            Color.accentColor
        }
        return state.visualizerColorTheme.resolvedColor(fallback: themeFallback)
    }

    private var textColor: Color {
        let base: Color = switch state.themeMode {
        case .system:
            Color.primary
        case .albumAccent:
            if let colors = state.albumColors {
                Color(nsColor: colors.accentNSColor)
            } else {
                Color.primary
            }
        case .albumTint:
            Color.white
        }
        return state.lyricsColorPreset.resolvedColor(fallback: base, customHex: state.customLyricsColorHex)
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
                    .shadow(
                        color: state.karaokeGlowEnabled ? textColor.opacity(0.55) : .clear,
                        radius: state.karaokeGlowEnabled ? 4 : 0
                    )

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 28)
        .clipShape(RoundedRectangle(cornerRadius: state.barCornerRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: state.barCornerRadius, style: .continuous)
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
