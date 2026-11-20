import SwiftUI
import AppKit

struct SettingsView: View {
    @ObservedObject var state: LyricsState

    var body: some View {
        TabView {
            generalTab
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            appearanceTab
                .tabItem {
                    Label("Appearance", systemImage: "paintbrush")
                }

            visualizerTab
                .tabItem {
                    Label("Visualizer", systemImage: "waveform")
                }

            lyricsSyncTab
                .tabItem {
                    Label("Lyrics & Sync", systemImage: "music.note.list")
                }
        }
        .frame(width: 470, height: 430)
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
            Section("Visualizer") {
                Toggle("Show Visualizer", isOn: $state.showEqualizer)

                if state.showEqualizer {
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
            }
        }
        .formStyle(.grouped)
    }
}

@MainActor
final class SettingsWindowController {
    private let state: LyricsState
    private var window: NSWindow?

    init(state: LyricsState) {
        self.state = state
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
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win
    }
}
