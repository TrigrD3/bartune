import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let state = LyricsState()
    private let spotifyMonitor = SpotifyMonitor()
    private let lyricsFetcher = LyricsFetcher()
    private var overlayController: OverlayWindowController?
    private var settingsController: SettingsWindowController?

    private var statusItem: NSStatusItem?
    private var trackMenuItem: NSMenuItem?
    private var toggleMenuItem: NSMenuItem?
    private var offsetMenuItem: NSMenuItem?
    private var hoverModeItems: [HoverMode: NSMenuItem] = [:]

    private var lastFetchedTrackId: String?
    private var fetchTask: Task<Void, Never>?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        setupStatusBarMenu()
        overlayController = OverlayWindowController(state: state)
        settingsController = SettingsWindowController(state: state)

        spotifyMonitor.onUpdate = { [weak self] snapshot in
            self?.handlePlaybackUpdate(snapshot)
        }
        spotifyMonitor.start()

        state.$trackSummary
            .receive(on: RunLoop.main)
            .sink { [weak self] summary in
                self?.trackMenuItem?.title = summary
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
    }

    func applicationWillTerminate(_ notification: Notification) {
        spotifyMonitor.stop()
        fetchTask?.cancel()
    }

    private func setupStatusBarMenu() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "music.note", accessibilityDescription: "LeftBar Lyrics")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        let trackItem = NSMenuItem(title: "Not Playing", action: nil, keyEquivalent: "")
        trackItem.isEnabled = false
        menu.addItem(trackItem)
        self.trackMenuItem = trackItem

        menu.addItem(.separator())

        let toggleItem = NSMenuItem(title: "Show Lyrics", action: #selector(toggleLyrics), keyEquivalent: "l")
        toggleItem.target = self
        toggleItem.state = .on
        menu.addItem(toggleItem)
        self.toggleMenuItem = toggleItem

        // Quick-switch Hover Mode submenu
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

        let quitItem = NSMenuItem(title: "Quit LeftBar Lyrics", action: #selector(quitApp), keyEquivalent: "q")
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

    private func handlePlaybackUpdate(_ snapshot: PlaybackSnapshot) {
        guard snapshot.isRunning, let track = snapshot.track else {
            if lastFetchedTrackId != nil {
                lastFetchedTrackId = nil
                fetchTask?.cancel()
                state.setTrack(nil, lyrics: [])
            }
            state.updatePlayback(isPlaying: false, position: 0)
            return
        }

        if track.id != lastFetchedTrackId {
            lastFetchedTrackId = track.id
            fetchTask?.cancel()
            state.setTrack(track, lyrics: [])

            fetchTask = Task { [weak self] in
                guard let self else { return }
                let lyrics = await self.lyricsFetcher.fetchLyrics(for: track)
                guard !Task.isCancelled, self.lastFetchedTrackId == track.id else { return }
                self.state.setTrack(track, lyrics: lyrics)
            }
        }

        state.updatePlayback(isPlaying: snapshot.isPlaying, position: snapshot.position)
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
