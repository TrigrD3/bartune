import CryptoKit
import Foundation
import NaturalLanguage

enum AudioSyncEngine: String, CaseIterable, Identifiable, Codable, Sendable {
    case off = "off"
    case appleSpeech = "appleSpeech"
    case whisper = "whisper"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .off: return "Off"
        case .appleSpeech: return "Apple Speech"
        case .whisper: return "Local Whisper"
        }
    }

    var description: String {
        switch self {
        case .off:
            return "Uses fetched LRC/YRC timestamps only (no System Audio Recording permission required)."
        case .appleSpeech:
            return "Zero-dependency on-device Apple Speech alignment. Caches synced karaoke timings per track."
        case .whisper:
            return "Uses local whisper-cli and shared GGML models for higher accuracy on singing vocals and multiple languages."
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
        case .idle, .permissionRequired, .unavailable:
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
}

struct AudioSyncedLyricsRecord: Equatable, Codable, Sendable {
    let trackId: String
    let engine: AudioSyncEngine
    let syncedAt: Date
    let medianOffset: Double?
    let alignedLineCount: Int
    let sourceLineCount: Int?
    let lines: [LyricLine]

    init(
        trackId: String,
        engine: AudioSyncEngine,
        syncedAt: Date,
        medianOffset: Double?,
        alignedLineCount: Int,
        sourceLineCount: Int? = nil,
        lines: [LyricLine]
    ) {
        self.trackId = trackId
        self.engine = engine
        self.syncedAt = syncedAt
        self.medianOffset = medianOffset
        self.alignedLineCount = alignedLineCount
        self.sourceLineCount = sourceLineCount
        self.lines = lines
    }

    /// Evaluates whether a cached alignment is trustworthy enough to skip live re-syncing.
    /// Rejects single-line partial matches on multi-line tracks (including transcript-only
    /// caches that omit untranscribed lines), extreme outlier offsets (> 5s), and
    /// duplicate/inverted line timestamps from cross-line bleed.
    var isReliable: Bool {
        let nonEmpty = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmpty.isEmpty else { return false }
        if let offset = medianOffset, abs(offset) > 5.0 {
            return false
        }
        for idx in 1..<nonEmpty.count where nonEmpty[idx].timestamp < nonEmpty[idx - 1].timestamp + 0.15 {
            return false
        }
        let referenceCount = max(nonEmpty.count, sourceLineCount ?? 0)
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
        guard let data = try? Data(contentsOf: url),
              let record = try? JSONDecoder().decode(AudioSyncedLyricsRecord.self, from: data),
              !record.lines.isEmpty
        else { return nil }
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

struct DiscoveredWhisperModel: Identifiable, Equatable, Hashable, Sendable {
    let path: String
    let name: String
    let sizeBytes: Int64
    let sourceLabel: String

    var id: String { path }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
    }
}

enum WhisperModelPreset: String, CaseIterable, Identifiable, Sendable {
    case tiny = "ggml-tiny.bin"
    case base = "ggml-base.bin"
    case small = "ggml-small.bin"
    case medium = "ggml-medium.bin"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tiny: return "Tiny (~75 MB · Fastest)"
        case .base: return "Base (~142 MB · Balanced)"
        case .small: return "Small (~466 MB · Accurate)"
        case .medium: return "Medium (~1.5 GB · Best Vocals)"
        }
    }

    var downloadURL: URL {
        URL(string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(rawValue)")!
    }
}

enum WhisperModelLocator {
    static let defaultModelDownloadURL = URL(
        string: "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-tiny.bin"
    )!
    static let defaultModelFilename = "ggml-tiny.bin"

    /// Shared directory used when BarTune downloads a model so other tools on the Mac can reuse it.
    static func sharedCacheDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        homeDirectory.appendingPathComponent(".cache/whisper", isDirectory: true)
    }

    /// Searches standard shared ML model locations without copying or duplicating files.
    static func discoverModels(
        customPath: String? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        extraSearchDirectories: [(url: URL, label: String)] = []
    ) -> [DiscoveredWhisperModel] {
        let fm = FileManager.default
        var seenCanonicalPaths = Set<String>()
        var results: [DiscoveredWhisperModel] = []

        func registerIfValid(fileURL: URL, sourceLabel: String) {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: fileURL.path, isDirectory: &isDir), !isDir.boolValue else { return }
            let lower = fileURL.lastPathComponent.lowercased()
            guard lower.hasSuffix(".bin"), lower.contains("ggml") || sourceLabel == "Custom" else { return }
            let canonical = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard seenCanonicalPaths.insert(canonical).inserted else { return }
            let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            results.append(
                DiscoveredWhisperModel(
                    path: fileURL.path,
                    name: fileURL.lastPathComponent,
                    sizeBytes: size,
                    sourceLabel: sourceLabel
                )
            )
        }

        if let custom = customPath?.trimmingCharacters(in: .whitespacesAndNewlines), !custom.isEmpty {
            registerIfValid(fileURL: URL(fileURLWithPath: custom), sourceLabel: "Custom")
        }

        if let envModel = environment["WHISPER_MODEL_PATH"], !envModel.isEmpty {
            registerIfValid(fileURL: URL(fileURLWithPath: envModel), sourceLabel: "WHISPER_MODEL_PATH")
        }

        var searchDirs: [(URL, String)] = []
        if let envDir = environment["WHISPER_MODELS_DIR"], !envDir.isEmpty {
            searchDirs.append((URL(fileURLWithPath: envDir, isDirectory: true), "WHISPER_MODELS_DIR"))
        }
        searchDirs.append((homeDirectory.appendingPathComponent(".cache/whisper", isDirectory: true), "~/.cache/whisper"))
        let hfHome = environment["HF_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? homeDirectory.appendingPathComponent(".cache/huggingface", isDirectory: true)
        searchDirs.append((hfHome.appendingPathComponent("hub", isDirectory: true), "HuggingFace Cache"))
        searchDirs.append((URL(fileURLWithPath: "/opt/homebrew/share/whisper-cpp", isDirectory: true), "Homebrew"))
        searchDirs.append((URL(fileURLWithPath: "/usr/local/share/whisper-cpp", isDirectory: true), "Homebrew"))
        searchDirs.append((homeDirectory.appendingPathComponent(".local/share/whisper", isDirectory: true), "~/.local/share/whisper"))
        searchDirs.append((
            homeDirectory.appendingPathComponent("Library/Application Support/whisper", isDirectory: true),
            "Application Support"
        ))
        searchDirs.append(contentsOf: extraSearchDirectories)

        for (dir, label) in searchDirs {
            guard fm.fileExists(atPath: dir.path) else { continue }
            guard let enumerator = fm.enumerator(
                at: dir,
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
                options: [.skipsPackageDescendants]
            ) else { continue }

            let baseDepth = dir.standardizedFileURL.pathComponents.count
            for case let fileURL as URL in enumerator {
                let depth = fileURL.standardizedFileURL.pathComponents.count - baseDepth
                if depth > 4 {
                    enumerator.skipDescendants()
                    continue
                }
                registerIfValid(fileURL: fileURL, sourceLabel: label)
            }
        }

        return results
    }

    static func locateWhisperCLI(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let fm = FileManager.default
        var candidates = [
            "/opt/homebrew/bin/whisper-cli",
            "/usr/local/bin/whisper-cli",
        ]
        if let pathEnv = environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                candidates.append("\(dir)/whisper-cli")
            }
        }
        for candidate in candidates where fm.isExecutableFile(atPath: candidate) {
            return candidate
        }
        return nil
    }
}

