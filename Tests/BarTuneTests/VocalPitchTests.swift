@testable import BarTune
import XCTest

final class VocalPitchTests: XCTestCase {
    private let sampleRate = 16000

    func testEstimatesVocalPitchesWithHighClarity() throws {
        for frequency: Float in [80, 220, 440, 1000] {
            let samples = tone(frequency, seconds: 1, harmonics: frequency == 220)
            let segment = try XCTUnwrap(VocalPitchContour.analyze(mid: samples, start: 12, rate: 1.5))
            XCTAssertEqual(segment.start, 12)
            XCTAssertEqual(segment.step, 0.015, accuracy: 1e-9)
            XCTAssertEqual(segment.f0Hz.count, 100)
            for frame in 10..<90 {
                XCTAssertEqual(segment.f0Hz[frame], frequency, accuracy: frequency * 0.01)
                XCTAssertGreaterThan(segment.harmonicity[frame], 0.7)
            }
        }
    }

    func testNoiseImpulseAndOutOfRangeOrWidePannedTonesHaveLowClarity() throws {
        var impulse = [Float](repeating: 0, count: sampleRate)
        impulse[sampleRate / 2] = 1
        let wideTone = tone(220, seconds: 1)
        for (mid, side) in [(noise(seconds: 1), []), (impulse, []), (tone(65, seconds: 1), []), (wideTone, wideTone)] {
            let segment = try XCTUnwrap(VocalPitchContour.analyze(mid: mid, side: side, start: 0, rate: 1))
            XCTAssertLessThan(segment.harmonicity.max() ?? 1, 0.25)
            XCTAssertTrue(segment.f0Hz.allSatisfy { $0 == 0 })
        }
    }

    func testMergesContiguousChunksAndKeepsGapsAndNewerOverlaps() throws {
        var contour = VocalPitchContour()
        contour.merge(segment(start: 5, count: 50, clarity: 0))
        contour.merge(segment(start: 5.52, count: 50, clarity: 0.9))
        contour.merge(segment(start: 8, count: 50, clarity: 0))
        let merged = try XCTUnwrap(contour.segment(covering: 5.4...5.7))
        XCTAssertEqual(merged.harmonicity.count, 100)
        XCTAssertFalse(contour.isSeparatedVocals(from: 5.4, to: 5.7))
        XCTAssertNil(contour.segment(covering: 5.9...8.1))
        XCTAssertNil(contour.harmonicityRise(at: 8.1))
        XCTAssertEqual(try XCTUnwrap(contour.harmonicityRise(at: 5.5)), 0.9, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(contour.meanHarmonicity(from: 5.3, to: 5.4)), 0, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(contour.maxHarmonicity(from: 5.49, to: 5.5)), 0.9, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(contour.voicedFraction), 1 / 3, accuracy: 0.001)

        contour.merge(segment(start: 5.5, count: 50, clarity: 0))
        XCTAssertEqual(contour.maxHarmonicity(from: 5.6, to: 5.8), 0)

        var mixed = VocalPitchContour()
        mixed.merge(segment(start: 0, count: 50, clarity: 0.1, fromSeparatedVocals: false))
        mixed.merge(segment(start: 0.5, count: 50, clarity: 0.1, fromSeparatedVocals: true))
        XCTAssertEqual(mixed.segments.count, 1)
        XCTAssertFalse(mixed.isSeparatedVocals(from: 0.1, to: 0.3))
        XCTAssertTrue(mixed.isSeparatedVocals(from: 0.6, to: 0.8))
        // A window straddling a fallback chunk boundary is still evaluated, as full mix.
        XCTAssertFalse(mixed.isSeparatedVocals(from: 0.4, to: 0.6))
        XCTAssertEqual(try XCTUnwrap(mixed.meanHarmonicity(from: 0.4, to: 0.6)), 0.1, accuracy: 0.001)
    }

    func testCapacityDropsOnlyOldestFrames() throws {
        var contour = VocalPitchContour()
        contour.merge(segment(start: 0, count: VocalPitchContour.maxFrames, clarity: 0.9))
        contour.merge(segment(start: 2000, count: 100, clarity: 0))
        XCTAssertEqual(contour.segments.map(\.f0Hz.count), [VocalPitchContour.maxFrames - 100, 100])
        XCTAssertNil(contour.segment(covering: 0...0.9))
        XCTAssertEqual(try XCTUnwrap(contour.segments.first).start, 1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(contour.voicedFraction), 1199 / 1200, accuracy: 1e-6)
    }

    func testRefinementStopsHeldVowelWhenLoudNoiseContinues() throws {
        let samples = tone(440, seconds: 1, harmonics: true) + noise(seconds: 1)
        var envelope = VocalEnvelope()
        envelope.append(mid: samples, side: [], sampleRate: Double(sampleRate), startTime: 5, rate: 1)
        var contour = VocalPitchContour()
        try contour.merge(XCTUnwrap(VocalPitchContour.analyze(mid: samples, start: 5, rate: 1)))
        let word = RecognizedAudioWord(text: "stay", startTime: 5.4, duration: 0.4, confidence: 0.9)
        let loudnessOnly = WaveformTimingRefiner.refine([word], envelope: envelope, timingError: 0.06)
        let refined = WaveformTimingRefiner.refine([word], envelope: envelope, pitchContour: contour, timingError: 0.06)
        XCTAssertGreaterThan(try XCTUnwrap(loudnessOnly.words.first).endTime, 6.3)
        XCTAssertEqual(try XCTUnwrap(refined.words.first).endTime, 6, accuracy: 0.035)
        XCTAssertEqual(refined.stats.harmonicityTrimmed, 1)
    }

