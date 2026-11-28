import SwiftUI
import AppKit

struct EqualizerIconView: View {
    let isPlaying: Bool
    let tint: Color
    let lowCPUMode: Bool
    let style: VisualizerStyle
    let width: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: lowCPUMode ? 0.30 : 0.10, paused: !isPlaying)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let w = CGFloat(width)
            switch style {
            case .bars:
                Canvas { context, size in
                    let barCount = max(3, min(8, Int((Double(size.width) / 4.2).rounded())))
                    let barW: CGFloat = 2.2
                    let spacing: CGFloat = 2.0
                    let totalW = CGFloat(barCount) * barW + CGFloat(max(0, barCount - 1)) * spacing
                    let startX = max(0, (size.width - totalW) / 2)
                    for idx in 0..<barCount {
                        let wave = isPlaying ? (0.28 + 0.72 * abs(sin(t * 4.8 + Double(idx) * 1.15))) : 0.25
                        let h = max(3.0, 11.0 * wave)
                        let rect = CGRect(
                            x: startX + CGFloat(idx) * (barW + spacing),
                            y: size.height - h,
                            width: barW,
                            height: h
                        )
                        context.fill(Path(roundedRect: rect, cornerRadius: barW / 2), with: .color(tint))
                    }
                }
                .frame(width: w, height: 12)

            case .wave:
                Canvas { context, size in
                    var path = Path()
                    let midY = size.height / 2
                    let amp = isPlaying ? (size.height * 0.38) : 0.6
                    let steps = max(14, Int(size.width))
                    let cycles = max(2.2, Double(size.width) / 9.0)
                    for i in 0...steps {
                        let frac = Double(i) / Double(steps)
                        let x = frac * size.width
                        let y = midY + sin(frac * .pi * cycles + t * 6.0) * amp
                        if i == 0 {
                            path.move(to: CGPoint(x: x, y: y))
                        } else {
                            path.addLine(to: CGPoint(x: x, y: y))
                        }
                    }
                    context.stroke(path, with: .color(tint), style: StrokeStyle(lineWidth: 1.6, lineCap: .round))
                }
                .frame(width: w, height: 12)

            case .dots:
                Canvas { context, size in
                    let dotCount = max(3, min(7, Int((Double(size.width) / 5.5).rounded())))
                    let baseSize: CGFloat = 3.2
                    let spacing: CGFloat = 2.5
                    let totalW = CGFloat(dotCount) * baseSize + CGFloat(max(0, dotCount - 1)) * spacing
                    let startX = max(0, (size.width - totalW) / 2)
                    let midY = size.height / 2
                    for idx in 0..<dotCount {
                        let scale = isPlaying ? (0.52 + 0.48 * abs(sin(t * 4.4 + Double(idx) * 1.05))) : 0.55
                        let d = baseSize * scale
                        let cx = startX + CGFloat(idx) * (baseSize + spacing) + baseSize / 2
                        let rect = CGRect(x: cx - d / 2, y: midY - d / 2, width: d, height: d)
                        context.fill(Path(ellipseIn: rect), with: .color(tint))
                    }
                }
                .frame(width: w, height: 12)

            case .vinyl:
                let angle = isPlaying ? (t.truncatingRemainder(dividingBy: 3.0) / 3.0) * 360.0 : 0.0
                ZStack {
                    Circle()
                        .stroke(tint, lineWidth: 1.4)
                    Circle()
                        .trim(from: 0.0, to: 0.35)
                        .stroke(tint.opacity(0.65), lineWidth: 1.0)
                        .padding(2.2)
                    Circle()
                        .fill(tint)
                        .frame(width: 2.5, height: 2.5)
                }
                .frame(width: 12, height: 12)
                .rotationEffect(.degrees(angle))
                .frame(width: w, height: 12)

            case .note:
                let pulse = isPlaying ? (0.88 + 0.14 * sin(t * 5.0)) : 0.9
                Image(systemName: "music.note")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(tint)
                    .scaleEffect(pulse)
                    .frame(width: w, height: 12)
            }
        }
    }
}

