import CoreML
import Foundation

/// CTC Viterbi forced alignment: finds the most likely frames for a known token sequence.
enum CTCForcedAlignment {
    static let blank = 0

    struct TokenSpan: Equatable {
        let firstFrame: Int
        let lastFrame: Int
        /// Summed log-probability of the token over its frames.
        let logProbability: Float
    }

    /// `logProbs` is row-major `[frame][vocab]`. `allowedFrames`, when given, limits each token to a frame range.
    /// Returns nil when the tokens cannot fit the frames or their ranges.
    static func align(
        logProbs: [Float],
        vocabSize: Int,
        tokens: [Int],
        allowedFrames: [ClosedRange<Int>]? = nil
    ) -> [TokenSpan]? {
        let frameCount = logProbs.count / vocabSize
        guard !tokens.isEmpty, frameCount > 0 else { return nil }
        let stateCount = 2 * tokens.count + 1
        let impossible = -Float.infinity

        func emission(_ frame: Int, _ state: Int) -> Float {
            guard state % 2 == 1 else { return logProbs[frame * vocabSize + blank] }
            let token = (state - 1) / 2
            if let allowed = allowedFrames?[token], !allowed.contains(frame) { return impossible }
            return logProbs[frame * vocabSize + tokens[token]]
        }

        var score = [Float](repeating: impossible, count: stateCount)
        score[0] = emission(0, 0)
        score[1] = emission(0, 1)
        // 0 = stayed, 1 = came from the previous state, 2 = skipped the blank before this token.
        var steps = [UInt8](repeating: 0, count: frameCount * stateCount)
        var next = score
        for frame in 1..<frameCount {
            for state in 0..<stateCount {
                var best = score[state]
                var step: UInt8 = 0
                if state > 0, score[state - 1] > best {
                    best = score[state - 1]
                    step = 1
                }
                if state >= 3, state % 2 == 1, tokens[(state - 1) / 2] != tokens[(state - 3) / 2], score[state - 2] > best {
                    best = score[state - 2]
                    step = 2
                }
                next[state] = best + emission(frame, state)
                steps[frame * stateCount + state] = step
            }
            swap(&score, &next)
        }

        var state = score[stateCount - 1] >= score[stateCount - 2] ? stateCount - 1 : stateCount - 2
        guard score[state] > impossible else { return nil }
        var first = [Int](repeating: -1, count: tokens.count)
        var last = [Int](repeating: -1, count: tokens.count)
        var total = [Float](repeating: 0, count: tokens.count)
        for frame in stride(from: frameCount - 1, through: 0, by: -1) {
            if state % 2 == 1 {
                let token = (state - 1) / 2
                if last[token] < 0 { last[token] = frame }
                first[token] = frame
                total[token] += logProbs[frame * vocabSize + tokens[token]]
            }
            state -= Int(steps[frame * stateCount + state])
        }
        return tokens.indices.map { TokenSpan(firstFrame: first[$0], lastFrame: last[$0], logProbability: total[$0]) }
    }
}

/// Lyric words and the romanized readings the aligner's acoustic model spells them with.
enum ForcedAlignmentText {
    enum Script: Equatable {
        case latin, japanese, korean, chinese

        static func detect(in lines: [LyricLine]) -> Script {
            if JapaneseRomanizer.isJapaneseTrack(lines) { return .japanese }
            if KoreanRomanizer.isKoreanTrack(lines) { return .korean }
            if ChineseRomanizer.isChineseTrack(lines) { return .chinese }
            return .latin
        }
    }

    struct Word: Equatable {
        let display: String
        let reading: String
        var tokenIDs: [Int] { reading.compactMap { ForcedAlignmentText.vocabulary[$0] } }
    }

    /// The MMS forced-aligner's letters (`<blank>` is 0; `<pad>`, `</s>`, `<unk>` are unused).
    static let vocabulary: [Character: Int] = Dictionary(uniqueKeysWithValues: Array("aienoutsrmkldghybpwcvjzf'qx")
        .enumerated().map { ($1, $0 + 4) })

