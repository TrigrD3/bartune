@testable import BarTune
import XCTest

final class LyricsForcedAlignerTests: XCTestCase {
    private let vocabSize = 31
    private let ka = [14, 4] // "k", "a"

    /// Log-probs where each listed frame strongly favours one token and every other frame favours blank.
    private func emissions(frames: Int, peaks: [Int: Int]) -> [Float] {
        var values = [Float](repeating: -10, count: frames * vocabSize)
        for frame in 0..<frames {
            let token = peaks[frame] ?? CTCForcedAlignment.blank
            values[frame * vocabSize + token] = -0.01
        }
        return values
    }

    func testViterbiPlacesEachTokenOnItsPeakFrames() {
        let logProbs = emissions(frames: 20, peaks: [5: 14, 6: 14, 7: 4, 12: 14, 13: 4])
        let spans = CTCForcedAlignment.align(logProbs: logProbs, vocabSize: vocabSize, tokens: ka + ka)

        XCTAssertEqual(spans?.map(\.firstFrame), [5, 7, 12, 13])
        XCTAssertEqual(spans?.map(\.lastFrame), [6, 7, 12, 13])
    }

    func testViterbiSeparatesRepeatedTokensWithABlank() {
        // "aa" needs a blank between the two a's, so they land on frames 3 and 5.
        let logProbs = emissions(frames: 8, peaks: [3: 4, 5: 4])
        let spans = CTCForcedAlignment.align(logProbs: logProbs, vocabSize: vocabSize, tokens: [4, 4])
        XCTAssertEqual(spans?.map(\.firstFrame), [3, 5])
    }

    func testViterbiKeepsTokensInsideTheirAllowedFrames() {
        // The "ka" peak at frames 2-3 is outside the allowed range, so the later, weaker one wins.
        var logProbs = emissions(frames: 20, peaks: [2: 14, 3: 4])
        logProbs[14 * vocabSize + 14] = -2
        logProbs[15 * vocabSize + 4] = -2
        let spans = CTCForcedAlignment.align(
            logProbs: logProbs, vocabSize: vocabSize, tokens: ka, allowedFrames: [10...19, 10...19]
        )
        XCTAssertEqual(spans?.map(\.firstFrame), [14, 15])
    }

    func testViterbiReturnsNilWhenTokensCannotFit() {
        let logProbs = emissions(frames: 2, peaks: [:])
        XCTAssertNil(CTCForcedAlignment.align(logProbs: logProbs, vocabSize: vocabSize, tokens: [4, 4]))
        XCTAssertNil(CTCForcedAlignment.align(
            logProbs: emissions(frames: 10, peaks: [:]), vocabSize: vocabSize, tokens: ka, allowedFrames: [8...9, 0...1]
        ))
    }

    func testRomanizedWordsKeepLyricTokensAndDropUnreadableOnes() {
        let words = ForcedAlignmentText.words(for: "駄目駄目", script: .japanese)
        XCTAssertEqual(words.map(\.display).joined(), "駄目駄目")
        XCTAssertEqual(words.map(\.reading).joined(), "damedame")

        XCTAssertEqual(ForcedAlignmentText.words(for: "Darling, BABY!", script: .latin).map(\.reading), ["darling", "baby"])
        XCTAssertEqual(ForcedAlignmentText.words(for: "Darling, BABY!", script: .latin).map(\.display), ["Darling,", "BABY!"])
        XCTAssertTrue(ForcedAlignmentText.words(for: "♪ …", script: .latin).isEmpty)
    }

    func testEngineReturnsLyricWordsAtTheirAlignedTrackTimes() async throws {
        // 100 frames per 24 s window -> one frame every 0.24 s of audio.
        let model = FakeAcousticModel(windowSampleCount: 24 * 16000, frameCount: 100)
        let lines = [
            LyricLine(id: 0, timestamp: 12.0, text: "ka"),
            LyricLine(id: 1, timestamp: 16.0, text: "ka"),
        ]
        let aligner = LyricsForcedAligner(lines: lines, model: model, lineWindow: 3.0, holdBack: 2.0)
        // Chunks start at track 10 s; the window's newest 12 s map to frames 50-99 (track 10-22 s).
        // "ka" of line 0 peaks at track 13.12 s (frame 63), line 1 at 17.2 s (frame 80).
        model.peaksForCall = [[63: 14, 64: 4, 80: 14, 81: 4], [:]]

        // The first chunk commits track 10-20 s (the newest 2 s wait for right-hand context).
        let first = try await aligner.transcribe(chunk(start: 10.0))
        XCTAssertTrue(first.isEmpty, "line 0's window (9-19 s) is covered, but line 1's (13-24 s) is not")

        let second = try await aligner.transcribe(chunk(start: 22.0))
        XCTAssertEqual(second.map(\.text), ["ka", "ka"])
        XCTAssertEqual(second.map(\.sourceLineId), [0, 1])
        XCTAssertEqual(second.first?.startTime ?? 0, 13.12, accuracy: 0.01)
        XCTAssertEqual(second.last?.startTime ?? 0, 17.2, accuracy: 0.01)

        let third = try await aligner.transcribe(chunk(start: 34.0))
        XCTAssertTrue(third.isEmpty, "a line is aligned only once")
    }

