import SwiftUI
import AppKit

struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

struct EqualizerIconView: View {
    let isPlaying: Bool
    @State private var phase: Double = 0

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.12, paused: !isPlaying)) { timeline in
            let t = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(0..<3, id: \.self) { idx in
                    let wave = isPlaying ? (0.35 + 0.65 * abs(sin(t * 4.5 + Double(idx) * 1.4))) : 0.25
                    Capsule()
                        .fill(Color.accentColor)
                        .frame(width: 2, height: max(3, 10 * wave))
                }
            }
            .frame(width: 10, height: 11, alignment: .bottom)
        }
    }
}

struct KaraokeLineView: View {
    let text: String
    let progress: Double

    @State private var textWidth: CGFloat = 0

    var body: some View {
        GeometryReader { container in
            let availableWidth = container.size.width
            let overflow = max(0, textWidth - availableWidth)
            // Keep the active sweep point centered when a line is wider than the left menu bar
            let scrollOffset: CGFloat = overflow > 0
                ? -min(overflow, max(0, CGFloat(progress) * textWidth - availableWidth * 0.45))
                : 0

            ZStack(alignment: .leading) {
                // Unsung base text
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(0.36))
                    .fixedSize(horizontal: true, vertical: false)
                    .background(
                        GeometryReader { textGeo in
                            Color.clear.onAppear {
                                textWidth = textGeo.size.width
                            }
                            .onChange(of: text) { _ in
                                textWidth = textGeo.size.width
                            }
                            .onChange(of: textGeo.size.width) { newWidth in
                                textWidth = newWidth
                            }
                        }
                    )

                // Sung karaoke highlighted text with smooth feathered sweep mask
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.primary)
                    .fixedSize(horizontal: true, vertical: false)
                    .mask(
                        GeometryReader { maskGeo in
                            let w = maskGeo.size.width
                            let feather: CGFloat = 16
                            let fillWidth = max(0, min(w + feather, CGFloat(progress) * w + feather * 0.5))

                            HStack(spacing: 0) {
                                Rectangle()
                                    .fill(Color.white)
                                    .frame(width: max(0, fillWidth - feather))
                                LinearGradient(
                                    colors: [Color.white, Color.clear],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                )
                                .frame(width: feather)
                                Spacer(minLength: 0)
                            }
                        }
                    )
            }
            .offset(x: scrollOffset)
            .animation(.linear(duration: 0.06), value: scrollOffset)
            .frame(maxHeight: .infinity, alignment: .center)
        }
        .clipped()
    }
}

struct CursorCutoutMask: View {
    let cursorX: CGFloat?

    var body: some View {
        GeometryReader { geo in
            let w = max(1, geo.size.width)
            if let cx = cursorX {
                let clearHalf: CGFloat = 34
                let feather: CGFloat = 28

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

    var body: some View {
        ZStack(alignment: .leading) {
            Color(nsColor: .windowBackgroundColor).opacity(0.96)

            HStack(spacing: 7) {
                EqualizerIconView(isPlaying: state.isPlaying)

                KaraokeLineView(text: state.currentText, progress: state.lineProgress)
                    .id(state.currentLineId)
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
        .mask(CursorCutoutMask(cursorX: state.cursorLocalX))
        .animation(.easeOut(duration: 0.08), value: state.cursorLocalX == nil)
    }
}