struct KaraokeLineView: View {
    let text: String
    let state: LyricsState
    let font: Font
    /// Same font as `font`, for measuring word boundaries; nil keeps the character-share edge.
    var measureFont: NSFont?
    let unsungColor: Color
    let sungColor: Color
    let karaokeEnabled: Bool
    let isPlaying: Bool
    let lowCPUMode: Bool
    var glowEnabled: Bool = false
    var wordPopEnabled: Bool = false
    var typingCaretEnabled: Bool = false

    @State private var textWidth: CGFloat = 0

    static let caretWidth: CGFloat = 1.5

    /// Mask stops for the sweep's soft edge; the fade ends at `progress` so unsung glyphs stay unlit.
    static func sweepFeather(progress: Double, textWidth: CGFloat) -> (solidEnd: Double, clearStart: Double) {
        let featherFrac = min(0.25, Double(6 / max(1, textWidth)))
        let edge = max(0.0, min(1.0, progress))
        guard edge < 1 else { return (1, 1) }
        return (max(0.0, edge - featherFrac), edge)
    }

    static func isTimelinePaused(
        isPlaying: Bool,
        karaokeEnabled: Bool,
        textWidth: CGFloat,
        availableWidth: CGFloat
    ) -> Bool {
        let hasOverflow = textWidth > availableWidth
        return !isPlaying || (!karaokeEnabled && !hasOverflow)
    }

    static func scrollProgress(
        state: LyricsState,
        at date: Date,
        karaokeEnabled _: Bool,
        measureFont: NSFont? = nil
    ) -> Double {
        state.liveProgress(at: date, font: measureFont)
    }

    static func scrollOffset(
        progress: Double,
        textWidth: CGFloat,
        availableWidth: CGFloat,
        trailingInset: CGFloat = 0
    ) -> CGFloat {
        let overflow = max(0, textWidth + trailingInset - availableWidth)
        return overflow > 0
            ? -min(overflow, max(0, CGFloat(progress) * textWidth - availableWidth * 0.45))
            : 0
    }

    static func sweepFrameInterval(lowCPUMode: Bool) -> TimeInterval {
        lowCPUMode ? (1.0 / 8.0) : (1.0 / 20.0)
    }

    static func activeWordPop(_ pop: LyricsState.WordPop?) -> LyricsState.WordPop? {
        guard let pop, pop.strength > 0.001, pop.end > pop.start else {
            return nil
        }
        return pop
    }