    func testEngineWaitsForTheNextLineSoALineCannotStretchIntoIt() async throws {
        let model = FakeAcousticModel(windowSampleCount: 24 * 16000, frameCount: 100)
        let lines = [
            LyricLine(id: 0, timestamp: 11.0, text: "ka"),
            LyricLine(id: 1, timestamp: 13.0, text: "ka"),
            LyricLine(id: 2, timestamp: 40.0, text: "ka"),
        ]
        let aligner = LyricsForcedAligner(lines: lines, model: model, lineWindow: 3.0, holdBack: 2.0)
        // Line 0 sings "k" at 12.16 s and holds "a" until line 1's "ka" at 14.08 s.
        var peaks: [Int: Int] = [59: 14, 67: 14, 68: 4]
        for frame in 60...66 {
            peaks[frame] = 4
        }
        model.peaksForCall = [peaks, [:], [:]]

        // Committed audio ends at 20 s: line 0's window (8-16 s) is covered, line 1's (10-43 s) isn't.
        let first = try await aligner.transcribe(chunk(start: 10.0))
        XCTAssertTrue(first.isEmpty, "line 0 waits until line 1 can be aligned with it")

        _ = try await aligner.transcribe(chunk(start: 22.0))
        let third = try await aligner.transcribe(chunk(start: 34.0))
        XCTAssertEqual(third.map(\.text), ["ka"])
        XCTAssertEqual(third.first?.startTime ?? 0, 12.16, accuracy: 0.01)
        XCTAssertLessThanOrEqual(third.first.map { $0.startTime + $0.duration } ?? 99, 14.08 + 0.01)
    }

    /// Lines 0-3 and 5 are heard 0.1-0.6 s after their LRC time; line 4 (16.5 s) lands 1.9 s late.
    private func alignOffsetSong(line4Heard weakly: Bool) async throws -> (words: [RecognizedAudioWord], confident: Set<Int>) {
        let model = FakeAcousticModel(windowSampleCount: 24 * 16000, frameCount: 100)
        let lines = [10.5, 12.0, 13.5, 15.0, 16.5, 19.5].enumerated().map { LyricLine(id: $0, timestamp: $1, text: "ka") }
        let aligner = LyricsForcedAligner(lines: lines, model: model, lineWindow: 3.0, holdBack: 2.0)
        // First window: frame f is track -2 + 0.24 f. Second window: frame f is track 10 + 0.24 f.
        var first: [Int: Int] = [:]
        for frame in [54, 61, 67, 73, 85] {
            first[frame] = 14
            first[frame + 1] = 4
        }
        model.peaksForCall = [first, [42: 14, 43: 4]]
        if weakly { model.weakFrames = [85, 86] }

        var words = try await aligner.transcribe(chunk(start: 10.0))
        words += try await aligner.transcribe(chunk(start: 22.0))
        return (words, aligner.confidentLineIDs)
    }

    func testEngineDropsAnUnconfidentLineFarFromTheSongsOffsetSoItFallsBackToTheLRC() async throws {
        let (words, confident) = try await alignOffsetSong(line4Heard: true)

        XCTAssertEqual(words.count, 5)
        XCTAssertFalse(words.contains { abs($0.startTime - 18.4) < 0.5 }, "line 4 is 1.4 s off the 0.52 s median offset")
        XCTAssertEqual(words.last?.startTime ?? 0, 20.08, accuracy: 0.01)
        XCTAssertEqual(confident, [0, 1, 2, 3, 5])
    }

    func testEngineKeepsAConfidentLineFarFromTheSongsOffset() async throws {
        let (words, confident) = try await alignOffsetSong(line4Heard: false)

        XCTAssertEqual(words.first { abs($0.startTime - 18.4) < 0.01 }?.text, "ka", "a clearly heard line isn't judged by the others")
        XCTAssertEqual(confident, [0, 1, 2, 3, 4, 5])
    }

