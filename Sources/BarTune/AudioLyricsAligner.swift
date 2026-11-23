import CryptoKit
import Foundation
import NaturalLanguage

enum AudioSyncEngine: String, CaseIterable, Identifiable, Codable, Sendable {
    case off = "off"
    case lyricsAlignment = "lyricsAlignment"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .lyricsAlignment: return "Lyrics Alignment"
        }
    }

    var description: String {
        switch self {
        case .off:
            return "Uses fetched LRC/YRC timestamps only (no System Audio Recording permission required)."
        case .lyricsAlignment:
            return "Aligns the fetched lyrics to the song's audio on the Neural Engine instead of transcribing it (Apple silicon, alignment model required)."
        }
    }
}

struct OverlaySyncBadge: Equatable, Sendable {
    let symbolName: String
    let text: String
    let isSynced: Bool
}

enum AudioSyncStatus: Equatable, Sendable {
    case idle
    case cached(AudioSyncEngine)
    case syncing(engine: AudioSyncEngine, alignedLines: Int, totalLines: Int)
    case permissionRequired(String)
    case unavailable(String)
    /// The song's lyric source overrides the enabled engine.
    case offForTrack(TrackLyricSource)

    var allowsResync: Bool {
        if case .offForTrack = self { return false }
        return true
    }

    var overlayBadge: OverlaySyncBadge? {
        switch self {
        case .cached:
            return OverlaySyncBadge(symbolName: "checkmark.circle.fill", text: "Synced", isSynced: true)
        case let .syncing(_, aligned, _):
            return OverlaySyncBadge(
                symbolName: "waveform",
                text: aligned > 0 ? "Syncing" : "Listening",
                isSynced: false
            )
        case .idle, .permissionRequired, .unavailable, .offForTrack:
            return nil
        }
    }

    var label: String {
        switch self {
        case .idle:
            return "Idle"
        case let .cached(engine):
            return "Cached (\(engine.title))"
        case let .syncing(engine, aligned, total):
            if aligned > 0 {
                return "Syncing via \(engine.title) (\(aligned)/\(total) lines)…"
            }
            return "Listening via \(engine.title)…"
        case let .permissionRequired(detail):
            return detail
        case let .unavailable(detail):
            return detail
        case let .offForTrack(source):
            return "Off for this song (\(source.title) lyrics selected)"
        }
    }
}

struct RecognizedAudioWord: Equatable, Codable, Sendable {
    let text: String
    let startTime: Double
    let duration: Double
    let confidence: Double

    var endTime: Double { startTime + max(0.04, duration) }
}

struct AudioAlignmentResult: Equatable, Sendable {
    let lines: [LyricLine]
    let matchedLineCount: Int
    let matchedWordCount: Int
    let medianOffset: Double?
    /// IDs of the lines whose timing came from recognized audio, in line order.
    var matchedLineIDs: [Int] = []
}

struct AudioSyncedLyricsRecord: Equatable, Codable, Sendable {
    let trackId: String
    let engine: AudioSyncEngine
    let syncedAt: Date
    let medianOffset: Double?
    let alignedLineCount: Int
    let sourceLineCount: Int?
    let lines: [LyricLine]
    /// Words heard so far, so a later play can add to a partial sync instead of starting over.
    let heardWords: [RecognizedAudioWord]?
    /// Lyrics Alignment: lines the engine had the audio for but could not align; not listened for again.
    let checkedLineIDs: [Int]?

    init(
        trackId: String,
        engine: AudioSyncEngine,
        syncedAt: Date,
        medianOffset: Double?,
        alignedLineCount: Int,
        sourceLineCount: Int? = nil,
        lines: [LyricLine],
        heardWords: [RecognizedAudioWord]? = nil,
        checkedLineIDs: [Int]? = nil
    ) {
        self.trackId = trackId
        self.engine = engine
        self.syncedAt = syncedAt
        self.medianOffset = medianOffset
        self.alignedLineCount = alignedLineCount
        self.sourceLineCount = sourceLineCount
        self.lines = lines
        self.heardWords = heardWords
        self.checkedLineIDs = checkedLineIDs
    }

    /// Evaluates whether a cached alignment is trustworthy enough to skip live re-syncing.
    /// Rejects incomplete transcript-only caches (fewer non-empty lines than the source lyrics),
    /// single-line partial matches on multi-line tracks, extreme outlier offsets (> 5s), and
    /// duplicate/inverted line timestamps from cross-line bleed.
    var isReliable: Bool {
        isReliable(expectedSourceLineCount: nil)
    }

    /// Share of lyric lines that must be heard before a sync counts as complete and stops listening.
    static let completeLineFraction = 0.6

    static func linesNeededForCompletion(of lineCount: Int) -> Int {
        max(1, Int((Double(lineCount) * completeLineFraction).rounded(.up)))
    }

