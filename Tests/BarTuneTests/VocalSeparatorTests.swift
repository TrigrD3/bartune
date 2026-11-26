@testable import BarTune
import Foundation
import XCTest

final class VocalSeparatorTests: XCTestCase {
    private final class Separator: VocalIsolating, @unchecked Sendable {
        let separate: ([Float], [Float]) throws -> ([Float], [Float])
        private(set) var calls = 0

        init(separate: @escaping ([Float], [Float]) throws -> ([Float], [Float])) {
            self.separate = separate
        }

        func vocals(left: [Float], right: [Float]) throws -> (left: [Float], right: [Float]) {
            calls += 1
            return try separate(left, right)
        }
    }

    private final class MaskPredictor: VocalMaskPredicting, @unchecked Sendable {
        let windowFrameCount = 8
        let nbBins = SpectralSTFT.nbBins
        private(set) var calls = 0
        var gainForCall: (Int) -> Float = { _ in 1 }
        var mutedCenterBin: Int?

        func predictVocalMagnitude(mixMagnitude: [Float]) -> [Float] {
            XCTAssertEqual(mixMagnitude.count, windowFrameCount * 2 * nbBins)
            calls += 1
            var output = mixMagnitude.map { $0 * gainForCall(calls) }
            if let center = mutedCenterBin {
                for frame in 0..<windowFrameCount {
                    for channel in 0..<2 {
                        for bin in (center - 1)...(center + 1) {
                            output[(frame * 2 + channel) * nbBins + bin] = 0
                        }
                    }
                }
            }
            return output
        }
    }

    func testSTFTRoundTripReconstructsNonAlignedLength() {
        let input = (0..<10317).map { index in
            0.43 * sin(2 * Float.pi * 417 * Float(index) / 44100)
                + 0.19 * cos(2 * Float.pi * 1387 * Float(index) / 44100)
        }
        let stft = SpectralSTFT()
        let spectrum = stft.stft(samples: input)
        let output = stft.istft(real: spectrum.real, imag: spectrum.imag, outputLength: input.count)

        XCTAssertEqual(spectrum.real.count, (input.count / SpectralSTFT.hopLength + 1) * (SpectralSTFT.nFFT / 2 + 1))
        XCTAssertEqual(spectrum.imag.count, spectrum.real.count)
        XCTAssertEqual(spectrum.magnitudes.count, spectrum.real.count)
        XCTAssertEqual(output.count, input.count)
        XCTAssertLessThan(zip(output, input).map { abs($0 - $1) }.max() ?? .infinity, 1e-4)
    }

    func testSpectralMaskAttenuatesBothChannelsWithoutChangingPhase() throws {
        let left = (0..<11317).map { 0.6 * sin(2 * Float.pi * 440 * Float($0) / 44100) }
        let right = (0..<11317).map { 0.35 * cos(2 * Float.pi * 1250 * Float($0) / 44100) }
        let predictor = MaskPredictor()
        predictor.gainForCall = { _ in 0.35 }

        let output = try SpectralVocalSeparator(model: predictor).vocals(left: left, right: right)

        XCTAssertEqual(output.left.count, left.count)
        XCTAssertEqual(output.right.count, right.count)
        // Reflection at the excerpt boundaries introduces energy above the model cutoff.
        let interior = SpectralSTFT.nFFT..<(left.count - SpectralSTFT.nFFT)
        XCTAssertLessThan(interior.map { abs(output.left[$0] - left[$0] * 0.35) }.max() ?? .infinity, 1e-4)
        XCTAssertLessThan(interior.map { abs(output.right[$0] - right[$0] * 0.35) }.max() ?? .infinity, 1e-4)
    }

    func testSpectralMaskRemovesOneFrequencyAndPreservesTheOther() throws {
        let lowBin = 40
        let highBin = 100
        let sampleCount = 32768
        let retained = (0..<sampleCount).map { index in
            0.2 * sin(2 * Float.pi * Float(highBin * index) / Float(SpectralSTFT.nFFT))
        }
        let input = (0..<sampleCount).map { index in
            0.3 * sin(2 * Float.pi * Float(lowBin * index) / Float(SpectralSTFT.nFFT)) + retained[index]
        }
        let predictor = MaskPredictor()
        predictor.mutedCenterBin = lowBin

        let output = try SpectralVocalSeparator(model: predictor).vocals(left: input, right: input)

        let interior = 8192..<24576
        XCTAssertLessThan(interior.map { abs(output.left[$0] - retained[$0]) }.max() ?? .infinity, 1e-4)
        XCTAssertLessThan(interior.map { abs(output.right[$0] - retained[$0]) }.max() ?? .infinity, 1e-4)
    }

