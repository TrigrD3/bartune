import Accelerate
import AVFoundation
import CoreML
import Foundation

/// Separates the lead vocals from a stereo music excerpt.
protocol VocalIsolating: AnyObject, Sendable {
    /// Returns the vocal stem at 44.1 kHz, with the same length as the stereo excerpt.
    func vocals(left: [Float], right: [Float]) throws -> (left: [Float], right: [Float])
}

enum VocalSeparation {
    static let sampleRate = 44100.0
}

protocol VocalMaskPredicting: AnyObject, Sendable {
    var windowFrameCount: Int { get }
    var nbBins: Int { get }
    /// Frame-major stereo magnitudes, with the bins of each channel stored contiguously.
    func predictVocalMagnitude(mixMagnitude: [Float]) throws -> [Float]
}

private enum VocalSeparationError: Error {
    case invalidWindow
    case invalidOutput
}

enum AudioResampler {
    /// Mono `samples` converted from `sourceRate` to `targetRate` with Core Audio's sample rate converter.
    static func resample(_ samples: [Float], from sourceRate: Double, to targetRate: Double) -> [Float]? {
        guard sourceRate.isFinite, targetRate.isFinite, sourceRate > 0, targetRate > 0 else { return nil }
        guard sourceRate != targetRate, !samples.isEmpty else { return samples }
        let outputFrames = (Double(samples.count) * targetRate / sourceRate).rounded(.up)
        guard outputFrames <= Double(AVAudioFrameCount.max - 64),
              let inputFrames = AVAudioFrameCount(exactly: samples.count),
              let source = AVAudioFormat(standardFormatWithSampleRate: sourceRate, channels: 1),
              let target = AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 1),
              let converter = AVAudioConverter(from: source, to: target),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: inputFrames),
              let channel = input.floatChannelData?[0]
        else { return nil }
        converter.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        input.frameLength = inputFrames
        samples.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress { channel.update(from: base, count: buffer.count) }
        }
        let capacity = AVAudioFrameCount(outputFrames) + 64
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
        var supplied = false
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, status in
            if supplied {
                status.pointee = .endOfStream
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard status != .error, error == nil, output.frameLength > 0, let data = output.floatChannelData else { return nil }
        return Array(UnsafeBufferPointer(start: data[0], count: Int(output.frameLength)))
    }
}

/// Centered real FFT matching PyTorch's periodic Hann window and reflect padding.
final class SpectralSTFT {
    static let nFFT = 4096
    static let hopLength = 1024
    static let nbBins = 1487
    static let spectrumBins = nFFT / 2 + 1
    private static let log2FFT: vDSP_Length = 12
    private let setup: FFTSetup
    private let window: [Float]

