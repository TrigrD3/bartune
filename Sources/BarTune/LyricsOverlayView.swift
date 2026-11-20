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
                let barCount = max(3, min(8, Int((w / 4.2).rounded())))
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(0..<barCount, id: \.self) { idx in
                        let wave = isPlaying ? (0.28 + 0.72 * abs(sin(t * 4.8 + Double(idx) * 1.15))) : 0.25
                        Capsule()
                            .fill(tint)
                            .frame(width: 2.2, height: max(3, 11 * wave))
                    }
                }
                .frame(width: w, height: 12, alignment: .bottom)

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
                let dotCount = max(3, min(7, Int((w / 5.5).rounded())))
                HStack(spacing: 2.5) {
                    ForEach(0..<dotCount, id: \.self) { idx in
                        let scale = isPlaying ? (0.52 + 0.48 * abs(sin(t * 4.4 + Double(idx) * 1.05))) : 0.55
                        Circle()
                            .fill(tint)
                            .frame(width: 3.2, height: 3.2)
                            .scaleEffect(scale)
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
        TimelineView(.animation(minimumInterval: lowCPUMode ? (1.0 / 8.0) : (1.0 / 30.0), paused: !isPlaying || !karaokeEnabled)) { timeline in
            let progress = karaokeEnabled ? state.liveProgress(at: timeline.date) : 1.0
            GeometryReader { container in
                let availableWidth = container.size.width
                let overflow = max(0, textWidth - availableWidth)
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
            .clipped()
        }
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

    private var activeBackdropColor: Color {
        if state.themeMode == .albumTint, let colors = state.albumColors {
            return Color(nsColor: colors.backdropNSColor).opacity(state.backgroundOpacity)
        }
        return Color(nsColor: .windowBackgroundColor).opacity(state.backgroundOpacity)
    }

    private var activeEqualizerColor: Color {
        if state.themeMode != .system, let colors = state.albumColors {
            return Color(nsColor: colors.accentNSColor)
        }
        return Color.accentColor
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

    var body: some View {
        ZStack(alignment: .leading) {
            activeBackdropColor
                .animation(.easeInOut(duration: 0.45), value: state.albumColors?.accentR)

            HStack(spacing: 7) {
                if state.showEqualizer {
                    EqualizerIconView(
                        isPlaying: state.isPlaying && state.animateVisualizer,
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
                    isPlaying: state.isPlaying,
                    lowCPUMode: state.lowCPUMode
                )
                .id("\(state.currentLineId)-\(state.romanizeJapanese)-\(state.romanizeKorean)-\(state.romanizeChinese)")
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .offset(y: 6)),
                    removal: .opacity.combined(with: .offset(y: -6))
                ))
                .animation(.spring(response: 0.28, dampingFraction: 0.85), value: state.currentLineId)
            }
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .compositingGroup()
        .mask(
            CursorCutoutMask(
                cursorX: state.hoverMode == .spotlight ? state.cursorLocalX : nil,
                spotlightWidth: state.spotlightWidth
            )
        )
        .animation(.easeOut(duration: 0.08), value: state.cursorLocalX == nil)
    }
}
