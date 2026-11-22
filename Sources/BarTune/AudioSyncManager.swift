import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

protocol AudioCaptureProviding: AnyObject {
    var onAudioSamples: (([Float], Double) -> Void)? { get set }
    @MainActor func start(targetBundleIds: Set<String>) async throws
    @MainActor func stop()
}

enum AudioSampleExtractor {
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
        output: SCStreamOutput,
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
        output: SCStreamOutput,
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

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        // Minimal video footprint since we only consume audio buffers.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let newStream = SCStream(filter: scFilter, configuration: config, delegate: nil)
        try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: audioQueue)
        try await newStream.startCapture()
        return LiveSCStreamHandle(stream: newStream)
    }
}

final class SystemAudioCapture: NSObject, SCStreamOutput, AudioCaptureProviding, @unchecked Sendable {
    private let callbackLock = NSLock()
    private var _onAudioSamples: (([Float], Double) -> Void)?
    var onAudioSamples: (([Float], Double) -> Void)? {
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

    init(backend: SystemAudioCaptureBackend = LiveSystemAudioCaptureBackend()) {
        self.backend = backend
        super.init()
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

        let newStream = try await backend.startStream(
            display: display,
            includedApplications: includedApps,
            output: self,
            audioQueue: audioQueue
        )

        guard sessionID == currentSession else {
            await newStream.stopCapture()
            return
        }

        stream = newStream
    }

    @MainActor
    func stop() {
        sessionID &+= 1
        guard let activeStream = stream else { return }
        stream = nil
        Task {
            await activeStream.stopCapture()
        }
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let formatDesc = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbdPtr = CMAudioFormatDescriptionGetStreamBasicDescription(formatDesc)
        else { return }

        let asbd = asbdPtr.pointee
        let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 16000.0
        guard let blockBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else { return }

        let monoSamples = AudioSampleExtractor.extractMonoSamples(from: blockBuffer, asbd: asbd)
        guard !monoSamples.isEmpty else { return }
        onAudioSamples?(monoSamples, sampleRate)
    }
}

enum WAVEncoder {
    /// Encodes 16-bit mono PCM WAV data for whisper-server input.
    static func encodeMono16BitPCM(samples: [Float], sampleRate: Int = 16000) -> Data {
        let dataSize = samples.count * 2
        var data = Data(capacity: 44 + dataSize)

        func appendUInt32LE(_ value: UInt32) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        func appendUInt16LE(_ value: UInt16) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }

        data.append(contentsOf: "RIFF".utf8)
        appendUInt32LE(UInt32(36 + dataSize))
        data.append(contentsOf: "WAVE".utf8)
        data.append(contentsOf: "fmt ".utf8)
        appendUInt32LE(16) // PCM chunk size
        appendUInt16LE(1) // AudioFormat = PCM
        appendUInt16LE(1) // NumChannels = 1
        appendUInt32LE(UInt32(sampleRate))
        appendUInt32LE(UInt32(sampleRate * 2)) // ByteRate
        appendUInt16LE(2) // BlockAlign
        appendUInt16LE(16) // BitsPerSample
        data.append(contentsOf: "data".utf8)
        appendUInt32LE(UInt32(dataSize))

        for sample in samples {
            let clamped = max(-1.0, min(1.0, sample))
            var intSample = Int16(clamped * 32767.0).littleEndian
            withUnsafeBytes(of: &intSample) { data.append(contentsOf: $0) }
        }
        return data
    }
}

@MainActor
final class AudioSyncManager {
    struct Dependencies {
        var capture: AudioCaptureProviding
        var hasScreenCaptureAccess: () -> Bool
        var requestScreenCaptureAccess: () -> Void
        var locateWhisperServer: () -> String?
        var resolveWhisperModelPath: @Sendable (String) -> String?
        var launchWhisper: @Sendable (_ serverPath: String, _ modelPath: String) async -> WhisperTranscribing?
        var whisperChunkDurationSeconds: Double

