import Foundation

/// Second-order band-pass made of a high-pass and a low-pass biquad (RBJ cookbook, Butterworth Q).
struct VoiceBandFilter {
    private struct Biquad {
        var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0
        var x1: Float = 0, x2: Float = 0, y1: Float = 0, y2: Float = 0

        static func make(highPass: Bool, cutoff: Double, sampleRate: Double) -> Biquad {
            let omega = 2 * Double.pi * min(cutoff, sampleRate * 0.45) / sampleRate
            let alpha = sin(omega) / (2 * 0.7071)
            let cosine = cos(omega)
            let a0 = 1 + alpha
            var filter = Biquad()
            if highPass {
                filter.b0 = Float((1 + cosine) / 2 / a0)
                filter.b1 = Float(-(1 + cosine) / a0)
            } else {
                filter.b0 = Float((1 - cosine) / 2 / a0)
                filter.b1 = Float((1 - cosine) / a0)
            }
            filter.b2 = filter.b0
            filter.a1 = Float(-2 * cosine / a0)
            filter.a2 = Float((1 - alpha) / a0)
            return filter
        }

        mutating func process(_ x: Float) -> Float {
            let y = b0 * x + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1
            x1 = x
            y2 = y1
            y1 = y
            return y
        }
    }

    private var highPass: Biquad
    private var lowPass: Biquad

    init(sampleRate: Double, low: Double = 250, high: Double = 3500) {
        highPass = .make(highPass: true, cutoff: low, sampleRate: sampleRate)
        lowPass = .make(highPass: false, cutoff: high, sampleRate: sampleRate)
    }

    mutating func process(_ x: Float) -> Float {
        lowPass.process(highPass.process(x))
    }
}

/// Voice-band loudness of the captured player audio over track time, in 10 ms frames.
///
/// With stereo input the level estimates the centre-panned part of the mix (mid energy minus side
/// energy), where lead vocals usually sit; instruments panned wide cancel out of it.
struct VocalEnvelope {
    struct Segment: Equatable {
        /// Track time of the first frame.
        var start: Double
        /// Track seconds per frame.
        let step: Double
        var levels: [Float]
        /// Raw linear min/max sample peaks (`-1...1`) per frame for timeline waveform display.
        var minPeaks: [Float] = []
        var maxPeaks: [Float] = []
        fileprivate var captureIndex = 0

        var end: Double { start + Double(levels.count) * step }

        func frame(at time: Double) -> Int {
            Int(((time - start) / step).rounded(.down))
        }
        func time(ofFrame frame: Int) -> Double {
            start + Double(frame) * step
        }
    }

    static let frameSeconds = 0.01
    /// About 20 minutes of frames; the oldest segments go first.
    static let maxFrames = 120_000

    private(set) var segments: [Segment] = []
    private(set) var totalFrameCount = 0
    private var midFilter = VoiceBandFilter(sampleRate: 16000)
    private var sideFilter = VoiceBandFilter(sampleRate: 16000)
    private var sampleRate = 0.0
    private var rate = 1.0
    private var expectedNextStart: Double?
    private var midEnergy: Float = 0
    private var sideEnergy: Float = 0
    private var frameMin: Float = 0
    private var frameMax: Float = 0
    private var pendingSamples = 0
    private var captureIndex = 0

    struct FrameLocation: Sendable {
        fileprivate let captureIndex: Int
        fileprivate let time: Double
    }

