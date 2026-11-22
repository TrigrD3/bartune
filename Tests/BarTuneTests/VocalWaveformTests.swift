@testable import BarTune
import XCTest

final class VocalWaveformTests: XCTestCase {
    private let sampleRate = 16000.0

    /// `seconds` of a 440 Hz tone, or silence when `amplitude` is 0.
    private func tone(_ seconds: Double, amplitude: Float = 0.5) -> [Float] {
        (0..<Int(seconds * sampleRate)).map { amplitude * sin(2 * .pi * 440 * Float($0) / Float(sampleRate)) }
    }

    private func envelope(_ parts: [(seconds: Double, amplitude: Float)], start: Double = 0) -> VocalEnvelope {
        var envelope = VocalEnvelope()
        let samples = parts.flatMap { tone($0.seconds, amplitude: $0.amplitude) }
        envelope.append(mid: samples, side: [], sampleRate: sampleRate, startTime: start, rate: 1)
        return envelope
    }

    private func word(_ start: Double, _ duration: Double) -> RecognizedAudioWord {
        RecognizedAudioWord(text: "la", startTime: start, duration: duration, confidence: 1)
    }

    private func level(_ envelope: VocalEnvelope, at time: Double) -> Float {
        let segment = envelope.segments[0]
        return segment.levels[segment.frame(at: time)]
    }

    // MARK: - Envelope

    func testEnvelopeIsLoudWhereTheVoiceBandSoundsAndQuietElsewhere() {
        let env = envelope([(1, 0), (1, 0.5)], start: 30)
        XCTAssertEqual(env.segments.count, 1)
        XCTAssertEqual(env.segments[0].start, 30)
        XCTAssertEqual(env.segments[0].levels.count, 200)
        XCTAssertLessThan(level(env, at: 30.5), -60)
        XCTAssertGreaterThan(level(env, at: 31.5), -20)
    }

    func testWidePannedSoundCancelsOutOfTheCentreLevel() {
        let left = tone(1)
        let right = [Float](repeating: 0, count: left.count)
        let split = AudioSampleExtractor.midSide(channels: [left, right])
        var wide = VocalEnvelope()
        wide.append(mid: split.mid, side: split.side, sampleRate: sampleRate, startTime: 0, rate: 1)
        let centred = AudioSampleExtractor.midSide(channels: [left, left])
        var centre = VocalEnvelope()
        centre.append(mid: centred.mid, side: centred.side, sampleRate: sampleRate, startTime: 0, rate: 1)

        // Wide sound is held 6 dB under its mid level rather than cancelled, so frame noise can't fake onsets.
        XCTAssertEqual(level(centre, at: 0.5) - level(wide, at: 0.5), 12, accuracy: 0.5)
    }

    func testContiguousAudioExtendsASegmentAndASeekStartsANewOne() {
        var env = VocalEnvelope()
        env.append(mid: tone(0.5), side: [], sampleRate: sampleRate, startTime: 10, rate: 1)
        env.append(mid: tone(0.5), side: [], sampleRate: sampleRate, startTime: 10.5, rate: 1)
        XCTAssertEqual(env.segments.count, 1)
        XCTAssertEqual(env.segments[0].levels.count, 100)

        env.append(mid: tone(0.5), side: [], sampleRate: sampleRate, startTime: 80, rate: 1)
        XCTAssertEqual(env.segments.count, 2)
        XCTAssertNotNil(env.segment(covering: 80.1...80.4))
        XCTAssertNil(env.segment(covering: 10.8...80.2))
    }

    func testPlaybackRateScalesFrameTimes() {
        var env = VocalEnvelope()
        env.append(mid: tone(1), side: [], sampleRate: sampleRate, startTime: 0, rate: 1.5)
        XCTAssertEqual(env.segments[0].end, 1.5, accuracy: 1e-9)
    }

    // MARK: - Refiner