    func testRefinementPreservesUnvoicedWordEndingBeforeLoudNoise() throws {
        let unvoicedSamples = noise(seconds: 2)
        let consonantSamples = sampleRate / 5
        let samples = tone(440, seconds: 1, harmonics: true)
            + unvoicedSamples.prefix(consonantSamples).map { $0 * 0.6 }
            + unvoicedSamples.dropFirst(consonantSamples)
        var envelope = VocalEnvelope()
        envelope.append(mid: samples, side: [], sampleRate: Double(sampleRate), startTime: 5, rate: 1)
        var contour = VocalPitchContour()
        contour.merge(segment(start: 5.4, count: 60, clarity: 0.9))
        contour.merge(segment(start: 6, count: 200, clarity: 0))
        let word = RecognizedAudioWord(text: "last", startTime: 5.4, duration: 0.8, confidence: 0.9)

        let loudnessOnly = WaveformTimingRefiner.refine([word], envelope: envelope, timingError: 0.06)
        let refined = WaveformTimingRefiner.refine([word], envelope: envelope, pitchContour: contour, timingError: 0.06)
        XCTAssertEqual(try XCTUnwrap(loudnessOnly.words.first).endTime, 7.7, accuracy: 0.02)
        XCTAssertEqual(try XCTUnwrap(refined.words.first).duration, 0.8, accuracy: 1e-6)
        XCTAssertEqual(refined.stats.extended, 0)
    }

    func testRefinementCapsAtPitchCoverageThenTrimsWhenNoiseArrives() throws {
        let samples = tone(440, seconds: 1, harmonics: true) + noise(seconds: 1)
        var envelope = VocalEnvelope()
        envelope.append(mid: samples, side: [], sampleRate: Double(sampleRate), startTime: 5, rate: 1)
        let word = RecognizedAudioWord(text: "stay", startTime: 5.4, duration: 0.4, confidence: 0.9)
        var contour = VocalPitchContour()
        contour.merge(segment(start: 5.5, count: 40, clarity: 0.9))

        let partial = WaveformTimingRefiner.refine([word], envelope: envelope, pitchContour: contour, timingError: 0.06)
        XCTAssertEqual(try XCTUnwrap(partial.words.first).endTime, 5.9, accuracy: 1e-6)
        XCTAssertEqual(partial.stats.extended, 1)

        contour.merge(segment(start: 5.9, count: 10, clarity: 0.9))
        contour.merge(segment(start: 6, count: 100, clarity: 0))
        let complete = WaveformTimingRefiner.refine([word], envelope: envelope, pitchContour: contour, timingError: 0.06)
        XCTAssertEqual(try XCTUnwrap(complete.words.first).endTime, 6, accuracy: 1e-6)
        XCTAssertEqual(complete.stats.harmonicityTrimmed, 1)
    }

    func testSilenceGateKeepsShortUnvoicedConsonantAtCaptureBoundary() {
        let quiet = noise(seconds: 4).map { $0 * 0.001 }
        var envelope = VocalEnvelope()
        envelope.append(mid: quiet + noise(seconds: 4), side: [], sampleRate: Double(sampleRate), startTime: 0, rate: 1)
        var contour = VocalPitchContour()
        contour.merge(segment(start: 0, count: 800, clarity: 0))
        let consonant = RecognizedAudioWord(text: "t", startTime: 0.05, duration: 0.08, confidence: 0.9)
        let falseWord = RecognizedAudioWord(text: "stay", startTime: 2.0, duration: 0.3, confidence: 0.9)
        let result = WaveformTimingRefiner.refine([consonant, falseWord], envelope: envelope, pitchContour: contour, timingError: 0.06)
        XCTAssertEqual(result.words.map(\.text), ["t"])
        XCTAssertEqual(result.stats.dropped, 1)
    }

    private func segment(start: Double, count: Int, clarity: Float, fromSeparatedVocals: Bool = false) -> VocalPitchContour.Segment {
        VocalPitchContour.Segment(
            start: start,
            step: 0.01,
            f0Hz: [Float](repeating: clarity > 0 ? 220 : 0, count: count),
            harmonicity: [Float](repeating: clarity, count: count),
            fromSeparatedVocals: fromSeparatedVocals
        )
    }

    private func tone(_ frequency: Float, seconds: Int, harmonics: Bool = false) -> [Float] {
        (0..<(seconds * sampleRate)).map { index in
            let phase = 2 * Float.pi * frequency * Float(index) / Float(sampleRate)
            return 0.22 * sin(phase) + (harmonics ? 0.11 * sin(2 * phase) + 0.05 * sin(3 * phase) : 0)
        }
    }

    private func noise(seconds: Int) -> [Float] {
        var seed: UInt32 = 1
        return (0..<(seconds * sampleRate)).map { _ in
            seed = 1_664_525 &* seed &+ 1_013_904_223
            return Float(seed >> 8) / Float(1 << 24) * 2 - 1
        }
    }
}
