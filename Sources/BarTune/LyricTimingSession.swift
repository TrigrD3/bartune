import Foundation

struct EditableWord: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    var timestamp: Double?
    /// Exact duration imported from source word timing; cleared once the word is retimed.
    var preservedDuration: Double?

    init(id: UUID = UUID(), text: String, timestamp: Double? = nil, preservedDuration: Double? = nil) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.preservedDuration = preservedDuration
    }
}

struct EditableLine: Identifiable, Equatable, Sendable {
    let id: UUID
    var text: String
    var timestamp: Double?
    var endTimestamp: Double?
    var words: [EditableWord]

    init(
        id: UUID = UUID(),
        text: String,
        timestamp: Double? = nil,
        endTimestamp: Double? = nil,
        words: [EditableWord] = []
    ) {
        self.id = id
        self.text = text
        self.timestamp = timestamp
        self.endTimestamp = endTimestamp
        self.words = words
    }
}

enum StampingMode: Equatable, Sendable {
    case off
    case lines
    case words(lineIndex: Int)
}

/// Pure editing and tap-stamping model for the Lyric Timing Editor.
struct LyricTimingSession: Equatable, Sendable {
    private enum StampUndoAction: Equatable, Sendable {
        case lineTimestamp(lineId: UUID, previousTimestamp: Double?, previousNextLineIndex: Int)
        case lineEndTimestamp(lineId: UUID, previousEndTimestamp: Double?)
        case wordTimestamp(
            lineId: UUID,
            wordId: UUID,
            previousWordTimestamp: Double?,
            previousWordDuration: Double?,
            previousLineTimestamp: Double?,
            previousNextWordIndex: Int
        )
    }

    var lines: [EditableLine]
    var stampingMode: StampingMode = .off
    var nextLineIndex: Int = 0
    var nextWordIndex: Int = 0
    private var stampUndoStack: [StampUndoAction] = []

    var canUndoStamp: Bool { !stampUndoStack.isEmpty }

    init(lines: [LyricLine] = [], explicitEndIndices: Set<Int>? = nil) {
        self.lines = lines.enumerated().map { index, line in
            let nextStart = (index + 1 < lines.count) ? lines[index + 1].timestamp : nil
            let explicitEnd: Double?
            if let dur = line.duration {
                let candidate = max(line.timestamp, line.timestamp + dur)
                if let explicitEndIndices {
                    explicitEnd = explicitEndIndices.contains(index) ? candidate : nil
                } else if let nextStart, abs(candidate - nextStart) < 0.005 {
                    explicitEnd = nil
                } else {
                    explicitEnd = candidate
                }
            } else {
                explicitEnd = nil
            }
            let editableWords = line.words.map { word in
                EditableWord(
                    text: word.text,
                    timestamp: max(0.0, word.timestamp),
                    preservedDuration: word.duration.map { max(0.0, $0) }
                )
            }
            return EditableLine(
                text: line.text,
                timestamp: max(0.0, line.timestamp),
                endTimestamp: explicitEnd,
                words: editableWords
            )
        }
    }

    init(editableLines: [EditableLine]) {
        self.lines = editableLines
    }

    // MARK: - Word Splitting

    /// Splits a line into words for the word-stamping pass: by whitespace when spaces are present,
    /// or per character for CJK text that has no spaces. Spaced words retain their trailing space
    /// (except the last) so joined word text reproduces the line text cleanly.
    static func splitWords(for text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let parts = trimmed.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if parts.count > 1 {
            return parts.enumerated().map { index, part in
                index + 1 < parts.count ? part + " " : part
            }
        }
        if containsCJK(trimmed) {
            return trimmed.map { String($0) }
        }
        return [trimmed]
    }

    private static func containsCJK(_ text: String) -> Bool {
        JapaneseRomanizer.containsJapaneseOrCJK(text) || KoreanRomanizer.containsHangul(text)
    }

    static func romanizedPreview(forLine text: String) -> String? {
        guard JapaneseRomanizer.containsJapaneseOrCJK(text) else { return nil }
        let romaji = JapaneseRomanizer.romanizeLine(text)
        return romaji == text ? nil : romaji
    }

    static func romanizedWordPreviews(for words: [EditableWord]) -> [String] {
        guard !words.isEmpty else { return [] }
        let texts = words.map(\.text)
        guard JapaneseRomanizer.containsJapaneseOrCJK(texts.joined()) else {
            return Array(repeating: "", count: words.count)
        }
        return JapaneseRomanizer.romanizeWords(texts)
    }

    // MARK: - Line Text & Structure Editing

