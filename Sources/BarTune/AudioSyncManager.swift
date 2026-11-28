import Accelerate
import AppKit
import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

enum SystemAudioCapturePermission: Equatable, Sendable {
    case unknown
    case granted
    case denied
}

/// One delivery of captured player audio.
struct CapturedAudio: Sendable {
    /// Mono mix of all channels.
    let samples: [Float]
    /// Half the left-minus-right difference per frame; empty for mono audio.
    var side: [Float] = []
    let sampleRate: Double
    /// Seconds the first sample was captured before this delivery, from the buffer's presentation timestamp.
    var captureDelay: Double?
    /// Monotonic capture timestamp (`ProcessInfo.processInfo.systemUptime` domain) measured before extraction.
    var capturedAt: Double?
    /// Preceding frames were dropped by capture, even if their duration is below the gap tolerance.
    var startsNewSpan = false

    func firstSampleUptime(deliveredAt: Double) -> Double {
        capturedAt ?? (deliveredAt - (captureDelay ?? 0))
    }

    func trimmingBefore(_ boundary: Double, deliveredAt: Double) -> CapturedAudio? {
        // A callback already queued for the main actor at the seek contains only old audio.
        guard deliveredAt > boundary else { return nil }
        let start = firstSampleUptime(deliveredAt: deliveredAt)
        guard start < boundary else { return self }

        guard sampleRate > 0, !samples.isEmpty,
              start + Double(samples.count - 1) / sampleRate >= boundary
        else { return nil }
        var count = Int((boundary - start) * sampleRate)
        // Compare in the timestamp domain so rounding cannot discard a frame exactly at the boundary.
        if start + Double(count) / sampleRate < boundary { count += 1 }
        let retainedStart = start + Double(count) / sampleRate
        return CapturedAudio(
            samples: Array(samples.dropFirst(count)),
            side: Array(side.dropFirst(count)),
            sampleRate: sampleRate,
            captureDelay: max(0, deliveredAt - retainedStart),
            capturedAt: retainedStart,
            startsNewSpan: startsNewSpan
        )
    }
}

protocol AudioCaptureProviding: AnyObject {
    var onAudioSamples: (@Sendable (CapturedAudio) -> Void)? { get set }
    var onCaptureFailure: (@Sendable (Error) -> Void)? { get set }
    @MainActor func start(targetBundleIds: Set<String>, sampleRate: Int) async throws
    @MainActor func stop()
}

extension AudioCaptureProviding {
    /// Backends that only report errors from start do not need to retain a failure handler.
    var onCaptureFailure: (@Sendable (Error) -> Void)? {
        get { nil }
        set { _ = newValue }
    }
}

enum AudioLevel {
    /// Scales a chunk so its peak reaches 0.95. Capture follows the player's volume, and a quiet
    /// player leaves too little signal for recognition. Near-silence is left as is so its noise isn't amplified.
    static func normalizedForRecognition(_ samples: [Float], maxGain: Float = 100) -> [Float] {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        let gain = normalizationGain(peak: peak, maxGain: maxGain)
        return gain == 1 ? samples : samples.map { $0 * gain }
    }

    static func normalizationGain(peak: Float, maxGain: Float = 100) -> Float {
        guard peak.isFinite, peak > 0.0001, maxGain.isFinite, maxGain > 0 else { return 1 }
        let gain = min(0.95 / peak, maxGain)
        // The vocal separator also needs a representable inverse to restore the capture level.
        return gain.isFinite && gain > 0 && (1 / gain).isFinite ? gain : 1
    }
}

enum AudioSampleExtractor {
    /// Mono mix and side signal of one or more equal-length channels.
    static func midSide(channels: [[Float]]) -> (mid: [Float], side: [Float]) {
        guard let first = channels.first else { return ([], []) }
        let count = channels.map(\.count).min() ?? 0
        guard channels.count > 1 else { return (Array(first.prefix(count)), []) }
        guard count > 0 else { return ([], []) }
        var mid = [Float](repeating: 0, count: count)
        var side = [Float](repeating: 0, count: count)
        let n = vDSP_Length(count)
        var half: Float = 0.5
        if channels.count == 2 {
            vDSP_vadd(channels[0], 1, channels[1], 1, &mid, 1, n)
            vDSP_vsmul(mid, 1, &half, &mid, 1, n)
            vDSP_vsub(channels[1], 1, channels[0], 1, &side, 1, n)
            vDSP_vsmul(side, 1, &half, &side, 1, n)
            return (mid, side)
        }
        var scale = 1 / Float(channels.count)
        for channel in channels {
            vDSP_vadd(mid, 1, channel, 1, &mid, 1, n)
        }
        vDSP_vsmul(mid, 1, &scale, &mid, 1, n)
        vDSP_vsub(channels[1], 1, channels[0], 1, &side, 1, n)
        vDSP_vsmul(side, 1, &half, &side, 1, n)
        return (mid, side)
    }

    /// Splits `channelCount`-way interleaved samples into one array per channel.
    static func deinterleave(_ samples: [Float], channelCount: Int) -> [[Float]] {
        guard channelCount > 1 else { return [samples] }
        let frames = samples.count / channelCount
        guard frames > 0 else { return Array(repeating: [], count: channelCount) }
        let stride = Int32(channelCount)
        let n = Int32(frames)
        return samples.withUnsafeBufferPointer { source in
            guard let base = source.baseAddress else { return Array(repeating: [], count: channelCount) }
            return (0..<channelCount).map { channel in
                var output = [Float](repeating: 0, count: frames)
                output.withUnsafeMutableBufferPointer { destination in
                    if let dst = destination.baseAddress {
                        cblas_scopy(n, base.advanced(by: channel), stride, dst, 1)
                    }
                }
                return output
            }
        }
    }

    /// Every channel of a captured audio buffer, as Float samples; empty for unsupported formats.
    static func extractChannels(from sampleBuffer: CMSampleBuffer, asbd: AudioStreamBasicDescription) -> [[Float]] {
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        guard (isFloat && asbd.mBitsPerChannel == 32) || (!isFloat && asbd.mBitsPerChannel == 16) else { return [] }
        var sizeNeeded = 0
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: nil
        ) == noErr, sizeNeeded > 0 else { return [] }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retained: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: list,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment,
            blockBufferOut: &retained
        ) == noErr else { return [] }

        var channels: [[Float]] = []
        for buffer in UnsafeMutableAudioBufferListPointer(list) {
            guard let data = buffer.mData else { continue }
            let samples: [Float]
            if isFloat {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
                samples = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: count))
            } else {
                let count = Int(buffer.mDataByteSize) / MemoryLayout<Int16>.size
                samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Int16.self), count: count).map { Float($0) / 32768.0 }
            }
            channels.append(contentsOf: deinterleave(samples, channelCount: max(1, Int(buffer.mNumberChannels))))
        }
        return channels
    }

    /// Seconds a buffer stamped `presentation` (host clock) is older than `hostNow`; nil when the stamp
    /// isn't plausible for live capture.
    static func captureDelay(presentation: Double, hostNow: Double) -> Double? {
        let delay = hostNow - presentation
        return (0...1).contains(delay) ? delay : nil
    }

    static func extractMonoSamples(
        from blockBuffer: CMBlockBuffer,
        asbd: AudioStreamBasicDescription
    ) -> [Float] {
        let totalLength = CMBlockBufferGetDataLength(blockBuffer)
        guard totalLength > 0 else { return [] }

        let channelCount = max(1, Int(asbd.mChannelsPerFrame))
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        if isFloat && asbd.mBitsPerChannel == 32 {
            let totalFloats = totalLength / MemoryLayout<Float>.size
            guard totalFloats > 0 else { return [] }
            let byteCount = totalFloats * MemoryLayout<Float>.size
            var rawFloats = [Float](repeating: 0, count: totalFloats)
            let copyStatus = rawFloats.withUnsafeMutableBytes { dest -> OSStatus in
                guard let base = dest.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteCount, destination: base)
            }
            guard copyStatus == kCMBlockBufferNoErr else { return [] }

            if channelCount == 1 {
                return rawFloats
            }
            if isNonInterleaved {
                let frameCount = totalFloats / channelCount
                return Array(rawFloats.prefix(frameCount))
            }

            let frameCount = totalFloats / channelCount
            var monoSamples: [Float] = []
            monoSamples.reserveCapacity(frameCount)
            for f in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += rawFloats[f * channelCount + ch]
                }
                monoSamples.append(sum / Float(channelCount))
            }
            return monoSamples
        } else if !isFloat && asbd.mBitsPerChannel == 16 {
            let totalInt16 = totalLength / MemoryLayout<Int16>.size
            guard totalInt16 > 0 else { return [] }
            let byteCount = totalInt16 * MemoryLayout<Int16>.size
            var rawInts = [Int16](repeating: 0, count: totalInt16)
            let copyStatus = rawInts.withUnsafeMutableBytes { dest -> OSStatus in
                guard let base = dest.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
                return CMBlockBufferCopyDataBytes(blockBuffer, atOffset: 0, dataLength: byteCount, destination: base)
            }
            guard copyStatus == kCMBlockBufferNoErr else { return [] }

            if isNonInterleaved || channelCount == 1 {
                let frameCount = isNonInterleaved ? (totalInt16 / channelCount) : totalInt16
                return rawInts.prefix(frameCount).map { Float($0) / 32768.0 }
            }

            let frameCount = totalInt16 / channelCount
            var monoSamples: [Float] = []
            monoSamples.reserveCapacity(frameCount)
            for f in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += Float(rawInts[f * channelCount + ch]) / 32768.0
                }
                monoSamples.append(sum / Float(channelCount))
            }
            return monoSamples
        }
        return []
    }
}

enum SystemAudioCaptureError: LocalizedError, Equatable {
    case noDisplayAvailable
    case unresolvedPlayer

    var errorDescription: String? {
        switch self {
        case .noDisplayAvailable:
            return "No display available for system audio capture."
        case .unresolvedPlayer:
            return "Could not find the active media player for isolated audio capture."
        }
    }
}

struct CaptureApplication: @unchecked Sendable {
    let bundleIdentifier: String
    fileprivate let scApplication: SCRunningApplication?

    init(bundleIdentifier: String, scApplication: SCRunningApplication? = nil) {
        self.bundleIdentifier = bundleIdentifier
        self.scApplication = scApplication
    }
}

struct CaptureDisplay: @unchecked Sendable {
    fileprivate let scDisplay: SCDisplay?

    init(scDisplay: SCDisplay? = nil) {
        self.scDisplay = scDisplay
    }
}

struct CaptureShareableSnapshot: Sendable {
    let displays: [CaptureDisplay]
    let applications: [CaptureApplication]
}

protocol SystemAudioStreamControlling: AnyObject, Sendable {
    func stopCapture() async
}

protocol SystemAudioCaptureBackend: Sendable {
    func fetchShareableContent() async throws -> CaptureShareableSnapshot
    @MainActor
    func startStream(
        display: CaptureDisplay,
        includedApplications: [CaptureApplication],
        output: AudioCaptureStreamOutput,
        audioQueue: DispatchQueue,
        sampleRate: Int
    ) async throws -> SystemAudioStreamControlling
}

private final class LiveSCStreamHandle: SystemAudioStreamControlling, @unchecked Sendable {
    private let stream: SCStream

    init(stream: SCStream) {
        self.stream = stream
    }

    func stopCapture() async {
        try? await stream.stopCapture()
    }
}

private struct LiveSystemAudioCaptureBackend: SystemAudioCaptureBackend {
    func fetchShareableContent() async throws -> CaptureShareableSnapshot {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        return CaptureShareableSnapshot(
            displays: content.displays.map { CaptureDisplay(scDisplay: $0) },
            applications: content.applications.map {
                CaptureApplication(bundleIdentifier: $0.bundleIdentifier, scApplication: $0)
            }
        )
    }

    @MainActor
    func startStream(
        display: CaptureDisplay,
        includedApplications: [CaptureApplication],
        output: AudioCaptureStreamOutput,
        audioQueue: DispatchQueue,
        sampleRate: Int
    ) async throws -> SystemAudioStreamControlling {
        guard let scDisplay = display.scDisplay else {
            throw SystemAudioCaptureError.noDisplayAvailable
        }
        let scApps = includedApplications.compactMap(\.scApplication)
        guard !scApps.isEmpty else {
            throw SystemAudioCaptureError.unresolvedPlayer
        }

        let scFilter = SCContentFilter(display: scDisplay, including: scApps, exceptingWindows: [])
        let config = SystemAudioCapture.makeStreamConfiguration(sampleRate: sampleRate)

        let newStream = SCStream(filter: scFilter, configuration: config, delegate: nil)
        try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)
        try await newStream.startCapture()
        return LiveSCStreamHandle(stream: newStream)
    }
}

/// Coalesces frequent audio callbacks on the capture worker into coarser batches
/// (~200 ms) to reduce MainActor wakeups without distorting capture timestamps or gap detection.
struct AudioCaptureBatcher {
    let targetDuration: Double
    private var samples: [Float] = []
    private var side: [Float] = []
    private var sampleRate: Double = 0
    private var firstCapturedAt: Double?
    private var firstCaptureDelay: Double?
    private var hasSide = false
    private var startsNewSpan = false

    init(targetDuration: Double = 0.20) {
        self.targetDuration = targetDuration
    }

    mutating func append(_ audio: CapturedAudio, deliveryUptime: Double = ProcessInfo.processInfo.systemUptime) -> [CapturedAudio] {
        guard !audio.samples.isEmpty, audio.sampleRate > 0 else { return [] }
        let incomingHasSide = audio.side.count == audio.samples.count
        var ready: [CapturedAudio] = []

        if !samples.isEmpty {
            let rateChanged = abs(audio.sampleRate - sampleRate) > 0.5
            let sideChanged = incomingHasSide != hasSide
            let gapDetected: Bool = if let firstAt = firstCapturedAt, let nextAt = audio.capturedAt {
                abs(nextAt - (firstAt + Double(samples.count) / sampleRate)) > 0.05
            } else {
                false
            }
            if rateChanged || sideChanged || gapDetected || audio.startsNewSpan,
               let flushed = flush(deliveryUptime: deliveryUptime) {
                ready.append(flushed)
            }
        }

        if samples.isEmpty {
            sampleRate = audio.sampleRate
            firstCapturedAt = audio.capturedAt
            firstCaptureDelay = audio.captureDelay
            hasSide = incomingHasSide
            startsNewSpan = audio.startsNewSpan
            let targetSamples = max(audio.samples.count, Int((audio.sampleRate * targetDuration).rounded()))
            samples.reserveCapacity(targetSamples)
            if incomingHasSide {
                side.reserveCapacity(targetSamples)
            }
        }

        samples.append(contentsOf: audio.samples)
        if hasSide {
            side.append(contentsOf: audio.side)
        }

        if Double(samples.count) / sampleRate >= targetDuration, let flushed = flush(deliveryUptime: deliveryUptime) {
            ready.append(flushed)
        }
        return ready
    }

    mutating func flush(deliveryUptime: Double = ProcessInfo.processInfo.systemUptime) -> CapturedAudio? {
        guard !samples.isEmpty else { return nil }
        let out = CapturedAudio(
            samples: samples,
            side: hasSide ? side : [],
            sampleRate: sampleRate,
            captureDelay: firstCapturedAt.map { max(firstCaptureDelay ?? 0, deliveryUptime - $0) } ?? firstCaptureDelay,
            capturedAt: firstCapturedAt,
            startsNewSpan: startsNewSpan
        )
        samples.removeAll(keepingCapacity: false)
        side.removeAll(keepingCapacity: false)
        sampleRate = 0
        firstCapturedAt = nil
        firstCaptureDelay = nil
        hasSide = false
        startsNewSpan = false
        return out
    }
}

