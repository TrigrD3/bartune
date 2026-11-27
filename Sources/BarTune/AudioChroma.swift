import Accelerate
import Foundation

/// Octave-independent pitch energy on a shared 20 Hz track-time grid.
struct AudioChromaProfile: Sendable {
    struct Segment: Sendable {
        fileprivate let startFrame: Int
        var start: Double { Double(startFrame) * step }
        let step = AudioChromaProfile.frameSeconds
        fileprivate(set) var frames: [Float]

        var frameCount: Int { frames.count / AudioChromaProfile.pitchClasses }
        fileprivate var endFrame: Int { startFrame + frameCount }
        var end: Double { Double(endFrame) * step }
    }

    struct Match {
        let lagFrames: Double
        let similarity: Double
        let margin: Double
        let separatePeak: Double
    }

    static let frameSeconds = 0.05
    static let pitchClasses = 12
    fileprivate static let peakNeighborhoodFrames = 3
    /// Twenty minutes of chroma frames, about 1.1 MB.
    static let maxFrames = 24000

    private(set) var segments: [Segment] = []

    mutating func append(samples: [Float], sampleRate: Double, startTime: Double, rate: Double = 1) {
        guard !samples.isEmpty, sampleRate.isFinite, sampleRate > 130,
              startTime.isFinite, rate.isFinite, rate > 0
        else { return }
        let firstFrame = Self.frameCeiling(max(0, startTime))
        let endFrame = Self.frameCeiling(startTime + Double(samples.count) / sampleRate * rate)
        let startFrame = max(firstFrame, endFrame - Self.maxFrames)
        guard startFrame < endFrame else { return }

        // Keep roughly the same window duration and frequency resolution at other sample rates.
        let log2Size = vDSP_Length(max(5, log2(sampleRate * 2048 / 16000).rounded()))
        let size = 1 << Int(log2Size)
        guard let fft = vDSP_create_fftsetup(log2Size, FFTRadix(kFFTRadix2)) else { return }
        defer { vDSP_destroy_fftsetup(fft) }

        let half = size / 2
        let binWidth = sampleRate / Double(size)
        let firstBin = max(1, Int((65 / binWidth).rounded()))
        let lastBin = min(half - 2, Int((2093 / binWidth).rounded()))
        guard firstBin <= lastBin else { return }

        var window = [Float](repeating: 0, count: size)
        vDSP_hann_window(&window, vDSP_Length(size), Int32(vDSP_HANN_NORM))
        var real = [Float](repeating: 0, count: half)
        var imaginary = real
        var power = real
        var frames = [Float](repeating: 0, count: (endFrame - startFrame) * Self.pitchClasses)

        real.withUnsafeMutableBufferPointer { real in
            imaginary.withUnsafeMutableBufferPointer { imaginary in
                guard let even = real.baseAddress, let odd = imaginary.baseAddress else { return }
                var split = DSPSplitComplex(realp: even, imagp: odd)
                for frame in startFrame..<endFrame {
                    let centerTime = Double(frame) * Self.frameSeconds
                    let center = Int(((centerTime - startTime) * sampleRate / rate).rounded())
                    let sampleStart = center - half
                    // Real FFT input packs even and odd samples in separate buffers. Zero-pad
                    // the chunk edges so the 50 ms grid can stay contiguous across chunks.
                    for index in 0..<half {
                        let offset = index * 2
                        let source = sampleStart + offset
                        even[index] = samples.indices.contains(source) ? samples[source] * window[offset] : 0
                        odd[index] = samples.indices.contains(source + 1) ? samples[source + 1] * window[offset + 1] : 0
                    }
                    vDSP_fft_zrip(fft, &split, 1, log2Size, FFTDirection(FFT_FORWARD))
                    vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(half))
                    power[0] = 0 // Packed DC and Nyquist are outside the chroma band.
                    Self.foldPitchPeaks(
                        power, bins: firstBin...lastBin, binWidth: binWidth,
                        into: &frames, at: (frame - startFrame) * Self.pitchClasses
                    )
                }
            }
        }