    /// False when the lyrics changed since this record was aligned (e.g. a different version was fetched).
    /// Transcription records rewrite line text, so only their line count is compared.
    func matchesSource(_ sourceLines: [LyricLine], comparingText: Bool) -> Bool {
        func texts(_ lines: [LyricLine]) -> [String] {
            lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let source = texts(sourceLines)
        if let sourceLineCount, sourceLineCount != source.count {
            return false
        }
        return !comparingText || texts(lines) == source
    }

    /// A reliable record that matched enough lines to skip listening again on the next play.
    func isComplete(expectedSourceLineCount: Int?) -> Bool {
        guard isReliable(expectedSourceLineCount: expectedSourceLineCount) else { return false }
        let nonEmpty = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let reference = max(nonEmpty, sourceLineCount ?? expectedSourceLineCount ?? 0)
        return alignedLineCount >= Self.linesNeededForCompletion(of: reference)
    }

    func isReliable(expectedSourceLineCount: Int?) -> Bool {
        let nonEmpty = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmpty.isEmpty else { return false }
        if let offset = medianOffset, abs(offset) > 5.0 {
            return false
        }
        for idx in 1..<nonEmpty.count where nonEmpty[idx].timestamp < nonEmpty[idx - 1].timestamp + 0.15 {
            return false
        }
        // Playback lookup binary-searches every line, so blank markers must be in order too.
        for idx in 1..<lines.count where lines[idx].timestamp < lines[idx - 1].timestamp {
            return false
        }
        let resolvedSourceCount = sourceLineCount ?? expectedSourceLineCount
        if let sourceCount = resolvedSourceCount, nonEmpty.count < sourceCount {
            return false
        }
        let referenceCount = max(nonEmpty.count, resolvedSourceCount ?? 0)
        let minRequired = min(2, referenceCount)
        return alignedLineCount >= minRequired
    }
}

struct AudioSyncedLyricsCache: Sendable {
    let directory: URL

    static var `default`: AudioSyncedLyricsCache {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("com.arya.BarTune/audio-sync", isDirectory: true)
        return AudioSyncedLyricsCache(directory: dir)
    }

    private func fileURL(for trackId: String) -> URL {
        let digest = SHA256.hash(data: Data(trackId.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hex).json")
    }

    func load(trackId: String) -> AudioSyncedLyricsRecord? {
        let url = fileURL(for: trackId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        // A record that no longer decodes (e.g. from the removed Apple Speech engine) is dropped so the song syncs fresh.
        guard let record = try? JSONDecoder().decode(AudioSyncedLyricsRecord.self, from: data) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        guard !record.lines.isEmpty else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return record
    }

    func save(_ record: AudioSyncedLyricsRecord) {
        guard !record.lines.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(record) else { return }
        try? data.write(to: fileURL(for: record.trackId), options: .atomic)
    }

    func remove(trackId: String) {
        try? FileManager.default.removeItem(at: fileURL(for: trackId))
    }

    func fileURL(forCacheKey cacheKey: String) -> URL {
        directory.appendingPathComponent("\(cacheKey).json")
    }

    func removeByCacheKey(_ cacheKey: String) {
        try? FileManager.default.removeItem(at: fileURL(forCacheKey: cacheKey))
    }

    func syncEngine(forCacheKey cacheKey: String) -> AudioSyncEngine? {
        let url = directory.appendingPathComponent("\(cacheKey).json")
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(AudioSyncedLyricsRecord.self, from: data),
              !record.lines.isEmpty
        else { return nil }
        return record.engine
    }

    func clear() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            try? fm.removeItem(at: file)
        }
    }

    func stats() -> (count: Int, bytes: Int64) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }

        var count = 0
        var totalBytes: Int64 = 0
        for file in files where file.pathExtension == "json" {
            count += 1
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalBytes += Int64(size)
            }
        }
        return (count, totalBytes)
    }
}

