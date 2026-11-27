@testable import BarTune
import Foundation
import XCTest

final class AudioChromaTests: XCTestCase {
    func testChordProfilesDistinguishMajorAndMinorHarmonies() throws {
        let cMajor = try chordFrames([261.63, 329.63, 392.00]) // C E G
        let dMajor = try chordFrames([293.66, 369.99, 440.00]) // D F# A
        let aMinor = try chordFrames([220.00, 261.63, 329.63]) // A C E

        let same = AudioChromaProfile.cosineSimilarity(template: cMajor, target: cMajor, lagFrames: 0)
        let different = AudioChromaProfile.cosineSimilarity(template: cMajor, target: dMajor, lagFrames: 0)
        let sharedNotes = AudioChromaProfile.cosineSimilarity(template: cMajor, target: aMinor, lagFrames: 0)
        XCTAssertGreaterThan(same, 0.95)
        XCTAssertGreaterThan(sharedNotes, different + 0.1)
    }

    func testBestMatchFindsRepeatedAudioChordProgressionWithinHalfFrame() throws {
        var profile = AudioChromaProfile()
        profile.append(samples: ChromaTestAudio.repeatedPhrase(secondStart: 20.07), sampleRate: ChromaTestAudio.sampleRate, startTime: 0)
        let phrase = try XCTUnwrap(profile.slice(from: 10, to: 12)).frames
        let target = try XCTUnwrap(profile.slice(from: 18, to: 23)).frames

        let match = try XCTUnwrap(AudioChromaProfile.bestMatch(
            template: phrase,
            in: target,
            expectedLagFrames: 44,
            maxLagDeltaFrames: 8
        ))
        XCTAssertEqual(match.lagFrames * 0.05, 2.07, accuracy: 0.025)
        XCTAssertGreaterThan(match.similarity, 0.85)
    }

    func testUnrelatedAudioProgressionHasLowSimilarity() throws {
        var profile = AudioChromaProfile()
        profile.append(samples: ChromaTestAudio.repeatedPhrase(transposeSecondBy: 6), sampleRate: ChromaTestAudio.sampleRate, startTime: 0)
        let source = try XCTUnwrap(profile.slice(from: 10.1, to: 11.9)).frames
        let unrelated = try XCTUnwrap(profile.slice(from: 20.1, to: 21.9)).frames
        let score = AudioChromaProfile.cosineSimilarity(template: source, target: unrelated, lagFrames: 0)
        XCTAssertLessThan(score, 0.6)
    }

    func testMixedSampleRateChunksShareTrackGridButGapBreaksSlice() throws {
        var profile = AudioChromaProfile()
        profile.append(samples: tone(440, count: 16000, rate: 16000), sampleRate: 16000, startTime: 0)
        profile.append(samples: tone(440, count: 8000, rate: 8000), sampleRate: 8000, startTime: 1)
        let joined = try XCTUnwrap(profile.slice(from: 0.5, to: 1.5))
        XCTAssertEqual(joined.startTime, 0.5, accuracy: 1e-9)
        XCTAssertEqual(joined.frames.count / 12, 20)

        profile.append(samples: tone(440, count: 8000, rate: 8000), sampleRate: 8000, startTime: 2.2, rate: 2)
        XCTAssertNil(profile.slice(from: 1.8, to: 2.4), "a 200 ms capture gap cannot be matched as continuous audio")
        XCTAssertEqual(profile.slice(from: 2.2, to: 4.2)?.frames.count, 40 * 12)
    }

