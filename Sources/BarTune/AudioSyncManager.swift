import AppKit
import AVFoundation
import Combine
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

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
            capturedAt: retainedStart
        )
    }
}

protocol AudioCaptureProviding: AnyObject {
    var onAudioSamples: (@Sendable (CapturedAudio) -> Void)? { get set }
    @MainActor func start(targetBundleIds: Set<String>) async throws
    @MainActor func stop()
}

enum AudioLevel {
    /// Scales a chunk so its peak reaches 0.95. Capture follows the player's volume, and a quiet
    /// player leaves too little signal for recognition. Near-silence is left as is so its noise isn't amplified.
    static func normalizedForRecognition(_ samples: [Float], maxGain: Float = 100) -> [Float] {
        let peak = samples.reduce(Float(0)) { max($0, abs($1)) }
        guard peak > 0.0001 else { return samples }
        let gain = min(0.95 / peak, maxGain)
        return samples.map { $0 * gain }
    }
}

enum AudioSampleExtractor {
    /// Mono mix and side signal of one or more equal-length channels.
    static func midSide(channels: [[Float]]) -> (mid: [Float], side: [Float]) {
        guard let first = channels.first else { return ([], []) }
        let count = channels.map(\.count).min() ?? 0
        guard channels.count > 1 else { return (Array(first.prefix(count)), []) }
        let scale = 1 / Float(channels.count)
        var mid = [Float](repeating: 0, count: count)
        var side = [Float](repeating: 0, count: count)
        for index in 0..<count {
            var sum: Float = 0
            for channel in channels {
                sum += channel[index]
            }
            mid[index] = sum * scale
            side[index] = (channels[0][index] - channels[1][index]) / 2
        }
        return (mid, side)
    }

    /// Splits `channelCount`-way interleaved samples into one array per channel.
    static func deinterleave(_ samples: [Float], channelCount: Int) -> [[Float]] {
        guard channelCount > 1 else { return [samples] }
        let frames = samples.count / channelCount
        return (0..<channelCount).map { channel in
            (0..<frames).map { samples[$0 * channelCount + channel] }
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
        audioQueue: DispatchQueue
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
        audioQueue: DispatchQueue
    ) async throws -> SystemAudioStreamControlling {
        guard let scDisplay = display.scDisplay else {
            throw SystemAudioCaptureError.noDisplayAvailable
        }
        let scApps = includedApplications.compactMap(\.scApplication)
        guard !scApps.isEmpty else {
            throw SystemAudioCaptureError.unresolvedPlayer
        }

        let scFilter = SCContentFilter(display: scDisplay, including: scApps, exceptingWindows: [])
        let config = SystemAudioCapture.makeStreamConfiguration()

        let newStream = SCStream(filter: scFilter, configuration: config, delegate: nil)
        try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)
        try await newStream.startCapture()
        return LiveSCStreamHandle(stream: newStream)
    }
}

/// Coalesces frequent ScreenCaptureKit audio callbacks (~20 ms) on `audioQueue` into coarser batches
/// (~200 ms) to reduce MainActor wakeups without distorting capture timestamps or gap detection.
struct AudioCaptureBatcher {
    let targetDuration: Double
    private var samples: [Float] = []
    private var side: [Float] = []
    private var sampleRate: Double = 0
    private var firstCapturedAt: Double?
    private var firstCaptureDelay: Double?
    private var hasSide = false

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
            if rateChanged || sideChanged || gapDetected, let flushed = flush(deliveryUptime: deliveryUptime) {
                ready.append(flushed)
            }
        }

        if samples.isEmpty {
            sampleRate = audio.sampleRate
            firstCapturedAt = audio.capturedAt
            firstCaptureDelay = audio.captureDelay
            hasSide = incomingHasSide
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
            capturedAt: firstCapturedAt
        )
        samples.removeAll(keepingCapacity: false)
        side.removeAll(keepingCapacity: false)
        sampleRate = 0
        firstCapturedAt = nil
        firstCaptureDelay = nil
        hasSide = false
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

    static func makeStreamConfiguration() -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16000
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
    func start(targetBundleIds: Set<String> = []) async throws {
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
                audioQueue: audioQueue
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
}