    var body: some View {
        GeometryReader { container in
            let availableWidth = container.size.width
            let timelinePaused = Self.isTimelinePaused(
                isPlaying: isPlaying,
                karaokeEnabled: karaokeEnabled,
                textWidth: textWidth,
                availableWidth: availableWidth
            )

            let frameInterval = Self.sweepFrameInterval(lowCPUMode: lowCPUMode)
            TimelineView(.animation(minimumInterval: frameInterval, paused: timelinePaused)) { timeline in
                let renderDate = isPlaying ? timeline.date.addingTimeInterval(frameInterval) : timeline.date
                let progress = Self.scrollProgress(
                    state: state,
                    at: renderDate,
                    karaokeEnabled: karaokeEnabled,
                    measureFont: measureFont
                )
                let scrollOffset = Self.scrollOffset(
                    progress: progress,
                    textWidth: textWidth,
                    availableWidth: availableWidth,
                    trailingInset: typingCaretEnabled && karaokeEnabled ? Self.caretWidth : 0
                )

                let rawPop = (wordPopEnabled && karaokeEnabled)
                    ? measureFont.flatMap { state.liveWordPop(at: renderDate, font: $0) }
                    : nil
                let pop = Self.activeWordPop(rawPop)
                Group {
                    if let pop {
                        let strength = CGFloat(pop.strength)
                        ZStack(alignment: .leading) {
                            sweptText(progress: progress)
                                .mask(WordSpanMask(start: pop.start, end: pop.end, inverted: true))
                            sweptText(progress: progress)
                                .mask(WordSpanMask(start: pop.start, end: pop.end, inverted: false))
                                .brightness(0.18 * strength)
                                .scaleEffect(1 + 0.08 * strength, anchor: UnitPoint(x: (pop.start + pop.end) / 2, y: 0.5))
                                .offset(y: -2 * strength)
                                .shadow(color: sungColor.opacity(0.6 * strength), radius: 3 * strength)
                        }
                    } else {
                        sweptText(progress: progress)
                    }
                }
                .overlay(alignment: .leading) {
                    if typingCaretEnabled, karaokeEnabled, textWidth > 0 {
                        typingCaret(progress: progress, waiting: state.liveIsWaitingForWord(at: renderDate), at: renderDate)
                    }
                }
                .offset(x: scrollOffset)
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .background(alignment: .leading) {
            StaticLyricText(text: text, font: font, color: .clear)
                .background(widthReader)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .clipped()
    }

    /// The line with the karaoke sweep at `progress`.
    private func sweptText(progress: Double) -> some View {
        ZStack(alignment: .leading) {
            if karaokeEnabled {
                StaticLyricText(text: text, font: font, color: unsungColor)
                    .equatable()

                StaticLyricText(text: text, font: font, color: sungColor)
                    .equatable()
                    .mask {
                        let feather = Self.sweepFeather(progress: progress, textWidth: textWidth)
                        LinearGradient(
                            stops: [
                                .init(color: .white, location: 0),
                                .init(color: .white, location: feather.solidEnd),
                                .init(color: .clear, location: feather.clearStart),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    }
                    .modifier(KaraokeGlowModifier(enabled: glowEnabled, color: sungColor))
            } else {
                StaticLyricText(text: text, font: font, color: sungColor)
                    .equatable()
                    .modifier(KaraokeGlowModifier(enabled: glowEnabled, color: sungColor))
            }
        }
    }

    /// Thin caret at the sweep edge: solid while a word is sung, blinking while waiting for the next one.
    private func typingCaret(progress: Double, waiting: Bool, at date: Date) -> some View {
        let phase = date.timeIntervalSinceReferenceDate * 2 * .pi
        let height = (measureFont?.pointSize ?? 13) * 1.15
        return Capsule()
            .fill(sungColor)
            .frame(width: Self.caretWidth, height: height)
            .opacity(waiting ? 0.55 + 0.45 * cos(phase) : 1)
            .offset(x: CGFloat(max(0, min(1, progress))) * textWidth)
            .allowsHitTesting(false)
    }

    private var widthReader: some View {
        GeometryReader { textGeo in
            Color.clear
                .onAppear { textWidth = textGeo.size.width }
                .onChange(of: text) { _ in textWidth = textGeo.size.width }
                .onChange(of: textGeo.size.width) { newWidth in textWidth = newWidth }
        }
    }
}

private struct KaraokeGlowModifier: ViewModifier {
    let enabled: Bool
    let color: Color

    func body(content: Content) -> some View {
        if enabled {
            content
                .compositingGroup()
                .shadow(color: color.opacity(0.55), radius: 4)
        } else {
            content
        }
    }
}

private struct StaticLyricText: View, Equatable {
    let text: String
    let font: Font
    let color: Color

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(color)
            .fixedSize(horizontal: true, vertical: false)
    }
}

struct CursorCutoutMask: View {
    let cursorX: CGFloat?
    let spotlightWidth: Double

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            if let cx = cursorX {
                let clearHalf: CGFloat = CGFloat(spotlightWidth) / 2.0
                let feather: CGFloat = 24

                let s1 = max(0, min(1, (cx - clearHalf - feather) / w))
                let s2 = max(s1, min(1, (cx - clearHalf) / w))
                let s3 = max(s2, min(1, (cx + clearHalf) / w))
                let s4 = max(s3, min(1, (cx + clearHalf + feather) / w))

                LinearGradient(
                    stops: [
                        .init(color: .white, location: 0),
                        .init(color: .white, location: s1),
                        .init(color: .clear, location: s2),
                        .init(color: .clear, location: s3),
                        .init(color: .white, location: s4),
                        .init(color: .white, location: 1)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            } else {
                Color.white
            }
        }
    }
}

struct LyricsOverlayView: View {
    @ObservedObject var state: LyricsState
    @State private var hideSyncedBadge: Bool = false
    @State private var badgeDismissTask: Task<Void, Never>?

    private var activeBackdropColor: Color {
        if state.themeMode == .albumTint, let colors = state.albumColors {
            return Color(nsColor: colors.backdropNSColor).opacity(state.backgroundOpacity)
        }
        return Color(nsColor: .windowBackgroundColor).opacity(state.backgroundOpacity)
    }

    private var activeEqualizerColor: Color {
        let themeFallback: Color = if state.themeMode != .system, let colors = state.albumColors {
            Color(nsColor: colors.accentNSColor)
        } else {
            Color.accentColor
        }
        return state.visualizerColorTheme.resolvedColor(fallback: themeFallback)
    }

    private var activeSungColor: Color {
        let themeBase: Color = switch state.themeMode {
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
        return state.lyricsColorPreset.resolvedColor(fallback: themeBase, customHex: state.customLyricsColorHex)
    }

    private var activeUnsungColor: Color {
        switch state.themeMode {
        case .albumTint:
            return Color.white.opacity(0.40)
        case .system, .albumAccent:
            return Color.primary.opacity(0.36)
        }
    }

    private func syncBadgeForegroundColor(isSynced: Bool) -> Color {
        if isSynced {
            return state.themeMode == .albumTint ? Color.white : Color.green
        }
        return state.themeMode == .albumTint ? Color.white.opacity(0.85) : Color.secondary
    }

    private func syncBadgeBackgroundColor(isSynced: Bool) -> Color {
        if isSynced {
            return state.themeMode == .albumTint ? Color.white.opacity(0.18) : Color.green.opacity(0.14)
        }
        return state.themeMode == .albumTint ? Color.white.opacity(0.12) : Color.primary.opacity(0.08)
    }

    private func handleBadgeAutoDismiss(for status: AudioSyncStatus) {
        badgeDismissTask?.cancel()
        badgeDismissTask = nil
        if status.isFinished {
            hideSyncedBadge = false
            badgeDismissTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 3_500_000_000)
                guard !Task.isCancelled else { return }
                hideSyncedBadge = true
            }
        } else {
            hideSyncedBadge = false
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            activeBackdropColor
                .animation(.easeInOut(duration: 0.45), value: state.albumColors?.accentR)

            HStack(spacing: 7) {
                if state.showEqualizer {
                    EqualizerIconView(
                        isPlaying: state.isEnabled && state.isPlaying && state.animateVisualizer,
                        tint: activeEqualizerColor,
                        lowCPUMode: state.lowCPUMode,
                        style: state.visualizerStyle,
                        width: state.visualizerWidth
                    )
                }

                ZStack(alignment: .leading) {
                KaraokeLineView(
                    text: state.currentText,
                    state: state,
                    font: state.fontOption.font(size: state.fontSize, weight: state.fontWeight),
                    measureFont: state.fontOption.nsFont(size: state.fontSize, weight: state.fontWeight),
                    unsungColor: activeUnsungColor,
                    sungColor: activeSungColor,
                    karaokeEnabled: state.karaokeAnimationEnabled,
                    isPlaying: state.isEnabled && state.isPlaying,
                    lowCPUMode: state.lowCPUMode,
                    glowEnabled: state.karaokeGlowEnabled,
                    wordPopEnabled: state.wordPopEnabled,
                    typingCaretEnabled: state.typingCaretEnabled
                )
                .id(
                    "\(state.currentLineId)-\(state.romanizeJapanese)-\(state.romanizeKorean)-\(state.romanizeChinese)-\(state.translateLyrics)-\(state.translationLanguage.rawValue)"
                )
                .transition(LineTransition.transition(for: state.lineTransitionStyle))
                }
                // Old and new line overlap in one clipped slot, so slides travel the bar instead of spilling out of it.
                .clipped()
                .animation(
                    LineTransition.animation(for: state.lineTransitionStyle, duration: state.lineTransitionDuration),
                    value: state.currentLineId
                )

                if state.showTrackTitle, !state.trackSummary.isEmpty, state.trackSummary != "Not Playing" {
                    MarqueeTrackLabelView(
                        text: state.trackSummary,
                        color: activeUnsungColor,
                        maxWidth: 116,
                        isPlaying: state.isEnabled && state.isPlaying,
                        lowCPUMode: state.lowCPUMode
                    )
                    .layoutPriority(1)
                    .transition(.opacity)
                }

                if state.showSyncBadge, let badge = state.audioSyncStatus.overlayBadge {
                    SyncStatusBadgeView(
                        badge: badge,
                        compact: !badge.isAnimating && hideSyncedBadge,
                        foreground: syncBadgeForegroundColor(isSynced: badge.isSynced),
                        background: syncBadgeBackgroundColor(isSynced: badge.isSynced),
                        lowCPUMode: state.lowCPUMode
                    )
                    .fixedSize()
                    .layoutPriority(2)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .scale(scale: 0.85)),
                        removal: .opacity.combined(with: .scale(scale: 0.92))
                    ))
                }
            }
            .padding(.horizontal, 10)
            .animation(.spring(response: 0.32, dampingFraction: 0.82), value: state.audioSyncStatus.overlayBadge)
            .animation(.easeOut(duration: 0.35), value: hideSyncedBadge)
            .onChange(of: state.audioSyncStatus) { newStatus in
                handleBadgeAutoDismiss(for: newStatus)
            }
            .onChange(of: state.trackSummary) { _ in
                handleBadgeAutoDismiss(for: state.audioSyncStatus)
            }
            .onAppear {
                handleBadgeAutoDismiss(for: state.audioSyncStatus)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: state.barCornerRadius, style: .continuous))
        .modifier(
            SpotlightMaskModifier(
                cursorX: state.hoverMode == .spotlight ? state.cursorLocalX : nil,
                spotlightWidth: state.spotlightWidth
            )
        )
        .animation(.easeOut(duration: 0.08), value: state.cursorLocalX == nil)
    }
}