    func testEngineAlignsOnlyMissingLinesInsideTheGapTheirAlignedNeighboursLeave() async throws {
        let model = FakeAcousticModel(windowSampleCount: 24 * 16000, frameCount: 100)
        let lines = [12.0, 14.0, 16.0].enumerated().map { LyricLine(id: $0, timestamp: $1, text: "ka") }
        // Lines 0 and 2 were aligned on an earlier play: sung 12.16-12.8 s and 16.24-17.0 s.
        let aligner = LyricsForcedAligner(
            lines: lines, model: model, anchors: [0: 12.16...12.8, 2: 16.24...17.0], lineWindow: 3.0, holdBack: 2.0
        )
        // Frame f is track -2 + 0.24 f. Line 0's own "ka" at 12.4 s (frame 60) is the strongest match for
        // line 1's window; line 1 is really sung at 14.8 s (frames 70-71), heard more weakly.
        model.peaksForCall = [[60: 14, 61: 4, 70: 14, 71: 4]]
        model.weakFrames = [70, 71]

        let words = try await aligner.transcribe(chunk(start: 10.0))

        XCTAssertEqual(words.count, 1, "the aligned lines are not aligned again")
        XCTAssertEqual(words.first?.startTime ?? 0, 14.8, accuracy: 0.01)
    }

    func testEngineReportsTheLinesItHeardAndWhichOfThemItHeardClearly() async throws {
        let model = FakeAcousticModel(windowSampleCount: 24 * 16000, frameCount: 100)
        let lines = [12.0, 16.0, 21.0].enumerated().map { LyricLine(id: $0 + 10, timestamp: $1, text: "ka") }
        let aligner = LyricsForcedAligner(lines: lines, model: model, anchors: [12: 21.2...21.6], lineWindow: 3.0, holdBack: 2.0)
        // Line 10 is heard clearly at 13.12 s; line 11's "ka" at 17.2 s only weakly.
        model.peaksForCall = [[63: 14, 64: 4, 80: 14, 81: 4], [:]]
        model.weakFrames = [80, 81]

        var words = try await aligner.transcribe(chunk(start: 10.0))
        words += try await aligner.transcribe(chunk(start: 22.0))

        XCTAssertEqual(words.count, 2, "an unconfident line is still shown")
        XCTAssertEqual(aligner.confidentLineIDs, [10])
        XCTAssertEqual(aligner.nearlyConfidentLineIDs, [11], "a weakly heard line may still lock on a vocal onset")
        XCTAssertEqual(aligner.attemptedLineIDs, [10, 11], "the anchor isn't attempted")
    }

    func testFinalChunkAlignsTheLinesItsAudioEndsOn() async throws {
        let lines = [LyricLine(id: 0, timestamp: 12.0, text: "ka"), LyricLine(id: 1, timestamp: 20.0, text: "ka")]
        // Frame f is track -2 + 0.24 f: line 1's "ka" at 20.8 s is in the newest 2 s a whole chunk holds back.
        let peaks = [63: 14, 64: 4, 95: 14, 96: 4]

        let waiting = FakeAcousticModel(windowSampleCount: 24 * 16000, frameCount: 100)
        waiting.peaksForCall = [peaks]
        let midSong = try await LyricsForcedAligner(lines: lines, model: waiting, lineWindow: 3.0, holdBack: 2.0)
            .transcribe(chunk(start: 10.0))
        XCTAssertTrue(midSong.isEmpty, "more audio would follow, so line 1's window isn't covered yet")

        let model = FakeAcousticModel(windowSampleCount: 24 * 16000, frameCount: 100)
        model.peaksForCall = [peaks]
        let words = try await LyricsForcedAligner(lines: lines, model: model, lineWindow: 3.0, holdBack: 2.0)
            .transcribe(chunk(start: 10.0, isFinal: true))
        XCTAssertEqual(words.count, 2)
        XCTAssertEqual(words.last?.startTime ?? 0, 20.8, accuracy: 0.01)
    }

    func testLineSungBeforeCaptureOnAPlayFromTheStartAlignsAfterASeekBack() async throws {
        let model = FakeAcousticModel(windowSampleCount: 24 * 16000, frameCount: 100)
        let lines = [0.4, 2.0, 4.0, 40.0].enumerated().map { LyricLine(id: $0, timestamp: $1, text: "ka") }
        let aligner = LyricsForcedAligner(lines: lines, model: model, lineWindow: 3.0, holdBack: 2.0)
        // Seek back to 0: frame f is track -12 + 0.24 f, so "ka" at frames 53-54 is sung at 0.72 s.
        model.peaksForCall = [[:], [53: 14, 54: 4]]

        // Capture starts once the lyrics and model load, after line 0 is sung.
        let first = try await aligner.transcribe(chunk(start: 7.3))
        XCTAssertTrue(first.isEmpty)

        let words = try await aligner.transcribe(chunk(start: 0.0))
        XCTAssertEqual(words.first?.startTime ?? 0, 0.72, accuracy: 0.01)
    }

    func testEngineStartsOverAfterASeek() async throws {
        let model = FakeAcousticModel(windowSampleCount: 24 * 16000, frameCount: 100)
        let aligner = LyricsForcedAligner(
            lines: [LyricLine(id: 0, timestamp: 12.0, text: "ka"), LyricLine(id: 1, timestamp: 70.0, text: "ka")],
            model: model, lineWindow: 3.0, holdBack: 2.0
        )
        model.peaksForCall = [[:], [:]]
        _ = try await aligner.transcribe(chunk(start: 10.0))
        // A jump to 60 s: the earlier audio must not be stitched onto the new position.
        _ = try await aligner.transcribe(chunk(start: 60.0))

        let half = 12 * 16000
        XCTAssertEqual(model.windows.count, 2)
        XCTAssertEqual(Set(model.windows[1].prefix(half)).count, 1, "the new run's window is padded, not filled with pre-seek audio")
    }

