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

struct LyricsOverlayView: View {
    @ObservedObject var state: LyricsState

    var body: some View {
        ZStack(alignment: .leading) {
            // Solid-enough adaptive backdrop to cleanly mask File/Edit/View underneath
            VisualEffectBackground()
                .overlay(Color(nsColor: .windowBackgroundColor).opacity(0.88))

            HStack(spacing: 6) {
                Image(systemName: "music.note")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)

                Text(state.currentText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .id(state.currentLineId)
                    .transition(.opacity.combined(with: .offset(y: 3)))
                    .animation(.easeInOut(duration: 0.2), value: state.currentLineId)

                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}