private struct SyncStatusBadgeView: View {
    let badge: OverlaySyncBadge
    let compact: Bool
    let foreground: Color
    let background: Color
    let lowCPUMode: Bool

    var body: some View {
        if compact && !badge.isAnimating {
            Image(systemName: badge.symbolName)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(badge.isSynced ? Color.green : foreground)
                .transition(.opacity.combined(with: .scale(scale: 0.85)))
        } else {
            TimelineView(.animation(minimumInterval: lowCPUMode ? 0.30 : 0.12, paused: !badge.isAnimating)) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                let pulse = badge.isAnimating ? (0.55 + 0.45 * abs(sin(t * 3.2))) : 1.0
                let iconScale = badge.isAnimating ? (0.88 + 0.16 * abs(sin(t * 3.2))) : 1.0
                let dotPhase = Int(t * 2.2) % 3

                HStack(spacing: 3) {
                    Image(systemName: badge.symbolName)
                        .font(.system(size: 9.5, weight: .semibold))
                        .scaleEffect(iconScale)
                        .opacity(pulse)

                    Text(badge.text)
                        .font(.system(size: 10, weight: .medium))

                    if badge.isAnimating {
                        HStack(spacing: 1.5) {
                            ForEach(0..<3, id: \.self) { idx in
                                Circle()
                                    .fill(foreground)
                                    .frame(width: 2.2, height: 2.2)
                                    .opacity(idx == dotPhase ? 1.0 : 0.30)
                            }
                        }
                        .padding(.leading, 1)
                    }
                }
                .foregroundStyle(foreground)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(background)
                )
                .overlay(
                    Capsule(style: .continuous)
                        .strokeBorder(foreground.opacity(badge.isAnimating ? (0.18 + 0.22 * pulse) : 0.28), lineWidth: 0.5)
                )
            }
        }
    }
}

