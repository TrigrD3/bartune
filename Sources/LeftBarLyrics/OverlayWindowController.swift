import AppKit
import SwiftUI
import Combine

@MainActor
final class OverlayWindowController {
    private let state: LyricsState
    private var panel: NSPanel?
    private var hostingView: NSHostingView<LyricsOverlayView>?
    private var cancellables = Set<AnyCancellable>()

    private var mouseMoveMonitor: Any?
    private var mouseDownMonitor: Any?
    private var keyDownMonitor: Any?
    private var hoverCheckTimer: Timer?

    private var isHovered = false
    private var isMenuLikelyOpen = false
    private var unhoverWorkItem: DispatchWorkItem?

    /// Cached rect of the left-of-notch menu bar region (including Apple logo for smooth hover detection).
    private var hoverTriggerRect: NSRect = .zero

    init(state: LyricsState) {
        self.state = state
        setupPanel()
        observeState()
        observeScreens()
        startHoverMonitoring()
    }

    deinit {
        if let m = mouseMoveMonitor { NSEvent.removeMonitor(m) }
        if let m = mouseDownMonitor { NSEvent.removeMonitor(m) }
        if let m = keyDownMonitor { NSEvent.removeMonitor(m) }
    }

    private func setupPanel() {
        let frame = computeOverlayFrame()
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        // Sit directly above the macOS menu bar items without ever stealing focus or clicks
        let menuLevel = Int(CGWindowLevelForKey(.mainMenuWindow))
        panel.level = NSWindow.Level(rawValue: menuLevel + 1)
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .ignoresCycle,
            .fullScreenAuxiliary
        ]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.alphaValue = 0

        let view = NSHostingView(rootView: LyricsOverlayView(state: state))
        view.frame = NSRect(origin: .zero, size: frame.size)
        view.autoresizingMask = [.width, .height]
        panel.contentView = view

        panel.orderFrontRegardless()
        self.panel = panel
        self.hostingView = view
    }

    private func observeState() {
        Publishers.CombineLatest3(state.$isEnabled, state.$isPlaying, state.$currentText)
            .receive(on: RunLoop.main)
            .sink { [weak self] _, _, _ in
                self?.refreshVisibility()
            }
            .store(in: &cancellables)
    }

    private func observeScreens() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.repositionPanel()
            }
        }
    }

    private func targetScreen() -> NSScreen? {
        // Prefer the built-in notched screen if available, otherwise fall back to main screen.
        if let notched = NSScreen.screens.first(where: { $0.auxiliaryTopLeftArea != nil }) {
            return notched
        }
        return NSScreen.main ?? NSScreen.screens.first
    }

    private func computeOverlayFrame() -> NSRect {
        guard let screen = targetScreen() else {
            hoverTriggerRect = .zero
            return NSRect(x: 40, y: 0, width: 400, height: 24)
        }

        if let leftArea = screen.auxiliaryTopLeftArea {
            // Keep the Apple logo (~38pt) visible on the far left; fill up to just before the notch.
            let appleLogoWidth: CGFloat = 38
            let rightPadding: CGFloat = 6
            let verticalInset: CGFloat = 2

            let overlayX = leftArea.minX + appleLogoWidth
            let overlayWidth = max(120, leftArea.width - appleLogoWidth - rightPadding)
            let overlayHeight = max(20, leftArea.height - verticalInset * 2)
            let overlayY = leftArea.minY + verticalInset

            // Hover trigger covers the entire left-of-notch menu bar (including the Apple logo).
            hoverTriggerRect = NSRect(
                x: leftArea.minX,
                y: leftArea.minY - 4,
                width: leftArea.width + 4,
                height: leftArea.height + 8
            )

            return NSRect(x: overlayX, y: overlayY, width: overlayWidth, height: overlayHeight)
        } else {
            // Non-notched screen fallback: top-left 45% of menu bar, strictly inside menu bar height.
            let menuBarHeight = max(24, screen.frame.maxY - screen.visibleFrame.maxY)
            let appleLogoWidth: CGFloat = 38
            let width = max(200, screen.frame.width * 0.42 - appleLogoWidth)
            let y = screen.frame.maxY - menuBarHeight + 1

            hoverTriggerRect = NSRect(
                x: screen.frame.minX,
                y: screen.frame.maxY - menuBarHeight - 4,
                width: width + appleLogoWidth,
                height: menuBarHeight + 8
            )

            return NSRect(
                x: screen.frame.minX + appleLogoWidth,
                y: y,
                width: width,
                height: menuBarHeight - 2
            )
        }
    }

    func repositionPanel() {
        let frame = computeOverlayFrame()
        panel?.setFrame(frame, display: true)
    }

    private func startHoverMonitoring() {
        mouseMoveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateMouseLocation()
            }
        }

        mouseDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                self?.handleGlobalMouseDown()
            }
        }

        keyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if self.isMenuLikelyOpen {
                    self.isMenuLikelyOpen = false
                    self.evaluateMouseLocation()
                }
            }
        }

        // Lightweight periodic check while hidden/hovered so we never get stuck hidden.
        hoverCheckTimer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateMouseLocation()
            }
        }
    }

    private func handleGlobalMouseDown() {
        let loc = NSEvent.mouseLocation
        if hoverTriggerRect.contains(loc) {
            // User clicked a menu item (File, Edit, View, etc.) — keep lyrics hidden while menu is open.
            isMenuLikelyOpen = true
            isHovered = true
            unhoverWorkItem?.cancel()
            refreshVisibility()
        } else if isMenuLikelyOpen {
            // User clicked outside the menu bar (closing or selecting from the menu).
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
                guard let self else { return }
                self.isMenuLikelyOpen = false
                self.evaluateMouseLocation()
            }
        }
    }

    private func evaluateMouseLocation() {
        let loc = NSEvent.mouseLocation
        let inside = hoverTriggerRect.contains(loc)

        if inside {
            unhoverWorkItem?.cancel()
            unhoverWorkItem = nil
            if !isHovered {
                isHovered = true
                refreshVisibility()
            }
        } else if isHovered && !isMenuLikelyOpen {
            if unhoverWorkItem == nil {
                let work = DispatchWorkItem { [weak self] in
                    guard let self else { return }
                    self.unhoverWorkItem = nil
                    if !self.hoverTriggerRect.contains(NSEvent.mouseLocation) && !self.isMenuLikelyOpen {
                        self.isHovered = false
                        self.refreshVisibility()
                    }
                }
                unhoverWorkItem = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.22, execute: work)
            }
        }
    }

    private func refreshVisibility() {
        guard let panel else { return }
        let visible = state.shouldShowOverlay && !isHovered && !isMenuLikelyOpen
        let targetAlpha: CGFloat = visible ? 1.0 : 0.0

        guard abs(panel.alphaValue - targetAlpha) > 0.01 else { return }

        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = visible ? 0.22 : 0.10
            ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            panel.animator().alphaValue = targetAlpha
        }
    }
}