    /// Lyric tokens of one line (as `LyricsAudioAligner.tokenizeLine` splits it) with their readings.
    /// Tokens with no readable letters, such as punctuation or symbols, are left out.
    static func words(for text: String, script: Script) -> [Word] {
        let displays = LyricsAudioAligner.tokenizeLine(text)
            .map { $0.display.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let readings: [String] = switch script {
        case .japanese: JapaneseRomanizer.romanizeWords(displays)
        case .korean: displays.map(KoreanRomanizer.romanizeLine)
        case .chinese: displays.map(ChineseRomanizer.romanizeLine)
        case .latin: displays
        }
        return zip(displays, readings).compactMap { display, reading in
            let letters = letters(of: reading)
            return letters.isEmpty ? nil : Word(display: display, reading: letters)
        }
    }

    /// The model's letters in `reading`, with diacritics stripped.
    private static func letters(of reading: String) -> String {
        let folded = (reading.applyingTransform(.stripDiacritics, reverse: false) ?? reading).lowercased()
        return String(folded.filter { vocabulary[$0] != nil })
    }

    struct Syllable: Equatable {
        let display: String
        /// How many letters of the word's reading this syllable spans.
        let letterCount: Int
    }

    /// `word` split into sung syllables whose letters spell its reading in order: one per Hangul block,
    /// one per hanzi in a Chinese song, vowel groups for Latin text. Empty for a one-syllable word, for
    /// Japanese (a kanji's reading spans several morae), or when the pieces don't spell the reading.
    static func syllables(of word: Word, script: Script, latinRules: LatinSyllabifier.Rules = .standard) -> [Syllable] {
        let characters = Array(word.display)
        let pieces: [String]
        if characters.contains(where: isHangulSyllable) {
            pieces = split(characters, startingAt: isHangulSyllable)
        } else if characters.contains(where: { ChineseRomanizer.containsHan(String($0)) }) {
            guard script == .chinese else { return [] }
            pieces = split(characters) { ChineseRomanizer.containsHan(String($0)) }
        } else if JapaneseRomanizer.containsKana(word.display) {
            return []
        } else {
            pieces = LatinSyllabifier.split(word.display, rules: latinRules)
        }

        var syllables: [(display: String, letters: String)] = []
        var pendingDisplay = ""
        for piece in pieces {
            let reading = switch script {
            case .korean: KoreanRomanizer.romanizeLine(piece)
            case .chinese: ChineseRomanizer.romanizeLine(piece)
            case .latin, .japanese: piece
            }
            let pieceLetters = letters(of: reading)
            if pieceLetters.isEmpty {
                // Letterless pieces (punctuation) ride along with a neighbouring syllable.
                if syllables.isEmpty { pendingDisplay += piece } else { syllables[syllables.count - 1].display += piece }
            } else {
                syllables.append((pendingDisplay + piece, pieceLetters))
                pendingDisplay = ""
            }
        }
        guard syllables.count > 1, syllables.map(\.letters).joined() == word.reading else { return [] }
        return syllables.map { Syllable(display: $0.display, letterCount: $0.letters.count) }
    }

    private static func isHangulSyllable(_ character: Character) -> Bool {
        character.unicodeScalars.contains { (0xAC00...0xD7A3).contains($0.value) }
    }

    /// Starts a new piece at every character matching `isStart`; other characters join the current piece.
    private static func split(_ characters: [Character], startingAt isStart: (Character) -> Bool) -> [String] {
        var pieces: [String] = []
        for character in characters {
            if isStart(character) || pieces.isEmpty {
                pieces.append(String(character))
            } else {
                pieces[pieces.count - 1].append(character)
            }
        }
        return pieces
    }
}

/// Splits a Latin-script word at its vowel groups (`to·night`, `se·la·ma·nya`), which is where sung
/// notes change. A rule of thumb, not a dictionary: it works for any Latin language but splits some
/// English words differently from a dictionary (`fo·re·ver`).
enum LatinSyllabifier {
    enum Rules: Equatable {
        case standard
        /// Indonesian and Malay: every vowel is sounded (no silent e, `su·a·ra`, `di·a`) except in the
        /// diphthongs ai, au, oi and ei, "y" is a consonant, and "ng" is one consonant (`de·ngar`).
        case indonesian