    func testLatinWordsSplitAtTheirVowelGroups() {
        let cases: [String: [String]] = [
            "tonight": ["to", "night"],
            "away": ["a", "way"],
            "singing": ["sin", "ging"],
            "beautiful": ["beau", "ti", "ful"],
            "mother": ["mo", "ther"],
            "children": ["chil", "dren"],
            "picking": ["pick", "ing"],
            "little": ["lit", "tle"],
            "lyrics": ["ly", "rics"],
            "beyond": ["be", "yond"],
            "selamanya": ["se", "la", "ma", "nya"],
            "bernyanyi": ["ber", "nya", "nyi"],
            "Forever,": ["Fo", "re", "ver,"],
        ]
        for (word, syllables) in cases {
            XCTAssertEqual(LatinSyllabifier.split(word), syllables, word)
        }
    }

    func testNgBeforeAConsonantClosesTheSyllable() {
        XCTAssertEqual(LatinSyllabifier.split("memanggil"), ["me", "mang", "gil"])
        XCTAssertEqual(LatinSyllabifier.split("hungry"), ["hun", "gry"], "an onset pair still wins")
    }

    func testIndonesianRulesSoundEveryVowelAndKeepNgTogether() {
        let cases: [String: [String]] = [
            "Suara": ["Su", "a", "ra"],
            "dia": ["di", "a"],
            "biasa": ["bi", "a", "sa"],
            "kau": ["kau"],
            "pulau": ["pu", "lau"],
            "dengar": ["de", "ngar"],
            "ingin": ["i", "ngin"],
            "memanggil": ["me", "mang", "gil"],
            "bernyanyi": ["ber", "nya", "nyi"],
            "sate": ["sa", "te"],
            "saya": ["sa", "ya"],
        ]
        for (word, syllables) in cases {
            XCTAssertEqual(LatinSyllabifier.split(word, rules: .indonesian), syllables, word)
        }
        XCTAssertEqual(LatinSyllabifier.split("Suara"), ["Sua", "ra"], "standard rules keep a vowel run together")
    }

    func testIndonesianLyricsUseIndonesianRules() {
        let indonesian = ["Dan terjadi lagi", "Kisah lama yang terulang kembali", "Kau terluka lagi", "Dari cinta rumit yang kau jalani"]
        let english = ["And it happened again", "An old story that repeats itself", "You are hurt again"]
        XCTAssertEqual(LatinSyllabifier.Rules.detect(in: indonesian.enumerated().map { LyricLine(id: $0, timestamp: 0, text: $1) }), .indonesian)
        XCTAssertEqual(LatinSyllabifier.Rules.detect(in: english.enumerated().map { LyricLine(id: $0, timestamp: 0, text: $1) }), .standard)
    }

    func testSilentFinalEKeepsAWordWhole() {
        for word in ["love", "smile", "loved", "times", "the", "don't", "strong"] {
            XCTAssertEqual(LatinSyllabifier.split(word), [word], word)
        }
        XCTAssertEqual(LatinSyllabifier.split("wanted"), ["wan", "ted"], "-ted is sounded")
        XCTAssertEqual(LatinSyllabifier.split("roses"), ["ro", "ses"], "-ses is sounded")
    }

    func testSyllablesSpellTheWordsReadingInEachScript() {
        func syllables(_ text: String, _ script: ForcedAlignmentText.Script) -> [String] {
            ForcedAlignmentText.words(for: text, script: script).flatMap {
                ForcedAlignmentText.syllables(of: $0, script: script).map(\.display)
            }
        }
        XCTAssertEqual(syllables("사랑해", .korean), ["사", "랑", "해"])
        XCTAssertEqual(syllables("你好，", .chinese), ["你", "好，"])
        XCTAssertEqual(syllables("(tonight", .latin), ["(to", "night"], "punctuation rides with a syllable")
        XCTAssertTrue(syllables("大好き", .japanese).isEmpty, "a kanji's reading spans several morae")
        XCTAssertTrue(syllables("love", .latin).isEmpty, "one syllable needs no split")

        let word = ForcedAlignmentText.words(for: "beautiful", script: .latin)[0]
        let pieces = ForcedAlignmentText.syllables(of: word, script: .latin)
        XCTAssertEqual(pieces.map(\.letterCount), [4, 2, 3])
        XCTAssertEqual(pieces.map(\.letterCount).reduce(0, +), word.reading.count)
    }