        static func live() -> Dependencies {
            Dependencies(
                capture: SystemAudioCapture(),
                hasScreenCaptureAccess: { CGPreflightScreenCaptureAccess() },
                requestScreenCaptureAccess: { CGRequestScreenCaptureAccess() },
                locateWhisperServer: { WhisperModelLocator.locateWhisperServer() },
                resolveWhisperModelPath: { selected in
                    let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, FileManager.default.fileExists(atPath: trimmed) {
                        return trimmed
                    }
                    return WhisperModelLocator.discoverModels(customPath: trimmed).first?.path
                },
                launchWhisper: { serverPath, modelPath in
                    await WhisperServer.launch(serverPath: serverPath, modelPath: modelPath)
                },
                whisperChunkDurationSeconds: 12.0
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
    private(set) var recognizedWords: [RecognizedAudioWord] = []
    private(set) var isLiveSyncActive: Bool = false
    private var syncGeneration: UInt64 = 0
    private var captureTargetGeneration: UInt64 = 0

    private static let seekTolerance: Double = 2.0

    // Whisper chunk state
    private var whisperSampleBuffer: [Float] = []
    private var whisperChunkStartPos: Double?
    private var whisperChunkPlaybackRate: Double = 1.0
    private var whisperPendingSeekPos: Double?
    /// Uptime of the last detected seek; deliveries captured before it hold pre-seek audio.
    private var whisperSeekBoundary: TimeInterval = 0
    /// Last playback state this manager saw; seeks are detected against it because `LyricsState` is updated first.
    private var whisperLastPlayback: (position: Double, uptime: TimeInterval, rate: Double, isPlaying: Bool)?
    private var whisperStartupTask: Task<Void, Never>?
    private var whisperProcessingTask: Task<Void, Never>?
    private var whisperEngine: WhisperTranscribing?
    /// Lyric language passed to Whisper, so it doesn't guess per chunk.
    private var whisperLanguage: String?
    private var whisperSampleRate: Double = 16000.0
    private var whisperCapturedSeconds: Double = 0
    private var whisperChunkDurationSeconds: Double { dependencies.whisperChunkDurationSeconds }

    var bufferedWhisperSampleCount: Int { whisperSampleBuffer.count }
    var currentWhisperChunkStartPos: Double? { whisperChunkStartPos }
    var isWhisperProcessing: Bool { whisperProcessingTask != nil }

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
    }

    func stop() {
        syncGeneration &+= 1
        captureTargetGeneration &+= 1
        isLiveSyncActive = false
        capture.onAudioSamples = nil
        capture.stop()
        whisperStartupTask?.cancel()
        whisperStartupTask = nil
        whisperProcessingTask?.cancel()
        whisperProcessingTask = nil
        whisperEngine?.shutdown()
        whisperEngine = nil
        whisperSampleBuffer.removeAll(keepingCapacity: false)
        whisperChunkStartPos = nil
        whisperChunkPlaybackRate = 1.0
        whisperPendingSeekPos = nil
        whisperLastPlayback = nil
        whisperCapturedSeconds = 0
    }

    /// Evaluates whether the current track can load cached audio-synced lyrics or needs live alignment.
    func handleTrackLoaded(track: TrackInfo, rawLines: [LyricLine], forceResync: Bool = false) {
        stop()
        activeTrackId = track.id
        activeSourceBundleId = track.sourceBundleId
        baseLines = rawLines
        recognizedWords = []
        cachedAlignedLineCount = 0
        priorHeardWords = []

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
        } else if let cached = cache.load(trackId: track.id) {
            let current = rawLines.isEmpty
                || cached.matchesSource(rawLines, comparingText: !state.replaceLyricsWithTranscription)
            let reliable = current && cached.isReliable(expectedSourceLineCount: expectedSourceLineCount)
            if reliable, rawLines.isEmpty || cached.isComplete(expectedSourceLineCount: expectedSourceLineCount) {
                if baseLines.isEmpty {
                    baseLines = cached.lines
                }
                state.applyAudioSyncedLines(cached.lines)
                state.audioSyncStatus = .cached(cached.engine)
                return
            }
            if reliable {
                // Show the partial sync now and keep listening to fill in the lines it missed.
                state.applyAudioSyncedLines(cached.lines)
                cachedAlignedLineCount = cached.alignedLineCount
                priorHeardWords = cached.heardWords ?? []
            } else {
                cache.remove(trackId: track.id)
            }
        }

        guard !rawLines.isEmpty else {
            state.audioSyncStatus = .idle
            return
        }

        if !forceResync, !state.replaceLyricsWithTranscription, Self.hasPreexistingWordSync(rawLines) {
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
        whisperSampleBuffer.removeAll(keepingCapacity: true)
        whisperChunkStartPos = nil
        // Deliveries still queued from the old capture must not start the new chunk.
        whisperSeekBoundary = ProcessInfo.processInfo.systemUptime
        startCaptureForCurrentTarget(trackId: track.id, engine: state.audioSyncEngine, generation: syncGeneration)
    }

    private func startCaptureForCurrentTarget(
        trackId: String,
        engine: AudioSyncEngine,
        generation: UInt64
    ) {
        captureTargetGeneration &+= 1
        let captureGeneration = captureTargetGeneration
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
        discardWhisperChunkIfSeeked(to: position, playbackRate: resolvedRate, isPlaying: isPlaying)
        guard !isPlaying, isLiveSyncActive else { return }
        // Persist whatever alignment we gathered before pausing/stopping.
        persistCurrentAlignmentIfReady()
    }

    private static func sanitizedPlaybackRate(_ rate: Double) -> Double {
        (rate.isFinite && rate > 0) ? rate : 1.0
    }

    private func discardWhisperChunkIfSeeked(to position: Double, playbackRate: Double, isPlaying: Bool) {
        guard isLiveSyncActive, state.audioSyncEngine == .whisper else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let last = whisperLastPlayback
        whisperLastPlayback = (position, now, playbackRate, isPlaying)
        if let chunkStart = whisperChunkStartPos {
            let bufferedDuration = whisperSampleRate > 0 ? Double(whisperSampleBuffer.count) / whisperSampleRate : 0
            let expected = chunkStart + bufferedDuration * whisperChunkPlaybackRate
            let seeked = abs(position - expected) > Self.seekTolerance
            let rateChanged = abs(playbackRate - whisperChunkPlaybackRate) > 0.01
            if seeked || rateChanged {
                whisperSampleBuffer.removeAll(keepingCapacity: true)
                whisperChunkStartPos = nil
                whisperChunkPlaybackRate = playbackRate
                whisperPendingSeekPos = position
                whisperSeekBoundary = ProcessInfo.processInfo.systemUptime
            }
        } else if let last {
            let expected = last.position + (last.isPlaying ? (now - last.uptime) * last.rate : 0)
            let seeked = abs(position - expected) > Self.seekTolerance
            let rateChanged = abs(playbackRate - last.rate) > 0.01
            if seeked || rateChanged {
                whisperPendingSeekPos = position
                whisperChunkPlaybackRate = playbackRate
                whisperSeekBoundary = now
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
            duration: 0,
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
        case .whisper:
            startWhisperSync(track: track, lines: lines)
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

    private func startWhisperSync(track: TrackInfo, lines: [LyricLine]) {
        guard let serverPath = dependencies.locateWhisperServer() else {
            state.audioSyncStatus = .unavailable("whisper-server not found (install via: brew install whisper-cpp)")
            return
        }

        let generation = syncGeneration
        let selectedModelPath = state.whisperModelPath
        let resolveModelPath = dependencies.resolveWhisperModelPath
        let launchWhisper = dependencies.launchWhisper
        whisperSampleBuffer.removeAll(keepingCapacity: true)
        whisperChunkStartPos = nil
        whisperChunkPlaybackRate = Self.sanitizedPlaybackRate(state.playbackRate)
        whisperPendingSeekPos = nil
        whisperLanguage = LyricsLanguageDetector.detectSpeechLocale(for: lines).language.languageCode?.identifier
        state.audioSyncStatus = .syncing(engine: .whisper, alignedLines: 0, totalLines: lines.count)

        whisperStartupTask = Task { [weak self] in
            let resolvedModelPath = await Task.detached(priority: .utility) {
                resolveModelPath(selectedModelPath)
            }.value
            guard let self,
                  !Task.isCancelled,
                  self.syncGeneration == generation,
                  self.activeTrackId == track.id,
                  self.state.audioSyncEngine == .whisper
            else { return }
            guard let modelPath = resolvedModelPath else {
                self.whisperStartupTask = nil
                self.state.audioSyncStatus = .unavailable("No Whisper GGML model found — pick or download one in Settings")
                return
            }
            let engine = await launchWhisper(serverPath, modelPath)
            guard !Task.isCancelled,
                  self.syncGeneration == generation,
                  self.activeTrackId == track.id,
                  self.state.audioSyncEngine == .whisper
            else {
                engine?.shutdown()
                return
            }
            self.whisperStartupTask = nil
            guard let engine else {
                self.state.audioSyncStatus = .unavailable("whisper-server could not load the Whisper model")
                return
            }
            self.whisperEngine = engine
            let language = self.whisperLanguage
            self.diagnostics.update { $0.localeIdentifier = language ?? "auto (Whisper)" }
            self.beginWhisperCapture(track: track, generation: generation)
        }
    }

    private func beginWhisperCapture(track: TrackInfo, generation: UInt64) {
        capture.onAudioSamples = { [weak self] samples, sampleRate in
            let capturedAt = ProcessInfo.processInfo.systemUptime
            Task { @MainActor in
                guard let self,
                      self.syncGeneration == generation,
                      self.isLiveSyncActive,
                      self.activeTrackId == track.id,
                      self.state.audioSyncEngine == .whisper,
                      capturedAt > self.whisperSeekBoundary
                else { return }
                self.whisperSampleRate = sampleRate
                if sampleRate > 0 {
                    self.whisperCapturedSeconds += Double(samples.count) / sampleRate
                    self.diagnostics.recordAudio(totalSeconds: self.whisperCapturedSeconds)
                }
                if self.whisperChunkStartPos == nil {
                    let livePos = self.currentPlaybackPosition()
                    if let pending = self.whisperPendingSeekPos {
                        self.whisperPendingSeekPos = nil
                        self.whisperChunkStartPos = abs(livePos - pending) <= Self.seekTolerance ? livePos : pending
                    } else {
                        self.whisperChunkStartPos = livePos
                    }
                    self.whisperChunkPlaybackRate = Self.sanitizedPlaybackRate(self.state.playbackRate)
                }
                self.whisperSampleBuffer.append(contentsOf: samples)

                let targetFrames = max(1, Int(sampleRate * self.whisperChunkDurationSeconds))
                let maxFrames = targetFrames * 2
                if self.whisperSampleBuffer.count > maxFrames {
                    let overflow = self.whisperSampleBuffer.count - maxFrames
                    self.whisperSampleBuffer.removeFirst(overflow)
                    if let startPos = self.whisperChunkStartPos, sampleRate > 0 {
                        self.whisperChunkStartPos = startPos + (Double(overflow) / sampleRate) * self.whisperChunkPlaybackRate
                    }
                }

                self.dispatchWhisperChunkIfReady(trackId: track.id, generation: generation)
            }
        }

        isLiveSyncActive = true
        whisperLastPlayback = (
            currentPlaybackPosition(),
            ProcessInfo.processInfo.systemUptime,
            Self.sanitizedPlaybackRate(state.playbackRate),
            state.isPlaying
        )
        startCaptureForCurrentTarget(trackId: track.id, engine: .whisper, generation: generation)
    }

    /// Dispatches one `targetFrames` chunk when the worker is idle; called on sample delivery and worker completion.
    private func dispatchWhisperChunkIfReady(trackId: String, generation: UInt64) {
        guard syncGeneration == generation,
              isLiveSyncActive,
              activeTrackId == trackId,
              state.audioSyncEngine == .whisper,
              whisperProcessingTask == nil,
              let engine = whisperEngine
        else { return }
        let sampleRate = whisperSampleRate
        let targetFrames = max(1, Int(sampleRate * whisperChunkDurationSeconds))
        guard whisperSampleBuffer.count >= targetFrames else { return }

        let chunk = Array(whisperSampleBuffer.prefix(targetFrames))
        let chunkStart = whisperChunkStartPos ?? currentPlaybackPosition()
        whisperSampleBuffer.removeFirst(targetFrames)
        if whisperSampleBuffer.isEmpty {
            whisperChunkStartPos = nil
        } else if sampleRate > 0 {
            whisperChunkStartPos = chunkStart + (Double(targetFrames) / sampleRate) * whisperChunkPlaybackRate
        }

        let request = WhisperChunkRequest(
            samples: chunk,
            sampleRate: Int(sampleRate),
            chunkStartTime: chunkStart,
            playbackRate: whisperChunkPlaybackRate,
            language: whisperLanguage
        )
        whisperProcessingTask = Task { [weak self] in
            let words: [RecognizedAudioWord]
            do {
                words = try await engine.transcribe(request)
            } catch {
                guard let self, self.syncGeneration == generation else { return }
                self.whisperProcessingTask = nil
                self.persistCurrentAlignmentIfReady()
                self.stop()
                self.state.audioSyncStatus = .unavailable("whisper-server stopped unexpectedly; it restarts with the next track")
                return
            }
            guard let self, self.syncGeneration == generation else { return }
            self.whisperProcessingTask = nil
            guard self.activeTrackId == trackId,
                  self.isLiveSyncActive,
                  self.state.audioSyncEngine == .whisper
            else { return }
            self.diagnostics.update { $0.record(words: words, replacing: false) }
            if !words.isEmpty {
                self.recognizedWords.append(contentsOf: words)
                self.applyAlignment(engine: .whisper)
            }
            self.dispatchWhisperChunkIfReady(trackId: trackId, generation: generation)
        }
    }

    private func currentPlaybackPosition() -> Double {
        let elapsed = max(0.0, Date().timeIntervalSince(state.playbackAnchorDate))
        return state.playbackAnchorPosition + (state.isPlaying ? elapsed * state.playbackRate : 0.0)
    }

    /// Words from earlier plays fill only the stretches this play hasn't heard; this play's words win.
    nonisolated static func mergeHeardWords(
        prior: [RecognizedAudioWord],
        current: [RecognizedAudioWord],
        margin: Double = 1.0
    ) -> [RecognizedAudioWord] {
        let kept = prior.filter { old in
            !current.contains { $0.startTime - margin < old.endTime && old.startTime < $0.endTime + margin }
        }
        return (kept + current).sorted { $0.startTime < $1.startTime }
    }

    private var allHeardWords: [RecognizedAudioWord] {
        Self.mergeHeardWords(prior: priorHeardWords, current: recognizedWords)
    }

    private func applyAlignment(engine: AudioSyncEngine) {
        guard !baseLines.isEmpty, !recognizedWords.isEmpty else { return }
        let result = LyricsAudioAligner.align(
            lines: baseLines,
            recognizedWords: allHeardWords,
            replaceTextWithTranscription: state.replaceLyricsWithTranscription
        )
        let lines = baseLines
        diagnostics.update { $0.record(alignment: result, sourceLines: lines) }
        AudioSyncDiagnosticsModel.logger.debug(
            "Alignment: \(result.matchedLineCount, privacy: .public)/\(lines.count, privacy: .public) lines, \(self.recognizedWords.count, privacy: .public) words heard"
        )
        guard result.matchedLineCount > 0, result.matchedLineCount > cachedAlignedLineCount else { return }

        state.applyAudioSyncedLines(result.lines)
        state.audioSyncStatus = .syncing(
            engine: engine,
            alignedLines: result.matchedLineCount,
            totalLines: baseLines.count
        )

        let nonEmptyCount = max(
            1,
            baseLines.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        )
        let confidentThreshold = state.replaceLyricsWithTranscription
            ? nonEmptyCount
            : AudioSyncedLyricsRecord.linesNeededForCompletion(of: nonEmptyCount)

        if result.matchedLineCount >= confidentThreshold {
            persistAlignment(result, engine: engine)
            stop()
            state.audioSyncStatus = .cached(engine)
        } else if result.matchedLineCount >= 1 {
            persistAlignment(result, engine: engine)
        }
    }

    private func persistCurrentAlignmentIfReady() {
        let engine = state.audioSyncEngine
        guard engine != .off, !baseLines.isEmpty, !recognizedWords.isEmpty else { return }
        let result = LyricsAudioAligner.align(
            lines: baseLines,
            recognizedWords: allHeardWords,
            replaceTextWithTranscription: state.replaceLyricsWithTranscription
        )
        guard result.matchedLineCount > 0, result.matchedLineCount > cachedAlignedLineCount else { return }
        persistAlignment(result, engine: engine)
    }

    private func persistAlignment(_ result: AudioAlignmentResult, engine: AudioSyncEngine) {
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
            heardWords: allHeardWords
        )
        cache.save(record)
    }

    struct WhisperChunkRequest: Sendable {
        let samples: [Float]
        let sampleRate: Int
        let chunkStartTime: Double
        /// Media seconds per recorded second, used to map in-chunk word offsets to track time.
        let playbackRate: Double
        var language: String?
    }

    /// Downloads a GGML Whisper model preset into `~/.cache/whisper/` so other tools on the Mac can reuse it.
    static func downloadSharedModel(_ preset: WhisperModelPreset = .tiny) async throws -> URL {
        let dir = WhisperModelLocator.sharedCacheDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let destURL = dir.appendingPathComponent(preset.rawValue)
        if FileManager.default.fileExists(atPath: destURL.path) {
            return destURL
        }

        let (tempURL, response) = try await URLSession.shared.download(from: preset.downloadURL)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw NSError(domain: "BarTune.WhisperDownload", code: http.statusCode, userInfo: [
                NSLocalizedDescriptionKey: "Download failed with HTTP \(http.statusCode)",
            ])
        }

        if FileManager.default.fileExists(atPath: destURL.path) {
            try FileManager.default.removeItem(at: destURL)
        }
        try FileManager.default.moveItem(at: tempURL, to: destURL)
        return destURL
    }
}