    func testMergePreservesBothStoredSegmentsAndFillsOnlyTheGap() throws {
        var stored = AudioChromaProfile()
        stored.append(samples: tone(440, count: 8000, rate: 8000), sampleRate: 8000, startTime: 0)
        stored.append(samples: tone(523.25, count: 8000, rate: 8000), sampleRate: 8000, startTime: 2)
        let first = try XCTUnwrap(stored.slice(from: 0, to: 1)).frames
        let last = try XCTUnwrap(stored.slice(from: 2, to: 3)).frames

        var incoming = AudioChromaProfile()
        incoming.append(samples: tone(659.25, count: 16000, rate: 8000), sampleRate: 8000, startTime: 0.5)
        let gap = try XCTUnwrap(incoming.slice(from: 1, to: 2)).frames

        stored.merge(incoming)

        XCTAssertEqual(stored.segments.count, 1)
        XCTAssertEqual(try XCTUnwrap(stored.slice(from: 0, to: 1)).frames, first)
        XCTAssertEqual(try XCTUnwrap(stored.slice(from: 1, to: 2)).frames, gap)
        XCTAssertEqual(try XCTUnwrap(stored.slice(from: 2, to: 3)).frames, last)
    }

    func testDroneHasNoDistinctiveMatchMargin() throws {
        let drone = try chordFrames([261.63, 329.63, 392.0])
        let match = try XCTUnwrap(AudioChromaProfile.bestMatch(
            template: drone,
            in: drone + drone + drone,
            expectedLagFrames: 20,
            maxLagDeltaFrames: 4
        ))
        XCTAssertLessThan(match.margin, 0.08)
    }

    func testTwoSeparatedIdenticalPeaksAreAmbiguous() {
        let locked = LyricLine(id: 0, timestamp: 10, text: "Beautiful day comes again", words: [
            WordTimestamp(timestamp: 10.1, duration: 0.5, text: "Beautiful "),
            WordTimestamp(timestamp: 10.6, duration: 0.5, text: "day "),
            WordTimestamp(timestamp: 11.1, duration: 0.5, text: "comes "),
            WordTimestamp(timestamp: 11.6, duration: 0.4, text: "again"),
        ])
        let lines = [locked, LyricLine(id: 1, timestamp: 20.5, text: locked.text)]
        let rate = ChromaTestAudio.sampleRate
        var audio = ChromaTestAudio.repeatedPhrase(secondStart: 18)
        let phrase = Array(audio[Int(18 * rate)..<Int(20 * rate)])
        audio.replaceSubrange(Int(22 * rate)..<Int(24 * rate), with: phrase)

        var continuous = AudioChromaProfile()
        continuous.append(samples: audio, sampleRate: rate, startTime: 0)
        var gapped = AudioChromaProfile()
        gapped.append(samples: Array(audio[..<Int(20.75 * rate)]), sampleRate: rate, startTime: 0)
        gapped.append(samples: Array(audio[Int(21.25 * rate)...]), sampleRate: rate, startTime: 21.25)

        for profile in [continuous, gapped] {
            let result = ChorusSelfSimilarity.recoverRepeatedLines(
                in: lines, lockedIDs: [0], chroma: profile, medianOffset: 0
            )
            XCTAssertTrue(result.recoveredLineIDs.isEmpty)
            XCTAssertEqual(result.lines, lines)
        }
    }