enum WhisperJSONParser {
    private struct OutputRoot: Decodable {
        let transcription: [Segment]?
    }

    private struct Segment: Decodable {
        let offsets: Offsets?
        let text: String?
        let tokens: [Token]?
    }

    private struct Token: Decodable {
        let text: String?
        let offsets: Offsets?
        let p: Double?
    }

    private struct Offsets: Decodable {
        let from: Double?
        let to: Double?
    }

    /// Parses `whisper-cli -ojf` JSON output into track-relative `RecognizedAudioWord` items.
    static func parse(data: Data, chunkStartTime: Double) -> [RecognizedAudioWord] {
        guard let root = try? JSONDecoder().decode(OutputRoot.self, from: data),
              let segments = root.transcription
        else { return [] }

        var words: [RecognizedAudioWord] = []

        for segment in segments {
            if let tokens = segment.tokens, !tokens.isEmpty {
                words.append(contentsOf: mergeTokens(tokens, chunkStartTime: chunkStartTime))
            } else if let text = segment.text, let offsets = segment.offsets,
                      let fromMs = offsets.from, let toMs = offsets.to {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !trimmed.hasPrefix("[") else { continue }
                let parts = trimmed.split(whereSeparator: \.isWhitespace).map(String.init)
                guard !parts.isEmpty else { continue }
                let startSec = chunkStartTime + fromMs / 1000.0
                let totalDur = max(0.1, (toMs - fromMs) / 1000.0)
                let perWord = totalDur / Double(parts.count)
                for (i, part) in parts.enumerated() {
                    words.append(
                        RecognizedAudioWord(
                            text: part,
                            startTime: startSec + Double(i) * perWord,
                            duration: perWord,
                            confidence: 0.75
                        )
                    )
                }
            }
        }

        return words
    }