        insert(Segment(startFrame: startFrame, frames: frames))
        trimToCapacity()
    }

    private static func foldPitchPeaks(
        _ power: [Float], bins: ClosedRange<Int>, binWidth: Double, into frames: inout [Float], at offset: Int
    ) {
        for bin in bins {
            let left = power[bin - 1]
            let center = power[bin]
            let right = power[bin + 1]
            // Assign each peak once. Interpolation keeps low notes and off-bin pitches from
            // spreading their Hann main lobe across several neighboring pitch classes.
            guard center.isFinite, center > left, center >= right, center > 0 else { continue }
            let fraction = Double(0.5 * (right - left) / (2 * center - left - right))
            let frequency = (Double(bin) + fraction) * binWidth
            let midi = Int((69 + 12 * log2(frequency / 440)).rounded())
            let pitchClass = (midi % pitchClasses + pitchClasses) % pitchClasses
            frames[offset + pitchClass] += sqrt(center)
        }
        let range = offset..<(offset + pitchClasses)
        let norm = sqrt(frames[range].reduce(Float(0)) { $0 + $1 * $1 })
        guard norm > 0 else { return }
        for index in range {
            frames[index] /= norm
        }
    }

    /// Keeps the first capture of overlapping grid frames and joins touching segments.
    mutating func merge(_ other: Self) {
        for segment in other.segments {
            insert(segment)
        }
        trimToCapacity()
    }

    private mutating func insert(_ segment: Segment) {
        guard let index = segments.firstIndex(where: { $0.endFrame >= segment.startFrame }) else {
            segments.append(segment)
            return
        }
        if segment.endFrame < segments[index].startFrame {
            segments.insert(segment, at: index)
            return
        }
        if segment.startFrame < segments[index].startFrame {
            let prefixCount = (segments[index].startFrame - segment.startFrame) * Self.pitchClasses
            segments[index] = Segment(
                startFrame: segment.startFrame, frames: Array(segment.frames.prefix(prefixCount)) + segments[index].frames
            )
        }
        while index + 1 < segments.count, segments[index + 1].startFrame <= segment.endFrame {
            let next = segments[index + 1]
            let gapStart = (segments[index].endFrame - segment.startFrame) * Self.pitchClasses
            let gapEnd = (next.startFrame - segment.startFrame) * Self.pitchClasses
            segments[index].frames.append(contentsOf: segment.frames[gapStart..<gapEnd])
            segments[index].frames.append(contentsOf: next.frames)
            segments.remove(at: index + 1)
        }
        let overlap = (segments[index].endFrame - segment.startFrame) * Self.pitchClasses
        segments[index].frames.append(contentsOf: segment.frames.dropFirst(overlap))
    }

    private mutating func trimToCapacity() {
        var excess = segments.reduce(-Self.maxFrames) { $0 + $1.frameCount }
        while excess > 0, let first = segments.first {
            if first.frameCount <= excess {
                excess -= first.frameCount
                segments.removeFirst()
            } else {
                segments[0] = Segment(
                    startFrame: first.startFrame + excess, frames: Array(first.frames.dropFirst(excess * Self.pitchClasses))
                )
                break
            }
        }
    }

    /// Frames in the half-open range, only when one segment covers the entire slice.
    func slice(from start: Double, to end: Double) -> (frames: [Float], startTime: Double)? {
        guard start.isFinite, end.isFinite, end > start,
              let segment = segments.first(where: { start >= $0.start - 1e-8 && end <= $0.end + 1e-8 })
        else { return nil }
        let first = max(segment.startFrame, Self.frameCeiling(start))
        let limit = min(segment.endFrame, Self.frameCeiling(end))
        guard first < limit else { return nil }
        let lower = (first - segment.startFrame) * Self.pitchClasses
        let upper = (limit - segment.startFrame) * Self.pitchClasses
        return (Array(segment.frames[lower..<upper]), Double(first) * Self.frameSeconds)
    }

    fileprivate static func frameCeiling(_ time: Double) -> Int {
        Int((time / frameSeconds - 1e-8).rounded(.up))
    }

    /// Cosine over a window of L2-normalized frames. Silent frames contribute zero energy.
    static func cosineSimilarity(template: [Float], target: [Float], lagFrames: Int) -> Double {
        guard !template.isEmpty, template.count.isMultiple(of: pitchClasses),
              target.count.isMultiple(of: pitchClasses), lagFrames >= 0,
              lagFrames <= (target.count - template.count) / pitchClasses
        else { return 0 }
        return template.withUnsafeBufferPointer { template in
            target.withUnsafeBufferPointer { target in
                guard let source = template.baseAddress, let target = target.baseAddress else { return 0 }
                let shifted = target + lagFrames * pitchClasses
                let count = vDSP_Length(template.count)
                var dot: Float = 0
                var sourceEnergy: Float = 0
                var targetEnergy: Float = 0
                vDSP_dotpr(source, 1, shifted, 1, &dot, count)
                vDSP_svesq(source, 1, &sourceEnergy, count)
                vDSP_svesq(shifted, 1, &targetEnergy, count)
                let norm = sqrt(Double(sourceEnergy) * Double(targetEnergy))
                return norm > 0 ? min(1, max(0, Double(dot) / norm)) : 0
            }
        }
    }

    /// Searches only lags for which the whole template fits in the target. Lag is relative to the
    /// first target frame. The median uses all searched lags, including the peak.
    static func bestMatch(template: [Float], in target: [Float], expectedLagFrames: Int, maxLagDeltaFrames: Int) -> Match? {
        let lower = max(0, expectedLagFrames - maxLagDeltaFrames)
        let upper = min((target.count - template.count) / pitchClasses, expectedLagFrames + maxLagDeltaFrames)
        guard !template.isEmpty, lower <= upper else { return nil }
        let scores = (lower...upper).map { cosineSimilarity(template: template, target: target, lagFrames: $0) }
        guard let peakIndex = scores.indices.max(by: { scores[$0] < scores[$1] }) else { return nil }
        let peak = scores[peakIndex]
        let sortedScores = scores.sorted()
        let median = (sortedScores[(scores.count - 1) / 2] + sortedScores[scores.count / 2]) / 2
        // Nearby lags are part of the same peak (three frames are 150 ms).
        let separatePeak = scores.indices.lazy.filter { abs($0 - peakIndex) > peakNeighborhoodFrames }.map { scores[$0] }.max() ?? 0

        var correction = 0.0
        if peakIndex > 0, peakIndex + 1 < scores.count {
            let left = scores[peakIndex - 1]
            let right = scores[peakIndex + 1]
            let curvature = 2 * peak - left - right
            if curvature > 0 {
                correction = 0.5 * (right - left) / curvature
            }
        }
        return Match(lagFrames: Double(lower + peakIndex) + correction, similarity: peak, margin: peak - median, separatePeak: separatePeak)
    }
}