    func testRepeatedLineTransfersSyllableTimingWithoutCrossingNeighborAndSkipsTrivialLine() throws {
        let locked = LyricLine(id: 0, timestamp: 10, duration: 2, text: "Beautiful day comes again", words: [
            WordTimestamp(timestamp: 10.1, duration: 0.3, text: "Beau"),
            WordTimestamp(timestamp: 10.4, duration: 0.25, text: "ti"),
            WordTimestamp(timestamp: 10.65, duration: 0.35, text: "ful "),
            WordTimestamp(timestamp: 11.0, duration: 0.4, text: "day "),
            WordTimestamp(timestamp: 11.4, duration: 0.3, text: "comes "),
            WordTimestamp(timestamp: 11.7, duration: 0.3, text: "again"),
        ])
        let lines = [
            locked,
            LyricLine(id: 1, timestamp: 15, duration: 1, text: "Yeah", words: [
                WordTimestamp(timestamp: 15, duration: 1, text: "Yeah"),
            ]),
            LyricLine(id: 2, timestamp: 20.5, text: "beautiful day comes again!", words: [
                WordTimestamp(timestamp: 20.5, duration: 0.1, text: "beautiful day comes again!"),
            ]),
            LyricLine(id: 3, timestamp: 25, text: "Yeah"),
            LyricLine(id: 4, timestamp: 28, text: "Next distinct line"),
        ]
        var profile = AudioChromaProfile()
        profile.append(samples: ChromaTestAudio.repeatedPhrase(), sampleRate: ChromaTestAudio.sampleRate, startTime: 0)

        let result = ChorusSelfSimilarity.recoverRepeatedLines(
            in: lines, lockedIDs: [0, 1], chroma: profile, medianOffset: 0
        )
        XCTAssertEqual(result.recoveredLineIDs, [2])
        let recovered = try XCTUnwrap(result.lines.first { $0.id == 2 })
        XCTAssertEqual(recovered.timestamp, 20, accuracy: 0.025)
        XCTAssertEqual(recovered.words.map(\.text).joined(), recovered.text)
        XCTAssertEqual(recovered.words.first?.text, "beau")
        XCTAssertEqual(recovered.words.last?.text, "again!")
        for (source, copied) in zip(locked.words, recovered.words) {
            XCTAssertEqual(copied.timestamp - recovered.timestamp, source.timestamp - locked.timestamp, accuracy: 0.025)
            XCTAssertEqual(copied.duration, source.duration)
        }
        let lastWord = try XCTUnwrap(recovered.words.last)
        XCTAssertLessThan(lastWord.timestamp + (lastWord.duration ?? 0), 25)
        XCTAssertEqual(Array(result.lines.prefix(2)), Array(lines.prefix(2)))
        XCTAssertEqual(result.lines.first { $0.id == 3 }?.words, [], "a repeated short ad lib is not timing evidence")
    }

    func testRepeatIsRefusedWhenItWouldOverlapNextLockedLine() {
        let locked = LyricLine(id: 0, timestamp: 10, duration: 2, text: "Beautiful day comes again", words: [
            WordTimestamp(timestamp: 10.1, duration: 0.5, text: "Beautiful "),
            WordTimestamp(timestamp: 10.6, duration: 0.5, text: "day "),
            WordTimestamp(timestamp: 11.1, duration: 0.5, text: "comes "),
            WordTimestamp(timestamp: 11.6, duration: 0.4, text: "again"),
        ])
        let lines = [
            locked,
            LyricLine(id: 1, timestamp: 20.5, text: locked.text),
            LyricLine(id: 2, timestamp: 20.9, duration: 1, text: "Next locked line", words: [
                WordTimestamp(timestamp: 20.9, duration: 1, text: "Next locked line"),
            ]),
        ]
        var profile = AudioChromaProfile()
        profile.append(samples: ChromaTestAudio.repeatedPhrase(), sampleRate: ChromaTestAudio.sampleRate, startTime: 0)

        let result = ChorusSelfSimilarity.recoverRepeatedLines(
            in: lines, lockedIDs: [0, 2], chroma: profile, medianOffset: 0
        )
        XCTAssertFalse(result.recoveredLineIDs.contains(1))
        XCTAssertEqual(result.lines[1], lines[1])
    }

    func testRecoveredLineDoesNotOverlapNextUnlockedLyric() {
        let locked = LyricLine(id: 0, timestamp: 10, duration: 2, text: "Beautiful day comes again", words: [
            WordTimestamp(timestamp: 10.1, duration: 0.5, text: "Beautiful "),
            WordTimestamp(timestamp: 10.6, duration: 0.5, text: "day "),
            WordTimestamp(timestamp: 11.1, duration: 0.5, text: "comes "),
            WordTimestamp(timestamp: 11.6, duration: 0.4, text: "again"),
        ])
        let lines = [
            locked,
            LyricLine(id: 1, timestamp: 20.5, text: locked.text),
            LyricLine(id: 2, timestamp: 21, text: "Next distinct line"),
        ]
        var profile = AudioChromaProfile()
        profile.append(samples: ChromaTestAudio.repeatedPhrase(), sampleRate: ChromaTestAudio.sampleRate, startTime: 0)

        let result = ChorusSelfSimilarity.recoverRepeatedLines(
            in: lines, lockedIDs: [0], chroma: profile, medianOffset: 0
        )
        XCTAssertFalse(result.recoveredLineIDs.contains(1))
        XCTAssertEqual(result.lines[1], lines[1])
    }