        static func detect(in lines: [LyricLine]) -> Rules {
            let identifier = LyricsLanguageDetector.detectSpeechLocale(for: lines).identifier
            return identifier.hasPrefix("id") || identifier.hasPrefix("ms") ? .indonesian : .standard
        }
    }

    /// Consonant pairs that start a syllable together, so a split goes before them (`mo·ther`, `hun·dred`).
    private static let onsets: Set<String> = [
        "ch", "sh", "th", "ph", "wh", "kh", "ny", "sy",
        "bl", "br", "cl", "cr", "dr", "fl", "fr", "gl", "gr", "pl", "pr", "tr",
    ]
    private static let indonesianDiphthongs: Set<String> = ["ai", "au", "oi", "ei"]

    static func split(_ word: String, rules: Rules = .standard) -> [String] {
        let characters = Array(word)
        let bases = characters.map { character -> Character? in
            let folded = String(character).applyingTransform(.stripDiacritics, reverse: false) ?? String(character)
            return folded.lowercased().first.flatMap { $0.isLetter && $0.isASCII ? $0 : nil }
        }
        func isVowel(_ index: Int) -> Bool {
            guard let base = bases[index] else { return false }
            if "aeiou".contains(base) { return true }
            // "y" is a vowel after a consonant (my, lyrics) and a consonant otherwise (you, beyond).
            guard rules == .standard, base == "y", index > 0, let previous = bases[index - 1] else { return false }
            return !"aeiouy".contains(previous)
        }

        func extends(_ nucleus: (start: Int, end: Int), with index: Int) -> Bool {
            guard nucleus.end == index else { return false }
            guard rules == .indonesian else { return true }
            guard nucleus.end - nucleus.start == 1, let first = bases[nucleus.start], let second = bases[index] else { return false }
            return indonesianDiphthongs.contains(String([first, second]))
        }

        // Each nucleus is a run of vowels: (first index, index after its last vowel).
        var nuclei: [(start: Int, end: Int)] = []
        for index in characters.indices where isVowel(index) {
            if let last = nuclei.last, extends(last, with: index) {
                nuclei[nuclei.count - 1].end = index + 1
            } else {
                nuclei.append((index, index + 1))
            }
        }
        if rules == .standard, nuclei.count > 1, let last = nuclei.last, isSilentFinalE(last, bases: bases) {
            nuclei.removeLast()
        }
        guard nuclei.count > 1 else { return [word] }

        var cuts: [Int] = []
        for (left, right) in zip(nuclei, nuclei.dropFirst()) {
            let gap = right.start - left.end
            let pair = { (index: Int) in bases[index].flatMap { first in bases[index + 1].map { String([first, $0]) } } }
            var cut: Int = if gap <= 1 {
                left.end
            } else if let last = pair(right.start - 2), onsets.contains(last) || (rules == .indonesian && last == "ng") {
                right.start - 2
            } else if gap > 2, pair(left.end) == "ng" {
                // "ng" before another consonant closes the syllable (mang·gil, ang·ka).
                left.end + 2
            } else {
                left.end + 1
            }
            // "ck" stays with the syllable before it (pick·ing).
            if cut < right.start, bases[cut - 1] == "c", bases[cut] == "k" { cut += 1 }
            cuts.append(cut)
        }
        let bounds = [0] + cuts + [characters.count]
        return zip(bounds, bounds.dropFirst()).map { String(characters[$0..<$1]) }
    }

