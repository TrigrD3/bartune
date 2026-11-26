import Accelerate
import Foundation

/// Periodicity of the centre-panned mix, in 10 ms frames. Track-time steps follow the playback rate.
struct VocalPitchContour: Sendable {
    struct Segment: Sendable {
        var start: Double
        let step: Double
        var f0Hz: [Float]
        var harmonicity: [Float]

        var end: Double { start + Double(harmonicity.count) * step }

        func frame(at time: Double) -> Int {
            Int(((time - start) / step + 1e-8).rounded(.down))
        }

        func frames(from start: Double, to end: Double) -> ArraySlice<Float> {
            let low = max(0, min(frame(at: start), harmonicity.count - 1))
            let high = max(low, min(frame(at: end), harmonicity.count - 1))
            return harmonicity[low...high]
        }
    }

    static let sampleRate = 16000
    static let maxFrames = 120_000
    static let voicedThreshold: Float = 0.7
    static let unvoicedFloor: Float = 0.25

    private(set) var segments: [Segment] = []
    private var frameCount = 0
    private var voicedFrameCount = 0

    var voicedFraction: Float? {
        frameCount > 0 ? Float(voicedFrameCount) / Float(frameCount) : nil
    }

    mutating func merge(_ segment: Segment) {
        guard !segment.harmonicity.isEmpty else { return }
        let last = segments.count - 1
        // Like the envelope, tolerate capture clock jitter when a new chunk re-anchors.
        if last >= 0, abs(segments[last].step - segment.step) < 1e-8,
           abs(segments[last].end - segment.start) <= 0.05 {
            segments[last].f0Hz.append(contentsOf: segment.f0Hz)
            segments[last].harmonicity.append(contentsOf: segment.harmonicity)
        } else {
            segments.append(segment)
        }
        frameCount += segment.harmonicity.count
        voicedFrameCount += Self.countVoiced(segment.harmonicity[...])
        while frameCount > Self.maxFrames {
            let excess = min(frameCount - Self.maxFrames, segments[0].harmonicity.count)
            voicedFrameCount -= Self.countVoiced(segments[0].harmonicity.prefix(excess))
            frameCount -= excess
            if excess == segments[0].harmonicity.count {
                segments.removeFirst()
            } else {
                segments[0].f0Hz.removeFirst(excess)
                segments[0].harmonicity.removeFirst(excess)
                segments[0].start += Double(excess) * segments[0].step
            }
        }
    }

    private static func countVoiced(_ frames: ArraySlice<Float>) -> Int {
        frames.reduce(into: 0) { if $1 >= voicedThreshold { $0 += 1 } }
    }

    func segment(covering range: ClosedRange<Double>) -> Segment? {
        segments.last { $0.start <= range.lowerBound + 1e-8 && range.upperBound <= $0.end + 1e-8 }
    }

    func meanHarmonicity(from start: Double, to end: Double) -> Float? {
        guard start <= end else { return nil }
        return segment(covering: start...end).map { Self.mean($0.frames(from: start, to: end)) }
    }

    func maxHarmonicity(from start: Double, to end: Double) -> Float? {
        guard start <= end else { return nil }
        return segment(covering: start...end)?.frames(from: start, to: end).max()
    }

    func harmonicityRise(at time: Double) -> Float? {
        guard let segment = segment(covering: (time - 0.35)...(time + 0.25)) else { return nil }
        return Self.mean(segment.frames(from: time, to: time + 0.25))
            - Self.mean(segment.frames(from: time - 0.35, to: time - 0.05))
    }

    private static func mean(_ frames: ArraySlice<Float>) -> Float {
        frames.reduce(0, +) / Float(frames.count)
    }

    /// Estimates F0 on 16 kHz samples. All spectra and lag buffers are reused for the entire chunk.
    static func analyze(mid: [Float], side: [Float] = [], start: Double, rate: Double) -> Segment? {
        let hop = 160
        let count = mid.count / hop
        guard mid.count >= YIN.windowSize,
              let setup = vDSP_create_fftsetup(YIN.fftOrder, FFTRadix(kFFTRadix2))
        else { return nil }
        defer { vDSP_destroy_fftsetup(setup) }

        let signal = bandpassed(mid)
        let sideSignal = side.count == mid.count && side.contains(where: { $0 != 0 }) ? bandpassed(side) : []
        var segment = Segment(start: start, step: Double(hop) / Double(sampleRate) * rate, f0Hz: [], harmonicity: [])
        segment.f0Hz.reserveCapacity(count)
        segment.harmonicity.reserveCapacity(count)

        signal.withUnsafeBufferPointer { buffer in
            // Two split-complex spectra and the cumulative mean normalized differences.
            let half = YIN.windowSize / 2
            withUnsafeTemporaryAllocation(of: Float.self, capacity: 4 * half + YIN.maxLag + 2) { scratch in
                guard let signalStart = buffer.baseAddress, let work = scratch.baseAddress else { return }
                let yin = YIN(setup: setup, work: work)
                for frame in 0..<count {
                    // Shift boundary windows inward so complete hops meet without gaps across chunks.
                    let offset = min(max(0, frame * hop + hop / 2 - half), buffer.count - YIN.windowSize)
                    let window = signalStart + offset
                    var energy: Float = 0
                    vDSP_svesq(window, 1, &energy, vDSP_Length(YIN.referenceSize))
                    let centre = centreWeight(side: sideSignal, offset: offset, midEnergy: energy)
                    let estimate = yin.estimate(window: window, energy: energy, centre: centre)
                    segment.f0Hz.append(estimate.f0Hz)
                    segment.harmonicity.append(estimate.harmonicity)
                }
            }
        }
        return segment
    }