    func testRecoveredLineDoesNotOverlapPreviousUnlockedWordTail() {
        let locked = LyricLine(id: 0, timestamp: 10, duration: 2, text: "Beautiful day comes again", words: [
            WordTimestamp(timestamp: 10.1, duration: 0.5, text: "Beautiful "),
            WordTimestamp(timestamp: 10.6, duration: 0.5, text: "day "),
            WordTimestamp(timestamp: 11.1, duration: 0.5, text: "comes "),
            WordTimestamp(timestamp: 11.6, duration: 0.4, text: "again"),
        ])
        let previous = LyricLine(id: 1, timestamp: 18.5, text: "Hold on", words: [
            WordTimestamp(timestamp: 18.5, duration: 0.5, text: "Hold "),
            WordTimestamp(timestamp: 19, duration: 3.2, text: "on"),
        ])
        let target = LyricLine(id: 2, timestamp: 22.5, text: locked.text)
        var profile = AudioChromaProfile()
        profile.append(samples: ChromaTestAudio.repeatedPhrase(), sampleRate: ChromaTestAudio.sampleRate, startTime: 0)

        let isolated = ChorusSelfSimilarity.recoverRepeatedLines(
            in: [locked, target], lockedIDs: [0], chroma: profile, medianOffset: 0
        )
        XCTAssertEqual(isolated.recoveredLineIDs, [2])
        XCTAssertEqual(isolated.lines[1].timestamp, 20, accuracy: 0.025)

        let lines = [locked, previous, target]
        let result = ChorusSelfSimilarity.recoverRepeatedLines(
            in: lines, lockedIDs: [0], chroma: profile, medianOffset: 0
        )
        XCTAssertTrue(result.recoveredLineIDs.isEmpty)
        XCTAssertEqual(result.lines, lines)
    }

    func testTwoLockedArrangementsWithSeparatedMatchesAreAmbiguous() {
        func lockedLine(id: Int, start: Double) -> LyricLine {
            LyricLine(id: id, timestamp: start, duration: 2, text: "Beautiful day comes again", words: [
                WordTimestamp(timestamp: start + 0.1, duration: 0.5, text: "Beautiful "),
                WordTimestamp(timestamp: start + 0.6, duration: 0.5, text: "day "),
                WordTimestamp(timestamp: start + 1.1, duration: 0.5, text: "comes "),
                WordTimestamp(timestamp: start + 1.6, duration: 0.4, text: "again"),
            ])
        }

        let firstTemplate = lockedLine(id: 0, start: 5)
        let secondTemplate = lockedLine(id: 1, start: 10)
        let target = LyricLine(id: 2, timestamp: 22, text: firstTemplate.text)
        let rate = ChromaTestAudio.sampleRate
        let fixture = ChromaTestAudio.repeatedPhrase(transposeSecondBy: 6)
        let firstArrangement = fixture[Int(10 * rate)..<Int(12 * rate)]
        let secondArrangement = fixture[Int(20 * rate)..<Int(22 * rate)]
        var audio = [Float](repeating: 0, count: fixture.count)
        for (start, arrangement) in [(5.0, firstArrangement), (10, secondArrangement), (20, firstArrangement), (24, secondArrangement)] {
            let first = Int(start * rate)
            audio.replaceSubrange(first..<(first + arrangement.count), with: arrangement)
        }
        var profile = AudioChromaProfile()
        profile.append(samples: audio, sampleRate: rate, startTime: 0)

        for (template, expectedStart) in [(firstTemplate, 20.0), (secondTemplate, 24.0)] {
            let isolated = ChorusSelfSimilarity.recoverRepeatedLines(
                in: [template, target], lockedIDs: [template.id], chroma: profile, medianOffset: 0
            )
            XCTAssertEqual(isolated.recoveredLineIDs, [2])
            XCTAssertEqual(isolated.lines[1].timestamp, expectedStart, accuracy: 0.025)
        }

        let lines = [firstTemplate, secondTemplate, target]
        let result = ChorusSelfSimilarity.recoverRepeatedLines(
            in: lines, lockedIDs: [0, 1], chroma: profile, medianOffset: 0
        )
        XCTAssertTrue(result.recoveredLineIDs.isEmpty)
        XCTAssertEqual(result.lines, lines)
    }