    func testEngineStartsEachSyllableAtItsFirstAlignedLetter() async throws {
        let model = FakeAcousticModel(windowSampleCount: 24 * 16000, frameCount: 100)
        let aligner = LyricsForcedAligner(lines: [LyricLine(id: 0, timestamp: 12.0, text: "kaka")], model: model)
        // Frame f is track 10 + 0.24 (f - 50): "ka" at 13.12 s, then "ka" at 13.84 s.
        model.peaksForCall = [[63: 14, 64: 4, 66: 14, 67: 4]]

        let words = try await aligner.transcribe(chunk(start: 10.0))

        let syllables = try XCTUnwrap(words.first?.syllables)
        XCTAssertEqual(syllables.map(\.text), ["ka", "ka"])
        XCTAssertEqual(syllables[0].startTime, words[0].startTime)
        XCTAssertEqual(syllables[1].startTime, 13.84, accuracy: 0.01)
    }

    func testEngineSplitsIndonesianLyricsByIndonesianRules() async throws {
        let model = FakeAcousticModel(windowSampleCount: 24 * 16000, frameCount: 100)
        // Earlier lines (sung before this run's audio) only tell the aligner the song is Indonesian.
        let context = ["Dan terjadi lagi", "Kisah lama yang terulang kembali", "Kau terluka lagi", "Dari cinta rumit yang kau jalani"]
        let lines = context.enumerated().map { LyricLine(id: $0, timestamp: Double($0 + 1), text: $1) }
            + [LyricLine(id: 9, timestamp: 12.0, text: "dia")]
        let aligner = LyricsForcedAligner(lines: lines, model: model)
        // "d" "i" at 13.12 s, "a" at 13.84 s.
        model.peaksForCall = [[63: 16, 64: 5, 66: 4]]

        let words = try await aligner.transcribe(chunk(start: 10.0))

        XCTAssertEqual(words.map(\.text), ["dia"])
        XCTAssertEqual(words.first?.syllables?.map(\.text), ["di", "a"])
        XCTAssertEqual(words.first?.syllables?.last?.startTime ?? 0, 13.84, accuracy: 0.01)
    }

    func testEngineIgnoresAudioAtAnotherSampleRate() async throws {
        let model = FakeAcousticModel(windowSampleCount: 24 * 16000, frameCount: 100)
        let aligner = LyricsForcedAligner(lines: [LyricLine(id: 0, timestamp: 1, text: "ka")], model: model)
        let words = try await aligner.transcribe(AudioSyncManager.AudioChunkRequest(
            samples: [Float](repeating: 0.1, count: 48000), sampleRate: 48000, chunkStartTime: 0, playbackRate: 1
        ))
        XCTAssertTrue(words.isEmpty)
        XCTAssertTrue(model.windows.isEmpty)
    }

    func testAnchoredUpperBoundMakesLongDeclaredLineReadyAtAnchor() async throws {
        // Line 0 starts at 12.0 s with a 40 s declared duration (end 52.0 s), while line 1 is already
        // locked at 16.5...18.5 s. Committed audio through 20.08 s covers line 0's window ending at 16.5 s
        // instead of waiting for 55.0 s.
        let model = FakeAcousticModel(windowSampleCount: 24 * 16000, frameCount: 100)
        let lines = [
            LyricLine(id: 0, timestamp: 12.0, duration: 40.0, text: "ka"),
            LyricLine(id: 1, timestamp: 52.0, duration: 2.0, text: "ta"),
        ]
        let aligner = LyricsForcedAligner(
            lines: lines,
            model: model,
            anchors: [1: 16.5...18.5]
        )
        // Frame f is track -2 + 0.24 f, so the word starts at 13.12 s.
        model.peaksForCall = [[63: 14, 64: 4]]

        let words = try await aligner.transcribe(chunk(start: 10.0))
        XCTAssertEqual(words.map(\.text), ["ka"])
        XCTAssertEqual(words.first?.sourceLineId, 0)
        XCTAssertEqual(words.first?.startTime ?? 0, 13.12, accuracy: 0.01)
    }

    func testLongDeclaredLineUsesNextRowForReadinessAndSearchesBeyondIt() async throws {
        let model = FakeAcousticModel(windowSampleCount: 24 * 16000, frameCount: 100)
        let lines = [
            LyricLine(id: 0, timestamp: 12, duration: 40, text: "ka"),
            LyricLine(id: 1, timestamp: 16, text: "ka"),
            LyricLine(id: 2, timestamp: 24, text: "ka"),
        ]
        let aligner = LyricsForcedAligner(lines: lines, model: model)
        // Second window: frame f is track 6 + 0.24 f. The first "ka" is held past 16 + 3 s.
        model.peaksForCall = [[:], [52: 14, 53: 4, 54: 4, 55: 4, 56: 4, 57: 4, 58: 4, 64: 14, 65: 4]]
        let first = try await aligner.transcribe(chunk(start: 6))
        XCTAssertTrue(first.isEmpty)

        let words = try await aligner.transcribe(chunk(start: 18))
        XCTAssertEqual(words.map(\.sourceLineId), [0], "the second row provides context by 27 s")
        let word = try XCTUnwrap(words.first)
        XCTAssertEqual(word.startTime, 18.48, accuracy: 0.01)
        XCTAssertEqual(word.startTime + word.duration, 20.16, accuracy: 0.01)
    }

