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
    private var overlayController: OverlayWindowController?
    private var settingsController: SettingsWindowController?
    private var lastLoadedTrack: TrackInfo?

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
        audioSyncCache: AudioSyncedLyricsCache = .default
    ) {
        let resolvedState = state ?? LyricsState()
        self.state = resolvedState
        self.spotifyMonitor = spotifyMonitor ?? SpotifyMonitor()
        self.lyricsFetcher = lyricsFetcher
        self.lyricsRetryDelays = lyricsRetryDelays
        self.lyricsTranslator = lyricsTranslator
        self.colorExtractor = colorExtractor
        self.audioSyncManager = audioSyncManager ?? AudioSyncManager(state: resolvedState, cache: audioSyncCache)
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
            appUpdater: appUpdater
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
            self?.audioSyncManager.resyncCurrentTrack()
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
                    audioSyncManager.handleTrackLoaded(track: track, rawLines: [])
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
            let resolvedTrack = lastLoadedTrack ?? track
            state.setTrack(resolvedTrack, lyrics: lyrics)
            audioSyncManager.handleTrackLoaded(track: resolvedTrack, rawLines: lyrics)
            if state.translateLyrics, !lyrics.isEmpty {
                translateCurrentTrack()
            }
            return
        }
    }

    private func restartAudioSyncForCurrentTrack() {
        guard let track = lastLoadedTrack, !state.rawLyricLines.isEmpty else {
            audioSyncManager.stop()
            state.audioSyncStatus = .idle
            return
        }
        audioSyncManager.handleTrackLoaded(track: track, rawLines: state.rawLyricLines)
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

    @objc private func openSettings() {
        settingsController?.show()
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