    func testLaterRecoveredLineDoesNotOverlapEarlierRecoveredWordTail() throws {
        let earlierTemplate = LyricLine(id: 1, timestamp: 10, text: "Beautiful day comes again", words: [
            WordTimestamp(timestamp: 10.1, duration: 0.5, text: "Beautiful "),
            WordTimestamp(timestamp: 10.6, duration: 0.5, text: "day "),
            WordTimestamp(timestamp: 11.1, duration: 0.5, text: "comes "),
            WordTimestamp(timestamp: 11.6, duration: 0.9, text: "again"),
        ])
        let laterTemplate = LyricLine(id: 0, timestamp: 5, text: "Another chorus comes around", words: [
            WordTimestamp(timestamp: 5.1, duration: 0.5, text: "Another "),
            WordTimestamp(timestamp: 5.6, duration: 0.5, text: "chorus "),
            WordTimestamp(timestamp: 6.1, duration: 0.5, text: "comes "),
            WordTimestamp(timestamp: 6.6, duration: 0.4, text: "around"),
        ])
        let lines = [
            laterTemplate,
            earlierTemplate,
            LyricLine(id: 2, timestamp: 20.5, text: earlierTemplate.text),
            LyricLine(id: 3, timestamp: 23, text: laterTemplate.text),
        ]
        let rate = ChromaTestAudio.sampleRate
        let fixture = ChromaTestAudio.repeatedPhrase(transposeSecondBy: 6)
        let earlier = fixture[Int(10 * rate)..<Int(12 * rate)]
        let later = fixture[Int(20 * rate)..<Int(22 * rate)]
        var audio = [Float](repeating: 0, count: fixture.count)
        for (start, phrase) in [(5.0, later), (10, earlier), (20, earlier), (22.4, later)] {
            let first = Int(start * rate)
            audio.replaceSubrange(first..<(first + phrase.count), with: phrase)
        }
        var profile = AudioChromaProfile()
        profile.append(samples: audio, sampleRate: rate, startTime: 0)

        let result = ChorusSelfSimilarity.recoverRepeatedLines(
            in: lines, lockedIDs: [0, 1], chroma: profile, medianOffset: 0
        )
        XCTAssertTrue(result.recoveredLineIDs.contains(2))
        let lastWord = try XCTUnwrap(result.lines[2].words.last)
        if result.recoveredLineIDs.contains(3) {
            XCTAssertGreaterThanOrEqual(result.lines[3].timestamp, lastWord.timestamp + (lastWord.duration ?? 0))
        }
    }

