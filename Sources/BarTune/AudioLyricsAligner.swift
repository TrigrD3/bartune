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
    let isAnimating: Bool
}

enum AudioSyncStatus: Equatable, Sendable {
    case idle
    case cached(AudioSyncEngine)
    case syncing(engine: AudioSyncEngine, alignedLines: Int, totalLines: Int)
    /// Lyrics Alignment stopped listening: another play would hear the same audio, so it can't lock more lines.
    case settled(engine: AudioSyncEngine, lockedLines: Int, totalLines: Int)
    case permissionRequired(String)
    case unavailable(String)
    /// The song's lyric source overrides the enabled engine.
    case offForTrack(TrackLyricSource)

    static let processTapNoAudioWarning = AudioSyncStatus.permissionRequired(
        "No audio detected — check player volume or System Audio Recording permission in Privacy & Security"
    )

    /// No longer listening: the sync is as complete as the audio allows.
    var isFinished: Bool {
        switch self {
        case .cached, .settled: return true
        default: return false
        }
    }

    var allowsResync: Bool {
        if case .offForTrack = self { return false }
        return true
    }

    var overlayBadge: OverlaySyncBadge? {
        switch self {
        case .cached:
            return OverlaySyncBadge(symbolName: "checkmark.circle.fill", text: "Synced", isSynced: true, isAnimating: false)
        case let .settled(_, locked, total):
            return OverlaySyncBadge(symbolName: "checkmark.circle", text: "Synced \(locked)/\(total)", isSynced: false, isAnimating: false)
        case let .syncing(_, aligned, _):
            return OverlaySyncBadge(
                symbolName: "waveform",
                text: aligned > 0 ? "Syncing" : "Listening",
                isSynced: false,
                isAnimating: true
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
        case let .settled(engine, locked, total):
            return "Cached (\(engine.title), \(locked)/\(total) lines locked)"
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
    struct Syllable: Equatable, Codable, Sendable {
        let text: String
        let startTime: Double
    }

    let text: String
    let startTime: Double
    let duration: Double
    let confidence: Double
    /// Lyrics Alignment: the word's syllables when it has more than one; their texts spell `text`.
    var syllables: [Syllable]?
    /// Lyrics Alignment: originating `LyricLine.id` from forced alignment so wide windows never steal adjacent lines' words.
    var sourceLineId: Int?

    var endTime: Double { startTime + max(0.04, duration) }
}

struct AudioAlignmentResult: Equatable, Sendable {
    let lines: [LyricLine]
    let matchedLineCount: Int
    let matchedWordCount: Int
    let medianOffset: Double?
    /// IDs of the lines whose timing came from recognized audio, in line order.
    var matchedLineIDs: [Int] = []
    /// Lines shortened after their matched words ran well past the next expected row.
    var clampedRunawayLineIDs: Set<Int> = []
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
    /// Lyrics Alignment: lines aligned confidently enough that later plays keep them as they are.
    let lockedLineIDs: [Int]?
    /// Lyrics Alignment: unlocked lines whose audio was heard since the locked set last grew.
    let attemptedLineIDs: [Int]?
    /// Lyrics Alignment: how many lines were locked when the play that saved this record began.
    let lockedAtPlayStart: Int?
    let chromaTemplates: [ChorusSelfSimilarity.CachedTemplate]?

    init(
        trackId: String,
        engine: AudioSyncEngine,
        syncedAt: Date,
        medianOffset: Double?,
        alignedLineCount: Int,
        sourceLineCount: Int? = nil,
        lines: [LyricLine],
        heardWords: [RecognizedAudioWord]? = nil,
        lockedLineIDs: [Int]? = nil,
        attemptedLineIDs: [Int]? = nil,
        lockedAtPlayStart: Int? = nil,
        chromaTemplates: [ChorusSelfSimilarity.CachedTemplate]? = nil
    ) {
        self.trackId = trackId
        self.engine = engine
        self.syncedAt = syncedAt
        self.medianOffset = medianOffset
        self.alignedLineCount = alignedLineCount
        self.sourceLineCount = sourceLineCount
        self.lines = lines
        self.heardWords = heardWords
        self.lockedLineIDs = lockedLineIDs
        self.attemptedLineIDs = attemptedLineIDs
        self.lockedAtPlayStart = lockedAtPlayStart
        self.chromaTemplates = chromaTemplates
    }

    /// Evaluates whether a cached alignment is trustworthy enough to skip live re-syncing.
    /// Rejects incomplete transcript-only caches (fewer non-empty lines than the source lyrics),
    /// single-line partial matches on multi-line tracks, offsets beyond 5 s (8 s with two Lyrics Alignment locks), and
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
    func matchesSource(_ sourceLines: [LyricLine]) -> Bool {
        func texts(_ lines: [LyricLine]) -> [String] {
            lines.map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        }
        let source = texts(sourceLines)
        if let sourceLineCount, sourceLineCount != source.count {
            return false
        }
        return texts(lines) == source
    }

    /// Rebuilds the cached alignment onto `sourceLines`'s exact row layout and IDs (plus remapping
    /// heard-word `sourceLineId`, locked, and attempted IDs) when `matchesSource(sourceLines)` holds
    /// but blank rows shifted `LRCParser`'s row IDs.
    func remapped(to sourceLines: [LyricLine]) -> AudioSyncedLyricsRecord {
        let cachedNonEmpty = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let sourceNonEmpty = sourceLines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard cachedNonEmpty.count == sourceNonEmpty.count, !cachedNonEmpty.isEmpty else { return self }
        var idMap: [Int: Int] = [:]
        idMap.reserveCapacity(cachedNonEmpty.count)
        var changed = lines.count != sourceLines.count
        for (oldLine, newLine) in zip(cachedNonEmpty, sourceNonEmpty) {
            idMap[oldLine.id] = newLine.id
            if oldLine.id != newLine.id { changed = true }
        }
        guard changed else { return self }

        var cachedIter = cachedNonEmpty.makeIterator()
        var remappedLines: [LyricLine] = []
        remappedLines.reserveCapacity(sourceLines.count)
        var lastNonEmptyEnd: Double?
        for source in sourceLines {
            if source.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let ts = lastNonEmptyEnd.map { max(source.timestamp, $0) } ?? source.timestamp
                remappedLines.append(LyricLine(
                    id: source.id,
                    timestamp: ts,
                    duration: source.duration,
                    text: source.text,
                    words: source.words
                ))
            } else if let oldLine = cachedIter.next() {
                LyricsAudioAligner.reconcilePrecedingBoundary(
                    in: &remappedLines,
                    before: remappedLines.count,
                    targetStart: oldLine.timestamp
                )
                let remappedLine = LyricLine(
                    id: source.id,
                    timestamp: oldLine.timestamp,
                    duration: oldLine.duration,
                    text: oldLine.text,
                    words: oldLine.words
                )
                remappedLines.append(remappedLine)
                lastNonEmptyEnd = oldLine.timestamp + (oldLine.duration ?? 0.25)
            }
        }
        let remappedWords = heardWords?.map { word -> RecognizedAudioWord in
            guard let oldId = word.sourceLineId, let mappedId = idMap[oldId], mappedId != oldId else { return word }
            var copy = word
            copy.sourceLineId = mappedId
            return copy
        }
        return AudioSyncedLyricsRecord(
            trackId: trackId,
            engine: engine,
            syncedAt: syncedAt,
            medianOffset: medianOffset,
            alignedLineCount: alignedLineCount,
            sourceLineCount: sourceLineCount,
            lines: remappedLines,
            heardWords: remappedWords,
            lockedLineIDs: lockedLineIDs?.compactMap { idMap[$0] },
            attemptedLineIDs: attemptedLineIDs?.compactMap { idMap[$0] },
            lockedAtPlayStart: lockedAtPlayStart,
            chromaTemplates: chromaTemplates?.compactMap { template in
                idMap[template.lineId].map { template.remapped(lineId: $0) }
            }
        )
    }

    /// Lyrics Alignment: attempted lines that stay settled because the play that heard them locked nothing new.
    var settledLineIDs: Set<Int> {
        guard let lockedAtPlayStart, lockedAtPlayStart == (lockedLineIDs ?? []).count else { return [] }
        return Set(attemptedLineIDs ?? [])
    }

    var hasLowYieldLocks: Bool {
        engine == .lyricsAlignment && Self.hasLowYieldLocks(
            lockedIDs: Set(lockedLineIDs ?? []), attemptedIDs: Set(attemptedLineIDs ?? [])
        )
    }

    static func hasLowYieldLocks(lockedIDs: Set<Int>, attemptedIDs: Set<Int>) -> Bool {
        guard (1...4).contains(lockedIDs.count) else { return false }
        let missed = attemptedIDs.subtracting(lockedIDs).count
        // Wait for a substantial sample, then reject locks on fewer than one in five heard lines.
        return missed >= 10 && missed > lockedIDs.count * 4
    }

    /// A reliable record that matched enough lines to skip listening again on the next play.
    func isComplete(expectedSourceLineCount: Int?) -> Bool {
        guard isReliable(expectedSourceLineCount: expectedSourceLineCount) else { return false }
        let nonEmpty = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let reference = max(nonEmpty, sourceLineCount ?? expectedSourceLineCount ?? 0)
        return alignedLineCount >= Self.linesNeededForCompletion(of: reference)
    }

    func isReliable(expectedSourceLineCount: Int?) -> Bool {
        isReliable(expectedSourceLineCount: expectedSourceLineCount, minimumAlignedLineCount: 2)
    }

    /// A single timed line can resume live fill-in when the record tracks locks.
    func canResumePartial(expectedSourceLineCount: Int?) -> Bool {
        guard engine == .lyricsAlignment, lockedLineIDs != nil,
              lines.contains(where: { !$0.words.isEmpty && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { return false }
        return isReliable(expectedSourceLineCount: expectedSourceLineCount, minimumAlignedLineCount: 1)
    }

    private func isReliable(expectedSourceLineCount: Int?, minimumAlignedLineCount: Int) -> Bool {
        guard !hasLowYieldLocks else { return false }
        let nonEmpty = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmpty.isEmpty else { return false }
        let offsetLimit = engine == .lyricsAlignment && Set(lockedLineIDs ?? []).count >= 2
            ? LyricsAudioAligner.maxOwnedOffset : LyricsAudioAligner.standardOffsetLimit
        if let offset = medianOffset, abs(offset) > offsetLimit {
            return false
        }
        // Lyrics Alignment schedules section tags as markers, so only lyrics need the minimum gap.
        let lyrics = engine == .lyricsAlignment ? nonEmpty.filter { !ForcedAlignmentText.isStructuralTag($0.text) } : nonEmpty
        for (previous, next) in zip(lyrics, lyrics.dropFirst()) where next.timestamp < previous.timestamp + 0.15 {
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
        let minRequired = min(minimumAlignedLineCount, referenceCount)
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
    static let standardOffsetLimit = 5.0
    static let maxOwnedOffset = 8.0

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
    /// With `splitsSyllables`, a matched word that carries syllables is timed one syllable at a time.
    static func align(
        lines: [LyricLine],
        recognizedWords: [RecognizedAudioWord],
        searchWindow: Double = 8.0,
        regroupsCJKWords: Bool = true,
        splitsSyllables: Bool = false
    ) -> AudioAlignmentResult {
        guard !lines.isEmpty, !recognizedWords.isEmpty else {
            return AudioAlignmentResult(lines: lines, matchedLineCount: 0, matchedWordCount: 0, medianOffset: nil)
        }

        func normalizeHeardWord(_ word: RecognizedAudioWord) -> String {
            let normalized = normalizeToken(word.text)
            guard normalized.isEmpty, !regroupsCJKWords, word.sourceLineId != nil else { return normalized }
            return ForcedAlignmentText.displaySymbols(in: word.text)
        }
        let heardWords = recognizedWords
            .filter { !normalizeHeardWord($0).isEmpty }
            .sorted { $0.startTime < $1.startTime }
        // Lyric tokens from Lyrics Alignment keep their own boundaries; joining across lines would break them.
        let sortedRecognized = regroupsCJKWords ? regroupCJKWords(heardWords) : heardWords

        guard !sortedRecognized.isEmpty else {
            return AudioAlignmentResult(lines: lines, matchedLineCount: 0, matchedWordCount: 0, medianOffset: nil)
        }

        let recognizedTokens = sortedRecognized.map { RecognizedToken(word: $0, normalized: normalizeHeardWord($0)) }
        let tokensByLine = Dictionary(grouping: recognizedTokens, by: \.word.sourceLineId)
        // Try forced-aligned words before legacy words so a replay cannot consume another line's onset.
        func sources(for lineId: Int) -> [[RecognizedToken]] {
            [tokensByLine[lineId], tokensByLine[nil]].compactMap { $0 }
        }
        let displayTokens = lines.map { tokenizeLine($0.text) }
        let structuralRows = lines.map { !regroupsCJKWords && ForcedAlignmentText.isStructuralTag($0.text) }
        let forcedTokens: [[DisplayToken]] = regroupsCJKWords ? [] : lines.indices.map { index in
            let tokens = displayTokens[index]
            let lead = ForcedAlignmentText.leadDisplays(in: tokens.map(\.display))
            return zip(tokens, lead).map { token, spoken in
                let isSung = ForcedAlignmentText.containsLead(token.display, withBackingVocalsRemoved: spoken)
                let normal = token.normalized.isEmpty ? ForcedAlignmentText.displaySymbols(in: token.display) : token.normalized
                return DisplayToken(display: token.display, normalized: isSung ? normal : "")
            }
        }

        var nextNonEmptyTimestamp: [Double?] = Array(repeating: nil, count: lines.count)
        var upcomingNonEmpty: Double?
        for idx in lines.indices.reversed() {
            nextNonEmptyTimestamp[idx] = upcomingNonEmpty
            if !isEmptyLine(lines[idx]) && !structuralRows[idx] {
                upcomingNonEmpty = lines[idx].timestamp
            }
        }

        // Pass 1: estimate global offset from confident, temporally coherent line matches.
        let maxOwnedOffset = min(searchWindow, Self.maxOwnedOffset)
        var offsetSamples: [Double] = []
        var ownedOffsetSamples: [Double] = []
        for (lineIdx, line) in lines.enumerated() where !structuralRows[lineIdx] {
            let nextTs = nextNonEmptyTimestamp[lineIdx] ?? (line.timestamp + max(5.0, line.duration ?? 5.0))
            let lineEnd = max(line.duration.map { line.timestamp + $0 } ?? nextTs, nextTs)
            let searchSpan = (line.timestamp - searchWindow)...(lineEnd + searchWindow)
            for source in sources(for: line.id) {
                let isLineOwned = !regroupsCJKWords && source.first?.word.sourceLineId == line.id
                let lineTokens = isLineOwned ? forcedTokens[lineIdx] : displayTokens[lineIdx]
                let meaningfulIndices = lineTokens.indices.filter { !lineTokens[$0].normalized.isEmpty }
                guard let firstMeaningfulIndex = meaningfulIndices.first else { continue }
                let meaningfulCount = meaningfulIndices.count
                let minMatches = meaningfulCount <= 2 ? 1 : max(2, meaningfulCount / 3)
                let matches = matchLineTokens(lineTokens, in: source, window: searchSpan, expectedStart: line.timestamp)
                guard matches.count >= minMatches, let first = matches.first, first.tokenIndex == firstMeaningfulIndex else { continue }
                let offset = first.word.startTime - line.timestamp
                if isLineOwned {
                    guard abs(offset) <= maxOwnedOffset, hasConfidentWords(matches) else { continue }
                    if abs(offset) > standardOffsetLimit, matches.count < meaningfulCount {
                        guard meaningfulCount >= 4 else { continue }
                        let confidences = Dictionary(uniqueKeysWithValues: matches.map { ($0.tokenIndex, $0.word.confidence) })
                        guard LyricsForcedAligner.hasAcousticSupport(in: meaningfulIndices.map { confidences[$0] ?? 0 })
                        else { continue }
                    }
                    ownedOffsetSamples.append(offset)
                    if abs(offset) <= standardOffsetLimit { offsetSamples.append(offset) }
                } else {
                    guard abs(offset) <= standardOffsetLimit else { continue }
                    offsetSamples.append(offset)
                }
                break
            }
        }

        let ownedMedian = consistentMedian(ownedOffsetSamples)
        let medianOffset = consistentMedian(offsetSamples) ?? ownedMedian
        let shift = medianOffset ?? 0.0
        var recentOwnedOffset = ownedMedian ?? shift
        let firstLyricIndex = lines.indices.first { !isEmptyLine(lines[$0]) && !structuralRows[$0] }
        let localPadding = min(searchWindow, regroupsCJKWords ? (medianOffset != nil ? 1.5 : 2.0) : 3.0)
        let maxLineShift = regroupsCJKWords ? 2.5 : 3.5
        // Before corroboration, a confident tagged onset can land in the coarse search's outer range.
        let maxConfidentOwnedShift = medianOffset == nil ? 5.5 : 4.0
        var alignedLines: [LyricLine] = []
        alignedLines.reserveCapacity(lines.count)
        var matchedLineCount = 0
        var matchedLineIDs: [Int] = []
        var clampedRunawayLineIDs = Set<Int>()
        var matchedWordCount = 0
        /// Later lines only match words starting after this: just past the last matched word's start, not
        /// its end, because a stretched last word can run right up to the next line's first word.
        /// Tagged matches are already isolated by line ID and can reconcile an overlapping predecessor.
        var lastConsumedWordStart: Double = 0.0
        var previousLineEnd: Double = 0.0
        var previousEmittedTimestamp: Double?
        var previousBlankTimestamp: Double?
        var previousMatch: (fallbackEnd: Double?, offsetBeforeMatch: Double)?

        // Pass 2: align each line inside a monotonic window so adjacent lines never steal words or overlap.
        lineLoop: for (lineIdx, line) in lines.enumerated() {
            let lineTokens = displayTokens[lineIdx]
            let isNonEmpty = !isEmptyLine(line) && !structuralRows[lineIdx]
            let nextNonEmptyTs = nextNonEmptyTimestamp[lineIdx]
            let nominalEndTs = nextNonEmptyTs ?? (line.timestamp + max(5.0, line.duration ?? 5.0))
            // An early explicit `duration` or early blank marker in the fetched lyrics must not stop
            // Lyrics Alignment from matching words that continue through the actual vocal end.
            let rawLineDur: Double = if regroupsCJKWords {
                max(0.4, line.duration ?? (nominalEndTs - line.timestamp))
            } else {
                max(0.4, max(line.duration ?? 0, nominalEndTs - line.timestamp))
            }
            let shiftedStart = max(0, line.timestamp + shift)
            let shiftedEnd = shiftedStart + rawLineDur
            let ownedShiftedStart = max(0, line.timestamp + recentOwnedOffset)
            let nextShiftedStart = nextNonEmptyTs.map { max(0, $0 + shift) } ?? (shiftedEnd + localPadding)
            let nextAnyTs: Double? = (lineIdx + 1 < lines.count) ? lines[lineIdx + 1].timestamp : nil
            let nextUntaggedBound = nextAnyTs.map { max(0, $0 + shift) } ?? nextShiftedStart
            // A blank marker only needs to stay ordered, so it adds no lyric spacing.
            let spacingFloor = max(
                previousEmittedTimestamp.map { $0 + 0.25 } ?? 0,
                previousBlankTimestamp.map { $0 + 0.01 } ?? 0
            )
            let minAllowedStart = max(spacingFloor, previousLineEnd)
            // Give tagged lines room for the phrase after an eligible late onset. Untagged matches use the
            // tighter next-row bound so adjacent lines cannot claim the same words.
            let untaggedWindowEnd = min(shiftedEnd + localPadding, nextUntaggedBound + 0.4)
            let latestOwnedOnset = min(
                line.timestamp + maxOwnedOffset,
                max(max(shiftedStart, line.timestamp) + maxLineShift, ownedShiftedStart + maxConfidentOwnedShift)
            )
            let ownedWindowEnd = max(max(shiftedStart, ownedShiftedStart, line.timestamp) + localPadding, latestOwnedOnset) + rawLineDur
            // The previous non-empty line's end (a held-note tail or an unmatched line's fetched duration)
            // can run past where this line's vocal actually begins, even across an intervening blank marker.
            // Allow a relaxed floor back to the previous line's last heard word (or timestamp + 0.25 s if
            // unmatched) and reconcile its tail + any intervening blanks when relaxing recovers earlier words.
            let trimmablePreviousIndex = alignedLines.indices.last { !isEmptyLine(alignedLines[$0]) && !structuralRows[$0] }
            let interveningBlankCount = trimmablePreviousIndex.map { alignedLines.count - 1 - $0 } ?? 0
            func floors(forLineOwned isLineOwnedMatch: Bool) -> [Double] {
                var result = [minAllowedStart]
                let consumedFloor = isLineOwnedMatch ? 0 : lastConsumedWordStart
                if let prevIdx = trimmablePreviousIndex {
                    let previous = alignedLines[prevIdx]
                    let relaxedBase = max(previous.timestamp + 0.25, consumedFloor)
                    let relaxed = relaxedBase + Double(interveningBlankCount) * 0.01
                    if relaxed < minAllowedStart { result.append(relaxed) }
                } else if !alignedLines.isEmpty, minAllowedStart > 0 {
                    // Leading blank markers before the first lyric line must not block early vocals;
                    // `reconcilePrecedingBoundary` pulls those blanks back before `best.start`.
                    result.append(0.0)
                }
                return result
            }

            var bestCandidate: (
                matches: [TokenMatch], words: [WordTimestamp], start: Double, end: Double,
                hasFirstToken: Bool, isLineOwned: Bool, rawOffset: Double
            )?
            for source in sources(for: line.id) where isNonEmpty {
                let isLineOwnedMatch = !regroupsCJKWords && source.first?.word.sourceLineId == line.id
                let matchTokens = isLineOwnedMatch ? forcedTokens[lineIdx] : lineTokens
                let firstMeaningfulTokenIndex = matchTokens.firstIndex { !$0.normalized.isEmpty }
                let meaningfulTokenCount = matchTokens.filter { !$0.normalized.isEmpty }.count
                let minMatches = meaningfulTokenCount <= 2 ? 1 : max(2, meaningfulTokenCount / 3)
                let expectedStart = isLineOwnedMatch ? ownedShiftedStart : shiftedStart
                let earliestStart = isLineOwnedMatch ? min(shiftedStart, ownedShiftedStart, line.timestamp) : shiftedStart
                let leadingOwnedLine = isLineOwnedMatch && lineIdx == firstLyricIndex
                let maxEarlyOffset = leadingOwnedLine && line.timestamp <= LyricsForcedAligner.maxIntroStart
                    ? LyricsForcedAligner.maxIntroStart : maxOwnedOffset
                let padding = leadingOwnedLine ? maxEarlyOffset : localPadding
                let windowEnd = isLineOwnedMatch ? ownedWindowEnd : untaggedWindowEnd
                let consumedFloor = isLineOwnedMatch ? 0 : lastConsumedWordStart
                for floor in floors(forLineOwned: isLineOwnedMatch) {
                    let windowStart = max(0, consumedFloor, floor, earliestStart - padding)
                    guard windowEnd > windowStart else { continue }
                    let matches = matchLineTokens(matchTokens, in: source, window: windowStart...windowEnd, expectedStart: expectedStart)
                    guard matches.count >= minMatches else { continue }
                    let matchMap = Dictionary(uniqueKeysWithValues: matches.map { ($0.tokenIndex, $0.word) })
                    let builtWords = interpolateWordTimestamps(
                        tokens: lineTokens,
                        matches: matchMap,
                        fallbackSpan: max(shiftedStart, floor)...max(shiftedEnd, floor + 0.4),
                        minStart: floor,
                        splitsSyllables: splitsSyllables
                    )
                    let newLineStart = builtWords.first?.timestamp ?? shiftedStart
                    let rawEnd = builtWords.last.map { $0.timestamp + ($0.duration ?? 0.2) } ?? shiftedEnd

                    let firstMatchedWord = firstMeaningfulTokenIndex.flatMap { matchMap[$0] }
                    let hasFirstToken = firstMatchedWord != nil
                    // Leading display tokens can start before the first owned word is sung.
                    let onsetForOffset = (isLineOwnedMatch ? firstMatchedWord?.startTime : nil) ?? newLineStart
                    let rawOffset = onsetForOffset - line.timestamp
                    let confidentOnset = hasFirstToken && hasConfidentWords(matches)
                    let maxOwnedShift = confidentOnset ? maxConfidentOwnedShift : maxLineShift
                    let earlyIntro = leadingOwnedLine && rawOffset < 0 && hasFirstToken
                        && (confidentOnset || (matches.count == meaningfulTokenCount
                            && hasConfidentWords(matches, minimum: LyricsForcedAligner.onsetLockConfidence)))
                    let withinShift = abs(onsetForOffset - shiftedStart) <= maxLineShift
                        || (isLineOwnedMatch && (abs(rawOffset) <= maxLineShift || abs(onsetForOffset - expectedStart) <= maxOwnedShift))
                        || earlyIntro
                    guard withinShift, newLineStart >= floor,
                          !isLineOwnedMatch || (-maxEarlyOffset...maxOwnedOffset).contains(rawOffset)
                    else { continue }
                    if let currentBest = bestCandidate {
                        let strictlyBetter = matches.count > currentBest.matches.count
                            || (matches.count == currentBest.matches.count && hasFirstToken && !currentBest.hasFirstToken)
                        if strictlyBetter {
                            bestCandidate = (matches, builtWords, newLineStart, rawEnd, hasFirstToken, isLineOwnedMatch, rawOffset)
                        }
                    } else {
                        bestCandidate = (matches, builtWords, newLineStart, rawEnd, hasFirstToken, isLineOwnedMatch, rawOffset)
                    }
                }
                if bestCandidate != nil { break }
            }

            if let best = bestCandidate {
                if let previousMatch, let previousIndex = trimmablePreviousIndex,
                   previousLineEnd > best.start + localPadding {
                    clampedRunawayLineIDs.insert(alignedLines[previousIndex].id)
                    recentOwnedOffset = previousMatch.offsetBeforeMatch
                }
                let clampedEnd = regroupsCJKWords && nextShiftedStart > best.start + 0.3
                    ? min(best.end, nextShiftedStart) : best.end
                let newDuration = max(0.3, clampedEnd - best.start)
                var emittedLine = LyricLine(
                    id: line.id,
                    timestamp: best.start,
                    duration: newDuration,
                    text: line.text,
                    words: best.words
                )
                if clampedEnd < best.end {
                    emittedLine = Self.trimmed(emittedLine, toEnd: best.start + newDuration)
                }
                Self.reconcilePrecedingBoundary(
                    in: &alignedLines,
                    before: alignedLines.count,
                    targetStart: best.start,
                    ignoringStructuralTags: !regroupsCJKWords
                )
                matchedLineCount += 1
                matchedLineIDs.append(line.id)
                matchedWordCount += best.matches.count
                let maxMatchedStart = (best.matches.map(\.word.startTime).max() ?? best.start) + 0.001
                lastConsumedWordStart = max(lastConsumedWordStart, maxMatchedStart)
                if !regroupsCJKWords {
                    // Keep the full tail until the next lyric's actual onset or fallback is known.
                    let boundary = nextAnyTs.map { predictedFallbackStart(at: $0, medianOffset: medianOffset) }
                    let fallbackEnd = boundary.flatMap { best.end > $0 + localPadding ? max(best.start + 0.3, $0) : nil }
                    previousMatch = (fallbackEnd, recentOwnedOffset)
                }
                // A pickup well before the first LRC row can have a different offset from the verse.
                if best.isLineOwned, best.hasFirstToken, clampedEnd == best.end, hasConfidentWords(best.matches),
                   lineIdx != firstLyricIndex || best.rawOffset >= -localPadding {
                    recentOwnedOffset = best.rawOffset
                }
                previousLineEnd = best.start + newDuration
                previousEmittedTimestamp = best.start
                previousBlankTimestamp = nil

                alignedLines.append(emittedLine)
                continue lineLoop
            }

            let baseStart = predictedFallbackStart(at: line.timestamp, medianOffset: medianOffset)
            let canTrimPreviousMatch = isNonEmpty && previousMatch != nil && previousMatch?.fallbackEnd == nil
            let fallbackEnd = previousMatch?.fallbackEnd ?? previousLineEnd
            if let match = previousMatch, match.fallbackEnd != nil, let previousIndex = trimmablePreviousIndex,
               isNonEmpty || nextNonEmptyTs == nil {
                let previous = alignedLines[previousIndex]
                alignedLines[previousIndex] = Self.trimmed(previous, toEnd: fallbackEnd)
                clampedRunawayLineIDs.insert(previous.id)
                previousLineEnd = fallbackEnd
                recentOwnedOffset = match.offsetBeforeMatch
                previousMatch = nil
            }
            // A lyric's fallback timestamp can cut short the previous match and move provisional markers.
            let fallbackStart: Double = if canTrimPreviousMatch {
                max(baseStart, previousEmittedTimestamp.map { $0 + 0.25 } ?? 0)
            } else if previousEmittedTimestamp != nil || previousBlankTimestamp != nil {
                max(baseStart, spacingFloor, fallbackEnd)
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
                if canTrimPreviousMatch,
                   fallbackStart < previousLineEnd || previousBlankTimestamp.map({ $0 >= fallbackStart }) == true {
                    Self.reconcilePrecedingBoundary(
                        in: &alignedLines, before: alignedLines.count, targetStart: fallbackStart, ignoringStructuralTags: true
                    )
                }
                previousMatch = nil
                previousEmittedTimestamp = fallbackStart
                previousBlankTimestamp = nil
                previousLineEnd = fallbackStart + max(0.25, line.duration ?? 0.25)
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
            matchedLineIDs: matchedLineIDs,
            clampedRunawayLineIDs: clampedRunawayLineIDs
        )
    }

    static func predictedFallbackStart(at timestamp: Double, medianOffset: Double?) -> Double {
        let shift = medianOffset ?? 0
        return abs(shift) >= 0.15 ? max(0, timestamp + shift) : timestamp
    }

    /// `line` cut to end at `end`, with any word running past it shortened to fit.
    static func trimmed(_ line: LyricLine, toEnd end: Double) -> LyricLine {
        let clampedEnd = max(line.timestamp, end)
        return LyricLine(
            id: line.id,
            timestamp: line.timestamp,
            duration: clampedEnd - line.timestamp,
            text: line.text,
            words: line.words.map { word in
                guard word.timestamp + (word.duration ?? 0) > clampedEnd else { return word }
                let clampedStart = min(word.timestamp, clampedEnd)
                return WordTimestamp(timestamp: clampedStart, duration: max(0.0, clampedEnd - clampedStart), text: word.text)
            }
        )
    }

    /// Trims the preceding non-empty line (and pulls back any intervening blank markers) when a newly
    /// aligned or recovered line starts before the preceding line's end or an intervening blank's timestamp.
    static func reconcilePrecedingBoundary(in lines: inout [LyricLine], before targetIndex: Int, targetStart: Double, ignoringStructuralTags: Bool = false) {
        guard targetIndex > 0, targetIndex <= lines.count else { return }
        let precedingRange = 0..<targetIndex
        guard let prevIdx = precedingRange.last(where: {
            !isEmptyLine(lines[$0]) && !(ignoringStructuralTags && ForcedAlignmentText.isStructuralTag(lines[$0].text))
        }) else {
            let count = targetIndex
            let eps = min(0.01, max(0.0, targetStart) / Double(count + 1))
            for idx in 0..<count {
                let slot = max(0.0, targetStart - Double(count - idx) * eps)
                if lines[idx].timestamp >= slot {
                    lines[idx] = LyricLine(
                        id: lines[idx].id,
                        timestamp: slot,
                        duration: lines[idx].duration,
                        text: lines[idx].text,
                        words: lines[idx].words
                    )
                }
            }
            return
        }
        let prev = lines[prevIdx]
        guard targetStart >= prev.timestamp else { return }
        let prevEnd = prev.duration.map { prev.timestamp + $0 }
            ?? prev.words.last.map { $0.timestamp + ($0.duration ?? 0) }
            ?? prev.timestamp
        let blankStart = prevIdx + 1
        let blankCount = targetIndex - blankStart
        let eps = blankCount > 0 ? min(0.01, max(0.0, targetStart - prev.timestamp) / Double(blankCount + 2)) : 0.0
        var ceiling = targetStart
        if blankCount > 0 {
            for offset in stride(from: blankCount - 1, through: 0, by: -1) {
                let idx = blankStart + offset
                let maxAllowed = max(prev.timestamp, ceiling - eps)
                // Also clamp stale blanks sitting below `prevEnd` up into `[prev.timestamp, maxAllowed]`
                // so a shifted preceding line is never crushed down to an unadjusted earlier blank timestamp.
                let minAllowed = min(maxAllowed, max(prev.timestamp, prevEnd) + Double(offset) * eps)
                let currentTs = lines[idx].timestamp
                let adjusted: Double? = if currentTs > maxAllowed || currentTs >= ceiling {
                    maxAllowed
                } else if currentTs < minAllowed {
                    minAllowed
                } else {
                    nil
                }
                if let adjusted {
                    lines[idx] = LyricLine(
                        id: lines[idx].id,
                        timestamp: adjusted,
                        duration: lines[idx].duration,
                        text: lines[idx].text,
                        words: lines[idx].words
                    )
                }
                ceiling = lines[idx].timestamp
            }
        }
        if prevEnd > ceiling {
            lines[prevIdx] = trimmed(prev, toEnd: ceiling)
        }
    }

    private static func isEmptyLine(_ line: LyricLine) -> Bool {
        line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private struct RecognizedToken {
        let word: RecognizedAudioWord
        let normalized: String
    }

    private struct TokenMatch {
        let tokenIndex: Int
        let word: RecognizedAudioWord
    }

    private static func consistentMedian(_ offsets: [Double]) -> Double? {
        guard offsets.count >= 2 else { return nil }
        let sorted = offsets.sorted()
        let median = sorted[sorted.count / 2]
        return sorted.filter { abs($0 - median) <= 1.5 }.count >= 2 ? median : nil
    }

    private static func hasConfidentWords(_ matches: [TokenMatch], minimum: Double = LyricsForcedAligner.lockConfidence) -> Bool {
        let confidences = matches.map(\.word.confidence)
        return confidences.reduce(0, +) >= Double(confidences.count) * minimum
            && LyricsForcedAligner.hasAcousticSupport(in: confidences)
    }

    private static func matchLineTokens(
        _ lineTokens: [DisplayToken],
        in source: [RecognizedToken],
        window: ClosedRange<Double>,
        expectedStart: Double
    ) -> [TokenMatch] {
        let candidates = source.filter { window.contains($0.word.startTime) }
        guard !candidates.isEmpty else { return [] }

        func scan(startingAt initialCursor: Int) -> [TokenMatch] {
            var matches: [TokenMatch] = []
            var cursor = initialCursor

            for (tokenIdx, token) in lineTokens.enumerated() {
                guard !token.normalized.isEmpty else { continue }
                let searchLimit = min(candidates.count, cursor + 8)
                for cIdx in cursor..<searchLimit where tokensMatch(token.normalized, candidates[cIdx].normalized) {
                    let word = candidates[cIdx].word
                    if let previous = matches.last?.word {
                        let gapStart = word.sourceLineId == nil ? previous.startTime : previous.endTime
                        if word.startTime - gapStart > LyricsForcedAligner.maxWordSpan { break }
                    }
                    matches.append(TokenMatch(tokenIndex: tokenIdx, word: word))
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
            for (idx, cand) in candidates.enumerated() where idx > 0 && tokensMatch(firstNorm, cand.normalized) {
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

    private static func interpolateWordTimestamps(
        tokens: [DisplayToken],
        matches: [Int: RecognizedAudioWord],
        fallbackSpan: ClosedRange<Double>,
        minStart: Double = 0.0,
        splitsSyllables: Bool
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

        var starts = Array(repeating: fallbackSpan.lowerBound, count: tokens.count)
        var ends = Array(repeating: fallbackSpan.upperBound, count: tokens.count)

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
                starts[i] = max(minStart, anchorStart - offsetFromAnchor)
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

        return tokens.enumerated().flatMap { idx, token in
            let s = starts[idx]
            let rawDur = max(0, ends[idx] - s)
            let dur: Double
            if idx + 1 < tokens.count {
                let available = max(0, starts[idx + 1] - s)
                dur = min(max(0.05, rawDur), available)
            } else {
                dur = max(0.05, rawDur)
            }
            if splitsSyllables, let syllables = matches[idx]?.syllables,
               let split = syllableTimestamps(syllables, display: token.display, start: s, end: s + dur) {
                return split
            }
            return [WordTimestamp(timestamp: s, duration: dur, text: token.display)]
        }
    }

    /// A word's syllables kept inside its `start...end`, the last one carrying the token's trailing text;
    /// nil when the syllables don't spell the start of `display`.
    private static func syllableTimestamps(
        _ syllables: [RecognizedAudioWord.Syllable],
        display: String,
        start: Double,
        end: Double
    ) -> [WordTimestamp]? {
        let spelled = syllables.map(\.text).joined()
        guard syllables.count > 1, display.hasPrefix(spelled) else { return nil }
        var starts = [start]
        for syllable in syllables.dropFirst() {
            starts.append(min(end, max(starts[starts.count - 1], syllable.startTime)))
        }
        let trailing = String(display.dropFirst(spelled.count))
        return syllables.indices.map { index in
            let isLast = index == syllables.count - 1
            let syllableEnd = isLast ? end : starts[index + 1]
            return WordTimestamp(
                timestamp: starts[index],
                duration: syllableEnd - starts[index],
                text: syllables[index].text + (isLast ? trailing : "")
            )
        }
    }

    /// A line's timed words grouped into the tokens `tokenizeLine` splits its text into, so the
    /// syllables of one word come back together; nil when the words don't spell those tokens.
    static func tokenGroups(of line: LyricLine) -> [[WordTimestamp]]? {
        tokenGroups(of: line, tokens: tokenizeLine(line.text))
    }

    private static func tokenGroups(of line: LyricLine, tokens: [DisplayToken]) -> [[WordTimestamp]]? {
        var groups: [[WordTimestamp]] = []
        var index = 0
        for token in tokens {
            var group: [WordTimestamp] = []
            var spelled = ""
            while index < line.words.count, spelled != token.display {
                spelled += line.words[index].text
                guard token.display.hasPrefix(spelled) else { return nil }
                group.append(line.words[index])
                index += 1
            }
            guard spelled == token.display else { return nil }
            groups.append(group)
        }
        return index == line.words.count ? groups : nil
    }

    /// Timed lead words for audio anchors and confidence checks. Backing vocals keep their display timings.
    static func leadTokenGroups(of line: LyricLine) -> [[WordTimestamp]] {
        guard !ForcedAlignmentText.isStructuralTag(line.text) else { return [] }
        let groups = tokenGroups(of: line) ?? line.words.map { [$0] }
        guard line.text.contains("(") else { return groups }
        let displays = groups.map { $0.map(\.text).joined() }
        let lead = ForcedAlignmentText.leadDisplays(in: displays)
        return groups.indices.compactMap { index in
            ForcedAlignmentText.containsLead(displays[index], withBackingVocalsRemoved: lead[index]) ? groups[index] : nil
        }
    }
}
