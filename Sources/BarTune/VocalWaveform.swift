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
    private var midFilter = VoiceBandFilter(sampleRate: 16000)
    private var sideFilter = VoiceBandFilter(sampleRate: 16000)
    private var sampleRate = 0.0
    private var rate = 1.0
    private var expectedNextStart: Double?
    private var midEnergy: Float = 0
    private var sideEnergy: Float = 0
    private var pendingSamples = 0

    /// Appends captured audio starting at `startTime` (track seconds); `side` is empty for mono audio.
    /// Audio that doesn't continue the last append (a seek, a gap, a rate change) starts a new segment.
    mutating func append(mid: [Float], side: [Float], sampleRate: Double, startTime: Double, rate: Double) {
        guard sampleRate > 0, rate > 0, !mid.isEmpty else { return }
        let contiguous = expectedNextStart.map { abs($0 - startTime) <= 0.05 } ?? false
        if !contiguous || sampleRate != self.sampleRate || abs(rate - self.rate) > 0.001 {
            self.sampleRate = sampleRate
            self.rate = rate
            midFilter = VoiceBandFilter(sampleRate: sampleRate)
            sideFilter = VoiceBandFilter(sampleRate: sampleRate)
            midEnergy = 0
            sideEnergy = 0
            pendingSamples = 0
            segments.append(Segment(start: startTime, step: samplesPerFrame / sampleRate * rate, levels: []))
        }
        expectedNextStart = startTime + Double(mid.count) / sampleRate * rate

        let frameLength = Int(samplesPerFrame)
        let hasSide = side.count == mid.count
        var levels = segments[segments.count - 1].levels
        for index in mid.indices {
            let m = midFilter.process(mid[index])
            midEnergy += m * m
            if hasSide {
                let s = sideFilter.process(side[index])
                sideEnergy += s * s
            }
            pendingSamples += 1
            if pendingSamples == frameLength {
                let centre = max(midEnergy * 0.25, midEnergy - sideEnergy) / Float(frameLength)
                levels.append(10 * log10(centre + 1e-10))
                midEnergy = 0
                sideEnergy = 0
                pendingSamples = 0
            }
        }
        segments[segments.count - 1].levels = levels
        trimToCapacity()
    }

    private var samplesPerFrame: Double { (sampleRate * Self.frameSeconds).rounded() }

    private mutating func trimToCapacity() {
        var total = segments.reduce(0) { $0 + $1.levels.count }
        while total > Self.maxFrames, segments.count > 1 {
            total -= segments.removeFirst().levels.count
        }
        // One continuous segment past capacity keeps its newest frames.
        if total > Self.maxFrames, var only = segments.first {
            let excess = total - Self.maxFrames
            only.levels.removeFirst(excess)
            only.start += Double(excess) * only.step
            segments[0] = only
        }
    }

    /// The newest segment holding every frame of `range`.
    func segment(covering range: ClosedRange<Double>) -> Segment? {
        segments.last { $0.start <= range.lowerBound && range.upperBound <= $0.end }
    }

    /// The level below which the given share of all frames fall, once at least 5 s were heard.
    func percentile(_ share: Double) -> Float? {
        let all = segments.flatMap(\.levels)
        guard all.count >= 500 else { return nil }
        let sorted = all.sorted()
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))]
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

    /// `timingError` is about how far (seconds) the engine's word times can be off; silence is judged
    /// that far around each word.
    static func refine(
        _ words: [RecognizedAudioWord],
        envelope: VocalEnvelope,
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
            if let gateLevel,
               let segment = envelope.segment(covering: word.startTime...word.endTime),
               let peak = maxLevel(in: segment, from: word.startTime - slack, to: word.endTime + slack),
               peak < gateLevel {
                stats.dropped += 1
                continue
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
            let sustainEnd = min(limit, segment.time(ofFrame: frame))
            if sustainEnd - end >= segment.step * 2 {
                refined[index] = RecognizedAudioWord(
                    text: word.text,
                    startTime: word.startTime,
                    duration: sustainEnd - word.startTime,
                    confidence: word.confidence,
                    syllables: word.syllables
                )
                stats.extended += 1
            }
        }
        return (refined, stats)
    }

    private static func maxLevel(in segment: VocalEnvelope.Segment, from start: Double, to end: Double) -> Float? {
        let low = max(0, segment.frame(at: start))
        let high = min(segment.levels.count - 1, max(low, segment.frame(at: end) - 1))
        guard low <= high else { return nil }
        return segment.levels[low...high].max()
    }
}