    func testAnchorWindowMissedOnSeekRemainsEligibleOnReplay() async throws {
        let model = FakeAcousticModel(windowSampleCount: 24 * 16000, frameCount: 100)
        let lines = [
            LyricLine(id: 7, timestamp: 17, text: "ka"),
            LyricLine(id: 8, timestamp: 22, text: "ta"),
        ]
        let aligner = LyricsForcedAligner(lines: lines, model: model, anchors: [8: 15...16])
        model.peaksForCall = [[:], [92: 14, 93: 4]]
        // The LRC start lies in the run, but the entire allowed 14...15 s interval precedes it.
        let missed = try await aligner.transcribe(chunk(start: 16))
        XCTAssertTrue(missed.isEmpty)
        XCTAssertTrue(aligner.attemptedLineIDs.isEmpty)

        // The replay ends at 16 s and covers the whole window before the 17 s LRC start.
        let words = try await aligner.transcribe(chunk(start: 4, isFinal: true))
        XCTAssertEqual(words.map(\.sourceLineId), [7])
        XCTAssertEqual(words.first?.startTime ?? 0, 14.08, accuracy: 0.01)
        XCTAssertEqual(aligner.attemptedLineIDs, [7])
    }

    func testSubFrameOverlapWithAnchorCappedWindowDoesNotMarkLineDone() async throws {
        let model = FakeAcousticModel(windowSampleCount: 24 * 16000, frameCount: 100)
        let lines = [
            LyricLine(id: 7, timestamp: 17, text: "ka"),
            LyricLine(id: 8, timestamp: 22, text: "ta"),
        ]
        let aligner = LyricsForcedAligner(lines: lines, model: model, anchors: [8: 15...16])
        model.peaksForCall = [[:], [92: 14, 93: 4]]
        // Overlap with the 14...15 s effective window is only 0.05 s (< 1 frame of 0.24 s);
        // align() cannot score a single frame so line 7 must remain eligible on replay.
        let missed = try await aligner.transcribe(chunk(start: 14.95))
        XCTAssertTrue(missed.isEmpty)
        XCTAssertTrue(aligner.attemptedLineIDs.isEmpty)

        let words = try await aligner.transcribe(chunk(start: 4, isFinal: true))
        XCTAssertEqual(words.map(\.sourceLineId), [7])
        XCTAssertEqual(aligner.attemptedLineIDs, [7])
    }

    func testConsecutiveLongDeclaredRowsWaitForCoveredContextBeforeCommitting() async throws {
        // Two consecutive long-duration rows (L0 at 12 s dur 40 s, L1 at 16 s dur 40 s) followed by
        // normal row L2 at 17 s (so L1 reaches readyAt = 17 + 3 = 20 s inside chunk 1's 20.08 s coverage,
        // exercising the batch-pruning loop while L1's own 59 s search window is still uncovered).
        let k = try XCTUnwrap(ForcedAlignmentText.vocabulary["k"])
        let a = try XCTUnwrap(ForcedAlignmentText.vocabulary["a"])
        let t = try XCTUnwrap(ForcedAlignmentText.vocabulary["t"])
        let n = try XCTUnwrap(ForcedAlignmentText.vocabulary["n"])
        let model = FakeAcousticModel(windowSampleCount: 24 * 16000, frameCount: 100)
        let lines = [
            LyricLine(id: 0, timestamp: 12, duration: 40, text: "ka"),
            LyricLine(id: 1, timestamp: 16, duration: 40, text: "ta"),
            LyricLine(id: 2, timestamp: 17, text: "na"),
        ]
        let aligner = LyricsForcedAligner(lines: lines, model: model)
        // Window 1 (start 10, frame f = -2 + 0.24 f, retained frames 50..91 -> 10.0..20.08 s):
        //   L0 "k" at frame 90 (19.60 s), "a" starts at frame 91 (19.84 s).
        // Window 2 (start 22, frame f = 10 + 0.24 f, retained frames 42..91 -> 20.08..32.08 s):
        //   L0 sustained "a" through frame 45 (20.80 s), L1 "ta" at frames 60..61 (24.40 s), L2 "na" at frames 70..71 (26.80 s).
        model.peaksForCall = [
            [90: k, 91: a],
            [42: a, 43: a, 44: a, 45: a, 60: t, 61: a, 70: n, 71: a],
        ]
        let first = try await aligner.transcribe(chunk(start: 10))
        XCTAssertTrue(first.isEmpty, "L0 must wait while ready context line L1 still has uncovered audio")
        XCTAssertTrue(aligner.attemptedLineIDs.isEmpty)

        let second = try await aligner.transcribe(chunk(start: 22))
        let l0Word = try XCTUnwrap(second.first { $0.sourceLineId == 0 })
        let l1Word = try XCTUnwrap(second.first { $0.sourceLineId == 1 })
        XCTAssertEqual(l0Word.startTime, 19.60, accuracy: 0.05)
        XCTAssertEqual(l1Word.startTime, 24.40, accuracy: 0.05)
    }