    /// Appends captured audio starting at `startTime` (track seconds); `side` is empty for mono audio.
    /// Audio that doesn't continue the last append (a seek, a gap, a rate change) starts a new segment.
    mutating func append(mid: [Float], side: [Float], sampleRate: Double, startTime: Double, rate: Double, startsNewSpan: Bool = false) {
        guard sampleRate > 0, rate > 0, !mid.isEmpty else { return }
        let contiguous = expectedNextStart.map { abs($0 - startTime) <= 0.05 } ?? false
        if startsNewSpan || !contiguous || sampleRate != self.sampleRate || abs(rate - self.rate) > 0.001 {
            self.sampleRate = sampleRate
            self.rate = rate
            midFilter = VoiceBandFilter(sampleRate: sampleRate)
            sideFilter = VoiceBandFilter(sampleRate: sampleRate)
            midEnergy = 0
            sideEnergy = 0
            frameMin = 0
            frameMax = 0
            pendingSamples = 0
            captureIndex += 1
            segments.append(Segment(start: startTime, step: samplesPerFrame / sampleRate * rate, levels: [], captureIndex: captureIndex))
        }
        expectedNextStart = startTime + Double(mid.count) / sampleRate * rate

        let frameLength = Int(samplesPerFrame)
        let hasSide = side.count == mid.count
        let segIdx = segments.count - 1
        for index in mid.indices {
            let sample = mid[index]
            if hasSide {
                let sideSample = side[index]
                let left = sample + sideSample
                let right = sample - sideSample
                let lo = min(left, right)
                let hi = max(left, right)
                if lo < frameMin { frameMin = lo }
                if hi > frameMax { frameMax = hi }
            } else {
                if sample < frameMin { frameMin = sample }
                if sample > frameMax { frameMax = sample }
            }
            let m = midFilter.process(sample)
            midEnergy += m * m
            if hasSide {
                let s = sideFilter.process(side[index])
                sideEnergy += s * s
            }
            pendingSamples += 1
            if pendingSamples == frameLength {
                let centre = max(midEnergy * 0.25, midEnergy - sideEnergy) / Float(frameLength)
                segments[segIdx].levels.append(10 * log10(centre + 1e-10))
                segments[segIdx].minPeaks.append(max(-1.0, min(0.0, frameMin)))
                segments[segIdx].maxPeaks.append(min(1.0, max(0.0, frameMax)))
                totalFrameCount += 1
                midEnergy = 0
                sideEnergy = 0
                frameMin = 0
                frameMax = 0
                pendingSamples = 0
            }
        }
        trimToCapacity()
    }

    /// Locates a chunk on the live frame grid, accounting for timestamp jitter between deliveries.
    func frameLocation(at time: Double) -> FrameLocation? {
        guard let segment = segments.last, let expectedNextStart else { return nil }
        let gridEnd = segment.end + Double(pendingSamples) / sampleRate * rate
        return FrameLocation(captureIndex: segment.captureIndex, time: gridEnd - (expectedNextStart - time))
    }

    /// Replaces the full-mix preview in place so the adjacent capture frames stay contiguous.
    mutating func replaceFrames(at location: FrameLocation, with stem: Segment) -> Bool {
        guard !stem.levels.isEmpty,
              let index = segments.lastIndex(where: { $0.captureIndex == location.captureIndex }),
              abs(segments[index].step - stem.step) < 1e-6
        else { return false }
        let first = Int(((location.time - segments[index].start) / stem.step).rounded())
        let start = max(0, first)
        let end = min(segments[index].levels.count, first + stem.levels.count)
        guard start < end else { return false }

        let frames = start..<end
        let source = (start - first)..<(end - first)
        segments[index].levels.replaceSubrange(frames, with: stem.levels[source])
        segments[index].minPeaks.replaceSubrange(frames, with: stem.minPeaks[source])
        segments[index].maxPeaks.replaceSubrange(frames, with: stem.maxPeaks[source])
        return true
    }

    private var samplesPerFrame: Double { (sampleRate * Self.frameSeconds).rounded() }

    private mutating func trimToCapacity() {
        while totalFrameCount > Self.maxFrames, segments.count > 1 {
            totalFrameCount -= segments.removeFirst().levels.count
        }
        // One continuous segment past capacity keeps its newest frames.
        if totalFrameCount > Self.maxFrames, var only = segments.first {
            let excess = totalFrameCount - Self.maxFrames
            only.levels.removeFirst(excess)
            if only.minPeaks.count >= excess { only.minPeaks.removeFirst(excess) }
            if only.maxPeaks.count >= excess { only.maxPeaks.removeFirst(excess) }
            only.start += Double(excess) * only.step
            segments[0] = only
            totalFrameCount -= excess
        }
    }