enum ChorusSelfSimilarity {
    struct CachedTemplate: Equatable, Codable, Sendable {
        let lineId: Int
        let startTime: Double
        let quantizedFrames: Data

        init(lineId: Int, startTime: Double, frames: [Float]) {
            self.lineId = lineId
            self.startTime = startTime
            quantizedFrames = Data(frames.map { UInt8((min(1, max(0, $0)) * 255).rounded()) })
        }

        var frames: [Float] {
            quantizedFrames.map { Float($0) / 255.0 }
        }

        func remapped(lineId: Int) -> CachedTemplate {
            CachedTemplate(lineId: lineId, startTime: startTime, quantizedFrames: quantizedFrames)
        }

        private init(lineId: Int, startTime: Double, quantizedFrames: Data) {
            self.lineId = lineId
            self.startTime = startTime
            self.quantizedFrames = quantizedFrames
        }
    }

    struct Result {
        let lines: [LyricLine]
        let recoveredLineIDs: Set<Int>
    }

    private struct Template {
        let line: LyricLine
        let tail: Double
        let frames: [Float]
        let startTime: Double
    }

    private static let padding = 0.5
    private static let maxLagShift = 4.0
    private static let minLineGap = 0.15
    private static let peakNeighborhood = Double(AudioChromaProfile.peakNeighborhoodFrames) * AudioChromaProfile.frameSeconds
    private static let minPeakSeparationMargin = 0.04

