import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state: LyricsState
    private let spotifyMonitor: SpotifyMonitor
    private let lyricsFetcher: LyricsFetcher
    private let lyricsRetryDelays: [Duration]
    private let lyricsTranslator: LyricsTranslator
    private let colorExtractor: AlbumArtColorExtractor
    private let appUpdater = AppUpdaterModel()
    private let audioSyncManager: AudioSyncManager
    private let customLyricsStore: CustomLyricsStore
    private var overlayController: OverlayWindowController?
    private var settingsController: SettingsWindowController?
    private var lyricTimingEditorController: LyricTimingEditorWindowController?
    private var lastLoadedTrack: TrackInfo?
    private var lastFetchedLines: [LyricLine] = []

    private var statusItem: NSStatusItem?
    private var trackMenuItem: NSMenuItem?
    private var playPauseMenuItem: NSMenuItem?
    private var toggleMenuItem: NSMenuItem?
    private var offsetMenuItem: NSMenuItem?
    private var hoverModeItems: [HoverMode: NSMenuItem] = [:]

    private var lastFetchedTrackId: String?
    private(set) var fetchTask: Task<Void, Never>?
    private var translateTask: Task<Void, Never>?
    private var colorTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    /// The last lyrics retry delay repeats until lyrics load or the track changes.
    init(
        state: LyricsState? = nil,
        spotifyMonitor: SpotifyMonitor? = nil,
        lyricsFetcher: LyricsFetcher = LyricsFetcher(),
        lyricsTranslator: LyricsTranslator = LyricsTranslator(),
        colorExtractor: AlbumArtColorExtractor = AlbumArtColorExtractor(),
        audioSyncManager: AudioSyncManager? = nil,
        lyricsRetryDelays: [Duration] = [.seconds(5), .seconds(15), .seconds(30)],
        audioSyncCache: AudioSyncedLyricsCache = .default,
        customLyricsStore: CustomLyricsStore = .default
    ) {
        let resolvedState = state ?? LyricsState()
        self.state = resolvedState
        self.spotifyMonitor = spotifyMonitor ?? SpotifyMonitor()
        self.lyricsFetcher = lyricsFetcher
        self.lyricsRetryDelays = lyricsRetryDelays
        self.lyricsTranslator = lyricsTranslator
        self.colorExtractor = colorExtractor
        self.audioSyncManager = audioSyncManager ?? AudioSyncManager(state: resolvedState, cache: audioSyncCache)
        self.customLyricsStore = customLyricsStore
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        URLCache.shared = URLCache(memoryCapacity: 2 * 1024 * 1024, diskCapacity: 10 * 1024 * 1024)
        NSApp.setActivationPolicy(.accessory)

        setupStatusBarMenu()
        overlayController = OverlayWindowController(state: state)
        settingsController = SettingsWindowController(
            state: state,
            cacheRemover: OfflineCacheRemover(fetcher: lyricsFetcher, translator: lyricsTranslator),
            appUpdater: appUpdater,
            diagnostics: audioSyncManager.diagnostics,
            onOpenLyricTimingEditor: { [weak self] in
                self?.openLyricTimingEditor()
            }
        )
        lyricTimingEditorController = LyricTimingEditorWindowController(
            state: state,
            customLyricsStore: customLyricsStore,
            onSeek: { [weak self] trackId, seconds in
                self?.spotifyMonitor.sendCommand(.seek(seconds), expectedTrackId: trackId)
            },
            onTogglePlayPause: { [weak self] trackId in
                self?.spotifyMonitor.sendCommand(.playPause, expectedTrackId: trackId)
            },
            onSelectSource: { [weak self] track, source in
                self?.selectLyricSource(source, for: track)
            },
            onSaveCustom: { [weak self] track, lines in
                try self?.saveCustomLyrics(lines, for: track)
            },
            onDeleteCustom: { [weak self] track in
                self?.deleteCustomLyrics(for: track)
            }
        )

        startPlaybackMonitoring()
    }

    func startPlaybackMonitoring() {
        cancellables.removeAll()
        spotifyMonitor.onUpdate = { [weak self] snapshot in
            self?.handlePlaybackUpdate(snapshot)
        }
        spotifyMonitor.start(
            lowCPUMode: state.lowCPUMode,
            browserMusicEnabled: state.browserMusicEnabled,
            browserYouTubeVideosEnabled: state.browserYouTubeVideosEnabled
        )

        state.$lowCPUMode
            .receive(on: RunLoop.main)
            .sink { [weak self] lowCPU in
                self?.spotifyMonitor.setLowCPUMode(lowCPU)
            }
            .store(in: &cancellables)

        state.$browserMusicEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                guard let self else { return }
                self.spotifyMonitor.setBrowserMusicEnabled(enabled)
                if !enabled, self.lastFetchedTrackId?.hasPrefix("browser:") == true {
                    self.clearActivePlayback()
                }
            }
            .store(in: &cancellables)

        state.$browserYouTubeVideosEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                self?.spotifyMonitor.setBrowserYouTubeVideosEnabled(enabled)
            }
            .store(in: &cancellables)

        state.$trackSummary
            .receive(on: RunLoop.main)
            .sink { [weak self] summary in
                self?.trackMenuItem?.title = summary
            }
            .store(in: &cancellables)

        state.$isPlaying
            .receive(on: RunLoop.main)
            .sink { [weak self] isPlaying in
                self?.playPauseMenuItem?.title = isPlaying ? "Pause" : "Play"
            }
            .store(in: &cancellables)

        state.$hoverMode
            .receive(on: RunLoop.main)
            .sink { [weak self] mode in
                self?.syncHoverModeMenu(mode)
            }
            .store(in: &cancellables)

        state.$offsetSeconds
            .receive(on: RunLoop.main)
            .sink { [weak self] offset in
                let sign = offset > 0 ? "+" : ""
                self?.offsetMenuItem?.title = String(format: "Sync Offset: %@%.1fs", sign, offset)
            }
            .store(in: &cancellables)

        state.$translateLyrics
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] enabled in
                if enabled {
                    self?.translateCurrentTrack()
                } else {
                    self?.translateTask?.cancel()
                }
            }
            .store(in: &cancellables)

        state.$translationLanguage
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.state.translateLyrics else { return }
                self.translateCurrentTrack()
            }
            .store(in: &cancellables)

        state.onResyncCurrentTrack = { [weak self] in
            self?.resyncCurrentTrackIfAutomatic()
        }

        state.$audioSyncEngine
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.restartAudioSyncForCurrentTrack()
            }
            .store(in: &cancellables)

        state.$whisperModelPath
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                guard let self, self.state.audioSyncEngine == .whisper else { return }
                self.restartAudioSyncForCurrentTrack()
            }
            .store(in: &cancellables)
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopPlaybackMonitoring()
    }

    func stopPlaybackMonitoring() {
        cancellables.removeAll()
        audioSyncManager.stop()
        spotifyMonitor.stop()
        fetchTask?.cancel()
        translateTask?.cancel()
        colorTask?.cancel()
    }

    private func setupStatusBarMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "BarTune")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        let trackItem = NSMenuItem(title: "Not Playing", action: nil, keyEquivalent: "")
        trackItem.isEnabled = false
        menu.addItem(trackItem)
        self.trackMenuItem = trackItem

        let playPauseItem = NSMenuItem(title: "Play", action: #selector(togglePlayPause), keyEquivalent: "")
        playPauseItem.target = self
        menu.addItem(playPauseItem)
        self.playPauseMenuItem = playPauseItem

        let nextItem = NSMenuItem(title: "Next Track", action: #selector(nextTrack), keyEquivalent: "")
        nextItem.target = self
        menu.addItem(nextItem)

        let prevItem = NSMenuItem(title: "Previous Track", action: #selector(previousTrack), keyEquivalent: "")
        prevItem.target = self
        menu.addItem(prevItem)

        menu.addItem(.separator())

        let toggleItem = NSMenuItem(title: "Show Lyrics", action: #selector(toggleLyrics), keyEquivalent: "l")
        toggleItem.target = self
        toggleItem.state = .on
        menu.addItem(toggleItem)
        self.toggleMenuItem = toggleItem

        let hoverMenuItem = NSMenuItem(title: "Hover Mode", action: nil, keyEquivalent: "")
        let hoverSubmenu = NSMenu()
        for mode in HoverMode.allCases {
            let modeItem = NSMenuItem(title: mode.title, action: #selector(selectHoverMode(_:)), keyEquivalent: "")
            modeItem.target = self
            modeItem.representedObject = mode.rawValue
            modeItem.state = (mode == state.hoverMode) ? .on : .off
            hoverSubmenu.addItem(modeItem)
            hoverModeItems[mode] = modeItem
        }
        hoverMenuItem.submenu = hoverSubmenu
        menu.addItem(hoverMenuItem)

        menu.addItem(.separator())

        let offsetHeader = NSMenuItem(title: "Sync Offset: 0.0s", action: nil, keyEquivalent: "")
        offsetHeader.isEnabled = false
        menu.addItem(offsetHeader)
        self.offsetMenuItem = offsetHeader

        let earlierItem = NSMenuItem(title: "Lyrics Earlier (+0.5s)", action: #selector(nudgeEarlier), keyEquivalent: "")
        earlierItem.target = self
        menu.addItem(earlierItem)

        let laterItem = NSMenuItem(title: "Lyrics Later (-0.5s)", action: #selector(nudgeLater), keyEquivalent: "")
        laterItem.target = self
        menu.addItem(laterItem)

        let resetItem = NSMenuItem(title: "Reset Offset", action: #selector(resetOffset), keyEquivalent: "")
        resetItem.target = self
        menu.addItem(resetItem)

        let editTimingItem = NSMenuItem(title: "Edit Lyric Timing…", action: #selector(openLyricTimingEditor), keyEquivalent: "")
        editTimingItem.target = self
        menu.addItem(editTimingItem)

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let quitItem = NSMenuItem(title: "Quit BarTune", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        item.menu = menu
        self.statusItem = item
    }

    private func syncHoverModeMenu(_ active: HoverMode) {
        for (mode, item) in hoverModeItems {
            item.state = (mode == active) ? .on : .off
        }
    }

    func waitForPendingFetch() async {
        await fetchTask?.value
    }

    private func clearActivePlayback() {
        if lastFetchedTrackId != nil {
            lastFetchedTrackId = nil
            lastLoadedTrack = nil
            lastFetchedLines = []
            fetchTask?.cancel()
            translateTask?.cancel()
            colorTask?.cancel()
            audioSyncManager.stop()
            state.audioSyncStatus = .idle
            state.setTrack(nil, lyrics: [])
        }
        state.updatePlayback(isPlaying: false, position: 0)
    }

    func handlePlaybackUpdate(_ snapshot: PlaybackSnapshot) {
        let activeTrack = snapshot.track.flatMap { track in
            (track.id.hasPrefix("browser:") && !state.browserMusicEnabled) ? nil : track
        }
        guard snapshot.isRunning, let track = activeTrack else {
            clearActivePlayback()
            return
        }

        if track.id != lastFetchedTrackId {
            lastFetchedTrackId = track.id
            lastLoadedTrack = track
            lastFetchedLines = []
            fetchTask?.cancel()
            translateTask?.cancel()
            colorTask?.cancel()
            audioSyncManager.stop()
            state.audioSyncStatus = .idle
            state.setTrack(track, lyrics: [])

            fetchTask = Task { [weak self] in
                await self?.loadLyrics(for: track)
            }

            colorTask = Task { [weak self] in
                guard let self else { return }
                let colors = await self.colorExtractor.extractColors(from: track.artworkURL)
                guard !Task.isCancelled,
                      self.lastFetchedTrackId == track.id
                else { return }
                self.state.albumColors = colors
            }
        } else if track.sourceBundleId != lastLoadedTrack?.sourceBundleId {
            lastLoadedTrack = track
            audioSyncManager.updateSourceBundle(for: track)
        }

        state.updatePlayback(
            isPlaying: snapshot.isPlaying,
            position: snapshot.position,
            playbackRate: snapshot.playbackRate
        )
        audioSyncManager.handlePlaybackStateChanged(isPlaying: snapshot.isPlaying, position: snapshot.position)
    }

    private func loadLyrics(for track: TrackInfo) async {
        // Apply Custom lyrics immediately when selected, without waiting for network fetch.
        if state.lyricSourceChoice(for: track.id) == .custom,
           customLyricsStore.exists(trackId: track.id) {
            let resolvedTrack = lastLoadedTrack ?? track
            applyResolvedLyricSource(for: resolvedTrack, fetchedLines: [])
            if let lookup = await lyricsFetcher.lookupLyrics(for: track),
               !Task.isCancelled,
               lastFetchedTrackId == track.id {
                lastFetchedLines = lookup
                if state.lyricSourceChoice(for: track.id) != .custom {
                    applyResolvedLyricSource(for: lastLoadedTrack ?? track, fetchedLines: lookup)
                }
            }
            return
        }

        var retries = 0
        while true {
            let lookup = await lyricsFetcher.lookupLyrics(for: track)
            guard !Task.isCancelled,
                  lastFetchedTrackId == track.id,
                  !(track.id.hasPrefix("browser:") && !state.browserMusicEnabled)
            else { return }
            guard let lyrics = lookup else {
                // A provider failed transiently (e.g. offline), so retry while this track stays current.
                if retries == 0 {
                    // Meanwhile show a cached audio sync record, as a confirmed miss would.
                    let resolvedTrack = lastLoadedTrack ?? track
                    if case .useAutomatic = resolvedAction(for: resolvedTrack, fetchedLines: []) {
                        audioSyncManager.handleTrackLoaded(track: resolvedTrack, rawLines: [])
                    }
                }
                let delay = lyricsRetryDelays[min(retries, lyricsRetryDelays.count - 1)]
                retries += 1
                do {
                    try await Task.sleep(for: delay)
                } catch {
                    return
                }
                guard lastFetchedTrackId == track.id else { return }
                continue
            }
            lastFetchedLines = lyrics
            let resolvedTrack = lastLoadedTrack ?? track
            applyResolvedLyricSource(for: resolvedTrack, fetchedLines: lyrics)
            return
        }
    }

    private func resolvedAction(for track: TrackInfo, fetchedLines: [LyricLine]) -> ResolvedLyricAction {
        let customLines = customLyricsStore.load(trackId: track.id)?.lines
        return LyricSourceResolver.resolve(
            choice: state.lyricSourceChoice(for: track.id),
            customLines: customLines,
            fetchedLines: fetchedLines,
            audioSyncEngine: state.audioSyncEngine
        )
    }

    private func applyResolvedLyricSource(for track: TrackInfo, fetchedLines: [LyricLine]) {
        switch resolvedAction(for: track, fetchedLines: fetchedLines) {
        case let .useDefault(lines):
            state.setTrack(track, lyrics: lines)
            audioSyncManager.stop()
            state.audioSyncStatus = .idle
            state.refreshActiveLineForCurrentPosition()
        case let .useCustom(lines):
            state.setTrack(track, lyrics: lines)
            audioSyncManager.stop()
            state.audioSyncStatus = .idle
            state.refreshActiveLineForCurrentPosition()
        case let .useAutomatic(lines):
            state.setTrack(track, lyrics: lines)
            audioSyncManager.handleTrackLoaded(track: track, rawLines: lines)
            state.refreshActiveLineForCurrentPosition()
        }
        if state.translateLyrics, !state.rawLyricLines.isEmpty {
            translateCurrentTrack()
        }
    }

    func selectLyricSource(_ source: TrackLyricSource, for track: TrackInfo) {
        state.setLyricSourceChoice(source, for: track.id)
        guard lastLoadedTrack?.id == track.id else { return }
        applyResolvedLyricSource(for: track, fetchedLines: lastFetchedLines)
    }

    func saveCustomLyrics(_ lines: [LyricLine], for track: TrackInfo) throws {
        guard !lines.isEmpty else {
            throw CustomLyricsStoreError.emptyLyrics
        }
        let record = CustomLyricsRecord(
            trackId: track.id,
            title: track.title,
            artist: track.artist,
            savedAt: Date(),
            lines: lines
        )
        try customLyricsStore.save(record)
        state.setLyricSourceChoice(.custom, for: track.id)
        guard lastLoadedTrack?.id == track.id else { return }
        applyResolvedLyricSource(for: track, fetchedLines: lastFetchedLines)
    }

    func deleteCustomLyrics(for track: TrackInfo) {
        customLyricsStore.remove(trackId: track.id)
        if state.lyricSourceChoice(for: track.id) == .custom {
            state.setLyricSourceChoice(nil, for: track.id)
        }
        guard lastLoadedTrack?.id == track.id else { return }
        applyResolvedLyricSource(for: track, fetchedLines: lastFetchedLines)
    }

    private func resyncCurrentTrackIfAutomatic() {
        guard let track = lastLoadedTrack else { return }
        guard case .useAutomatic = resolvedAction(for: track, fetchedLines: lastFetchedLines) else {
            audioSyncManager.stop()
            state.audioSyncStatus = .idle
            return
        }
        audioSyncManager.resyncCurrentTrack()
    }

    private func restartAudioSyncForCurrentTrack() {
        guard let track = lastLoadedTrack else {
            audioSyncManager.stop()
            state.audioSyncStatus = .idle
            return
        }
        switch resolvedAction(for: track, fetchedLines: lastFetchedLines) {
        case let .useAutomatic(lines):
            guard !lines.isEmpty else {
                audioSyncManager.stop()
                state.audioSyncStatus = .idle
                return
            }
            audioSyncManager.handleTrackLoaded(track: track, rawLines: lines)
        case .useDefault, .useCustom:
            audioSyncManager.stop()
            state.audioSyncStatus = .idle
        }
    }

    private func translateCurrentTrack() {
        translateTask?.cancel()
        guard let trackId = lastFetchedTrackId else { return }
        let lines = state.rawLyricLines
        guard !lines.isEmpty else { return }
        let targetLang = state.translationLanguage

        translateTask = Task { [weak self] in
            guard let self else { return }
            let translated = await self.lyricsTranslator.translate(
                lines: lines,
                trackId: trackId,
                targetLanguage: targetLang
            )
            guard !Task.isCancelled,
                  self.lastFetchedTrackId == trackId,
                  self.state.translationLanguage == targetLang,
                  !(trackId.hasPrefix("browser:") && !self.state.browserMusicEnabled)
            else { return }
            guard self.state.setTranslatedLines(translated, sourceLines: lines) else {
                self.translateCurrentTrack()
                return
            }
        }
    }

    @objc private func togglePlayPause() {
        spotifyMonitor.sendCommand(.playPause)
    }

    @objc private func nextTrack() {
        spotifyMonitor.sendCommand(.nextTrack)
    }

    @objc private func previousTrack() {
        spotifyMonitor.sendCommand(.previousTrack)
    }

    @objc private func toggleLyrics() {
        state.isEnabled.toggle()
        toggleMenuItem?.state = state.isEnabled ? .on : .off
    }

    @objc private func selectHoverMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = HoverMode(rawValue: raw) else { return }
        state.hoverMode = mode
    }

    @objc private func nudgeEarlier() {
        state.offsetSeconds += 0.5
    }

    @objc private func nudgeLater() {
        state.offsetSeconds -= 0.5
    }

    @objc private func resetOffset() {
        state.offsetSeconds = 0.0
    }

    @objc private func openLyricTimingEditor() {
        lyricTimingEditorController?.show()
    }

    @objc private func openSettings() {
        settingsController?.show()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