    private static func mergeTokens(_ tokens: [Token], chunkStartTime: Double) -> [RecognizedAudioWord] {
        var merged: [RecognizedAudioWord] = []
        var currentText = ""
        var currentStart: Double?
        var currentEnd: Double = 0
        var confSum = 0.0
        var confCount = 0

        func flush() {
            let trimmed = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, let start = currentStart {
                let dur = max(0.05, currentEnd - start)
                let conf = confCount > 0 ? confSum / Double(confCount) : 0.7
                merged.append(
                    RecognizedAudioWord(
                        text: trimmed,
                        startTime: start,
                        duration: dur,
                        confidence: conf
                    )
                )
            }
            currentText = ""
            currentStart = nil
            currentEnd = 0
            confSum = 0
            confCount = 0
        }

        for token in tokens {
            guard let rawText = token.text else { continue }
            let trimmedCheck = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedCheck.isEmpty { continue }
            if trimmedCheck.hasPrefix("[") && trimmedCheck.hasSuffix("]") {
                flush()
                continue
            }
            guard let fromMs = token.offsets?.from, let toMs = token.offsets?.to else { continue }
            let start = chunkStartTime + fromMs / 1000.0
            let end = chunkStartTime + max(fromMs + 40, toMs) / 1000.0
            let startsNewWord = rawText.first?.isWhitespace == true

            if startsNewWord && !currentText.isEmpty {
                flush()
            }

            if currentStart == nil {
                currentStart = start
            }
            currentText += rawText
            currentEnd = max(currentEnd, end)
            confSum += token.p ?? 0.7
            confCount += 1
        }
        flush()

        return merged
    }
}

enum LyricsLanguageDetector {
    /// Detects the best speech recognition locale from fetched lyrics so Apple Speech
    /// doesn't default to English on Japanese, Korean, Chinese, or other non-English songs.
    static func detectSpeechLocale(for lines: [LyricLine]) -> Locale {
        guard !lines.isEmpty else { return .current }
        if JapaneseRomanizer.isJapaneseTrack(lines) {
            return Locale(identifier: "ja-JP")
        }
        if KoreanRomanizer.isKoreanTrack(lines) {
            return Locale(identifier: "ko-KR")
        }
        if ChineseRomanizer.isChineseTrack(lines) {
            return Locale(identifier: "zh-CN")
        }

        let sample = lines.prefix(12).map(\.text).joined(separator: " ")
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

        while CFStringTokenizerAdvanceToNextToken(tokenizer) != [] {
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
        replaceTextWithTranscription: Bool = false
    ) -> AudioAlignmentResult {
        guard !lines.isEmpty, !recognizedWords.isEmpty else {
            return AudioAlignmentResult(lines: lines, matchedLineCount: 0, matchedWordCount: 0, medianOffset: nil)
        }

        let sortedRecognized = recognizedWords
            .filter { !normalizeToken($0.text).isEmpty }
            .sorted { $0.startTime < $1.startTime }

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
        var matchedWordCount = 0
        var lastConsumedTime: Double = 0.0
        var previousEmittedTimestamp: Double?

        // Pass 2: align each line inside a tight, monotonic window so adjacent lines never steal words or overlap.
        for (lineIdx, line) in lines.enumerated() {
            let lineTokens = tokenizeLine(line.text)
            let nextTs = (lineIdx + 1 < lines.count) ? lines[lineIdx + 1].timestamp : (line.timestamp + 4.5)
            let rawLineDur = max(0.4, line.duration ?? (nextTs - line.timestamp))
            let shiftedStart = max(0, line.timestamp + shift)
            let shiftedEnd = shiftedStart + rawLineDur
            let nextShiftedStart = (lineIdx + 1 < lines.count) ? max(0, nextTs + shift) : (shiftedEnd + localPadding)

            let windowStart = max(0, max(lastConsumedTime, shiftedStart - localPadding))
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
                    $0.startTime >= max(lastConsumedTime, shiftedStart - 0.6) && $0.startTime < min(shiftedEnd + 0.4, nextShiftedStart)
                }
                if !windowWords.isEmpty, Self.transcriptionMatchesLine(lineTokens: lineTokens, recognized: windowWords) {
                    let startTs = windowWords.first?.startTime ?? shiftedStart
                    let isMonotonic = previousEmittedTimestamp.map { startTs >= $0 + 0.25 } ?? true
                    if abs(startTs - shiftedStart) <= 2.5, isMonotonic {
                        matchedLineCount += 1
                        matchedWordCount += windowWords.count
                        let transcribedWords: [WordTimestamp] = windowWords.enumerated().map { idx, word in
                            let suffix = (idx + 1 < windowWords.count) ? " " : ""
                            return WordTimestamp(
                                timestamp: word.startTime,
                                duration: max(0.05, word.duration),
                                text: word.text + suffix
                            )
                        }
                        let transcribedText = transcribedWords.map(\.text).joined()
                        let endTs = windowWords.last?.endTime ?? shiftedEnd
                        let clampedEnd = nextShiftedStart > startTs + 0.3 ? min(endTs, nextShiftedStart) : endTs
                        lastConsumedTime = max(lastConsumedTime, clampedEnd)
                        previousEmittedTimestamp = startTs
                        alignedLines.append(
                            LyricLine(
                                id: line.id,
                                timestamp: startTs,
                                duration: max(0.3, clampedEnd - startTs),
                                text: transcribedText,
                                words: transcribedWords
                            )
                        )
                    }
                }
                // In transcript-only mode, omit untranscribed static fallback lines.
                continue
            }

            if matches.count >= minMatches {
                let builtWords = interpolateWordTimestamps(
                    tokens: lineTokens,
                    matches: matchMap,
                    fallbackStart: shiftedStart,
                    fallbackEnd: shiftedEnd
                )
                let newLineStart = builtWords.first?.timestamp ?? shiftedStart
                let rawEnd = builtWords.last.map { $0.timestamp + ($0.duration ?? 0.2) } ?? shiftedEnd
                let isMonotonic = previousEmittedTimestamp.map { newLineStart >= $0 + 0.25 } ?? true

                if abs(newLineStart - shiftedStart) <= 2.5, isMonotonic {
                    let clampedEnd = nextShiftedStart > newLineStart + 0.3 ? min(rawEnd, nextShiftedStart) : rawEnd
                    let newDuration = max(0.3, clampedEnd - newLineStart)
                    matchedLineCount += 1
                    matchedWordCount += matches.count
                    lastConsumedTime = max(lastConsumedTime, clampedEnd)
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

            if let offset = medianOffset, abs(offset) >= 0.15 {
                let shiftedWords = line.words.map { word in
                    WordTimestamp(
                        timestamp: max(0, word.timestamp + offset),
                        duration: word.duration,
                        text: word.text
                    )
                }
                let fallbackStart = max(0, line.timestamp + offset)
                if !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    previousEmittedTimestamp = fallbackStart
                }
                alignedLines.append(
                    LyricLine(
                        id: line.id,
                        timestamp: fallbackStart,
                        duration: line.duration,
                        text: line.text,
                        words: shiftedWords
                    )
                )
            } else {
                if !line.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    previousEmittedTimestamp = line.timestamp
                }
                alignedLines.append(line)
            }
        }