    func testHeldNoteLengthensTheWordUntilItFades() {
        // Silence, then a note from 1.0 s to 2.5 s, then silence.
        let env = envelope([(1, 0), (1.5, 0.5), (1, 0)])
        let result = WaveformTimingRefiner.refine([word(1.0, 0.2)], envelope: env, onsetWindow: 0)
        XCTAssertEqual(result.words[0].endTime, 2.5, accuracy: 0.03)
        XCTAssertEqual(result.stats.extended, 1)
    }

    func testHeldNoteStopsShortOfTheNextWord() {
        let env = envelope([(1, 0), (1.5, 0.5), (1, 0)])
        let result = WaveformTimingRefiner.refine([word(1.0, 0.2), word(2.0, 0.3)], envelope: env, onsetWindow: 0)
        XCTAssertEqual(result.words[0].endTime, 2.0 - WaveformTimingRefiner.minimumGap, accuracy: 0.01)
    }

    func testWordStartSnapsOntoTheNearbyOnset() {
        let env = envelope([(1, 0), (0.55, 0.5), (1, 0)])
        let result = WaveformTimingRefiner.refine([word(1.05, 0.5)], envelope: env, onsetWindow: 0.06)
        XCTAssertEqual(result.words[0].startTime, 1.0, accuracy: 0.015)
        XCTAssertEqual(result.words[0].endTime, 1.55, accuracy: 1e-9, "Snapping a start keeps the word's end")
        XCTAssertEqual(result.stats.snapped, 1)
    }

    func testOnsetOutsideTheWindowIsIgnored() {
        let env = envelope([(1, 0), (1, 0.5)])
        let result = WaveformTimingRefiner.refine([word(1.2, 0.5)], envelope: env, onsetWindow: 0.06)
        XCTAssertEqual(result.words[0].startTime, 1.2)
        XCTAssertEqual(result.stats.snapped, 0)
    }

    func testWordHeardInSilenceIsDropped() {
        let env = envelope([(4, 0), (4, 0.5)])
        let result = WaveformTimingRefiner.refine([word(1.0, 0.3), word(5.0, 0.3)], envelope: env, onsetWindow: 0)
        XCTAssertEqual(result.words.map(\.startTime), [5.0])
        XCTAssertEqual(result.stats.dropped, 1)
    }

    func testEarlyWordJustBeforeTheVoiceIsKept() {
        // Recognized 0.15 s early: its whole span is in the gap before the voice at 5.0 s.
        let env = envelope([(5, 0), (3, 0.5)])
        let result = WaveformTimingRefiner.refine([word(4.85, 0.08)], envelope: env, onsetWindow: 0.15)
        XCTAssertEqual(result.words.count, 1)
        XCTAssertEqual(result.words[0].startTime, 5.0, accuracy: 0.015)
    }

    func testSongWithoutQuietPartsKeepsEveryWord() {
        // Steady sound throughout: no dynamic range, so nothing can be called silence.
        let env = envelope([(8, 0.2)])
        let result = WaveformTimingRefiner.refine([word(1.0, 0.3), word(5.0, 0.3)], envelope: env, onsetWindow: 0)
        XCTAssertEqual(result.words.count, 2)
    }

    func testWordsOutsideTheHeardAudioAreUnchanged() {
        let env = envelope([(1, 0), (1, 0.5)])
        let words = [word(40.0, 0.2)]
        XCTAssertEqual(WaveformTimingRefiner.refine(words, envelope: env, onsetWindow: 0.15).words, words)
    }

    func testRefiningTwiceChangesNothingMore() {
        let env = envelope([(1, 0), (1.5, 0.5), (1, 0)])
        let once = WaveformTimingRefiner.refine([word(1.04, 0.2)], envelope: env, onsetWindow: 0.06).words
        let twice = WaveformTimingRefiner.refine(once, envelope: env, onsetWindow: 0.06)
        XCTAssertEqual(twice.words, once)
    }
}