    static func extractCachedTemplates(
        in lines: [LyricLine],
        lockedIDs: Set<Int>,
        chroma: AudioChromaProfile,
        existing: [CachedTemplate] = []
    ) -> [CachedTemplate] {
        guard !lockedIDs.isEmpty else { return [] }
        let tokens = lines.map { LyricsAudioAligner.tokenizeLine($0.text).map(\.normalized).filter { !$0.isEmpty } }
        let repeated = Dictionary(grouping: lines.indices.filter {
            tokens[$0].count >= 2 || (tokens[$0].first?.count ?? 0) >= 8
        }) { tokens[$0].joined(separator: " ") }
        let repeatedIndices = Set(repeated.values.filter { $0.count > 1 }.joined())
        let existingByID = Dictionary(existing.map { ($0.lineId, $0) }, uniquingKeysWith: { _, latest in latest })

        var result: [CachedTemplate] = []
        for index in lines.indices where repeatedIndices.contains(index) && lockedIDs.contains(lines[index].id) {
            let line = lines[index]
            if let template = makeTemplate(line, chroma: chroma) {
                result.append(CachedTemplate(lineId: line.id, startTime: template.startTime, frames: template.frames))
            } else if let kept = existingByID[line.id],
                      !kept.quantizedFrames.isEmpty,
                      kept.quantizedFrames.count.isMultiple(of: AudioChromaProfile.pitchClasses) {
                result.append(kept)
            }
        }
        return result
    }