    func testCachedChromaTemplateRecoversRepeatedChorusWithoutRehearingFirstChorus() throws {
        let locked = LyricLine(id: 0, timestamp: 10, duration: 2, text: "Beautiful day comes again", words: [
            WordTimestamp(timestamp: 10.1, duration: 0.5, text: "Beautiful "),
            WordTimestamp(timestamp: 10.6, duration: 0.5, text: "day "),
            WordTimestamp(timestamp: 11.1, duration: 0.5, text: "comes "),
            WordTimestamp(timestamp: 11.6, duration: 0.4, text: "again"),
        ])
        let unique = LyricLine(id: 1, timestamp: 15, duration: 1, text: "Unique bridge line", words: [
            WordTimestamp(timestamp: 15.0, duration: 1.0, text: "Unique bridge line"),
        ])
        let target = LyricLine(id: 2, timestamp: 20.4, text: locked.text)
        let lines = [locked, unique, target]
        let rate = ChromaTestAudio.sampleRate
        let audio = ChromaTestAudio.repeatedPhrase(secondStart: 20.0)

        // Pass 1 hears only Chorus 1 (0...16 s) and extracts compact cached templates.
        var pass1Chroma = AudioChromaProfile()
        pass1Chroma.append(samples: Array(audio[..<Int(16 * rate)]), sampleRate: rate, startTime: 0)
        let templates = ChorusSelfSimilarity.extractCachedTemplates(in: lines, lockedIDs: [0, 1], chroma: pass1Chroma)
        XCTAssertEqual(templates.map(\.lineId), [0], "only locked lines with repeated text should be cached")

        // Round-trip through JSON Codable as AudioSyncedLyricsRecord does.
        let encoded = try JSONEncoder().encode(templates)
        let decoded = try JSONDecoder().decode([ChorusSelfSimilarity.CachedTemplate].self, from: encoded)
        XCTAssertEqual(decoded, templates)

        // Pass 2 only hears Chorus 2 (17...28 s): Chorus 1 is absent from live chroma,
        // but cached templates still recover Chorus 2 accurately.
        var pass2Chroma = AudioChromaProfile()
        pass2Chroma.append(samples: Array(audio[Int(17 * rate)..<Int(28 * rate)]), sampleRate: rate, startTime: 17)
        let withoutCache = ChorusSelfSimilarity.recoverRepeatedLines(
            in: lines, lockedIDs: [0, 1], chroma: pass2Chroma, medianOffset: 0
        )
        XCTAssertTrue(withoutCache.recoveredLineIDs.isEmpty)

        let withCache = ChorusSelfSimilarity.recoverRepeatedLines(
            in: lines, lockedIDs: [0, 1], chroma: pass2Chroma, cachedTemplates: decoded, medianOffset: 0
        )
        XCTAssertEqual(withCache.recoveredLineIDs, [2])
        XCTAssertEqual(withCache.lines[2].timestamp, 20.0, accuracy: 0.1)

        // Re-extracting templates on Pass 2 preserves Chorus 1's cached template even though Pass 2 didn't hear it.
        let preserved = ChorusSelfSimilarity.extractCachedTemplates(
            in: lines, lockedIDs: [0, 1], chroma: pass2Chroma, existing: decoded
        )
        XCTAssertEqual(preserved, decoded)
    }

    private func chordFrames(_ frequencies: [Double]) throws -> [Float] {
        let sampleRate = 8000.0
        let samples = (0..<24000).map { sample -> Float in
            let time = Double(sample) / sampleRate
            return Float(frequencies.reduce(0) { $0 + sin(2 * .pi * $1 * time) } / Double(frequencies.count))
        }
        var profile = AudioChromaProfile()
        profile.append(samples: samples, sampleRate: sampleRate, startTime: 0)
        return try XCTUnwrap(profile.slice(from: 1, to: 2)).frames
    }

    private func tone(_ frequency: Double, count: Int, rate: Double) -> [Float] {
        (0..<count).map { Float(sin(2 * .pi * frequency * Double($0) / rate)) }
    }
}

enum ChromaTestAudio {
    static let sampleRate = 8000.0

    static func repeatedPhrase(secondStart: Double = 20, transposeSecondBy semitones: Double = 0) -> [Float] {
        let rate = sampleRate
        let chords = [
            [261.63, 329.63, 392.0], [293.66, 369.99, 440.0],
            [220.0, 261.63, 329.63], [246.94, 311.13, 369.99],
        ]
        return (0..<Int(30 * rate)).map { sample in
            let time = Double(sample) / rate
            let isSecondPhrase = time >= secondStart && time < secondStart + 2
            let phraseTime = isSecondPhrase ? time - secondStart : time >= 10 && time < 12 ? time - 10 : -1
            if phraseTime < 0 {
                let adLibTime = time >= 25 && time < 26 ? time - 25 : time >= 15 && time < 16 ? time - 15 : -1
                guard adLibTime >= 0 else { return 0 }
                return Float(sin(2 * .pi * (adLibTime < 0.5 ? 440 : 523.25) * time))
            }
            let transpose = isSecondPhrase ? pow(2, semitones / 12) : 1
            let frequencies = chords[Int(phraseTime / 0.5)].map { $0 * transpose }
            return Float(frequencies.reduce(0) { $0 + sin(2 * .pi * $1 * phraseTime) } / Double(frequencies.count))
        }
    }
}