    func testLongLineNextToLaterAnchorWaitsUntilAnchorCapIsCovered() async throws {
        // L0 fetched at 12 s with 40 s duration; L1 fetched at 16 s is anchored at 23..25 s.
        // L0's readyAt is 19 s, but its anchor-capped windowEnd is 23 s. Chunk 1 (coveredEnd 20.08 s)
        // must not commit L0 early via done.contains(1); chunk 2 captures L0's onset at 21.52 s.
        let k = try XCTUnwrap(ForcedAlignmentText.vocabulary["k"])
        let a = try XCTUnwrap(ForcedAlignmentText.vocabulary["a"])
        let model = FakeAcousticModel(windowSampleCount: 24 * 16000, frameCount: 100)
        let lines = [
            LyricLine(id: 0, timestamp: 12, duration: 40, text: "ka"),
            LyricLine(id: 1, timestamp: 16, text: "ta"),
        ]
        let aligner = LyricsForcedAligner(lines: lines, model: model, anchors: [1: 23...25])
        // Window 2 (frame f = 10 + 0.24 f): frame 48 is 21.52 s.
        model.peaksForCall = [
            [:],
            [48: k, 49: a],
        ]

        let first = try await aligner.transcribe(chunk(start: 10))
        XCTAssertTrue(first.isEmpty, "must wait until anchor-capped windowEnd (23 s) is covered")
        XCTAssertTrue(aligner.attemptedLineIDs.isEmpty)

        let second = try await aligner.transcribe(chunk(start: 22))
        let word = try XCTUnwrap(second.first { $0.sourceLineId == 0 })
        XCTAssertEqual(word.startTime, 21.52, accuracy: 0.05)
    }

    func testModelInstallVerifiesTheArchiveAndReplacesAStaleCompiledModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("src/\(LyricsAlignerModel.packageName)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: source.appendingPathComponent("Manifest.json"))
        let archive = root.appendingPathComponent("model.zip")
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-c", "-k", "--keepParent", source.path, archive.path]
        try ditto.run()
        ditto.waitUntilExit()
        let digest = try AppUpdateService.sha256Hex(ofFileAt: archive)

        let models = root.appendingPathComponent("Models")
        let stale = models.appendingPathComponent(LyricsAlignerModel.compiledName)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true)