    /// English's silent final e (love, smile, loved, times), but not a sounded "-le" (lit·tle),
    /// "-ted"/"-ded" (wan·ted) or "-ses"-like (ro·ses) ending.
    private static func isSilentFinalE(_ nucleus: (start: Int, end: Int), bases: [Character?]) -> Bool {
        guard nucleus.end - nucleus.start == 1, bases[nucleus.start] == "e", nucleus.start > 0,
              let before = bases[nucleus.start - 1]
        else { return false }
        let after = bases[nucleus.end...].compactMap { $0 }
        switch after {
        case []:
            guard before == "l", nucleus.start > 1, let consonant = bases[nucleus.start - 2] else { return true }
            return "aeiouy".contains(consonant)
        case ["d"]: return !"td".contains(before)
        case ["s"]: return !"sxzcgh".contains(before)
        default: return false
        }
    }
}

/// A CTC acoustic model that scores one fixed-length window of 16 kHz mono audio.
protocol CTCAcousticModel: AnyObject, Sendable {
    var windowSampleCount: Int { get }
    var frameCount: Int { get }
    var vocabSize: Int { get }
    /// Row-major `[frame][vocab]` log-probabilities for a zero-mean, unit-variance window.
    func logProbabilities(window: [Float]) throws -> [Float]
}

/// Aligns the known lyrics to captured audio instead of transcribing it. Each chunk is scored in a window
/// that ends with it; a line is aligned once audio covering its LRC time ± `lineWindow` has been scored.
/// An engine that knows which lyric lines it has had the audio for, aligned or not.
protocol LineAttemptReporting: AnyObject {
    var attemptedLineIDs: Set<Int> { get }
}

final class LyricsForcedAligner: AudioChunkTranscribing, LineAttemptReporting, @unchecked Sendable {
    private struct PreparedLine {
        let id: Int
        let start: Double
        let end: Double
        let words: [ForcedAlignmentText.Word]
        /// Each word's syllables, empty for a word of one.
        let syllables: [[ForcedAlignmentText.Syllable]]
        /// Track-time limits from the nearest lines already aligned before and after this one.
        var lowerBound = -Double.infinity
        var upperBound = Double.infinity
    }

    private let model: CTCAcousticModel
    private let lines: [PreparedLine]
    private let lineWindow: Double
    private let holdBackSamples: Int
    private let lock = NSLock()
    private var done = Set<Int>()
    private let anchoredIndices: Set<Int>

    // The current run of contiguous audio; a seek or rate change starts a new one.
    private var runStartTime = 0.0
    private var runRate = 1.0
    private var expectedNextChunkStart: Double?
    private var history: [Float] = []
    private var runSamples = 0
    private var frames: [Float] = []
    private var committedFrames = 0
    /// End of the last aligned word in this run; later lines can't start before it.
    private var alignedUntilFrame = 0
    /// Onset minus LRC time of every line kept so far, across runs.
    private var lineOffsets: [Double] = []
    /// A line whose onset strays this far from the song's median offset is dropped, so it keeps its LRC time.
    private let maxOffsetDeviation = 1.0

    static let sampleRate = 16000
    /// A run starting this early is a play from the song's start: capture waits for the lyrics and
    /// model to load (1.4–8.8 s measured), so lines sung before it can't be heard on any play.
    static let playFromStartReach = 12.0

    /// `anchors` are lines aligned on an earlier play (line ID -> sung span in track time): they are not
    /// aligned again, and bound the lines between them.
    init(
        lines: [LyricLine],
        model: CTCAcousticModel,
        anchors: [Int: ClosedRange<Double>] = [:],
        lineWindow: Double = 3.0,
        holdBack: Double = 2.0
    ) {
        self.model = model
        self.lineWindow = lineWindow
        holdBackSamples = Int(holdBack * Double(Self.sampleRate))
        let script = ForcedAlignmentText.Script.detect(in: lines)
        let latinRules = LatinSyllabifier.Rules.detect(in: lines)
        let timed = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var prepared: [PreparedLine] = []
        var spans: [ClosedRange<Double>?] = []
        for (index, line) in timed.enumerated() {
            let words = ForcedAlignmentText.words(for: line.text, script: script)
            guard !words.isEmpty else { continue }
            let end = index + 1 < timed.count ? timed[index + 1].timestamp : line.timestamp + 5
            prepared.append(PreparedLine(
                id: line.id,
                start: line.timestamp,
                end: end,
                words: words,
                syllables: words.map { ForcedAlignmentText.syllables(of: $0, script: script, latinRules: latinRules) }
            ))
            spans.append(anchors[line.id])
        }
        var anchored = Set<Int>()
        var offsets: [Double] = []
        var lowerBound = -Double.infinity
        for index in prepared.indices {
            if let span = spans[index] {
                anchored.insert(index)
                offsets.append(span.lowerBound - prepared[index].start)
                lowerBound = span.upperBound
            } else {
                prepared[index].lowerBound = lowerBound
            }
        }
        var upperBound = Double.infinity
        for index in prepared.indices.reversed() {
            if let span = spans[index] {
                upperBound = span.lowerBound
            } else {
                prepared[index].upperBound = upperBound
            }
        }
        self.lines = prepared
        anchoredIndices = anchored
        done = anchored
        lineOffsets = offsets
    }