    /// The newest segment holding every frame of `range`.
    func segment(covering range: ClosedRange<Double>) -> Segment? {
        segments.last { $0.start <= range.lowerBound && range.upperBound <= $0.end }
    }

    /// How much louder (dB) the 0.25 s after `time` is than 0.35–0.05 s before it; nil unless one segment holds both.
    /// Used alongside harmonicity to decide whether a nearly confident line starts on a vocal onset.
    func onsetRise(at time: Double) -> Float? {
        guard let segment = segment(covering: (time - 0.35)...(time + 0.25)) else { return nil }
        func mean(_ from: Double, _ to: Double) -> Float? {
            let low = max(0, segment.frame(at: from)), high = min(segment.levels.count - 1, segment.frame(at: to))
            guard high > low else { return nil }
            return segment.levels[low...high].reduce(0, +) / Float(high - low + 1)
        }
        guard let after = mean(time, time + 0.25), let before = mean(time - 0.35, time - 0.05) else { return nil }
        return after - before
    }

    /// The level below which the given share of all frames fall, once at least 5 s were heard.
    func percentile(_ share: Double) -> Float? {
        let all = segments.flatMap(\.levels)
        guard all.count >= 500 else { return nil }
        let sorted = all.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))]
    }

    /// Combines non-overlapping cached frames with the current play's live envelope while keeping
    /// segments in capture recency order (oldest cached first, newest live last) so future merges
    /// evict the oldest captured frames rather than the lowest track timestamps.
    static func mergedPreservingCaptureOrder(cached: VocalEnvelope?, live: VocalEnvelope, capacity: Int = maxFrames) -> VocalEnvelope? {
        let cachedSegments = cached?.segments.filter { !$0.levels.isEmpty } ?? []
        let liveSegments = live.segments.filter { !$0.levels.isEmpty }
        guard !cachedSegments.isEmpty || !liveSegments.isEmpty else { return nil }
        if cachedSegments.isEmpty, liveSegments.count == 1, liveSegments[0].levels.count <= capacity {
            return live
        }

        // Resolve overlaps among live segments in capture order so replays replace stale peaks.
        var resolvedLive: [Segment] = []
        for liveSeg in liveSegments {
            resolvedLive = subtracting(liveSeg, from: resolvedLive)
            resolvedLive.append(liveSeg)
        }

        // Remove intervals covered by live frames from cached segments, preserving surrounding peaks.
        var preservedCached = cachedSegments
        for liveSeg in resolvedLive {
            preservedCached = subtracting(liveSeg, from: preservedCached)
        }

        // Apply the frame budget to recency order (keep newest live frames first, then fill with cached),
        // rather than evicting fresh low-timestamp segments after sorting by track time.
        let keptLive = keepNewest(resolvedLive, budget: capacity)
        let liveFrameCount = keptLive.reduce(0) { $0 + $1.levels.count }
        let keptCached = keepNewest(preservedCached, budget: max(0, capacity - liveFrameCount))

        var merged = VocalEnvelope()
        merged.segments = keptCached + keptLive
        merged.totalFrameCount = merged.segments.reduce(0) { $0 + $1.levels.count }
        return merged.segments.isEmpty ? nil : merged
    }

    /// Returns a track-time-sorted copy of `mergedPreservingCaptureOrder` ready for timeline drawing.
    static func mergedForDisplay(cached: VocalEnvelope?, live: VocalEnvelope, capacity: Int = maxFrames) -> VocalEnvelope? {
        guard var merged = mergedPreservingCaptureOrder(cached: cached, live: live, capacity: capacity) else {
            return nil
        }
        if merged.segments.count > 1 {
            merged.segments.sort { $0.start < $1.start }
        }
        return merged
    }

    private static func subtracting(_ cut: Segment, from segments: [Segment]) -> [Segment] {
        var result: [Segment] = []
        result.reserveCapacity(segments.count)
        for seg in segments {
            if cut.end <= seg.start || cut.start >= seg.end {
                result.append(seg)
                continue
            }
            if cut.start > seg.start {
                let exactFrames = (cut.start - seg.start) / seg.step
                let leftCount = max(0, min(seg.levels.count, Int(floor(exactFrames + 1e-6))))
                if leftCount > 0 {
                    result.append(slice(seg, range: 0..<leftCount))
                }
            }
            if cut.end < seg.end {
                let exactFrames = (cut.end - seg.start) / seg.step
                let rightStart = max(0, min(seg.levels.count, Int(ceil(exactFrames - 1e-6))))
                if rightStart < seg.levels.count {
                    result.append(slice(seg, range: rightStart..<seg.levels.count))
                }
            }
        }
        return result
    }

    private static func keepNewest(_ segments: [Segment], budget: Int) -> [Segment] {
        guard budget > 0, !segments.isEmpty else { return [] }
        var kept = segments
        var total = kept.reduce(0) { $0 + $1.levels.count }
        while total > budget, !kept.isEmpty {
            let excess = total - budget
            let oldest = kept[0]
            if oldest.levels.count <= excess {
                total -= oldest.levels.count
                kept.removeFirst()
            } else {
                kept[0] = slice(oldest, range: excess..<oldest.levels.count)
                total = budget
            }
        }
        return kept
    }

    private static func slice(_ segment: Segment, range: Range<Int>) -> Segment {
        let hasMin = segment.minPeaks.count == segment.levels.count
        let hasMax = segment.maxPeaks.count == segment.levels.count
        return Segment(
            start: segment.time(ofFrame: range.lowerBound),
            step: segment.step,
            levels: Array(segment.levels[range]),
            minPeaks: hasMin ? Array(segment.minPeaks[range]) : [],
            maxPeaks: hasMax ? Array(segment.maxPeaks[range]) : []
        )
    }
}

