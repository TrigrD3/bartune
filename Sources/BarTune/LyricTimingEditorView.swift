import AppKit
import Combine
import SwiftUI

@MainActor
final class LyricTimingEditorModel: ObservableObject {
    @Published var session: LyricTimingSession
    @Published var selectedLineId: UUID?
    @Published var activeTrack: TrackInfo?
    @Published var selectedSource: TrackLyricSource = .defaultSource
    @Published var hasCustomLyrics: Bool = false
    @Published var statusMessage: String?

    private let state: LyricsState
    private let customLyricsStore: CustomLyricsStore
    private let onSeek: (Double) -> Void
    private let onTogglePlayPause: () -> Void
    private let onSelectSource: (TrackInfo, TrackLyricSource) -> Void
    private let onSaveCustom: (TrackInfo, [LyricLine]) -> Void
    private let onDeleteCustom: (TrackInfo) -> Void
    private var cancellables = Set<AnyCancellable>()

    init(
        state: LyricsState,
        customLyricsStore: CustomLyricsStore,
        onSeek: @escaping (Double) -> Void,
        onTogglePlayPause: @escaping () -> Void,
        onSelectSource: @escaping (TrackInfo, TrackLyricSource) -> Void,
        onSaveCustom: @escaping (TrackInfo, [LyricLine]) -> Void,
        onDeleteCustom: @escaping (TrackInfo) -> Void
    ) {
        self.state = state
        self.customLyricsStore = customLyricsStore
        self.onSeek = onSeek
        self.onTogglePlayPause = onTogglePlayPause
        self.onSelectSource = onSelectSource
        self.onSaveCustom = onSaveCustom
        self.onDeleteCustom = onDeleteCustom
        self.session = LyricTimingSession(lines: [])
        loadCurrentTrack()

        state.$currentTrack
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] newTrack in
                guard let self, let newTrack else { return }
                if newTrack.id != self.activeTrack?.id {
                    self.loadCurrentTrack()
                }
            }
            .store(in: &cancellables)
    }

    var availableSources: [TrackLyricSource] {
        hasCustomLyrics ? [.defaultSource, .custom, .automatic] : [.defaultSource, .automatic]
    }

    var selectedLineIndex: Int? {
        guard let selectedLineId else { return nil }
        return session.lines.firstIndex { $0.id == selectedLineId }
    }

    func loadCurrentTrack() {
        guard let track = state.currentTrack else {
            // Keep any already-loaded track and session open when playback pauses or stops.
            return
        }
        activeTrack = track
        statusMessage = nil

        let customRecord = customLyricsStore.load(trackId: track.id)
        hasCustomLyrics = customRecord != nil
        selectedSource = LyricSourceResolver.effectiveSource(
            choice: state.lyricSourceChoice(for: track.id),
            hasCustomLyrics: hasCustomLyrics,
            audioSyncEngine: state.audioSyncEngine
        )

        let startingLines = !state.rawLyricLines.isEmpty ? state.rawLyricLines : (customRecord?.lines ?? [])
        session = LyricTimingSession(lines: startingLines)
        selectedLineId = session.lines.first?.id
    }

    func selectSource(_ source: TrackLyricSource) {
        guard let track = activeTrack else { return }
        selectedSource = source
        onSelectSource(track, source)
        // Reload lines to reflect the newly selected source when not actively stamping.
        session = LyricTimingSession(lines: state.rawLyricLines)
        selectedLineId = session.lines.first?.id
        statusMessage = "Switched to \(source.title)."
    }

    func togglePlayPause() {
        onTogglePlayPause()
    }

    func seek(to seconds: Double) {
        onSeek(max(0.0, seconds))
    }

    func nudgePlayback(by delta: Double) {
        seek(to: max(0.0, state.currentPlaybackPosition() + delta))
    }

    func stampNow() {
        let pos = state.currentPlaybackPosition()
        if session.stamp(at: pos) {
            statusMessage = nil
            if case .lines = session.stampingMode, session.nextLineIndex < session.lines.count {
                selectedLineId = session.lines[session.nextLineIndex].id
            }
        }
    }

    func stampSelectedLineEndNow() {
        guard let index = selectedLineIndex else { return }
        let pos = state.currentPlaybackPosition()
        _ = session.stampLineEnd(at: pos, forLine: index)
    }

    func undoLastStamp() {
        _ = session.undoLastStamp()
    }

    func saveCustomLyrics() {
        guard let track = activeTrack else { return }
        let built = session.buildLyricLines()
        guard !built.isEmpty else {
            statusMessage = "Stamp at least one line before saving."
            return
        }
        session.stopStamping()
        onSaveCustom(track, built)
        hasCustomLyrics = true
        selectedSource = .custom
        statusMessage = "Saved Custom timing (\(built.count) lines)."
    }

    func deleteCustomLyrics() {
        guard let track = activeTrack else { return }
        session.stopStamping()
        onDeleteCustom(track)
        hasCustomLyrics = false
        selectedSource = LyricSourceResolver.effectiveSource(
            choice: state.lyricSourceChoice(for: track.id),
            hasCustomLyrics: false,
            audioSyncEngine: state.audioSyncEngine
        )
        session = LyricTimingSession(lines: state.rawLyricLines)
        selectedLineId = session.lines.first?.id
        statusMessage = "Deleted Custom lyrics."
    }

    func pastePlainLyrics(_ text: String) {
        session.replaceWithPlainText(text)
        selectedLineId = session.lines.first?.id
        statusMessage = "Loaded \(session.lines.count) lines. Press Stamp Lines to time them."
    }
}

