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
            let lyricalLines = lines.filter { !ForcedAlignmentText.isStructuralTag($0.text) }
            if JapaneseRomanizer.isJapaneseTrack(lyricalLines) { return .japanese }
            if KoreanRomanizer.isKoreanTrack(lyricalLines) { return .korean }
            if ChineseRomanizer.isChineseTrack(lyricalLines) { return .chinese }
            return .latin
        }
    }

    struct Word: Equatable {
        let display: String
        let reading: String
        let tokenIndex: Int
        var tokenIDs: [Int] { reading.compactMap { ForcedAlignmentText.vocabulary[$0] } }
    }

    /// The MMS forced-aligner's letters (`<blank>` is 0; `<pad>`, `</s>`, `<unk>` are unused).
    static let vocabulary: [Character: Int] = Dictionary(uniqueKeysWithValues: Array("aienoutsrmkldghybpwcvjzf'qx")
        .enumerated().map { ($1, $0 + 4) })

    private static let structuralTag = try! NSRegularExpression(
        pattern: #"^(?:\[\s*(?:(?:pre|post)[ -]?)?(?:chorus|verse|intro|bridge|outro|instrumental|interlude|refrain|hook|break|(?:guitar\s+)?solo)(?:\s+\d+)?(?:\s+x\d+)?(?:\s*:[^\[\]]*)?\s*\]|\(\s*(?:x\s*\d+|\d+\s*x)\s*\))$"#,
        options: .caseInsensitive
    )

    static func isStructuralTag(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "[" || trimmed.first == "(" else { return false }
        return structuralTag.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil
    }

    private static let symbolReadings: [Character: String] = ["&": "and", "%": "percent", "+": "plus"]

    /// A symbol-only display token can still be spoken by the forced alignment model.
    static func displaySymbols(in text: String) -> String {
        String(text.filter { symbolReadings[$0] != nil })
    }

    static func containsLead(_ display: String, withBackingVocalsRemoved lead: String) -> Bool {
        display == lead || lead.contains(where: canBeSung)
    }

    private static func canBeSung(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || symbolReadings[character] != nil
    }

    /// Same token boundaries as the original display, with inline backing vocals removed from readings.
    static func leadDisplays(in displays: [String]) -> [String] {
        guard displays.contains(where: { $0.contains("(") }) else { return displays }

        var groups: [Range<Int>] = []
        var depth = 0
        var start = 0
        for (offset, character) in displays.lazy.flatMap({ $0 }).enumerated() {
            if character == "(" {
                if depth == 0 { start = offset }
                depth += 1
            } else if character == ")", depth > 0 {
                depth -= 1
                if depth == 0 { groups.append(start..<(offset + 1)) }
            }
        }
        guard !groups.isEmpty else { return displays }

        var offset = 0
        var group = 0
        let outside = displays.map { display in
            display.filter { _ in
                defer { offset += 1 }
                if group < groups.count, offset == groups[group].upperBound { group += 1 }
                return group == groups.count || !groups[group].contains(offset)
            }
        }
        let hasLead = outside.contains { $0.contains(where: canBeSung) }
        return hasLead ? outside : displays
    }

    /// Lyric tokens of one line (as `LyricsAudioAligner.tokenizeLine` splits it) with their readings.
    /// Tokens with no model reading, such as decorative punctuation, are left out.
    static func words(for text: String, script: Script) -> [Word] {
        guard !isStructuralTag(text) else { return [] }
        let tokens = LyricsAudioAligner.tokenizeLine(text)
        let lead = leadDisplays(in: tokens.map(\.display)).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let leadIndices = lead.indices.filter { !lead[$0].isEmpty }
        let spoken = leadIndices.map { lead[$0] }
        let readings: [String] = switch script {
        case .japanese: JapaneseRomanizer.romanizeWords(spoken)
        case .korean: spoken.map(KoreanRomanizer.romanizeLine)
        case .chinese: spoken.map(ChineseRomanizer.romanizeLine)
        case .latin: spoken
        }
        return zip(leadIndices, readings).compactMap { index, reading in
            let leadDisplay = lead[index]
            let isLatin = script == .latin || (!JapaneseRomanizer.containsJapaneseOrCJK(leadDisplay) && !KoreanRomanizer.containsHangul(leadDisplay))
            let letters = letters(of: isLatin && !reading.isEmpty ? latinReading(leadDisplay) : reading)
            let display = tokens[index].display.trimmingCharacters(in: .whitespacesAndNewlines)
            return letters.isEmpty ? nil : Word(display: display, reading: letters, tokenIndex: index)
        }
    }

    private static let elisions = ["'bout": "about", "'cause": "cause", "'cuz": "cause", "'til": "until", "'em": "them", "'round": "around"]
    private static let numericToken = try! NSRegularExpression(
        pattern: #"(?<![\p{L}\p{N}])(?:[0-9]{1,3}(?:,[0-9]{3})+|24/7|[0-9]{1,4}(?:st|nd|rd|th)?)(?![\p{L}\p{N}])"#
    )
    private static let smallNumbers = [
        "zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine",
        "ten", "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen",
    ]
    private static let tens = ["", "", "twenty", "thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"]
    private static let cardinalScales: [(Int, String)] = [
        (1_000_000_000_000_000_000, "quintillion"),
        (1_000_000_000_000_000, "quadrillion"),
        (1_000_000_000_000, "trillion"),
        (1_000_000_000, "billion"),
        (1_000_000, "million"),
        (1000, "thousand"),
    ]
    private static let irregularOrdinals = [
        "one": "first",
        "two": "second",
        "three": "third",
        "five": "fifth",
        "eight": "eighth",
        "nine": "ninth",
        "twelve": "twelfth"
    ]

    private static func latinReading(_ text: String) -> String {
        guard !text.allSatisfy(\.isLetter) else { return text }
        let straight = text.lowercased().replacingOccurrences(of: "’", with: "'").replacingOccurrences(of: "‘", with: "'")
        var reading = straight
        if let apostrophe = straight.firstIndex(where: { $0.isLetter || $0 == "'" }), straight[apostrophe] == "'" {
            let word = straight[straight.index(after: apostrophe)...].prefix(while: \.isLetter)
            if let expansion = elisions["'" + word] {
                reading.replaceSubrange(apostrophe..<word.endIndex, with: expansion)
            }
        }
        if reading.utf8.contains(where: { (48...57).contains($0) }) {
            let numericMatches = numericToken.matches(in: reading, range: NSRange(reading.startIndex..., in: reading))
            // Edit in reverse order so the next match's UTF-16 offsets still refer to the same text.
            for match in numericMatches.reversed() {
                guard let range = Range(match.range, in: reading) else { continue }
                reading.replaceSubrange(range, with: numberReading(reading[range]))
            }
        }
        for (symbol, spoken) in symbolReadings where reading.contains(symbol) {
            reading = reading.replacingOccurrences(of: String(symbol), with: spoken)
        }
        return reading
    }

    private static func numberReading(_ text: Substring) -> String {
        if text == "24/7" { return "twenty four seven" }
        // Comma grouping makes the cardinal reading explicit, even for four-digit values.
        if text.contains(",") {
            guard let number = Int(text.replacingOccurrences(of: ",", with: "")) else { return String(text) }
            return cardinal(number)
        }
        let digits = text.prefix(while: \.isNumber)
        guard let number = Int(digits) else { return String(text) }
        if digits.count < text.count {
            var components = cardinal(number).split(separator: " ")
            guard let last = components.popLast() else { return String(text) }
            let ordinal = irregularOrdinals[String(last)] ?? (last.hasSuffix("y") ? "\(last.dropLast())ieth" : "\(last)th")
            return (components + [Substring(ordinal)]).joined(separator: " ")
        }
        let remainder = number % 100
        if (1100...1999).contains(number) {
            let century = cardinal(number / 100)
            if remainder == 0 { return century + " hundred" }
            return century + (remainder < 10 ? " oh " : " ") + cardinal(remainder)
        }
        if (2010...2099).contains(number) { return "twenty " + cardinal(remainder) }
        return cardinal(number)
    }

    private static func cardinal(_ number: Int) -> String {
        if number < smallNumbers.count { return smallNumbers[number] }
        for (base, scale) in cardinalScales where number >= base {
            let high = cardinal(number / base) + " " + scale
            let low = number % base
            return low == 0 ? high : high + " " + cardinal(low)
        }
        let base = number < 100 ? 10 : 100
        let high = base == 10 ? tens[number / base] : smallNumbers[number / base] + " hundred"
        let low = number % base
        return low == 0 ? high : high + " " + cardinal(low)
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
/// An engine that reports which lyric lines it had the audio for, and which of them it aligned confidently.
protocol LineAttemptReporting: AnyObject {
    /// Lyrics attempted against captured audio, including lines with no reliable match. Anchors are excluded.
    var attemptedLineIDs: Set<Int> { get }
    /// Aligned lines whose words the model heard clearly enough to lock.
    var confidentLineIDs: Set<Int> { get }
    /// Aligned lines just below that, locked only when the vocal envelope rises at their start.
    var nearlyConfidentLineIDs: Set<Int> { get }
    /// Releases a provisional offset after a sustained run of attempted lines with no new locks.
    func discardStaleOffset(lockedLineIDs: Set<Int>) -> Bool
}

final class LyricsForcedAligner: AudioChunkTranscribing, LineAttemptReporting, @unchecked Sendable {
    private struct PreparedLine {
        let id: Int
        let start: Double
        /// The next row provides context even when a held vocal extends past it.
        let contextEnd: Double
        let searchEnd: Double
        let words: [ForcedAlignmentText.Word]
        let wordIntervals: [ClosedRange<Double>]?
        /// Each word's syllables, empty for a word of one.
        let syllables: [[ForcedAlignmentText.Syllable]]
        /// Track-time limits from the nearest lines already aligned before and after this one.
        var lowerBound = -Double.infinity
        var upperBound = Double.infinity
    }

    private struct SearchWindow {
        let start: Double
        let end: Double
        let readyAt: Double
        let earliestOnset: Double
        let latestOnset: Double
        /// The search edges before neighboring anchors constrain the CTC path.
        let rawStart: Double
        let rawEnd: Double
        /// Estimated track-time shift for word priors; nil while testing a coarse offset.
        let wordOffset: Double?
    }

    private struct Alignment {
        var words: [RecognizedAudioWord] = []
        var confidentOffsets: [Int: Double] = [:]
        var nearlyConfident: Set<Int> = []
        var confidenceSum = 0.0
    }

    private let model: CTCAcousticModel
    private let lines: [PreparedLine]
    private let lineWindow: Double
    private let holdBackSamples: Int
    private let lock = NSLock()
    private var done = Set<Int>()
    private let anchoredIndices: Set<Int>
    private var confident = Set<Int>()
    private var nearlyConfident = Set<Int>()

    // The current run of contiguous audio; a seek or rate change starts a new one.
    private var skippedInRun = Set<Int>()
    private var doneAtRunStart = Set<Int>()
    private var runStartTime = 0.0
    private var runRate = 1.0
    private var expectedNextChunkStart: Double?
    private var history: [Float] = []
    private var runSamples = 0
    private var frames: [Float] = []
    private var committedFrames = 0
    /// End of the last aligned word in this run; later lines can't start before it.
    private var alignedUntilFrame = 0
    /// Onset minus LRC time of each anchor and confident line, across runs.
    private var lineOffsets: [Int: Double] = [:]
    private let maxOffsetDeviation = 1.25
    static let maxWordSpan = 3.5
    static let maxIntroStart = 10.0

    static func maxLineSpan(wordCount: Int) -> Double {
        max(6, Double(wordCount) * 1.7)
    }

    /// A line whose words average at least this confidence is locked. Tuned on JamendoLyrics (English):
    /// 93% of such lines start within 300 ms of the sung onset, against 70% of all aligned lines.
    static let lockConfidence = 0.15
    /// A line from this confidence up is locked when its start sits on a vocal onset (`VocalEnvelope.onsetRise`).
    static let onsetLockConfidence = 0.08

    static let sampleRate = 16000

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
        let alignmentRows = lines.filter { !ForcedAlignmentText.isStructuralTag($0.text) }
        let script = ForcedAlignmentText.Script.detect(in: lines)
        let latinRules = LatinSyllabifier.Rules.detect(in: alignmentRows)
        let instrumentalGap = 12.0
        var prepared: [PreparedLine] = []
        var spans: [ClosedRange<Double>?] = []
        for (index, line) in alignmentRows.enumerated() {
            let words = ForcedAlignmentText.words(for: line.text, script: script)
            guard !words.isEmpty else { continue }
            let next = index + 1 < alignmentRows.count ? alignmentRows[index + 1] : nil
            let endsAtBlank = next?.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == true
            let duration = line.duration ?? 0
            let nextTime = next?.timestamp ?? (line.timestamp + max(5, duration))
            let hasLongGap = !endsAtBlank && next.map { $0.timestamp - line.timestamp > instrumentalGap } == true
            // A distant row adds little context. Allow a plausible declared duration for the line before it.
            let estimatedDuration = max(8, Double(words.count) * 1.2, duration <= instrumentalGap ? duration : 0)
            let contextEnd = hasLongGap ? min(nextTime, line.timestamp + estimatedDuration) : nextTime
            prepared.append(PreparedLine(
                id: line.id,
                start: line.timestamp,
                contextEnd: contextEnd,
                searchEnd: endsAtBlank || hasLongGap ? contextEnd : max(contextEnd, line.timestamp + duration),
                words: words,
                wordIntervals: Self.wordIntervals(in: line, matching: words),
                syllables: words.map { ForcedAlignmentText.syllables(of: $0, script: script, latinRules: latinRules) }
            ))
            spans.append(anchors[line.id])
        }
        var anchored = Set<Int>()
        var offsets: [Int: Double] = [:]
        var lowerBound = -Double.infinity
        for index in prepared.indices {
            if let span = spans[index] {
                anchored.insert(index)
                offsets[index] = span.lowerBound - prepared[index].start
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

    private static func wordIntervals(in line: LyricLine, matching words: [ForcedAlignmentText.Word]) -> [ClosedRange<Double>]? {
        guard !line.words.isEmpty,
              line.words.allSatisfy({ word in
                  let duration = word.duration ?? 0
                  return word.timestamp >= 0 && duration >= 0 && (word.timestamp + duration).isFinite
              }),
              !zip(line.words, line.words.dropFirst()).contains(where: { $0.timestamp > $1.timestamp })
        else { return nil }

        let groups: [[WordTimestamp]]
        if let displayGroups = LyricsAudioAligner.tokenGroups(of: line) {
            groups = words.map { displayGroups[$0.tokenIndex] }
        } else {
            // Some providers omit surrounding whitespace on individual timed words.
            let displays = LyricsAudioAligner.tokenizeLine(line.text).map(\.display)
            let coversAllDisplayTokens = line.words.count == displays.count
            let expected = coversAllDisplayTokens ? displays : words.map(\.display)
            guard line.words.count == expected.count, zip(line.words, expected).allSatisfy({ word, display in
                word.text.trimmingCharacters(in: .whitespacesAndNewlines) == display.trimmingCharacters(in: .whitespacesAndNewlines)
            }) else { return nil }
            groups = coversAllDisplayTokens ? words.map { [line.words[$0.tokenIndex]] } : line.words.map { [$0] }
        }
        let intervals = groups.compactMap { group -> ClosedRange<Double>? in
            guard let start = group.first?.timestamp,
                  let end = group.map({ $0.timestamp + ($0.duration ?? 0) }).max()
            else { return nil }
            return start...end
        }
        return intervals.count == words.count ? intervals : nil
    }

    var attemptedLineIDs: Set<Int> {
        lock.lock()
        defer { lock.unlock() }
        return Set(done.subtracting(anchoredIndices).map { lines[$0].id })
    }

    var confidentLineIDs: Set<Int> {
        lock.lock()
        defer { lock.unlock() }
        return Set(confident.map { lines[$0].id })
    }

    var nearlyConfidentLineIDs: Set<Int> {
        lock.lock()
        defer { lock.unlock() }
        return Set(nearlyConfident.subtracting(confident).map { lines[$0].id })
    }

    func discardStaleOffset(lockedLineIDs: Set<Int>) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard anchoredIndices.isEmpty, !lineOffsets.isEmpty else { return false }
        // Include locks the manager promoted using vocal onsets as well as acoustic offset evidence.
        let locks = confident.union(done.filter { lockedLineIDs.contains(lines[$0].id) })
        guard locks.count <= 4, let lastLock = locks.max() else { return false }
        // Count distinct misses after the latest lock. Nearly confident lines still support the offset.
        let misses = done.lazy.filter {
            $0 > lastLock && !self.doneAtRunStart.contains($0) && !self.nearlyConfident.contains($0)
        }
        guard misses.prefix(8).count == 8 else { return false }

        // Look for a new offset on the remaining rows. A later run can retry the discarded rows.
        skippedInRun.formUnion(done)
        done.removeAll()
        doneAtRunStart.removeAll()
        lineOffsets.removeAll()
        confident.removeAll()
        nearlyConfident.removeAll()
        alignedUntilFrame = 0
        return true
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
        try score(request.samples, holdingBack: !request.isFinal)
        return alignReadyLines(throughEnd: request.isFinal)
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
            runStartTime = request.chunkStartTime
            runRate = request.playbackRate
            history.removeAll()
            runSamples = 0
            frames.removeAll()
            committedFrames = 0
            alignedUntilFrame = 0
            skippedInRun.removeAll()
            doneAtRunStart = done
        }
        expectedNextChunkStart = request.chunkStartTime
            + Double(request.samples.count) / Double(Self.sampleRate) * request.playbackRate
    }

    /// Scores the window ending with `samples` and keeps the frames not yet kept, except the newest
    /// `holdBack`, which wait for the next window so they have audio on both sides (unless no window follows).
    private func score(_ samples: [Float], holdingBack: Bool) throws {
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
        let heldBack = holdingBack ? holdBackSamples : 0
        let keepEnd = Int((Double(windowSize - heldBack) / Double(windowSize) * Double(frameCount)).rounded())
        let keepStart = max(0, committedFrames - windowStartFrame)
        guard keepEnd > keepStart else { return }
        frames.append(contentsOf: logProbs[(keepStart * model.vocabSize)..<(keepEnd * model.vocabSize)])
        committedFrames += keepEnd - keepStart
    }

    /// `throughEnd`: the run's audio ends here (the track's last chunk), so every line still ahead is aligned
    /// with what was heard.
    private func alignReadyLines(throughEnd: Bool = false) -> [RecognizedAudioWord] {
        var words: [RecognizedAudioWord] = []
        var previousDoneCount: Int
        repeat {
            previousDoneCount = done.count
            words += alignReadyBatch(throughEnd: throughEnd)
        } while done.count > previousDoneCount
        return words
    }

    private func alignReadyBatch(throughEnd: Bool) -> [RecognizedAudioWord] {
        let coveredStart = trackTime(ofRunFrame: 0)
        let coveredEnd = trackTime(ofRunFrame: committedFrames)
        let canProbe = lineOffsets.isEmpty && lineWindow > 0
        var missedRawOnsets: [Int] = []
        var batch: [Int] = []
        for index in lines.indices where !done.contains(index) && !skippedInRun.contains(index) {
            let window = searchWindow(for: index)
            guard window.latestOnset >= coveredStart else {
                // A late vocal may still be captured, even when its raw onset was missed.
                if canProbe, lines[index].start + 2 * lineWindow >= coveredStart {
                    missedRawOnsets.append(index)
                }
                continue
            }
            guard window.readyAt <= coveredEnd || (throughEnd && window.earliestOnset < coveredEnd) else { break }
            // A seek may start after the next anchor, or finish before the previous anchor,
            // or overlap by less than two frames (where `align` cannot produce a valid span).
            let effectiveLow = max(0, runFrame(atTrackTime: window.start))
            let effectiveHigh = min(committedFrames - 1, runFrame(atTrackTime: window.end))
            guard max(coveredStart, window.start) < min(coveredEnd, window.end),
                  effectiveHigh > effectiveLow
            else { continue }
            batch.append(index)
            if endsBeforeInstrumentalBreak(index) { break }
        }
        // Do not commit a batch while its trailing line (whether a context row or a row bounded by an
        // upcoming anchor) still has uncovered audio in its effective search window.
        while let last = batch.last,
              !throughEnd,
              searchWindow(for: last).end > coveredEnd {
            batch.removeLast()
        }
        let keep = keptLineCount(in: batch, throughEnd: throughEnd)
        let baseline = keep > 0 ? align(batch, keeping: keep) : nil
        if canProbe, let words = commitCoarseMatch(
            in: batch, keeping: keep, baseline: baseline, missedRawOnsets: missedRawOnsets, throughEnd: throughEnd
        ) {
            return words
        }
        let kept = batch.prefix(keep)
        if let baseline { return commitBatch(baseline, keeping: kept) }
        done.formUnion(kept)
        return kept.flatMap { index in
            let withContext = batch.contains(index + 1) ? align([index, index + 1], keeping: 1) : nil
            return (withContext ?? align([index], keeping: 1)).map(commit) ?? []
        }
    }

    private func keptLineCount(in batch: [Int], throughEnd: Bool) -> Int {
        guard let last = batch.last else { return 0 }
        // The newest ready line is context unless the batch ends at a known boundary.
        let lastIsBounded = throughEnd || last == lines.count - 1 || done.contains(last + 1) || endsBeforeInstrumentalBreak(last)
        return batch.count - (lastIsBounded ? 0 : 1)
    }

    /// Tries the two adjacent timing ranges against the frames already scored for the raw batch.
    /// Returns an empty result while a plausible later window still needs audio.
    private func commitCoarseMatch(
        in batch: [Int], keeping keep: Int, baseline: Alignment?, missedRawOnsets: [Int], throughEnd: Bool
    ) -> [RecognizedAudioWord]? {
        let confidenceGain = 0.05
        let baselineLocks = baseline?.confidentOffsets.count ?? 0

        let coveredStart = trackTime(ofRunFrame: alignedUntilFrame)
        let coveredEnd = trackTime(ofRunFrame: committedFrames)
        var winner: (alignment: Alignment, kept: ArraySlice<Int>, missed: ArraySlice<Int>, confidence: Double)?
        var waitingForAudio = false
        for shift in [-2 * lineWindow, 2 * lineWindow] {
            let candidates = shift > 0 ? missedRawOnsets + batch : batch
            let candidateKeep = keptLineCount(in: candidates, throughEnd: throughEnd)
            guard candidateKeep > 0 else { continue }
            let minimumLines = min(2, candidates.count)
            let minimumKept = min(2, candidateKeep)
            // Count rejected and uncovered lines as zero so a smaller probe cannot win by skipping weak lines.
            let comparisonCount = Double(max(keep, candidateKeep))
            let baselineConfidence = (baseline?.confidenceSum ?? 0) / comparisonCount
            guard baselineConfidence + confidenceGain <= 1 else { continue }
            let windows = candidates.map { searchWindow(for: $0, coarseShift: shift) }
            // The onset must be captured, even if the padding before it is clipped.
            let eligible = windows.drop { $0.latestOnset < coveredStart }
            let covered = eligible.prefix { window in
                let effectiveLow = max(alignedUntilFrame, runFrame(atTrackTime: window.start))
                let effectiveHigh = min(committedFrames - 1, runFrame(atTrackTime: window.end))
                return window.latestOnset >= coveredStart
                    && (throughEnd ? window.latestOnset < coveredEnd : window.end <= coveredEnd)
                    && max(coveredStart, window.start) < min(coveredEnd, window.end)
                    && effectiveHigh > effectiveLow
            }
            let lastIsBounded = throughEnd || (covered.endIndex == candidates.endIndex && candidateKeep == candidates.count)
            let probeKeep = covered.count - (lastIsBounded ? 0 : 1)
            if covered.count < minimumLines || probeKeep < minimumKept {
                waitingForAudio = waitingForAudio || (eligible.count >= minimumLines && covered.count < eligible.count)
                continue
            }
            let probe = candidates[covered.indices]
            guard let match = align(Array(probe), keeping: probeKeep, coarseShift: shift),
                  !match.confidentOffsets.isEmpty,
                  match.confidentOffsets.count >= baselineLocks
            else { continue }
            // A lone clipped row needs a clearly heard first word; later syllables can otherwise
            // pull a CTC path across a long blank stretch and manufacture an early onset.
            if throughEnd, probeKeep == 1, covered.contains(where: { $0.end > coveredEnd }),
               (match.words.first?.confidence ?? 0) < 0.01 { continue }
            let confidence = match.confidenceSum / comparisonCount
            guard confidence >= baselineConfidence + confidenceGain else { continue }
            if let winner {
                let current = winner.alignment
                guard match.confidentOffsets.count > current.confidentOffsets.count
                    || (match.confidentOffsets.count == current.confidentOffsets.count && confidence > winner.confidence)
                else { continue }
            }
            winner = (match, probe.prefix(probeKeep), candidates[..<probe.startIndex], confidence)
        }
        guard let winner else {
            return !throughEnd && baselineLocks == 0 && waitingForAudio ? [] : nil
        }
        // Earlier lines missed by capture stay eligible on a later run, and the uncovered tail stays pending.
        skippedInRun.formUnion(winner.missed)
        return commitBatch(winner.alignment, keeping: winner.kept)
    }

    /// Aligns `batch` together and evaluates the words of its first `keep` lines.
    private func align(
        _ batch: [Int], keeping keep: Int, coarseShift: Double? = nil, usesWordPriors: Bool = true, frameBounds: ClosedRange<Int>? = nil
    ) -> Alignment? {
        let windows = batch.map { searchWindow(for: $0, coarseShift: coarseShift) }
        guard let start = windows.map(\.start).min(), let end = windows.map(\.end).max() else { return nil }
        let lowFrame = max(alignedUntilFrame, runFrame(atTrackTime: start), frameBounds?.lowerBound ?? 0)
        let highFrame = min(committedFrames - 1, runFrame(atTrackTime: end), frameBounds?.upperBound ?? Int.max)
        guard highFrame > lowFrame else { return nil }

        var tokens: [Int] = []
        var allowed: [ClosedRange<Int>] = []
        var pinningRanges: [ClosedRange<Int>] = []
        var owners: [(line: Int, word: Int)] = []
        var restrictedByWordPriors = false
        for (index, window) in zip(batch, windows) {
            let line = lines[index]
            let low = max(lowFrame, runFrame(atTrackTime: window.start))
            let high = min(highFrame, runFrame(atTrackTime: window.end))
            guard high >= low else { return nil }
            let lineRange = (low - lowFrame)...(high - lowFrame)
            let wordRanges = usesWordPriors ? priorFrameRanges(line.wordIntervals, in: window, frames: low...high, from: lowFrame) : nil
            pinningRanges.append(runFrame(atTrackTime: window.rawStart)...min(committedFrames - 1, runFrame(atTrackTime: window.rawEnd)))
            for (wordIndex, word) in line.words.enumerated() {
                let range = wordRanges?[wordIndex] ?? lineRange
                if range != lineRange { restrictedByWordPriors = true }
                for token in word.tokenIDs {
                    tokens.append(token)
                    allowed.append(range)
                    owners.append((index, wordIndex))
                }
            }
        }
        let vocab = model.vocabSize
        let slice = Array(frames[(lowFrame * vocab)..<((highFrame + 1) * vocab)])
        guard let spans = CTCForcedAlignment.align(logProbs: slice, vocabSize: vocab, tokens: tokens, allowedFrames: allowed)
        else { return restrictedByWordPriors ? align(batch, keeping: keep, coarseShift: coarseShift, usesWordPriors: false) : nil }

        let kept = Set(batch.prefix(keep))
        var words: [RecognizedAudioWord] = []
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
                syllables: syllables(lines[owner.line].syllables[owner.word], spans: spans[cursor...end], from: lowFrame),
                sourceLineId: lines[owner.line].id
            ))
            cursor = end + 1
        }
        let keptLines = batch.prefix(keep)
        let alignment = dropUnreliableLines(words, lines: keptLines, pinningRanges: pinningRanges, isCoarseProbe: coarseShift != nil)
        guard restrictedByWordPriors else { return alignment }
        if alignment.words.isEmpty {
            // A provider's times can spell the lyrics correctly yet miss the actual vocal entirely.
            return align(batch, keeping: keep, coarseShift: coarseShift, usesWordPriors: false) ?? alignment
        }
        return retryRejectedLines(in: alignment, keeping: keptLines, coarseShift: coarseShift)
    }

    private func retryRejectedLines(in alignment: Alignment, keeping kept: ArraySlice<Int>, coarseShift: Double?) -> Alignment {
        let accepted = Dictionary(grouping: alignment.words, by: \.sourceLineId)
        let rejectedRuns = kept.split { accepted[lines[$0].id] != nil }
        guard !rejectedRuns.isEmpty else { return alignment }

        var combined = alignment
        // Each rejected run can search the full line windows between its accepted neighbors.
        for run in rejectedRuns {
            var low = alignedUntilFrame
            var high = committedFrames - 1
            if run.startIndex > kept.startIndex, let previous = accepted[lines[kept[run.startIndex - 1]].id]?.last {
                low = runFrame(atTrackTime: previous.startTime + previous.duration)
            }
            if run.endIndex < kept.endIndex, let next = accepted[lines[kept[run.endIndex]].id]?.first {
                high = runFrame(atTrackTime: next.startTime) - 1
            }
            guard low < high,
                  let retry = align(Array(run), keeping: run.count, coarseShift: coarseShift, usesWordPriors: false, frameBounds: low...high)
            else { continue }
            combined.words.append(contentsOf: retry.words)
            combined.confidentOffsets.merge(retry.confidentOffsets) { accepted, _ in accepted }
            combined.nearlyConfident.formUnion(retry.nearlyConfident)
            combined.confidenceSum += retry.confidenceSum
        }
        combined.words.sort { $0.startTime < $1.startTime }
        return combined
    }

    private func priorFrameRanges(
        _ intervals: [ClosedRange<Double>]?, in window: SearchWindow, frames: ClosedRange<Int>, from lowFrame: Int
    ) -> [ClosedRange<Int>]? {
        guard let intervals, let offset = window.wordOffset else { return nil }
        let start = max(window.start, trackTime(ofRunFrame: frames.lowerBound))
        let end = min(window.end, trackTime(ofRunFrame: frames.upperBound))
        let padding = 1.0
        var ranges: [ClosedRange<Int>] = []
        for interval in intervals {
            let lower = max(start, interval.lowerBound + offset - padding)
            let upper = min(end, interval.upperBound + offset + padding)
            guard lower <= upper else { return nil }
            ranges.append((runFrame(atTrackTime: lower) - lowFrame)...(runFrame(atTrackTime: upper) - lowFrame))
        }
        return ranges
    }

    private func commit(_ alignment: Alignment) -> [RecognizedAudioWord] {
        confident.formUnion(alignment.confidentOffsets.keys)
        lineOffsets.merge(alignment.confidentOffsets) { _, offset in offset }
        nearlyConfident.formUnion(alignment.nearlyConfident)
        if let last = alignment.words.last {
            alignedUntilFrame = runFrame(atTrackTime: last.startTime + last.duration)
        }
        return alignment.words
    }

    private func commitBatch(_ alignment: Alignment, keeping kept: ArraySlice<Int>) -> [RecognizedAudioWord] {
        let acceptedIDs = Set(alignment.words.compactMap(\.sourceLineId))
        guard let firstRejected = kept.dropLast().firstIndex(where: { !acceptedIDs.contains(lines[$0].id) }) else {
            done.formUnion(kept)
            return commit(alignment)
        }
        // A rejected line can force later words off their real peaks. Leave that suffix for the next batch.
        done.formUnion(kept[...firstRejected])
        let prefix = kept[..<firstRejected]
        let prefixIDs = Set(prefix.map { lines[$0].id })
        var accepted = alignment
        accepted.words = alignment.words.filter { $0.sourceLineId.map(prefixIDs.contains) ?? false }
        accepted.confidentOffsets = alignment.confidentOffsets.filter { $0.key < kept[firstRejected] }
        accepted.nearlyConfident = alignment.nearlyConfident.filter { $0 < kept[firstRejected] }
        return commit(accepted)
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

    private func endsBeforeInstrumentalBreak(_ index: Int) -> Bool {
        index + 1 < lines.count && lines[index + 1].start - lines[index].contextEnd > 2 * lineWindow
    }

    private func median(_ offsets: [Double]) -> Double? {
        guard !offsets.isEmpty else { return nil }
        let sorted = offsets.sorted()
        return (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
    }

    private func offsetEstimate(before index: Int, using offsets: [Int: Double]) -> (offset: Double, priorCount: Int) {
        guard !offsets.isEmpty else { return (0, 0) }
        let recent = Array(lines.indices[..<index].reversed().lazy.compactMap { offsets[$0] }.prefix(3))
        return (median(recent) ?? median(Array(offsets.values)) ?? 0, recent.count)
    }

    private func searchWindow(for index: Int, coarseShift: Double? = nil) -> SearchWindow {
        let line = lines[index]
        let (offset, priorCount) = offsetEstimate(before: index, using: lineOffsets)
        // Keep the LRC window within reach until two earlier lines support the shift.
        let startShift = coarseShift ?? (priorCount < 2 ? min(0, offset) : offset)
        let endShift = coarseShift ?? (priorCount < 2 ? max(0, offset) : offset)
        let paddedStart = line.start + startShift - lineWindow
        let rawStart = coarseShift != nil ? max(0, paddedStart) : (index == 0 && line.start <= Self.maxIntroStart ? 0 : paddedStart)
        let rawEnd = line.searchEnd + endShift + lineWindow
        let shiftedOnset = line.start + offset
        return SearchWindow(
            start: max(rawStart, line.lowerBound),
            end: min(rawEnd, line.upperBound),
            readyAt: min(line.contextEnd + endShift + lineWindow, line.upperBound),
            earliestOnset: min(line.start, shiftedOnset),
            // Later anchors can widen the search on replay; an earlier match can establish a missed onset.
            latestOnset: coarseShift.map { line.start + $0 } ?? max(0, priorCount < 2 ? max(line.start, shiftedOnset) : shiftedOnset),
            rawStart: rawStart,
            rawEnd: rawEnd,
            wordOffset: coarseShift == nil ? offset : nil
        )
    }

    private func dropUnreliableLines(
        _ words: [RecognizedAudioWord],
        lines kept: ArraySlice<Int>,
        pinningRanges: [ClosedRange<Int>],
        isCoarseProbe: Bool
    ) -> Alignment {
        var accepted = Alignment()
        var offsets = lineOffsets
        var cursor = 0
        for (line, range) in zip(kept, pinningRanges) {
            let next = cursor + lines[line].words.count
            let lineWords = words[cursor..<next]
            cursor = next
            guard let first = lineWords.first, let last = lineWords.last else { continue }
            let end = last.startTime + last.duration
            let meanConfidence = lineWords.reduce(0) { $0 + $1.confidence } / Double(lineWords.count)
            // A CTC path can bridge silence without losing token confidence.
            guard meanConfidence >= 0.01,
                  end - first.startTime <= Self.maxLineSpan(wordCount: lineWords.count),
                  !lineWords.contains(where: { $0.duration > Self.maxWordSpan }),
                  !zip(lineWords, lineWords.dropFirst()).contains(where: { $1.startTime - $0.endTime > Self.maxWordSpan })
            else { continue }
            let squished = lineWords.count >= 4 && end - first.startTime < Double(lineWords.count) * 0.16
            if squished, meanConfidence < Self.lockConfidence { continue }
            let pinned = runFrame(atTrackTime: first.startTime) <= range.lowerBound + 1
                || runFrame(atTrackTime: end) >= range.upperBound
            if pinned, meanConfidence < Self.onsetLockConfidence { continue }
            // A few high-confidence words can lift the mean of a coarse match made mostly of guesses.
            if isCoarseProbe, lineWords.count > 1,
               lineWords.lazy.filter({ $0.confidence >= 0.10 }).count <= lineWords.count / 2 { continue }

            let offset = first.startTime - lines[line].start
            let supportsLock = meanConfidence >= Self.onsetLockConfidence
                && Self.hasAcousticSupport(in: lineWords.map(\.confidence))
            if supportsLock, meanConfidence >= Self.lockConfidence {
                accepted.confidentOffsets[line] = offset
                offsets[line] = offset
            } else {
                if offsets.count >= 4, abs(offset - offsetEstimate(before: line, using: offsets).offset) > maxOffsetDeviation {
                    continue
                }
                if supportsLock {
                    accepted.nearlyConfident.insert(line)
                }
            }
            accepted.words.append(contentsOf: lineWords)
            accepted.confidenceSum += meanConfidence
        }
        return accepted
    }

    static func hasAcousticSupport(in confidences: [Double]) -> Bool {
        guard confidences.count >= 4 else { return true }
        // Include the middle word in the prefix so it cannot mask a weak suffix.
        let middle = (confidences.count + 1) / 2
        let first = confidences[..<middle].reduce(0, +) / Double(middle)
        let second = confidences[middle...].reduce(0, +) / Double(confidences.count - middle)
        return min(first, second) >= 0.03
    }
}

/// The Core ML conversion of the MMS forced-aligner, run on the Neural Engine.
final class CoreMLAcousticModel: CTCAcousticModel, @unchecked Sendable {
    private let model: MLModel
    private let lock = NSLock()
    private let inputArray: MLMultiArray
    private let inputProvider: MLDictionaryFeatureProvider
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
        let sampleCount = input[1].intValue
        guard let reusableInput = try? MLMultiArray(shape: [1, NSNumber(value: sampleCount)], dataType: .float32),
              let reusableProvider = try? MLDictionaryFeatureProvider(dictionary: ["audio": reusableInput])
        else { return nil }
        self.model = model
        inputArray = reusableInput
        inputProvider = reusableProvider
        windowSampleCount = sampleCount
        frameCount = output[1].intValue
        vocabSize = output[2].intValue
    }

    func logProbabilities(window: [Float]) throws -> [Float] {
        lock.lock()
        defer { lock.unlock() }
        let destination = inputArray.dataPointer.bindMemory(to: Float.self, capacity: windowSampleCount)
        let copyCount = min(window.count, windowSampleCount)
        if copyCount > 0 {
            window.withUnsafeBufferPointer { source in
                if let base = source.baseAddress {
                    destination.update(from: base, count: copyCount)
                }
            }
        }
        if copyCount < windowSampleCount {
            destination.advanced(by: copyCount).initialize(repeating: 0, count: windowSampleCount - copyCount)
        }
        guard let output = try model.prediction(from: inputProvider).featureValue(for: "logprobs")?.multiArrayValue else {
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

typealias AcousticModelCache = CompiledModelCache<CTCAcousticModel>

/// Reuses loaded Core ML models across tracks and coalesces concurrent loads of the same model.
final class CompiledModelCache<Model>: @unchecked Sendable {
    private struct Key: Hashable {
        let url: URL
        let modificationDate: Date?
    }

    private final class PendingLoad {
        var model: Model?
        var finished = false
    }

    private let condition = NSCondition()
    private var inFlight: [Key: PendingLoad] = [:]
    private var generation = 0
    private var currentKey: Key?
    private var cached: Model?

    func load(
        compiledURL: URL,
        modificationDate: Date?,
        loader: (URL) -> Model?
    ) -> Model? {
        let key = Key(url: compiledURL.standardizedFileURL, modificationDate: modificationDate)
        condition.lock()
        defer { condition.unlock() }
        if currentKey != key {
            currentKey = key
            cached = nil
        }
        if let cached { return cached }
        if let pending = inFlight[key] {
            while !pending.finished {
                condition.wait()
            }
            return pending.model
        }

        let pending = PendingLoad()
        inFlight[key] = pending
        let loadGeneration = generation
        condition.unlock()
        let model = loader(key.url)
        condition.lock()

        if generation == loadGeneration {
            inFlight[key] = nil
            if currentKey == key { cached = model }
        }
        // Callers already waiting on this load receive its result even after invalidation.
        pending.model = model
        pending.finished = true
        condition.broadcast()
        return model
    }

    func invalidate() {
        condition.lock()
        generation += 1
        inFlight.removeAll()
        currentKey = nil
        cached = nil
        condition.unlock()
    }
}

/// Where the Core ML alignment model lives, and how a sync session loads it.
enum LyricsAlignerModel {
    static let packageName = "LyricsAligner.mlpackage"
    static let compiledName = "LyricsAligner.mlmodelc"
    private static let sharedModelCache = AcousticModelCache()
    // Keep first-use compilation from publishing an older model after a replacement.
    private static let modelFilesLock = NSLock()

    static func releaseCachedModel() {
        sharedModelCache.invalidate()
    }

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
        case rollbackFailed(installError: String, restoreError: String)

        var errorDescription: String? {
            switch self {
            case .checksumMismatch: "The downloaded model did not match its checksum."
            case let .httpStatus(code): "Download failed with HTTP \(code)."
            case .unpackFailed: "The downloaded model could not be unpacked."
            case .invalidURL: "The model download address is invalid."
            case let .rollbackFailed(installError, restoreError):
                "Model installation failed. \(installError) The previous model could not be fully restored. \(restoreError)"
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

    /// Verifies and unpacks a zipped Core ML package, optionally compiling it before replacing the installed artifacts.
    static func install(
        archive: URL,
        expectedSHA256: String,
        into directory: URL,
        packageName: String = packageName,
        compiledName: String = compiledName,
        fileManager: FileManager = .default,
        lock: NSLock = modelFilesLock,
        onInstalled: (() -> Void)? = nil,
        compile: ((URL, URL) throws -> Void)? = nil
    ) throws {
        guard try AppUpdateService.sha256Hex(ofFileAt: archive) == expectedSHA256.lowercased() else {
            throw InstallError.checksumMismatch
        }
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
        let stagedCompiled = staging.appendingPathComponent(compiledName)
        try compile?(unpacked, stagedCompiled)
        try lock.withLock {
            let package = directory.appendingPathComponent(packageName)
            let compiled = directory.appendingPathComponent(compiledName)
            let backupPrefix = ".backup-\(UUID().uuidString)-"
            var backups: [(original: URL, backup: URL)] = []
            var installed: [URL] = []
            do {
                for original in [package, compiled] {
                    let backup = directory.appendingPathComponent(backupPrefix + original.lastPathComponent)
                    do {
                        try fileManager.moveItem(at: original, to: backup)
                        backups.append((original, backup))
                    } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                        continue
                    }
                }
                var artifacts = [(unpacked, package)]
                if compile != nil { artifacts.append((stagedCompiled, compiled)) }
                for (source, destination) in artifacts {
                    try fileManager.moveItem(at: source, to: destination)
                    installed.append(destination)
                }
            } catch {
                let installError = error
                var restoreError: Error?
                for artifact in installed.reversed() {
                    do {
                        try fileManager.removeItem(at: artifact)
                    } catch {
                        restoreError = restoreError ?? error
                    }
                }
                for (original, backup) in backups.reversed() {
                    do {
                        try fileManager.moveItem(at: backup, to: original)
                    } catch {
                        restoreError = restoreError ?? error
                    }
                }
                if let restoreError {
                    throw InstallError.rollbackFailed(
                        installError: installError.localizedDescription,
                        restoreError: restoreError.localizedDescription
                    )
                }
                throw installError
            }
            for (_, backup) in backups {
                try? fileManager.removeItem(at: backup)
            }
            if compiledName == Self.compiledName { releaseCachedModel() }
            onInstalled?()
        }
    }

    static func isInstalled(in directory: URL = directory) -> Bool {
        let fileManager = FileManager.default
        return fileManager.fileExists(atPath: directory.appendingPathComponent(compiledName).path)
            || fileManager.fileExists(atPath: directory.appendingPathComponent(packageName).path)
    }

    /// Returns an aligner for `lines`, compiling an installed `.mlpackage` once and reusing the loaded
    /// `CoreMLAcousticModel` across tracks until released; nil when the model is missing, fails to load,
    /// or the Mac has no Neural Engine (the model's CPU path returns NaN).
    static func launch(
        lines: [LyricLine],
        anchors: [Int: ClosedRange<Double>] = [:],
        directory: URL = directory
    ) async -> AudioChunkTranscribing? {
        #if arch(arm64)
            return await Task.detached(priority: .utility) {
                modelFilesLock.withLock {
                    let compiled = directory.appendingPathComponent(compiledName)
                    let package = directory.appendingPathComponent(packageName)
                    let fileManager = FileManager.default
                    if !fileManager.fileExists(atPath: compiled.path), fileManager.fileExists(atPath: package.path) {
                        guard let temporary = try? MLModel.compileModel(at: package) else { return nil }
                        defer { try? fileManager.removeItem(at: temporary) }
                        guard (try? fileManager.moveItem(at: temporary, to: compiled)) != nil else { return nil }
                        releaseCachedModel()
                    }
                    let modDate = (try? fileManager.attributesOfItem(atPath: compiled.path))?[.modificationDate] as? Date
                    return sharedModelCache.load(compiledURL: compiled, modificationDate: modDate) {
                        CoreMLAcousticModel(compiledModelURL: $0)
                    }.map { LyricsForcedAligner(lines: lines, model: $0, anchors: anchors) }
                }
            }.value
        #else
            return nil
        #endif
    }
}