    /// Lines this engine has had the full audio window for, whether they aligned or not; not the anchors.
    var attemptedLineIDs: Set<Int> {
        lock.lock()
        defer { lock.unlock() }
        return Set(done.subtracting(anchoredIndices).map { lines[$0].id })
    }

    // swiftlint:disable:next async_without_await
    func transcribe(_ request: AudioSyncManager.AudioChunkRequest) async throws -> [RecognizedAudioWord] {
        guard request.sampleRate == Self.sampleRate, !request.samples.isEmpty else { return [] }
        return try process(request)
    }

    private func process(_ request: AudioSyncManager.AudioChunkRequest) throws -> [RecognizedAudioWord] {
        lock.lock()
        defer { lock.unlock() }
        startNewRunIfNeeded(for: request)
        try score(request.samples)
        return alignReadyLines()
    }

    func shutdown() {}

    private var secondsPerFrame: Double {
        Double(model.windowSampleCount) / Double(Self.sampleRate) / Double(model.frameCount)
    }

    private func trackTime(ofRunFrame frame: Int) -> Double {
        runStartTime + Double(frame) * secondsPerFrame * runRate
    }

    private func runFrame(atTrackTime time: Double) -> Int {
        Int(((time - runStartTime) / runRate / secondsPerFrame).rounded())
    }

    private func startNewRunIfNeeded(for request: AudioSyncManager.AudioChunkRequest) {
        let contiguous = expectedNextChunkStart.map { abs($0 - request.chunkStartTime) <= 0.5 } ?? false
        if !contiguous || abs(request.playbackRate - runRate) > 0.001 {
            if request.chunkStartTime <= Self.playFromStartReach {
                done.formUnion(lines.indices.filter { lines[$0].start < request.chunkStartTime })
            }
            runStartTime = request.chunkStartTime
            runRate = request.playbackRate
            history.removeAll()
            runSamples = 0
            frames.removeAll()
            committedFrames = 0
            alignedUntilFrame = 0
        }
        expectedNextChunkStart = request.chunkStartTime
            + Double(request.samples.count) / Double(Self.sampleRate) * request.playbackRate
    }

    /// Scores the window ending with `samples` and keeps the frames not yet kept, except the newest
    /// `holdBack`, which wait for the next window so they have audio on both sides.
    private func score(_ samples: [Float]) throws {
        let windowSize = model.windowSampleCount
        history.append(contentsOf: samples)
        if history.count > windowSize { history.removeFirst(history.count - windowSize) }
        runSamples += samples.count

        var window = [Float](repeating: 0, count: windowSize - history.count) + history
        let mean = window.reduce(0, +) / Float(windowSize)
        let variance = window.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Float(windowSize)
        let scale = 1 / (variance.squareRoot() + 1e-7)
        for index in window.indices {
            window[index] = (window[index] - mean) * scale
        }

        let logProbs = try model.logProbabilities(window: window)
        let frameCount = model.frameCount
        let windowStartFrame = Int((Double(runSamples - windowSize) / Double(windowSize) * Double(frameCount)).rounded())
        let keepEnd = Int((Double(windowSize - holdBackSamples) / Double(windowSize) * Double(frameCount)).rounded())
        let keepStart = max(0, committedFrames - windowStartFrame)
        guard keepEnd > keepStart else { return }
        frames.append(contentsOf: logProbs[(keepStart * model.vocabSize)..<(keepEnd * model.vocabSize)])
        committedFrames += keepEnd - keepStart
    }