        XCTAssertThrowsError(try LyricsAlignerModel.install(archive: archive, expectedSHA256: String(repeating: "0", count: 64), into: models))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path), "a bad archive changes nothing")
        XCTAssertFalse(LyricsAlignerModel.isInstalled(in: models.appendingPathComponent("none")))

        try LyricsAlignerModel.install(archive: archive, expectedSHA256: digest, into: models)
        let installed = models.appendingPathComponent("\(LyricsAlignerModel.packageName)/Manifest.json")
        XCTAssertEqual(try String(contentsOf: installed, encoding: .utf8), "weights")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path), "the old compiled model must be rebuilt from the new package")
    }

    func testAcousticModelCacheReusesModelAcrossTracksAndInvalidatesOnChangeOrRelease() throws {
        let cache = AcousticModelCache()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LyricsAligner.mlmodelc")
        let t1 = Date(timeIntervalSince1970: 1_700_000_000)
        let t2 = Date(timeIntervalSince1970: 1_700_000_100)
        var loadCount = 0

        let first = try XCTUnwrap(cache.load(compiledURL: url, modificationDate: t1) { _ in
            loadCount += 1
            return FakeAcousticModel(windowSampleCount: 16000, frameCount: 50)
        })
        let second = try XCTUnwrap(cache.load(compiledURL: url, modificationDate: t1) { _ in
            loadCount += 1
            return FakeAcousticModel(windowSampleCount: 16000, frameCount: 50)
        })
        XCTAssertEqual(loadCount, 1, "same URL and modification date must reuse the cached acoustic model")
        XCTAssertIdentical(first, second)

        let reloadedAfterMod = try XCTUnwrap(cache.load(compiledURL: url, modificationDate: t2) { _ in
            loadCount += 1
            return FakeAcousticModel(windowSampleCount: 16000, frameCount: 50)
        })
        XCTAssertEqual(loadCount, 2, "a changed modification date must reload the acoustic model")
        XCTAssertNotIdentical(first, reloadedAfterMod)

        cache.invalidate()
        let reloadedAfterInvalidate = try XCTUnwrap(cache.load(compiledURL: url, modificationDate: t2) { _ in
            loadCount += 1
            return FakeAcousticModel(windowSampleCount: 16000, frameCount: 50)
        })
        XCTAssertEqual(loadCount, 3, "explicit invalidation must release and reload the cached model")
        XCTAssertNotIdentical(reloadedAfterMod, reloadedAfterInvalidate)
    }

    func testConcurrentAcousticModelLoadsShareTheBlockedLoader() {
        let cache = AcousticModelCache()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LyricsAligner.mlmodelc")
        let date = Date()
        let model = FakeAcousticModel(windowSampleCount: 16000, frameCount: 50)
        let firstStarted = expectation(description: "First loader started")
        let firstFinished = expectation(description: "First lookup returned")
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let first = cache.load(compiledURL: url, modificationDate: date) { _ in
                firstStarted.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return model
            }
            XCTAssertIdentical(first, model)
            firstFinished.fulfill()
        }
        wait(for: [firstStarted], timeout: 2)

        let secondStarted = expectation(description: "Concurrent lookup started")
        let secondFinished = expectation(description: "Concurrent lookup returned")
        let duplicateLoad = expectation(description: "Concurrent lookup invoked its loader")
        duplicateLoad.isInverted = true
        DispatchQueue.global().async {
            secondStarted.fulfill()
            let second = cache.load(compiledURL: url, modificationDate: date) { _ in
                duplicateLoad.fulfill()
                return FakeAcousticModel(windowSampleCount: 16000, frameCount: 50)
            }
            XCTAssertIdentical(second, model)
            secondFinished.fulfill()
        }
        wait(for: [secondStarted], timeout: 2)
        wait(for: [duplicateLoad], timeout: 0.1)
        release.signal()
        wait(for: [firstFinished, secondFinished], timeout: 2)
    }

    func testInvalidatingDuringAnAcousticModelLoadPreventsStalePublication() {
        let cache = AcousticModelCache()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LyricsAligner.mlmodelc")
        let date = Date()
        let started = expectation(description: "Loader started")
        let finished = expectation(description: "Invalidated load finished")
        let release = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = cache.load(compiledURL: url, modificationDate: date) { _ in
                started.fulfill()
                XCTAssertEqual(release.wait(timeout: .now() + 5), .success)
                return FakeAcousticModel(windowSampleCount: 16000, frameCount: 50)
            }
            finished.fulfill()
        }
        wait(for: [started], timeout: 2)
        cache.invalidate()
        release.signal()
        wait(for: [finished], timeout: 2)

        let replacement = FakeAcousticModel(windowSampleCount: 16000, frameCount: 50)
        XCTAssertIdentical(cache.load(compiledURL: url, modificationDate: date) { _ in replacement }, replacement)
    }

    func testFailedAcousticModelReloadEvictsThePreviousVersion() {
        let cache = AcousticModelCache()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LyricsAligner.mlmodelc")
        let date = Date()
        weak var previous: FakeAcousticModel?
        _ = cache.load(compiledURL: url, modificationDate: date) { _ in
            let model = FakeAcousticModel(windowSampleCount: 16000, frameCount: 50)
            previous = model
            return model
        }
        XCTAssertNotNil(previous)
        XCTAssertNil(cache.load(compiledURL: url, modificationDate: date.addingTimeInterval(1)) { _ in nil })
        XCTAssertNil(previous, "A failed reload must release the stale model")
    }

    private func chunk(start: Double, isFinal: Bool = false) -> AudioSyncManager.AudioChunkRequest {
        AudioSyncManager.AudioChunkRequest(
            samples: (0..<(12 * 16000)).map { Float($0 % 7 + 1) / 8 },
            sampleRate: 16000,
            chunkStartTime: start,
            playbackRate: 1,
            isFinal: isFinal
        )
    }
}

private final class FakeAcousticModel: CTCAcousticModel, @unchecked Sendable {
    let windowSampleCount: Int
    let frameCount: Int
    let vocabSize = 31
    /// Peak frames (frame -> token) per call, in call order; later calls get all-blank output.
    var peaksForCall: [[Int: Int]] = []
    /// Peak frames heard only weakly (log-prob -2 instead of -0.01).
    var weakFrames: Set<Int> = []
    private(set) var windows: [[Float]] = []

    init(windowSampleCount: Int, frameCount: Int) {
        self.windowSampleCount = windowSampleCount
        self.frameCount = frameCount
    }

    func logProbabilities(window: [Float]) -> [Float] {
        windows.append(window)
        let peaks = peaksForCall.isEmpty ? [:] : peaksForCall.removeFirst()
        var values = [Float](repeating: -10, count: frameCount * vocabSize)
        for frame in 0..<frameCount {
            values[frame * vocabSize + (peaks[frame] ?? CTCForcedAlignment.blank)] = weakFrames.contains(frame) ? -2 : -0.01
        }
        return values
    }
}