    mutating func replaceWithPlainText(_ plainText: String) {
        let parsed = plainText
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { EditableLine(text: $0) }
        lines = parsed
        stampingMode = .off
        nextLineIndex = 0
        nextWordIndex = 0
        stampUndoStack.removeAll()
    }

    private static func normalizedTextForWordComparison(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    mutating func updateLineText(at index: Int, to newText: String) {
        guard lines.indices.contains(index) else { return }
        guard lines[index].text != newText else { return }
        lines[index].text = newText
        if !lines[index].words.isEmpty {
            let joined = Self.normalizedTextForWordComparison(lines[index].words.map(\.text).joined())
            if joined != Self.normalizedTextForWordComparison(newText) {
                lines[index].words = []
                if case let .words(activeLine) = stampingMode, activeLine == index {
                    stampingMode = .off
                    nextWordIndex = 0
                }
            }
        }
    }

    @discardableResult
    mutating func addLine(after index: Int? = nil, text: String = "") -> Int {
        let insertIndex: Int = if let index, lines.indices.contains(index) {
            index + 1
        } else {
            lines.count
        }
        lines.insert(EditableLine(text: text), at: insertIndex)
        if nextLineIndex > insertIndex {
            nextLineIndex += 1
        }
        if case let .words(activeLine) = stampingMode, activeLine >= insertIndex {
            stampingMode = .words(lineIndex: activeLine + 1)
        }
        return insertIndex
    }

    mutating func deleteLine(at index: Int) {
        guard lines.indices.contains(index) else { return }
        lines.remove(at: index)
        if nextLineIndex > index {
            nextLineIndex -= 1
        }
        nextLineIndex = min(nextLineIndex, lines.count)
        if case let .words(activeLine) = stampingMode {
            if activeLine == index {
                stampingMode = .off
                nextWordIndex = 0
            } else if activeLine > index {
                stampingMode = .words(lineIndex: activeLine - 1)
            }
        }
    }

    mutating func clearWords(forLine index: Int) {
        guard lines.indices.contains(index) else { return }
        lines[index].words = []
        if case let .words(activeLine) = stampingMode, activeLine == index {
            nextWordIndex = 0
        }
    }

    // MARK: - Tap-to-Time Stamping

    mutating func beginLinePass(from index: Int = 0) {
        nextLineIndex = max(0, min(index, lines.count))
        stampingMode = .lines
    }

    mutating func beginWordPass(forLine index: Int, from wordIndex: Int = 0) {
        guard lines.indices.contains(index) else { return }
        ensureWordsInitialized(forLine: index)
        nextWordIndex = max(0, min(wordIndex, lines[index].words.count))
        stampingMode = .words(lineIndex: index)
    }

    mutating func ensureWordsInitialized(forLine index: Int) {
        guard lines.indices.contains(index) else { return }
        let expected = Self.splitWords(for: lines[index].text)
        let currentJoined = Self.normalizedTextForWordComparison(lines[index].words.map(\.text).joined())
        let expectedJoined = Self.normalizedTextForWordComparison(expected.joined())
        if lines[index].words.isEmpty || currentJoined != expectedJoined {
            lines[index].words = expected.map { EditableWord(text: $0) }
        }
    }

    mutating func stopStamping() {
        stampingMode = .off
    }

    @discardableResult
    mutating func stamp(at position: Double) -> Bool {
        let clamped = Self.clampTime(position)
        switch stampingMode {
        case .off:
            return false
        case .lines:
            guard nextLineIndex < lines.count else { return false }
            let target = lines[nextLineIndex]
            stampUndoStack.append(.lineTimestamp(
                lineId: target.id,
                previousTimestamp: target.timestamp,
                previousNextLineIndex: nextLineIndex
            ))
            lines[nextLineIndex].timestamp = clamped
            nextLineIndex += 1
            return true
        case let .words(lineIndex):
            guard lines.indices.contains(lineIndex),
                  nextWordIndex < lines[lineIndex].words.count
            else { return false }
            let line = lines[lineIndex]
            let word = line.words[nextWordIndex]
            stampUndoStack.append(.wordTimestamp(
                lineId: line.id,
                wordId: word.id,
                previousWordTimestamp: word.timestamp,
                previousWordDuration: word.preservedDuration,
                previousLineTimestamp: line.timestamp,
                previousNextWordIndex: nextWordIndex
            ))
            lines[lineIndex].words[nextWordIndex].timestamp = clamped
            lines[lineIndex].words[nextWordIndex].preservedDuration = nil
            if nextWordIndex == 0, lines[lineIndex].timestamp == nil {
                lines[lineIndex].timestamp = clamped
            }
            nextWordIndex += 1
            return true
        }
    }

    @discardableResult
    mutating func stampLineEnd(at position: Double, forLine index: Int) -> Bool {
        guard lines.indices.contains(index) else { return false }
        let line = lines[index]
        stampUndoStack.append(.lineEndTimestamp(
            lineId: line.id,
            previousEndTimestamp: line.endTimestamp
        ))
        lines[index].endTimestamp = Self.clampTime(position)
        return true
    }

    @discardableResult
    mutating func undoLastStamp() -> Bool {
        while let action = stampUndoStack.popLast() {
            switch action {
            case let .lineTimestamp(lineId, previousTimestamp, _):
                guard let lineIndex = lines.firstIndex(where: { $0.id == lineId }) else { continue }
                lines[lineIndex].timestamp = previousTimestamp
                nextLineIndex = lineIndex
                return true
            case let .lineEndTimestamp(lineId, previousEndTimestamp):
                guard let lineIndex = lines.firstIndex(where: { $0.id == lineId }) else { continue }
                lines[lineIndex].endTimestamp = previousEndTimestamp
                return true
            case let .wordTimestamp(
                lineId,
                wordId,
                previousWordTimestamp,
                previousWordDuration,
                previousLineTimestamp,
                _
            ):
                guard let lineIndex = lines.firstIndex(where: { $0.id == lineId }),
                      let wordIndex = lines[lineIndex].words.firstIndex(where: { $0.id == wordId })
                else { continue }
                lines[lineIndex].words[wordIndex].timestamp = previousWordTimestamp
                lines[lineIndex].words[wordIndex].preservedDuration = previousWordDuration
                if wordIndex == 0 {
                    lines[lineIndex].timestamp = previousLineTimestamp
                }
                if case let .words(activeLine) = stampingMode, activeLine == lineIndex {
                    nextWordIndex = wordIndex
                }
                return true
            }
        }
        return false
    }

    // MARK: - Fine-Tuning (Nudging & Direct Entry)

    mutating func nudgeLine(at index: Int, by delta: Double) {
        guard lines.indices.contains(index) else { return }
        let oldTimestamp = lines[index].timestamp ?? 0.0
        let newTimestamp = Self.clampTime(oldTimestamp + delta)
        let appliedDelta = newTimestamp - oldTimestamp
        lines[index].timestamp = newTimestamp
        if let end = lines[index].endTimestamp {
            lines[index].endTimestamp = Self.clampTime(end + appliedDelta)
        }
        for wordIndex in lines[index].words.indices {
            if let wordTs = lines[index].words[wordIndex].timestamp {
                lines[index].words[wordIndex].timestamp = Self.clampTime(wordTs + appliedDelta)
            }
        }
    }

    mutating func setLineTimestamp(at index: Int, to seconds: Double?) {
        guard lines.indices.contains(index) else { return }
        lines[index].timestamp = seconds.map(Self.clampTime)
    }

    mutating func setLineEndTimestamp(at index: Int, to seconds: Double?) {
        guard lines.indices.contains(index) else { return }
        lines[index].endTimestamp = seconds.map(Self.clampTime)
    }

    mutating func nudgeWord(lineIndex: Int, wordIndex: Int, by delta: Double) {
        guard lines.indices.contains(lineIndex),
              lines[lineIndex].words.indices.contains(wordIndex)
        else { return }
        let base = lines[lineIndex].words[wordIndex].timestamp ?? lines[lineIndex].timestamp ?? 0.0
        lines[lineIndex].words[wordIndex].timestamp = Self.clampTime(base + delta)
        lines[lineIndex].words[wordIndex].preservedDuration = nil
    }

    mutating func setWordTimestamp(lineIndex: Int, wordIndex: Int, to seconds: Double?) {
        guard lines.indices.contains(lineIndex),
              lines[lineIndex].words.indices.contains(wordIndex)
        else { return }
        lines[lineIndex].words[wordIndex].timestamp = seconds.map(Self.clampTime)
        lines[lineIndex].words[wordIndex].preservedDuration = nil
    }

    private static func clampTime(_ seconds: Double) -> Double {
        guard seconds.isFinite else { return 0.0 }
        return max(0.0, (seconds * 1000.0).rounded() / 1000.0)
    }

    // MARK: - Out-of-Order Warnings

    func outOfOrderLineIndices() -> Set<Int> {
        var warnings: Set<Int> = []
        var maxSeen: Double?
        for (index, line) in lines.enumerated() {
            guard let ts = line.timestamp else { continue }
            if let maxSeen, ts < maxSeen {
                warnings.insert(index)
            }
            maxSeen = max(maxSeen ?? ts, ts)
            if let end = line.endTimestamp, end < ts {
                warnings.insert(index)
            }
        }
        return warnings
    }

    func outOfOrderWordIndices(inLine lineIndex: Int) -> Set<Int> {
        guard lines.indices.contains(lineIndex) else { return [] }
        let line = lines[lineIndex]
        var warnings: Set<Int> = []
        var maxSeen: Double?
        for (index, word) in line.words.enumerated() {
            guard let ts = word.timestamp else { continue }
            if let lineTs = line.timestamp, ts < lineTs {
                warnings.insert(index)
            }
            if let maxSeen, ts < maxSeen {
                warnings.insert(index)
            }
            maxSeen = max(maxSeen ?? ts, ts)
        }
        return warnings
    }

    var hasOutOfOrderWarnings: Bool {
        if !outOfOrderLineIndices().isEmpty {
            return true
        }
        return lines.indices.contains { !outOfOrderWordIndices(inLine: $0).isEmpty }
    }

    // MARK: - Duration Derivation & Export

    /// 1-based line numbers of non-empty lines that still have no start timestamp.
    var unstampedLineNumbers: [Int] {
        lines.enumerated().compactMap { index, line in
            let hasText = !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return (hasText && line.timestamp == nil) ? (index + 1) : nil
        }
    }

    /// 0-based indices (within `buildLyricLines()`) whose end timestamp was explicitly set.
    var explicitEndLineIndices: Set<Int> {
        var indices: Set<Int> = []
        var builtIndex = 0
        for line in lines where line.timestamp != nil {
            if let end = line.endTimestamp, let start = line.timestamp, end > start {
                indices.insert(builtIndex)
            }
            builtIndex += 1
        }
        return indices
    }

    func buildLyricLines() -> [LyricLine] {
        let stampedLines: [(EditableLine, Double)] = lines.compactMap { line in
            guard let start = line.timestamp else { return nil }
            return (line, start)
        }

        return stampedLines.enumerated().map { index, pair in
            let (line, start) = pair
            let nextLineStart = (index + 1 < stampedLines.count) ? stampedLines[index + 1].1 : nil

            let lineEnd: Double? = if let explicitEnd = line.endTimestamp, explicitEnd > start {
                explicitEnd
            } else if let nextLineStart, nextLineStart > start {
                nextLineStart
            } else {
                nil
            }
            let lineDuration = lineEnd.map { $0 - start }

            let stampedWords: [(EditableWord, Double)] = line.words.compactMap { word in
                guard let wordStart = word.timestamp else { return nil }
                return (word, wordStart)
            }
            let builtWords: [WordTimestamp] = stampedWords.enumerated().map { wordIndex, wordPair in
                let (word, wordStart) = wordPair
                let wordDuration: Double?
                if let preserved = word.preservedDuration {
                    wordDuration = preserved
                } else {
                    let nextWordStart = (wordIndex + 1 < stampedWords.count) ? stampedWords[wordIndex + 1].1 : nil
                    let wordEnd: Double? = if let nextWordStart, nextWordStart > wordStart {
                        nextWordStart
                    } else if let lineEnd, lineEnd > wordStart {
                        lineEnd
                    } else {
                        nil
                    }
                    wordDuration = wordEnd.map { $0 - wordStart }
                }
                return WordTimestamp(timestamp: wordStart, duration: wordDuration, text: word.text)
            }

            return LyricLine(
                id: index,
                timestamp: start,
                duration: lineDuration,
                text: line.text,
                words: builtWords
            )
        }
    }

    // MARK: - Time Formatting & Parsing

    static func formatTime(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite else { return "—" }
        let clamped = max(0.0, seconds)
        let totalHundredths = Int((clamped * 100.0).rounded())
        let minutes = totalHundredths / 6000
        let sec = (totalHundredths % 6000) / 100
        let hundredths = totalHundredths % 100
        return String(format: "%d:%02d.%02d", minutes, sec, hundredths)
    }

    static func parseTime(_ text: String) -> Double? {
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: ",", with: ".")
        guard !trimmed.isEmpty else { return nil }
        if trimmed.contains(":") {
            let parts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2,
                  let minutes = Double(parts[0]),
                  let seconds = Double(parts[1]),
                  minutes.isFinite, seconds.isFinite,
                  minutes >= 0, seconds >= 0, seconds < 60
            else { return nil }
            return clampTime(minutes * 60.0 + seconds)
        }
        guard let value = Double(trimmed), value.isFinite, value >= 0 else { return nil }
        return clampTime(value)
    }
}