enum LyricsLanguageDetector {
    /// Detects the lyric language from fetched lyrics for Japanese, Korean, Chinese, or other non-English songs.
    static func detectSpeechLocale(for lines: [LyricLine]) -> Locale {
        guard !lines.isEmpty else { return .current }
        let nonEmpty = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let isCJK: (LyricLine) -> Bool = {
            JapaneseRomanizer.containsKana($0.text)
                || KoreanRomanizer.containsHangul($0.text)
                || ChineseRomanizer.containsHan($0.text)
        }
        let cjkLines = nonEmpty.filter(isCJK)
        // A few CJK lines in a mostly Latin song must not pick a CJK recognizer.
        if !cjkLines.isEmpty, cjkLines.count * 2 >= nonEmpty.count {
            if JapaneseRomanizer.isJapaneseTrack(cjkLines) {
                return Locale(identifier: "ja-JP")
            }
            if KoreanRomanizer.isKoreanTrack(cjkLines) {
                return Locale(identifier: "ko-KR")
            }
            return Locale(identifier: "zh-CN")
        }

        let sample = nonEmpty.filter { !isCJK($0) }.prefix(12).map(\.text).joined(separator: " ")
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        if let dominant = recognizer.dominantLanguage, dominant != .undetermined {
            let code = dominant.rawValue
            switch code {
            case "ja": return Locale(identifier: "ja-JP")
            case "ko": return Locale(identifier: "ko-KR")
            case "zh-Hans", "zh-Hant", "zh": return Locale(identifier: "zh-CN")
            case "id": return Locale(identifier: "id-ID")
            case "en": return Locale(identifier: "en-US")
            default: return Locale(identifier: code)
            }
        }
        return .current
    }
}

enum LyricsAudioAligner {
    struct DisplayToken: Equatable {
        let display: String
        let normalized: String
    }

