import AppKit
import Combine
import SwiftUI

enum EditorLoopMode: Equatable {
    case off
    case line
    case song

    var next: EditorLoopMode {
        switch self {
        case .off: .line
        case .line: .song
        case .song: .off
        }
    }

    var symbolName: String {
        switch self {
        case .off, .song: "repeat"
        case .line: "repeat.1"
        }
    }

    var helpText: String {
        switch self {
        case .off: "Loop: Off (click to loop selected line)"
        case .line: "Loop: Selected Line (click to loop song)"
        case .song: "Loop: Song (click to turn off)"
        }
    }
}

extension EditableLine {
    var requiresDeletionConfirmation: Bool {
        timestamp != nil || endTimestamp != nil || words.contains { $0.timestamp != nil }
            || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

/// Isolated observable so high-frequency active-word updates never re-render `LyricTimingEditorView.body`.
@MainActor
final class EditorPlayingHighlight: ObservableObject {
    @Published var playingLineId: UUID?
    @Published var playingWordId: UUID?
}

@MainActor
final class LyricTimingEditorModel: ObservableObject {
    @Published var session: LyricTimingSession {
        didSet {
            if session.lines != oldValue.lines { draftRevision &+= 1 }
            refreshSessionDerivedState()
        }
    }
    @Published var selectedLineId: UUID? {
        didSet {
            if selectedLineId != oldValue {
                inFlightLoopSeek = nil
                seekToLineLoopStartIfOutsideRange()
            }
        }
    }
    @Published var activeTrack: TrackInfo?
    @Published var selectedSource: TrackLyricSource = .defaultSource
    @Published var hasCustomLyrics: Bool = false
    @Published var statusMessage: String?
    @Published var loopMode: EditorLoopMode = .off {
        didSet {
            if loopMode != oldValue {
                inFlightLoopSeek = nil
            }
            syncLoopTimer()
            if loopMode == .line, oldValue != .line {
                seekToLineLoopStartIfOutsideRange()
            }
        }
    }
    @Published var followPlayback: Bool = true
    @Published private(set) var pendingNewTrack: TrackInfo?
    @Published private(set) var isPlaying: Bool
    @Published private(set) var pausedPlaybackPosition: Double
    @Published private(set) var scrubPreviewPosition: Double?
    @Published private(set) var romanizeJapanese: Bool
    @Published private(set) var romanizeKorean: Bool
    @Published private(set) var romanizeChinese: Bool
    @Published private(set) var vocalEnvelopeVersion: UInt64 = 0
    let playingHighlight = EditorPlayingHighlight()
    var playingLineId: UUID? { playingHighlight.playingLineId }
    var playingWordId: UUID? { playingHighlight.playingWordId }
    private(set) var nextLaterByStart: [Double: Double] = [:]
    private(set) var nextWordStartsByLineId: [UUID: [Double?]] = [:]
    private(set) var maxLineEnd: Double = 0.0
    private var preferChineseForHan: Bool = false

    private let state: LyricsState
    private let loadCustomRecord: @Sendable (String) -> CustomLyricsRecord?
    private let loadRetainedLines: @Sendable (String, TrackLyricSource) -> [LyricLine]
    private let onSeek: (String, Double) -> Void
    private let onTogglePlayPause: (String) -> Void
    private let onPreviousTrack: (String) -> Void
    private let onNextTrack: (String) -> Void
    private let onSelectSource: (TrackInfo, TrackLyricSource, [LyricLine]?) -> [LyricLine]
    private let onSaveCustom: (TrackInfo, [LyricLine], Set<Int>) throws -> Void
    private let onDeleteCustom: (TrackInfo) throws -> [LyricLine]
    private let vocalEnvelopeProvider: (String?) -> VocalEnvelope?
    private var baselineLines: [EditableLine] = []
    private var loadedRawLines: [LyricLine] = []
    private var appliedSource: TrackLyricSource = .defaultSource
    private var draftRevision: UInt64 = 0
    private(set) var customRecordLoad: Task<Void, Never>?
    private var cachedCustomRecord: (trackId: String, record: CustomLyricsRecord?)?
    private var lineRomajiCache: [String: String?] = [:]
    private var wordRomajiCache: [[String]: [String]] = [:]
    private var lineWordSpanCache: [UUID: (texts: [String], spans: [LyricTimingSession.DisplayWordSpan])] = [:]
    private var previewBoundaryCache: [UUID: (pieces: [String], fractions: [Double])] = [:]
    private var rtlPreviewCache: [String: Bool] = [:]
    private struct InFlightLoopSeek {
        let target: Double
        let issuedAt: Date
        let anchorDateAtIssue: Date
    }

    private static let loopSeekRetryTimeout: TimeInterval = 1.0

    private var lastPlayingPosition: Double = 0.0
    private var lastLoopSeekDate: Date = .distantPast
    private var inFlightLoopSeek: InFlightLoopSeek?
    private var loopTimer: Timer?
    private var activeFieldEditCount = 0
    private var isTimelineDragging = false
    private var isCommittingSave = false
    private var pendingAutomaticRefresh = false
    private var isRefreshingSessionState = false
    private var cancellables = Set<AnyCancellable>()

    deinit {
        loopTimer?.invalidate()
    }

    func stopLoopTimer() {
        loopTimer?.invalidate()
        loopTimer = nil
        inFlightLoopSeek = nil
    }

    func tearDown() {
        stopLoopTimer()
        customRecordLoad?.cancel()
        customRecordLoad = nil
    }

    var loopPollingInterval: TimeInterval? { loopTimer?.timeInterval }

    private var loopPlaybackRate: Double {
        state.playbackRate.isFinite && state.playbackRate > 0 ? state.playbackRate : 1
    }

    private func syncLoopTimer() {
        let shouldRun = loopMode != .off && isPlaying
        if !shouldRun {
            stopLoopTimer()
            return
        }
        let trackInterval: TimeInterval = state.lowCPUMode ? 0.20 : 0.10
        let desiredInterval = loopMode == .line ? trackInterval / max(1, loopPlaybackRate) : trackInterval
        if loopPollingInterval == desiredInterval {
            return
        }
        stopLoopTimer()
        loopTimer = Timer.scheduledTimer(withTimeInterval: desiredInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.checkLoop(at: self.currentEditorPlaybackPosition())
            }
        }
    }

    var hasUnsavedEdits: Bool {
        session.lines != baselineLines
    }

    var hasPendingChanges: Bool {
        hasUnsavedEdits || isEditingField
    }

    var isEditingField: Bool { activeFieldEditCount > 0 }

    var canStampNow: Bool {
        pendingNewTrack == nil
            && !isEditingField
            && !isTimelineDragging
            && scrubPreviewPosition == nil
            && session.stampingMode != .off
    }

    var canStampSelectedLineEnd: Bool {
        guard let track = activeTrack,
              selectedLineIndex != nil,
              pendingNewTrack == nil,
              state.currentTrack == nil || state.currentTrack?.id == track.id
        else { return false }
        return true
    }

    func beginFieldEdit() {
        activeFieldEditCount += 1
    }

    func endFieldEdit() {
        activeFieldEditCount = max(0, activeFieldEditCount - 1)
        if pendingAutomaticRefresh {
            applyAutomaticRefreshIfEligible()
        }
    }

    func beginTimelineDrag() {
        isTimelineDragging = true
    }

    func endTimelineDrag() {
        isTimelineDragging = false
        if pendingAutomaticRefresh {
            applyAutomaticRefreshIfEligible()
        }
    }

    private func refreshSessionDerivedState() {
        let lookup = LyricTimingSession.nextLaterStartLookup(for: session.lines)
        nextLaterByStart = lookup
        var wordStartsByLine: [UUID: [Double?]] = [:]
        wordStartsByLine.reserveCapacity(session.lines.count)
        var maxEnd = 0.0
        for line in session.lines {
            if !line.words.isEmpty {
                wordStartsByLine[line.id] = LyricTimingSession.nextWordStarts(for: line.words)
            }
            guard let start = line.timestamp else { continue }
            let end = LyricTimingSession.derivedLineEnd(
                for: line,
                nextLaterStart: lookup[start],
                fallbackDuration: TimelineLayoutMath.finalLineFallbackDuration
            ) ?? (start + TimelineLayoutMath.finalLineFallbackDuration)
            if end > maxEnd { maxEnd = end }
        }
        nextWordStartsByLineId = wordStartsByLine
        maxLineEnd = maxEnd
        if !isRefreshingSessionState {
            isRefreshingSessionState = true
            if pendingAutomaticRefresh {
                applyAutomaticRefreshIfEligible()
            }
            syncPlayingHighlight(at: currentEditorPlaybackPosition(), recordPlaybackPosition: false)
            isRefreshingSessionState = false
        }
    }

    private func applyAutomaticRefreshIfEligible() {
        // The pending load resolves against the latest lyrics and engine setting. Starting another
        // refresh here could cancel a source switch before its choice is persisted.
        guard !isCommittingSave, customRecordLoad == nil else { return }
        guard let currentTrack = state.currentTrack,
              currentTrack.id == activeTrack?.id
        else {
            pendingAutomaticRefresh = false
            return
        }
        // Keep the refresh pending while the user has unsaved edits or an active edit/pass so
        // undoing back to the baseline still picks up an audio-sync update that arrived in between.
        if isEditingField || isTimelineDragging || session.stampingMode != .off || hasUnsavedEdits {
            pendingAutomaticRefresh = true
            return
        }
        pendingAutomaticRefresh = false
        let effectiveSource = LyricSourceResolver.effectiveSource(
            choice: state.lyricSourceChoice(for: currentTrack.id),
            hasCustomLyrics: hasCustomLyrics,
            audioSyncEngine: state.audioSyncEngine
        )
        let sourceChanged = effectiveSource != selectedSource
        let rawLinesChanged = state.rawLyricLines != loadedRawLines
        if sourceChanged || (rawLinesChanged && !state.rawLyricLines.isEmpty && (session.lines.isEmpty || effectiveSource != .custom)) {
            loadCurrentTrack()
        }
    }

    init(
        state: LyricsState,
        customLyricsStore: CustomLyricsStore,
        loadCustomRecord: (@Sendable (String) -> CustomLyricsRecord?)? = nil,
        loadRetainedLines: (@Sendable (String, TrackLyricSource) -> [LyricLine])? = nil,
        onSeek: @escaping (String, Double) -> Void,
        onTogglePlayPause: @escaping (String) -> Void,
        onPreviousTrack: @escaping (String) -> Void = { _ in },
        onNextTrack: @escaping (String) -> Void = { _ in },
        onSelectSource: @escaping (TrackInfo, TrackLyricSource, [LyricLine]?) -> [LyricLine],
        onSaveCustom: @escaping (TrackInfo, [LyricLine], Set<Int>) throws -> Void,
        onDeleteCustom: @escaping (TrackInfo) throws -> [LyricLine],
        vocalEnvelopeProvider: @escaping (String?) -> VocalEnvelope? = { _ in nil },
        vocalEnvelopeDidChange: AnyPublisher<String, Never> = Empty().eraseToAnyPublisher()
    ) {
        self.state = state
        self.loadCustomRecord = loadCustomRecord ?? { customLyricsStore.load(trackId: $0) }
        self.loadRetainedLines = loadRetainedLines ?? { AppDelegate.loadRetainedTrackLines(trackId: $0, source: $1) }
        self.onSeek = onSeek
        self.onTogglePlayPause = onTogglePlayPause
        self.onPreviousTrack = onPreviousTrack
        self.onNextTrack = onNextTrack
        self.onSelectSource = onSelectSource
        self.onSaveCustom = onSaveCustom
        self.onDeleteCustom = onDeleteCustom
        self.vocalEnvelopeProvider = vocalEnvelopeProvider
        self.isPlaying = state.isPlaying
        self.pausedPlaybackPosition = state.currentPlaybackPosition()
        self.romanizeJapanese = state.romanizeJapanese
        self.romanizeKorean = state.romanizeKorean
        self.romanizeChinese = state.romanizeChinese
        self.session = LyricTimingSession(lines: [])
        loadCurrentTrack()

        state.$playbackRate.combineLatest(state.$lowCPUMode)
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncLoopTimer() }
            .store(in: &cancellables)

        state.$currentTrack
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] newTrack in
                guard let self else { return }
                guard let newTrack else {
                    // Clear any pending switch banner when playback goes idle while preserving the active draft.
                    self.pendingNewTrack = nil
                    return
                }
                if newTrack.id == self.activeTrack?.id {
                    self.pendingNewTrack = nil
                    self.isPlaying = self.state.isPlaying
                    self.syncLoopTimer()
                    return
                }
                if self.hasPendingChanges {
                    // Always preserve unsaved drafts when playback changes; freeze the draft at its own
                    // last playing position and stop any active live stamping pass until the user switches tracks.
                    if self.pendingNewTrack == nil {
                        self.pausedPlaybackPosition = self.lastPlayingPosition
                        self.isPlaying = false
                        self.syncLoopTimer()
                    }
                    if self.session.stampingMode != .off {
                        self.session.stopStamping()
                    }
                    self.pendingNewTrack = newTrack
                    return
                }
                self.pendingNewTrack = nil
                self.loadCurrentTrack()
            }
            .store(in: &cancellables)

        state.rawLinesDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in
                self?.applyAutomaticRefreshIfEligible()
            }
            .store(in: &cancellables)

        state.$audioSyncEngine
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.applyAutomaticRefreshIfEligible()
            }
            .store(in: &cancellables)

        state.$isPlaying
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] playing in
                guard let self else { return }
                guard self.pendingNewTrack == nil else { return }
                self.isPlaying = playing
                self.syncLoopTimer()
                if !playing {
                    if self.state.currentTrack?.id == self.activeTrack?.id {
                        let pos = self.state.currentPlaybackPosition()
                        self.pausedPlaybackPosition = pos
                        self.lastPlayingPosition = pos
                        if self.scrubPreviewPosition == nil {
                            self.syncPlayingHighlight(at: pos, recordPlaybackPosition: false)
                        }
                    } else if self.lastPlayingPosition > 0 {
                        self.pausedPlaybackPosition = self.lastPlayingPosition
                    }
                }
            }
            .store(in: &cancellables)

        state.pausedPositionDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] pos in
                guard let self,
                      !self.state.isPlaying,
                      self.state.currentTrack?.id == self.activeTrack?.id
                else { return }
                if self.pausedPlaybackPosition != pos {
                    self.pausedPlaybackPosition = pos
                }
                self.lastPlayingPosition = pos
                if self.scrubPreviewPosition == nil {
                    self.syncPlayingHighlight(at: pos, recordPlaybackPosition: false)
                }
            }
            .store(in: &cancellables)

        state.$romanizeJapanese
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] romanize in
                guard let self else { return }
                self.romanizeJapanese = romanize
                self.clearRomajiCaches()
            }
            .store(in: &cancellables)

        state.$romanizeKorean
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] romanize in
                guard let self else { return }
                self.romanizeKorean = romanize
                self.clearRomajiCaches()
            }
            .store(in: &cancellables)

        state.$romanizeChinese
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] romanize in
                guard let self else { return }
                self.romanizeChinese = romanize
                self.clearRomajiCaches()
            }
            .store(in: &cancellables)

        vocalEnvelopeDidChange
            .receive(on: RunLoop.main)
            .sink { [weak self] trackId in
                guard let self, trackId == self.activeTrack?.id else { return }
                self.vocalEnvelopeVersion &+= 1
            }
            .store(in: &cancellables)
    }

    private func clearRomajiCaches() {
        lineRomajiCache.removeAll()
        wordRomajiCache.removeAll()
        lineWordSpanCache.removeAll()
        previewBoundaryCache.removeAll()
        rtlPreviewCache.removeAll()
    }

    private func refreshPreviewLanguage(for lines: [LyricLine]? = nil) {
        let sourceLines = lines ?? session.lines.enumerated().map { idx, line in
            LyricLine(id: idx, timestamp: line.timestamp ?? 0, text: line.text)
        }
        let nextPrefer = ChineseRomanizer.isChineseTrack(sourceLines)
        if preferChineseForHan != nextPrefer {
            preferChineseForHan = nextPrefer
            clearRomajiCaches()
        }
    }

    func currentEditorPlaybackPosition(at now: Date = Date()) -> Double {
        if let scrubPreviewPosition {
            return scrubPreviewPosition
        }
        if isPlaying, state.currentTrack?.id == activeTrack?.id {
            return state.currentPlaybackPosition(at: now)
        }
        return pausedPlaybackPosition
    }

    /// Clamps seeks that would cross past the end of the active track/chapter so dragging past the
    /// padded timeline edge cannot advance to the next track/chapter and discard unsaved edits,
    /// while keeping all valid in-range targets (`0 ..< duration`) reachable verbatim.
    func clampedSeekPosition(_ seconds: Double) -> Double {
        let nonNegative = max(0.0, seconds)
        if let duration = activeTrack?.duration, duration.isFinite, duration > 0, nonNegative >= duration {
            return max(0.0, duration - 0.5)
        }
        return nonNegative
    }

    var hasAnyRomanizationEnabled: Bool {
        romanizeJapanese || romanizeKorean || romanizeChinese
    }

    func romanizedLinePreview(for text: String) -> String? {
        guard hasAnyRomanizationEnabled else { return nil }
        if let cached = lineRomajiCache[text] {
            return cached
        }
        let preview = LyricTimingSession.romanizedPreview(
            forLine: text,
            japanese: romanizeJapanese,
            korean: romanizeKorean,
            chinese: romanizeChinese,
            preferChineseForHan: preferChineseForHan
        )
        lineRomajiCache[text] = preview
        return preview
    }

    func romanizedWordPreviews(for words: [EditableWord]) -> [String] {
        guard hasAnyRomanizationEnabled else {
            return Array(repeating: "", count: words.count)
        }
        let key = words.map(\.text)
        if let cached = wordRomajiCache[key] {
            return cached
        }
        let previews = LyricTimingSession.romanizedWordPreviews(
            for: words,
            japanese: romanizeJapanese,
            korean: romanizeKorean,
            chinese: romanizeChinese,
            preferChineseForHan: preferChineseForHan
        )
        wordRomajiCache[key] = previews
        return previews
    }

    func displayWordSpans(for line: EditableLine) -> [LyricTimingSession.DisplayWordSpan] {
        let words = line.words
        if let cached = lineWordSpanCache[line.id], cached.texts.count == words.count {
            var matches = true
            for idx in words.indices where cached.texts[idx] != words[idx].text {
                matches = false
                break
            }
            if matches {
                return cached.spans
            }
        }
        let spans = LyricTimingSession.displayWordSpans(
            for: words,
            japanese: romanizeJapanese,
            korean: romanizeKorean,
            chinese: romanizeChinese,
            preferChineseForHan: preferChineseForHan
        )
        lineWordSpanCache[line.id] = (words.map(\.text), spans)
        return spans
    }

    static let previewFontSize: CGFloat = 11.0

    /// Measured cumulative width fractions (`0...1`) for `pieces` rendered in the karaoke preview font,
    /// cached per line so proportional fonts (e.g. `WWW iii`) sweep accurately without per-frame CoreText calls.
    func previewWordBoundaries(for lineId: UUID, pieces: [String]) -> [Double] {
        if let cached = previewBoundaryCache[lineId], cached.pieces == pieces {
            return cached.fractions
        }
        let fractions = Self.measureWordBoundaries(pieces: pieces)
        previewBoundaryCache[lineId] = (pieces, fractions)
        return fractions
    }

    static func wordsCoverFullLineText(_ line: EditableLine) -> Bool {
        guard !line.words.isEmpty else { return false }
        let joined = line.words.map(\.text).joined()
        return joined == line.text
            || joined.trimmingCharacters(in: .whitespacesAndNewlines) == line.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hasCompleteTimedWords(_ line: EditableLine) -> Bool {
        guard wordsCoverFullLineText(line) else { return false }
        return line.words.allSatisfy { word in
            word.timestamp != nil || word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    static func measureWordBoundaries(pieces: [String]) -> [Double] {
        guard !pieces.isEmpty else { return [0.0] }
        let fullText = pieces.joined()
        let font = NSFont.systemFont(ofSize: previewFontSize, weight: .medium)
        let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: fullText, attributes: [.font: font]))
        let totalWidth = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
        guard totalWidth > 0 else {
            let weights = pieces.map { max(1.0, Double($0.count)) }
            let sum = max(1.0, weights.reduce(0, +))
            var fallback = [0.0]
            var acc = 0.0
            for w in weights {
                acc += w
                fallback.append(acc / sum)
            }
            return fallback
        }
        let fullLength = (fullText as NSString).length
        let originX = Double(CTLineGetOffsetForStringIndex(ctLine, 0, nil))
        let endX = Double(CTLineGetOffsetForStringIndex(ctLine, fullLength, nil))
        let span = abs(endX - originX)
        let denom = span > 0 ? span : totalWidth
        var fractions: [Double] = [0.0]
        fractions.reserveCapacity(pieces.count + 1)
        var utf16Offset = 0
        for (idx, piece) in pieces.enumerated() {
            utf16Offset += (piece as NSString).length
            let clamped = min(fullLength, max(0, utf16Offset))
            if idx == pieces.count - 1 {
                fractions.append(1.0)
                continue
            }
            let x = Double(CTLineGetOffsetForStringIndex(ctLine, clamped, nil))
            // Advance from the line's leading edge so RTL lines progress 0 -> 1 from right to left.
            let rawFrac = abs(x - originX) / denom
            let frac = min(1.0, max(fractions[fractions.count - 1], rawFrac))
            fractions.append(frac)
        }
        return fractions
    }

    func isRightToLeftPreview(for text: String) -> Bool {
        if let cached = rtlPreviewCache[text] { return cached }
        let rtl = Self.isRightToLeftLine(text)
        rtlPreviewCache[text] = rtl
        return rtl
    }

    static func isRightToLeftLine(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let font = NSFont.systemFont(ofSize: previewFontSize, weight: .medium)
        let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let length = (text as NSString).length
        let originX = CTLineGetOffsetForStringIndex(ctLine, 0, nil)
        let endX = CTLineGetOffsetForStringIndex(ctLine, length, nil)
        return endX < originX
    }

    var currentVocalEnvelope: VocalEnvelope? {
        vocalEnvelopeProvider(activeTrack?.id)
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
        let sameTrack = activeTrack?.id == track.id
        let previousIndex = sameTrack ? selectedLineIndex : nil

        activeTrack = track
        pendingNewTrack = nil
        isPlaying = state.isPlaying
        if !sameTrack {
            let currentPos = state.currentPlaybackPosition()
            pausedPlaybackPosition = currentPos
            lastPlayingPosition = currentPos
        }
        syncLoopTimer()
        statusMessage = nil
        clearRomajiCaches()

        let choice = state.lyricSourceChoice(for: track.id)
        let rawLines = state.rawLyricLines
        selectedSource = LyricSourceResolver.effectiveSource(
            choice: choice,
            hasCustomLyrics: choice == .custom,
            audioSyncEngine: state.audioSyncEngine
        )
        if !sameTrack {
            appliedSource = selectedSource
        }
        withCustomRecord(
            for: track,
            source: selectedSource,
            clearSessionBeforeLoad: !sameTrack
        ) { model, record in
            guard model.state.currentTrack == nil || model.state.currentTrack?.id == track.id,
                  model.state.lyricSourceChoice(for: track.id) == choice
            else { return }
            let resolved = LyricSourceResolver.effectiveSource(
                choice: choice,
                hasCustomLyrics: record != nil,
                audioSyncEngine: model.state.audioSyncEngine
            )
            model.selectedSource = resolved
            model.appliedSource = resolved
            let currentLines = model.state.currentTrack?.id == track.id ? model.state.rawLyricLines : rawLines
            let lines = currentLines.isEmpty && model.selectedSource == .custom ? record?.lines ?? [] : currentLines
            let explicitEnds = model.selectedSource == .custom ? record?.explicitEndLineIndices : nil
            model.installLines(lines, explicitEnds: explicitEnds, selectedIndex: previousIndex)
            let pos = model.currentEditorPlaybackPosition()
            if !sameTrack {
                model.lastPlayingPosition = pos
            }
            model.syncPlayingHighlight(at: pos, recordPlaybackPosition: false)
        }
    }

    private func installLines(_ lines: [LyricLine], explicitEnds: Set<Int>?, selectedIndex: Int? = nil) {
        pendingAutomaticRefresh = false
        preferChineseForHan = ChineseRomanizer.isChineseTrack(lines)
        loadedRawLines = state.rawLyricLines
        session = LyricTimingSession(lines: lines, explicitEndIndices: explicitEnds)
        baselineLines = session.lines
        if let selectedIndex, session.lines.indices.contains(selectedIndex) {
            selectedLineId = session.lines[selectedIndex].id
        } else {
            selectedLineId = session.lines.first?.id
        }
    }

    private func withCustomRecord(
        for track: TrackInfo,
        source: TrackLyricSource,
        clearSessionBeforeLoad: Bool = true,
        onEditCancelled: ((LyricTimingEditorModel) -> Void)? = nil,
        apply: @escaping (LyricTimingEditorModel, CustomLyricsRecord?) -> Void
    ) {
        customRecordLoad?.cancel()
        customRecordLoad = nil
        if let cached = cachedCustomRecord, cached.trackId == track.id {
            hasCustomLyrics = cached.record != nil
            apply(self, cached.record)
            return
        }

        // Only clear the previous track's session on track switch; keep existing rows intact during a
        // same-track source switch so cancelling on an intervening edit never destroys the user's draft.
        if clearSessionBeforeLoad {
            installLines([], explicitEnds: nil)
            loadedRawLines = []
        }
        let requestRevision = draftRevision
        hasCustomLyrics = false
        customRecordLoad = Task { [weak self, loadCustomRecord] in
            let record = await Task.detached { loadCustomRecord(track.id) }.value
            guard let self, !Task.isCancelled else { return }
            customRecordLoad = nil
            guard activeTrack?.id == track.id, selectedSource == source else { return }
            // Keep overwrite detection accurate even when a new edit prevents replacing the draft.
            cachedCustomRecord = (track.id, record)
            hasCustomLyrics = record != nil
            let editedDuringLoad = draftRevision != requestRevision
            if editedDuringLoad || (clearSessionBeforeLoad && hasUnsavedEdits) {
                onEditCancelled?(self)
                return
            }
            if isEditingField || isTimelineDragging || session.stampingMode != .off {
                if let onEditCancelled {
                    onEditCancelled(self)
                } else {
                    pendingAutomaticRefresh = true
                }
                return
            }
            apply(self, record)
        }
    }

    /// Replaces the current draft only if both the draft and destination tracks still match what the
    /// user confirmed in the destructive dialog.
    @discardableResult
    func loadConfirmedTrack(expectedDraftId: String, expectedDestinationId: String) -> Bool {
        guard activeTrack?.id == expectedDraftId,
              pendingNewTrack?.id == expectedDestinationId,
              state.currentTrack?.id == expectedDestinationId
        else { return false }
        loadCurrentTrack()
        return true
    }

    func selectSource(_ source: TrackLyricSource) {
        guard let track = activeTrack else { return }
        let restoreSource = appliedSource
        selectedSource = source
        clearRomajiCaches()
        let onEditCancelled: (LyricTimingEditorModel) -> Void = { model in
            model.selectedSource = restoreSource
            model.statusMessage = "Kept your edits without switching to \(source.title)."
        }

        // Retained drafts load Automatic/Default caches from disk; keep those reads off the main actor,
        // and keep current rows intact until the replacement is ready so intervening edits survive cancellation.
        let isRetainedTrack = state.currentTrack?.id != track.id
        if isRetainedTrack, source != .custom {
            customRecordLoad?.cancel()
            customRecordLoad = nil
            let requestRevision = draftRevision
            let cachedRecordForTrack = cachedCustomRecord?.trackId == track.id ? cachedCustomRecord?.record : nil
            let needsCustomCheck = cachedCustomRecord?.trackId != track.id
            if needsCustomCheck {
                hasCustomLyrics = false
            }
            customRecordLoad = Task { [weak self, loadCustomRecord, loadRetainedLines] in
                let loaded: (record: CustomLyricsRecord?, lines: [LyricLine]) = await Task.detached {
                    let record = needsCustomCheck ? loadCustomRecord(track.id) : cachedRecordForTrack
                    let lines = loadRetainedLines(track.id, source)
                    return (record, lines)
                }.value
                guard let self, !Task.isCancelled else { return }
                customRecordLoad = nil
                guard activeTrack?.id == track.id, selectedSource == source else { return }
                if needsCustomCheck {
                    cachedCustomRecord = (track.id, loaded.record)
                    hasCustomLyrics = loaded.record != nil
                }
                guard draftRevision == requestRevision,
                      !isEditingField,
                      !isTimelineDragging,
                      session.stampingMode == .off
                else {
                    onEditCancelled(self)
                    return
                }
                let lines = onSelectSource(track, source, loaded.lines)
                appliedSource = source
                installLines(lines, explicitEnds: nil)
                statusMessage = "Switched to \(source.title)."
            }
            return
        }

        withCustomRecord(
            for: track,
            source: source,
            clearSessionBeforeLoad: false,
            onEditCancelled: onEditCancelled
        ) { model, record in
            let lines = model.onSelectSource(track, source, source == .custom ? record?.lines : nil)
            if source == .custom, record == nil {
                model.selectedSource = LyricSourceResolver.effectiveSource(
                    choice: source,
                    hasCustomLyrics: false,
                    audioSyncEngine: model.state.audioSyncEngine
                )
            }
            model.appliedSource = model.selectedSource
            let explicitEnds = model.selectedSource == .custom ? record?.explicitEndLineIndices : nil
            model.installLines(lines, explicitEnds: explicitEnds)
            model.statusMessage = "Switched to \(model.selectedSource.title)."
        }
    }

    func togglePlayPause() {
        guard let track = activeTrack else { return }
        onTogglePlayPause(track.id)
    }

    func previousTrack(expectedTrackId: String? = nil) {
        guard pendingNewTrack == nil,
              let targetId = expectedTrackId ?? activeTrack?.id,
              activeTrack?.id == targetId,
              state.currentTrack == nil || state.currentTrack?.id == targetId
        else { return }
        onPreviousTrack(targetId)
    }

    func nextTrack(expectedTrackId: String? = nil) {
        guard pendingNewTrack == nil,
              let targetId = expectedTrackId ?? activeTrack?.id,
              activeTrack?.id == targetId,
              state.currentTrack == nil || state.currentTrack?.id == targetId
        else { return }
        onNextTrack(targetId)
    }

    func cycleLoopMode() {
        loopMode = loopMode.next
    }

    private func issueLoopSeek(to target: Double, now: Date) {
        let anchorDate = state.playbackAnchorDate
        guard seek(to: target) else { return }
        lastLoopSeekDate = now
        inFlightLoopSeek = InFlightLoopSeek(target: target, issuedAt: now, anchorDateAtIssue: anchorDate)
    }

    private func seekToLineLoopStartIfOutsideRange() {
        guard loopMode == .line,
              isPlaying,
              scrubPreviewPosition == nil,
              let range = activeLoopRange()
        else { return }
        let pos = currentEditorPlaybackPosition()
        if pos < range.lowerBound || pos >= range.upperBound {
            issueLoopSeek(to: range.lowerBound, now: Date())
        }
    }

    /// Track-time margin before track/chapter end so the wall-clock loop timer can seek back before
    /// the player advances even at elevated browser playback rates (up to 4x).
    private func trackEndSafetyMargin() -> Double {
        0.6 * max(1, loopPlaybackRate)
    }

    func activeLoopRange() -> ClosedRange<Double>? {
        let fallback = TimelineLayoutMath.finalLineFallbackDuration
        switch loopMode {
        case .off:
            return nil
        case .line:
            guard let idx = selectedLineIndex,
                  session.lines.indices.contains(idx),
                  let start = session.lines[idx].timestamp
            else { return nil }
            let nextLater = nextLaterByStart[start]
            let derived = LyricTimingSession.derivedLineEnd(
                for: session.lines[idx],
                nextLaterStart: nextLater,
                fallbackDuration: fallback
            ) ?? (start + fallback)
            guard derived > start else { return nil }
            let rawEnd = derived
            if let duration = activeTrack?.duration, duration.isFinite, duration > 1.0 {
                let safeUpper = duration - trackEndSafetyMargin()
                guard safeUpper >= 0.5, start < safeUpper else { return nil }
                return start...min(rawEnd, safeUpper)
            }
            return start...rawEnd
        case .song:
            let duration = activeTrack?.duration ?? 0
            guard duration > 1.0 else { return nil }
            let safeUpper = duration - trackEndSafetyMargin()
            guard safeUpper >= 0.5 else { return nil }
            return 0.0...safeUpper
        }
    }

    func checkLoop(at position: Double, now: Date = Date()) {
        guard isPlaying,
              scrubPreviewPosition == nil,
              let range = activeLoopRange()
        else { return }
        let outOfRange = (loopMode == .line && position < range.lowerBound - 0.5) || position >= range.upperBound
        if let inFlight = inFlightLoopSeek {
            let anchorInRange = state.playbackAnchorPosition < range.upperBound
                && (loopMode != .line || state.playbackAnchorPosition >= range.lowerBound - 0.5)
            let acknowledged = !outOfRange
                || (state.playbackAnchorDate != inFlight.anchorDateAtIssue && anchorInRange)
            let timedOut = now.timeIntervalSince(inFlight.issuedAt) >= Self.loopSeekRetryTimeout
            if acknowledged || timedOut {
                inFlightLoopSeek = nil
            } else {
                return
            }
        }
        guard outOfRange else { return }
        let rate = loopPlaybackRate
        let loopWallDuration = max(0.0, (range.upperBound - range.lowerBound) / rate)
        let cooldown = min(0.45, max(0.08 / max(1, rate), loopWallDuration * 0.5))
        guard now.timeIntervalSince(lastLoopSeekDate) >= cooldown else { return }
        issueLoopSeek(to: range.lowerBound, now: now)
    }

    func syncPlayingHighlight(at pos: Double, recordPlaybackPosition: Bool = true) {
        let lines = session.lines
        var activeIdx: Int?
        var bestTimestamp = -Double.infinity
        for idx in lines.indices {
            guard let ts = lines[idx].timestamp, ts <= pos, ts >= bestTimestamp else { continue }
            bestTimestamp = ts
            activeIdx = idx
        }

        let resolvedLineId: UUID?
        let resolvedWordId: UUID?
        if let idx = activeIdx, let start = lines[idx].timestamp {
            let line = lines[idx]
            let nextStart = nextLaterByStart[start]
            let derivedEnd = LyricTimingSession.derivedLineEnd(
                for: line,
                nextLaterStart: nextStart,
                fallbackDuration: TimelineLayoutMath.finalLineFallbackDuration
            ) ?? (start + TimelineLayoutMath.finalLineFallbackDuration)
            let displayEnd = max(start + 0.3, derivedEnd)
            if pos <= displayEnd + 0.5 {
                resolvedLineId = line.id
                let nextWordStarts = nextWordStartsByLineId[line.id] ?? LyricTimingSession.nextWordStarts(for: line.words)
                var activeWordId: UUID?
                var bestWordTs = -Double.infinity
                for (wordIdx, word) in line.words.enumerated() {
                    guard let wts = word.timestamp, wts <= pos else { continue }
                    let nextWordStart = nextWordStarts.indices.contains(wordIdx) ? nextWordStarts[wordIdx] : nil
                    let wordDur = TimelineLayoutMath.wordDuration(
                        word: word,
                        wordStart: wts,
                        nextWordStart: nextWordStart,
                        lineEnd: derivedEnd
                    )
                    guard pos <= wts + wordDur, wts >= bestWordTs else { continue }
                    bestWordTs = wts
                    activeWordId = word.id
                }
                resolvedWordId = activeWordId
            } else {
                resolvedLineId = nil
                resolvedWordId = nil
            }
        } else {
            resolvedLineId = nil
            resolvedWordId = nil
        }

        if recordPlaybackPosition, isPlaying, scrubPreviewPosition == nil {
            lastPlayingPosition = pos
        }
        if playingHighlight.playingLineId != resolvedLineId {
            playingHighlight.playingLineId = resolvedLineId
        }
        if playingHighlight.playingWordId != resolvedWordId {
            playingHighlight.playingWordId = resolvedWordId
        }
        if followPlayback, isPlaying, session.stampingMode == .off, loopMode != .line, !isEditingField, !isTimelineDragging,
           let resolvedLineId, selectedLineId != resolvedLineId {
            selectedLineId = resolvedLineId
        }
    }

    func previewScrub(to seconds: Double) {
        let clamped = clampedSeekPosition(seconds)
        scrubPreviewPosition = clamped
        syncPlayingHighlight(at: clamped, recordPlaybackPosition: false)
    }

    func endScrub(commit: Bool) {
        let target = scrubPreviewPosition
        scrubPreviewPosition = nil
        guard let target else { return }
        if commit, seek(to: target) { return }
        syncPlayingHighlight(at: currentEditorPlaybackPosition(), recordPlaybackPosition: false)
    }

    @discardableResult
    func seek(to seconds: Double) -> Bool {
        guard let track = activeTrack, pendingNewTrack == nil,
              state.currentTrack == nil || state.currentTrack?.id == track.id
        else { return false }
        let clamped = clampedSeekPosition(seconds)
        inFlightLoopSeek = nil
        scrubPreviewPosition = nil
        lastPlayingPosition = clamped
        if !isPlaying {
            pausedPlaybackPosition = clamped
        }
        syncPlayingHighlight(at: clamped)
        onSeek(track.id, clamped)
        return true
    }

    func nudgePlayback(by delta: Double) {
        seek(to: max(0.0, currentEditorPlaybackPosition() + delta))
    }

    func stampNow() {
        guard canStampNow else { return }
        let pos = currentEditorPlaybackPosition()
        if session.stamp(at: pos) {
            statusMessage = nil
            if case .lines = session.stampingMode, session.nextLineIndex < session.lines.count {
                selectedLineId = session.lines[session.nextLineIndex].id
            }
        }
    }

    func stampSelectedLineEndNow() {
        guard canStampSelectedLineEnd, let index = selectedLineIndex else { return }
        let pos = currentEditorPlaybackPosition()
        _ = session.stampLineEnd(at: pos, forLine: index)
    }

    func undoLastStamp() {
        _ = session.undoLastStamp()
    }

    struct PendingCustomSave: Equatable {
        let draftRevision: UInt64
        let track: TrackInfo
        let lines: [LyricLine]
        let explicitEndIndices: Set<Int>
    }

    /// Validates the draft for saving; returns the payload if valid, otherwise sets `statusMessage`.
    func prepareCustomSave() -> PendingCustomSave? {
        guard let track = activeTrack else { return nil }
        guard cachedCustomRecord?.trackId == track.id else {
            statusMessage = "Checking for saved Custom timing. Please save again when the check finishes."
            return nil
        }
        let unstamped = session.unstampedLineNumbers
        if !unstamped.isEmpty {
            let preview = unstamped.prefix(5).map(String.init).joined(separator: ", ")
            let suffix = unstamped.count > 5 ? ", …" : ""
            let label = unstamped.count == 1 ? "line" : "lines"
            statusMessage = "Stamp or delete remaining lines before saving (\(label) \(preview)\(suffix))."
            return nil
        }
        let built = session.buildLyricLines()
        guard !built.isEmpty else {
            statusMessage = "Stamp at least one line before saving."
            return nil
        }
        return PendingCustomSave(
            draftRevision: draftRevision,
            track: track,
            lines: built,
            explicitEndIndices: session.explicitEndLineIndices
        )
    }

    @discardableResult
    func commitCustomSave(_ pending: PendingCustomSave) -> Bool {
        guard activeTrack?.id == pending.track.id else { return false }
        guard draftRevision == pending.draftRevision else {
            statusMessage = "The draft changed. Please save again to use the current timing."
            return false
        }
        let hadPendingRefresh = pendingAutomaticRefresh
        isCommittingSave = true
        pendingAutomaticRefresh = false
        session.stopStamping()
        do {
            try onSaveCustom(pending.track, pending.lines, pending.explicitEndIndices)
            isCommittingSave = false
            let savedRecord = CustomLyricsRecord(
                trackId: pending.track.id,
                title: pending.track.title,
                artist: pending.track.artist,
                savedAt: Date(),
                lines: pending.lines,
                explicitEndLineIndices: pending.explicitEndIndices
            )
            cachedCustomRecord = (pending.track.id, savedRecord)
            hasCustomLyrics = true
            selectedSource = .custom
            appliedSource = .custom
            loadedRawLines = state.rawLyricLines
            baselineLines = session.lines
            statusMessage = "Saved Custom timing (\(pending.lines.count) lines)."
            return true
        } catch {
            isCommittingSave = false
            let errorMessage = "Could not save Custom timing: \(error.localizedDescription)"
            pendingAutomaticRefresh = hadPendingRefresh
            if pendingAutomaticRefresh {
                applyAutomaticRefreshIfEligible()
            }
            statusMessage = errorMessage
            return false
        }
    }

    func deleteCustomLyrics(for capturedTrack: TrackInfo) {
        guard activeTrack?.id == capturedTrack.id else { return }
        session.stopStamping()
        do {
            let fallbackLines = try onDeleteCustom(capturedTrack)
            customRecordLoad?.cancel()
            customRecordLoad = nil
            cachedCustomRecord = (capturedTrack.id, nil)
            hasCustomLyrics = false
            let nextSource = LyricSourceResolver.effectiveSource(
                choice: state.lyricSourceChoice(for: capturedTrack.id),
                hasCustomLyrics: false,
                audioSyncEngine: state.audioSyncEngine
            )
            selectedSource = nextSource
            appliedSource = nextSource
            loadedRawLines = state.rawLyricLines
            session = LyricTimingSession(lines: fallbackLines)
            refreshPreviewLanguage(for: fallbackLines)
            baselineLines = session.lines
            selectedLineId = session.lines.first?.id
            statusMessage = "Deleted Custom lyrics."
        } catch {
            statusMessage = "Could not delete Custom lyrics: \(error.localizedDescription)"
        }
    }

    func pastePlainLyrics(_ text: String) {
        session.replaceWithPlainText(text)
        refreshPreviewLanguage()
        selectedLineId = session.lines.first?.id
        statusMessage = "Loaded \(session.lines.count) lines. Press Stamp Lines to time them."
    }

    func updateLineText(at index: Int, to newText: String) {
        session.updateLineText(at: index, to: newText)
        refreshPreviewLanguage()
    }

    @discardableResult
    func addLine(after index: Int?) -> Int {
        let inserted = session.addLine(after: index)
        refreshPreviewLanguage()
        return inserted
    }

    func deleteLine(at index: Int) {
        session.deleteLine(at: index)
        refreshPreviewLanguage()
    }
}