        return AudioAlignmentResult(
            lines: alignedLines,
            matchedLineCount: matchedLineCount,
            matchedWordCount: matchedWordCount,
            medianOffset: medianOffset
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
        let lineNorms = lineTokens.map(\.normalized).filter { !$0.isEmpty }
        let recNorms = recognized.map { normalizeToken($0.text) }.filter { !$0.isEmpty }
        guard !lineNorms.isEmpty, !recNorms.isEmpty else { return false }

        // Direct token match (handles both Latin and segmented CJK words).
        for lt in lineNorms where recNorms.contains(where: { tokensMatch(lt, $0) }) {
            return true
        }

        // Character bigram overlap fallback (handles minor pronunciation/kanji differences).
        let lineJoined = lineNorms.joined()
        let recJoined = recNorms.joined()
        let lineBigrams = characterBigrams(lineJoined)
        let recBigrams = characterBigrams(recJoined)
        guard !lineBigrams.isEmpty, !recBigrams.isEmpty else { return false }
        let shared = lineBigrams.intersection(recBigrams).count
        let denom = min(lineBigrams.count, recBigrams.count)
        return Double(shared) / Double(max(1, denom)) >= 0.30
    }

    private static func characterBigrams(_ text: String) -> Set<String> {
        let chars = Array(text)
        guard chars.count >= 2 else { return chars.isEmpty ? [] : [text] }
        var out = Set<String>()
        out.reserveCapacity(chars.count - 1)
        for i in 0..<(chars.count - 1) {
            out.insert(String(chars[i...i + 1]))
        }
        return out
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
                ends[i] = max(starts[i] + 0.05, anchorStart - Double(firstAnchor - i - 1) * step)
            }
        }

        // Fill gaps between consecutive anchors.
        for pairIdx in 0..<max(0, anchorIndices.count - 1) {
            let left = anchorIndices[pairIdx]
            let right = anchorIndices[pairIdx + 1]
            let gapCount = right - left - 1
            guard gapCount > 0 else { continue }
            let gapStart = ends[left]
            let gapEnd = max(gapStart + 0.05 * Double(gapCount), starts[right])
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
            let dur = max(0.05, ends[idx] - s)
            return WordTimestamp(timestamp: s, duration: dur, text: token.display)
        }
    }
}