    func testSpectralSeparatorCrossfadesWindowsAndKeepsArbitraryOutputLength() throws {
        let left = [Float](repeating: 0.4, count: 30123)
        let right = [Float](repeating: -0.2, count: left.count)
        let predictor = MaskPredictor()
        predictor.gainForCall = { $0.isMultiple(of: 2) ? 0.25 : 1 }

        let output = try SpectralVocalSeparator(model: predictor).vocals(left: left, right: right)

        XCTAssertGreaterThan(predictor.calls, 1)
        XCTAssertEqual(output.left.count, left.count)
        XCTAssertEqual(output.right.count, right.count)
        XCTAssertEqual(output.left[0], 0.4, accuracy: 1e-4)
        XCTAssertTrue(output.left.contains { $0 > 0.15 && $0 < 0.35 })
        XCTAssertLessThan(zip(output.left.dropFirst(), output.left).map { abs($0 - $1) }.max() ?? .infinity, 0.02)
        XCTAssertLessThan(zip(output.right, output.left).map { abs($0 + $1 * 0.5) }.max() ?? .infinity, 1e-4)
    }

    func testRecognitionAudioUsesTheVocalStemWhenAvailable() throws {
        let mid = [Float](repeating: 0.5, count: 44100)
        let side = [Float](repeating: 0.5, count: 44100)
        // Mid and side reconstruct a nonzero left channel and a silent right channel.
        let separator = Separator { _, right in (right, right) }

        let separated = try XCTUnwrap(AudioSyncManager.recognitionAudio(mid: mid, side: side, sampleRate: 44100, separator: separator))
        XCTAssertEqual(separated.sampleRate, 16000)
        XCTAssertNotNil(separated.vocalSeparationSeconds)
        XCTAssertLessThan(try XCTUnwrap(separated.samples.map(abs).max()), 1e-3)

        let full = try XCTUnwrap(AudioSyncManager.recognitionAudio(mid: mid, side: side, sampleRate: 44100, separator: nil))
        XCTAssertEqual(full.sampleRate, 16000)
        XCTAssertEqual(try XCTUnwrap(full.samples.dropFirst(8000).first), 0.5, accuracy: 0.01)
        XCTAssertNil(full.vocalSeparationSeconds)
    }

    func testRecognitionAudioFallsBackForMonoAndFailedSeparation() throws {
        enum SeparationFailure: Error { case test }
        let separator = Separator { _, _ in throw SeparationFailure.test }
        let mid: [Float] = [0.1, 0.2]

        let mono = try XCTUnwrap(AudioSyncManager.recognitionAudio(mid: mid, side: [], sampleRate: 16000, separator: separator))
        XCTAssertEqual(mono.samples, mid)
        XCTAssertEqual(mono.sampleRate, 16000)
        XCTAssertNil(mono.vocalSeparationSeconds)
        XCTAssertEqual(separator.calls, 0)

        let stereo = try XCTUnwrap(AudioSyncManager.recognitionAudio(mid: mid, side: [0.3, 0.4], sampleRate: 16000, separator: separator))
        XCTAssertEqual(stereo.samples, mid)
        XCTAssertEqual(stereo.sampleRate, 16000)
        XCTAssertNil(stereo.vocalSeparationSeconds)
        XCTAssertEqual(separator.calls, 1)
    }