struct LyricTimingEditorView: View {
    @ObservedObject var state: LyricsState
    @ObservedObject var model: LyricTimingEditorModel
    @State private var showPasteSheet = false
    @State private var pasteBuffer = ""
    @State private var showDeleteConfirmation = false

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if model.activeTrack == nil {
                emptyStateView
            } else {
                stampingBar
                Divider()

                if model.session.hasOutOfOrderWarnings {
                    outOfOrderBanner
                    Divider()
                }

                HSplitView {
                    linesListPane
                        .frame(minWidth: 380, idealWidth: 460)
                    wordInspectorPane
                        .frame(minWidth: 250, idealWidth: 290)
                }

                Divider()
                footerBar
            }
        }
        .frame(minWidth: 700, minHeight: 520)
        .sheet(isPresented: $showPasteSheet) {
            pasteLyricsSheet
        }
        .alert("Delete Custom Lyrics?", isPresented: $showDeleteConfirmation) {
            Button("Delete", role: .destructive) {
                model.deleteCustomLyrics()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(
                "This removes your saved Custom timing for \(model.activeTrack?.title ?? "this song"). "
                    + "Fetched lyrics and automatic audio sync records will not be affected."
            )
        }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.activeTrack?.title ?? "No Track Playing")
                    .font(.headline)
                    .lineLimit(1)
                if let artist = model.activeTrack?.artist, !artist.isEmpty {
                    Text(artist)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 12)

            if model.activeTrack != nil {
                HStack(spacing: 4) {
                    Button {
                        model.seek(to: 0)
                    } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .help("Restart from 0:00")

                    Button {
                        model.nudgePlayback(by: -5.0)
                    } label: {
                        Image(systemName: "gobackward.5")
                    }
                    .help("Back 5 seconds")

                    Button {
                        model.togglePlayPause()
                    } label: {
                        Image(systemName: state.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 14)
                    }
                    .help(state.isPlaying ? "Pause" : "Play")

                    Button {
                        model.nudgePlayback(by: 5.0)
                    } label: {
                        Image(systemName: "goforward.5")
                    }
                    .help("Forward 5 seconds")
                }

                TimelineView(.periodic(from: .now, by: 0.05)) { context in
                    Text(LyricTimingSession.formatTime(state.currentPlaybackPosition(at: context.date)))
                        .font(.system(.body, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                }

                Picker("Source", selection: Binding(
                    get: { model.selectedSource },
                    set: { model.selectSource($0) }
                )) {
                    ForEach(model.availableSources) { source in
                        Text(source.title).tag(source)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: model.hasCustomLyrics ? 230 : 165)
                .help("Per-song lyric source")
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - Stamping Bar

    private var stampingBar: some View {
        HStack(spacing: 10) {
            if model.session.stampingMode == .lines {
                Button {
                    model.session.stopStamping()
                } label: {
                    Label("Stop Line Pass", systemImage: "stop.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            } else {
                Button {
                    let startIndex = model.selectedLineIndex ?? 0
                    model.session.beginLinePass(from: startIndex)
                } label: {
                    Label("Stamp Lines (Space)", systemImage: "hand.tap")
                }
                .disabled(model.session.lines.isEmpty)
            }

            if case .words = model.session.stampingMode {
                Button {
                    model.session.stopStamping()
                } label: {
                    Label("Stop Word Pass", systemImage: "stop.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.orange)
            } else {
                Button {
                    if let idx = model.selectedLineIndex {
                        model.session.beginWordPass(forLine: idx)
                    }
                } label: {
                    Label("Stamp Words (Space)", systemImage: "character.cursor.ibeam")
                }
                .disabled(model.selectedLineIndex == nil)
            }

            Button {
                model.undoLastStamp()
            } label: {
                Label("Undo Stamp", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.session.canUndoStamp)

            Spacer()

            stampingStatusPill
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.bar)
    }

    @ViewBuilder
    private var stampingStatusPill: some View {
        switch model.session.stampingMode {
        case .off:
            Text("Editing mode — Space types normally")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .lines:
            if model.session.nextLineIndex < model.session.lines.count {
                Text("Press Space → Line \(model.session.nextLineIndex + 1)/\(model.session.lines.count)")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.orange)
            } else {
                Text("All lines stamped — click Stop or Save")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
            }
        case let .words(lineIndex):
            if model.session.lines.indices.contains(lineIndex) {
                let words = model.session.lines[lineIndex].words
                if model.session.nextWordIndex < words.count {
                    let nextText = words[model.session.nextWordIndex].text.trimmingCharacters(in: .whitespaces)
                    let romajiHint: String = {
                        guard state.romanizeJapanese else { return "" }
                        let previews = LyricTimingSession.romanizedWordPreviews(for: words)
                        let hint = previews.indices.contains(model.session.nextWordIndex)
                            ? previews[model.session.nextWordIndex]
                            : ""
                        return hint.isEmpty ? "" : " (\(hint))"
                    }()
                    Text("Press Space → Word \(model.session.nextWordIndex + 1)/\(words.count): \"\(nextText)\"\(romajiHint)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                } else {
                    Text("All words stamped for line \(lineIndex + 1)")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.green)
                }
            }
        }
    }

    private var outOfOrderBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("Some timestamps are out of order. Lines are kept in your order; adjust highlighted times if unintended.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.08))
    }

    // MARK: - Lines List

    private var linesListPane: some View {
        let outOfOrder = model.session.outOfOrderLineIndices()
        return VStack(spacing: 0) {
            HStack {
                Text("Lines (\(model.session.lines.count))")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Paste Plain Lyrics…") {
                    pasteBuffer = model.session.lines.map(\.text).joined(separator: "\n")
                    showPasteSheet = true
                }
                .controlSize(.small)
                Button {
                    let idx = model.session.addLine(after: model.selectedLineIndex)
                    model.selectedLineId = model.session.lines[idx].id
                } label: {
                    Label("Add Line", systemImage: "plus")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if model.session.lines.isEmpty {
                VStack(spacing: 10) {
                    Text("No lyrics loaded for this track.")
                        .foregroundStyle(.secondary)
                    Button("Paste Plain Lyrics…") {
                        pasteBuffer = ""
                        showPasteSheet = true
                    }
                    .buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    List {
                        ForEach(Array(model.session.lines.enumerated()), id: \.element.id) { index, line in
                            LineEditorRow(
                                index: index,
                                line: line,
                                romajiPreview: state.romanizeJapanese ? LyricTimingSession.romanizedPreview(forLine: line.text) : nil,
                                isSelected: model.selectedLineId == line.id,
                                isNextStamp: model.session.stampingMode == .lines && model.session.nextLineIndex == index,
                                isOutOfOrder: outOfOrder.contains(index),
                                canSeek: true,
                                onSelect: {
                                    model.selectedLineId = line.id
                                    if model.session.stampingMode == .lines {
                                        model.session.nextLineIndex = index
                                    }
                                },
                                onSeek: {
                                    if let ts = line.timestamp {
                                        model.seek(to: ts)
                                    }
                                },
                                onNudge: { delta in
                                    model.session.nudgeLine(at: index, by: delta)
                                },
                                onSetTime: { seconds in
                                    model.session.setLineTimestamp(at: index, to: seconds)
                                },
                                onEditText: { newText in
                                    model.session.updateLineText(at: index, to: newText)
                                },
                                onAddBelow: {
                                    let inserted = model.session.addLine(after: index)
                                    model.selectedLineId = model.session.lines[inserted].id
                                },
                                onDelete: {
                                    let wasSelected = model.selectedLineId == line.id
                                    model.session.deleteLine(at: index)
                                    if wasSelected {
                                        let nextIdx = min(index, max(0, model.session.lines.count - 1))
                                        model.selectedLineId = model.session.lines.indices.contains(nextIdx)
                                            ? model.session.lines[nextIdx].id
                                            : nil
                                    }
                                }
                            )
                            .id(line.id)
                            .listRowInsets(EdgeInsets(top: 4, leading: 8, bottom: 4, trailing: 8))
                        }
                    }
                    .listStyle(.inset)
                    .onChange(of: model.session.nextLineIndex) { nextIdx in
                        if model.session.stampingMode == .lines,
                           model.session.lines.indices.contains(nextIdx) {
                            withAnimation(.easeInOut(duration: 0.15)) {
                                proxy.scrollTo(model.session.lines[nextIdx].id, anchor: .center)
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Word Inspector

    private var wordInspectorPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Word Timing")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                if let idx = model.selectedLineIndex {
                    Button("Clear Words") {
                        model.session.clearWords(forLine: idx)
                    }
                    .controlSize(.small)
                    .disabled(model.session.lines[idx].words.isEmpty)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            if let idx = model.selectedLineIndex, model.session.lines.indices.contains(idx) {
                let line = model.session.lines[idx]
                let wordWarnings = model.session.outOfOrderWordIndices(inLine: idx)
                let isWordStampingThisLine = model.session.stampingMode == .words(lineIndex: idx)
                let wordRomaji = state.romanizeJapanese
                    ? LyricTimingSession.romanizedWordPreviews(for: line.words)
                    : Array(repeating: "", count: line.words.count)

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.text.isEmpty ? "(Empty line)" : line.text)
                            .font(.callout.weight(.medium))
                            .lineLimit(3)
                        if state.romanizeJapanese,
                           let romaji = LyricTimingSession.romanizedPreview(forLine: line.text) {
                            Text(romaji)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }
                    }

                    HStack(spacing: 8) {
                        Button(isWordStampingThisLine ? "Stop Word Pass" : "Start Word Pass") {
                            if isWordStampingThisLine {
                                model.session.stopStamping()
                            } else {
                                model.session.beginWordPass(forLine: idx)
                            }
                        }
                        .controlSize(.small)
                        .disabled(line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Stamp End") {
                            model.stampSelectedLineEndNow()
                        }
                        .controlSize(.small)
                        .help("Set optional end timestamp for this line at the current playback position")
                    }

                    HStack(spacing: 6) {
                        Text("End time:")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        TimestampField(
                            value: line.endTimestamp,
                            placeholder: "auto",
                            onCommit: { model.session.setLineEndTimestamp(at: idx, to: $0) }
                        )
                        .frame(width: 74)
                        if line.endTimestamp != nil {
                            Button("Auto") {
                                model.session.setLineEndTimestamp(at: idx, to: nil)
                            }
                            .controlSize(.mini)
                        }
                    }

                    Divider()

                    if line.words.isEmpty {
                        Text("No word timings yet. Click Start Word Pass and press Space as each word begins.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .padding(.top, 4)
                        Spacer()
                    } else {
                        List {
                            ForEach(Array(line.words.enumerated()), id: \.element.id) { wordIdx, word in
                                WordEditorRow(
                                    word: word,
                                    romajiPreview: wordRomaji.indices.contains(wordIdx) ? wordRomaji[wordIdx] : "",
                                    isNextStamp: isWordStampingThisLine && model.session.nextWordIndex == wordIdx,
                                    isOutOfOrder: wordWarnings.contains(wordIdx),
                                    onSelectForStamp: {
                                        if isWordStampingThisLine {
                                            model.session.nextWordIndex = wordIdx
                                        }
                                    },
                                    onNudge: { delta in
                                        model.session.nudgeWord(lineIndex: idx, wordIndex: wordIdx, by: delta)
                                    },
                                    onSetTime: { seconds in
                                        model.session.setWordTimestamp(lineIndex: idx, wordIndex: wordIdx, to: seconds)
                                    }
                                )
                                .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
                            }
                        }
                        .listStyle(.inset)
                    }
                }
                .padding(12)
            } else {
                Text("Select a line to inspect or stamp its words.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding()
            }
        }
    }

    // MARK: - Footer

    private var footerBar: some View {
        HStack(spacing: 10) {
            if model.hasCustomLyrics {
                Button("Delete Custom…", role: .destructive) {
                    showDeleteConfirmation = true
                }
            }

            if let message = model.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            Button("Save Custom") {
                model.saveCustomLyrics()
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.session.buildLyricLines().isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Empty & Paste Sheet

    private var emptyStateView: some View {
        VStack(spacing: 8) {
            Image(systemName: "music.note")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("Play a song in Spotify, Apple Music, or a supported browser to edit its lyric timing.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pasteLyricsSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Paste Plain Lyrics")
                .font(.headline)
            Text("One lyric line per line. Existing line timings in the editor will be cleared.")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextEditor(text: $pasteBuffer)
                .font(.body)
                .frame(minHeight: 260)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                )
            HStack {
                Spacer()
                Button("Cancel") {
                    showPasteSheet = false
                }
                Button("Load Lines") {
                    model.pastePlainLyrics(pasteBuffer)
                    showPasteSheet = false
                }
                .buttonStyle(.borderedProminent)
                .disabled(pasteBuffer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(16)
        .frame(width: 460, height: 380)
    }
}

private struct LineEditorRow: View {
    let index: Int
    let line: EditableLine
    let romajiPreview: String?
    let isSelected: Bool
    let isNextStamp: Bool
    let isOutOfOrder: Bool
    let canSeek: Bool
    let onSelect: () -> Void
    let onSeek: () -> Void
    let onNudge: (Double) -> Void
    let onSetTime: (Double?) -> Void
    let onEditText: (String) -> Void
    let onAddBelow: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: isNextStamp ? "arrowtriangle.right.fill" : "circle.fill")
                .font(.system(size: isNextStamp ? 10 : 5))
                .foregroundStyle(isNextStamp ? Color.orange : Color.clear)
                .frame(width: 12)

            Button(action: onSeek) {
                Image(systemName: "play.circle")
            }
            .buttonStyle(.borderless)
            .disabled(!canSeek || line.timestamp == nil)
            .help(canSeek ? "Seek player to this line" : "Click-to-seek is unavailable for browser tracks")

            Button("-0.1") { onNudge(-0.1) }
                .buttonStyle(.borderless)
                .font(.caption2.monospacedDigit())
                .disabled(line.timestamp == nil)

            TimestampField(
                value: line.timestamp,
                placeholder: "—",
                onCommit: onSetTime
            )
            .frame(width: 68)

            Button("+0.1") { onNudge(0.1) }
                .buttonStyle(.borderless)
                .font(.caption2.monospacedDigit())
                .disabled(line.timestamp == nil)

            if isOutOfOrder {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.yellow)
                    .help("Timestamp is earlier than a preceding line")
            }

            VStack(alignment: .leading, spacing: 1) {
                TextField("Lyric line", text: Binding(
                    get: { line.text },
                    set: { onEditText($0) }
                ))
                .textFieldStyle(.plain)

                if let romajiPreview, !romajiPreview.isEmpty {
                    Text(romajiPreview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            if !line.words.isEmpty {
                let stampedCount = line.words.filter { $0.timestamp != nil }.count
                Text("\(stampedCount)/\(line.words.count)w")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: Capsule())
            }

            Button(action: onAddBelow) {
                Image(systemName: "plus")
                    .font(.caption)
            }
            .buttonStyle(.borderless)
            .help("Insert line below")

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .help("Delete line")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isNextStamp ? Color.orange.opacity(0.16) : (isSelected ? Color.accentColor.opacity(0.14) : Color.clear))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelect()
            if canSeek, line.timestamp != nil {
                onSeek()
            }
        }
    }
}

private struct WordEditorRow: View {
    let word: EditableWord
    let romajiPreview: String
    let isNextStamp: Bool
    let isOutOfOrder: Bool
    let onSelectForStamp: () -> Void
    let onNudge: (Double) -> Void
    let onSetTime: (Double?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrowtriangle.right.fill")
                .font(.system(size: 9))
                .foregroundStyle(isNextStamp ? Color.orange : Color.clear)
                .frame(width: 10)

            VStack(alignment: .leading, spacing: 1) {
                Text(word.text.trimmingCharacters(in: .whitespaces))
                    .font(.callout)
                    .lineLimit(1)
                if !romajiPreview.isEmpty {
                    Text(romajiPreview)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if isOutOfOrder {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.yellow)
                    .help("Word timestamp is out of order")
            }

            Button("-0.1") { onNudge(-0.1) }
                .buttonStyle(.borderless)
                .font(.caption2.monospacedDigit())

            TimestampField(
                value: word.timestamp,
                placeholder: "—",
                onCommit: onSetTime
            )
            .frame(width: 64)

            Button("+0.1") { onNudge(0.1) }
                .buttonStyle(.borderless)
                .font(.caption2.monospacedDigit())
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(isNextStamp ? Color.orange.opacity(0.16) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            onSelectForStamp()
        }
    }
}

private struct TimestampField: View {
    let value: Double?
    let placeholder: String
    let onCommit: (Double?) -> Void
    @State private var text: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        TextField(placeholder, text: $text)
            .font(.system(.caption, design: .monospaced))
            .monospacedDigit()
            .textFieldStyle(.roundedBorder)
            .focused($isFocused)
            .onAppear {
                text = value.map { LyricTimingSession.formatTime($0) } ?? ""
            }
            .onChange(of: value) { newValue in
                if !isFocused {
                    text = newValue.map { LyricTimingSession.formatTime($0) } ?? ""
                }
            }
            .onSubmit {
                commit()
            }
            .onChange(of: isFocused) { focused in
                if !focused {
                    commit()
                }
            }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            onCommit(nil)
            return
        }
        if let parsed = LyricTimingSession.parseTime(trimmed) {
            onCommit(parsed)
            text = LyricTimingSession.formatTime(parsed)
        } else {
            text = value.map { LyricTimingSession.formatTime($0) } ?? ""
        }
    }
}

@MainActor
final class LyricTimingEditorWindowController: NSObject, NSWindowDelegate {
    private let state: LyricsState
    private let customLyricsStore: CustomLyricsStore
    private let onSeek: (Double) -> Void
    private let onTogglePlayPause: () -> Void
    private let onSelectSource: (TrackInfo, TrackLyricSource) -> Void
    private let onSaveCustom: (TrackInfo, [LyricLine]) -> Void
    private let onDeleteCustom: (TrackInfo) -> Void

    private var window: NSWindow?
    private var model: LyricTimingEditorModel?
    private var keyMonitor: Any?

    init(
        state: LyricsState,
        customLyricsStore: CustomLyricsStore,
        onSeek: @escaping (Double) -> Void,
        onTogglePlayPause: @escaping () -> Void,
        onSelectSource: @escaping (TrackInfo, TrackLyricSource) -> Void,
        onSaveCustom: @escaping (TrackInfo, [LyricLine]) -> Void,
        onDeleteCustom: @escaping (TrackInfo) -> Void
    ) {
        self.state = state
        self.customLyricsStore = customLyricsStore
        self.onSeek = onSeek
        self.onTogglePlayPause = onTogglePlayPause
        self.onSelectSource = onSelectSource
        self.onSaveCustom = onSaveCustom
        self.onDeleteCustom = onDeleteCustom
        super.init()
    }

    func show() {
        if let existing = window {
            model?.loadCurrentTrack()
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let editorModel = LyricTimingEditorModel(
            state: state,
            customLyricsStore: customLyricsStore,
            onSeek: onSeek,
            onTogglePlayPause: onTogglePlayPause,
            onSelectSource: onSelectSource,
            onSaveCustom: onSaveCustom,
            onDeleteCustom: onDeleteCustom
        )
        self.model = editorModel

        let hosting = NSHostingController(
            rootView: LyricTimingEditorView(state: state, model: editorModel)
        )
        let win = NSWindow(contentViewController: hosting)
        win.title = "Lyric Timing Editor"
        win.styleMask = [.titled, .closable, .resizable, .miniaturizable]
        win.setContentSize(NSSize(width: 780, height: 560))
        win.minSize = NSSize(width: 700, height: 520)
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win
        installKeyMonitor()
    }

    private func installKeyMonitor() {
        removeKeyMonitor()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self,
                  let win = self.window,
                  win.isKeyWindow,
                  let model = self.model,
                  model.session.stampingMode != .off,
                  event.keyCode == 49,
                  event.modifierFlags.isDisjoint(with: [.command, .control, .option])
            else {
                return event
            }
            model.stampNow()
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor {
            NSEvent.removeMonitor(keyMonitor)
            self.keyMonitor = nil
        }
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        model = nil
        window?.contentViewController = nil
        window = nil
    }
}