    init() {
        guard let setup = vDSP_create_fftsetup(Self.log2FFT, FFTRadix(kFFTRadix2)) else {
            preconditionFailure("Could not allocate vocal separator FFT setup.")
        }
        self.setup = setup
        var window = [Float](repeating: 0, count: Self.nFFT)
        vDSP_hann_window(&window, vDSP_Length(Self.nFFT), Int32(vDSP_HANN_DENORM))
        self.window = window
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    struct Spectrum {
        var real: [Float]
        var imag: [Float]

        var magnitudes: [Float] { real.indices.map { magnitude(at: $0) } }

        func magnitude(at index: Int) -> Float {
            let re = real[index]
            let im = imag[index]
            return (re * re + im * im).squareRoot()
        }

        mutating func applyMask(_ vocals: ArraySlice<Float>, frame: Int) {
            let offset = frame * SpectralSTFT.spectrumBins
            for (bin, vocal) in vocals.enumerated() {
                let index = offset + bin
                let scale = min(1, max(0, vocal) / max(magnitude(at: index), 1e-8))
                real[index] *= scale
                imag[index] *= scale
            }
            for bin in vocals.count..<SpectralSTFT.spectrumBins {
                real[offset + bin] = 0
                imag[offset + bin] = 0
            }
        }
    }

    func stft(samples: [Float]) -> Spectrum {
        guard !samples.isEmpty else { return Spectrum(real: [], imag: []) }
        let half = Self.nFFT / 2
        let frameCount = samples.count / Self.hopLength + 1
        let bins = Self.spectrumBins
        var real = [Float](repeating: 0, count: frameCount * bins)
        var imag = real
        var even = [Float](repeating: 0, count: half)
        var odd = even
        for frame in 0..<frameCount {
            let start = frame * Self.hopLength - half
            for index in 0..<half {
                let sample = index * 2
                even[index] = samples[Self.reflect(start + sample, count: samples.count)] * window[sample]
                odd[index] = samples[Self.reflect(start + sample + 1, count: samples.count)] * window[sample + 1]
            }
            fft(real: &even, imag: &odd, direction: FFT_FORWARD)
            let offset = frame * bins
            // vDSP returns twice the unnormalized DFT, with Nyquist packed into the imaginary DC slot.
            real[offset] = even[0] * 0.5
            real[offset + half] = odd[0] * 0.5
            for bin in 1..<half {
                real[offset + bin] = even[bin] * 0.5
                imag[offset + bin] = odd[bin] * 0.5
            }
        }
        return Spectrum(real: real, imag: imag)
    }

    func istft(real: [Float], imag: [Float], outputLength: Int) -> [Float] {
        guard outputLength > 0 else { return [] }
        let half = Self.nFFT / 2
        let bins = Self.spectrumBins
        let frameCount = real.count / bins
        let inverseScale = 1 / Float(Self.nFFT)
        var output = [Float](repeating: 0, count: outputLength)
        var weights = output
        var even = [Float](repeating: 0, count: half)
        var odd = even
        for frame in 0..<frameCount {
            let start = frame * Self.hopLength - half
            if start >= outputLength { break }
            let offset = frame * bins
            even[0] = real[offset]
            odd[0] = real[offset + half]
            for bin in 1..<half {
                even[bin] = real[offset + bin]
                odd[bin] = imag[offset + bin]
            }
            fft(real: &even, imag: &odd, direction: FFT_INVERSE)
            let end = min(Self.nFFT, outputLength - start)
            for sample in max(0, -start)..<end {
                let coefficient = window[sample]
                let value = sample.isMultiple(of: 2) ? even[sample / 2] : odd[sample / 2]
                output[start + sample] += value * inverseScale * coefficient
                weights[start + sample] += coefficient * coefficient
            }
        }
        for index in output.indices where weights[index] > 0 {
            output[index] /= weights[index]
        }
        return output
    }

    private func fft(real: inout [Float], imag: inout [Float], direction: Int) {
        real.withUnsafeMutableBufferPointer { real in
            imag.withUnsafeMutableBufferPointer { imag in
                guard let real = real.baseAddress, let imag = imag.baseAddress else { return }
                var split = DSPSplitComplex(realp: real, imagp: imag)
                vDSP_fft_zrip(setup, &split, 1, Self.log2FFT, FFTDirection(direction))
            }
        }
    }

    private static func reflect(_ index: Int, count: Int) -> Int {
        if (0..<count).contains(index) { return index }
        guard count > 1 else { return 0 }
        // Repeat reflection for excerpts shorter than the half-window.
        let period = 2 * (count - 1)
        let offset = abs(index) % period
        return min(offset, period - offset)
    }
}

final class SpectralVocalSeparator: VocalIsolating {
    private let model: VocalMaskPredicting

    init(model: VocalMaskPredicting) {
        self.model = model
    }

