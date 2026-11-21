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
    let unsungColor: Color
    let sungColor: Color
    let karaokeEnabled: Bool
    let isPlaying: Bool
    let lowCPUMode: Bool

    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { container in
            let availableWidth = container.size.width
            let overflow = max(0, textWidth - availableWidth)

            TimelineView(.animation(minimumInterval: lowCPUMode ? (1.0 / 8.0) : (1.0 / 30.0), paused: !isPlaying || !karaokeEnabled)) { timeline in
                let progress = karaokeEnabled ? state.liveProgress(at: timeline.date) : 1.0
                let scrollOffset: CGFloat = overflow > 0
                    ? -min(overflow, max(0, CGFloat(progress) * textWidth - availableWidth * 0.45))
                    : 0

                ZStack(alignment: .leading) {
                    if karaokeEnabled {
                        Text(text)
                            .font(font)
                            .foregroundStyle(unsungColor)
                            .fixedSize(horizontal: true, vertical: false)
                            .background(widthReader)

                        Text(text)
                            .font(font)
                            .foregroundStyle(sungColor)
                            .fixedSize(horizontal: true, vertical: false)
                            .mask {
                                let w = max(1, textWidth)
                                let featherFrac = min(0.25, Double(14 / w))
                                let edge = max(0.0, min(1.0, progress))
                                let fadeEnd = min(1.0, edge + featherFrac)
                                LinearGradient(
                                    stops: [
                                        .init(color: .white, location: 0),
                                        .init(color: .white, location: edge),
                                        .init(color: .clear, location: fadeEnd),
                                        .init(color: .clear, location: 1),
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                            }
                    } else {
                        Text(text)
                            .font(font)
                            .foregroundStyle(sungColor)
                            .fixedSize(horizontal: true, vertical: false)
                            .background(widthReader)
                    }
                }
                .offset(x: scrollOffset)
                .frame(maxHeight: .infinity, alignment: .center)
            }
        }
        .clipped()
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
        if case .cached = status {
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

                KaraokeLineView(
                    text: state.currentText,
                    state: state,
                    font: state.fontOption.font(size: state.fontSize, weight: state.fontWeight),
                    unsungColor: activeUnsungColor,
                    sungColor: activeSungColor,
                    karaokeEnabled: state.karaokeAnimationEnabled,
                    isPlaying: state.isEnabled && state.isPlaying,
                    lowCPUMode: state.lowCPUMode
                )
                .id(
                    "\(state.currentLineId)-\(state.romanizeJapanese)-\(state.romanizeKorean)-\(state.romanizeChinese)-\(state.translateLyrics)-\(state.translationLanguage.rawValue)"
                )
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 6)),
                    removal: .opacity.combined(with: .offset(y: -6))
                ))
                .animation(.spring(response: 0.28, dampingFraction: 0.85), value: state.currentLineId)

                if !state.trackSummary.isEmpty, state.trackSummary != "Not Playing" {
                    MarqueeTrackLabelView(
                        text: state.trackSummary,
                        color: activeUnsungColor,
                        maxWidth: 140,
                        isPlaying: state.isEnabled && state.isPlaying,
                        lowCPUMode: state.lowCPUMode
                    )
                    .layoutPriority(1)
                    .transition(.opacity)
                }

                if state.showSyncBadge,
                   let badge = state.audioSyncStatus.overlayBadge,
                   !(badge.isSynced && hideSyncedBadge) {
                    SyncStatusBadgeView(
                        badge: badge,
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
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
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
    let foreground: Color
    let background: Color
    let lowCPUMode: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: lowCPUMode ? 0.30 : 0.12, paused: badge.isSynced)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            let pulse = badge.isSynced ? 1.0 : (0.55 + 0.45 * abs(sin(t * 3.2)))
            let iconScale = badge.isSynced ? 1.0 : (0.88 + 0.16 * abs(sin(t * 3.2)))
            let dotPhase = Int(t * 2.2) % 3

            HStack(spacing: 3) {
                Image(systemName: badge.symbolName)
                    .font(.system(size: 9.5, weight: .semibold))
                    .scaleEffect(iconScale)
                    .opacity(pulse)

                Text(badge.text)
                    .font(.system(size: 10, weight: .medium))

                if !badge.isSynced {
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
                    .strokeBorder(foreground.opacity(badge.isSynced ? 0.28 : (0.18 + 0.22 * pulse)), lineWidth: 0.5)
            )
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

    @State private var textWidth: CGFloat = 0
    @State private var startDate: Date = .now

    private var needsScroll: Bool {
        textWidth > maxWidth + 1
    }

    var body: some View {
        let displayWidth = needsScroll ? maxWidth : max(1, textWidth)
        TimelineView(.animation(minimumInterval: lowCPUMode ? (1.0 / 12.0) : (1.0 / 30.0), paused: !isPlaying || !needsScroll)) { timeline in
            let elapsed = max(0, timeline.date.timeIntervalSince(startDate))
            let xOffset = MarqueeScrollCalculator.offset(
                at: elapsed,
                textWidth: textWidth,
                containerWidth: maxWidth
            )

            HStack(spacing: MarqueeScrollCalculator.gap) {
                labelText
                    .background(widthReader)
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

    private var widthReader: some View {
        GeometryReader { geo in
            Color.clear
                .onAppear { textWidth = geo.size.width }
                .onChange(of: text) { _ in textWidth = geo.size.width }
                .onChange(of: geo.size.width) { newW in textWidth = newW }
        }
    }
}