struct LyricTimingEditorView: View {
    private struct PendingTrackSwitch: Equatable {
        let draftTrackId: String
        let destinationTrack: TrackInfo
    }

    let state: LyricsState
    @ObservedObject var model: LyricTimingEditorModel
    @State private var showPasteSheet = false
    @State private var pasteBuffer = ""
    @State private var trackPendingDeletion: TrackInfo?
    @State private var pendingOverwriteSave: LyricTimingEditorModel.PendingCustomSave?
    @State private var pendingSourceSwitch: TrackLyricSource?
    @State private var pendingTrackSwitch: PendingTrackSwitch?
    @State private var lineIdPendingClearWords: UUID?
    @State private var lineIdPendingDelete: UUID?
    @State private var showTimeline = true

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()

            if model.activeTrack == nil {
                emptyStateView
            } else {
                stampingBar
                Divider()

                if let incoming = model.pendingNewTrack {
                    pendingNewTrackBanner(incoming)
                    Divider()
                }

                if model.session.hasOutOfOrderWarnings {
                    outOfOrderBanner
                    Divider()
                }

                VSplitView {
                    if showTimeline {
                        LyricTimelinePane(state: state, model: model)
                            .frame(minHeight: 132, idealHeight: 176, maxHeight: 380)
                    }

                    HSplitView {
                        linesListPane
                            .frame(minWidth: 380, idealWidth: 460)
                        wordInspectorPane
                            .frame(minWidth: 250, idealWidth: 290)
                    }
                    .frame(minHeight: 240)
                }

                Divider()
                footerBar
            }
        }
        .frame(minWidth: 700, minHeight: 520)
        .sheet(isPresented: $showPasteSheet) {
            pasteLyricsSheet
        }
        .alert(
            "Delete Custom Lyrics?",
            isPresented: Binding(
                get: { trackPendingDeletion != nil },
                set: { if !$0 { trackPendingDeletion = nil } }
            ),
            presenting: trackPendingDeletion
        ) { capturedTrack in
            Button("Delete", role: .destructive) {
                model.deleteCustomLyrics(for: capturedTrack)
                trackPendingDeletion = nil
            }
            Button("Cancel", role: .cancel) {
                trackPendingDeletion = nil
            }
        } message: { capturedTrack in
            Text(
                "This removes your saved Custom timing for \(capturedTrack.title). "
                    + "Fetched lyrics and automatic audio sync records will not be affected."
            )
        }
        .alert(
            "Replace Custom Lyrics?",
            isPresented: Binding(
                get: { pendingOverwriteSave != nil },
                set: { if !$0 { pendingOverwriteSave = nil } }
            ),
            presenting: pendingOverwriteSave
        ) { pending in
            Button("Replace", role: .destructive) {
                model.commitCustomSave(pending)
                pendingOverwriteSave = nil
            }
            Button("Cancel", role: .cancel) {
                pendingOverwriteSave = nil
            }
        } message: { pending in
            Text(
                "This permanently replaces your previously saved Custom timing for \(pending.track.title)."
            )
        }
        .alert(
            "Discard Unsaved Changes?",
            isPresented: Binding(
                get: { pendingSourceSwitch != nil },
                set: { if !$0 { pendingSourceSwitch = nil } }
            ),
            presenting: pendingSourceSwitch
        ) { targetSource in
            Button("Discard & Switch", role: .destructive) {
                model.selectSource(targetSource)
                pendingSourceSwitch = nil
            }
            Button("Cancel", role: .cancel) {
                pendingSourceSwitch = nil
            }
        } message: { targetSource in
            Text(
                "Switching to \(targetSource.title) will discard your unsaved lyric text and timing edits."
            )
        }
        .alert(
            "Discard Unsaved Changes?",
            isPresented: Binding(
                get: { pendingTrackSwitch != nil },
                set: { if !$0 { pendingTrackSwitch = nil } }
            ),
            presenting: pendingTrackSwitch
        ) { pending in
            Button("Discard & Load", role: .destructive) {
                model.loadConfirmedTrack(
                    expectedDraftId: pending.draftTrackId,
                    expectedDestinationId: pending.destinationTrack.id
                )
                pendingTrackSwitch = nil
            }
            Button("Cancel", role: .cancel) {
                pendingTrackSwitch = nil
            }
        } message: { pending in
            Text(
                "Loading \(pending.destinationTrack.title) will discard your unsaved lyric text and timing edits."
            )
        }
        .onChange(of: model.pendingNewTrack) { newPending in
            if let existing = pendingTrackSwitch, existing.destinationTrack.id != newPending?.id {
                pendingTrackSwitch = nil
            }
        }
        .alert(
            "Clear Word Timings?",
            isPresented: Binding(
                get: { lineIdPendingClearWords != nil },
                set: { if !$0 { lineIdPendingClearWords = nil } }
            ),
            presenting: lineIdPendingClearWords
        ) { lineId in
            Button("Clear Words", role: .destructive) {
                if let idx = model.session.lines.firstIndex(where: { $0.id == lineId }) {
                    model.session.clearWords(forLine: idx)
                }
                lineIdPendingClearWords = nil
            }
            Button("Cancel", role: .cancel) {
                lineIdPendingClearWords = nil
            }
        } message: { _ in
            Text("This removes all word timestamps on the selected line.")
        }
        .alert(
            "Delete Lyric Line?",
            isPresented: Binding(
                get: { lineIdPendingDelete != nil },
                set: { if !$0 { lineIdPendingDelete = nil } }
            ),
            presenting: lineIdPendingDelete
        ) { lineId in
            Button("Delete Line", role: .destructive) {
                performDeleteLine(id: lineId)
                lineIdPendingDelete = nil
            }
            Button("Cancel", role: .cancel) {
                lineIdPendingDelete = nil
            }
        } message: { lineId in
            if let line = model.session.lines.first(where: { $0.id == lineId }),
               !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text("This removes \"\(line.text)\" and its timing from the draft.")
            } else {
                Text("This removes the selected lyric line and its timing from the draft.")
            }
        }
    }

    private func performDeleteLine(id: UUID) {
        guard let index = model.session.lines.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = model.selectedLineId == id
        model.deleteLine(at: index)
        if wasSelected {
            let nextIdx = min(index, max(0, model.session.lines.count - 1))
            model.selectedLineId = model.session.lines.indices.contains(nextIdx)
                ? model.session.lines[nextIdx].id
                : nil
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

            if let activeTrack = model.activeTrack {
                HStack(spacing: 4) {
                    Button {
                        model.previousTrack(expectedTrackId: activeTrack.id)
                    } label: {
                        Image(systemName: "backward.end.fill")
                    }
                    .help("Previous Track")

                    Button {
                        model.nudgePlayback(by: -5.0)
                    } label: {
                        Image(systemName: "gobackward.5")
                    }
                    .help("Back 5 seconds")

                    Button {
                        model.togglePlayPause()
                    } label: {
                        Image(systemName: model.isPlaying ? "pause.fill" : "play.fill")
                            .frame(width: 14)
                    }
                    .help(model.isPlaying ? "Pause" : "Play")

                    Button {
                        model.nudgePlayback(by: 5.0)
                    } label: {
                        Image(systemName: "goforward.5")
                    }
                    .help("Forward 5 seconds")

                    Button {
                        model.nextTrack(expectedTrackId: activeTrack.id)
                    } label: {
                        Image(systemName: "forward.end.fill")
                    }
                    .help("Next Track")

                    Button {
                        model.cycleLoopMode()
                    } label: {
                        Image(systemName: model.loopMode.symbolName)
                            .foregroundStyle(model.loopMode == .off ? Color.primary : Color.accentColor)
                    }
                    .help(model.loopMode.helpText)
                }
                .disabled(model.pendingNewTrack != nil)

                TimelineView(.animation(minimumInterval: 0.10, paused: !model.isPlaying)) { context in
                    let pos = model.currentEditorPlaybackPosition(at: context.date)
                    Text(LyricTimingSession.formatTime(pos))
                        .font(.system(.body, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                        .onChange(of: Int(pos * 10)) { _ in
                            model.syncPlayingHighlight(at: pos)
                        }
                }

                Picker("Source", selection: Binding(
                    get: { model.selectedSource },
                    set: { newSource in
                        guard newSource != model.selectedSource else { return }
                        if model.hasPendingChanges {
                            pendingSourceSwitch = newSource
                        } else {
                            model.selectSource(newSource)
                        }
                    }
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
                .disabled(model.session.lines.isEmpty || model.pendingNewTrack != nil)
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
                .disabled(model.selectedLineIndex == nil || model.pendingNewTrack != nil)
            }

            Button {
                model.undoLastStamp()
            } label: {
                Label("Undo Stamp", systemImage: "arrow.uturn.backward")
            }
            .disabled(!model.session.canUndoStamp)

            Toggle(isOn: $showTimeline) {
                Label("Timeline", systemImage: "waveform.path")
            }
            .toggleStyle(.button)

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
                        guard model.hasAnyRomanizationEnabled else { return "" }
                        let previews = model.romanizedWordPreviews(for: words)
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

    private func pendingNewTrackBanner(_ incoming: TrackInfo) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "music.note")
                .foregroundStyle(.secondary)
            Text("Now playing \"\(incoming.title)\" — keeping your unsaved draft open.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer()
            Button("Load Now Playing") {
                if model.hasPendingChanges, let draftId = model.activeTrack?.id {
                    pendingTrackSwitch = PendingTrackSwitch(draftTrackId: draftId, destinationTrack: incoming)
                } else {
                    model.loadCurrentTrack()
                }
            }
            .controlSize(.small)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
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
                    let idx = model.addLine(after: model.selectedLineIndex)
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
                                romajiPreview: model.romanizedLinePreview(for: line.text),
                                isSelected: model.selectedLineId == line.id,
                                highlight: model.playingHighlight,
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
                                onFieldEditingChanged: { editing in
                                    if editing {
                                        model.beginFieldEdit()
                                    } else {
                                        model.endFieldEdit()
                                    }
                                },
                                onEditText: { newText in
                                    model.updateLineText(at: index, to: newText)
                                },
                                onAddBelow: {
                                    let inserted = model.addLine(after: index)
                                    model.selectedLineId = model.session.lines[inserted].id
                                },
                                onDelete: {
                                    if line.requiresDeletionConfirmation {
                                        lineIdPendingDelete = line.id
                                    } else {
                                        performDeleteLine(id: line.id)
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
                    .onReceive(model.playingHighlight.$playingLineId) { newId in
                        if model.followPlayback, model.session.stampingMode == .off, !model.isEditingField, let newId {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                proxy.scrollTo(newId, anchor: .center)
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
                        let line = model.session.lines[idx]
                        if line.words.contains(where: { $0.timestamp != nil }) {
                            lineIdPendingClearWords = line.id
                        } else {
                            model.session.clearWords(forLine: idx)
                        }
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
                let wordRomaji = model.romanizedWordPreviews(for: line.words)

                VStack(alignment: .leading, spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(line.text.isEmpty ? "(Empty line)" : line.text)
                            .font(.callout.weight(.medium))
                            .lineLimit(3)
                        if let romaji = model.romanizedLinePreview(for: line.text) {
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
                        .disabled(!isWordStampingThisLine && model.pendingNewTrack != nil)
                        .controlSize(.small)
                        .disabled(line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        Button("Stamp End") {
                            model.stampSelectedLineEndNow()
                        }
                        .disabled(!model.canStampSelectedLineEnd)
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
                            onCommit: { newEnd in
                                if let currentIdx = model.session.lines.firstIndex(where: { $0.id == line.id }) {
                                    model.session.setLineEndTimestamp(at: currentIdx, to: newEnd)
                                }
                            },
                            onEditingChanged: { editing in
                                if editing {
                                    model.beginFieldEdit()
                                } else {
                                    model.endFieldEdit()
                                }
                            }
                        )
                        .id(line.id)
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
                        ScrollViewReader { wordProxy in
                            List {
                                ForEach(Array(line.words.enumerated()), id: \.element.id) { wordIdx, word in
                                    WordEditorRow(
                                        word: word,
                                        romajiPreview: wordRomaji.indices.contains(wordIdx) ? wordRomaji[wordIdx] : "",
                                        highlight: model.playingHighlight,
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
                                        },
                                        onFieldEditingChanged: { editing in
                                            if editing {
                                                model.beginFieldEdit()
                                            } else {
                                                model.endFieldEdit()
                                            }
                                        }
                                    )
                                    .id(word.id)
                                    .listRowInsets(EdgeInsets(top: 3, leading: 6, bottom: 3, trailing: 6))
                                }
                            }
                            .listStyle(.inset)
                            .onReceive(model.playingHighlight.$playingWordId) { newWordId in
                                if model.followPlayback, model.session.stampingMode == .off, !model.isEditingField, let newWordId {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        wordProxy.scrollTo(newWordId, anchor: .center)
                                    }
                                }
                            }
                        }
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
            if model.hasCustomLyrics, let track = model.activeTrack {
                Button("Delete Custom…", role: .destructive) {
                    trackPendingDeletion = track
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
                guard let pending = model.prepareCustomSave() else { return }
                if model.hasCustomLyrics {
                    pendingOverwriteSave = pending
                } else {
                    model.commitCustomSave(pending)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.session.lines.isEmpty)
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

private struct LinePlayingBadge: View {
    let lineId: UUID
    let isNextStamp: Bool
    @ObservedObject var highlight: EditorPlayingHighlight

    var body: some View {
        let isPlayingLine = highlight.playingLineId == lineId
        Image(systemName: isNextStamp ? "arrowtriangle.right.fill" : (isPlayingLine ? "waveform" : "circle.fill"))
            .font(.system(size: (isNextStamp || isPlayingLine) ? 10 : 5))
            .foregroundStyle(isNextStamp ? Color.orange : (isPlayingLine ? Color.accentColor : Color.clear))
            .frame(width: 12)
    }
}

private struct LineEditorRow: View {
    let index: Int
    let line: EditableLine
    let romajiPreview: String?
    let isSelected: Bool
    let highlight: EditorPlayingHighlight
    let isNextStamp: Bool
    let isOutOfOrder: Bool
    let canSeek: Bool
    let onSelect: () -> Void
    let onSeek: () -> Void
    let onNudge: (Double) -> Void
    let onSetTime: (Double?) -> Void
    let onFieldEditingChanged: (Bool) -> Void
    let onEditText: (String) -> Void
    let onAddBelow: () -> Void
    let onDelete: () -> Void
    @FocusState private var isTextFocused: Bool
    @State private var reportedTextEditing = false

    var body: some View {
        HStack(spacing: 6) {
            LinePlayingBadge(lineId: line.id, isNextStamp: isNextStamp, highlight: highlight)

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
                onCommit: onSetTime,
                onEditingChanged: onFieldEditingChanged
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
                .focused($isTextFocused)
                .onChange(of: isTextFocused) { focused in
                    if focused {
                        if !reportedTextEditing {
                            reportedTextEditing = true
                            onFieldEditingChanged(true)
                        }
                    } else if reportedTextEditing {
                        reportedTextEditing = false
                        onFieldEditingChanged(false)
                    }
                }
                .onDisappear {
                    if reportedTextEditing {
                        reportedTextEditing = false
                        onFieldEditingChanged(false)
                    }
                }

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
    @ObservedObject var highlight: EditorPlayingHighlight
    let isNextStamp: Bool
    let isOutOfOrder: Bool
    let onSelectForStamp: () -> Void
    let onNudge: (Double) -> Void
    let onSetTime: (Double?) -> Void
    let onFieldEditingChanged: (Bool) -> Void

    var body: some View {
        let isPlayingWord = highlight.playingWordId == word.id
        HStack(spacing: 6) {
            Image(systemName: isNextStamp ? "arrowtriangle.right.fill" : (isPlayingWord ? "waveform" : "arrowtriangle.right.fill"))
                .font(.system(size: 9))
                .foregroundStyle(isNextStamp ? Color.orange : (isPlayingWord ? Color.accentColor : Color.clear))
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
                onCommit: onSetTime,
                onEditingChanged: onFieldEditingChanged
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
                .fill(isNextStamp ? Color.orange.opacity(0.16) : (highlight.playingWordId == word.id ? Color.accentColor.opacity(0.16) : Color.clear))
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
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var text: String = ""
    @State private var reportedEditing = false
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
                if focused {
                    if !reportedEditing {
                        reportedEditing = true
                        onEditingChanged(true)
                    }
                } else {
                    commit()
                    if reportedEditing {
                        reportedEditing = false
                        onEditingChanged(false)
                    }
                }
            }
            .onDisappear {
                if reportedEditing {
                    reportedEditing = false
                    onEditingChanged(false)
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
    private let onSeek: (String, Double) -> Void
    private let onTogglePlayPause: (String) -> Void
    private let onPreviousTrack: (String) -> Void
    private let onNextTrack: (String) -> Void
    private let onSelectSource: (TrackInfo, TrackLyricSource, [LyricLine]?) -> [LyricLine]
    private let onSaveCustom: (TrackInfo, [LyricLine], Set<Int>) throws -> Void
    private let onDeleteCustom: (TrackInfo) throws -> [LyricLine]
    private let vocalEnvelopeProvider: (String?) -> VocalEnvelope?
    private let vocalEnvelopeDidChange: AnyPublisher<String, Never>

    private var window: NSWindow?
    private var model: LyricTimingEditorModel?
    private var keyMonitor: Any?

    init(
        state: LyricsState,
        customLyricsStore: CustomLyricsStore,
        onSeek: @escaping (String, Double) -> Void,
        onTogglePlayPause: @escaping (String) -> Void,
        onPreviousTrack: @escaping (String) -> Void = { _ in },
        onNextTrack: @escaping (String) -> Void = { _ in },
        onSelectSource: @escaping (TrackInfo, TrackLyricSource, [LyricLine]?) -> [LyricLine],
        onSaveCustom: @escaping (TrackInfo, [LyricLine], Set<Int>) throws -> Void,
        onDeleteCustom: @escaping (TrackInfo) throws -> [LyricLine],
        vocalEnvelopeProvider: @escaping (String?) -> VocalEnvelope? = { _ in nil },
        vocalEnvelopeDidChange: AnyPublisher<String, Never> = Empty().eraseToAnyPublisher()
    ) {
        self.state = state
        self.customLyricsStore = customLyricsStore
        self.onSeek = onSeek
        self.onTogglePlayPause = onTogglePlayPause
        self.onPreviousTrack = onPreviousTrack
        self.onNextTrack = onNextTrack
        self.onSelectSource = onSelectSource
        self.onSaveCustom = onSaveCustom
        self.onDeleteCustom = onDeleteCustom
        self.vocalEnvelopeProvider = vocalEnvelopeProvider
        self.vocalEnvelopeDidChange = vocalEnvelopeDidChange
        super.init()
    }

    func show() {
        if let existing = window {
            existing.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let editorModel = LyricTimingEditorModel(
            state: state,
            customLyricsStore: customLyricsStore,
            onSeek: onSeek,
            onTogglePlayPause: onTogglePlayPause,
            onPreviousTrack: onPreviousTrack,
            onNextTrack: onNextTrack,
            onSelectSource: onSelectSource,
            onSaveCustom: onSaveCustom,
            onDeleteCustom: onDeleteCustom,
            vocalEnvelopeProvider: vocalEnvelopeProvider,
            vocalEnvelopeDidChange: vocalEnvelopeDidChange
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
                  win.attachedSheet == nil,
                  !(win.firstResponder is NSText),
                  let model = self.model,
                  model.canStampNow,
                  event.keyCode == 49,
                  event.modifierFlags.isDisjoint(with: [.command, .control, .option])
            else {
                return event
            }
            if event.isARepeat {
                return nil
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

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model, model.hasPendingChanges else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Discard Unsaved Changes?"
        alert.informativeText = "Closing the Lyric Timing Editor will discard your unsaved lyric text and timing edits."
        alert.addButton(withTitle: "Discard & Close")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func windowWillClose(_ notification: Notification) {
        removeKeyMonitor()
        model?.tearDown()
        model = nil
        window?.contentViewController = nil
        window = nil
    }
}

enum TimelineLayoutMath {
    static let minZoom: Double = 28.0
    static let maxZoom: Double = 160.0
    /// Matches `LyricsState.syncActiveLine`'s `line.timestamp + 4.5` fallback for an unbounded final line.
    static let finalLineFallbackDuration: Double = 4.5

    static func viewportX(forTime seconds: Double, viewportStart: Double, pixelsPerSecond: Double) -> CGFloat {
        CGFloat((seconds - viewportStart) * pixelsPerSecond)
    }

    static func time(forViewportX x: CGFloat, viewportStart: Double, pixelsPerSecond: Double) -> Double {
        guard pixelsPerSecond > 0 else { return max(0.0, viewportStart) }
        return max(0.0, viewportStart + Double(x) / pixelsPerSecond)
    }

    static func followedViewportStart(playhead: Double, visibleDuration: Double, maxStart: Double) -> Double {
        min(maxStart, max(0.0, playhead - visibleDuration * 0.5))
    }

    static func lineBlockRect(
        start: Double,
        duration: Double,
        viewportStart: Double,
        pixelsPerSecond: Double
    ) -> CGRect {
        let x = viewportX(forTime: start, viewportStart: viewportStart, pixelsPerSecond: pixelsPerSecond)
        let width = max(26, CGFloat(max(0.35, duration) * pixelsPerSecond))
        return CGRect(x: x, y: 26, width: width, height: 38)
    }

    /// Computes live playback highlight and karaoke sweep fraction from the line's derived end time
    /// rather than its inflated minimum visual block width.
    static func linePlaybackState(
        start: Double,
        end: Double,
        playheadTime: Double
    ) -> (isActive: Bool, sweepFraction: Double) {
        let actualDuration = max(0.0, end - start)
        let isActive = playheadTime >= start && playheadTime <= end
        let sweepFraction: Double = if playheadTime <= start {
            0.0
        } else if actualDuration > 0 {
            min(1.0, max(0.0, (playheadTime - start) / actualDuration))
        } else {
            1.0
        }
        return (isActive, sweepFraction)
    }

    static func wordBlockRect(
        start: Double,
        duration: Double,
        viewportStart: Double,
        pixelsPerSecond: Double
    ) -> CGRect {
        let x = viewportX(forTime: start, viewportStart: viewportStart, pixelsPerSecond: pixelsPerSecond)
        let width = max(20, CGFloat(max(0.08, duration) * pixelsPerSecond))
        return CGRect(x: x, y: 70, width: width, height: 26)
    }

    static func shapedVocalHeight(
        db: Float,
        minDB: Float,
        maxDB: Float,
        halfHeight: CGFloat
    ) -> CGFloat {
        let range = max(6.0, maxDB - minDB)
        let norm = CGFloat(min(1.0, max(0.0, (db - minDB) / range)))
        let shaped = norm * norm
        return shaped > 0.03 ? shaped * halfHeight * 0.92 : 0.0
    }

    /// Shared horizontal visibility check used by both canvas drawing and hit testing so minimum-width
    /// blocks extending into the viewport are drawn whenever they are draggable (and never hit when invisible).
    static func isBlockVisible(_ rect: CGRect, viewportWidth: CGFloat? = nil) -> Bool {
        guard rect.maxX >= 0 else { return false }
        if let viewportWidth {
            return rect.minX <= viewportWidth
        }
        return true
    }

    static func hitTestLine(
        at point: CGPoint,
        lines: [EditableLine],
        nextLaterByStart: [Double: Double]? = nil,
        viewportStart: Double,
        pixelsPerSecond: Double
    ) -> (index: Int, start: Double, actualEnd: Double, isResizeEdge: Bool)? {
        guard point.x >= 0, point.y >= 26, point.y <= 64 else { return nil }
        let lookup = nextLaterByStart ?? LyricTimingSession.nextLaterStartLookup(for: lines)
        // Iterate front-to-back (reverse drawing order) so overlapping later blocks win.
        for index in lines.indices.reversed() {
            let line = lines[index]
            guard let start = line.timestamp else { continue }
            let end = LyricTimingSession.derivedLineEnd(
                for: line,
                nextLaterStart: lookup[start],
                fallbackDuration: TimelineLayoutMath.finalLineFallbackDuration
            ) ?? (start + TimelineLayoutMath.finalLineFallbackDuration)
            let rect = lineBlockRect(
                start: start,
                duration: max(0.35, end - start),
                viewportStart: viewportStart,
                pixelsPerSecond: pixelsPerSecond
            )
            guard isBlockVisible(rect) else { continue }
            if rect.contains(point) {
                return (index, start, end, rect.maxX - point.x <= 8)
            }
        }
        return nil
    }

    static func hitTestWord(
        at point: CGPoint,
        line: EditableLine,
        lineEnd: Double?,
        viewportStart: Double,
        pixelsPerSecond: Double
    ) -> (wordIndex: Int, wordStart: Double)? {
        guard point.x >= 0, point.y >= 70, point.y <= 96 else { return nil }
        let words = line.words
        let nextWordStarts = LyricTimingSession.nextWordStarts(for: words)
        // Iterate front-to-back (reverse drawing order) so overlapping later words win.
        for wordIdx in words.indices.reversed() {
            let word = words[wordIdx]
            guard let wordStart = word.timestamp else { continue }
            let nextWordStart = nextWordStarts[wordIdx]
            let wordDur = wordDuration(
                word: word,
                wordStart: wordStart,
                nextWordStart: nextWordStart,
                lineEnd: lineEnd
            )
            let rect = wordBlockRect(
                start: wordStart,
                duration: wordDur,
                viewportStart: viewportStart,
                pixelsPerSecond: pixelsPerSecond
            )
            guard isBlockVisible(rect) else { continue }
            if rect.contains(point) {
                return (wordIdx, wordStart)
            }
        }
        return nil
    }

    static func totalDuration(
        maxLineEnd: Double,
        trackDuration: Double?,
        vocalEnvelope: VocalEnvelope?
    ) -> Double {
        let maxVocalEnd = vocalEnvelope?.segments.map(\.end).max() ?? 0.0
        return max(30.0, trackDuration ?? 0.0, maxLineEnd + 4.0, maxVocalEnd + 4.0)
    }

    static func clampedShiftedStart(original: Double, deltaSeconds: Double) -> Double {
        max(0.0, original + deltaSeconds)
    }

    /// Clamps a resized line end strictly past `lineStart` without enforcing a 200 ms minimum that
    /// would inflate imported sub-200 ms lines; visual minimums belong in `lineBlockRect`.
    static func clampedResizedEnd(lineStart: Double, originEnd: Double, deltaSeconds: Double) -> Double {
        max(lineStart + 0.01, originEnd + deltaSeconds)
    }

    /// Exact playback duration for a word: preserves imported `preservedDuration` (including 0 or short
    /// < 80 ms words) verbatim; visual minimum widths belong exclusively in `wordBlockRect`.
    static func wordDuration(
        word: EditableWord,
        wordStart: Double,
        nextWordStart: Double?,
        lineEnd: Double? = nil
    ) -> Double {
        if let preserved = word.preservedDuration, preserved.isFinite, preserved >= 0 {
            return preserved
        }
        if let nextWordStart, nextWordStart > wordStart {
            return nextWordStart - wordStart
        }
        if let lineEnd, lineEnd > wordStart {
            return lineEnd - wordStart
        }
        return 0.45
    }
}

private struct LyricTimelinePane: View {
    let state: LyricsState
    @ObservedObject var model: LyricTimingEditorModel
    @State private var pixelsPerSecond: Double = 60.0
    @State private var manualViewportStart: Double = 0.0
    @State private var lastViewportWidth: CGFloat = 760.0
    @State private var activeDrag: ActiveTimelineDrag?
    @State private var dragExceededThreshold = false
    @GestureState private var isCanvasDragActive = false

    private struct ActiveTimelineDrag {
        let trackId: String
        let originViewportStart: Double
        let originPixelsPerSecond: Double
        let kind: TimelineDragKind

        var freezesViewport: Bool {
            switch kind {
            case .scrubRuler, .moveLine, .resizeLineEnd, .moveWord:
                true
            case .pan, .cancelled:
                false
            }
        }
    }

    private enum TimelineDragKind {
        case cancelled
        case scrubRuler
        case pan
        case moveLine(lineId: UUID, originStart: Double, originEnd: Double?, originWordTimestamps: [Double?])
        case resizeLineEnd(lineId: UUID, lineStart: Double, originEnd: Double)
        case moveWord(lineId: UUID, wordId: UUID, originStart: Double)
    }

    private var totalSeconds: Double {
        TimelineLayoutMath.totalDuration(
            maxLineEnd: model.maxLineEnd,
            trackDuration: model.activeTrack?.duration,
            vocalEnvelope: model.currentVocalEnvelope
        )
    }

    private func resolvedViewportStart(
        at date: Date,
        visibleDuration: Double,
        maxStart: Double
    ) -> Double {
        if let drag = activeDrag,
           drag.trackId == model.activeTrack?.id,
           drag.freezesViewport {
            return drag.originViewportStart
        }
        if model.followPlayback {
            return TimelineLayoutMath.followedViewportStart(
                playhead: model.currentEditorPlaybackPosition(at: date),
                visibleDuration: visibleDuration,
                maxStart: maxStart
            )
        }
        return min(maxStart, max(0.0, manualViewportStart))
    }

    private func cancelActiveDrag(keepCancelledUntilRelease: Bool = false) {
        model.endTimelineDrag()
        if activeDrag != nil || model.scrubPreviewPosition != nil {
            model.endScrub(commit: false)
            if keepCancelledUntilRelease, activeDrag != nil {
                activeDrag = ActiveTimelineDrag(
                    trackId: "",
                    originViewportStart: 0.0,
                    originPixelsPerSecond: pixelsPerSecond,
                    kind: .cancelled
                )
            } else {
                activeDrag = nil
            }
            dragExceededThreshold = false
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            timelineToolbar(hasVocalData: !(model.currentVocalEnvelope?.segments.isEmpty ?? true))
            Divider()
            GeometryReader { geo in
                let viewportWidth = max(200, geo.size.width)
                let canvasHeight = max(92, geo.size.height - 14)
                let frameInterval = state.lowCPUMode ? (1.0 / 8.0) : (1.0 / 15.0)
                let waveformInterval = state.lowCPUMode ? 0.5 : 0.25
                let visibleDuration = max(1.0, Double(viewportWidth) / pixelsPerSecond)
                let maxStart = max(0.0, totalSeconds - visibleDuration)

                VStack(spacing: 0) {
                    // Stable gesture container stays mounted across Follow/Play mode changes so panning never drops.
                    ZStack(alignment: .topLeading) {
                        if model.followPlayback, model.isPlaying {
                            TimelineView(.animation(minimumInterval: frameInterval, paused: false)) { context in
                                let playheadTime = model.currentEditorPlaybackPosition(at: context.date)
                                let viewportStart = resolvedViewportStart(
                                    at: context.date,
                                    visibleDuration: visibleDuration,
                                    maxStart: maxStart
                                )
                                canvasView(
                                    viewportWidth: viewportWidth,
                                    canvasHeight: canvasHeight,
                                    viewportStart: viewportStart,
                                    playheadTime: playheadTime,
                                    drawsPlayhead: true
                                )
                            }
                        } else {
                            let viewportStart = resolvedViewportStart(
                                at: Date(),
                                visibleDuration: visibleDuration,
                                maxStart: maxStart
                            )
                            ZStack(alignment: .topLeading) {
                                TimelineView(.animation(minimumInterval: waveformInterval, paused: !model.isPlaying)) { context in
                                    let currentPos = model.currentEditorPlaybackPosition(at: context.date)
                                    canvasView(
                                        viewportWidth: viewportWidth,
                                        canvasHeight: canvasHeight,
                                        viewportStart: viewportStart,
                                        playheadTime: currentPos,
                                        drawsPlayhead: false
                                    )
                                }

                                TimelineView(.animation(minimumInterval: frameInterval, paused: !model.isPlaying)) { context in
                                    let playheadTime = model.currentEditorPlaybackPosition(at: context.date)
                                    let px = TimelineLayoutMath.viewportX(
                                        forTime: playheadTime,
                                        viewportStart: viewportStart,
                                        pixelsPerSecond: pixelsPerSecond
                                    )
                                    if px >= -8, px <= viewportWidth + 8 {
                                        ZStack(alignment: .topLeading) {
                                            Rectangle()
                                                .fill(Color.red)
                                                .frame(width: 1.5, height: canvasHeight)
                                                .offset(x: px - 0.75)
                                            RoundedRectangle(cornerRadius: 2)
                                                .fill(Color.red)
                                                .frame(width: 8, height: 8)
                                                .offset(x: px - 4)
                                        }
                                        .allowsHitTesting(false)
                                    }
                                }
                            }
                        }
                    }
                    .frame(width: viewportWidth, height: canvasHeight)
                    .contentShape(Rectangle())
                    .background(
                        TimelineScrollWheelCatcher { deltaX, deltaY, isZoom in
                            if isZoom {
                                guard activeDrag == nil else { return }
                                let nextZoom = pixelsPerSecond * (1.0 + Double(deltaY) * 0.01)
                                pixelsPerSecond = min(TimelineLayoutMath.maxZoom, max(TimelineLayoutMath.minZoom, nextZoom))
                            } else {
                                guard activeDrag == nil else { return }
                                let primaryDelta = abs(deltaX) > 0.1 ? deltaX : deltaY
                                guard abs(primaryDelta) > 0.1 else { return }
                                let currentStart = resolvedViewportStart(
                                    at: Date(),
                                    visibleDuration: visibleDuration,
                                    maxStart: maxStart
                                )
                                model.followPlayback = false
                                let deltaSec = -Double(primaryDelta) / pixelsPerSecond
                                manualViewportStart = min(maxStart, max(0.0, currentStart + deltaSec))
                            }
                        }
                    )
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .updating($isCanvasDragActive) { _, state, _ in
                                state = true
                            }
                            .onChanged { value in
                                let currentStart = resolvedViewportStart(
                                    at: Date(),
                                    visibleDuration: visibleDuration,
                                    maxStart: maxStart
                                )
                                handleCanvasDrag(
                                    value: value,
                                    viewportStart: currentStart,
                                    maxStart: maxStart
                                )
                            }
                            .onEnded { _ in
                                if let drag = activeDrag, case .scrubRuler = drag.kind {
                                    let sameTrack = model.activeTrack?.id == drag.trackId
                                    model.endScrub(commit: sameTrack)
                                }
                                model.endTimelineDrag()
                                activeDrag = nil
                                dragExceededThreshold = false
                            }
                    )

                    TimelineView(.animation(minimumInterval: waveformInterval, paused: !model.isPlaying)) { context in
                        let currentPos = model.currentEditorPlaybackPosition(at: context.date)
                        let currentStart = resolvedViewportStart(
                            at: context.date,
                            visibleDuration: visibleDuration,
                            maxStart: maxStart
                        )
                        TimelineOverviewBar(
                            totalSeconds: totalSeconds,
                            viewportStart: currentStart,
                            visibleDuration: visibleDuration,
                            playheadTime: currentPos,
                            onJump: { newStart in
                                model.followPlayback = false
                                manualViewportStart = min(maxStart, max(0.0, newStart))
                            }
                        )
                        .frame(width: viewportWidth, height: 14)
                    }
                }
            }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { lastViewportWidth = max(200, geo.size.width) }
                        .onChange(of: geo.size.width) { newWidth in
                            lastViewportWidth = max(200, newWidth)
                        }
                }
            )
        }
        .background(.background)
        .onChange(of: model.isPlaying) { playing in
            if !playing, model.followPlayback {
                anchorManualViewportToCurrentPlayhead(pos: model.pausedPlaybackPosition)
            }
        }
        .onChange(of: model.activeTrack?.id) { _ in
            cancelActiveDrag(keepCancelledUntilRelease: true)
        }
        .onChange(of: isCanvasDragActive) { active in
            if !active, activeDrag != nil {
                cancelActiveDrag()
            }
        }
        .onDisappear {
            cancelActiveDrag()
        }
    }

    private func anchorManualViewportToCurrentPlayhead(pos: Double) {
        let visibleDuration = max(1.0, Double(lastViewportWidth) / pixelsPerSecond)
        let maxStart = max(0.0, totalSeconds - visibleDuration)
        manualViewportStart = TimelineLayoutMath.followedViewportStart(
            playhead: pos,
            visibleDuration: visibleDuration,
            maxStart: maxStart
        )
    }

    private func canvasView(
        viewportWidth: CGFloat,
        canvasHeight: CGFloat,
        viewportStart: Double,
        playheadTime: Double,
        drawsPlayhead: Bool
    ) -> some View {
        ViewportTimelineCanvas(
            lines: model.session.lines,
            nextLaterByStart: model.nextLaterByStart,
            nextWordStartsByLine: model.nextWordStartsByLineId,
            selectedLineId: model.selectedLineId,
            selectedLineIndex: model.selectedLineIndex,
            vocalEnvelope: model.currentVocalEnvelope,
            viewportStart: viewportStart,
            pixelsPerSecond: pixelsPerSecond,
            playheadTime: playheadTime,
            drawsPlayhead: drawsPlayhead,
            lineLabel: { line in
                if let romaji = model.romanizedLinePreview(for: line.text), !romaji.isEmpty {
                    return romaji
                }
                return line.text.isEmpty ? "♪" : line.text
            },
            wordSpans: { line in
                model.displayWordSpans(for: line)
            }
        )
        .frame(width: viewportWidth, height: canvasHeight)
        .allowsHitTesting(false)
    }

    private func timelineToolbar(hasVocalData: Bool) -> some View {
        ZStack {
            HStack(spacing: 10) {
                Label("Timeline", systemImage: "waveform.path")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 8)

                Toggle("Follow", isOn: Binding(
                    get: { model.followPlayback },
                    set: { newValue in
                        if !newValue, model.followPlayback {
                            anchorManualViewportToCurrentPlayhead(pos: model.currentEditorPlaybackPosition())
                        }
                        model.followPlayback = newValue
                    }
                ))
                    .toggleStyle(.checkbox)
                    .font(.caption)

                HStack(spacing: 4) {
                    Button {
                        pixelsPerSecond = max(TimelineLayoutMath.minZoom, pixelsPerSecond - 16)
                    } label: {
                        Image(systemName: "minus.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Zoom Out")

                    Button {
                        pixelsPerSecond = min(TimelineLayoutMath.maxZoom, pixelsPerSecond + 16)
                    } label: {
                        Image(systemName: "plus.magnifyingglass")
                    }
                    .buttonStyle(.borderless)
                    .help("Zoom In")
                }
            }

            LiveEditorKaraokePreview(
                state: state,
                model: model,
                fallbackLabel: hasVocalData ? "Vocal waveform cached" : "Play with Audio Sync on for vocal peaks"
            )
            .padding(.horizontal, 140)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .background(.bar)
    }

    private func handleCanvasDrag(
        value: DragGesture.Value,
        viewportStart: Double,
        maxStart: Double
    ) {
        guard let currentTrackId = model.activeTrack?.id else {
            cancelActiveDrag(keepCancelledUntilRelease: true)
            return
        }
        if activeDrag == nil {
            let kind = hitTestDragStart(at: value.startLocation, viewportStart: viewportStart)
            switch kind {
            case .moveLine, .resizeLineEnd, .moveWord:
                model.beginTimelineDrag()
            case .scrubRuler, .pan, .cancelled:
                break
            }
            activeDrag = ActiveTimelineDrag(
                trackId: currentTrackId,
                originViewportStart: viewportStart,
                originPixelsPerSecond: pixelsPerSecond,
                kind: kind
            )
        }
        guard let drag = activeDrag else { return }
        if case .cancelled = drag.kind {
            return
        }
        guard drag.trackId == currentTrackId else {
            cancelActiveDrag(keepCancelledUntilRelease: true)
            return
        }
        let dragScale = drag.originPixelsPerSecond
        let deltaSec = Double(value.translation.width) / dragScale

        switch drag.kind {
        case .cancelled:
            return
        case .scrubRuler:
            let time = TimelineLayoutMath.time(
                forViewportX: value.location.x,
                viewportStart: drag.originViewportStart,
                pixelsPerSecond: dragScale
            )
            model.previewScrub(to: time)
        case .pan:
            if !dragExceededThreshold {
                guard abs(value.translation.width) >= 2 else { return }
                dragExceededThreshold = true
            }
            model.followPlayback = false
            manualViewportStart = min(maxStart, max(0.0, drag.originViewportStart - deltaSec))
        case let .moveLine(lineId, originStart, originEnd, originWordTimestamps):
            if !dragExceededThreshold {
                guard abs(value.translation.width) >= 2 else { return }
                dragExceededThreshold = true
            }
            guard let index = model.session.lines.firstIndex(where: { $0.id == lineId }) else { return }
            model.session.translateLine(
                at: index,
                originStart: originStart,
                originEnd: originEnd,
                originWordTimestamps: originWordTimestamps,
                delta: deltaSec
            )
        case let .resizeLineEnd(lineId, lineStart, originEnd):
            if !dragExceededThreshold {
                guard abs(value.translation.width) >= 2 else { return }
                dragExceededThreshold = true
            }
            guard let index = model.session.lines.firstIndex(where: { $0.id == lineId }) else { return }
            model.session.setLineEndTimestamp(
                at: index,
                to: TimelineLayoutMath.clampedResizedEnd(lineStart: lineStart, originEnd: originEnd, deltaSeconds: deltaSec)
            )
        case let .moveWord(lineId, wordId, originStart):
            if !dragExceededThreshold {
                guard abs(value.translation.width) >= 2 else { return }
                dragExceededThreshold = true
            }
            guard let lineIndex = model.session.lines.firstIndex(where: { $0.id == lineId }),
                  let wordIndex = model.session.lines[lineIndex].words.firstIndex(where: { $0.id == wordId })
            else { return }
            let newStart = TimelineLayoutMath.clampedShiftedStart(original: originStart, deltaSeconds: deltaSec)
            model.session.translateWord(lineIndex: lineIndex, wordIndex: wordIndex, to: newStart)
        }
    }

    private func hitTestDragStart(at point: CGPoint, viewportStart: Double) -> TimelineDragKind {
        if point.y <= 22 {
            return .scrubRuler
        }

        let lines = model.session.lines
        if let hit = TimelineLayoutMath.hitTestLine(
            at: point,
            lines: lines,
            nextLaterByStart: model.nextLaterByStart,
            viewportStart: viewportStart,
            pixelsPerSecond: pixelsPerSecond
        ) {
            let line = lines[hit.index]
            model.selectedLineId = line.id
            if hit.isResizeEdge {
                return .resizeLineEnd(lineId: line.id, lineStart: hit.start, originEnd: hit.actualEnd)
            }
            return .moveLine(
                lineId: line.id,
                originStart: hit.start,
                originEnd: line.endTimestamp,
                originWordTimestamps: line.words.map(\.timestamp)
            )
        }

        if let lineIdx = model.selectedLineIndex, lines.indices.contains(lineIdx) {
            let line = lines[lineIdx]
            let nextStart = line.timestamp.flatMap { model.nextLaterByStart[$0] }
            let lineEnd = LyricTimingSession.derivedLineEnd(
                for: line,
                nextLaterStart: nextStart,
                fallbackDuration: TimelineLayoutMath.finalLineFallbackDuration
            )
            if let wordHit = TimelineLayoutMath.hitTestWord(
                at: point,
                line: line,
                lineEnd: lineEnd,
                viewportStart: viewportStart,
                pixelsPerSecond: pixelsPerSecond
            ),
                line.words.indices.contains(wordHit.wordIndex) {
                return .moveWord(
                    lineId: line.id,
                    wordId: line.words[wordHit.wordIndex].id,
                    originStart: wordHit.wordStart
                )
            }
        }

        return .pan
    }
}

private struct ViewportTimelineCanvas: View {
    let lines: [EditableLine]
    let nextLaterByStart: [Double: Double]
    let nextWordStartsByLine: [UUID: [Double?]]
    let selectedLineId: UUID?
    let selectedLineIndex: Int?
    let vocalEnvelope: VocalEnvelope?
    let viewportStart: Double
    let pixelsPerSecond: Double
    let playheadTime: Double
    let drawsPlayhead: Bool
    let lineLabel: (EditableLine) -> String
    let wordSpans: (EditableLine) -> [LyricTimingSession.DisplayWordSpan]

    var body: some View {
        Canvas { context, size in
            let viewportEnd = TimelineLayoutMath.time(
                forViewportX: size.width,
                viewportStart: viewportStart,
                pixelsPerSecond: pixelsPerSecond
            )
            drawRuler(context: context, size: size, viewportEnd: viewportEnd)
            drawVocalEnvelope(context: context, size: size, viewportEnd: viewportEnd)
            drawLines(context: context, size: size)
            drawSelectedLineWords(context: context, size: size)
            drawPlayhead(context: context, size: size)
        }
    }

    private func screenX(for time: Double) -> CGFloat {
        TimelineLayoutMath.viewportX(
            forTime: time,
            viewportStart: viewportStart,
            pixelsPerSecond: pixelsPerSecond
        )
    }

    private func drawRuler(context: GraphicsContext, size: CGSize, viewportEnd: Double) {
        let headerHeight: CGFloat = 22
        context.fill(Path(CGRect(x: 0, y: 0, width: size.width, height: headerHeight)), with: .color(.primary.opacity(0.04)))

        let step = pixelsPerSecond >= 90 ? 1 : (pixelsPerSecond >= 45 ? 2 : 5)
        let firstSec = max(0, (Int(floor(viewportStart)) / step) * step)
        let lastSec = Int(ceil(viewportEnd))
        for sec in stride(from: firstSec, through: lastSec, by: step) {
            let x = screenX(for: Double(sec))
            guard x >= -20, x <= size.width + 20 else { continue }
            var tick = Path()
            tick.move(to: CGPoint(x: x, y: headerHeight - 6))
            tick.addLine(to: CGPoint(x: x, y: size.height))
            context.stroke(tick, with: .color(.primary.opacity(0.08)), lineWidth: 1)

            let label = String(format: "%d:%02d", sec / 60, sec % 60)
            context.draw(
                Text(label).font(.system(size: 9, design: .monospaced)).foregroundColor(.secondary),
                at: CGPoint(x: x + 3, y: 9),
                anchor: .leading
            )
        }
    }

    private func drawVocalEnvelope(context: GraphicsContext, size: CGSize, viewportEnd: Double) {
        guard let segments = vocalEnvelope?.segments, !segments.isEmpty else { return }
        let laneTop: CGFloat = 26
        let laneHeight: CGFloat = max(20, size.height - laneTop - 6)
        let midY = laneTop + laneHeight / 2
        let halfH = laneHeight / 2

        // Dual-band rendering: muted outer full-mix min/max peaks + bright centre-isolated vocal band.
        let targetBinSeconds = max(VocalEnvelope.frameSeconds, 1.5 / pixelsPerSecond)
        let framesPerBin = max(1, Int((targetBinSeconds / VocalEnvelope.frameSeconds).rounded()))
        let barWidth = max(1.0, min(2.0, CGFloat(Double(framesPerBin) * VocalEnvelope.frameSeconds * pixelsPerSecond)))

        var axis = Path()
        axis.move(to: CGPoint(x: 0, y: midY))
        axis.addLine(to: CGPoint(x: size.width, y: midY))
        context.stroke(axis, with: .color(.primary.opacity(0.08)), lineWidth: 0.5)

        for segment in segments where segment.step > 0 && !segment.levels.isEmpty {
            guard segment.end >= viewportStart, segment.start <= viewportEnd else { continue }
            let firstFrame = max(0, (segment.frame(at: viewportStart) / framesPerBin) * framesPerBin)
            let lastFrame = min(segment.levels.count - 1, segment.frame(at: viewportEnd) + framesPerBin)
            guard firstFrame <= lastFrame else { continue }

            let hasPeakData = segment.minPeaks.count == segment.levels.count
                && segment.maxPeaks.count == segment.levels.count

            // Auto-gain to the visible peak so quiet macOS/Spotify listening volumes still fill the lane cleanly.
            var visiblePeak: Float = 0.05
            if hasPeakData {
                for idx in firstFrame...lastFrame {
                    let absP = max(abs(segment.minPeaks[idx]), abs(segment.maxPeaks[idx]))
                    if absP > visiblePeak { visiblePeak = absP }
                }
            }
            let gain = CGFloat(0.92 / max(0.05, visiblePeak))

            // Compute visible vocal dB floor/ceiling so isolated vocal onsets and ends pop cleanly above instruments.
            var minVocalDB: Float = -50.0
            var maxVocalDB: Float = -10.0
            if firstFrame <= lastFrame {
                var lo: Float = 0
                var hi: Float = -100
                for idx in firstFrame...lastFrame {
                    let lv = segment.levels[idx]
                    if lv < lo { lo = lv }
                    if lv > hi { hi = lv }
                }
                if hi > lo + 4.0 {
                    minVocalDB = lo + (hi - lo) * 0.25
                    maxVocalDB = hi
                }
            }
            var mixPeakPath = Path()
            var vocalPath = Path()
            var frame = firstFrame
            while frame <= lastFrame {
                let endFrame = min(segment.levels.count - 1, frame + framesPerBin - 1)
                let x = screenX(for: segment.time(ofFrame: frame))
                var vocalPeakDB = segment.levels[frame]
                if hasPeakData {
                    var minV = segment.minPeaks[frame]
                    var maxV = segment.maxPeaks[frame]
                    for idx in frame...endFrame {
                        if segment.minPeaks[idx] < minV { minV = segment.minPeaks[idx] }
                        if segment.maxPeaks[idx] > maxV { maxV = segment.maxPeaks[idx] }
                        if segment.levels[idx] > vocalPeakDB { vocalPeakDB = segment.levels[idx] }
                    }
                    let scaledMax = min(1.0, max(0.0, CGFloat(maxV) * gain))
                    let scaledMin = max(-1.0, min(0.0, CGFloat(minV) * gain))
                    let yTop = midY - scaledMax * halfH
                    let yBot = midY - scaledMin * halfH
                    mixPeakPath.addRect(CGRect(x: x, y: yTop, width: barWidth, height: max(1.0, yBot - yTop)))
                } else {
                    for idx in frame...endFrame where segment.levels[idx] > vocalPeakDB {
                        vocalPeakDB = segment.levels[idx]
                    }
                }
                let vocalH = TimelineLayoutMath.shapedVocalHeight(
                    db: vocalPeakDB,
                    minDB: minVocalDB,
                    maxDB: maxVocalDB,
                    halfHeight: halfH
                )
                if vocalH > 0 {
                    vocalPath.addRect(CGRect(x: x, y: midY - vocalH, width: barWidth, height: max(1.5, vocalH * 2)))
                }
                frame += framesPerBin
            }
            if hasPeakData {
                context.fill(mixPeakPath, with: .color(.secondary.opacity(0.22)))
            }
            context.fill(vocalPath, with: .color(.accentColor.opacity(0.68)))
        }
    }

    private func drawLines(context: GraphicsContext, size: CGSize) {
        let count = lines.count
        for index in 0..<count {
            let line = lines[index]
            guard let start = line.timestamp else { continue }
            let end = LyricTimingSession.derivedLineEnd(
                for: line,
                nextLaterStart: nextLaterByStart[start],
                fallbackDuration: TimelineLayoutMath.finalLineFallbackDuration
            ) ?? (start + TimelineLayoutMath.finalLineFallbackDuration)
            let actualDuration = max(0.0, end - start)
            let rect = TimelineLayoutMath.lineBlockRect(
                start: start,
                duration: actualDuration,
                viewportStart: viewportStart,
                pixelsPerSecond: pixelsPerSecond
            )
            guard TimelineLayoutMath.isBlockVisible(rect, viewportWidth: size.width) else { continue }
            let isSelected = line.id == selectedLineId
            let shape = Path(roundedRect: rect, cornerRadius: 5)
            let playbackState = TimelineLayoutMath.linePlaybackState(
                start: start,
                end: end,
                playheadTime: playheadTime
            )
            let isActive = playbackState.isActive
            context.fill(
                shape,
                with: .color(isSelected ? .accentColor.opacity(0.24) : (isActive ? .accentColor.opacity(0.14) : .secondary.opacity(0.16)))
            )

            // Smooth live karaoke sweep fill across the active line block.
            if playbackState.sweepFraction > 0 {
                let sweepRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(playbackState.sweepFraction), height: rect.height)
                var sweepCtx = context
                sweepCtx.clip(to: shape)
                sweepCtx.fill(Path(sweepRect), with: .color(.accentColor.opacity(isActive ? 0.34 : 0.12)))
            }

            context.stroke(
                shape,
                with: .color(isSelected || isActive ? .accentColor : .secondary.opacity(0.45)),
                lineWidth: isSelected || isActive ? 1.5 : 1
            )

            // Right-edge resize grip indicator
            let gripRect = CGRect(x: rect.maxX - 4, y: rect.minY + 10, width: 2, height: 18)
            context.fill(Path(roundedRect: gripRect, cornerRadius: 1), with: .color(.primary.opacity(0.25)))

            let playheadX = screenX(for: playheadTime)
            var clipped = context
            clipped.clip(to: Path(CGRect(x: rect.minX + 4, y: rect.minY, width: max(0, rect.width - 12), height: rect.height)))
            if LyricTimingEditorModel.hasCompleteTimedWords(line) {
                let spans = wordSpans(line)
                let nextWordStarts = nextWordStartsByLine[line.id] ?? []
                let timedSpans: [(text: String, start: Double, end: Double)] = spans.compactMap { span in
                    guard !span.label.isEmpty else { return nil }
                    let slice = span.sourceRange.compactMap { idx -> (Int, Double)? in
                        guard line.words.indices.contains(idx), let ts = line.words[idx].timestamp else { return nil }
                        return (idx, ts)
                    }
                    guard let first = slice.min(by: { $0.1 < $1.1 }),
                          let last = slice.max(by: { $0.1 < $1.1 })
                    else { return nil }
                    let nextWordStart = nextWordStarts.indices.contains(last.0) ? nextWordStarts[last.0] : nil
                    let dur = TimelineLayoutMath.wordDuration(
                        word: line.words[last.0],
                        wordStart: last.1,
                        nextWordStart: nextWordStart,
                        lineEnd: end
                    )
                    return (span.label, first.1, last.1 + dur)
                }.sorted { $0.start < $1.start }

                var wordTicks = Path()
                for (slot, span) in timedSpans.enumerated() {
                    let wordX = screenX(for: span.start)
                    let nextX: CGFloat = if slot + 1 < timedSpans.count {
                        min(screenX(for: timedSpans[slot + 1].start), max(screenX(for: span.end), wordX + 12))
                    } else {
                        min(rect.maxX - 8, max(screenX(for: span.end), wordX + 12))
                    }
                    if slot > 0, wordX > rect.minX + 2, wordX < rect.maxX - 8 {
                        wordTicks.move(to: CGPoint(x: wordX, y: rect.minY + 4))
                        wordTicks.addLine(to: CGPoint(x: wordX, y: rect.maxY - 4))
                    }
                    let wordWidth = max(0, nextX - wordX - 2)
                    if wordWidth >= 8 {
                        drawSweptCanvasText(
                            span.text,
                            in: CGRect(x: wordX + 2, y: rect.minY, width: wordWidth, height: rect.height),
                            playheadX: playheadX,
                            context: clipped
                        )
                    }
                }
                clipped.stroke(wordTicks, with: .color(.primary.opacity(0.14)), lineWidth: 0.75)
            } else {
                let text = lineLabel(line)
                let tokens = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                let usableLeft = rect.minX + 6
                let usableWidth = max(0, rect.width - 16)
                if tokens.count > 1, usableWidth >= 40 {
                    let weights = tokens.map { max(1.0, Double($0.count) + 0.5) }
                    let totalWeight = max(1.0, weights.reduce(0, +))
                    var acc = 0.0
                    for (idx, token) in tokens.enumerated() {
                        let slotX = usableLeft + usableWidth * CGFloat(acc / totalWeight)
                        let slotW = usableWidth * CGFloat(weights[idx] / totalWeight)
                        acc += weights[idx]
                        drawSweptCanvasText(
                            token,
                            in: CGRect(x: slotX, y: rect.minY, width: max(8, slotW - 2), height: rect.height),
                            playheadX: playheadX,
                            context: clipped
                        )
                    }
                } else {
                    drawSweptCanvasText(
                        text,
                        in: CGRect(x: usableLeft, y: rect.minY, width: usableWidth, height: rect.height),
                        playheadX: playheadX,
                        context: clipped
                    )
                }
            }
        }
    }

    private func drawSweptCanvasText(
        _ label: String,
        in slotRect: CGRect,
        playheadX: CGFloat,
        context: GraphicsContext
    ) {
        let point = CGPoint(x: slotRect.minX, y: slotRect.midY)
        let isSung = slotRect.minX <= playheadX
        var slotClip = context
        slotClip.clip(to: Path(slotRect))
        slotClip.draw(
            Text(label)
                .font(isSung ? .caption2.weight(.medium) : .caption2)
                .foregroundColor(isSung ? .primary : .secondary),
            at: point,
            anchor: .leading
        )
    }

    private func drawSelectedLineWords(context: GraphicsContext, size: CGSize) {
        guard let lineIdx = selectedLineIndex, lines.indices.contains(lineIdx) else { return }
        let line = lines[lineIdx]
        let nextStart = line.timestamp.flatMap { nextLaterByStart[$0] }
        let lineEnd = LyricTimingSession.derivedLineEnd(
            for: line,
            nextLaterStart: nextStart,
            fallbackDuration: TimelineLayoutMath.finalLineFallbackDuration
        )
        let words = line.words
        let nextWordStarts = nextWordStartsByLine[line.id] ?? []
        let spans = wordSpans(line)
        var labelByWord: [Int: String] = [:]
        var consumedWords: Set<Int> = []
        for span in spans where !span.label.isEmpty {
            labelByWord[span.sourceRange.lowerBound] = span.label
            if span.sourceRange.upperBound > span.sourceRange.lowerBound {
                for idx in (span.sourceRange.lowerBound + 1)...span.sourceRange.upperBound {
                    consumedWords.insert(idx)
                }
            }
        }
        for (wordIdx, word) in words.enumerated() {
            guard let wordStart = word.timestamp else { continue }
            let nextWordStart = nextWordStarts.indices.contains(wordIdx) ? nextWordStarts[wordIdx] : nil
            let wordDur = TimelineLayoutMath.wordDuration(
                word: word,
                wordStart: wordStart,
                nextWordStart: nextWordStart,
                lineEnd: lineEnd
            )
            let rect = TimelineLayoutMath.wordBlockRect(
                start: wordStart,
                duration: wordDur,
                viewportStart: viewportStart,
                pixelsPerSecond: pixelsPerSecond
            )
            guard TimelineLayoutMath.isBlockVisible(rect, viewportWidth: size.width) else { continue }
            let shape = Path(roundedRect: rect, cornerRadius: 4)
            let isActive = playheadTime >= wordStart && playheadTime <= wordStart + wordDur
            context.fill(shape, with: .color(.orange.opacity(isActive ? 0.28 : 0.16)))
            if playheadTime > wordStart {
                let sweepFrac = wordDur > 0 ? min(1.0, max(0.0, (playheadTime - wordStart) / wordDur)) : 1.0
                let sweepRect = CGRect(x: rect.minX, y: rect.minY, width: rect.width * CGFloat(sweepFrac), height: rect.height)
                var sweepCtx = context
                sweepCtx.clip(to: shape)
                sweepCtx.fill(Path(sweepRect), with: .color(.orange.opacity(isActive ? 0.45 : 0.18)))
            }
            context.stroke(shape, with: .color(.orange.opacity(isActive ? 0.95 : 0.55)), lineWidth: isActive ? 1.5 : 1)

            var clipped = context
            clipped.clip(to: Path(CGRect(x: rect.minX + 3, y: rect.minY, width: max(0, rect.width - 6), height: rect.height)))
            let label = labelByWord[wordIdx] ?? (consumedWords.contains(wordIdx) ? "·" : word.text.trimmingCharacters(in: .whitespaces))
            clipped.draw(
                Text(label).font(.caption2).foregroundColor(.primary),
                at: CGPoint(x: rect.minX + 4, y: rect.midY),
                anchor: .leading
            )
        }
    }

    private func drawPlayhead(context: GraphicsContext, size: CGSize) {
        guard drawsPlayhead else { return }
        let px = screenX(for: playheadTime)
        guard px >= -8, px <= size.width + 8 else { return }
        var line = Path()
        line.move(to: CGPoint(x: px, y: 0))
        line.addLine(to: CGPoint(x: px, y: size.height))
        context.stroke(line, with: .color(.red), lineWidth: 1.5)

        let cap = CGRect(x: px - 4, y: 0, width: 8, height: 8)
        context.fill(Path(roundedRect: cap, cornerRadius: 2), with: .color(.red))
    }
}

private struct LiveEditorKaraokePreview: View {
    let state: LyricsState
    @ObservedObject var model: LyricTimingEditorModel
    let fallbackLabel: String

    var body: some View {
        let interval = state.lowCPUMode ? (1.0 / 6.0) : (1.0 / 12.0)
        TimelineView(.animation(minimumInterval: interval, paused: !model.isPlaying)) { context in
            let pos = model.currentEditorPlaybackPosition(at: context.date)
            if let active = model.activeLineAndProgress(at: pos) {
                KaraokePreviewText(text: active.text, progress: active.progress, isRTL: active.isRTL)
            } else {
                Text(fallbackLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}

struct KaraokePreviewText: View {
    let text: String
    let progress: Double
    let isRTL: Bool

    @Environment(\.layoutDirection) private var layoutDirection

    var body: some View {
        let clampedProgress = progress.isFinite ? min(1.0, max(0.0, progress)) : 0.0
        let readingEdge: Alignment = isRTL == (layoutDirection == .rightToLeft) ? .leading : .trailing
        let label = Text(verbatim: text)
            .font(.system(size: LyricTimingEditorModel.previewFontSize, weight: .medium))
            .lineLimit(1)

        // The proposed size sets the viewport. Both text layers and the mask use the full line width.
        label.hidden()
            .overlay(alignment: readingEdge) {
                label.fixedSize()
                    .foregroundStyle(.secondary.opacity(0.45))
                    .overlay {
                        label.foregroundStyle(Color.accentColor)
                            .mask {
                                GeometryReader { geo in
                                    Rectangle()
                                        .frame(width: geo.size.width * CGFloat(clampedProgress))
                                        .frame(maxWidth: .infinity, alignment: readingEdge)
                                }
                            }
                    }
            }
            .clipped()
            .frame(maxWidth: 360)
    }
}

extension LyricTimingEditorModel {
    private struct TimedPreviewSpan {
        let index: Int
        let start: Double
        let end: Double
    }

    func activeLineAndProgress(at pos: Double) -> (text: String, progress: Double, isRTL: Bool)? {
        let lines = session.lines
        var activeIdx: Int?
        var bestTimestamp = -Double.infinity
        for idx in lines.indices {
            guard let ts = lines[idx].timestamp, ts <= pos, ts >= bestTimestamp else { continue }
            bestTimestamp = ts
            activeIdx = idx
        }
        guard let idx = activeIdx, let start = lines[idx].timestamp else { return nil }
        let line = lines[idx]
        let nextStart = nextLaterByStart[start]
        let derivedEnd = LyricTimingSession.derivedLineEnd(
            for: line,
            nextLaterStart: nextStart,
            fallbackDuration: TimelineLayoutMath.finalLineFallbackDuration
        ) ?? (start + TimelineLayoutMath.finalLineFallbackDuration)
        let displayEnd = max(start + 0.3, derivedEnd)
        guard pos <= displayEnd + 0.5 else { return nil }
        let lineProgress = derivedEnd > start ? min(1.0, max(0.0, (pos - start) / (derivedEnd - start))) : 1.0

        let display: String
        let progress: Double
        if LyricTimingEditorModel.hasCompleteTimedWords(line) {
            let spans = displayWordSpans(for: line)
            let nextWordStarts = nextWordStartsByLineId[line.id] ?? []
            let pieces = spans.map(\.previewText)
            let timedSpans: [TimedPreviewSpan] = spans.enumerated().compactMap { spanIdx, span in
                let slice = span.sourceRange.compactMap { wordIdx -> (Int, Double)? in
                    guard line.words.indices.contains(wordIdx), let ts = line.words[wordIdx].timestamp else { return nil }
                    return (wordIdx, ts)
                }
                guard let first = slice.min(by: { $0.1 < $1.1 }),
                      let last = slice.max(by: { $0.1 < $1.1 })
                else { return nil }
                let nextWordStart = nextWordStarts.indices.contains(last.0) ? nextWordStarts[last.0] : nil
                let dur = TimelineLayoutMath.wordDuration(
                    word: line.words[last.0],
                    wordStart: last.1,
                    nextWordStart: nextWordStart,
                    lineEnd: derivedEnd
                )
                return TimedPreviewSpan(index: spanIdx, start: first.1, end: max(first.1, last.1 + dur))
            }

            display = pieces.joined()
            // A single leading-edge mask can only follow non-overlapping stamps that advance in text order.
            if zip(timedSpans, timedSpans.dropFirst()).allSatisfy({ $0.start <= $1.start && $0.end <= $1.start + 0.001 }) {
                progress = Self.wordLevelProgress(
                    at: pos,
                    boundaries: previewWordBoundaries(for: line.id, pieces: pieces),
                    timedSpans: timedSpans
                )
            } else {
                progress = lineProgress
            }
        } else {
            if let rom = romanizedLinePreview(for: line.text), !rom.isEmpty {
                display = rom
            } else {
                display = line.text.isEmpty ? "♪" : line.text
            }
            progress = lineProgress
        }
        return (display, progress, isRightToLeftPreview(for: display))
    }

    private static func wordLevelProgress(
        at pos: Double,
        boundaries: [Double],
        timedSpans: [TimedPreviewSpan]
    ) -> Double {
        let pieceCount = max(0, boundaries.count - 1)
        guard pieceCount > 0 else { return 0.0 }

        if let first = timedSpans.first, pos <= first.start {
            return boundaries[min(pieceCount, first.index)]
        }
        for slot in timedSpans.indices {
            let span = timedSpans[slot]
            let nextStart = slot + 1 < timedSpans.count ? timedSpans[slot + 1].start : span.end
            let nextPieceIdx: Int = if slot + 1 < timedSpans.count, timedSpans[slot + 1].index > span.index {
                timedSpans[slot + 1].index
            } else {
                min(pieceCount, span.index + 1)
            }
            if pos <= nextStart || slot + 1 == timedSpans.count {
                let dur = span.end - span.start
                let frac = dur > 0 ? min(1.0, max(0.0, (pos - span.start) / dur)) : (pos >= span.start ? 1.0 : 0.0)
                let startFrac = boundaries[min(pieceCount, span.index)]
                let endFrac = boundaries[min(pieceCount, nextPieceIdx)]
                return startFrac + (endFrac - startFrac) * frac
            }
        }
        return 1.0
    }
}

private struct TimelineOverviewBar: View {
    let totalSeconds: Double
    let viewportStart: Double
    let visibleDuration: Double
    let playheadTime: Double
    let onJump: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            let denom = max(1.0, totalSeconds)
            let thumbX = CGFloat(viewportStart / denom) * width
            let thumbW = max(24, CGFloat(min(1.0, visibleDuration / denom)) * width)
            let playheadX = CGFloat(min(1.0, max(0.0, playheadTime / denom))) * width

            ZStack(alignment: .leading) {
                Rectangle().fill(Color.primary.opacity(0.06))
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.secondary.opacity(0.35))
                    .frame(width: min(width, thumbW), height: 8)
                    .offset(x: min(max(0, width - thumbW), max(0, thumbX)))
                Rectangle()
                    .fill(Color.red.opacity(0.85))
                    .frame(width: 2, height: 12)
                    .offset(x: playheadX)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let ratio = min(1.0, max(0.0, Double(value.location.x / width)))
                        onJump(ratio * totalSeconds - visibleDuration * 0.5)
                    }
            )
        }
    }
}

private struct TimelineScrollWheelCatcher: NSViewRepresentable {
    let onScroll: (CGFloat, CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> ScrollWheelNSView {
        let view = ScrollWheelNSView()
        view.onScroll = onScroll
        view.installMonitor()
        return view
    }

    func updateNSView(_ nsView: ScrollWheelNSView, context: Context) {
        nsView.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: ScrollWheelNSView, coordinator: ()) {
        nsView.removeMonitor()
    }

    final class ScrollWheelNSView: NSView {
        var onScroll: ((CGFloat, CGFloat, Bool) -> Void)?
        private var monitor: Any?

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let win = self.window, event.window === win else { return event }
                let localPoint = self.convert(event.locationInWindow, from: nil)
                guard self.bounds.contains(localPoint) else { return event }
                let isZoom = event.modifierFlags.contains(.option) || event.modifierFlags.contains(.command)
                let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1.0 : 12.0
                self.onScroll?(event.scrollingDeltaX * scale, event.scrollingDeltaY * scale, isZoom)
                return nil
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }
    }
}