@MainActor
final class AudioSyncManager {
    struct Dependencies {
        var capture: AudioCaptureProviding
        var hasScreenCaptureAccess: () -> Bool
        var requestScreenCaptureAccess: () -> Void
        var chunkDurationSeconds: Double
        var launchLyricsAligner: @Sendable (
            _ lines: [LyricLine],
            _ anchors: [Int: ClosedRange<Double>]
        ) async -> AudioChunkTranscribing? = {
            await LyricsAlignerModel.launch(lines: $0, anchors: $1)
        }
        var vocalEnvelopeNow: @Sendable () -> ContinuousClock.Instant = { .now }
        var vocalEnvelopeSleep: @Sendable (ContinuousClock.Instant) async throws -> Void = {
            try await Task.sleep(until: $0, clock: .continuous)
        }
        var releaseCachedModel: @Sendable () -> Void = { LyricsAlignerModel.releaseCachedModel() }
        var idleModelReleaseDelay: Duration = .seconds(60)
        var idleModelReleaseSleep: @Sendable (Duration) async throws -> Void = {
            try await Task.sleep(for: $0)
        }

        static func live() -> Dependencies {
            Dependencies(
                capture: SystemAudioCapture(),
                hasScreenCaptureAccess: { CGPreflightScreenCaptureAccess() },
                requestScreenCaptureAccess: { CGRequestScreenCaptureAccess() },
                chunkDurationSeconds: 12.0
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
    private var syncGeneration: UInt64 = 0
    private var captureTargetGeneration: UInt64 = 0

    private static let seekTolerance: Double = 2.0
    /// Audio this close to the track's end is sent as its final chunk, before the player moves on.
    static let trackEndMargin: Double = 1.0

    // Audio chunk state
    private var audioSampleBuffer: [Float] = []
    private var audioSideBuffer: [Float] = []
    private var chunkStartPos: Double?
    private var chunkPlaybackRate: Double = 1.0
    private var pendingSeekPos: Double?
    /// The audio up to the track's end was sent; reset by a seek, which can reach the end again.
    private var sentFinalChunk = false
    /// Uptime of the last detected seek; deliveries captured before it hold pre-seek audio.
    private var seekBoundary: TimeInterval = 0
    /// Last playback state this manager saw; seeks are detected against it because `LyricsState` is updated first.
    private var lastPlayback: (position: Double, uptime: TimeInterval, rate: Double, isPlaying: Bool)?
    private var alignerStartupTask: Task<Void, Never>?
    private var chunkProcessingTask: Task<Void, Never>?
    private var modelIdleReleaseTask: Task<Void, Never>?
    private var modelMayBeCached = false
    private var chunkEngine: AudioChunkTranscribing?
    private var activeSampleRate: Double = 16000.0
    private var capturedSeconds: Double = 0
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
        modelIdleReleaseTask = Task { [weak self] in
            do {
                try await sleepFor(delay)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  !self.isLiveSyncActive,
                  self.alignerStartupTask == nil
            else { return }
            self.modelIdleReleaseTask = nil
            self.modelMayBeCached = false
            release()
        }
    }

    private func clearAudioBuffers(keepingCapacity: Bool) {
        audioSampleBuffer.removeAll(keepingCapacity: keepingCapacity)
        audioSideBuffer.removeAll(keepingCapacity: keepingCapacity)
    }

    func stop() {
        cacheActiveVocalEnvelopeIfNonEmpty()
        syncGeneration &+= 1
        captureTargetGeneration &+= 1
        isLiveSyncActive = false
        capture.onAudioSamples = nil
        capture.stop()
        alignerStartupTask?.cancel()
        alignerStartupTask = nil
        chunkProcessingTask?.cancel()
        chunkProcessingTask = nil
        pendingVocalEnvelopeNotification?.cancel()
        pendingVocalEnvelopeNotification = nil
        chunkEngine?.shutdown()
        chunkEngine = nil
        clearAudioBuffers(keepingCapacity: false)
        chunkStartPos = nil
        chunkPlaybackRate = 1.0
        pendingSeekPos = nil
        lastPlayback = nil
        capturedSeconds = 0
        scheduleIdleModelReleaseIfNeeded()
    }

    /// Evaluates whether the current track can load cached audio-synced lyrics or needs live alignment.
    func handleTrackLoaded(track: TrackInfo, rawLines: [LyricLine], forceResync: Bool = false) {
        let trackChanged = activeTrackId != track.id
        stop()
        activeTrackId = track.id
        activeSourceBundleId = track.sourceBundleId
        baseLines = rawLines
        recognizedWords = []
        cachedAlignedLineCount = 0
        priorHeardWords = []
        anchoredLines = [:]
        lockedThisPlay = [:]
        attemptedLineIDs = []
        attemptedThisPlay = []
        confidentLineIDs = []
        nearlyConfidentLineIDs = []
        acceptedSessionLines = [:]
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

        let rawNonEmptyCount = rawLines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        let expectedSourceLineCount = rawNonEmptyCount > 0 ? rawNonEmptyCount : nil

        if forceResync {
            if !rawLines.isEmpty {
                cache.remove(trackId: track.id)
            }
        } else if let loaded = cache.load(trackId: track.id) {
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
                    attemptedLineIDs = cached.settledLineIDs
                } else {
                    priorHeardWords = cached.heardWords ?? []
                }
            } else if current {
                // Keep recognized words for refinement without applying unreliable timings.
                priorHeardWords = cached.heardWords ?? []
                if priorHeardWords.isEmpty {
                    cache.remove(trackId: track.id)
                }
            } else {
                cache.remove(trackId: track.id)
            }
        }

        guard !rawLines.isEmpty else {
            state.audioSyncStatus = .idle
            return
        }

        if !forceResync, Self.hasPreexistingWordSync(rawLines) {
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
        capture.stop()
        // Buffered samples belong to the old capture's timeline; the next sample starts a new chunk.
        clearAudioBuffers(keepingCapacity: true)
        chunkStartPos = nil
        // Deliveries still queued from the old capture must not start the new chunk.
        seekBoundary = ProcessInfo.processInfo.systemUptime
        startCaptureForCurrentTarget(trackId: track.id, engine: state.audioSyncEngine, generation: syncGeneration)
    }

    private func startCaptureForCurrentTarget(
        trackId: String,
        engine: AudioSyncEngine,
        generation: UInt64
    ) {
        captureTargetGeneration &+= 1
        let captureGeneration = captureTargetGeneration
        installChunkHandler(trackId: trackId, generation: generation, captureGeneration: captureGeneration)
        let targetBundles = Self.targetBundleIdentifiers(for: trackId, sourceBundleId: activeSourceBundleId)
        Task { [weak self] in
            guard let self,
                  self.syncGeneration == generation,
                  self.captureTargetGeneration == captureGeneration,
                  self.isLiveSyncActive,
                  self.activeTrackId == trackId,
                  self.state.audioSyncEngine == engine
            else { return }
            do {
                try await self.capture.start(targetBundleIds: targetBundles)
            } catch {
                guard self.syncGeneration == generation,
                      self.captureTargetGeneration == captureGeneration
                else { return }
                self.persistCurrentAlignmentIfReady()
                self.handleCaptureStartFailure(error, generation: generation)
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
        guard !isPlaying, isLiveSyncActive else { return }
        // Persist whatever alignment we gathered before pausing/stopping.
        persistCurrentAlignmentIfReady()
    }

    private static func sanitizedPlaybackRate(_ rate: Double) -> Double {
        (rate.isFinite && rate > 0) ? rate : 1.0
    }

    private func discardChunkIfSeeked(to position: Double, playbackRate: Double, isPlaying: Bool) {
        guard isLiveSyncActive, state.audioSyncEngine == .lyricsAlignment else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let last = lastPlayback
        lastPlayback = (position, now, playbackRate, isPlaying)
        if let chunkStart = chunkStartPos {
            let bufferedDuration = activeSampleRate > 0 ? Double(audioSampleBuffer.count) / activeSampleRate : 0
            let expected = chunkStart + bufferedDuration * chunkPlaybackRate
            let seeked = abs(position - expected) > Self.seekTolerance
            let rateChanged = abs(playbackRate - chunkPlaybackRate) > 0.01
            if seeked || rateChanged {
                clearAudioBuffers(keepingCapacity: true)
                chunkStartPos = nil
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
            startLyricsAlignmentSync(track: track, lines: lines)
        }
    }

    private func handleCaptureStartFailure(_ error: Error, generation: UInt64) {
        guard syncGeneration == generation else { return }
        stop()
        if let captureError = error as? SystemAudioCaptureError, captureError == .unresolvedPlayer {
            state.audioSyncStatus = .unavailable(captureError.localizedDescription)
        } else {
            state.audioSyncStatus = .permissionRequired("Audio capture failed: \(error.localizedDescription)")
        }
    }

    private func startLyricsAlignmentSync(track: TrackInfo, lines: [LyricLine]) {
        modelIdleReleaseTask?.cancel()
        modelIdleReleaseTask = nil
        modelMayBeCached = true
        let generation = syncGeneration
        let launch = dependencies.launchLyricsAligner
        clearAudioBuffers(keepingCapacity: true)
        chunkStartPos = nil
        chunkPlaybackRate = Self.sanitizedPlaybackRate(state.playbackRate)
        pendingSeekPos = nil
        sentFinalChunk = false
        state.audioSyncStatus = .syncing(engine: .lyricsAlignment, alignedLines: anchoredLines.count, totalLines: lines.count)

        let anchors = anchoredLines.compactMapValues(Self.sungSpan)
        alignerStartupTask = Task { [weak self] in
            let engine = await launch(lines, anchors)
            guard let self,
                  !Task.isCancelled,
                  self.syncGeneration == generation,
                  self.activeTrackId == track.id,
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
            self.diagnostics.update { $0.localeIdentifier = "lyrics alignment" }
            self.beginChunkCapture(track: track, generation: generation)
        }
    }

    private func beginChunkCapture(track: TrackInfo, generation: UInt64) {
        isLiveSyncActive = true
        lastPlayback = (
            currentPlaybackPosition(),
            ProcessInfo.processInfo.systemUptime,
            Self.sanitizedPlaybackRate(state.playbackRate),
            state.isPlaying
        )
        startCaptureForCurrentTarget(trackId: track.id, engine: .lyricsAlignment, generation: generation)
    }

    private func installChunkHandler(trackId: String, generation: UInt64, captureGeneration: UInt64) {
        capture.onAudioSamples = { @Sendable [weak self] batch in
            let deliveredAt = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in
                guard let self,
                      self.syncGeneration == generation,
                      self.captureTargetGeneration == captureGeneration,
                      self.isLiveSyncActive,
                      self.activeTrackId == trackId,
                      self.state.audioSyncEngine == .lyricsAlignment,
                      let audio = batch.trimmingBefore(self.seekBoundary, deliveredAt: deliveredAt)
                else { return }
                let samples = audio.samples
                let sampleRate = audio.sampleRate
                if sampleRate != self.activeSampleRate, !self.audioSampleBuffer.isEmpty {
                    self.clearAudioBuffers(keepingCapacity: true)
                    self.chunkStartPos = nil
                }
                self.activeSampleRate = sampleRate
                if sampleRate > 0 {
                    self.capturedSeconds += Double(samples.count) / sampleRate
                    self.diagnostics.recordAudio(totalSeconds: self.capturedSeconds)
                }
                if let delay = audio.captureDelay {
                    self.diagnostics.recordCaptureDelay(delay)
                }
                let livePos = Self.playbackPosition(
                    self.currentPlaybackPosition(),
                    capturedAt: audio.firstSampleUptime(deliveredAt: deliveredAt),
                    now: ProcessInfo.processInfo.systemUptime,
                    rate: self.state.isPlaying ? self.state.playbackRate : 0
                )
                if let existingStart = self.chunkStartPos,
                   sampleRate > 0,
                   audio.captureDelay != nil || audio.capturedAt != nil {
                    let expectedStart = existingStart
                        + Double(self.audioSampleBuffer.count) / sampleRate * self.chunkPlaybackRate
                    if abs(livePos - expectedStart) > Self.seekTolerance {
                        // Dropped audio gap: start a fresh chunk & envelope segment at the measured position.
                        self.clearAudioBuffers(keepingCapacity: true)
                        self.chunkStartPos = livePos
                        self.chunkPlaybackRate = Self.sanitizedPlaybackRate(self.state.playbackRate)
                    }
                }
                if self.chunkStartPos == nil {
                    if let pending = self.pendingSeekPos {
                        self.pendingSeekPos = nil
                        self.chunkStartPos = abs(livePos - pending) <= Self.seekTolerance ? livePos : pending
                    } else {
                        self.chunkStartPos = livePos
                    }
                    self.chunkPlaybackRate = Self.sanitizedPlaybackRate(self.state.playbackRate)
                }
                if let chunkStart = self.chunkStartPos, sampleRate > 0 {
                    let deliveryStart = chunkStart
                        + Double(self.audioSampleBuffer.count) / sampleRate * self.chunkPlaybackRate
                    let previousFrameCount = self.vocalEnvelope.totalFrameCount
                    let previousEnd = self.vocalEnvelope.segments.last?.end
                    self.vocalEnvelope.append(
                        mid: samples,
                        side: audio.side,
                        sampleRate: sampleRate,
                        startTime: deliveryStart,
                        rate: self.chunkPlaybackRate
                    )
                    let updatedFrameCount = self.vocalEnvelope.totalFrameCount
                    if updatedFrameCount > 0,
                       updatedFrameCount > previousFrameCount || self.vocalEnvelope.segments.last?.end != previousEnd {
                        self.vocalEnvelopeRevision &+= 1
                        self.notifyVocalEnvelopeChanged(for: trackId, throttled: previousFrameCount > 0)
                    }
                }
                self.audioSampleBuffer.append(contentsOf: samples)
                if audio.side.count == samples.count {
                    self.audioSideBuffer.append(contentsOf: audio.side)
                } else {
                    self.audioSideBuffer.append(contentsOf: repeatElement(0, count: samples.count))
                }

                let targetFrames = max(1, Int(sampleRate * self.chunkDurationSeconds))
                let maxFrames = targetFrames * 2
                if self.audioSampleBuffer.count > maxFrames {
                    let overflow = self.audioSampleBuffer.count - maxFrames
                    self.audioSampleBuffer.removeFirst(overflow)
                    self.audioSideBuffer.removeFirst(overflow)
                    if let startPos = self.chunkStartPos, sampleRate > 0 {
                        self.chunkStartPos = startPos + (Double(overflow) / sampleRate) * self.chunkPlaybackRate
                    }
                }

                self.dispatchChunkIfReady(trackId: trackId, generation: generation)
            }
        }
    }

    /// Dispatches one `targetFrames` chunk when the worker is idle, or what is left once the audio reaches the
    /// track's end; called on sample delivery and worker completion.
    private func dispatchChunkIfReady(trackId: String, generation: UInt64) {
        guard syncGeneration == generation,
              isLiveSyncActive,
              activeTrackId == trackId,
              state.audioSyncEngine == .lyricsAlignment,
              chunkProcessingTask == nil,
              let engine = chunkEngine
        else { return }
        let sampleRate = activeSampleRate
        let targetFrames = max(1, Int(sampleRate * chunkDurationSeconds))
        let chunkStart = chunkStartPos ?? currentPlaybackPosition()
        let bufferedEnd = chunkStart + Double(audioSampleBuffer.count) / max(sampleRate, 1) * chunkPlaybackRate
        let reachesEnd = !sentFinalChunk && activeTrackDuration > 0
            && bufferedEnd >= activeTrackDuration - Self.trackEndMargin
        let isFinal = reachesEnd && audioSampleBuffer.count <= targetFrames
        guard audioSampleBuffer.count >= targetFrames || (isFinal && !audioSampleBuffer.isEmpty) else { return }

        let frameCount = min(targetFrames, audioSampleBuffer.count)
        let rawChunk = Array(audioSampleBuffer.prefix(frameCount))
        let sideChunk = Array(audioSideBuffer.prefix(frameCount))
        audioSampleBuffer.removeFirst(frameCount)
        audioSideBuffer.removeFirst(frameCount)
        if audioSampleBuffer.isEmpty {
            chunkStartPos = nil
        } else if sampleRate > 0 {
            chunkStartPos = chunkStart + (Double(frameCount) / sampleRate) * chunkPlaybackRate
        }
        if isFinal { sentFinalChunk = true }

        let requestSampleRate = Int(sampleRate)
        let requestPlaybackRate = chunkPlaybackRate
        // Run pitch analysis, normalization, Core ML inference, and CTC Viterbi at `.background` QoS so multi-threaded
        // CPU fallback (libBNNS) stays on efficiency cores and never preempts interactive UI threads.
        chunkProcessingTask = Task.detached(priority: .background) { [weak self] in
            let pitch = requestSampleRate == VocalPitchContour.sampleRate
                ? VocalPitchContour.analyze(mid: rawChunk, side: sideChunk, start: chunkStart, rate: requestPlaybackRate)
                : nil
            guard !Task.isCancelled else { return }
            let chunk = AudioLevel.normalizedForRecognition(rawChunk)
            let request = AudioChunkRequest(
                samples: chunk,
                sampleRate: requestSampleRate,
                chunkStartTime: chunkStart,
                playbackRate: requestPlaybackRate,
                isFinal: isFinal
            )
            let words: [RecognizedAudioWord]
            do {
                words = try await engine.transcribe(request)
            } catch {
                await MainActor.run { [weak self] in
                    guard let self, self.syncGeneration == generation else { return }
                    self.chunkProcessingTask = nil
                    self.persistCurrentAlignmentIfReady()
                    self.stop()
                    self.state.audioSyncStatus = .unavailable("Lyrics alignment stopped unexpectedly; it restarts with the next track")
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self, self.syncGeneration == generation else { return }
                self.chunkProcessingTask = nil
                guard self.activeTrackId == trackId,
                      self.isLiveSyncActive,
                      self.state.audioSyncEngine == .lyricsAlignment
                else { return }
                if let pitch {
                    self.vocalPitchContour.merge(pitch)
                }
                let voicedFramePercent = self.vocalPitchContour.voicedFraction.map { $0 * 100 }
                self.diagnostics.update {
                    $0.voicedFramePercent = voicedFramePercent
                    $0.record(words: words, replacing: false)
                }
                self.recognizedWords.append(contentsOf: words)
                var newAttempts: Set<Int> = []
                if let reporter = engine as? LineAttemptReporting {
                    let reported = reporter.attemptedLineIDs
                    newAttempts = reported.subtracting(self.attemptedThisPlay)
                    self.attemptedLineIDs.formUnion(reported)
                    self.attemptedThisPlay.formUnion(newAttempts)
                    self.confidentLineIDs.formUnion(reporter.confidentLineIDs)
                    self.nearlyConfidentLineIDs.formUnion(reporter.nearlyConfidentLineIDs)
                }
                self.applyLyricsAlignment(replacingAttempts: newAttempts)
                self.dispatchChunkIfReady(trackId: trackId, generation: generation)
            }
        }
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
        keepingLockedAndAccepted(alignHeardWords())
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
                } else {
                    let hasPrev = prevEmittedTimestamp != nil || prevBlankTimestamp != nil
                    let preferredMin = max(
                        prevEmittedTimestamp.map { $0 + 0.25 } ?? 0,
                        prevLineEnd,
                        prevBlankTimestamp.map { $0 + 0.01 } ?? 0
                    )
                    let hardMin = max(
                        prevEmittedTimestamp.map { $0 + minLineGap } ?? 0,
                        prevBlankTimestamp ?? 0
                    )
                    let nextMatchedIdx = nextMatchedAfter[idx]
                    let maxStart: Double? = nextMatchedIdx.map { nextIdx in
                        let remainingNonEmpty = nonEmptyPrefix[nextIdx] - nonEmptyPrefix[idx]
                        return max(0.0, lines[nextIdx].timestamp - Double(remainingNonEmpty) * minLineGap)
                    }
                    let targetStart: Double?
                    if let upper = maxStart {
                        if hasPrev {
                            if hardMin <= upper {
                                let lower = max(hardMin, min(preferredMin, upper))
                                let clamped = min(upper, max(lower, line.timestamp))
                                targetStart = clamped != line.timestamp ? clamped : nil
                            } else if let nextIdx = nextMatchedIdx {
                                let fallback = min(lines[nextIdx].timestamp, max(prevEmittedTimestamp ?? 0, upper))
                                targetStart = fallback != line.timestamp ? fallback : nil
                            } else {
                                targetStart = nil
                            }
                        } else if line.timestamp > upper {
                            targetStart = upper
                        } else {
                            targetStart = nil
                        }
                    } else if hasPrev, line.timestamp < preferredMin {
                        targetStart = preferredMin
                    } else {
                        targetStart = nil
                    }
                    if let targetStart {
                        let shift = targetStart - line.timestamp
                        let shiftedWords = line.words.map { word in
                            WordTimestamp(timestamp: max(0, word.timestamp + shift), duration: word.duration, text: word.text)
                        }
                        lines[idx] = LyricLine(
                            id: line.id,
                            timestamp: targetStart,
                            duration: line.duration,
                            text: line.text,
                            words: shiftedWords
                        )
                    }
                    let placed = lines[idx]
                    let hasCompressedBlankBefore = prevBlankTimestamp != nil && idx > 0
                        && lines[idx - 1].timestamp < prevLineEnd
                    if placed.timestamp < prevLineEnd || hasCompressedBlankBefore {
                        LyricsAudioAligner.reconcilePrecedingBoundary(in: &lines, before: idx, targetStart: placed.timestamp, ignoringStructuralTags: true)
                    }
                    prevEmittedTimestamp = placed.timestamp
                    let placedEnd = placed.timestamp + max(0.25, placed.duration ?? 0.25)
                    prevLineEnd = nextMatchedIdx.map { min(lines[$0].timestamp, placedEnd) } ?? placedEnd
                    prevBlankTimestamp = nil
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

    /// Attempted lines count as settled only while this play hasn't locked anything new.
    private var settledLineIDs: Set<Int> { lockedThisPlay.isEmpty ? attemptedLineIDs : [] }

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

    /// A well-timed line locks when confident or when nearly confident and starting on a vocal onset.
    nonisolated static func locks(
        _ line: LyricLine,
        confident: Set<Int>,
        nearlyConfident: Set<Int>,
        envelope: VocalEnvelope,
        pitchContour: VocalPitchContour? = nil
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
        let onsetEnd = first.start + 0.25
        if let pitchContour, let clarity = pitchContour.meanHarmonicity(from: first.start, to: onsetEnd) {
            if clarity < VocalPitchContour.unvoicedFloor,
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

    /// Lyrics Alignment locks each confidently aligned line and keeps listening until no further play could
    /// lock another (see `lyricsAlignmentProgress`), saving after each chunk so a later play only listens for the rest.
    private func applyLyricsAlignment(replacingAttempts: Set<Int>) {
        guard !baseLines.isEmpty else { return }
        let fresh = alignHeardWords()
        let result = keepingLockedAndAccepted(fresh, replacingAttempts: replacingAttempts)
        // Only a line aligned from this play's audio that survived conflict resolution against existing
        // locks can lock itself, never a conflicting match or one carried over unlocked.
        let freshMatchedIDs = Set(fresh.matchedLineIDs)
        let survivedNewMatches = freshMatchedIDs
            .intersection(result.matchedLineIDs)
            .subtracting(lockedLineIDs)
            .subtracting(fresh.clampedRunawayLineIDs)
        var lockedNewLine = false
        for line in result.lines where survivedNewMatches.contains(line.id) && Self.locks(
            line,
            confident: confidentLineIDs,
            nearlyConfident: nearlyConfidentLineIDs,
            envelope: vocalEnvelope,
            pitchContour: vocalPitchContour
        ) {
            lockedThisPlay[line.id] = line
            lockedNewLine = true
        }
        let lines = baseLines
        diagnostics.update { $0.record(alignment: result, sourceLines: lines) }
        let progress = Self.lyricsAlignmentProgress(lockedIDs: lockedLineIDs, settledIDs: settledLineIDs, lines: baseLines)
        if progress.totalLines == 0 {
            stop()
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
        } else if droppedPriorWords {
            persistAlignment(result, engine: .lyricsAlignment)
        }
        if progress.isFinished {
            stop()
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
            lockedAtPlayStart: engine == .lyricsAlignment ? anchoredLines.count : nil
        )
        cache.save(record)
        cachedAlignedLineCount = forceUpdateCount
            ? result.matchedLineCount
            : max(cachedAlignedLineCount, result.matchedLineCount)
    }

    struct AudioChunkRequest: Sendable {
        let samples: [Float]
        let sampleRate: Int
        let chunkStartTime: Double
        /// Media seconds per recorded second, used to map in-chunk word offsets to track time.
        let playbackRate: Double
        /// The audio reaches the end of the track: no later chunk follows to complete its last lines.
        var isFinal = false
    }
}