final class SystemAudioCapture: AudioCaptureProviding, @unchecked Sendable {
    private let callbackLock = NSLock()
    private var _onAudioSamples: (@Sendable (CapturedAudio) -> Void)?
    var onAudioSamples: (@Sendable (CapturedAudio) -> Void)? {
        get {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            return _onAudioSamples
        }
        set {
            callbackLock.lock()
            defer { callbackLock.unlock() }
            _onAudioSamples = newValue
        }
    }

    private let backend: SystemAudioCaptureBackend
    @MainActor private var stream: SystemAudioStreamControlling?
    @MainActor private var sessionID: UInt64 = 0
    private let audioQueue = DispatchQueue(label: "com.arya.bartune.audiocapture", qos: .utility)
    @MainActor private var streamOutput: AudioCaptureStreamOutput?

    static func makeStreamConfiguration(sampleRate: Int = 16000) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = sampleRate
        // Stereo lets the vocal envelope weigh the centre of the mix; recognition gets the mono mix.
        config.channelCount = 2
        // Minimal video footprint since we only consume audio buffers; a long frame interval avoids
        // waking WindowServer/replayd for 1 FPS video readbacks.
        config.width = 2
        config.height = 2
        config.showsCursor = false
        config.queueDepth = 3
        config.minimumFrameInterval = CMTime(value: 600, timescale: 1)
        return config
    }

    init(backend: SystemAudioCaptureBackend = LiveSystemAudioCaptureBackend()) {
        self.backend = backend
    }

    static func resolveTargetApplications(
        in snapshot: CaptureShareableSnapshot,
        targetBundleIds: Set<String>
    ) -> [CaptureApplication] {
        guard !targetBundleIds.isEmpty else { return [] }
        return snapshot.applications.filter { targetBundleIds.contains($0.bundleIdentifier) }
    }

    @MainActor
    func start(targetBundleIds: Set<String> = [], sampleRate: Int = 16000) async throws {
        stop()
        sessionID &+= 1
        let currentSession = sessionID

        guard !targetBundleIds.isEmpty else {
            throw SystemAudioCaptureError.unresolvedPlayer
        }

        let content = try await backend.fetchShareableContent()
        guard sessionID == currentSession else { return }
        guard let display = content.displays.first else {
            throw SystemAudioCaptureError.noDisplayAvailable
        }

        let includedApps = Self.resolveTargetApplications(in: content, targetBundleIds: targetBundleIds)
        guard !includedApps.isEmpty else {
            throw SystemAudioCaptureError.unresolvedPlayer
        }

        let output = AudioCaptureStreamOutput(onAudioSamples: onAudioSamples)
        streamOutput = output
        let newStream: SystemAudioStreamControlling
        do {
            newStream = try await backend.startStream(
                display: display,
                includedApplications: includedApps,
                output: output,
                audioQueue: audioQueue,
                sampleRate: sampleRate
            )
        } catch {
            if streamOutput === output {
                streamOutput = nil
            }
            audioQueue.async { output.retire() }
            throw error
        }

        guard sessionID == currentSession else {
            await newStream.stopCapture()
            return
        }

        stream = newStream
    }

    @MainActor
    func stop() {
        sessionID &+= 1
        if let output = streamOutput {
            streamOutput = nil
            audioQueue.async { output.retire() }
        }
        guard let activeStream = stream else { return }
        stream = nil
        Task {
            await activeStream.stopCapture()
        }
    }
}

/// One output per stream. All callbacks and retirement run on the serial audio queue.
final class AudioCaptureStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
    private var batcher = AudioCaptureBatcher()
    private var onAudioSamples: (@Sendable (CapturedAudio) -> Void)?

    init(onAudioSamples: (@Sendable (CapturedAudio) -> Void)?) {
        self.onAudioSamples = onAudioSamples
    }

    func retire() {
        onAudioSamples = nil
        _ = batcher.flush()
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard onAudioSamples != nil, type == .audio, sampleBuffer.isValid else { return }
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return }

        let asbd = asbdPtr.pointee
        let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 16000.0
        let uptimeNow = ProcessInfo.processInfo.systemUptime
        let hostNow = CMClockGetTime(CMClockGetHostTimeClock()).seconds
        let presentation = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let delay = presentation.isNumeric
            ? AudioSampleExtractor.captureDelay(presentation: presentation.seconds, hostNow: hostNow)
            : nil
        let capturedAt = uptimeNow - (delay ?? 0)

        var (mid, side) = AudioSampleExtractor.midSide(
            channels: AudioSampleExtractor.extractChannels(from: sampleBuffer, asbd: asbd)
        )
        if mid.isEmpty, let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) {
            mid = AudioSampleExtractor.extractMonoSamples(from: blockBuffer, asbd: asbd)
            side = []
        }
        guard !mid.isEmpty else { return }
        let captured = CapturedAudio(samples: mid, side: side, sampleRate: sampleRate, captureDelay: delay, capturedAt: capturedAt)
        append(captured)
    }

    func append(_ captured: CapturedAudio) {
        guard let onAudioSamples else { return }
        for batch in batcher.append(captured) {
            onAudioSamples(batch)
        }
    }
}

protocol AudioChunkTranscribing: AnyObject, Sendable {
    func transcribe(_ request: AudioSyncManager.AudioChunkRequest) async throws -> [RecognizedAudioWord]
    func shutdown()
    /// Audio from a non-final request is still held back waiting for right context.
    var hasHeldAudio: Bool { get }
    /// Aligns held-back audio when its run ends without a final request. `continuesAfterGap`: a capture gap,
    /// not the track's end, ends the run, so lines missed at its edge stay eligible for the next span.
    func finishRun(continuesAfterGap: Bool) throws -> [RecognizedAudioWord]
}

extension AudioChunkTranscribing {
    var hasHeldAudio: Bool { false }

    // swiftlint:disable:next unneeded_throws_rethrows
    func finishRun(continuesAfterGap _: Bool) throws -> [RecognizedAudioWord] {
        []
    }
}