    static func normalizeToken(_ text: String) -> String {
        let folded = text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let scalars = folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(scalars))
    }

    static func containsCJK(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x3040...0x30FF).contains(v) || (0x4E00...0x9FFF).contains(v)
        }
    }

    /// Recognizers can return Japanese and Chinese as single characters or whole phrases.
    /// Each unspaced CJK run is re-split with the lyric tokenizer, timing each character by interpolation
    /// inside its recognized word, so recognized words line up with lyric tokens.
    static func regroupCJKWords(_ words: [RecognizedAudioWord], maxGap: Double = 1.0) -> [RecognizedAudioWord] {
        var out: [RecognizedAudioWord] = []
        var run: [RecognizedAudioWord] = []

        func flushRun() {
            defer { run.removeAll() }
            guard !run.isEmpty else { return }
            var chars: [(char: Character, start: Double, end: Double, confidence: Double)] = []
            for word in run {
                let wordChars = Array(word.text)
                let step = max(0.04, word.duration) / Double(wordChars.count)
                for (idx, char) in wordChars.enumerated() {
                    let start = word.startTime + Double(idx) * step
                    chars.append((char, start, start + step, word.confidence))
                }
            }
            var cursor = 0
            for token in tokenizeLine(String(chars.map(\.char))) {
                let count = token.display.count
                guard count > 0, cursor + count <= chars.count else { break }
                let slice = chars[cursor..<(cursor + count)]
                cursor += count
                guard let first = slice.first, let last = slice.last else { continue }
                out.append(
                    RecognizedAudioWord(
                        text: token.display,
                        startTime: first.start,
                        duration: last.end - first.start,
                        confidence: slice.map(\.confidence).reduce(0, +) / Double(count)
                    )
                )
            }
        }

        for word in words {
            if containsCJK(word.text), !word.text.contains(where: \.isWhitespace) {
                if let previous = run.last, word.startTime - previous.endTime > maxGap {
                    flushRun()
                }
                run.append(word)
            } else {
                flushRun()
                out.append(word)
            }
        }
        flushRun()
        return out
    }

    private static func containsCJKWithoutSpaces(_ text: String) -> Bool {
        let hasCJK = text.unicodeScalars.contains { scalar in
            let v = scalar.value
            return (0x3040...0x30FF).contains(v) || (0x4E00...0x9FFF).contains(v)
        }
        guard hasCJK else { return false }
        let spaceCount = text.filter(\.isWhitespace).count
        return spaceCount * 4 < text.count
    }

    /// Splits a lyric line into tokens while preserving exact text so joining `.display` reproduces `text`.
    /// Uses `CFStringTokenizer` for CJK text without spaces so Japanese/Chinese words align accurately.
    static func tokenizeLine(_ text: String) -> [DisplayToken] {
        guard !text.isEmpty else { return [] }
        if containsCJKWithoutSpaces(text) {
            return tokenizeCJKLine(text)
        }

        var tokens: [DisplayToken] = []
        var idx = text.startIndex

        while idx < text.endIndex {
            var wordEnd = idx
            while wordEnd < text.endIndex, !text[wordEnd].isWhitespace {
                wordEnd = text.index(after: wordEnd)
            }
            var spaceEnd = wordEnd
            while spaceEnd < text.endIndex, text[spaceEnd].isWhitespace {
                spaceEnd = text.index(after: spaceEnd)
            }
            let slice = String(text[idx..<spaceEnd])
            tokens.append(DisplayToken(display: slice, normalized: normalizeToken(slice)))
            idx = spaceEnd
        }

        return tokens
    }

    private static func tokenizeCJKLine(_ text: String) -> [DisplayToken] {
        let cfText = text as CFString
        let range = CFRange(location: 0, length: CFStringGetLength(cfText))
        let locale = Locale(identifier: "ja_JP") as CFLocale
        guard let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault,
            cfText,
            range,
            kCFStringTokenizerUnitWord,
            locale
        ) else {
            return [DisplayToken(display: text, normalized: normalizeToken(text))]
        }

        let nsText = text as NSString
        var tokens: [DisplayToken] = []
        var cursor = 0

        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let tokenRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            guard tokenRange.location != kCFNotFound, tokenRange.length > 0 else { continue }
            if tokenRange.location > cursor {
                let gap = nsText.substring(with: NSRange(location: cursor, length: tokenRange.location - cursor))
                if let last = tokens.popLast() {
                    let merged = last.display + gap
                    tokens.append(DisplayToken(display: merged, normalized: normalizeToken(merged)))
                } else {
                    tokens.append(DisplayToken(display: gap, normalized: normalizeToken(gap)))
                }
            }
            let word = nsText.substring(with: NSRange(location: tokenRange.location, length: tokenRange.length))
            tokens.append(DisplayToken(display: word, normalized: normalizeToken(word)))
            cursor = tokenRange.location + tokenRange.length
        }

        if cursor < nsText.length {
            let tail = nsText.substring(from: cursor)
            if let last = tokens.popLast() {
                let merged = last.display + tail
                tokens.append(DisplayToken(display: merged, normalized: normalizeToken(merged)))
            } else {
                tokens.append(DisplayToken(display: tail, normalized: normalizeToken(tail)))
            }
        }

        return tokens.isEmpty ? [DisplayToken(display: text, normalized: normalizeToken(text))] : tokens
    }

    /// Aligns fetched lyric lines against recognized audio words to produce precise word-level karaoke timings.
    /// When `replaceTextWithTranscription` is true, matched lines permanently use the recognized audio words
    /// as their lyric text (useful when written lyrics differ from sung pronunciation).
    static func align(
        lines: [LyricLine],
        recognizedWords: [RecognizedAudioWord],
        searchWindow: Double = 8.0,
        replaceTextWithTranscription: Bool = false,
        regroupsCJKWords: Bool = true
    ) -> AudioAlignmentResult {
        guard !lines.isEmpty, !recognizedWords.isEmpty else {
            return AudioAlignmentResult(lines: lines, matchedLineCount: 0, matchedWordCount: 0, medianOffset: nil)
        }

        let heardWords = recognizedWords
            .filter { !normalizeToken($0.text).isEmpty }
            .sorted { $0.startTime < $1.startTime }
        // Transcription mode writes the heard words into the lyrics, so it keeps their own boundaries;
        // so do lyric tokens from Lyrics Alignment, which joining across lines would break.
        let sortedRecognized = replaceTextWithTranscription || !regroupsCJKWords ? heardWords : regroupCJKWords(heardWords)

        guard !sortedRecognized.isEmpty else {
            return AudioAlignmentResult(lines: lines, matchedLineCount: 0, matchedWordCount: 0, medianOffset: nil)
        }

        let normalizedRec = sortedRecognized.map { normalizeToken($0.text) }

        // Pass 1: estimate global offset from confident, temporally coherent line matches.
        var offsetSamples: [Double] = []
        for (lineIdx, line) in lines.enumerated() {
            let lineTokens = tokenizeLine(line.text)
            let meaningfulCount = lineTokens.filter { !$0.normalized.isEmpty }.count
            guard meaningfulCount > 0 else { continue }
            let minMatches = meaningfulCount <= 2 ? 1 : max(2, meaningfulCount / 3)
            let nextTs = (lineIdx + 1 < lines.count) ? lines[lineIdx + 1].timestamp : (line.timestamp + 4.5)
            let lineEnd = line.duration.map { line.timestamp + $0 } ?? nextTs
            let matches = matchLineTokens(
                lineTokens: lineTokens,
                expectedStart: line.timestamp,
                window: (line.timestamp - searchWindow)...(lineEnd + searchWindow),
                recognized: sortedRecognized,
                normalizedRec: normalizedRec
            )
            if matches.count >= minMatches,
               let first = matches.first(where: { $0.tokenIndex == 0 }),
               abs(first.word.startTime - line.timestamp) <= 5.0 {
                offsetSamples.append(first.word.startTime - line.timestamp)
            }
        }

        let medianOffset: Double?
        if offsetSamples.count >= 2 {
            let sorted = offsetSamples.sorted()
            let candidate = sorted[sorted.count / 2]
            let consistent = sorted.filter { abs($0 - candidate) <= 1.5 }
            if consistent.count >= 2, abs(candidate) <= 5.0 {
                medianOffset = candidate
            } else {
                medianOffset = nil
            }
        } else {
            medianOffset = nil
        }

        let shift = medianOffset ?? 0.0
        let localPadding = min(searchWindow, medianOffset != nil ? 1.5 : 2.0)
        var alignedLines: [LyricLine] = []
        alignedLines.reserveCapacity(lines.count)
        var matchedLineCount = 0
        var matchedLineIDs: [Int] = []
        var matchedWordCount = 0
        /// Later lines only match words starting after this: just past the last matched word's start, not
        /// its end, because a stretched last word can run right up to the next line's first word.
        var lastConsumedWordStart: Double = 0.0
        var previousLineEnd: Double = 0.0
        var previousEmittedTimestamp: Double?
        var previousBlankTimestamp: Double?

        // Pass 2: align each line inside a tight, monotonic window so adjacent lines never steal words or overlap.
        for (lineIdx, line) in lines.enumerated() {
            let lineTokens = tokenizeLine(line.text)
            let isNonEmpty = !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let nextTs = (lineIdx + 1 < lines.count) ? lines[lineIdx + 1].timestamp : (line.timestamp + 4.5)
            let rawLineDur = max(0.4, line.duration ?? (nextTs - line.timestamp))
            let shiftedStart = max(0, line.timestamp + shift)
            let shiftedEnd = shiftedStart + rawLineDur
            let nextShiftedStart = (lineIdx + 1 < lines.count) ? max(0, nextTs + shift) : (shiftedEnd + localPadding)
            // A blank marker only needs to stay ordered, so it adds no lyric spacing.
            let minAllowedStart = max(
                previousEmittedTimestamp.map { $0 + 0.25 } ?? 0,
                previousLineEnd,
                previousBlankTimestamp.map { $0 + 0.01 } ?? 0
            )

            // Words before `minAllowedStart` would be rejected below, so they can't outrank a later eligible one.
            let windowStart = max(0, lastConsumedWordStart, minAllowedStart, shiftedStart - localPadding)
            let windowEnd = min(shiftedEnd + localPadding, nextShiftedStart + 0.4)

            let matches: [TokenMatch] = windowEnd > windowStart
                ? matchLineTokens(
                    lineTokens: lineTokens,
                    expectedStart: shiftedStart,
                    window: windowStart...windowEnd,
                    recognized: sortedRecognized,
                    normalizedRec: normalizedRec
                )
                : []

            let matchMap = Dictionary(uniqueKeysWithValues: matches.map { ($0.tokenIndex, $0.word) })
            let meaningfulTokenCount = lineTokens.filter { !$0.normalized.isEmpty }.count
            let minMatches = meaningfulTokenCount <= 2 ? 1 : max(2, meaningfulTokenCount / 3)

            if replaceTextWithTranscription {
                let windowWords = sortedRecognized.filter {
                    $0.startTime >= max(lastConsumedWordStart, shiftedStart - 0.6) && $0.startTime < min(shiftedEnd + 0.4, nextShiftedStart)
                }
                let startIsEligible = { (start: Double) in abs(start - shiftedStart) <= 2.5 && start >= minAllowedStart }
                if let matchedSpan = Self.matchedTranscriptionSpan(
                    lineTokens: lineTokens,
                    recognized: windowWords,
                    acceptsStart: startIsEligible
                ), let startTs = matchedSpan.first?.startTime {
                    matchedLineCount += 1
                    matchedLineIDs.append(line.id)
                    matchedWordCount += matchedSpan.count
                    let transcribedWords: [WordTimestamp] = matchedSpan.enumerated().map { idx, word in
                        let suffix = (idx + 1 < matchedSpan.count) ? " " : ""
                        return WordTimestamp(
                            timestamp: word.startTime,
                            duration: max(0.05, word.duration),
                            text: word.text + suffix
                        )
                    }
                    let transcribedText = transcribedWords.map(\.text).joined()
                    let actualWordEnd = matchedSpan.map(\.endTime).max() ?? shiftedEnd
                    let clampedEnd = nextShiftedStart > startTs + 0.3 ? min(actualWordEnd, nextShiftedStart) : actualWordEnd
                    let emittedDuration = max(0.3, clampedEnd - startTs)
                    lastConsumedWordStart = max(lastConsumedWordStart, (matchedSpan.map(\.startTime).max() ?? startTs) + 0.001)
                    previousLineEnd = max(previousLineEnd, startTs + emittedDuration)
                    previousEmittedTimestamp = startTs
                    alignedLines.append(
                        LyricLine(
                            id: line.id,
                            timestamp: startTs,
                            duration: emittedDuration,
                            text: transcribedText,
                            words: transcribedWords
                        )
                    )
                }
                // In transcript-only mode, omit untranscribed static fallback lines.
                continue
            }

            if matches.count >= minMatches {
                let builtWords = interpolateWordTimestamps(
                    tokens: lineTokens,
                    matches: matchMap,
                    fallbackStart: max(shiftedStart, minAllowedStart),
                    fallbackEnd: max(shiftedEnd, minAllowedStart + 0.4)
                )
                let newLineStart = builtWords.first?.timestamp ?? shiftedStart
                let rawEnd = builtWords.last.map { $0.timestamp + ($0.duration ?? 0.2) } ?? shiftedEnd

                if abs(newLineStart - shiftedStart) <= 2.5, newLineStart >= minAllowedStart {
                    let clampedEnd = nextShiftedStart > newLineStart + 0.3 ? min(rawEnd, nextShiftedStart) : rawEnd
                    let newDuration = max(0.3, clampedEnd - newLineStart)
                    matchedLineCount += 1
                    matchedLineIDs.append(line.id)
                    matchedWordCount += matches.count
                    lastConsumedWordStart = max(lastConsumedWordStart, (matches.map(\.word.startTime).max() ?? newLineStart) + 0.001)
                    previousLineEnd = max(previousLineEnd, newLineStart + newDuration)
                    previousEmittedTimestamp = newLineStart

                    alignedLines.append(
                        LyricLine(
                            id: line.id,
                            timestamp: newLineStart,
                            duration: newDuration,
                            text: line.text,
                            words: builtWords
                        )
                    )
                    continue
                }
            }

            let baseStart = (medianOffset.map { abs($0) >= 0.15 ? max(0, line.timestamp + $0) : line.timestamp }) ?? line.timestamp
            let fallbackStart: Double = if previousEmittedTimestamp != nil || previousBlankTimestamp != nil, baseStart < minAllowedStart {
                minAllowedStart
            } else {
                baseStart
            }
            let wordShift = fallbackStart - line.timestamp
            let fallbackWords: [WordTimestamp] = abs(wordShift) >= 0.001
                ? line.words.map { word in
                    WordTimestamp(
                        timestamp: max(0, word.timestamp + wordShift),
                        duration: word.duration,
                        text: word.text
                    )
                }
                : line.words

            if isNonEmpty {
                previousEmittedTimestamp = fallbackStart
                if let dur = line.duration {
                    previousLineEnd = max(previousLineEnd, fallbackStart + max(0.25, dur))
                } else {
                    previousLineEnd = max(previousLineEnd, fallbackStart + 0.25)
                }
            } else {
                previousBlankTimestamp = fallbackStart
            }
            alignedLines.append(
                LyricLine(
                    id: line.id,
                    timestamp: fallbackStart,
                    duration: line.duration,
                    text: line.text,
                    words: fallbackWords
                )
            )
        }

        return AudioAlignmentResult(
            lines: alignedLines,
            matchedLineCount: matchedLineCount,
            matchedWordCount: matchedWordCount,
            medianOffset: medianOffset,
            matchedLineIDs: matchedLineIDs
        )
    }

    private struct TokenMatch {
        let tokenIndex: Int
        let word: RecognizedAudioWord
    }

    private static func matchLineTokens(
        lineTokens: [DisplayToken],
        expectedStart: Double,
        window: ClosedRange<Double>,
        recognized: [RecognizedAudioWord],
        normalizedRec: [String]
    ) -> [TokenMatch] {
        var candidates: [(recIdx: Int, word: RecognizedAudioWord, norm: String)] = []
        for (i, word) in recognized.enumerated() where window.contains(word.startTime) {
            candidates.append((i, word, normalizedRec[i]))
        }
        guard !candidates.isEmpty else { return [] }

        func scan(startingAt initialCursor: Int) -> [TokenMatch] {
            var matches: [TokenMatch] = []
            var cursor = initialCursor
            var lastMatchTime: Double?

            for (tokenIdx, token) in lineTokens.enumerated() {
                guard !token.normalized.isEmpty else { continue }
                let searchLimit = min(candidates.count, cursor + 8)
                for cIdx in cursor..<searchLimit where tokensMatch(token.normalized, candidates[cIdx].norm) {
                    let word = candidates[cIdx].word
                    if let prevTime = lastMatchTime, word.startTime - prevTime > 3.5 {
                        break
                    }
                    matches.append(TokenMatch(tokenIndex: tokenIdx, word: word))
                    lastMatchTime = word.startTime
                    cursor = cIdx + 1
                    break
                }
            }
            return matches
        }

        // Try starting from each candidate matching the first meaningful token (plus cursor 0 fallback)
        // and pick the temporally coherent run with the most matches, breaking ties by proximity to expectedStart.
        var startIndices: [Int] = [0]
        if let firstNorm = lineTokens.first(where: { !$0.normalized.isEmpty })?.normalized {
            for (idx, cand) in candidates.enumerated() where idx > 0 && tokensMatch(firstNorm, cand.norm) {
                startIndices.append(idx)
            }
        }

        var bestMatches: [TokenMatch] = []
        var bestDistance = Double.greatestFiniteMagnitude

        for startIdx in startIndices {
            let run = scan(startingAt: startIdx)
            guard !run.isEmpty else { continue }
            let distance = abs((run.first?.word.startTime ?? expectedStart) - expectedStart)
            if run.count > bestMatches.count || (run.count == bestMatches.count && distance < bestDistance) {
                bestMatches = run
                bestDistance = distance
            }
        }

        return bestMatches
    }

    private static func tokensMatch(_ lhs: String, _ rhs: String) -> Bool {
        if lhs == rhs { return true }
        if lhs.count >= 4 && rhs.count >= 4 {
            if lhs.hasPrefix(rhs) || rhs.hasPrefix(lhs) {
                return true
            }
        }
        return false
    }

    /// Guards transcription-text overwrite so unrelated desktop speech cannot replace a song's lyrics.
    static func transcriptionMatchesLine(lineTokens: [DisplayToken], recognized: [RecognizedAudioWord]) -> Bool {
        matchedTranscriptionSpan(lineTokens: lineTokens, recognized: recognized) != nil
    }

    /// Returns the tightest contiguous span of `recognized` words showing ordered overlap
    /// across a meaningful portion of `lineTokens`, trimming unrelated surrounding speech.
    static func matchedTranscriptionSpan(
        lineTokens: [DisplayToken],
        recognized: [RecognizedAudioWord],
        acceptsStart: (Double) -> Bool = { _ in true }
    ) -> [RecognizedAudioWord]? {
        let lineNorms = lineTokens.map(\.normalized).filter { !$0.isEmpty }
        guard !lineNorms.isEmpty, !recognized.isEmpty else { return nil }

        let recEntries: [(windowIndex: Int, word: RecognizedAudioWord, norm: String)] = recognized.enumerated().compactMap { idx, word in
            let norm = normalizeToken(word.text)
            guard !norm.isEmpty else { return nil }
            return (idx, word, norm)
        }
        guard !recEntries.isEmpty else { return nil }

        let requiredMatches = lineNorms.count <= 1 ? 1 : max(2, (lineNorms.count + 1) / 2)
        let maxTokenGap = 4
        let maxTotalSpan = max(lineNorms.count + 3, lineNorms.count * 2)

        var bestSpan: ClosedRange<Int>?
        var bestMatchCount = 0
        var bestSpanLength = Int.max

        for lineStart in 0..<lineNorms.count {
            for recStart in 0..<recEntries.count
                where tokensMatch(lineNorms[lineStart], recEntries[recStart].norm) && acceptsStart(recEntries[recStart].word.startTime) {
                var matchCount = 1
                var prevRecIdx = recStart
                var lastTime = recEntries[recStart].word.startTime
                var cursor = recStart + 1

                if lineStart + 1 < lineNorms.count {
                    for lineIdx in (lineStart + 1)..<lineNorms.count {
                        let limit = min(recEntries.count, prevRecIdx + maxTokenGap + 1)
                        guard cursor < limit else { break }
                        for cIdx in cursor..<limit where tokensMatch(lineNorms[lineIdx], recEntries[cIdx].norm) {
                            let candidateTime = recEntries[cIdx].word.startTime
                            if candidateTime - lastTime > 3.5 {
                                break
                            }
                            matchCount += 1
                            prevRecIdx = cIdx
                            lastTime = candidateTime
                            cursor = cIdx + 1
                            break
                        }
                    }
                }

                guard matchCount >= requiredMatches else { continue }
                let startWinIdx = recEntries[recStart].windowIndex
                let endWinIdx = recEntries[prevRecIdx].windowIndex
                let spanLength = endWinIdx - startWinIdx + 1
                guard spanLength <= maxTotalSpan else { continue }

                if matchCount > bestMatchCount
                    || (matchCount == bestMatchCount && spanLength < bestSpanLength) {
                    bestMatchCount = matchCount
                    bestSpanLength = spanLength
                    bestSpan = startWinIdx...endWinIdx
                }
            }
        }

        if let bestSpan {
            return Array(recognized[bestSpan])
        }

        // Ordered character subsequence fallback over a contiguous span (handles CJK segmentation / minor diffs).
        // Space-delimited lyrics must meet the token overlap above.
        guard containsCJKWithoutSpaces(lineTokens.map(\.display).joined()) else { return nil }
        let lineJoined = lineNorms.joined()
        let lineChars = Array(lineJoined)
        guard lineChars.count >= 4 else { return nil }

        let maxRecTokens = min(recEntries.count, max(lineNorms.count * 2, 4))
        var bestFallbackSpan: ClosedRange<Int>?
        var bestLCS = 0
        var bestScore = 0.0

        for start in 0..<recEntries.count where acceptsStart(recEntries[start].word.startTime) {
            var spanChars: [Character] = []
            for end in start..<min(recEntries.count, start + maxRecTokens) {
                spanChars.append(contentsOf: recEntries[end].norm)
                guard recEntries[end].word.startTime - recEntries[start].word.startTime <= 5.0 else { break }
                guard spanChars.count >= 4 else { continue }
                let lcs = longestCommonSubsequenceLength(lineChars, spanChars)
                let lineCoverage = Double(lcs) / Double(lineChars.count)
                let spanCoverage = Double(lcs) / Double(spanChars.count)
                guard lineCoverage >= 0.70, spanCoverage >= 0.70 else { continue }
                let score = (2.0 * Double(lcs)) / Double(lineChars.count + spanChars.count)
                if lcs > bestLCS || (lcs == bestLCS && score > bestScore) {
                    bestLCS = lcs
                    bestScore = score
                    bestFallbackSpan = recEntries[start].windowIndex...recEntries[end].windowIndex
                }
            }
        }

        if let bestFallbackSpan {
            return Array(recognized[bestFallbackSpan])
        }
        return nil
    }

    private static func longestCommonSubsequenceLength(_ lhs: [Character], _ rhs: [Character]) -> Int {
        guard !lhs.isEmpty, !rhs.isEmpty else { return 0 }
        var dp = [Int](repeating: 0, count: rhs.count + 1)
        for ch in lhs {
            var prevDiag = 0
            for j in 0..<rhs.count {
                let saved = dp[j + 1]
                if ch == rhs[j] {
                    dp[j + 1] = prevDiag + 1
                } else {
                    dp[j + 1] = max(dp[j + 1], dp[j])
                }
                prevDiag = saved
            }
        }
        return dp[rhs.count]
    }

    private static func interpolateWordTimestamps(
        tokens: [DisplayToken],
        matches: [Int: RecognizedAudioWord],
        fallbackStart: Double,
        fallbackEnd: Double
    ) -> [WordTimestamp] {
        guard !tokens.isEmpty else { return [] }
        let anchorIndices = matches.keys.sorted()
        guard let firstAnchor = anchorIndices.first, let lastAnchor = anchorIndices.last else {
            return []
        }

        let avgWordDur: Double = {
            let durs = matches.values.map { max(0.08, $0.duration) }
            return durs.reduce(0, +) / Double(max(1, durs.count))
        }()

        var starts = Array(repeating: fallbackStart, count: tokens.count)
        var ends = Array(repeating: fallbackEnd, count: tokens.count)

        for idx in anchorIndices {
            if let word = matches[idx] {
                starts[idx] = word.startTime
                ends[idx] = word.endTime
            }
        }

        // Fill leading unmatched tokens before firstAnchor.
        if firstAnchor > 0 {
            let anchorStart = starts[firstAnchor]
            let step = max(0.08, min(0.35, avgWordDur))
            for i in 0..<firstAnchor {
                let offsetFromAnchor = Double(firstAnchor - i) * step
                starts[i] = max(0, anchorStart - offsetFromAnchor)
                ends[i] = max(starts[i], anchorStart - Double(firstAnchor - i - 1) * step)
            }
        }

        // Fill gaps between consecutive anchors without pushing words past the following anchor.
        for pairIdx in 0..<max(0, anchorIndices.count - 1) {
            let left = anchorIndices[pairIdx]
            let right = anchorIndices[pairIdx + 1]
            let gapCount = right - left - 1
            guard gapCount > 0 else { continue }
            let gapEnd = starts[right]
            let gapStart = min(ends[left], gapEnd)
            let step = (gapEnd - gapStart) / Double(gapCount)
            for offset in 1...gapCount {
                let idx = left + offset
                starts[idx] = gapStart + Double(offset - 1) * step
                ends[idx] = gapStart + Double(offset) * step
            }
        }

        // Fill trailing unmatched tokens after lastAnchor.
        if lastAnchor < tokens.count - 1 {
            let anchorEnd = ends[lastAnchor]
            let trailingCount = tokens.count - 1 - lastAnchor
            let step = max(0.08, min(0.35, avgWordDur))
            for offset in 1...trailingCount {
                let idx = lastAnchor + offset
                starts[idx] = anchorEnd + Double(offset - 1) * step
                ends[idx] = anchorEnd + Double(offset) * step
            }
        }

        return tokens.enumerated().map { idx, token in
            let s = starts[idx]
            let rawDur = max(0, ends[idx] - s)
            let dur: Double
            if idx + 1 < tokens.count {
                let available = max(0, starts[idx + 1] - s)
                dur = min(max(0.05, rawDur), available)
            } else {
                dur = max(0.05, rawDur)
            }
            return WordTimestamp(timestamp: s, duration: dur, text: token.display)
        }
    }
}