    private func alignReadyLines() -> [RecognizedAudioWord] {
        let coveredStart = trackTime(ofRunFrame: 0)
        let coveredEnd = trackTime(ofRunFrame: committedFrames)
        var batch: [Int] = []
        for index in lines.indices where !done.contains(index) {
            let line = lines[index]
            // A line that began before this run's audio is left for a later play.
            guard line.start >= coveredStart else { continue }
            guard line.end + lineWindow <= coveredEnd else { break }
            batch.append(index)
        }
        // The newest ready line is only context, so the line before it can't stretch into its audio;
        // a line right before an aligned one is already bounded by it.
        let keep = batch.last.map { $0 == lines.count - 1 || done.contains($0 + 1) } == true ? batch.count : batch.count - 1
        guard keep > 0 else { return [] }
        done.formUnion(batch.prefix(keep))
        if let words = align(batch, keeping: keep) { return words }
        return batch.prefix(keep).flatMap { index in
            align(batch.contains(index + 1) ? [index, index + 1] : [index], keeping: 1) ?? []
        }
    }

    /// Aligns `batch` together and returns the words of its first `keep` lines.
    private func align(_ batch: [Int], keeping keep: Int) -> [RecognizedAudioWord]? {
        guard let firstLine = batch.first.map({ lines[$0] }), let lastLine = batch.last.map({ lines[$0] }) else { return nil }
        let lowFrame = max(alignedUntilFrame, runFrame(atTrackTime: windowStart(of: firstLine)))
        let highFrame = min(committedFrames - 1, runFrame(atTrackTime: windowEnd(of: lastLine)))
        guard highFrame > lowFrame else { return nil }

        var tokens: [Int] = []
        var allowed: [ClosedRange<Int>] = []
        var owners: [(line: Int, word: Int)] = []
        for index in batch {
            let line = lines[index]
            let low = max(lowFrame, runFrame(atTrackTime: windowStart(of: line))) - lowFrame
            let high = min(highFrame, runFrame(atTrackTime: windowEnd(of: line))) - lowFrame
            guard high >= low else { return nil }
            for (wordIndex, word) in line.words.enumerated() {
                for token in word.tokenIDs {
                    tokens.append(token)
                    allowed.append(low...high)
                    owners.append((index, wordIndex))
                }
            }
        }
        let vocab = model.vocabSize
        let slice = Array(frames[(lowFrame * vocab)..<((highFrame + 1) * vocab)])
        guard let spans = CTCForcedAlignment.align(logProbs: slice, vocabSize: vocab, tokens: tokens, allowedFrames: allowed)
        else { return nil }

        let kept = Set(batch.prefix(keep))
        var words: [RecognizedAudioWord] = []
        var wordLines: [Int] = []
        var keptUntilFrame: Int?
        var cursor = 0
        while cursor < spans.count, kept.contains(owners[cursor].line) {
            let owner = owners[cursor]
            var end = cursor
            while end + 1 < spans.count, owners[end + 1] == owner {
                end += 1
            }
            let wordSpans = spans[cursor...end]
            let frameCount = wordSpans.reduce(0) { $0 + $1.lastFrame - $1.firstFrame + 1 }
            let logProbability = wordSpans.reduce(Float(0)) { $0 + $1.logProbability }
            let start = trackTime(ofRunFrame: lowFrame + spans[cursor].firstFrame)
            let finish = trackTime(ofRunFrame: lowFrame + spans[end].lastFrame + 1)
            words.append(RecognizedAudioWord(
                text: lines[owner.line].words[owner.word].display,
                startTime: start,
                duration: finish - start,
                confidence: Double(exp(logProbability / Float(max(1, frameCount)))),
                syllables: syllables(lines[owner.line].syllables[owner.word], spans: spans[cursor...end], from: lowFrame)
            ))
            wordLines.append(owner.line)
            keptUntilFrame = lowFrame + spans[end].lastFrame + 1
            cursor = end + 1
        }
        if let keptUntilFrame { alignedUntilFrame = keptUntilFrame }
        return dropUnreliableLines(words, lineOf: wordLines)
    }