    func vocals(left: [Float], right: [Float]) throws -> (left: [Float], right: [Float]) {
        let window = model.windowFrameCount
        let bins = model.nbBins
        guard window > 0, (1...SpectralSTFT.nbBins).contains(bins), left.count == right.count else {
            throw VocalSeparationError.invalidWindow
        }
        guard !left.isEmpty else { return ([], []) }
        try Task.checkCancellation()
        // Open-Unmix expects full-scale audio. One gain preserves the stereo balance it uses to separate sources.
        let peak = max(vDSP.maximumMagnitude(left), vDSP.maximumMagnitude(right))
        let gain = AudioLevel.normalizationGain(peak: peak)
        let stft = SpectralSTFT()
        var leftSpectrum = stft.stft(samples: gain == 1 ? left : vDSP.multiply(gain, left))
        var rightSpectrum = stft.stft(samples: gain == 1 ? right : vDSP.multiply(gain, right))
        let stride = SpectralSTFT.spectrumBins
        let frameCount = leftSpectrum.real.count / stride
        let overlap = min(16, window / 4)
        let starts = Array(Swift.stride(from: 0, to: max(1, frameCount - overlap), by: window - overlap))
        let frameSize = bins * 2
        var mixture = [Float](repeating: 0, count: window * frameSize)
        var previousTail = [Float]()
        for (index, start) in starts.enumerated() {
            try Task.checkCancellation()
            let count = min(window, frameCount - start)
            for frame in 0..<window {
                let source = (start + frame) * stride
                let offset = frame * frameSize
                for bin in 0..<bins {
                    mixture[offset + bin] = frame < count ? leftSpectrum.magnitude(at: source + bin) : 0
                    mixture[offset + bins + bin] = frame < count ? rightSpectrum.magnitude(at: source + bin) : 0
                }
            }
            var prediction = try model.predictVocalMagnitude(mixMagnitude: mixture)
            guard prediction.count == mixture.count, prediction.allSatisfy(\.isFinite) else {
                throw VocalSeparationError.invalidOutput
            }
            for frame in 0..<(previousTail.count / frameSize) {
                let weight = Float(frame + 1) / Float(overlap + 1)
                let offset = frame * frameSize
                for bin in offset..<(offset + frameSize) {
                    prediction[bin] = previousTail[bin] * (1 - weight) + prediction[bin] * weight
                }
            }
            // Leave the tail unmasked until the following window can read the mixture and blend its prediction.
            let ready = index < starts.count - 1 ? window - overlap : count
            previousTail = Array(prediction[(ready * frameSize)..<(count * frameSize)])
            for frame in 0..<ready {
                let offset = frame * frameSize
                leftSpectrum.applyMask(prediction[offset..<(offset + bins)], frame: start + frame)
                rightSpectrum.applyMask(prediction[(offset + bins)..<(offset + frameSize)], frame: start + frame)
            }
        }
        try Task.checkCancellation()
        let leftStem = stft.istft(real: leftSpectrum.real, imag: leftSpectrum.imag, outputLength: left.count)
        let rightStem = stft.istft(real: rightSpectrum.real, imag: rightSpectrum.imag, outputLength: right.count)
        // The envelope and pitch contour still measure the stem at the original capture level.
        guard gain != 1 else { return (leftStem, rightStem) }
        let inverseGain = 1 / gain
        return (vDSP.multiply(inverseGain, leftStem), vDSP.multiply(inverseGain, rightStem))
    }
}

@available(macOS 14, *)
final class CoreMLVocalMaskModel: VocalMaskPredicting, @unchecked Sendable {
    private let model: MLModel
    private let input: MLMultiArray
    private let inputFeatures: MLDictionaryFeatureProvider
    private let lock = NSLock()
    let windowFrameCount: Int
    let nbBins = SpectralSTFT.nbBins

    init?(compiledModelURL: URL, computeUnits: MLComputeUnits = .cpuAndNeuralEngine) {
        let configuration = MLModelConfiguration()
        // CPU + Neural Engine had the lowest peak RSS on the M3 12-second stereo benchmark.
        configuration.computeUnits = computeUnits
        guard let model = try? MLModel(contentsOf: compiledModelURL, configuration: configuration),
              let constraint = model.modelDescription.inputDescriptionsByName["mix_magnitude"]?.multiArrayConstraint,
              constraint.dataType == .float32,
              let output = model.modelDescription.outputDescriptionsByName["vocal_magnitude"]?.multiArrayConstraint,
              output.dataType == .float32, output.shape == constraint.shape,
              constraint.shape.count == 4, constraint.shape[0].intValue == 1, constraint.shape[1].intValue > 0,
              constraint.shape[2].intValue == 2, constraint.shape[3].intValue == SpectralSTFT.nbBins,
              let input = try? MLMultiArray(shape: constraint.shape, dataType: .float32),
              let features = try? MLDictionaryFeatureProvider(dictionary: ["mix_magnitude": MLFeatureValue(multiArray: input)])
        else { return nil }
        self.model = model
        self.input = input
        inputFeatures = features
        windowFrameCount = constraint.shape[1].intValue
    }