/// Refines recognized word timings with the vocal envelope: drops words heard in silence and
/// lengthens words to cover the note the singer holds.
///
/// Word starts are left alone: on annotated songs (JamendoLyrics), moving them onto envelope onsets
/// made Lyrics Alignment starts slightly worse, because sung onsets are rarely sharp in loudness.
enum WaveformTimingRefiner {
    struct Stats: Equatable, Sendable {
        var extended = 0
        var dropped = 0
        var harmonicityTrimmed = 0
    }

    /// A word whose loudest frame is this close to the song's quietest frames was heard in silence.
    static let silenceMargin: Float = 6
    /// Gating needs this much range between the quiet and loud frames, so a song with no quiet parts keeps every word.
    static let minimumDynamicRange: Float = 15
    /// A held note continues while the level stays within this many dB of where it starts.
    static let sustainDrop: Float = 8
    /// Seconds around a word's end whose peak is the held note's level: the final vowel starts there,
    /// and a louder earlier syllable must not end its hold.
    static let holdReach = 0.1
    /// A word peaking below this heard digital silence, so it holds no note to extend.
    static let minimumSignalLevel: Float = -80
    static let maxExtension = 1.5
    static let minimumGap = 0.02
    private static let unvoicedTailFrames = 5
    private static let quietFloorMargin: Float = 2
    private static let shortUnvoicedWord = 0.12