    /// Each syllable starts where the first of its letters was aligned.
    private func syllables(
        _ pieces: [ForcedAlignmentText.Syllable],
        spans: ArraySlice<CTCForcedAlignment.TokenSpan>,
        from lowFrame: Int
    ) -> [RecognizedAudioWord.Syllable]? {
        guard !pieces.isEmpty, pieces.reduce(0, { $0 + $1.letterCount }) == spans.count else { return nil }
        var index = spans.startIndex
        return pieces.map { piece in
            defer { index += piece.letterCount }
            return RecognizedAudioWord.Syllable(text: piece.display, startTime: trackTime(ofRunFrame: lowFrame + spans[index].firstFrame))
        }
    }

    private func windowStart(of line: PreparedLine) -> Double {
        max(line.start - lineWindow, line.lowerBound)
    }

    private func windowEnd(of line: PreparedLine) -> Double {
        min(line.end + lineWindow, line.upperBound)
    }

    /// Words the model barely hears (a shout under backing vocals, say) can land seconds off; such a
    /// line is dropped once enough lines give the song's offset to compare it with.
    private func dropUnreliableLines(_ words: [RecognizedAudioWord], lineOf wordLines: [Int]) -> [RecognizedAudioWord] {
        var dropped = Set<Int>()
        for (index, line) in wordLines.enumerated() where index == 0 || wordLines[index - 1] != line {
            let offset = words[index].startTime - lines[line].start
            if lineOffsets.count >= 4 {
                let median = lineOffsets.sorted()[lineOffsets.count / 2]
                if abs(offset - median) > maxOffsetDeviation {
                    dropped.insert(line)
                    continue
                }
            }
            lineOffsets.append(offset)
        }
        return zip(words, wordLines).filter { !dropped.contains($0.1) }.map(\.0)
    }
}

/// The Core ML conversion of the MMS forced-aligner, run on the Neural Engine.
final class CoreMLAcousticModel: CTCAcousticModel, @unchecked Sendable {
    private let model: MLModel
    let windowSampleCount: Int
    let frameCount: Int
    let vocabSize: Int

    /// `url` is a compiled `.mlmodelc`. Returns nil when the model can't load or has an unexpected shape.
    init?(compiledModelURL url: URL) {
        let config = MLModelConfiguration()
        // The CPU path returns NaN for this model; the Neural Engine path matches PyTorch.
        config.computeUnits = .cpuAndNeuralEngine
        guard let model = try? MLModel(contentsOf: url, configuration: config),
              let input = model.modelDescription.inputDescriptionsByName["audio"]?.multiArrayConstraint?.shape,
              let output = model.modelDescription.outputDescriptionsByName["logprobs"]?.multiArrayConstraint?.shape,
              input.count == 2, output.count == 3
        else { return nil }
        self.model = model
        windowSampleCount = input[1].intValue
        frameCount = output[1].intValue
        vocabSize = output[2].intValue
    }

    func logProbabilities(window: [Float]) throws -> [Float] {
        let input = try MLMultiArray(shape: [1, NSNumber(value: windowSampleCount)], dataType: .float32)
        let destination = input.dataPointer.bindMemory(to: Float.self, capacity: windowSampleCount)
        for index in 0..<min(window.count, windowSampleCount) {
            destination[index] = window[index]
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: ["audio": input])
        guard let output = try model.prediction(from: provider).featureValue(for: "logprobs")?.multiArrayValue else {
            return []
        }
        // Rows can be padded, so elements are read through the strides, not the flat subscript.
        let frameStride = output.strides[1].intValue, vocabStride = output.strides[2].intValue
        var values = [Float](repeating: 0, count: frameCount * vocabSize)
        func copy<Scalar>(_: Scalar.Type, _ convert: (Scalar) -> Float) {
            let base = output.dataPointer.bindMemory(to: Scalar.self, capacity: frameCount * frameStride)
            for frame in 0..<frameCount {
                for token in 0..<vocabSize {
                    values[frame * vocabSize + token] = convert(base[frame * frameStride + token * vocabStride])
                }
            }
        }
        switch output.dataType {
        case .float32: copy(Float.self) { $0 }
        #if arch(arm64)
        // Float16 is unavailable on Intel macOS; x86_64 builds take the default path.
        case .float16: copy(Float16.self) { Float($0) }
        #endif
        default:
            for frame in 0..<frameCount {
                for token in 0..<vocabSize {
                    values[frame * vocabSize + token] = output[[0, NSNumber(value: frame), NSNumber(value: token)]].floatValue
                }
            }
        }
        return values
    }
}

/// Where the Core ML alignment model lives, and how a sync session loads it.
enum LyricsAlignerModel {
    static let packageName = "LyricsAligner.mlpackage"
    static let compiledName = "LyricsAligner.mlmodelc"

    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("BarTune/Models", isDirectory: true)
    }