    private static func bandpassed(_ samples: [Float]) -> [Float] {
        var filter = VoiceBandFilter(sampleRate: Double(sampleRate), low: 80, high: 1200)
        return samples.map { filter.process($0) }
    }

    private static func centreWeight(side: [Float], offset: Int, midEnergy: Float) -> Float {
        guard !side.isEmpty, midEnergy > 0 else { return 1 }
        var energy: Float = 0
        side.withUnsafeBufferPointer { buffer in
            guard let first = buffer.baseAddress else { return }
            vDSP_svesq(first + offset, 1, &energy, vDSP_Length(YIN.referenceSize))
        }
        return max(0, 1 - energy / midEnergy)
    }

    private struct YIN {
        static let fftOrder: vDSP_Length = 9
        static let windowSize = 512
        static let minLag = 16
        static let maxLag = 200
        // An extra lag on either side of a candidate gives the parabolic fit its neighbours.
        static let referenceSize = windowSize - maxLag - 1

        private let setup: FFTSetup
        private let spectrum: DSPSplitComplex
        private let reference: DSPSplitComplex
        private let differences: UnsafeMutablePointer<Float>

        init(setup: FFTSetup, work: UnsafeMutablePointer<Float>) {
            self.setup = setup
            let half = Self.windowSize / 2
            spectrum = DSPSplitComplex(realp: work, imagp: work + half)
            reference = DSPSplitComplex(realp: work + 2 * half, imagp: work + 3 * half)
            differences = work + 4 * half
        }

        func estimate(window: UnsafePointer<Float>, energy: Float, centre: Float) -> (f0Hz: Float, harmonicity: Float) {
            guard energy > Float(Self.referenceSize) * 1e-8, centre > 0 else { return (0, 0) }
            let correlations = correlate(window)
            // Each forward real FFT doubles its spectrum, so the inverse product is scaled by 4N.
            let twiceCorrelationScale = 1 / Float(2 * Self.windowSize)
            var shiftedEnergy = energy
            var sum: Float = 0
            for lag in 1...(Self.maxLag + 1) {
                let outgoing = window[lag - 1]
                let incoming = window[lag + Self.referenceSize - 1]
                shiftedEnergy += incoming * incoming - outgoing * outgoing
                let cross = lag.isMultiple(of: 2) ? correlations.even[lag / 2] : correlations.odd[lag / 2]
                let difference = max(0, energy + shiftedEnergy - cross * twiceCorrelationScale)
                sum += difference
                differences[lag] = sum > 0 ? difference * Float(lag) / sum : 1
            }

            let lag = Self.bestLag(differences)
            guard lag > 0 else { return (0, 0) }
            let before = differences[lag - 1]
            let value = differences[lag]
            let after = differences[lag + 1]
            let curvature = before - 2 * value + after
            let correction = curvature > 0 ? 0.5 * (before - after) / curvature : 0
            let minimum = value - 0.25 * (before - after) * correction
            // Discount weak periodicity in band-limited noise before weighting by the centre energy.
            let harmonicity = min(1, max(0, (0.6 - minimum) / 0.6)) * centre
            guard harmonicity >= voicedThreshold else { return (0, harmonicity) }
            let period = min(Float(Self.maxLag), max(Float(Self.minLag), Float(lag) + correction))
            return (Float(sampleRate) / period, harmonicity)
        }

        private static func bestLag(_ differences: UnsafePointer<Float>) -> Int {
            var best = 0
            for lag in minLag...maxLag {
                let value = differences[lag]
                guard value <= differences[lag - 1], value <= differences[lag + 1]
                else { continue }
                if value < 0.2 { return lag }
                if best == 0 || value < differences[best] { best = lag }
            }
            return best
        }

        /// Cross-correlation of the full window with its zero-padded reference prefix. The lags
        /// we use cannot wrap around. vDSP packs the even and odd output samples into split arrays.
        private func correlate(_ window: UnsafePointer<Float>) -> (even: UnsafeMutablePointer<Float>, odd: UnsafeMutablePointer<Float>) {
            var spectrum = spectrum
            var reference = reference
            let half = Self.windowSize / 2
            let prefix = Self.referenceSize / 2
            window.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                vDSP_ctoz($0, 2, &spectrum, 1, vDSP_Length(half))
            }
            reference.realp.update(from: spectrum.realp, count: prefix + 1)
            reference.imagp.update(from: spectrum.imagp, count: prefix)
            vDSP_vclr(reference.realp + prefix + 1, 1, vDSP_Length(half - prefix - 1))
            vDSP_vclr(reference.imagp + prefix, 1, vDSP_Length(half - prefix))

            vDSP_fft_zrip(setup, &spectrum, 1, Self.fftOrder, FFTDirection(FFT_FORWARD))
            vDSP_fft_zrip(setup, &reference, 1, Self.fftOrder, FFTDirection(FFT_FORWARD))
            // DC and Nyquist share the first slot but are both real and multiply independently.
            reference.realp[0] *= spectrum.realp[0]
            reference.imagp[0] *= spectrum.imagp[0]
            var referenceBins = DSPSplitComplex(realp: reference.realp + 1, imagp: reference.imagp + 1)
            var signalBins = DSPSplitComplex(realp: spectrum.realp + 1, imagp: spectrum.imagp + 1)
            var product = referenceBins
            vDSP_zvmul(&referenceBins, 1, &signalBins, 1, &product, 1, vDSP_Length(half - 1), -1)
            vDSP_fft_zrip(setup, &reference, 1, Self.fftOrder, FFTDirection(FFT_INVERSE))
            return (reference.realp, reference.imagp)
        }
    }
}