@MainActor
final class AudioSyncManager {
    struct Dependencies {
        var capture: AudioCaptureProviding
        var cacheQueue = DispatchQueue(label: "com.arya.bartune.audiosynccache", qos: .utility)
        var hasScreenCaptureAccess: () -> Bool
        var requestScreenCaptureAccess: () -> Void
        var chunkDurationSeconds: Double
        var usesProcessTap: Bool = false
        var sustainedSilenceThreshold: Double = 6.0
        var launchLyricsAligner: @Sendable (
            _ lines: [LyricLine],
            _ anchors: [Int: ClosedRange<Double>]
        ) async -> AudioChunkTranscribing? = {
            await LyricsAlignerModel.launch(lines: $0, anchors: $1)
        }
        var launchLyricsAlignerWithPriors: (
            @Sendable (
                _ lines: [LyricLine],
                _ anchors: [Int: ClosedRange<Double>],
                _ priorLines: [Int: LyricLine]
            ) async -> AudioChunkTranscribing?
        )?
        var launchVocalSeparator: @Sendable () async -> VocalIsolating? = { await VocalSeparatorModel.launch() }
        var resampleForRecognition: @Sendable ([Float], Double, Double) -> [Float]? = {
            AudioResampler.resample($0, from: $1, to: $2)
        }
        var vocalEnvelopeNow: @Sendable () -> ContinuousClock.Instant = { .now }
        var vocalEnvelopeSleep: @Sendable (ContinuousClock.Instant) async throws -> Void = {
            try await Task.sleep(until: $0, clock: .continuous)
        }
        var releaseCachedModel: @Sendable () -> Void = { LyricsAlignerModel.releaseCachedModel() }
        var releaseCachedVocalSeparator: @Sendable () -> Void = { VocalSeparatorModel.releaseCachedModel() }
        var idleModelReleaseDelay: Duration = .seconds(60)
        var idleModelReleaseSleep: @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }
        var noAudioWatchdogSleep: @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }

        static func live() -> Dependencies {
            let launchWithPriors: @Sendable ([LyricLine], [Int: ClosedRange<Double>], [Int: LyricLine]) async -> AudioChunkTranscribing? = {
                await LyricsAlignerModel.launch(lines: $0, anchors: $1, priorLines: $2)
            }
            if #available(macOS 14.2, *) {
                return Dependencies(
                    capture: ProcessTapAudioCapture(),
                    hasScreenCaptureAccess: { true },
                    requestScreenCaptureAccess: {},
                    chunkDurationSeconds: 12.0,
                    usesProcessTap: true,
                    launchLyricsAlignerWithPriors: launchWithPriors
                )
            }
            return Dependencies(
                capture: SystemAudioCapture(),
                hasScreenCaptureAccess: { CGPreflightScreenCaptureAccess() },
                requestScreenCaptureAccess: { CGRequestScreenCaptureAccess() },
                chunkDurationSeconds: 12.0,
                usesProcessTap: false,
                launchLyricsAlignerWithPriors: launchWithPriors
            )
        }
    }

    private let state: LyricsState
    private let cache: AudioSyncedLyricsCache
    private let dependencies: Dependencies
    let diagnostics: AudioSyncDiagnosticsModel
    private var capture: AudioCaptureProviding { dependencies.capture }

    private var activeTrackId: String?
    private var activeSourceBundleId: String?
    private var baseLines: [LyricLine] = []
    /// Lines matched by the partial cached record this session started from; weaker live results don't replace it.
    private var cachedAlignedLineCount = 0
    /// Words heard on earlier plays of a partially synced track.
    private var priorHeardWords: [RecognizedAudioWord] = []
    /// Lyrics Alignment lines locked on an earlier play, by line ID: kept as they are, never realigned.
    private var anchoredLines: [Int: LyricLine] = [:]
    /// Lyrics Alignment lines locked on this play: confident alignments, kept as they are from then on.
    private var lockedThisPlay: [Int: LyricLine] = [:]
    /// Unlocked lines heard since the locked set last grew, carried over from the record when it didn't.
    private var attemptedLineIDs: Set<Int> = []
    /// Attempts made in this play, distinct from settled attempts loaded from an earlier record.
    private var attemptedThisPlay: Set<Int> = []
    /// Lines the engine aligned confidently on this play.
    private var confidentLineIDs: Set<Int> = []
    /// Lines aligned just below that on this play; they lock on a vocal onset.
    private var nearlyConfidentLineIDs: Set<Int> = []
    private var acceptedSessionLines: [Int: LyricLine] = [:]
    private var priorUnlockedLines: [Int: LyricLine] = [:]
    private var cachedChromaTemplates: [ChorusSelfSimilarity.CachedTemplate] = []
    private var activeTrackDuration: Double = 0
    private(set) var recognizedWords: [RecognizedAudioWord] = []
    /// Voice-band loudness of this play's captured audio, used to refine heard word timings.
    private(set) var vocalEnvelope = VocalEnvelope()
    private(set) var vocalPitchContour = VocalPitchContour()
    private var vocalEnvelopeCache = LRUMemoryCache<VocalEnvelope>(capacity: 12)
    private var vocalEnvelopeRevision: UInt64 = 0
    private var cachedDisplayEnvelope: (trackId: String, revision: UInt64, envelope: VocalEnvelope?)?
    private let vocalEnvelopeDidChangeSubject = PassthroughSubject<String, Never>()
    private var nextVocalEnvelopeNotifyAt = ContinuousClock.now
    private var pendingVocalEnvelopeNotification: Task<Void, Never>?

    var vocalEnvelopeDidChange: AnyPublisher<String, Never> {
        vocalEnvelopeDidChangeSubject.eraseToAnyPublisher()
    }

    private func notifyVocalEnvelopeChanged(for trackId: String, throttled: Bool) {
        let now = dependencies.vocalEnvelopeNow()
        let deadline = nextVocalEnvelopeNotifyAt
        if throttled, now < deadline {
            guard pendingVocalEnvelopeNotification == nil else { return }
            let sleepUntil = dependencies.vocalEnvelopeSleep
            pendingVocalEnvelopeNotification = Task { [weak self] in
                try? await sleepUntil(deadline)
                guard !Task.isCancelled, let self, self.activeTrackId == trackId else { return }
                self.notifyVocalEnvelopeChanged(for: trackId, throttled: false)
            }
            return
        }
        pendingVocalEnvelopeNotification?.cancel()
        pendingVocalEnvelopeNotification = nil
        nextVocalEnvelopeNotifyAt = now.advanced(by: .milliseconds(200))
        vocalEnvelopeDidChangeSubject.send(trackId)
    }

    func vocalEnvelope(for trackId: String?) -> VocalEnvelope? {
        if let trackId, trackId == activeTrackId {
            if let cached = cachedDisplayEnvelope,
               cached.trackId == trackId,
               cached.revision == vocalEnvelopeRevision {
                return cached.envelope
            }
            let merged = VocalEnvelope.mergedForDisplay(cached: vocalEnvelopeCache[trackId], live: vocalEnvelope)
            cachedDisplayEnvelope = (trackId, vocalEnvelopeRevision, merged)
            return merged
        }
        guard let trackId else { return vocalEnvelope.segments.isEmpty ? nil : vocalEnvelope }
        return VocalEnvelope.mergedForDisplay(cached: vocalEnvelopeCache[trackId], live: VocalEnvelope())
    }
    private(set) var isLiveSyncActive: Bool = false
    private(set) var isCaptureRunning: Bool = false
    private var syncGeneration: UInt64 = 0
    private var captureTargetGeneration: UInt64 = 0
    private var captureStartAccepted = false

    private static let seekTolerance: Double = 2.0
    /// The first poll after a repeat may arrive a few playback seconds into the new play.
    private static let restartWindow: Double = 4.0
    /// Audio this close to the track's end is sent as its final chunk, before the player moves on.
    static let trackEndMargin: Double = 1.0

    // Audio chunk state
    private var audioSampleBuffer: [Float] = []
    /// Stereo side samples for the contiguous suffix of the mid buffer after any mono delivery.
    private var audioSideBuffer: [Float] = []
    /// Sample offsets and track times for contiguous capture spans in the buffer.
    private var captureSpanStarts: [(offset: Int, time: Double, followsDrop: Bool)] = []
    private var chunkStartPos: Double? { captureSpanStarts.first?.time }
    private var chunkPlaybackRate: Double = 1.0
    private var pendingSeekPos: Double?
    /// The audio up to the track's end was sent; reset by a seek, which can reach the end again.
    private var sentFinalChunk = false
    /// Uptime of the last detected seek; deliveries captured before it hold pre-seek audio.
    private var seekBoundary: TimeInterval = 0
    /// Last playback state this manager saw; seeks are detected against it because `LyricsState` is updated first.
    private var lastPlayback: (position: Double, uptime: TimeInterval, rate: Double, isPlaying: Bool)?
    private struct ChunkOutcome: Sendable {
        let words: [RecognizedAudioWord]
        let pitch: VocalPitchContour.Segment?
        let chroma: AudioChromaProfile
    }

    private var cacheLoadTask: Task<Void, Never>?
    private var alignerStartupTask: Task<Void, Never>?
    private var chunkProcessingTask: Task<ChunkOutcome?, Never>?
    private var pendingTailFinalizations: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var modelIdleReleaseTask: Task<Void, Never>?
    private var noAudioWatchdogTask: Task<Void, Never>?
    private var noAudioObservationStartedAt: TimeInterval?
    private var modelMayBeCached = false
    private var chunkEngine: AudioChunkTranscribing?
    private var vocalSeparator: VocalIsolating?
    private var activeSampleRate: Double = 16000.0
    private var chromaProfile = AudioChromaProfile()
    private var capturedSeconds: Double = 0
    private var hasReceivedAudibleAudioThisSession = false
    private var consecutiveSilentSeconds: Double = 0
    private var silencePermissionFlagged = false
    private var chunkDurationSeconds: Double { dependencies.chunkDurationSeconds }

    var bufferedSampleCount: Int { audioSampleBuffer.count }
    var currentChunkStartPos: Double? { chunkStartPos }
    var isChunkProcessing: Bool { chunkProcessingTask != nil }

    init(
        state: LyricsState,
        cache: AudioSyncedLyricsCache = .default,
        dependencies: Dependencies = .live(),
        diagnostics: AudioSyncDiagnosticsModel? = nil
    ) {
        self.state = state
        self.cache = cache
        self.dependencies = dependencies
        self.diagnostics = diagnostics ?? AudioSyncDiagnosticsModel()
        self.nextVocalEnvelopeNotifyAt = dependencies.vocalEnvelopeNow()
    }

    func flushCacheOperations() async {
        // Wait for any outgoing-track tail finalizations so their cache saves are queued first.
        let tailTasks = pendingTailFinalizations.values.map(\.task)
        for task in tailTasks {
            await task.value
        }
        // Applying a cache load can enqueue a removal of its own.
        await cacheLoadTask?.value
        await withCheckedContinuation { continuation in
            dependencies.cacheQueue.async { continuation.resume() }
        }
    }

    private func removeCachedAlignment(trackId: String) {
        dependencies.cacheQueue.async { [cache] in
            cache.remove(trackId: trackId)
        }
    }

    private func cacheActiveVocalEnvelopeIfNonEmpty() {
        guard let prevId = activeTrackId, !vocalEnvelope.segments.isEmpty else { return }
        if let merged = VocalEnvelope.mergedPreservingCaptureOrder(cached: vocalEnvelopeCache[prevId], live: vocalEnvelope) {
            vocalEnvelopeCache[prevId] = merged
            vocalEnvelopeRevision &+= 1
            cachedDisplayEnvelope = nil
            notifyVocalEnvelopeChanged(for: prevId, throttled: false)
        }
    }

    private func scheduleIdleModelReleaseIfNeeded() {
        guard modelMayBeCached, modelIdleReleaseTask == nil else { return }
        let delay = dependencies.idleModelReleaseDelay
        let sleepFor = dependencies.idleModelReleaseSleep
        let release = dependencies.releaseCachedModel
        let releaseSeparator = dependencies.releaseCachedVocalSeparator
        modelIdleReleaseTask = Task { [weak self] in
            do {
                try await sleepFor(delay)
            } catch {
                return
            }
            guard !Task.isCancelled, let self else { return }
            self.modelIdleReleaseTask = nil
            guard !self.isLiveSyncActive || (!self.state.isPlaying && !self.isCaptureRunning),
                  self.alignerStartupTask == nil
            else { return }
            if self.isLiveSyncActive {
                let generation = self.syncGeneration
                await self.chunkProcessingTask?.value
                guard self.modelIdleReleaseTask == nil,
                      self.syncGeneration == generation,
                      self.isLiveSyncActive,
                      !self.state.isPlaying,
                      !self.isCaptureRunning
                else { return }
                // A paused session drops its engine and separator so the models can be freed; resuming relaunches them.
                self.chunkEngine?.shutdown()
                self.chunkEngine = nil
                self.vocalSeparator = nil
                self.discardBufferedAudio()
            }
            self.modelMayBeCached = false
            release()
            releaseSeparator()
        }
    }

    func stop() {
        for entry in pendingTailFinalizations.values {
            entry.task.cancel()
        }
        pendingTailFinalizations.removeAll()
        stopActiveSession()
    }

    /// Ends the live session but lets other tracks' tail finalizers finish saving.
    func stopLiveSession() {
        stopActiveSession()
    }

    /// Cancels the tail finalizers whose saves would restore records being deleted (all when `cacheKey` is nil),
    /// then waits for the cache writes they already queued, so the deletion runs after them.
    func cancelPendingTailFinalizations(cacheKey: String?) async {
        let trackIds = pendingTailFinalizations.keys.filter { trackId in
            cacheKey.map { AudioSyncedLyricsCache.cacheKey(forTrackId: trackId) == $0 } ?? true
        }
        for trackId in trackIds {
            pendingTailFinalizations.removeValue(forKey: trackId)?.task.cancel()
        }
        await withCheckedContinuation { continuation in
            dependencies.cacheQueue.async { continuation.resume() }
        }
    }

    /// Ends the live session when the player moves to another track, finishing the outgoing tail in the background.
    func handleTrackChanged() {
        finalizeOutgoingTrackTailIfNeeded()
        stopActiveSession()
    }

    private func stopCapture() {
        captureTargetGeneration &+= 1
        captureStartAccepted = false
        isCaptureRunning = false
        capture.onAudioSamples = nil
        capture.onCaptureFailure = nil
        capture.stop()
        resetNoAudioWatchdog()
    }

    private func stopActiveSession() {
        cacheActiveVocalEnvelopeIfNonEmpty()
        syncGeneration &+= 1
        isLiveSyncActive = false
        stopCapture()
        cacheLoadTask?.cancel()
        cacheLoadTask = nil
        alignerStartupTask?.cancel()
        alignerStartupTask = nil
        chunkProcessingTask?.cancel()
        chunkProcessingTask = nil
        pendingVocalEnvelopeNotification?.cancel()
        pendingVocalEnvelopeNotification = nil
        chunkEngine?.shutdown()
        chunkEngine = nil
        vocalSeparator = nil
        discardBufferedAudio(keepingCapacity: false)
        chunkPlaybackRate = 1.0
        pendingSeekPos = nil
        lastPlayback = nil
        capturedSeconds = 0
        hasReceivedAudibleAudioThisSession = false
        silencePermissionFlagged = false
        scheduleIdleModelReleaseIfNeeded()
    }

    /// Evaluates whether the current track can load cached audio-synced lyrics or needs live alignment.
    func handleTrackLoaded(
        track: TrackInfo,
        rawLines: [LyricLine],
        forceResync: Bool = false,
        onCacheLoad: (() -> Void)? = nil
    ) {
        let trackChanged = activeTrackId != track.id
        if trackChanged {
            finalizeOutgoingTrackTailIfNeeded()
        }
        if forceResync, let pending = pendingTailFinalizations.removeValue(forKey: track.id) {
            pending.task.cancel()
        }
        stopActiveSession()
        activeTrackId = track.id
        activeSourceBundleId = track.sourceBundleId
        baseLines = rawLines
        clearSessionAlignment()
        chromaProfile = AudioChromaProfile()
        cachedChromaTemplates = []
        anchoredLines = [:]
        priorUnlockedLines = [:]
        activeTrackDuration = track.duration
        // Always start a fresh live envelope so WaveformTimingRefiner never mixes levels across plays;
        // `vocalEnvelope(for:)` falls back to `vocalEnvelopeCache` for timeline display until new frames arrive.
        vocalEnvelope = VocalEnvelope()
        vocalPitchContour = VocalPitchContour()
        if forceResync {
            vocalEnvelopeCache.removeValue(forKey: track.id)
        }
        vocalEnvelopeRevision &+= 1
        cachedDisplayEnvelope = nil
        notifyVocalEnvelopeChanged(for: track.id, throttled: false)
        if trackChanged {
            diagnostics.clear()
        }

        let engine = state.audioSyncEngine
        guard engine != .off else {
            state.audioSyncStatus = .idle
            return
        }

        if forceResync {
            guard !rawLines.isEmpty else {
                state.audioSyncStatus = .idle
                return
            }
            removeCachedAlignment(trackId: track.id)
            startLiveSync(for: track, lines: rawLines, engine: engine)
            return
        }

        state.audioSyncStatus = .idle
        let generation = syncGeneration
        let cacheQueue = dependencies.cacheQueue
        let pendingFinalization = pendingTailFinalizations[track.id]?.task
        cacheLoadTask = Task { [weak self, cache] in
            if let pendingFinalization {
                await pendingFinalization.value
            }
            // A rapid reload must see all earlier saves and removals.
            let loaded: AudioSyncedLyricsRecord? = await withCheckedContinuation { continuation in
                cacheQueue.async {
                    continuation.resume(returning: cache.load(trackId: track.id))
                }
            }
            guard !Task.isCancelled,
                  let self,
                  self.syncGeneration == generation,
                  self.activeTrackId == track.id,
                  self.state.audioSyncEngine == engine
            else { return }
            self.cacheLoadTask = nil
            self.applyLoadedAlignment(loaded, track: track, rawLines: rawLines, engine: engine)
            onCacheLoad?()
        }
    }

    private func applyLoadedAlignment(
        _ loaded: AudioSyncedLyricsRecord?,
        track: TrackInfo,
        rawLines: [LyricLine],
        engine: AudioSyncEngine
    ) {
        let rawNonEmptyCount = rawLines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let expectedSourceLineCount = rawNonEmptyCount > 0 ? rawNonEmptyCount : nil

        if !rawLines.isEmpty, loaded?.hasLowYieldLocks == true {
            removeCachedAlignment(trackId: track.id)
            if rawLines != state.rawLyricLines {
                state.applyAudioSyncedLines(rawLines)
            }
        } else if let loaded {
            let current = rawLines.isEmpty
                || loaded.matchesSource(rawLines)
            let cached = (current && !rawLines.isEmpty) ? loaded.remapped(to: rawLines) : loaded
            let reliable = current && cached.isReliable(expectedSourceLineCount: expectedSourceLineCount)
            // A Lyrics Alignment record keeps filling in until no further play could lock another line.
            let fillsIn = engine == .lyricsAlignment && cached.engine == .lyricsAlignment
            let canResume = reliable || (current && fillsIn && !rawLines.isEmpty
                && cached.canResumePartial(expectedSourceLineCount: expectedSourceLineCount))
            let locked = Set(cached.lockedLineIDs ?? [])
            let progress = Self.lyricsAlignmentProgress(lockedIDs: locked, settledIDs: cached.settledLineIDs, lines: rawLines)
            let complete = fillsIn ? progress.isFinished : cached.isComplete(expectedSourceLineCount: expectedSourceLineCount)
            let hasCurrentLockProgress = current && fillsIn && cached.lockedLineIDs != nil
            if rawLines.isEmpty ? reliable : complete && (canResume || hasCurrentLockProgress) {
                if baseLines.isEmpty {
                    baseLines = cached.lines
                }
                if canResume {
                    state.applyAudioSyncedLines(cached.lines)
                }
                state.audioSyncStatus = fillsIn && !rawLines.isEmpty
                    ? progress.status(engine: cached.engine)
                    : .cached(cached.engine)
                return
            }
            if canResume {
                // Show the partial sync now and keep listening to fill in the lines it missed.
                state.applyAudioSyncedLines(cached.lines)
                cachedAlignedLineCount = cached.alignedLineCount
                if fillsIn {
                    let aligned = Self.alignedLineIDs(in: cached.lines)
                    anchoredLines = Dictionary(
                        cached.lines.filter { locked.contains($0.id) }.map { ($0.id, $0) },
                        uniquingKeysWith: { _, latest in latest }
                    )
                    // Lines shown but not locked stay as they are until this play aligns them again.
                    acceptedSessionLines = Dictionary(
                        cached.lines.filter { aligned.contains($0.id) && !locked.contains($0.id) }.map { ($0.id, $0) },
                        uniquingKeysWith: { _, latest in latest }
                    )
                    priorUnlockedLines = acceptedSessionLines
                    cachedChromaTemplates = cached.chromaTemplates ?? []
                    attemptedLineIDs = cached.settledLineIDs
                } else {
                    priorHeardWords = cached.heardWords ?? []
                }
            } else if current {
                // Keep recognized words for refinement without applying unreliable timings.
                priorHeardWords = cached.heardWords ?? []
                // Keep settled attempts too, so this play adds to them instead of starting over.
                let keepsAttempts = fillsIn && !rawLines.isEmpty && cached.lockedLineIDs != nil && !cached.settledLineIDs.isEmpty
                if keepsAttempts {
                    attemptedLineIDs = cached.settledLineIDs
                }
                if priorHeardWords.isEmpty, !cached.hasLowYieldLocks, !keepsAttempts {
                    removeCachedAlignment(trackId: track.id)
                }
            } else {
                removeCachedAlignment(trackId: track.id)
            }
        }

        guard !rawLines.isEmpty else {
            state.audioSyncStatus = .idle
            return
        }

        if Self.hasPreexistingWordSync(rawLines) {
            state.audioSyncStatus = .cached(engine)
            return
        }

        startLiveSync(for: track, lines: rawLines, engine: engine)
    }

    /// Updates the captured source bundle ID when the same recording hands off between browsers without resetting live alignment.
    func updateSourceBundle(for track: TrackInfo) {
        guard activeTrackId == track.id, activeSourceBundleId != track.sourceBundleId else { return }
        let previousTargets = Self.targetBundleIdentifiers(for: track.id, sourceBundleId: activeSourceBundleId)
        activeSourceBundleId = track.sourceBundleId
        let updatedTargets = Self.targetBundleIdentifiers(for: track.id, sourceBundleId: track.sourceBundleId)

        guard isLiveSyncActive, previousTargets != updatedTargets else { return }
        if isCaptureRunning {
            stopCapture()
        }
        hasReceivedAudibleAudioThisSession = false
        clearNoAudioWarning()
        // Buffered samples belong to the old capture's timeline; the next sample starts a new chunk.
        discardBufferedAudio()
        // Deliveries still queued from the old capture must not start the new chunk.
        seekBoundary = ProcessInfo.processInfo.systemUptime
        guard state.isPlaying else { return }
        startCaptureForCurrentTarget(trackId: track.id, engine: state.audioSyncEngine, generation: syncGeneration)
    }

    private func startCaptureForCurrentTarget(
        trackId: String,
        engine: AudioSyncEngine,
        generation: UInt64
    ) {
        captureTargetGeneration &+= 1
        captureStartAccepted = false
        isCaptureRunning = true
        resetNoAudioWatchdog()
        let captureGeneration = captureTargetGeneration
        installChunkHandler(trackId: trackId, generation: generation, captureGeneration: captureGeneration)
        capture.onCaptureFailure = { @Sendable [weak self] error in
            Task { @MainActor in
                self?.handleCaptureFailure(error, generation: generation, captureGeneration: captureGeneration)
            }
        }
        let targetBundles = Self.targetBundleIdentifiers(for: trackId, sourceBundleId: activeSourceBundleId)
        // ScreenCaptureKit supports 48 kHz, but the separator's native 44.1 kHz needs resampling.
        let sampleRate = state.isolateVocals ? 48000 : 16000
        Task { [weak self] in
            guard let self,
                  self.syncGeneration == generation,
                  self.captureTargetGeneration == captureGeneration,
                  self.isLiveSyncActive,
                  self.activeTrackId == trackId,
                  self.state.audioSyncEngine == engine
            else { return }
            guard self.state.isPlaying else {
                self.stopCapture()
                return
            }
            do {
                try await self.capture.start(targetBundleIds: targetBundles, sampleRate: sampleRate)
                guard self.syncGeneration == generation,
                      self.captureTargetGeneration == captureGeneration,
                      self.isLiveSyncActive
                else { return }
                guard self.state.isPlaying else {
                    self.stopCapture()
                    return
                }
                self.captureStartAccepted = true
                self.armNoAudioWatchdogIfNeeded()
            } catch {
                self.handleCaptureFailure(error, generation: generation, captureGeneration: captureGeneration)
            }
        }
    }

    static func hasPreexistingWordSync(_ lines: [LyricLine]) -> Bool {
        let nonEmpty = lines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !nonEmpty.isEmpty else { return false }
        let wordSyncedCount = nonEmpty.filter { $0.words.count > 1 }.count
        return wordSyncedCount * 2 >= nonEmpty.count
    }

    /// Maps a BarTune track to the exact media player bundle ID(s) for isolated ScreenCaptureKit audio capture.
    nonisolated static func targetBundleIdentifiers(for track: TrackInfo) -> Set<String> {
        targetBundleIdentifiers(for: track.id, sourceBundleId: track.sourceBundleId)
    }

    /// Maps a BarTune track ID prefix (and optional originating browser bundle ID) to the exact media player bundle ID(s) for isolated ScreenCaptureKit audio
    /// capture.
    nonisolated static func targetBundleIdentifiers(for trackId: String, sourceBundleId: String? = nil) -> Set<String> {
        if trackId.hasPrefix("spotify:") {
            return ["com.spotify.client"]
        }
        if trackId.hasPrefix("music:") {
            return ["com.apple.Music"]
        }
        if trackId.hasPrefix("browser:") {
            if let sourceBundleId, !sourceBundleId.isEmpty {
                return [sourceBundleId]
            }
            return [
                "com.google.Chrome",
                "company.thebrowser.Browser",
                "com.brave.Browser",
                "com.microsoft.edgemac",
                "com.apple.Safari",
            ]
        }
        return []
    }

    func handlePlaybackStateChanged(isPlaying: Bool, position: Double, playbackRate: Double? = nil) {
        let resolvedRate = Self.sanitizedPlaybackRate(playbackRate ?? state.playbackRate)
        discardChunkIfSeeked(to: position, playbackRate: resolvedRate, isPlaying: isPlaying)
        guard isLiveSyncActive else { return }
        if isPlaying {
            modelIdleReleaseTask?.cancel()
            modelIdleReleaseTask = nil
            if !isCaptureRunning, let trackId = activeTrackId {
                if chunkEngine != nil {
                    startCaptureForCurrentTarget(trackId: trackId, engine: state.audioSyncEngine, generation: syncGeneration)
                    dispatchChunkIfReady(trackId: trackId, generation: syncGeneration)
                } else if alignerStartupTask == nil, state.audioSyncEngine == .lyricsAlignment {
                    startLyricsAlignmentSync(trackId: trackId, lines: baseLines)
                }
            }
            armNoAudioWatchdogIfNeeded()
        } else {
            if isCaptureRunning {
                stopCapture()
                seekBoundary = ProcessInfo.processInfo.systemUptime
                // Persist whatever alignment we gathered before pausing/stopping.
                persistCurrentAlignmentIfReady()
            } else {
                resetNoAudioWatchdog()
            }
            scheduleIdleModelReleaseIfNeeded()
        }
    }

    private static func sanitizedPlaybackRate(_ rate: Double) -> Double {
        (rate.isFinite && rate > 0) ? rate : 1.0
    }

    private func discardBufferedAudio(keepingCapacity: Bool = true) {
        audioSampleBuffer.removeAll(keepingCapacity: keepingCapacity)
        audioSideBuffer.removeAll(keepingCapacity: keepingCapacity)
        captureSpanStarts.removeAll(keepingCapacity: keepingCapacity)
    }

    private func bufferedEndPosition(sampleRate: Double) -> Double? {
        guard let last = captureSpanStarts.last else { return nil }
        let duration = Double(audioSampleBuffer.count - last.offset) / max(sampleRate, 1)
        return last.time + duration * chunkPlaybackRate
    }

    private func beginCaptureSpan(at position: Double, followsDrop: Bool) -> Double {
        var start = position
        if audioSampleBuffer.isEmpty {
            if let pending = pendingSeekPos {
                pendingSeekPos = nil
                if abs(position - pending) > Self.seekTolerance { start = pending }
            }
            chunkPlaybackRate = Self.sanitizedPlaybackRate(state.playbackRate)
        }
        captureSpanStarts.append((audioSampleBuffer.count, start, followsDrop))
        return start
    }

    private func removeBufferedSamplePrefix(_ count: Int, sampleRate: Double) {
        if count == audioSampleBuffer.count {
            discardBufferedAudio()
            return
        }
        let unpairedCount = audioSampleBuffer.count - audioSideBuffer.count
        audioSampleBuffer.removeFirst(count)
        if count > unpairedCount { audioSideBuffer.removeFirst(count - unpairedCount) }
        guard let index = captureSpanStarts.lastIndex(where: { $0.offset <= count }) else { return }
        let span = captureSpanStarts[index]
        let start = span.time + Double(count - span.offset) / max(sampleRate, 1) * chunkPlaybackRate
        captureSpanStarts.removeFirst(index)
        captureSpanStarts[0] = (0, start, span.followsDrop)
        for index in captureSpanStarts.indices.dropFirst() {
            captureSpanStarts[index].offset -= count
        }
    }

    private func discardChunkIfSeeked(to position: Double, playbackRate: Double, isPlaying: Bool) {
        guard state.audioSyncEngine == .lyricsAlignment, isLiveSyncActive || lastPlayback != nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let last = lastPlayback
        lastPlayback = (position, now, playbackRate, isPlaying)
        if let last,
           position <= Self.restartWindow * max(1, playbackRate),
           last.position - position > Self.seekTolerance,
           !baseLines.isEmpty {
            if hasLowYieldLocks {
                state.applyAudioSyncedLines(baseLines)
                resyncCurrentTrack()
                return
            }
            if isLiveSyncActive,
               !lockedThisPlay.isEmpty,
               Self.lyricsAlignmentProgress(lockedIDs: lockedLineIDs, settledIDs: attemptedLineIDs, lines: baseLines).isFinished {
                resumeNextPassFromCache()
                return
            }
        }
        guard isLiveSyncActive else { return }
        if let expected = bufferedEndPosition(sampleRate: activeSampleRate) {
            let seeked = abs(position - expected) > Self.seekTolerance
            let rateChanged = abs(playbackRate - chunkPlaybackRate) > 0.01
            if seeked || rateChanged {
                discardBufferedAudio()
                chunkPlaybackRate = playbackRate
                pendingSeekPos = position
                seekBoundary = ProcessInfo.processInfo.systemUptime
                sentFinalChunk = false
            }
        } else if let last {
            let expected = last.position + (last.isPlaying ? (now - last.uptime) * last.rate : 0)
            let seeked = abs(position - expected) > Self.seekTolerance
            let rateChanged = abs(playbackRate - last.rate) > 0.01
            if seeked || rateChanged {
                pendingSeekPos = position
                chunkPlaybackRate = playbackRate
                seekBoundary = now
                sentFinalChunk = false
            }
        }
    }

    private func resumeNextPassFromCache() {
        guard let trackId = activeTrackId, !baseLines.isEmpty else { return }
        let track = TrackInfo(
            id: trackId,
            title: "",
            artist: "",
            album: "",
            duration: activeTrackDuration,
            artworkURL: nil,
            sourceBundleId: activeSourceBundleId
        )
        handleTrackLoaded(track: track, rawLines: baseLines, forceResync: false)
    }

    func resyncCurrentTrack() {
        guard let trackId = activeTrackId, !baseLines.isEmpty else { return }
        let track = TrackInfo(
            id: trackId,
            title: "",
            artist: "",
            album: "",
            duration: activeTrackDuration,
            artworkURL: nil,
            sourceBundleId: activeSourceBundleId
        )
        handleTrackLoaded(track: track, rawLines: baseLines, forceResync: true)
    }

    private func startLiveSync(for track: TrackInfo, lines: [LyricLine], engine: AudioSyncEngine) {
        guard !Self.targetBundleIdentifiers(for: track).isEmpty else {
            state.audioSyncStatus = .unavailable("Could not identify media player for audio capture")
            return
        }
        guard dependencies.hasScreenCaptureAccess() else {
            dependencies.requestScreenCaptureAccess()
            state.audioSyncStatus = .permissionRequired("Screen & System Audio Recording permission required")
            return
        }

        diagnostics.begin(engine: engine, track: track, totalLines: lines.count)
        switch engine {
        case .off:
            state.audioSyncStatus = .idle
        case .lyricsAlignment:
            startLyricsAlignmentSync(trackId: track.id, lines: lines)
        }
    }

    private func handleCaptureFailure(_ error: Error, generation: UInt64, captureGeneration: UInt64) {
        guard syncGeneration == generation, captureTargetGeneration == captureGeneration else { return }
        persistCurrentAlignmentIfReady()
        stopActiveSession()
        if dependencies.usesProcessTap {
            if let captureError = error as? ProcessTapCaptureError, captureError.isPermissionError {
                state.systemAudioCapturePermission = .denied
                state.audioSyncStatus = .permissionRequired(error.localizedDescription)
            } else {
                state.audioSyncStatus = .unavailable(error.localizedDescription)
            }
        } else if let captureError = error as? SystemAudioCaptureError, captureError == .unresolvedPlayer {
            state.audioSyncStatus = .unavailable(error.localizedDescription)
        } else {
            state.audioSyncStatus = .permissionRequired("Audio capture failed: \(error.localizedDescription)")
        }
    }

    private func startLyricsAlignmentSync(trackId: String, lines: [LyricLine]) {
        modelIdleReleaseTask?.cancel()
        modelIdleReleaseTask = nil
        modelMayBeCached = true
        let generation = syncGeneration
        let launch = dependencies.launchLyricsAligner
        let launchWithPriors = dependencies.launchLyricsAlignerWithPriors
        let launchSeparator = state.isolateVocals ? dependencies.launchVocalSeparator : nil
        discardBufferedAudio()
        chunkPlaybackRate = Self.sanitizedPlaybackRate(state.playbackRate)
        pendingSeekPos = nil
        sentFinalChunk = false
        state.audioSyncStatus = .syncing(engine: .lyricsAlignment, alignedLines: anchoredLines.count, totalLines: lines.count)

        let anchors = anchoredLines.compactMapValues(Self.sungSpan)
        let priorLines = priorUnlockedLines
        alignerStartupTask = Task { [weak self] in
            let engine = if let launchWithPriors {
                await launchWithPriors(lines, anchors, priorLines)
            } else {
                await launch(lines, anchors)
            }
            var separator: VocalIsolating?
            if engine != nil, !Task.isCancelled, let launchSeparator {
                separator = await launchSeparator()
            }
            guard let self,
                  !Task.isCancelled,
                  self.syncGeneration == generation,
                  self.activeTrackId == trackId,
                  self.state.audioSyncEngine == .lyricsAlignment
            else {
                guard let engine else { return }
                engine.shutdown()
                // A late launch may have cached the model after the idle release fired.
                if let self, !self.isLiveSyncActive, self.alignerStartupTask == nil {
                    self.modelMayBeCached = true
                    self.scheduleIdleModelReleaseIfNeeded()
                }
                return
            }
            self.alignerStartupTask = nil
            guard let engine else {
                self.scheduleIdleModelReleaseIfNeeded()
                self.state.audioSyncStatus = .unavailable("Lyrics alignment model not installed, or this Mac has no Neural Engine")
                return
            }
            self.chunkEngine = engine
            self.vocalSeparator = separator
            self.diagnostics.update { $0.localeIdentifier = "lyrics alignment" }
            self.beginChunkCapture(trackId: trackId, generation: generation)
        }
    }

    private func beginChunkCapture(trackId: String, generation: UInt64) {
        isLiveSyncActive = true
        lastPlayback = (
            currentPlaybackPosition(),
            ProcessInfo.processInfo.systemUptime,
            Self.sanitizedPlaybackRate(state.playbackRate),
            state.isPlaying
        )
        guard state.isPlaying else {
            scheduleIdleModelReleaseIfNeeded()
            return
        }
        startCaptureForCurrentTarget(trackId: trackId, engine: .lyricsAlignment, generation: generation)
    }

    private func resetNoAudioWatchdog() {
        noAudioWatchdogTask?.cancel()
        noAudioWatchdogTask = nil
        noAudioObservationStartedAt = nil
        consecutiveSilentSeconds = 0
    }

    /// Surfaces the no-audio warning if playback continues without any audible buffer (including zero callbacks
    /// while waiting for a late player process to open an audio stream).
    private func armNoAudioWatchdogIfNeeded() {
        guard dependencies.usesProcessTap,
              captureStartAccepted,
              isLiveSyncActive,
              state.isPlaying,
              !hasReceivedAudibleAudioThisSession,
              !silencePermissionFlagged,
              noAudioWatchdogTask == nil
        else { return }
        let threshold = max(0.05, dependencies.sustainedSilenceThreshold)
        let sleepFor = dependencies.noAudioWatchdogSleep
        let captureGeneration = captureTargetGeneration
        noAudioObservationStartedAt = ProcessInfo.processInfo.systemUptime
        noAudioWatchdogTask = Task { [weak self] in
            do {
                try await sleepFor(.seconds(threshold))
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.captureTargetGeneration == captureGeneration,
                  self.isLiveSyncActive,
                  self.state.isPlaying,
                  !self.hasReceivedAudibleAudioThisSession
            else { return }
            self.showNoAudioWarning()
        }
    }

    private func installChunkHandler(trackId: String, generation: UInt64, captureGeneration: UInt64) {
        capture.onAudioSamples = { @Sendable [weak self] batch in
            let deliveredAt = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in
                guard let self,
                      self.syncGeneration == generation,
                      self.captureTargetGeneration == captureGeneration,
                      self.isLiveSyncActive,
                      self.state.isPlaying,
                      self.activeTrackId == trackId,
                      self.state.audioSyncEngine == .lyricsAlignment,
                      let audio = batch.trimmingBefore(self.seekBoundary, deliveredAt: deliveredAt),
                      !audio.samples.isEmpty
                else { return }
                let samples = audio.samples
                let sampleRate = audio.sampleRate
                guard sampleRate.isFinite, sampleRate > 0, !samples.isEmpty else { return }
                self.capturedSeconds += Double(samples.count) / sampleRate
                self.diagnostics.recordAudio(totalSeconds: self.capturedSeconds)
                self.diagnostics.recordCaptureSampleRate(sampleRate)
                if let delay = audio.captureDelay {
                    self.diagnostics.recordCaptureDelay(delay)
                }
                self.updateProcessTapSilenceWatchdog(audio, deliveredAt: deliveredAt)
                // Startup silence must never become part of a stateful aligner chunk.
                guard !self.dependencies.usesProcessTap || self.hasReceivedAudibleAudioThisSession else { return }
                if !self.audioSampleBuffer.isEmpty, sampleRate != self.activeSampleRate {
                    self.discardBufferedAudio()
                }
                self.activeSampleRate = sampleRate
                let livePos = Self.playbackPosition(
                    self.currentPlaybackPosition(),
                    capturedAt: audio.firstSampleUptime(deliveredAt: deliveredAt),
                    now: ProcessInfo.processInfo.systemUptime,
                    rate: self.state.isPlaying ? self.state.playbackRate : 0
                )
                var continuedStart = self.bufferedEndPosition(sampleRate: sampleRate)
                if let expectedStart = continuedStart,
                   audio.captureDelay != nil || audio.capturedAt != nil,
                   abs(livePos - expectedStart) > 0.05 {
                    continuedStart = nil
                    if abs(livePos - expectedStart) > Self.seekTolerance {
                        // A large discontinuity starts a fresh inference chunk.
                        self.discardBufferedAudio()
                    }
                }
                if audio.startsNewSpan { continuedStart = nil }
                let deliveryStart = continuedStart ?? self.beginCaptureSpan(at: livePos, followsDrop: audio.startsNewSpan)
                self.appendFullMixEnvelope(audio, at: deliveryStart, trackId: trackId)
                self.audioSampleBuffer.append(contentsOf: samples)
                if audio.side.count == samples.count {
                    self.audioSideBuffer.append(contentsOf: audio.side)
                } else {
                    // Keep the mid samples so a mixed mono/stereo chunk can still use full-mix alignment.
                    self.audioSideBuffer.removeAll(keepingCapacity: true)
                }

                let targetFrames = max(1, Int(sampleRate * self.chunkDurationSeconds))
                let maxFrames = targetFrames * 2
                if self.audioSampleBuffer.count > maxFrames {
                    let overflow = self.audioSampleBuffer.count - maxFrames
                    self.removeBufferedSamplePrefix(overflow, sampleRate: sampleRate)
                }

                self.dispatchChunkIfReady(trackId: trackId, generation: generation)
            }
        }
    }

    private func appendFullMixEnvelope(_ audio: CapturedAudio, at start: Double, trackId: String) {
        let previousFrameCount = vocalEnvelope.totalFrameCount
        let previousEnd = vocalEnvelope.segments.last?.end
        vocalEnvelope.append(
            mid: audio.samples,
            side: audio.side,
            sampleRate: audio.sampleRate,
            startTime: start,
            rate: chunkPlaybackRate,
            startsNewSpan: audio.startsNewSpan
        )
        recordVocalEnvelopeChange(trackId: trackId, previousFrameCount: previousFrameCount, previousEnd: previousEnd)
    }

    private func recordVocalEnvelopeChange(trackId: String, previousFrameCount: Int, previousEnd: Double?) {
        let updatedFrameCount = vocalEnvelope.totalFrameCount
        if updatedFrameCount > 0,
           updatedFrameCount > previousFrameCount || vocalEnvelope.segments.last?.end != previousEnd {
            vocalEnvelopeRevision &+= 1
            notifyVocalEnvelopeChanged(for: trackId, throttled: previousFrameCount > 0)
        }
    }

    /// A quiet player or missing recording permission can produce silent buffers on Core Audio Process Taps.
    private func updateProcessTapSilenceWatchdog(_ audio: CapturedAudio, deliveredAt: TimeInterval) {
        guard dependencies.usesProcessTap, !hasReceivedAudibleAudioThisSession else { return }
        let hasSignal = audio.samples.contains { abs($0) > 0.00001 }
            || audio.side.contains { abs($0) > 0.00001 }
        if hasSignal {
            hasReceivedAudibleAudioThisSession = true
            resetNoAudioWatchdog()
            if state.systemAudioCapturePermission != .granted {
                state.systemAudioCapturePermission = .granted
            }
            clearNoAudioWarning()
        } else if let observationStart = noAudioObservationStartedAt, state.isPlaying {
            // A queued delivery can include samples from before startup was accepted or playback resumed.
            let duration = Double(audio.samples.count) / audio.sampleRate
            let earlySeconds = max(0, observationStart - audio.firstSampleUptime(deliveredAt: deliveredAt))
            consecutiveSilentSeconds += max(0, duration - earlySeconds)
            if consecutiveSilentSeconds >= dependencies.sustainedSilenceThreshold {
                showNoAudioWarning()
            }
        }
    }

    private func showNoAudioWarning() {
        resetNoAudioWatchdog()
        silencePermissionFlagged = true
        state.audioSyncStatus = .processTapNoAudioWarning
    }

    private func clearNoAudioWarning() {
        guard silencePermissionFlagged else { return }
        silencePermissionFlagged = false
        state.audioSyncStatus = .syncing(
            engine: .lyricsAlignment,
            alignedLines: max(acceptedSessionLines.count, cachedAlignedLineCount),
            totalLines: baseLines.count
        )
    }

    /// Dispatches one `targetFrames` chunk when the worker is idle, or what is left once the audio reaches the
    /// track's end; called on sample delivery and worker completion.
    private func dispatchChunkIfReady(trackId: String, generation: UInt64) {
        guard syncGeneration == generation,
              isLiveSyncActive,
              state.isPlaying,
              activeTrackId == trackId,
              state.audioSyncEngine == .lyricsAlignment,
              !dependencies.usesProcessTap || hasReceivedAudibleAudioThisSession,
              chunkProcessingTask == nil,
              let engine = chunkEngine
        else { return }
        let sampleRate = activeSampleRate
        let targetFrames = max(1, Int(sampleRate * chunkDurationSeconds))
        let chunkStart = chunkStartPos ?? currentPlaybackPosition()
        let bufferedEnd = bufferedEndPosition(sampleRate: sampleRate) ?? chunkStart
        let reachesEnd = !sentFinalChunk && activeTrackDuration > 0
            && bufferedEnd >= activeTrackDuration - Self.trackEndMargin
        // The aligner accepts a contiguous waveform. Finish the preceding span before submitting post-drop audio.
        let dropOffset = captureSpanStarts.dropFirst().first(where: \.followsDrop)?.offset
        let frameCount = min(targetFrames, dropOffset ?? audioSampleBuffer.count, audioSampleBuffer.count)
        let isFinal = reachesEnd && frameCount == audioSampleBuffer.count
        guard frameCount > 0, frameCount == targetFrames || frameCount == dropOffset || isFinal else { return }

        let requestPlaybackRate = chunkPlaybackRate
        let chunkEnd = chunkStart + Double(frameCount) / sampleRate * requestPlaybackRate
        if !isFinal, let reporter = engine as? LineAttemptReporting, !reporter.needsAudio(from: chunkStart, to: chunkEnd) {
            removeBufferedSamplePrefix(frameCount, sampleRate: sampleRate)
            if frameCount != dropOffset, !captureSpanStarts.isEmpty { captureSpanStarts[0].followsDrop = false }
            if isFinal { sentFinalChunk = true }
            dispatchChunkIfReady(trackId: trackId, generation: generation)
            return
        }

        let rawChunk = Array(audioSampleBuffer.prefix(frameCount))
        let sideChunk = audioSideBuffer.count == audioSampleBuffer.count ? Array(audioSideBuffer.prefix(frameCount)) : []
        let spans = captureSpanStarts.prefix { $0.offset < frameCount }
        let startsNewSpan = spans.first?.followsDrop == true
        let separator = vocalSeparator
        // The envelope location refers to its newest segment. A capture gap can put that segment
        // on a different time grid from the chunk, so keep the full-mix preview in that case.
        let envelopeLocation = separator != nil && captureSpanStarts.count == 1 ? vocalEnvelope.frameLocation(at: chunkStart) : nil
        removeBufferedSamplePrefix(frameCount, sampleRate: sampleRate)
        if frameCount != dropOffset, !captureSpanStarts.isEmpty { captureSpanStarts[0].followsDrop = false }
        if isFinal { sentFinalChunk = true }

        let resample = dependencies.resampleForRecognition
        // Run vocal isolation, pitch analysis, chroma extraction, normalization, Core ML inference,
        // and CTC Viterbi at `.background` QoS so multi-threaded CPU fallback (libBNNS) stays on
        // efficiency cores and never preempts interactive UI threads.
        chunkProcessingTask = Task.detached(priority: .background) { [weak self] () -> ChunkOutcome? in
            let recognized = Self.recognitionAudio(mid: rawChunk, side: sideChunk, sampleRate: sampleRate, separator: separator, resample: resample)
            guard !Task.isCancelled else { return nil }
            guard let audio = recognized else {
                await self?.stopAfterChunkFailure(
                    generation: generation, message: "Could not resample captured audio for lyrics alignment; it restarts with the next track"
                )
                return nil
            }
            if let envelopeLocation, audio.vocalSeparationSeconds != nil {
                var stem = VocalEnvelope()
                stem.append(mid: audio.samples, side: [], sampleRate: Double(audio.sampleRate), startTime: 0, rate: requestPlaybackRate)
                if let segment = stem.segments.first {
                    await self?.publishSeparatedEnvelope(segment, at: envelopeLocation, trackId: trackId, generation: generation)
                }
            }
            guard !Task.isCancelled else { return nil }
            let pitch = Self.analyzePitch(
                raw: (rawChunk, sideChunk, sampleRate),
                recognitionAudio: audio,
                start: chunkStart,
                rate: requestPlaybackRate
            )
            guard !Task.isCancelled else { return nil }
            var chroma = AudioChromaProfile()
            for index in spans.indices {
                let span = spans[index]
                let end = index + 1 < spans.endIndex ? spans[index + 1].offset : rawChunk.count
                let samples = spans.count == 1 ? rawChunk : Array(rawChunk[span.offset..<end])
                chroma.append(samples: samples, sampleRate: sampleRate, startTime: span.time, rate: requestPlaybackRate)
            }
            let chunkChroma = chroma
            guard !Task.isCancelled else { return nil }
            let request = AudioChunkRequest(
                samples: AudioLevel.normalizedForRecognition(audio.samples),
                sampleRate: audio.sampleRate,
                chunkStartTime: chunkStart,
                playbackRate: requestPlaybackRate,
                isFinal: isFinal,
                startsNewSpan: startsNewSpan
            )
            let words: [RecognizedAudioWord]
            do {
                words = try await engine.transcribe(request)
            } catch {
                await self?.stopAfterChunkFailure(
                    generation: generation, message: "Lyrics alignment stopped unexpectedly; it restarts with the next track"
                )
                return nil
            }
            let appliedOnMain = await MainActor.run { [weak self] () -> Bool in
                guard let self, self.syncGeneration == generation else { return false }
                self.chunkProcessingTask = nil
                guard self.activeTrackId == trackId,
                      self.isLiveSyncActive,
                      self.state.audioSyncEngine == .lyricsAlignment
                else { return true }
                if let pitch {
                    self.vocalPitchContour.merge(pitch)
                }
                self.chromaProfile.merge(chunkChroma)
                let voicedFramePercent = self.vocalPitchContour.voicedFraction.map { $0 * 100 }
                self.diagnostics.update {
                    $0.voicedFramePercent = voicedFramePercent
                    $0.vocalSeparationSeconds = audio.vocalSeparationSeconds
                    $0.record(words: words, replacing: false)
                }
                self.recognizedWords.append(contentsOf: words)
                var newAttempts: Set<Int> = []
                let reporter = engine as? LineAttemptReporting
                if let reporter {
                    let reported = reporter.attemptedLineIDs
                    newAttempts = reported.subtracting(self.attemptedThisPlay)
                    self.attemptedLineIDs.formUnion(reported)
                    self.attemptedThisPlay.formUnion(newAttempts)
                    self.confidentLineIDs.formUnion(reporter.confidentLineIDs)
                    self.nearlyConfidentLineIDs.formUnion(reporter.nearlyConfidentLineIDs)
                }
                self.applyLyricsAlignment(replacingAttempts: newAttempts, reporter: reporter)
                self.dispatchChunkIfReady(trackId: trackId, generation: generation)
                return true
            }
            return appliedOnMain ? nil : ChunkOutcome(words: words, pitch: pitch, chroma: chunkChroma)
        }
    }

    private func publishSeparatedEnvelope(
        _ segment: VocalEnvelope.Segment,
        at location: VocalEnvelope.FrameLocation,
        trackId: String,
        generation: UInt64
    ) {
        guard syncGeneration == generation, activeTrackId == trackId, isLiveSyncActive,
              state.audioSyncEngine == .lyricsAlignment,
              vocalEnvelope.replaceFrames(at: location, with: segment)
        else { return }
        vocalEnvelopeRevision &+= 1
        notifyVocalEnvelopeChanged(for: trackId, throttled: true)
    }

    private func stopAfterChunkFailure(generation: UInt64, message: String) {
        guard syncGeneration == generation else { return }
        chunkProcessingTask = nil
        persistCurrentAlignmentIfReady()
        stopActiveSession()
        state.audioSyncStatus = .unavailable(message)
    }

    nonisolated static func recognitionAudio(
        mid: [Float],
        side: [Float],
        sampleRate: Double,
        separator: VocalIsolating?,
        resample: ([Float], Double, Double) -> [Float]? = { AudioResampler.resample($0, from: $1, to: $2) }
    ) -> (samples: [Float], sampleRate: Int, vocalSeparationSeconds: Double?)? {
        let target = Double(LyricsForcedAligner.sampleRate)
        if let separator, !mid.isEmpty, side.count == mid.count {
            let start = ProcessInfo.processInfo.systemUptime
            let stemRate = VocalSeparation.sampleRate
            if let left = resample(zip(mid, side).map(+), sampleRate, stemRate),
               let right = resample(zip(mid, side).map(-), sampleRate, stemRate),
               let stem = try? separator.vocals(left: left, right: right) {
                let vocals = zip(stem.left, stem.right).map { ($0 + $1) / 2 }
                if let samples = resample(vocals, stemRate, target), !samples.isEmpty {
                    return (samples, Int(target), ProcessInfo.processInfo.systemUptime - start)
                }
            }
        }
        guard sampleRate > target else { return (mid, Int(sampleRate), nil) }
        guard let samples = resample(mid, sampleRate, target), !samples.isEmpty else { return nil }
        return (samples, Int(target), nil)
    }

    private nonisolated static func analyzePitch(
        raw: (mid: [Float], side: [Float], sampleRate: Double),
        recognitionAudio: (samples: [Float], sampleRate: Int, vocalSeparationSeconds: Double?),
        start: Double,
        rate: Double
    ) -> VocalPitchContour.Segment? {
        if recognitionAudio.vocalSeparationSeconds != nil,
           recognitionAudio.sampleRate == VocalPitchContour.sampleRate {
            return VocalPitchContour.analyze(
                mid: recognitionAudio.samples, side: [], start: start, rate: rate, fromSeparatedVocals: true
            )
        }
        if Int(raw.sampleRate) == VocalPitchContour.sampleRate {
            return VocalPitchContour.analyze(mid: raw.mid, side: raw.side, start: start, rate: rate)
        }
        if recognitionAudio.sampleRate == VocalPitchContour.sampleRate {
            return VocalPitchContour.analyze(mid: recognitionAudio.samples, side: [], start: start, rate: rate)
        }
        return nil
    }

    /// Track position at `capturedAt`, given the position `now` and the rate the track is playing at (0 when paused).
    nonisolated static func playbackPosition(_ position: Double, capturedAt: Double, now: Double, rate: Double) -> Double {
        position - max(0, now - capturedAt) * rate
    }

    private func currentPlaybackPosition() -> Double {
        let elapsed = max(0.0, Date().timeIntervalSince(state.playbackAnchorDate))
        return state.playbackAnchorPosition + (state.isPlaying ? elapsed * state.playbackRate : 0.0)
    }

    /// Words from earlier plays fill only the stretches this play hasn't heard; this play's words win,
    /// without letting fresh words tagged to one lyric evict retained words tagged to a different lyric.
    nonisolated static func mergeHeardWords(
        prior: [RecognizedAudioWord],
        current: [RecognizedAudioWord],
        margin: Double = 1.0
    ) -> [RecognizedAudioWord] {
        let kept = prior.filter { old in
            !current.contains { fresh in
                if let oldLineId = old.sourceLineId,
                   let freshLineId = fresh.sourceLineId,
                   oldLineId != freshLineId {
                    return false
                }
                return fresh.startTime - margin < old.endTime && old.startTime < fresh.endTime + margin
            }
        }
        return (kept + current).sorted { $0.startTime < $1.startTime }
    }

    private var allHeardWords: [RecognizedAudioWord] {
        guard anchoredLines.isEmpty else {
            // Lyrics Alignment never realigns an anchored line, so its saved words are never overlapped.
            return (Self.recognizedWords(of: Array(anchoredLines.values)) + recognizedWords).sorted { $0.startTime < $1.startTime }
        }
        let unattemptedPriorWords = priorHeardWords.filter { word in
            word.sourceLineId.map { !attemptedThisPlay.contains($0) } ?? true
        }
        return Self.mergeHeardWords(prior: unattemptedPriorWords, current: recognizedWords)
    }

    /// Every word heard, refined against this play's vocal loudness and harmonicity.
    private func refinedHeardWords() -> [RecognizedAudioWord] {
        let (words, stats) = WaveformTimingRefiner.refine(
            allHeardWords,
            envelope: vocalEnvelope,
            pitchContour: vocalPitchContour,
            timingError: 0.06
        )
        diagnostics.update { $0.waveformRefinement = stats }
        return words
    }

    /// Aligns the lyrics to every word heard, keeping lines anchored from an earlier play or already
    /// accepted in this Lyrics Alignment session so later audio-level shifts cannot drop them.
    private func currentAlignment() -> AudioAlignmentResult {
        let fresh = alignHeardWords()
        return recoveringRepeatedLines(keepingLockedAndAccepted(fresh), fresh: fresh)
    }

    private func recoveringRepeatedLines(_ result: AudioAlignmentResult, fresh: AudioAlignmentResult) -> AudioAlignmentResult {
        let locked = lockedLineIDs
        guard !locked.isEmpty, !chromaProfile.segments.isEmpty else { return result }
        let protectedTargetIDs = Set(fresh.matchedLineIDs)
            .intersection(result.matchedLineIDs)
            .subtracting(fresh.clampedRunawayLineIDs)
        let recovery = ChorusSelfSimilarity.recoverRepeatedLines(
            in: result.lines, lockedIDs: locked, protectedTargetIDs: protectedTargetIDs,
            chroma: chromaProfile, cachedTemplates: cachedChromaTemplates, medianOffset: result.medianOffset,
            sourceTimestamps: Dictionary(uniqueKeysWithValues: baseLines.map { ($0.id, $0.timestamp) })
        )
        diagnostics.update { $0.chorusRecoveredCount = recovery.recoveredLineIDs.count }
        guard !recovery.recoveredLineIDs.isEmpty else { return result }
        let matched = Set(result.matchedLineIDs).union(recovery.recoveredLineIDs)
        return AudioAlignmentResult(
            lines: recovery.lines,
            matchedLineCount: matched.count,
            matchedWordCount: result.matchedWordCount,
            medianOffset: result.medianOffset,
            matchedLineIDs: recovery.lines.map(\.id).filter(matched.contains),
            clampedRunawayLineIDs: result.clampedRunawayLineIDs.subtracting(recovery.recoveredLineIDs)
        )
    }

    /// The lyrics aligned to every word heard, before locked and accepted lines are put back.
    private func alignHeardWords() -> AudioAlignmentResult {
        LyricsAudioAligner.align(
            lines: baseLines,
            recognizedWords: refinedHeardWords(),
            regroupsCJKWords: false,
            splitsSyllables: state.syllableTiming
        )
    }

    private func keepingLockedAndAccepted(_ result: AudioAlignmentResult, replacingAttempts: Set<Int> = []) -> AudioAlignmentResult {
        Self.keepingLockedAndAccepted(
            result,
            baseLines: baseLines,
            anchoredLines: anchoredLines,
            lockedThisPlay: lockedThisPlay,
            acceptedSessionLines: acceptedSessionLines,
            replacingAttempts: replacingAttempts
        )
    }

    private nonisolated static func keepingLockedAndAccepted(
        _ result: AudioAlignmentResult,
        baseLines: [LyricLine],
        anchoredLines: [Int: LyricLine],
        lockedThisPlay: [Int: LyricLine],
        acceptedSessionLines: [Int: LyricLine],
        replacingAttempts: Set<Int> = []
    ) -> AudioAlignmentResult {
        let preserved = acceptedSessionLines
        guard !anchoredLines.isEmpty || !lockedThisPlay.isEmpty || !preserved.isEmpty else { return result }
        let minLineGap = 0.15
        let isNonEmpty: (LyricLine) -> Bool = {
            !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !ForcedAlignmentText.isStructuralTag($0.text)
        }
        let lockedIDs = Set(anchoredLines.keys).union(lockedThisPlay.keys)
        let resultMatched = Set(result.matchedLineIDs)
        let baseByID = Dictionary(uniqueKeysWithValues: baseLines.map { ($0.id, $0) })

        var lines: [LyricLine] = []
        lines.reserveCapacity(result.lines.count)
        var freshUnlockedIndices: [Int] = []
        var restoredUnlockedIndices: [Int] = []
        var matched: Set<Int> = []
        for (idx, line) in result.lines.enumerated() {
            if let locked = anchoredLines[line.id] ?? lockedThisPlay[line.id] {
                lines.append(locked)
                matched.insert(line.id)
            } else if resultMatched.contains(line.id) {
                lines.append(line)
                matched.insert(line.id)
                freshUnlockedIndices.append(idx)
            } else if let kept = preserved[line.id], !replacingAttempts.contains(line.id) {
                lines.append(kept)
                matched.insert(line.id)
                restoredUnlockedIndices.append(idx)
            } else {
                lines.append(line)
            }
        }

        // Drop freshly matched unlocked lines that leave less than `minLineGap` per intervening non-empty
        // line against locked anchors so fallback rows always have monotonic room to sit in between.
        for idx in freshUnlockedIndices where isNonEmpty(lines[idx]) {
            let candidate = lines[idx]
            let conflictsPrevLocked: Bool = if let prevIdx = lines[..<idx].lastIndex(where: { isNonEmpty($0) && lockedIDs.contains($0.id) }) {
                candidate.timestamp < lines[prevIdx].timestamp + Double(lines[(prevIdx + 1)..<idx].filter(isNonEmpty).count + 1) * minLineGap
            } else {
                false
            }
            let conflictsNextLocked: Bool = if let nextIdx = lines[(idx + 1)...].firstIndex(where: { isNonEmpty($0) && lockedIDs.contains($0.id) }) {
                candidate.timestamp + Double(lines[(idx + 1)..<nextIdx].filter(isNonEmpty).count + 1) * minLineGap > lines[nextIdx].timestamp
            } else {
                false
            }
            if conflictsPrevLocked || conflictsNextLocked {
                lines[idx] = baseByID[candidate.id] ?? result.lines[idx]
                matched.remove(candidate.id)
            }
        }

        // Drop unlocked preserved lines whose timestamps conflict with locked or surviving freshly matched
        // neighbors (including required spacing for intervening non-empty fallback rows).
        let authoritativeIDs = matched.subtracting(restoredUnlockedIndices.map { lines[$0].id })
        for idx in restoredUnlockedIndices {
            let candidate = lines[idx]
            guard isNonEmpty(candidate) else { continue }
            let conflictsPrev: Bool = if let prevIdx = lines[..<idx].lastIndex(where: { isNonEmpty($0) && matched.contains($0.id) }) {
                candidate.timestamp < lines[prevIdx].timestamp + Double(lines[(prevIdx + 1)..<idx].filter(isNonEmpty).count + 1) * minLineGap
            } else {
                false
            }
            let conflictsNext: Bool = if let nextIdx = lines[(idx + 1)...].firstIndex(where: { isNonEmpty($0) && authoritativeIDs.contains($0.id) }) {
                candidate.timestamp + Double(lines[(idx + 1)..<nextIdx].filter(isNonEmpty).count + 1) * minLineGap > lines[nextIdx].timestamp
            } else {
                false
            }
            if conflictsPrev || conflictsNext {
                lines[idx] = baseByID[candidate.id] ?? result.lines[idx]
                matched.remove(candidate.id)
            }
        }

        // Resolve any remaining pair of matched non-empty lines that leaves insufficient room for
        // intervening unmatched non-empty lines (preferring locked lines over unlocked ones).
        var lastMatchedNonEmptyIdx: Int?
        for idx in lines.indices where isNonEmpty(lines[idx]) && matched.contains(lines[idx].id) {
            if let prevIdx = lastMatchedNonEmptyIdx {
                let requiredGap = Double(lines[(prevIdx + 1)..<idx].filter(isNonEmpty).count + 1) * minLineGap
                if lines[idx].timestamp < lines[prevIdx].timestamp + requiredGap {
                    if !lockedIDs.contains(lines[idx].id) {
                        let id = lines[idx].id
                        lines[idx] = baseByID[id] ?? result.lines[idx]
                        matched.remove(id)
                        continue
                    } else if !lockedIDs.contains(lines[prevIdx].id) {
                        let prevId = lines[prevIdx].id
                        lines[prevIdx] = baseByID[prevId] ?? result.lines[prevIdx]
                        matched.remove(prevId)
                    }
                }
            }
            lastMatchedNonEmptyIdx = idx
        }

        // Forward monotonicity pass bounded by both preceding and upcoming matched lines so fallback
        // rows and blank markers stay monotonic without inverting against a tight later matched line.
        // Precompute non-empty prefix counts and next matched non-empty index once in O(N).
        var nonEmptyPrefix = [Int](repeating: 0, count: lines.count + 1)
        for idx in lines.indices {
            nonEmptyPrefix[idx + 1] = nonEmptyPrefix[idx] + (isNonEmpty(lines[idx]) ? 1 : 0)
        }
        var nextMatchedAfter = [Int?](repeating: nil, count: lines.count)
        var upcomingMatched: Int?
        for idx in lines.indices.reversed() {
            nextMatchedAfter[idx] = upcomingMatched
            if isNonEmpty(lines[idx]), matched.contains(lines[idx].id) {
                upcomingMatched = idx
            }
        }

        var prevEmittedTimestamp: Double?
        var prevLineEnd: Double = 0.0
        var prevBlankTimestamp: Double?
        var previousWasMatched = false
        for idx in lines.indices {
            let line = lines[idx]
            if isNonEmpty(line) {
                if matched.contains(line.id) {
                    prevEmittedTimestamp = line.timestamp
                    let end = line.duration.map { line.timestamp + $0 }
                        ?? line.words.last.map { $0.timestamp + ($0.duration ?? 0) }
                        ?? (line.timestamp + 0.25)
                    prevLineEnd = max(line.timestamp + 0.25, end)
                    prevBlankTimestamp = nil
                    previousWasMatched = true
                } else {
                    let hasPrev = prevEmittedTimestamp != nil || prevBlankTimestamp != nil
                    // A matched tail and any markers placed after it can yield to the source lyric.
                    let blankFloor = previousWasMatched ? nil : prevBlankTimestamp
                    let preferredMin = max(
                        prevEmittedTimestamp.map { $0 + 0.25 } ?? 0,
                        previousWasMatched ? 0 : prevLineEnd,
                        blankFloor.map { $0 + 0.01 } ?? 0
                    )
                    let hardMin = max(
                        prevEmittedTimestamp.map { $0 + minLineGap } ?? 0,
                        blankFloor ?? 0
                    )
                    let nextMatchedIdx = nextMatchedAfter[idx]
                    let maxStart: Double? = nextMatchedIdx.map { nextIdx in
                        let remainingNonEmpty = nonEmptyPrefix[nextIdx] - nonEmptyPrefix[idx]
                        return max(0.0, lines[nextIdx].timestamp - Double(remainingNonEmpty) * minLineGap)
                    }
                    // Fresh fallback rows may have been pushed by timing that the merge replaced.
                    let source = baseByID[line.id]
                    let fallbackStart = source.map {
                        LyricsAudioAligner.predictedFallbackStart(at: $0.timestamp, medianOffset: result.medianOffset)
                    } ?? line.timestamp
                    let targetStart: Double
                    if let upper = maxStart {
                        if !hasPrev {
                            targetStart = min(upper, fallbackStart)
                        } else if hardMin <= upper {
                            let lower = max(hardMin, min(preferredMin, upper))
                            targetStart = min(upper, max(lower, fallbackStart))
                        } else if let nextIdx = nextMatchedIdx {
                            targetStart = min(lines[nextIdx].timestamp, max(prevEmittedTimestamp ?? 0, upper))
                        } else {
                            targetStart = fallbackStart
                        }
                    } else {
                        targetStart = hasPrev ? max(preferredMin, fallbackStart) : fallbackStart
                    }
                    let original = source ?? line
                    if targetStart != line.timestamp || original != line {
                        let shift = targetStart - original.timestamp
                        let shiftedWords = original.words.map { word in
                            WordTimestamp(timestamp: max(0, word.timestamp + shift), duration: word.duration, text: word.text)
                        }
                        lines[idx] = LyricLine(
                            id: line.id,
                            timestamp: targetStart,
                            duration: original.duration,
                            text: line.text,
                            words: shiftedWords
                        )
                    }
                    let placed = lines[idx]
                    let needsBlankReconciliation = prevBlankTimestamp.map { $0 < prevLineEnd || $0 >= placed.timestamp } ?? false
                    if placed.timestamp < prevLineEnd || needsBlankReconciliation {
                        LyricsAudioAligner.reconcilePrecedingBoundary(in: &lines, before: idx, targetStart: placed.timestamp, ignoringStructuralTags: true)
                    }
                    prevEmittedTimestamp = placed.timestamp
                    let placedEnd = placed.timestamp + max(0.25, placed.duration ?? 0.25)
                    prevLineEnd = nextMatchedIdx.map { min(lines[$0].timestamp, placedEnd) } ?? placedEnd
                    prevBlankTimestamp = nil
                    previousWasMatched = false
                }
            } else {
                let hasPrev = prevEmittedTimestamp != nil || prevBlankTimestamp != nil
                let hardBlankFloor = max(prevEmittedTimestamp ?? 0, prevBlankTimestamp ?? 0)
                let nextMatchedIdx = nextMatchedAfter[idx]
                let blankStep: Double
                let maxBlank: Double?
                if let nextIdx = nextMatchedIdx {
                    let remainingNonEmpty = nonEmptyPrefix[nextIdx] - nonEmptyPrefix[idx + 1]
                    let remainingBlanks = (nextIdx - idx - 1) - remainingNonEmpty
                    let blanksToFit = remainingBlanks + 1
                    let nonEmptyCeiling = max(hardBlankFloor, lines[nextIdx].timestamp - Double(remainingNonEmpty) * minLineGap)
                    let availableSlack = max(0.0, nonEmptyCeiling - hardBlankFloor)
                    blankStep = min(0.01, availableSlack / Double(blanksToFit + 1))
                    maxBlank = max(hardBlankFloor, nonEmptyCeiling - Double(blanksToFit) * blankStep)
                } else {
                    blankStep = 0.01
                    maxBlank = nil
                }
                let minBlank = max(
                    prevLineEnd,
                    prevEmittedTimestamp.map { $0 + blankStep } ?? 0,
                    prevBlankTimestamp.map { $0 + blankStep } ?? 0
                )
                let targetBlank: Double?
                if let upper = maxBlank {
                    let lower = hasPrev ? max(hardBlankFloor, min(minBlank, upper)) : 0.0
                    let clamped = min(upper, max(lower, line.timestamp))
                    targetBlank = clamped != line.timestamp ? clamped : nil
                } else if hasPrev, line.timestamp < minBlank {
                    targetBlank = minBlank
                } else {
                    targetBlank = nil
                }
                if let targetBlank {
                    lines[idx] = LyricLine(
                        id: line.id,
                        timestamp: targetBlank,
                        duration: line.duration,
                        text: line.text,
                        words: line.words
                    )
                }
                prevBlankTimestamp = lines[idx].timestamp
            }
        }

        // Reconcile preceding boundaries for matched lines so restoring a locked line's held tail
        // trims cleanly against an earlier recovered next line and keeps intervening blanks ordered.
        for idx in lines.indices where isNonEmpty(lines[idx]) && matched.contains(lines[idx].id) {
            LyricsAudioAligner.reconcilePrecedingBoundary(in: &lines, before: idx, targetStart: lines[idx].timestamp, ignoringStructuralTags: true)
        }
        return AudioAlignmentResult(
            lines: lines,
            matchedLineCount: matched.count,
            matchedWordCount: result.matchedWordCount,
            medianOffset: result.medianOffset,
            matchedLineIDs: lines.map(\.id).filter(matched.contains)
        )
    }

    /// Lines of a Lyrics Alignment record that were timed from the audio carry its word timings.
    nonisolated static func alignedLineIDs(in lines: [LyricLine]) -> Set<Int> {
        Set(lines.filter { !$0.words.isEmpty }.map(\.id))
    }

    struct LockProgress: Equatable {
        let lockedLines: Int
        let totalLines: Int
        /// Every line is locked or settled, so another play can't lock more.
        let isFinished: Bool

        func status(engine: AudioSyncEngine) -> AudioSyncStatus {
            lockedLines == totalLines
                ? .cached(engine)
                : .settled(engine: engine, lockedLines: lockedLines, totalLines: totalLines)
        }
    }

    /// Counts the lines the aligner can read (it skips lines with no letters, like "♪"). `settledIDs` are
    /// unlocked lines heard since the locked set last grew: the same audio with the same anchors around
    /// them would align them the same way again.
    nonisolated static func lyricsAlignmentProgress(lockedIDs: Set<Int>, settledIDs: Set<Int>, lines: [LyricLine]) -> LockProgress {
        let script = ForcedAlignmentText.Script.detect(in: lines)
        let readable = lines.filter { !ForcedAlignmentText.words(for: $0.text, script: script).isEmpty }.map(\.id)
        return LockProgress(
            lockedLines: readable.filter(lockedIDs.contains).count,
            totalLines: readable.count,
            isFinished: !readable.isEmpty && readable.allSatisfy { lockedIDs.contains($0) || settledIDs.contains($0) }
        )
    }

    private var lockedLineIDs: Set<Int> { Set(anchoredLines.keys).union(lockedThisPlay.keys) }

    private var hasLowYieldLocks: Bool {
        AudioSyncedLyricsRecord.hasLowYieldLocks(lockedIDs: lockedLineIDs, attemptedIDs: attemptedLineIDs)
    }

    /// Attempted lines that stay settled during this play: once prior anchors exist, only lines near a newly
    /// locked anchor reopen rather than wiping every settled line on the track.
    private var settledLineIDs: Set<Int> {
        AudioSyncedLyricsRecord.settledLineIDs(
            attemptedIDs: attemptedLineIDs,
            newlyLockedIDs: Set(lockedThisPlay.keys),
            hadPriorAnchors: !anchoredLines.isEmpty,
            in: baseLines
        )
    }

    nonisolated static func sungSpan(of line: LyricLine) -> ClosedRange<Double>? {
        let lead = LyricsAudioAligner.leadTokenGroups(of: line)
        guard let first = lead.first?.first, let last = lead.last?.last else { return nil }
        return first.timestamp...max(first.timestamp, last.timestamp + (last.duration ?? 0))
    }

    /// Words of aligned lines, with a word timed by syllable regrouped so it carries its syllables again.
    nonisolated static func recognizedWords(of lines: [LyricLine]) -> [RecognizedAudioWord] {
        lines.flatMap { line in
            LyricsAudioAligner.leadTokenGroups(of: line).compactMap { group in
                guard let first = group.first, let last = group.last else { return nil }
                return RecognizedAudioWord(
                    text: group.map(\.text).joined().trimmingCharacters(in: .whitespaces),
                    startTime: first.timestamp,
                    duration: last.timestamp + (last.duration ?? 0.2) - first.timestamp,
                    confidence: 1,
                    syllables: group.count > 1
                        ? group.map { RecognizedAudioWord.Syllable(text: $0.text, startTime: $0.timestamp) }
                        : nil,
                    sourceLineId: line.id
                )
            }
        }
    }

    /// The vocal level rise (dB) at a nearly confident line's start that locks it. Tuned on JamendoLyrics
    /// (English): with `onsetLockConfidence` it adds a fifth more locked lines, about 93% of them within
    /// 300 ms of the sung start on songs it was not tuned on.
    nonisolated static let onsetLockRise: Float = 3
    private nonisolated static let harmonicityLockRise: Float = 0.35
    nonisolated static let consensusStartTolerance = 0.15
    nonisolated static let consensusEndTolerance = 0.25

    /// A well-timed line locks when confident, or when nearly confident and either starting on a vocal onset
    /// or agreeing closely with an earlier unlocked pass.
    nonisolated static func locks(
        _ line: LyricLine,
        confident: Set<Int>,
        nearlyConfident: Set<Int>,
        envelope: VocalEnvelope,
        pitchContour: VocalPitchContour? = nil,
        priorAlignedLine: LyricLine? = nil
    ) -> Bool {
        let groups = LyricsAudioAligner.leadTokenGroups(of: line)
        guard !groups.joined().contains(where: { word in
            (word.duration ?? 0) <= 0 && (!LyricsAudioAligner.normalizeToken(word.text).isEmpty || !ForcedAlignmentText.displaySymbols(in: word.text).isEmpty)
        }) else {
            return false
        }
        let spans = groups.compactMap { group -> (start: Double, end: Double)? in
            guard let first = group.first, let last = group.last else { return nil }
            return (first.timestamp, last.timestamp + (last.duration ?? 0))
        }
        let maxWordSpan = LyricsForcedAligner.maxWordSpan
        guard let first = spans.first, let last = spans.last else { return false }
        // Interpolated backing vocals extend the displayed line beyond the last lead word.
        let finalDisplayEnd = line.words.last.map { $0.timestamp + ($0.duration ?? 0) } ?? last.end
        guard spans.allSatisfy({ $0.end - $0.start <= maxWordSpan }),
              last.end - first.start <= LyricsForcedAligner.maxLineSpan(wordCount: spans.count),
              !zip(spans, spans.dropFirst()).contains(where: { $1.start - $0.end > maxWordSpan }),
              line.timestamp + (line.duration ?? 0) - max(last.end, finalDisplayEnd) <= maxWordSpan
        else { return false }
        if confident.contains(line.id) { return true }
        guard nearlyConfident.contains(line.id) else { return false }
        if let priorAlignedLine,
           let priorSpan = sungSpan(of: priorAlignedLine),
           abs(first.start - priorSpan.lowerBound) <= consensusStartTolerance,
           abs(last.end - priorSpan.upperBound) <= consensusEndTolerance {
            return true
        }
        let onsetEnd = first.start + 0.25
        if let pitchContour, let clarity = pitchContour.meanHarmonicity(from: first.start, to: onsetEnd) {
            // Breathy vocals masked by instruments keep full-mix harmonicity low, so the full mix vetoes only near-zero clarity.
            let floor = pitchContour.isSeparatedVocals(from: first.start, to: onsetEnd)
                ? VocalPitchContour.unvoicedFloor : VocalPitchContour.fullMixUnvoicedFloor
            if clarity < floor,
               let peak = pitchContour.maxHarmonicity(from: first.start, to: onsetEnd),
               peak < VocalPitchContour.voicedThreshold {
                return false
            }
            if clarity >= VocalPitchContour.voicedThreshold,
               let harmonicityRise = pitchContour.harmonicityRise(at: first.start),
               harmonicityRise >= harmonicityLockRise {
                return true
            }
        }
        return (envelope.onsetRise(at: first.start) ?? 0) >= onsetLockRise
    }

    private func clearSessionAlignment() {
        recognizedWords = []
        priorHeardWords = []
        lockedThisPlay = [:]
        attemptedLineIDs = []
        attemptedThisPlay = []
        confidentLineIDs = []
        nearlyConfidentLineIDs = []
        acceptedSessionLines = [:]
        priorUnlockedLines = [:]
        cachedChromaTemplates = []
        cachedAlignedLineCount = 0
    }

    /// Lyrics Alignment locks each confidently aligned line and keeps listening until no further play could
    /// lock another (see `lyricsAlignmentProgress`), saving after each chunk so a later play only listens for the rest.
    private func applyLyricsAlignment(replacingAttempts: Set<Int>, reporter: LineAttemptReporting?) {
        guard !silencePermissionFlagged, !baseLines.isEmpty else { return }
        let fresh = alignHeardWords()
        let direct = keepingLockedAndAccepted(fresh, replacingAttempts: replacingAttempts)
        // Only a line aligned from this play's audio that survived conflict resolution against existing
        // locks can lock itself, never a conflicting match or one carried over unlocked.
        let survivedNewMatches = Set(fresh.matchedLineIDs)
            .intersection(direct.matchedLineIDs)
            .subtracting(lockedLineIDs)
            .subtracting(fresh.clampedRunawayLineIDs)
        var lockedNewLine = false
        for line in direct.lines where survivedNewMatches.contains(line.id) && Self.locks(
            line,
            confident: confidentLineIDs,
            nearlyConfident: nearlyConfidentLineIDs,
            envelope: vocalEnvelope,
            pitchContour: vocalPitchContour,
            priorAlignedLine: priorUnlockedLines[line.id]
        ) {
            lockedThisPlay[line.id] = line
            lockedNewLine = true
        }
        if reporter?.discardStaleOffset(lockedLineIDs: lockedLineIDs) == true {
            clearSessionAlignment()
            if let trackId = activeTrackId { removeCachedAlignment(trackId: trackId) }
            let lines = baseLines
            let fallback = AudioAlignmentResult(lines: lines, matchedLineCount: 0, matchedWordCount: 0, medianOffset: nil)
            diagnostics.update {
                $0.totalRecognizedWords = 0
                $0.recentWords.removeAll()
                $0.record(alignment: fallback, sourceLines: lines)
            }
            diagnostics.note("Released provisional lyric timing after consecutive missed lines")
            state.applyAudioSyncedLines(lines)
            state.audioSyncStatus = .syncing(engine: .lyricsAlignment, alignedLines: 0, totalLines: lines.count)
            return
        }
        // Only direct alignment can establish a locked template.
        let result = recoveringRepeatedLines(direct, fresh: fresh)
        let lines = baseLines
        diagnostics.update { $0.record(alignment: result, sourceLines: lines) }
        let progress = Self.lyricsAlignmentProgress(lockedIDs: lockedLineIDs, settledIDs: settledLineIDs, lines: baseLines)
        if progress.totalLines == 0 {
            stopActiveSession()
            state.audioSyncStatus = .unavailable("Lyrics script is not supported by Lyrics Alignment")
            return
        }
        // Treat a newly acquired lock as progress even if it displaced multiple unlocked cached lines
        // and temporarily lowered `matchedLineCount`, while still refusing to downgrade legacy caches
        // whose lines weren't tracked in `acceptedSessionLines`.
        let matchedIDs = Set(result.matchedLineIDs)
        let displacedAcceptedCount = acceptedSessionLines.keys.filter { !matchedIDs.contains($0) }.count
        let droppedPreviouslyAccepted = acceptedSessionLines.keys.contains {
            replacingAttempts.contains($0) && !matchedIDs.contains($0)
        }
        let droppedPriorWords = priorHeardWords.contains { word in
            word.sourceLineId.map { replacingAttempts.contains($0) && !matchedIDs.contains($0) } ?? false
        }
        let newLockDisplacedCache = lockedNewLine
            && (result.matchedLineCount + displacedAcceptedCount >= cachedAlignedLineCount)
        if droppedPreviouslyAccepted || (result.matchedLineCount > 0 && (newLockDisplacedCache || result.matchedLineCount >= cachedAlignedLineCount)) {
            acceptedSessionLines = Dictionary(
                result.lines.filter { matchedIDs.contains($0.id) }.map { ($0.id, $0) },
                uniquingKeysWith: { _, latest in latest }
            )
            persistAlignment(result, engine: .lyricsAlignment, forceUpdateCount: newLockDisplacedCache || droppedPreviouslyAccepted)
            state.applyAudioSyncedLines(result.lines)
        } else if droppedPriorWords || (cachedAlignedLineCount == 0 && (!replacingAttempts.isEmpty || progress.isFinished)) {
            persistAlignment(result, engine: .lyricsAlignment)
        }
        if progress.isFinished {
            // Keep the playback boundary so the next repeat can retry a poorly aligned pass.
            let restartBoundary = hasLowYieldLocks ? lastPlayback : nil
            stopActiveSession()
            lastPlayback = restartBoundary
            state.audioSyncStatus = progress.status(engine: .lyricsAlignment)
        } else {
            state.audioSyncStatus = .syncing(
                engine: .lyricsAlignment,
                alignedLines: max(result.matchedLineCount, cachedAlignedLineCount),
                totalLines: baseLines.count
            )
        }
    }

    private func persistCurrentAlignmentIfReady() {
        let engine = state.audioSyncEngine
        guard engine != .off, !baseLines.isEmpty, !recognizedWords.isEmpty else { return }
        let result = currentAlignment()
        guard result.matchedLineCount > 0, result.matchedLineCount > cachedAlignedLineCount else { return }
        persistAlignment(result, engine: engine)
    }

    private func persistAlignment(_ result: AudioAlignmentResult, engine: AudioSyncEngine, forceUpdateCount: Bool = false) {
        guard let trackId = activeTrackId else { return }
        let sourceCount = baseLines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let templates = engine == .lyricsAlignment
            ? ChorusSelfSimilarity.extractCachedTemplates(
                in: result.lines,
                lockedIDs: lockedLineIDs,
                chroma: chromaProfile,
                existing: cachedChromaTemplates
            )
            : []
        if engine == .lyricsAlignment {
            cachedChromaTemplates = templates
        }
        let record = AudioSyncedLyricsRecord(
            trackId: trackId,
            engine: engine,
            syncedAt: Date(),
            medianOffset: result.medianOffset,
            alignedLineCount: result.matchedLineCount,
            sourceLineCount: sourceCount,
            lines: result.lines,
            heardWords: refinedHeardWords(),
            lockedLineIDs: engine == .lyricsAlignment ? lockedLineIDs.sorted() : nil,
            attemptedLineIDs: engine == .lyricsAlignment ? attemptedLineIDs.subtracting(lockedLineIDs).sorted() : nil,
            lockedAtPlayStart: engine == .lyricsAlignment ? anchoredLines.count : nil,
            newlyLockedLineIDs: engine == .lyricsAlignment ? lockedThisPlay.keys.sorted() : nil,
            chromaTemplates: templates.isEmpty ? nil : templates
        )
        dependencies.cacheQueue.async { [cache] in
            cache.save(record)
        }
        cachedAlignedLineCount = forceUpdateCount
            ? result.matchedLineCount
            : max(cachedAlignedLineCount, result.matchedLineCount)
    }

    /// Finishes an in-flight chunk and any buffered tail audio for the outgoing track in the background so a
    /// track switch or crossfade does not drop the final lines before they can lock or settle into the cache.
    private func finalizeOutgoingTrackTailIfNeeded() {
        guard isLiveSyncActive,
              state.audioSyncEngine == .lyricsAlignment,
              !silencePermissionFlagged,
              let trackId = activeTrackId,
              !baseLines.isEmpty,
              let engine = chunkEngine
        else { return }
        let hasRemainingAudio = !sentFinalChunk
            && !audioSampleBuffer.isEmpty
            && (!dependencies.usesProcessTap || hasReceivedAudibleAudioThisSession)
        let inFlightTask = chunkProcessingTask
        guard inFlightTask != nil || hasRemainingAudio || engine.hasHeldAudio else { return }

        // Hand ownership to the background finalizer before `stopActiveSession()` tears down live state.
        chunkEngine = nil
        chunkProcessingTask = nil
        let separator = vocalSeparator
        vocalSeparator = nil

        let remainingMid = hasRemainingAudio ? audioSampleBuffer : []
        let remainingSide = hasRemainingAudio && audioSideBuffer.count == audioSampleBuffer.count ? audioSideBuffer : []
        let remainingSpans = hasRemainingAudio ? captureSpanStarts : []
        let sampleRate = activeSampleRate
        let fallbackChunkStart = chunkStartPos ?? currentPlaybackPosition()
        let playbackRate = chunkPlaybackRate
        let chunkFrames = max(1, Int(sampleRate * chunkDurationSeconds))
        let resample = dependencies.resampleForRecognition
        let cache = cache
        let cacheQueue = dependencies.cacheQueue

        let baseLines = baseLines
        let anchoredLines = anchoredLines
        var lockedThisPlay = lockedThisPlay
        let acceptedSessionLines = acceptedSessionLines
        let priorUnlockedLines = priorUnlockedLines
        var attemptedLineIDs = attemptedLineIDs
        var attemptedThisPlay = attemptedThisPlay
        var confidentLineIDs = confidentLineIDs
        var nearlyConfidentLineIDs = nearlyConfidentLineIDs
        var recognizedWords = recognizedWords
        let priorHeardWords = priorHeardWords
        let vocalEnvelope = vocalEnvelope
        var vocalPitchContour = vocalPitchContour
        var chromaProfile = chromaProfile
        let cachedChromaTemplates = cachedChromaTemplates
        let cachedAlignedLineCount = cachedAlignedLineCount
        let splitsSyllables = state.syllableTiming

        let taskID = UUID()
        let task = Task.detached(priority: .background) { [weak self] in
            defer {
                engine.shutdown()
                Task { @MainActor [weak self] in
                    if self?.pendingTailFinalizations[trackId]?.id == taskID {
                        self?.pendingTailFinalizations.removeValue(forKey: trackId)
                    }
                }
            }

            if let inFlightTask, let outcome = await inFlightTask.value {
                if let pitch = outcome.pitch {
                    vocalPitchContour.merge(pitch)
                }
                chromaProfile.merge(outcome.chroma)
                recognizedWords.append(contentsOf: outcome.words)
            }
            guard !Task.isCancelled else { return }

            let requests = remainingMid.isEmpty ? [] : Self.tailRequests(
                sampleCount: remainingMid.count,
                spans: remainingSpans.isEmpty ? [(0, fallbackChunkStart, false)] : remainingSpans,
                sampleRate: sampleRate,
                rate: playbackRate,
                chunkFrames: chunkFrames
            )
            for piece in requests {
                guard !Task.isCancelled else { return }
                // A drop starts a new run, which would discard the audio the previous run held back.
                if piece.startsNewSpan, let words = try? engine.finishRun(continuesAfterGap: true) {
                    recognizedWords.append(contentsOf: words)
                }
                let segMid = Array(remainingMid[piece.range])
                let segSide = remainingSide.count == remainingMid.count ? Array(remainingSide[piece.range]) : []
                guard let audio = Self.recognitionAudio(
                    mid: segMid, side: segSide, sampleRate: sampleRate, separator: separator, resample: resample
                ) else { break }
                guard !Task.isCancelled else { return }

                let pitch = Self.analyzePitch(
                    raw: (segMid, segSide, sampleRate),
                    recognitionAudio: audio,
                    start: piece.startTime,
                    rate: playbackRate
                )
                if let pitch {
                    vocalPitchContour.merge(pitch)
                }
                for span in piece.chromaSpans {
                    chromaProfile.append(
                        samples: Array(remainingMid[span.range]), sampleRate: sampleRate, startTime: span.time, rate: playbackRate
                    )
                }

                let request = AudioChunkRequest(
                    samples: AudioLevel.normalizedForRecognition(audio.samples),
                    sampleRate: audio.sampleRate,
                    chunkStartTime: piece.startTime,
                    playbackRate: playbackRate,
                    isFinal: piece.isFinal,
                    startsNewSpan: piece.startsNewSpan
                )
                if let words = try? await engine.transcribe(request) {
                    recognizedWords.append(contentsOf: words)
                }
            }
            guard !Task.isCancelled else { return }
            if let words = try? engine.finishRun(continuesAfterGap: false) {
                recognizedWords.append(contentsOf: words)
            }

            var newAttempts: Set<Int> = []
            let reporter = engine as? LineAttemptReporting
            if let reporter {
                let reported = reporter.attemptedLineIDs
                newAttempts = reported.subtracting(attemptedThisPlay)
                attemptedLineIDs.formUnion(reported)
                attemptedThisPlay.formUnion(newAttempts)
                confidentLineIDs.formUnion(reporter.confidentLineIDs)
                nearlyConfidentLineIDs.formUnion(reporter.nearlyConfidentLineIDs)
            }

            let allHeard: [RecognizedAudioWord]
            if anchoredLines.isEmpty {
                let unattemptedPrior = priorHeardWords.filter { word in
                    word.sourceLineId.map { !attemptedThisPlay.contains($0) } ?? true
                }
                allHeard = Self.mergeHeardWords(prior: unattemptedPrior, current: recognizedWords)
            } else {
                allHeard = (Self.recognizedWords(of: Array(anchoredLines.values)) + recognizedWords)
                    .sorted { $0.startTime < $1.startTime }
            }
            let (refinedWords, _) = WaveformTimingRefiner.refine(
                allHeard, envelope: vocalEnvelope, pitchContour: vocalPitchContour, timingError: 0.06
            )
            let fresh = LyricsAudioAligner.align(
                lines: baseLines,
                recognizedWords: refinedWords,
                regroupsCJKWords: false,
                splitsSyllables: splitsSyllables
            )
            let direct = Self.keepingLockedAndAccepted(
                fresh,
                baseLines: baseLines,
                anchoredLines: anchoredLines,
                lockedThisPlay: lockedThisPlay,
                acceptedSessionLines: acceptedSessionLines,
                replacingAttempts: newAttempts
            )
            let existingLocked = Set(anchoredLines.keys).union(lockedThisPlay.keys)
            let survivedNewMatches = Set(fresh.matchedLineIDs)
                .intersection(direct.matchedLineIDs)
                .subtracting(existingLocked)
                .subtracting(fresh.clampedRunawayLineIDs)
            var lockedNewLine = false
            for line in direct.lines where survivedNewMatches.contains(line.id) && Self.locks(
                line,
                confident: confidentLineIDs,
                nearlyConfident: nearlyConfidentLineIDs,
                envelope: vocalEnvelope,
                pitchContour: vocalPitchContour,
                priorAlignedLine: priorUnlockedLines[line.id]
            ) {
                lockedThisPlay[line.id] = line
                lockedNewLine = true
            }
            let lockedIDs = Set(anchoredLines.keys).union(lockedThisPlay.keys)
            if reporter?.discardStaleOffset(lockedLineIDs: lockedIDs) == true {
                await Self.enqueueUnlessCancelled(on: cacheQueue) { cache.remove(trackId: trackId) }
                return
            }

            var result = direct
            if !lockedIDs.isEmpty, !chromaProfile.segments.isEmpty {
                let protectedTargetIDs = Set(fresh.matchedLineIDs)
                    .intersection(direct.matchedLineIDs)
                    .subtracting(fresh.clampedRunawayLineIDs)
                let recovery = ChorusSelfSimilarity.recoverRepeatedLines(
                    in: direct.lines,
                    lockedIDs: lockedIDs,
                    protectedTargetIDs: protectedTargetIDs,
                    chroma: chromaProfile,
                    cachedTemplates: cachedChromaTemplates,
                    medianOffset: direct.medianOffset,
                    sourceTimestamps: Dictionary(uniqueKeysWithValues: baseLines.map { ($0.id, $0.timestamp) })
                )
                if !recovery.recoveredLineIDs.isEmpty {
                    let matched = Set(direct.matchedLineIDs).union(recovery.recoveredLineIDs)
                    result = AudioAlignmentResult(
                        lines: recovery.lines,
                        matchedLineCount: matched.count,
                        matchedWordCount: direct.matchedWordCount,
                        medianOffset: direct.medianOffset,
                        matchedLineIDs: recovery.lines.map(\.id).filter(matched.contains),
                        clampedRunawayLineIDs: direct.clampedRunawayLineIDs.subtracting(recovery.recoveredLineIDs)
                    )
                }
            }

            let settled = AudioSyncedLyricsRecord.settledLineIDs(
                attemptedIDs: attemptedLineIDs,
                newlyLockedIDs: Set(lockedThisPlay.keys),
                hadPriorAnchors: !anchoredLines.isEmpty,
                in: baseLines
            )
            let progress = Self.lyricsAlignmentProgress(lockedIDs: lockedIDs, settledIDs: settled, lines: baseLines)
            guard progress.totalLines > 0 else { return }

            let matchedIDs = Set(result.matchedLineIDs)
            let displacedAcceptedCount = acceptedSessionLines.keys.filter { !matchedIDs.contains($0) }.count
            let droppedPreviouslyAccepted = acceptedSessionLines.keys.contains {
                newAttempts.contains($0) && !matchedIDs.contains($0)
            }
            let droppedPriorWords = priorHeardWords.contains { word in
                word.sourceLineId.map { newAttempts.contains($0) && !matchedIDs.contains($0) } ?? false
            }
            let newLockDisplacedCache = lockedNewLine
                && (result.matchedLineCount + displacedAcceptedCount >= cachedAlignedLineCount)
            let shouldPersist = droppedPreviouslyAccepted
                || (result.matchedLineCount > 0 && (newLockDisplacedCache || result.matchedLineCount >= cachedAlignedLineCount))
                || droppedPriorWords
                || (cachedAlignedLineCount == 0 && (!newAttempts.isEmpty || progress.isFinished))
            guard shouldPersist, !Task.isCancelled else { return }

            let sourceCount = baseLines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            let templates = ChorusSelfSimilarity.extractCachedTemplates(
                in: result.lines,
                lockedIDs: lockedIDs,
                chroma: chromaProfile,
                existing: cachedChromaTemplates
            )
            let record = AudioSyncedLyricsRecord(
                trackId: trackId,
                engine: .lyricsAlignment,
                syncedAt: Date(),
                medianOffset: result.medianOffset,
                alignedLineCount: result.matchedLineCount,
                sourceLineCount: sourceCount,
                lines: result.lines,
                heardWords: refinedWords,
                lockedLineIDs: lockedIDs.sorted(),
                attemptedLineIDs: attemptedLineIDs.subtracting(lockedIDs).sorted(),
                lockedAtPlayStart: anchoredLines.count,
                newlyLockedLineIDs: lockedThisPlay.keys.sorted(),
                chromaTemplates: templates.isEmpty ? nil : templates
            )
            await Self.enqueueUnlessCancelled(on: cacheQueue) { cache.save(record) }
        }
        pendingTailFinalizations[trackId] = (taskID, task)
    }

    struct TailRequest: Equatable {
        struct ChromaSpan: Equatable {
            let range: Range<Int>
            let time: Double
        }

        let range: Range<Int>
        let startTime: Double
        let startsNewSpan: Bool
        var isFinal: Bool
        /// The capture spans inside `range` at their own track times, as the live path extracts chroma.
        let chromaSpans: [ChromaSpan]
    }

    /// Splits buffered tail audio into requests no longer than a live chunk, starting a new run at each drop.
    /// The aligner's window fits one live chunk plus its held-back context, so a longer request would misplace frames.
    nonisolated static func tailRequests(
        sampleCount: Int,
        spans: [(offset: Int, time: Double, followsDrop: Bool)],
        sampleRate: Double,
        rate: Double,
        chunkFrames: Int
    ) -> [TailRequest] {
        guard sampleCount > 0, let first = spans.first else { return [] }
        let spanEnds = spans.dropFirst().map(\.offset) + [sampleCount]
        func time(at offset: Int, in index: Int) -> Double {
            spans[index].time + Double(offset - spans[index].offset) / max(sampleRate, 1) * rate
        }

        var segments: [(range: Range<Int>, followsDrop: Bool)] = []
        var segmentStart = 0
        var segmentFollowsDrop = first.followsDrop
        for span in spans.dropFirst() where span.followsDrop && span.offset > segmentStart && span.offset < sampleCount {
            segments.append((segmentStart..<span.offset, segmentFollowsDrop))
            segmentStart = span.offset
            segmentFollowsDrop = true
        }
        segments.append((segmentStart..<sampleCount, segmentFollowsDrop))

        var requests: [TailRequest] = []
        for segment in segments {
            for start in stride(from: segment.range.lowerBound, to: segment.range.upperBound, by: max(1, chunkFrames)) {
                let range = start..<min(start + max(1, chunkFrames), segment.range.upperBound)
                let startSpan = spans.lastIndex { $0.offset <= start } ?? 0
                let chromaSpans = spans.indices.compactMap { index -> TailRequest.ChromaSpan? in
                    let lower = max(range.lowerBound, spans[index].offset)
                    let upper = min(range.upperBound, spanEnds[index])
                    return lower < upper ? TailRequest.ChromaSpan(range: lower..<upper, time: time(at: lower, in: index)) : nil
                }
                requests.append(TailRequest(
                    range: range,
                    startTime: time(at: start, in: startSpan),
                    startsNewSpan: segment.followsDrop && start == segment.range.lowerBound,
                    isFinal: false,
                    chromaSpans: chromaSpans
                ))
            }
        }
        requests[requests.count - 1].isFinal = true
        return requests
    }

    /// Force resync cancels finalizers on the main actor, so checking there orders a finalizer's cache write
    /// before resync's removal or drops it.
    private nonisolated static func enqueueUnlessCancelled(
        on queue: DispatchQueue,
        _ operation: @escaping @Sendable () -> Void
    ) async {
        await MainActor.run {
            guard !Task.isCancelled else { return }
            queue.async(execute: operation)
        }
    }

    struct AudioChunkRequest: Sendable {
        let samples: [Float]
        let sampleRate: Int
        let chunkStartTime: Double
        /// Media seconds per recorded second, used to map in-chunk word offsets to track time.
        let playbackRate: Double
        /// The audio reaches the end of the track: no later chunk follows to complete its last lines.
        var isFinal = false
        /// The capture FIFO dropped frames before this chunk.
        var startsNewSpan = false
    }
}
