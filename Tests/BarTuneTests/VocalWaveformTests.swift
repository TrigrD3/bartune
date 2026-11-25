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

    func testOnsetRiseIsLargeWhereTheVoiceStartsAndSmallInsideAHeldNote() throws {
        let env = envelope([(1.0, 0.005), (1.0, 0.5)])
        XCTAssertGreaterThan(try XCTUnwrap(env.onsetRise(at: 1.0)), 20)
        XCTAssertLessThan(try abs(XCTUnwrap(env.onsetRise(at: 1.6))), 1)
        XCTAssertNil(env.onsetRise(at: 0.2), "the audio before the start wasn't heard")
    }

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

    func testOneContinuousSegmentIsTrimmedToCapacity() {
        // 1 kHz keeps the test fast: 10 samples per frame, 1000 frames past capacity.
        var env = VocalEnvelope()
        let frames = VocalEnvelope.maxFrames + 1000
        env.append(mid: [Float](repeating: 0.1, count: frames * 10), side: [], sampleRate: 1000, startTime: 0, rate: 1)
        XCTAssertEqual(env.segments.count, 1)
        XCTAssertEqual(env.segments[0].levels.count, VocalEnvelope.maxFrames)
        XCTAssertEqual(env.segments[0].start, 10, accuracy: 1e-6)
        XCTAssertEqual(env.segments[0].end, Double(frames) * 0.01, accuracy: 1e-6)
        XCTAssertEqual(env.totalFrameCount, env.segments.reduce(0) { $0 + $1.levels.count })

        env.append(mid: [Float](repeating: 0.1, count: 1000), side: [], sampleRate: 1000, startTime: 2000, rate: 1)
        XCTAssertEqual(env.segments.count, 1)
        XCTAssertEqual(env.segments[0].levels.count, 100)
        XCTAssertEqual(env.totalFrameCount, env.segments.reduce(0) { $0 + $1.levels.count })
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
        let result = WaveformTimingRefiner.refine([word(1.0, 0.2)], envelope: env, timingError: 0)
        XCTAssertEqual(result.words[0].endTime, 2.5, accuracy: 0.03)
        XCTAssertEqual(result.stats.extended, 1)
    }

    func testHeldNoteSofterThanTheWordsLoudestSyllableIsStillHeld() {
        // "kem" is loud (1.0-1.2 s); the held "li" is 10.5 dB softer and lasts until 2.5 s.
        let env = envelope([(1, 0), (0.2, 0.5), (1.3, 0.15), (1, 0)])
        let result = WaveformTimingRefiner.refine([word(1.0, 0.3)], envelope: env, timingError: 0)
        XCTAssertEqual(result.words[0].endTime, 2.5, accuracy: 0.05)
    }

    func testHeldNoteKeepsTheWordsSyllables() {
        let env = envelope([(1, 0), (1.5, 0.5), (1, 0)])
        var held = word(1.0, 0.2)
        held.syllables = [.init(text: "a", startTime: 1.0), .init(text: "way", startTime: 1.1)]
        let result = WaveformTimingRefiner.refine([held], envelope: env, timingError: 0)
        XCTAssertEqual(result.stats.extended, 1)
        XCTAssertEqual(result.words[0].syllables, held.syllables)
    }

    func testHeldNoteStopsShortOfTheNextWord() {
        let env = envelope([(1, 0), (1.5, 0.5), (1, 0)])
        let result = WaveformTimingRefiner.refine([word(1.0, 0.2), word(2.0, 0.3)], envelope: env, timingError: 0)
        XCTAssertEqual(result.words[0].endTime, 2.0 - WaveformTimingRefiner.minimumGap, accuracy: 0.01)
    }

    func testWordInDigitalSilenceIsNotExtended() {
        // All-zero audio has no dynamic range, so the silence gate is off; nothing may be held either.
        let env = envelope([(8, 0)])
        let result = WaveformTimingRefiner.refine([word(1.0, 0.2)], envelope: env, timingError: 0)
        XCTAssertEqual(result.words[0].endTime, 1.2, accuracy: 1e-9)
        XCTAssertEqual(result.stats.extended, 0)
    }

    func testWordStartsAreLeftAlone() {
        let env = envelope([(1, 0), (1, 0.5)])
        let result = WaveformTimingRefiner.refine([word(1.05, 0.2)], envelope: env, timingError: 0.06)
        XCTAssertEqual(result.words[0].startTime, 1.05)
    }

    func testWordHeardInSilenceIsDropped() {
        let env = envelope([(4, 0), (4, 0.5)])
        let result = WaveformTimingRefiner.refine([word(1.0, 0.3), word(5.0, 0.3)], envelope: env, timingError: 0)
        XCTAssertEqual(result.words.map(\.startTime), [5.0])
        XCTAssertEqual(result.stats.dropped, 1)
    }

    func testEarlyWordJustBeforeTheVoiceIsKept() {
        // Recognized 0.15 s early: its whole span is in the gap before the voice at 5.0 s.
        let env = envelope([(5, 0), (3, 0.5)])
        let result = WaveformTimingRefiner.refine([word(4.85, 0.08)], envelope: env, timingError: 0.15)
        XCTAssertEqual(result.words.count, 1)
    }

    func testSongWithoutQuietPartsKeepsEveryWord() {
        // Steady sound throughout: no dynamic range, so nothing can be called silence.
        let env = envelope([(8, 0.2)])
        let result = WaveformTimingRefiner.refine([word(1.0, 0.3), word(5.0, 0.3)], envelope: env, timingError: 0)
        XCTAssertEqual(result.words.count, 2)
    }

    func testWordsOutsideTheHeardAudioAreUnchanged() {
        let env = envelope([(1, 0), (1, 0.5)])
        let words = [word(40.0, 0.2)]
        XCTAssertEqual(WaveformTimingRefiner.refine(words, envelope: env, timingError: 0.15).words, words)
    }

    func testRefiningTwiceChangesNothingMore() {
        let env = envelope([(1, 0), (1.5, 0.5), (1, 0)])
        let once = WaveformTimingRefiner.refine([word(1.04, 0.2)], envelope: env, timingError: 0.06).words
        let twice = WaveformTimingRefiner.refine(once, envelope: env, timingError: 0.06)
        XCTAssertEqual(twice.words, once)
    }

    func testMergedForDisplayRetainsNonOverlappingCachedSegmentsWhenLiveResumes() throws {
        var cached = VocalEnvelope()
        cached.append(mid: tone(10.0, amplitude: 0.4), side: [], sampleRate: sampleRate, startTime: 0.0, rate: 1)

        var live = VocalEnvelope()
        live.append(mid: tone(1.0, amplitude: 0.6), side: [], sampleRate: sampleRate, startTime: 4.0, rate: 1)

        let merged = try XCTUnwrap(VocalEnvelope.mergedForDisplay(cached: cached, live: live))
        XCTAssertEqual(merged.segments.count, 3)
        guard merged.segments.count == 3 else { return }
        XCTAssertEqual(merged.segments[0].start, 0.0, accuracy: 0.001)
        XCTAssertEqual(merged.segments[0].end, 4.0, accuracy: 0.02)
        XCTAssertEqual(merged.segments[1].start, 4.0, accuracy: 0.001)
        XCTAssertEqual(merged.segments[1].end, 5.0, accuracy: 0.02)
        XCTAssertEqual(merged.segments[2].start, 5.0, accuracy: 0.02)
        XCTAssertEqual(merged.segments[2].end, 10.0, accuracy: 0.02)
        XCTAssertNotNil(merged.segment(covering: 0.5...3.5))
        XCTAssertNotNil(merged.segment(covering: 4.1...4.9))
        XCTAssertNotNil(merged.segment(covering: 5.5...9.5))
    }

    func testMergedForDisplayReplacesLiveOverlapsAndPreservesFreshIntroUnderCapacity() {
        // Live-to-live replay overlap: newer capture at 2..4 s replaces older live peaks at 2..4 s.
        var live = VocalEnvelope()
        live.append(mid: tone(6.0, amplitude: 0.2), side: [], sampleRate: sampleRate, startTime: 0.0, rate: 1)
        live.append(mid: tone(2.0, amplitude: 0.8), side: [], sampleRate: sampleRate, startTime: 2.0, rate: 1)

        let deduped = VocalEnvelope.mergedForDisplay(cached: nil, live: live)
        XCTAssertEqual(deduped?.segments.count, 3)
        // Ensure no two segments overlap in track time.
        if let segs = deduped?.segments {
            for idx in 0..<(segs.count - 1) {
                XCTAssertLessThanOrEqual(segs[idx].end, segs[idx + 1].start + 0.011)
            }
        }

        // Capacity eviction drops older cached segments first, never a freshly captured intro at 0..1 s.
        var cached = VocalEnvelope()
        cached.append(mid: tone(4.0, amplitude: 0.4), side: [], sampleRate: sampleRate, startTime: 10.0, rate: 1)
        var freshIntro = VocalEnvelope()
        freshIntro.append(mid: tone(1.0, amplitude: 0.6), side: [], sampleRate: sampleRate, startTime: 0.0, rate: 1)

        let capped = VocalEnvelope.mergedForDisplay(cached: cached, live: freshIntro, capacity: 250)
        XCTAssertNotNil(capped?.segment(covering: 0.1...0.9), "fresh live intro must survive capacity trimming")
        let totalFrames = capped?.segments.reduce(0) { $0 + $1.levels.count } ?? 0
        XCTAssertLessThanOrEqual(totalFrames, 250)

        // Partial excess eviction slices only the excess frames from the oldest segment instead of dropping it whole.
        var multiCached = VocalEnvelope()
        multiCached.append(mid: tone(3.0, amplitude: 0.4), side: [], sampleRate: sampleRate, startTime: 10.0, rate: 1) // 300 frames
        multiCached.append(mid: tone(1.0, amplitude: 0.4), side: [], sampleRate: sampleRate, startTime: 20.0, rate: 1) // 100 frames
        var tinyLive = VocalEnvelope()
        tinyLive.append(mid: tone(0.1, amplitude: 0.6), side: [], sampleRate: sampleRate, startTime: 30.0, rate: 1) // 10 frames
        let tightlyCapped = VocalEnvelope.mergedForDisplay(cached: multiCached, live: tinyLive, capacity: 400)
        let keptTotal = tightlyCapped?.segments.reduce(0) { $0 + $1.levels.count } ?? 0
        XCTAssertEqual(keptTotal, 400, "should slice only 10 excess frames instead of dropping the 300-frame segment")
        XCTAssertEqual(tightlyCapped?.segments.count, 3)

        // Capture order survives across consecutive cache merges: 50 s -> 0 s -> 10 s evicts 50 s, keeping [0 s, 10 s].
        var seg50 = VocalEnvelope()
        seg50.append(mid: tone(1.0, amplitude: 0.5), side: [], sampleRate: sampleRate, startTime: 50.0, rate: 1) // 100 frames
        var seg0 = VocalEnvelope()
        seg0.append(mid: tone(1.0, amplitude: 0.6), side: [], sampleRate: sampleRate, startTime: 0.0, rate: 1) // 100 frames
        var seg10 = VocalEnvelope()
        seg10.append(mid: tone(1.0, amplitude: 0.7), side: [], sampleRate: sampleRate, startTime: 10.0, rate: 1) // 100 frames
        let cachedAfterIntro = VocalEnvelope.mergedPreservingCaptureOrder(cached: seg50, live: seg0, capacity: 200)
        let displayAfterMid = VocalEnvelope.mergedForDisplay(cached: cachedAfterIntro, live: seg10, capacity: 200)
        XCTAssertEqual(displayAfterMid?.segments.map(\.start) ?? [], [0.0, 10.0])
    }

    func testSubtractingPreservesExactFractionalFrameBoundariesWithoutGap() throws {
        // Cached segment 10.00...10.50 (50 frames @ 0.01 s) with live segment 10.10...10.20 (10 frames).
        // (10.1 - 10.0) / 0.01 is 9.999999999999964 in IEEE-754; snapping near-integer boundaries keeps
        // all 10 left frames (10.00...10.10) and all 30 right frames (10.20...10.50) with zero gap.
        var cached = VocalEnvelope()
        cached.append(mid: tone(0.5, amplitude: 0.4), side: [], sampleRate: sampleRate, startTime: 10.0, rate: 1)
        var live = VocalEnvelope()
        live.append(mid: tone(0.1, amplitude: 0.7), side: [], sampleRate: sampleRate, startTime: 10.1, rate: 1)

        let merged = try XCTUnwrap(VocalEnvelope.mergedForDisplay(cached: cached, live: live))
        XCTAssertEqual(merged.segments.count, 3)
        guard merged.segments.count == 3 else { return }
        let segs = merged.segments
        XCTAssertEqual(segs[0].start, 10.0, accuracy: 0.0001)
        XCTAssertEqual(segs[0].levels.count, 10)
        XCTAssertEqual(segs[0].end, 10.1, accuracy: 0.0001)
        XCTAssertEqual(segs[1].start, 10.1, accuracy: 0.0001)
        XCTAssertEqual(segs[1].levels.count, 10)
        XCTAssertEqual(segs[1].end, 10.2, accuracy: 0.0001)
        XCTAssertEqual(segs[2].start, 10.2, accuracy: 0.0001)
        XCTAssertEqual(segs[2].levels.count, 30)
        XCTAssertEqual(segs[2].end, 10.5, accuracy: 0.0001)
        XCTAssertEqual(merged.totalFrameCount, 50)
    }

    func testTotalFrameCountTracksAppendsAndCapacityTrims() {
        var envelope = VocalEnvelope()
        XCTAssertEqual(envelope.totalFrameCount, 0)
        envelope.append(mid: tone(0.5, amplitude: 0.4), side: [], sampleRate: sampleRate, startTime: 0.0, rate: 1)
        XCTAssertEqual(envelope.totalFrameCount, 50)
        envelope.append(mid: tone(0.25, amplitude: 0.5), side: [], sampleRate: sampleRate, startTime: 5.0, rate: 1)
        XCTAssertEqual(envelope.totalFrameCount, 75)
        XCTAssertEqual(envelope.totalFrameCount, envelope.segments.reduce(0) { $0 + $1.levels.count })
    }
}