    /// `timingError` is about how far (seconds) the engine's word times can be off; silence is judged
    /// that far around each word.
    static func refine(
        _ words: [RecognizedAudioWord],
        envelope: VocalEnvelope,
        pitchContour: VocalPitchContour? = nil,
        timingError: Double
    ) -> (words: [RecognizedAudioWord], stats: Stats) {
        var stats = Stats()
        let floor = envelope.percentile(0.1)
        let gateLevel: Float? = {
            guard let floor, let loud = envelope.percentile(0.9), loud - floor >= minimumDynamicRange else { return nil }
            return floor + silenceMargin
        }()

        // Pass 1: drop words heard in silence.
        var refined: [RecognizedAudioWord] = []
        for word in words.sorted(by: { $0.startTime < $1.startTime }) {
            let slack = timingError + 0.1
            let from = word.startTime - slack
            let to = word.endTime + slack
            let wordRange = word.startTime...word.endTime
            if let floor, let gateLevel,
               let segment = envelope.segment(covering: wordRange),
               let peak = maxLevel(in: segment, from: from, to: to),
               peak < gateLevel {
                let clarity = pitchContour?.segment(covering: wordRange)?.frames(from: from, to: to).max()
                if isSilent(word, peak: peak, floor: floor, clarity: clarity) {
                    stats.dropped += 1
                    continue
                }
            }
            refined.append(word)
        }

        // Pass 2: lengthen each word over the note it holds, up to the next word.
        for index in refined.indices {
            let word = refined[index]
            let end = word.startTime + word.duration
            guard let segment = envelope.segment(covering: word.startTime...end),
                  let peak = maxLevel(in: segment, from: max(word.startTime, end - holdReach), to: end + holdReach),
                  peak >= minimumSignalLevel
            else { continue }
            let nextStart = index + 1 < refined.count ? refined[index + 1].startTime : .infinity
            let limit = min(nextStart - minimumGap, end + maxExtension, segment.end)
            guard limit > end else { continue }
            var frame = segment.frame(at: end)
            let lastFrame = min(segment.levels.count - 1, segment.frame(at: limit) - 1)
            while frame <= lastFrame, frame >= 0, segment.levels[frame] >= peak - sustainDrop {
                frame += 1
            }
            var sustainEnd = min(limit, segment.time(ofFrame: frame))
            let wordEnd = word.endTime
            if sustainEnd > wordEnd,
               let pitchContour,
               let pitchSegment = pitchContour.segment(covering: wordEnd...wordEnd),
               let vowelClarity = pitchSegment.frames(from: max(word.startTime, wordEnd - holdReach), to: wordEnd).max() {
                if vowelClarity >= VocalPitchContour.voicedThreshold {
                    // Live capture can append loudness before the pitch worker catches up.
                    sustainEnd = min(sustainEnd, pitchSegment.end)
                    if let unvoicedStart = unvoicedTailStart(in: pitchSegment, from: wordEnd, before: sustainEnd) {
                        sustainEnd = unvoicedStart
                        stats.harmonicityTrimmed += 1
                    }
                } else if let wordClarity = pitchContour.maxHarmonicity(from: word.startTime, to: wordEnd),
                          wordClarity >= VocalPitchContour.voicedThreshold {
                    // A voiced word that already ends in a consonant has no held vowel to extend.
                    continue
                }
            }
            if sustainEnd - end >= segment.step * 2 {
                refined[index] = RecognizedAudioWord(
                    text: word.text,
                    startTime: word.startTime,
                    duration: sustainEnd - word.startTime,
                    confidence: word.confidence,
                    syllables: word.syllables,
                    sourceLineId: word.sourceLineId
                )
                stats.extended += 1
            }
        }
        return (refined, stats)
    }

    private static func isSilent(_ word: RecognizedAudioWord, peak: Float, floor: Float, clarity: Float?) -> Bool {
        guard let clarity else { return true }
        // Quiet consonants and whispered words can have very little periodicity.
        return clarity <= 0.05 && (peak < minimumSignalLevel
            || (peak < floor + quietFloorMargin && word.duration >= shortUnvoicedWord))
    }

    private static func unvoicedTailStart(
        in segment: VocalPitchContour.Segment,
        from end: Double,
        before limit: Double
    ) -> Double? {
        let first = max(0, segment.frame(at: end))
        let last = min(segment.harmonicity.count - 1, segment.frame(at: limit) - 1)
        guard first <= last else { return nil }
        var consecutive = 0
        for frame in first...last {
            if segment.harmonicity[frame] < VocalPitchContour.unvoicedFloor {
                consecutive += 1
                if consecutive == unvoicedTailFrames {
                    let start = segment.start + Double(frame - consecutive + 1) * segment.step
                    return max(end, start)
                }
            } else {
                consecutive = 0
            }
        }
        return nil
    }

    private static func maxLevel(in segment: VocalEnvelope.Segment, from start: Double, to end: Double) -> Float? {
        let low = max(0, segment.frame(at: start))
        let high = min(segment.levels.count - 1, max(low, segment.frame(at: end) - 1))
        guard low <= high else { return nil }
        return segment.levels[low...high].max()
    }
}