    func testRecognitionAudioResamples48kHzCaptureThroughTheSeparatorTo16kHz() throws {
        let tone = (0..<48000).map { 0.4 * sin(2 * Float.pi * 440 * Float($0) / 48000) }
        let separator = Separator { left, _ in (left, left) }
        let audio = try XCTUnwrap(AudioSyncManager.recognitionAudio(mid: tone, side: tone, sampleRate: 48000, separator: separator))

        let stem = try XCTUnwrap(AudioResampler.resample(tone.map { $0 * 2 }, from: 48000, to: 44100))
        XCTAssertEqual(Double(stem.count), 44100, accuracy: 20)
        let recognition = try XCTUnwrap(AudioResampler.resample(stem, from: 44100, to: 16000))
        XCTAssertEqual(audio.samples, recognition)
        XCTAssertNotNil(audio.vocalSeparationSeconds)
        XCTAssertEqual(audio.sampleRate, 16000)
        XCTAssertEqual(Double(audio.samples.count), 16000, accuracy: 20)
        let crossings = zip(audio.samples.dropLast(), audio.samples.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
        XCTAssertEqual(Double(crossings), 440, accuracy: 3)
        XCTAssertEqual(try XCTUnwrap(audio.samples.dropFirst(100).prefix(1000).max()), 0.8, accuracy: 0.02)
    }

    func testModelInstallRejectsAFileWithTheWrongDigest() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("separator.zip")
        try Data("corrupted model bytes".utf8).write(to: archive)

        XCTAssertThrowsError(try VocalSeparatorModel.install(archive: archive, into: directory)) { error in
            guard case .checksumMismatch? = error as? VocalSeparatorModel.InstallError else {
                return XCTFail("Expected checksumMismatch, received \(error)")
            }
        }
        XCTAssertFalse(VocalSeparatorModel.isInstalled(in: directory))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), [archive.lastPathComponent])
    }

    func testCompiledCacheAloneIsRemovableAndHasNoPackage() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(
            at: directory.appendingPathComponent(VocalSeparatorModel.compiledName),
            withIntermediateDirectories: false
        )

        XCTAssertTrue(VocalSeparatorModel.isInstalled(in: directory))
        XCTAssertFalse(VocalSeparatorModel.hasPackage(in: directory))

        try VocalSeparatorModel.remove(from: directory)

        XCTAssertFalse(VocalSeparatorModel.isInstalled(in: directory))
    }

    func testRemovingSeparatorDeletesBothArtifactsAndKeepsTheAligner() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let alignerArtifacts = [LyricsAlignerModel.packageName, LyricsAlignerModel.compiledName]
        let separatorArtifacts = [VocalSeparatorModel.packageName, VocalSeparatorModel.compiledName]
        for artifact in alignerArtifacts + separatorArtifacts {
            try FileManager.default.createDirectory(at: directory.appendingPathComponent(artifact), withIntermediateDirectories: false)
        }
        XCTAssertTrue(VocalSeparatorModel.isInstalled(in: directory))
        XCTAssertTrue(VocalSeparatorModel.hasPackage(in: directory))

        try VocalSeparatorModel.remove(from: directory)

        XCTAssertFalse(VocalSeparatorModel.isInstalled(in: directory))
        XCTAssertEqual(try Set(FileManager.default.contentsOfDirectory(atPath: directory.path)), Set(alignerArtifacts))
        XCTAssertNoThrow(try VocalSeparatorModel.remove(from: directory))
    }

    func testSeparatorCacheReusesIdenticalModelAndReloadsOnChangeOrInvalidation() {
        let cache = VocalSeparatorModelCache()
        let root = FileManager.default.temporaryDirectory
        let url = root.appendingPathComponent("first.mlmodelc")
        let other = root.appendingPathComponent("second.mlmodelc")
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let later = date.addingTimeInterval(10)
        let first = Separator { ($0, $1) }
        let replacement = Separator { ($0, $1) }

        XCTAssertIdentical(cache.load(compiledURL: url, modificationDate: date) { _ in first }, first)
        XCTAssertIdentical(cache.load(compiledURL: url, modificationDate: date) { _ in replacement }, first)
        XCTAssertIdentical(cache.load(compiledURL: url, modificationDate: later) { _ in replacement }, replacement)
        XCTAssertIdentical(cache.load(compiledURL: other, modificationDate: later) { _ in first }, first)

        cache.invalidate()
        XCTAssertIdentical(cache.load(compiledURL: other, modificationDate: later) { _ in replacement }, replacement)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("bartune-vocal-separator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        return directory
    }
}