    /// The model, published as a pre-release so the app updater never treats it as an app release.
    static let downloadURLString =
        "https://github.com/TrigrD3/bartune/releases/download/lyrics-aligner-model-1/LyricsAligner.mlpackage.zip"
    static let downloadSHA256 = "f9c2d96ce0321f5f8d03702fc7b3f9db77f0851bdaecddfe9974837d6095a586"
    static let downloadSizeDescription = "274 MB"

    enum InstallError: LocalizedError {
        case checksumMismatch
        case httpStatus(Int)
        case unpackFailed
        case invalidURL

        var errorDescription: String? {
            switch self {
            case .checksumMismatch: "The downloaded model did not match its checksum."
            case let .httpStatus(code): "Download failed with HTTP \(code)."
            case .unpackFailed: "The downloaded model could not be unpacked."
            case .invalidURL: "The model download address is invalid."
            }
        }
    }

    static func download(into directory: URL = directory) async throws {
        guard let url = URL(string: downloadURLString) else { throw InstallError.invalidURL }
        let (archive, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: archive) }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw InstallError.httpStatus(http.statusCode)
        }
        try await Task.detached(priority: .utility) {
            try install(archive: archive, expectedSHA256: downloadSHA256, into: directory)
        }.value
    }

    /// Verifies and unpacks a zipped `LyricsAligner.mlpackage` into `directory`, replacing any earlier model.
    static func install(archive: URL, expectedSHA256: String, into directory: URL) throws {
        guard try AppUpdateService.sha256Hex(ofFileAt: archive) == expectedSHA256.lowercased() else {
            throw InstallError.checksumMismatch
        }
        let fileManager = FileManager.default
        let staging = directory.appendingPathComponent(".staging-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", archive.path, staging.path]
        try ditto.run()
        ditto.waitUntilExit()
        let unpacked = staging.appendingPathComponent(packageName)
        guard ditto.terminationStatus == 0, fileManager.fileExists(atPath: unpacked.path) else {
            throw InstallError.unpackFailed
        }
        for name in [packageName, compiledName] {
            try? fileManager.removeItem(at: directory.appendingPathComponent(name))
        }
        try fileManager.moveItem(at: unpacked, to: directory.appendingPathComponent(packageName))
    }

    static func isInstalled(in directory: URL = directory) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: directory.appendingPathComponent(compiledName).path)
            || fileManager.fileExists(atPath: directory.appendingPathComponent(packageName).path)
    }

    /// Returns an aligner for `lines`, compiling an installed `.mlpackage` once; nil when the model is
    /// missing, fails to load, or the Mac has no Neural Engine (the model's CPU path returns NaN).
    static func launch(
        lines: [LyricLine],
        anchors: [Int: ClosedRange<Double>] = [:],
        directory: URL = directory
    ) async -> AudioChunkTranscribing? {
        #if arch(arm64)
            let compiled = directory.appendingPathComponent(compiledName)
            let package = directory.appendingPathComponent(packageName)
            let fileManager = FileManager.default
            if !fileManager.fileExists(atPath: compiled.path), fileManager.fileExists(atPath: package.path) {
                guard let temporary = try? await MLModel.compileModel(at: package) else { return nil }
                try? fileManager.removeItem(at: compiled)
                guard (try? fileManager.moveItem(at: temporary, to: compiled)) != nil else { return nil }
            }
            return await Task.detached(priority: .utility) {
                CoreMLAcousticModel(compiledModelURL: compiled).map { LyricsForcedAligner(lines: lines, model: $0, anchors: anchors) }
            }.value
        #else
            return nil
        #endif
    }
}