    func predictVocalMagnitude(mixMagnitude: [Float]) throws -> [Float] {
        guard mixMagnitude.count == input.count else { throw VocalSeparationError.invalidWindow }
        return try lock.withLock {
            try Task.checkCancellation()
            input.withUnsafeMutableBufferPointer(ofType: Float.self) { buffer, _ in
                _ = buffer.update(from: mixMagnitude)
            }
            let prediction = try model.prediction(from: inputFeatures)
            guard let output = prediction.featureValue(for: "vocal_magnitude")?.multiArrayValue,
                  output.shape == input.shape, output.dataType == .float32
            else { throw VocalSeparationError.invalidOutput }
            return output.withUnsafeBufferPointer(ofType: Float.self) { buffer in
                let frameStride = output.strides[1].intValue
                let channelStride = output.strides[2].intValue
                let binStride = output.strides[3].intValue
                if frameStride == nbBins * 2, channelStride == nbBins, binStride == 1 {
                    return Array(buffer.prefix(input.count))
                }
                var values = [Float](repeating: 0, count: input.count)
                for frame in 0..<windowFrameCount {
                    for channel in 0..<2 {
                        let start = frame * frameStride + channel * channelStride
                        let offset = (frame * 2 + channel) * nbBins
                        for bin in 0..<nbBins {
                            values[offset + bin] = buffer[start + bin * binStride]
                        }
                    }
                }
                return values
            }
        }
    }
}

typealias VocalSeparatorModelCache = CompiledModelCache<VocalIsolating>

enum VocalSeparatorModel {
    static let packageName = "VocalSeparator.mlpackage"
    static let compiledName = "VocalSeparator.mlmodelc"
    private static let cache = VocalSeparatorModelCache()
    // A removal or install must not race with first-use compilation and move the compiled model back into place.
    private static let modelFilesLock = NSLock()

    static var directory: URL { LyricsAlignerModel.directory }

    /// The quantized SigSep UMX-HQ vocals model, pinned by checksum.
    static let downloadURLString =
        "https://github.com/TrigrD3/bartune/releases/download/vocal-separator-model-1/VocalSeparator.mlpackage.zip"
    static let downloadSHA256 = "36ca301d10ad709b75e916a1232157e6a147a790ad6908314b80c785f10ef7de"
    static let downloadSizeDescription = "5.96 MB"

    typealias InstallError = LyricsAlignerModel.InstallError

    static func download(into directory: URL = directory) async throws {
        guard let url = URL(string: downloadURLString) else { throw InstallError.invalidURL }
        let (archive, response) = try await URLSession.shared.download(from: url)
        defer { try? FileManager.default.removeItem(at: archive) }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw InstallError.httpStatus(http.statusCode)
        }
        try await Task.detached(priority: .utility) {
            try install(archive: archive, into: directory, compile: compileModel)
        }.value
    }

    static func install(
        archive: URL,
        expectedSHA256: String = downloadSHA256,
        into directory: URL,
        compile: ((URL, URL) throws -> Void)? = nil
    ) throws {
        try LyricsAlignerModel.install(
            archive: archive,
            expectedSHA256: expectedSHA256,
            into: directory,
            packageName: packageName,
            compiledName: compiledName,
            lock: modelFilesLock,
            onInstalled: releaseCachedModel,
            compile: compile
        )
    }

    static func isInstalled(in directory: URL = directory) -> Bool {
        hasPackage(in: directory)
            || FileManager.default.fileExists(atPath: directory.appendingPathComponent(compiledName).path)
    }

    static func hasPackage(in directory: URL = directory) -> Bool {
        // A compiled cache may belong to an older separator. Install always retains the source package.
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(packageName).path)
    }

    static func remove(from directory: URL = directory) throws {
        try modelFilesLock.withLock {
            defer { releaseCachedModel() }
            let fileManager = FileManager.default
            for name in [packageName, compiledName] {
                do {
                    try fileManager.removeItem(at: directory.appendingPathComponent(name))
                } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError {
                    continue
                }
            }
        }
    }

    static func releaseCachedModel() {
        cache.invalidate()
    }

    /// Loads the installed separator, compiling on demand for existing packages without a compiled cache.
    static func launch(directory: URL = directory) async -> VocalIsolating? {
        guard #available(macOS 14, *) else { return nil }
        return await Task.detached(priority: .utility) {
            modelFilesLock.withLock { load(in: directory) }
        }.value
    }

    @available(macOS 14, *)
    private static func load(in directory: URL) -> VocalIsolating? {
        let compiled = directory.appendingPathComponent(compiledName)
        let package = directory.appendingPathComponent(packageName)
        let fileManager = FileManager.default
        guard hasPackage(in: directory) else { return nil }
        if !fileManager.fileExists(atPath: compiled.path), (try? compileModel(at: package, to: compiled)) == nil {
            return nil
        }
        let modDate = (try? fileManager.attributesOfItem(atPath: compiled.path))?[.modificationDate] as? Date
        return cache.load(compiledURL: compiled, modificationDate: modDate) {
            CoreMLVocalMaskModel(compiledModelURL: $0).map(SpectralVocalSeparator.init)
        }
    }

    private static func compileModel(at package: URL, to destination: URL) throws {
        let temporary = try MLModel.compileModel(at: package)
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.moveItem(at: temporary, to: destination)
    }
}