private struct SpotlightMaskModifier: ViewModifier {
    let cursorX: CGFloat?
    let spotlightWidth: Double

    func body(content: Content) -> some View {
        if let cursorX {
            content
                .compositingGroup()
                .mask(CursorCutoutMask(cursorX: cursorX, spotlightWidth: spotlightWidth))
        } else {
            content
        }
    }
}

enum MarqueeScrollCalculator {
    static let gap: CGFloat = 24

    /// Computes horizontal scroll offset for a smoothly looping marquee label.
    /// Returns `0` when the text already fits inside `containerWidth`.
    static func offset(
        at elapsed: Double,
        textWidth: CGFloat,
        containerWidth: CGFloat,
        speed: Double = 24.0,
        pauseDuration: Double = 1.6
    ) -> CGFloat {
        guard textWidth > containerWidth + 1, speed > 0 else { return 0 }
        let travel = Double(textWidth + gap)
        let scrollDuration = travel / speed
        let cycle = pauseDuration + scrollDuration
        let phase = elapsed.truncatingRemainder(dividingBy: cycle)
        guard phase > pauseDuration else { return 0 }
        return -CGFloat((phase - pauseDuration) * speed)
    }
}

private struct MarqueeTrackLabelView: View {
    let text: String
    let color: Color
    let maxWidth: CGFloat
    let isPlaying: Bool
    let lowCPUMode: Bool