    static func recoverRepeatedLines(
        in lines: [LyricLine],
        lockedIDs: Set<Int>,
        protectedTargetIDs: Set<Int> = [],
        chroma: AudioChromaProfile,
        cachedTemplates: [CachedTemplate] = [],
        medianOffset: Double?,
        sourceTimestamps: [Int: Double] = [:]
    ) -> Result {
        let offsetLimit = lockedIDs.count >= 2 ? LyricsAudioAligner.maxOwnedOffset : LyricsAudioAligner.standardOffsetLimit
        let offset = medianOffset ?? 0
        guard abs(offset) <= offsetLimit, !lockedIDs.isEmpty, !chroma.segments.isEmpty else {
            return Result(lines: lines, recoveredLineIDs: [])
        }

        let cachedByID = Dictionary(cachedTemplates.map { ($0.lineId, $0) }, uniquingKeysWith: { _, latest in latest })
        let tokens = lines.map { LyricsAudioAligner.tokenizeLine($0.text).map(\.normalized).filter { !$0.isEmpty } }
        let repeated = Dictionary(grouping: lines.indices.filter {
            tokens[$0].count >= 2 || (tokens[$0].first?.count ?? 0) >= 8
        }) { tokens[$0].joined(separator: " ") }
        var templatesByTarget: [Int: [Template]] = [:]
        let excludedTargets = lockedIDs.union(protectedTargetIDs)
        for indices in repeated.values where indices.count > 1 {
            let targets = indices.filter { !excludedTargets.contains(lines[$0].id) }
            guard !targets.isEmpty else { continue }
            let templates = indices.compactMap { index -> Template? in
                guard lockedIDs.contains(lines[index].id) else { return nil }
                return makeTemplate(lines[index], chroma: chroma)
                    ?? cachedByID[lines[index].id].flatMap { makeTemplate(lines[index], cached: $0) }
            }
            guard !templates.isEmpty else { continue }
            for index in targets {
                templatesByTarget[index] = templates
            }
        }

        var updated = lines
        var recovered: Set<Int> = []
        let nonEmpty = lines.indices.filter { !lines[$0].text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var previousLocked: LyricLine?
        var remainingLocks = nonEmpty.filter { lockedIDs.contains(lines[$0].id) }[...]
        for (position, index) in nonEmpty.enumerated() {
            let target = lines[index]
            if lockedIDs.contains(target.id) {
                previousLocked = target
                remainingLocks = remainingLocks.dropFirst()
                continue
            }
            guard let templates = templatesByTarget[index] else { continue }
            let source = sourceTimestamps[target.id] ?? target.timestamp
            let expected = source + offset
            var lower = max(0, expected - maxLagShift, source - offsetLimit)
            var upper = min(expected + maxLagShift, source + offsetLimit)
            if index > 0 {
                lower = max(lower, updated[index - 1].timestamp)
            }
            if index + 1 < lines.count {
                upper = min(upper, updated[index + 1].timestamp)
            }
            if position > 0 {
                let previous = updated[nonEmpty[position - 1]]
                lower = max(lower, previous.timestamp + minLineGap)
                if !previous.words.isEmpty {
                    lower = max(lower, lineEnd(previous))
                }
            }
            let nextStart = position + 1 < nonEmpty.count ? updated[nonEmpty[position + 1]].timestamp : .infinity
            upper = min(upper, nextStart - minLineGap)
            if let previousLocked {
                lower = max(lower, lineEnd(previousLocked))
            }
            let nextLockedStart = remainingLocks.first.map { lines[$0].timestamp } ?? .infinity
            let candidates = templates.compactMap { template -> (template: Template, start: Double, similarity: Double)? in
                let latest = min(upper, min(nextStart, nextLockedStart) - template.tail)
                guard lower <= latest,
                      let candidate = match(template, in: chroma, lower: lower, upper: latest)
                else { return nil }
                return (template, candidate.start, candidate.similarity)
            }
            guard let best = candidates.max(by: { $0.similarity < $1.similarity }), best.start + minLineGap <= nextStart,
                  !candidates.contains(where: {
                      abs($0.start - best.start) > peakNeighborhood && best.similarity - $0.similarity < minPeakSeparationMargin
                  })
            else { continue }
            let words = shiftedWords(from: best.template.line, to: target.text, start: best.start)
            updated[index] = LyricLine(
                id: target.id, timestamp: best.start, duration: best.template.line.duration, text: target.text, words: words
            )
            recovered.insert(target.id)
        }

        return Result(lines: updated, recoveredLineIDs: recovered)
    }

    /// Keep the target's spelling and punctuation while transferring each timed part, including syllables.
    private static func shiftedWords(from template: LyricLine, to text: String, start: Double) -> [WordTimestamp] {
        let shift = start - template.timestamp
        var cursor = text.startIndex
        return template.words.enumerated().map { index, word in
            let display: String
            if text == template.text {
                display = word.text
            } else {
                let partStart = cursor
                var remaining = LyricsAudioAligner.normalizeToken(word.text).count
                while cursor < text.endIndex, remaining > 0 {
                    remaining -= LyricsAudioAligner.normalizeToken(String(text[cursor])).count
                    text.formIndex(after: &cursor)
                }
                while cursor < text.endIndex, LyricsAudioAligner.normalizeToken(String(text[cursor])).isEmpty {
                    text.formIndex(after: &cursor)
                }
                if index == template.words.count - 1 { cursor = text.endIndex }
                display = String(text[partStart..<cursor])
            }
            return WordTimestamp(timestamp: word.timestamp + shift, duration: word.duration, text: display)
        }
    }

    private static func lineEnd(_ line: LyricLine) -> Double {
        let wordsEnd = line.words.map { $0.timestamp + ($0.duration ?? 0) }.max() ?? line.timestamp
        return max(wordsEnd, line.timestamp + (line.duration ?? 0))
    }

    private static func makeTemplate(_ line: LyricLine, chroma: AudioChromaProfile) -> Template? {
        guard let firstWord = line.words.first, let lastWord = line.words.last,
              firstWord.timestamp >= line.timestamp,
              zip(line.words, line.words.dropFirst()).allSatisfy({ $0.timestamp <= $1.timestamp })
        else { return nil }
        let sungEnd = lastWord.timestamp + (lastWord.duration ?? 0)
        guard sungEnd - firstWord.timestamp >= 1,
              let segment = chroma.segments.first(where: { $0.start <= firstWord.timestamp && sungEnd <= $0.end }),
              let slice = chroma.slice(
                  from: max(segment.start, firstWord.timestamp - padding), to: min(segment.end, sungEnd + padding)
              )
        else { return nil }
        return Template(line: line, tail: lineEnd(line) - line.timestamp, frames: slice.frames, startTime: slice.startTime)
    }

    private static func makeTemplate(_ line: LyricLine, cached: CachedTemplate) -> Template? {
        guard let firstWord = line.words.first, let lastWord = line.words.last,
              firstWord.timestamp >= line.timestamp,
              zip(line.words, line.words.dropFirst()).allSatisfy({ $0.timestamp <= $1.timestamp })
        else { return nil }
        let sungEnd = lastWord.timestamp + (lastWord.duration ?? 0)
        let frames = cached.frames
        guard sungEnd - firstWord.timestamp >= 1,
              !frames.isEmpty,
              frames.count.isMultiple(of: AudioChromaProfile.pitchClasses)
        else { return nil }
        return Template(line: line, tail: lineEnd(line) - line.timestamp, frames: frames, startTime: cached.startTime)
    }

    private static func match(
        _ template: Template, in chroma: AudioChromaProfile, lower: Double, upper: Double
    ) -> (start: Double, similarity: Double)? {
        let step = AudioChromaProfile.frameSeconds
        let contextOffset = template.startTime - template.line.timestamp
        let templateDuration = Double(template.frames.count / AudioChromaProfile.pitchClasses) * step
        let first = AudioChromaProfile.frameCeiling(lower + contextOffset)
        let last = -AudioChromaProfile.frameCeiling(-(upper + contextOffset))
        guard first <= last else { return nil }
        var best: (start: Double, peak: AudioChromaProfile.Match)?
        var otherSegmentPeak = 0.0
        for segment in chroma.segments {
            let from = max(Double(first) * step, segment.start)
            let to = min(Double(last) * step + templateDuration, segment.end)
            guard to - from >= templateDuration - 1e-8,
                  let target = chroma.slice(from: from, to: to)
            else { continue }
            let lags = (target.frames.count - template.frames.count) / AudioChromaProfile.pitchClasses
            guard let peak = AudioChromaProfile.bestMatch(
                template: template.frames, in: target.frames, expectedLagFrames: lags / 2, maxLagDeltaFrames: (lags + 1) / 2
            )
            else { continue }
            if let best, best.peak.similarity >= peak.similarity {
                otherSegmentPeak = max(otherSegmentPeak, peak.similarity)
                continue
            }
            otherSegmentPeak = max(otherSegmentPeak, best?.peak.similarity ?? 0)
            let start = target.startTime + peak.lagFrames * step - contextOffset
            best = (min(upper, max(lower, start)), peak)
        }
        guard let best, best.peak.similarity >= 0.85, best.peak.margin >= 0.08,
              best.peak.similarity - max(best.peak.separatePeak, otherSegmentPeak) >= minPeakSeparationMargin
        else { return nil }
        return (best.start, best.peak.similarity)
    }
}