    @State private var startDate: Date = .now

    private var measuredTextWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 10.5, weight: .regular)
        let size = (text as NSString).size(withAttributes: [.font: font])
        return ceil(size.width) + 2
    }

    var body: some View {
        let textWidth = measuredTextWidth
        let needsScroll = textWidth > maxWidth + 1
        let displayWidth = needsScroll ? maxWidth : textWidth

        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isPlaying || !needsScroll)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startDate))
            let xOffset = MarqueeScrollCalculator.offset(
                at: elapsed,
                textWidth: textWidth,
                containerWidth: maxWidth
            )

            HStack(spacing: MarqueeScrollCalculator.gap) {
                labelText
                if needsScroll {
                    labelText
                }
            }
            .offset(x: xOffset)
            .frame(width: displayWidth, alignment: .leading)
            .clipped()
        }
        .onChange(of: text) { _ in
            startDate = .now
        }
    }

    private var labelText: some View {
        Text(text)
            .font(.system(size: 10.5, weight: .regular))
            .foregroundStyle(color)
            .fixedSize(horizontal: true, vertical: false)
    }
}

/// Shows only one word's span of the line (or everything but it, when `inverted`).
struct WordSpanMask: View {
    let start: Double
    let end: Double
    let inverted: Bool

    var body: some View {
        let inside: Color = inverted ? .clear : .white
        let outside: Color = inverted ? .white : .clear
        LinearGradient(
            stops: [
                .init(color: outside, location: 0),
                .init(color: outside, location: start),
                .init(color: inside, location: start),
                .init(color: inside, location: end),
                .init(color: outside, location: end),
                .init(color: outside, location: 1),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
    }
}

/// The look and timing of the change from one lyric line to the next.
enum LineTransition {
    static func transition(for style: LineTransitionStyle) -> AnyTransition {
        switch style {
        case .subtle:
            return .asymmetric(
                insertion: .opacity.combined(with: .offset(y: 6)),
                removal: .opacity.combined(with: .offset(y: -6))
            )
        case .slide:
            return .asymmetric(
                insertion: .move(edge: .bottom).combined(with: .opacity),
                removal: .move(edge: .top).combined(with: .opacity)
            )
        case .blurFade:
            return .modifier(active: BlurFade(amount: 1), identity: BlurFade(amount: 0))
        case .pop:
            return .asymmetric(
                insertion: .scale(scale: 0.7, anchor: .leading).combined(with: .opacity),
                removal: .scale(scale: 1.12, anchor: .leading).combined(with: .opacity)
            )
        case .push:
            return .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
        case .none:
            return .identity
        }
    }

    static func animation(for style: LineTransitionStyle, duration: Double) -> Animation? {
        switch style {
        case .subtle: return .spring(response: duration, dampingFraction: 0.85)
        case .slide, .push: return .spring(response: duration, dampingFraction: 0.86)
        case .blurFade: return .easeInOut(duration: duration)
        case .pop: return .spring(response: duration, dampingFraction: 0.55)
        case .none: return nil
        }
    }
}

private struct BlurFade: ViewModifier {
    /// 0 is the settled line, 1 fully blurred and transparent.
    let amount: Double

    func body(content: Content) -> some View {
        content
            .blur(radius: 6 * amount)
            .opacity(1 - amount)
    }
}
