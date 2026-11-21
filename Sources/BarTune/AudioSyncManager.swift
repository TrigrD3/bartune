import AppKit
import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import Speech

protocol AudioCaptureProviding: AnyObject {
    var onAudioSamples: (([Float], Double) -> Void)? { get set }
    @MainActor func start(targetBundleIds: Set<String>) async throws
    @MainActor func stop()
}

protocol SpeechRecognitionTaskHandling: AnyObject {
    func cancel()
}

extension SFSpeechRecognitionTask: SpeechRecognitionTaskHandling {}

struct SpeechRecognizedSegment: Sendable {
    let substring: String
    let timestamp: TimeInterval
    let duration: TimeInterval
    let confidence: Float
}

protocol SpeechRecognizing: AnyObject {
    var isAvailable: Bool { get }
    var supportsOnDeviceRecognition: Bool { get }
    func startRecognitionTask(
        with request: SFSpeechAudioBufferRecognitionRequest,
        resultHandler: @escaping @Sendable ([SpeechRecognizedSegment]?, Error?) -> Void
    ) -> SpeechRecognitionTaskHandling
}

extension SFSpeechRecognizer: SpeechRecognizing {
    func startRecognitionTask(
        with request: SFSpeechAudioBufferRecognitionRequest,
        resultHandler: @escaping @Sendable ([SpeechRecognizedSegment]?, Error?) -> Void
    ) -> SpeechRecognitionTaskHandling {
        recognitionTask(with: request) { result, error in
            let segments = result?.bestTranscription.segments.map {
                SpeechRecognizedSegment(
                    substring: $0.substring,
                    timestamp: $0.timestamp,
                    duration: $0.duration,
                    confidence: $0.confidence
                )
            }
            resultHandler(segments, error)
        }
    }
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

private final class SystemAudioCapture: NSObject, SCStreamOutput, AudioCaptureProviding, @unchecked Sendable {
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

    @MainActor private var stream: SCStream?
    @MainActor private var activeTargetBundleIds: Set<String> = []
    @MainActor private var launchObserver: NSObjectProtocol?
    @MainActor private var sessionID: UInt64 = 0
    private let audioQueue = DispatchQueue(label: "com.arya.bartune.audiocapture", qos: .utility)

    private static func makeContentFilter(
        content: SCShareableContent,
        display: SCDisplay,
        targetBundleIds: Set<String>
    ) -> SCContentFilter {
        if !targetBundleIds.isEmpty {
            let excludedApps = content.applications.filter { !targetBundleIds.contains($0.bundleIdentifier) }
            return SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        }
        return SCContentFilter(display: display, excludingWindows: [])
    }

    @MainActor
    func start(targetBundleIds: Set<String> = []) async throws {
        stop()
        sessionID &+= 1
        let currentSession = sessionID

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard sessionID == currentSession else { return }
        guard let display = content.displays.first else {
            throw NSError(domain: "BarTune.AudioCapture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No display available for system audio capture.",
            ])
        }

        let filter = Self.makeContentFilter(content: content, display: display, targetBundleIds: targetBundleIds)
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        // Minimal video footprint since we only consume audio buffers.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let newStream = SCStream(filter: filter, configuration: config, delegate: nil)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await newStream.startCapture()

        guard sessionID == currentSession else {
            try? await newStream.stopCapture()
            return
        }

        stream = newStream
        activeTargetBundleIds = targetBundleIds

        if !targetBundleIds.isEmpty {
            launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                let launchedBundleId = (notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                    .bundleIdentifier
                Task { @MainActor [weak self] in
                    guard let self, self.sessionID == currentSession, let activeStream = self.stream else { return }
                    if let bundleId = launchedBundleId, self.activeTargetBundleIds.contains(bundleId) {
                        return
                    }
                    let targets = self.activeTargetBundleIds
                    guard let updated = try? await SCShareableContent.excludingDesktopWindows(
                        false,
                        onScreenWindowsOnly: false
                    ), self.sessionID == currentSession, self.stream === activeStream,
                        let updatedDisplay = updated.displays.first
                    else { return }
                    let updatedFilter = Self.makeContentFilter(
                        content: updated,
                        display: updatedDisplay,
                        targetBundleIds: targets
                    )
                    try? await activeStream.updateContentFilter(updatedFilter)
                }
            }
        }
    }

    @MainActor
    func stop() {
        sessionID &+= 1
        if let observer = launchObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
            launchObserver = nil
        }
        activeTargetBundleIds = []
        guard let activeStream = stream else { return }
        stream = nil
        Task {
            try? await activeStream.stopCapture()
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
    /// Encodes 16-bit mono PCM WAV data for whisper-cli input.
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
        var speechAuthorizationStatus: () -> SFSpeechRecognizerAuthorizationStatus
        var requestSpeechAuthorization: (@escaping @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void
        var makeSpeechRecognizer: (Locale?) -> SpeechRecognizing?
        var locateWhisperCLI: () -> String?
        var resolveWhisperModelPath: @Sendable (String) -> String?
        var runWhisperChunk: @Sendable (WhisperChunkRequest) -> [RecognizedAudioWord]
        var whisperChunkDurationSeconds: Double

        static func live() -> Dependencies {
            Dependencies(
                capture: SystemAudioCapture(),
                hasScreenCaptureAccess: { CGPreflightScreenCaptureAccess() },
                requestScreenCaptureAccess: { CGRequestScreenCaptureAccess() },
                speechAuthorizationStatus: { SFSpeechRecognizer.authorizationStatus() },
                requestSpeechAuthorization: { handler in
                    SFSpeechRecognizer.requestAuthorization(handler)
                },
                makeSpeechRecognizer: { locale in
                    if let locale {
                        return SFSpeechRecognizer(locale: locale)
                    }
                    return SFSpeechRecognizer()
                },
                locateWhisperCLI: { WhisperModelLocator.locateWhisperCLI() },
                resolveWhisperModelPath: { selected in
                    let trimmed = selected.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !trimmed.isEmpty, FileManager.default.fileExists(atPath: trimmed) {
                        return trimmed
                    }
                    return WhisperModelLocator.discoverModels(customPath: trimmed).first?.path
                },
                runWhisperChunk: { request in
                    AudioSyncManager.runWhisperChunk(request)
                },
                whisperChunkDurationSeconds: 12.0
            )
        }
    }

    private let state: LyricsState
    private let cache: AudioSyncedLyricsCache
    private let dependencies: Dependencies
    private var capture: AudioCaptureProviding { dependencies.capture }

    private var activeTrackId: String?
    private var activeSourceBundleId: String?
    private var baseLines: [LyricLine] = []
    private(set) var recognizedWords: [RecognizedAudioWord] = []
    private(set) var isLiveSyncActive: Bool = false
    private var syncGeneration: UInt64 = 0

    // Apple Speech state
    private var speechRecognizer: SpeechRecognizing?
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechTask: SpeechRecognitionTaskHandling?
    /// Track position at each stream time where playback (re)started; a same-track seek appends one.
    private var speechTimelineAnchors: [(streamTime: Double, trackPosition: Double)] = []
    private var speechStreamDuration: Double = 0
    private static let seekTolerance: Double = 2.0
    private var speechAudioFormat: AVAudioFormat?

    // Whisper chunk state
    private var whisperSampleBuffer: [Float] = []
    private var whisperChunkStartPos: Double?
    private var whisperStartupTask: Task<Void, Never>?
    private var whisperProcessingTask: Task<Void, Never>?
    private var whisperSampleRate: Double = 16000.0
    private var whisperChunkDurationSeconds: Double { dependencies.whisperChunkDurationSeconds }

    var bufferedWhisperSampleCount: Int { whisperSampleBuffer.count }
    var currentWhisperChunkStartPos: Double? { whisperChunkStartPos }
    var isWhisperProcessing: Bool { whisperProcessingTask != nil }

    init(
        state: LyricsState,
        cache: AudioSyncedLyricsCache = .default,
        dependencies: Dependencies = .live()
    ) {
        self.state = state
        self.cache = cache
        self.dependencies = dependencies
    }

    func stop() {
        syncGeneration &+= 1
        isLiveSyncActive = false
        capture.onAudioSamples = nil
        capture.stop()
        speechRequest?.endAudio()
        speechTask?.cancel()
        speechRequest = nil
        speechTask = nil
        speechRecognizer = nil
        whisperStartupTask?.cancel()
        whisperStartupTask = nil
        whisperProcessingTask?.cancel()
        whisperProcessingTask = nil
        whisperSampleBuffer.removeAll(keepingCapacity: false)
        whisperChunkStartPos = nil
    }

    /// Evaluates whether the current track can load cached audio-synced lyrics or needs live alignment.
    func handleTrackLoaded(track: TrackInfo, rawLines: [LyricLine], forceResync: Bool = false) {
        stop()
        activeTrackId = track.id
        activeSourceBundleId = track.sourceBundleId
        baseLines = rawLines
        recognizedWords = []

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
            if cached.isReliable(expectedSourceLineCount: expectedSourceLineCount) {
                if baseLines.isEmpty {
                    baseLines = cached.lines
                }
                state.applyAudioSyncedLines(cached.lines)
                state.audioSyncStatus = .cached(cached.engine)
                return
            }
            cache.remove(trackId: track.id)
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

    func handlePlaybackStateChanged(isPlaying: Bool, position: Double) {
        if isPlaying {
            reanchorSpeechTimelineIfSeeked(to: position)
        }
        guard !isPlaying, isLiveSyncActive else { return }
        // Persist whatever alignment we gathered before pausing/stopping.
        persistCurrentAlignmentIfReady()
    }

    private func reanchorSpeechTimelineIfSeeked(to position: Double) {
        guard isLiveSyncActive, speechRequest != nil, let anchor = speechTimelineAnchors.last else { return }
        let expected = anchor.trackPosition + (speechStreamDuration - anchor.streamTime)
        guard abs(position - expected) > Self.seekTolerance else { return }
        speechTimelineAnchors.append((streamTime: speechStreamDuration, trackPosition: position))
    }

    private func trackPosition(forSpeechStreamTime streamTime: Double) -> Double {
        guard let anchor = speechTimelineAnchors.last(where: { $0.streamTime <= streamTime }) ?? speechTimelineAnchors.first
        else { return streamTime }
        return anchor.trackPosition + (streamTime - anchor.streamTime)
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
        guard dependencies.hasScreenCaptureAccess() else {
            dependencies.requestScreenCaptureAccess()
            state.audioSyncStatus = .permissionRequired("Screen & System Audio Recording permission required")
            return
        }

        switch engine {
        case .off:
            state.audioSyncStatus = .idle
        case .appleSpeech:
            startAppleSpeechSync(track: track, lines: lines)
        case .whisper:
            startWhisperSync(track: track, lines: lines)
        }
    }

    private func startAppleSpeechSync(track: TrackInfo, lines: [LyricLine]) {
        let generation = syncGeneration
        let authStatus = dependencies.speechAuthorizationStatus()
        if authStatus == .notDetermined {
            dependencies.requestSpeechAuthorization { [weak self] newStatus in
                Task { @MainActor in
                    guard let self,
                          self.syncGeneration == generation,
                          self.activeTrackId == track.id,
                          self.state.audioSyncEngine == .appleSpeech
                    else { return }
                    if newStatus == .authorized {
                        self.beginAppleSpeechSession(track: track, lines: lines, generation: generation)
                    } else {
                        self.state.audioSyncStatus = .permissionRequired("Speech Recognition permission required")
                    }
                }
            }
            return
        }

        guard authStatus == .authorized else {
            state.audioSyncStatus = .permissionRequired("Speech Recognition permission required")
            return
        }

        beginAppleSpeechSession(track: track, lines: lines, generation: generation)
    }

    private func beginAppleSpeechSession(track: TrackInfo, lines: [LyricLine], generation: UInt64) {
        guard syncGeneration == generation,
              activeTrackId == track.id,
              state.audioSyncEngine == .appleSpeech
        else { return }

        let detectedLocale = LyricsLanguageDetector.detectSpeechLocale(for: lines)
        let selectedRecognizer: SpeechRecognizing? = if let preferred = dependencies.makeSpeechRecognizer(detectedLocale),
           preferred.isAvailable,
           preferred.supportsOnDeviceRecognition {
            preferred
        } else if let fallback = dependencies.makeSpeechRecognizer(nil),
                  fallback.isAvailable,
                  fallback.supportsOnDeviceRecognition {
            fallback
        } else {
            nil
        }

        guard let recognizer = selectedRecognizer else {
            state.audioSyncStatus = .unavailable("On-device Apple Speech recognition is unavailable for this locale")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.requiresOnDeviceRecognition = true
        request.contextualStrings = Array(lines.prefix(40).map(\.text))

        let anchorPos = currentPlaybackPosition()
        speechRecognizer = recognizer
        speechRequest = request
        speechTimelineAnchors = [(streamTime: 0, trackPosition: anchorPos)]
        speechStreamDuration = 0
        speechAudioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)

        state.audioSyncStatus = .syncing(engine: .appleSpeech, alignedLines: 0, totalLines: lines.count)

        speechTask = recognizer.startRecognitionTask(with: request) { [weak self] segments, error in
            Task { @MainActor in
                guard let self,
                      self.syncGeneration == generation,
                      self.activeTrackId == track.id,
                      self.state.audioSyncEngine == .appleSpeech
                else { return }
                if let segments {
                    let words: [RecognizedAudioWord] = segments.map { seg in
                        RecognizedAudioWord(
                            text: seg.substring,
                            startTime: self.trackPosition(forSpeechStreamTime: seg.timestamp),
                            duration: max(0.05, seg.duration),
                            confidence: Double(seg.confidence)
                        )
                    }
                    self.recognizedWords = words
                    self.applyAlignment(engine: .appleSpeech)
                }
                if let error, self.isLiveSyncActive {
                    self.persistCurrentAlignmentIfReady()
                    self.stop()
                    self.state.audioSyncStatus = .unavailable("Apple Speech recognition stopped: \(error.localizedDescription)")
                }
            }
        }

        capture.onAudioSamples = { [weak self] samples, sampleRate in
            Task { @MainActor in
                guard let self,
                      self.syncGeneration == generation,
                      self.isLiveSyncActive,
                      self.state.audioSyncEngine == .appleSpeech,
                      let req = self.speechRequest
                else { return }
                let format: AVAudioFormat
                if let cached = self.speechAudioFormat, cached.sampleRate == sampleRate {
                    format = cached
                } else if let created = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: sampleRate,
                    channels: 1,
                    interleaved: false
                ) {
                    self.speechAudioFormat = created
                    format = created
                } else {
                    return
                }
                guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)) else {
                    return
                }

                buffer.frameLength = AVAudioFrameCount(samples.count)
                if let channelData = buffer.floatChannelData?[0] {
                    samples.withUnsafeBufferPointer { src in
                        if let base = src.baseAddress {
                            channelData.update(from: base, count: samples.count)
                        }
                    }
                }
                req.append(buffer)
                if sampleRate > 0 {
                    self.speechStreamDuration += Double(samples.count) / sampleRate
                }
            }
        }

        isLiveSyncActive = true
        let targetBundles = Self.targetBundleIdentifiers(for: track)
        Task { [weak self] in
            guard let self,
                  self.syncGeneration == generation,
                  self.isLiveSyncActive,
                  self.state.audioSyncEngine == .appleSpeech
            else { return }
            do {
                try await self.capture.start(targetBundleIds: targetBundles)
            } catch {
                guard self.syncGeneration == generation else { return }
                self.isLiveSyncActive = false
                self.state.audioSyncStatus = .permissionRequired("Audio capture failed: \(error.localizedDescription)")
            }
        }
    }

    private func startWhisperSync(track: TrackInfo, lines: [LyricLine]) {
        guard let cliPath = dependencies.locateWhisperCLI() else {
            state.audioSyncStatus = .unavailable("whisper-cli not found (install via: brew install whisper-cpp)")
            return
        }

        let generation = syncGeneration
        let selectedModelPath = state.whisperModelPath
        let resolveModelPath = dependencies.resolveWhisperModelPath
        whisperSampleBuffer.removeAll(keepingCapacity: true)
        whisperChunkStartPos = nil
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
            self.whisperStartupTask = nil
            guard let modelPath = resolvedModelPath else {
                self.state.audioSyncStatus = .unavailable("No Whisper GGML model found — pick or download one in Settings")
                return
            }
            self.beginWhisperCapture(
                track: track,
                cliPath: cliPath,
                modelPath: modelPath,
                generation: generation
            )
        }
    }

    private func beginWhisperCapture(
        track: TrackInfo,
        cliPath: String,
        modelPath: String,
        generation: UInt64
    ) {
        capture.onAudioSamples = { [weak self] samples, sampleRate in
            Task { @MainActor in
                guard let self,
                      self.syncGeneration == generation,
                      self.isLiveSyncActive,
                      self.activeTrackId == track.id,
                      self.state.audioSyncEngine == .whisper
                else { return }
                self.whisperSampleRate = sampleRate
                if self.whisperChunkStartPos == nil {
                    self.whisperChunkStartPos = self.currentPlaybackPosition()
                }
                self.whisperSampleBuffer.append(contentsOf: samples)

                let targetFrames = max(1, Int(sampleRate * self.whisperChunkDurationSeconds))
                let maxFrames = targetFrames * 2
                if self.whisperSampleBuffer.count > maxFrames {
                    let overflow = self.whisperSampleBuffer.count - maxFrames
                    self.whisperSampleBuffer.removeFirst(overflow)
                    if let startPos = self.whisperChunkStartPos, sampleRate > 0 {
                        self.whisperChunkStartPos = startPos + Double(overflow) / sampleRate
                    }
                }

                self.dispatchWhisperChunkIfReady(
                    trackId: track.id,
                    cliPath: cliPath,
                    modelPath: modelPath,
                    generation: generation
                )
            }
        }

        isLiveSyncActive = true
        let targetBundles = Self.targetBundleIdentifiers(for: track)
        Task { [weak self] in
            guard let self,
                  self.syncGeneration == generation,
                  self.isLiveSyncActive,
                  self.activeTrackId == track.id,
                  self.state.audioSyncEngine == .whisper
            else { return }
            do {
                try await self.capture.start(targetBundleIds: targetBundles)
            } catch {
                guard self.syncGeneration == generation else { return }
                self.isLiveSyncActive = false
                self.state.audioSyncStatus = .permissionRequired("Audio capture failed: \(error.localizedDescription)")
            }
        }
    }

    /// Dispatches one `targetFrames` chunk when the worker is idle; called on sample delivery and worker completion.
    private func dispatchWhisperChunkIfReady(
        trackId: String,
        cliPath: String,
        modelPath: String,
        generation: UInt64
    ) {
        guard syncGeneration == generation,
              isLiveSyncActive,
              activeTrackId == trackId,
              state.audioSyncEngine == .whisper,
              whisperProcessingTask == nil
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
            whisperChunkStartPos = chunkStart + Double(targetFrames) / sampleRate
        }

        let request = WhisperChunkRequest(
            cliPath: cliPath,
            modelPath: modelPath,
            samples: chunk,
            sampleRate: Int(sampleRate),
            chunkStartTime: chunkStart,
            prompt: promptSnippet(around: chunkStart)
        )
        let runWhisperChunk = dependencies.runWhisperChunk
        whisperProcessingTask = Task { [weak self] in
            let words = await Task.detached(priority: .utility) {
                runWhisperChunk(request)
            }.value
            guard let self, self.syncGeneration == generation else { return }
            self.whisperProcessingTask = nil
            guard self.activeTrackId == trackId,
                  self.isLiveSyncActive,
                  self.state.audioSyncEngine == .whisper
            else { return }
            if !words.isEmpty {
                self.recognizedWords.append(contentsOf: words)
                self.applyAlignment(engine: .whisper)
            }
            self.dispatchWhisperChunkIfReady(
                trackId: trackId,
                cliPath: cliPath,
                modelPath: modelPath,
                generation: generation
            )
        }
    }

    private func currentPlaybackPosition() -> Double {
        let elapsed = max(0.0, Date().timeIntervalSince(state.playbackAnchorDate))
        return state.playbackAnchorPosition + (state.isPlaying ? elapsed * state.playbackRate : 0.0)
    }

    private func promptSnippet(around position: Double) -> String {
        baseLines
            .filter { $0.timestamp >= position - 4.0 && $0.timestamp <= position + 20.0 }
            .prefix(6)
            .map(\.text)
            .joined(separator: " ")
    }

    private func applyAlignment(engine: AudioSyncEngine) {
        guard !baseLines.isEmpty, !recognizedWords.isEmpty else { return }
        let result = LyricsAudioAligner.align(
            lines: baseLines,
            recognizedWords: recognizedWords,
            replaceTextWithTranscription: state.replaceLyricsWithTranscription
        )
        guard result.matchedLineCount > 0 else { return }

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
            : min(nonEmptyCount, result.medianOffset != nil ? 2 : 3)

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
            recognizedWords: recognizedWords,
            replaceTextWithTranscription: state.replaceLyricsWithTranscription
        )
        guard result.matchedLineCount > 0 else { return }
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
            lines: result.lines
        )
        cache.save(record)
    }

    struct WhisperChunkRequest: Sendable {
        let cliPath: String
        let modelPath: String
        let samples: [Float]
        let sampleRate: Int
        let chunkStartTime: Double
        let prompt: String
    }

    nonisolated static func runWhisperChunk(_ request: WhisperChunkRequest) -> [RecognizedAudioWord] {
        let tempDir = FileManager.default.temporaryDirectory
        let token = UUID().uuidString
        let wavURL = tempDir.appendingPathComponent("bartune-sync-\(token).wav")
        let outPrefix = tempDir.appendingPathComponent("bartune-sync-\(token)-out")
        let jsonURL = outPrefix.appendingPathExtension("json")

        defer {
            try? FileManager.default.removeItem(at: wavURL)
            try? FileManager.default.removeItem(at: jsonURL)
        }

        let wavData = WAVEncoder.encodeMono16BitPCM(samples: request.samples, sampleRate: request.sampleRate)
        guard (try? wavData.write(to: wavURL)) != nil else { return [] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: request.cliPath)
        var args = [
            "-m", request.modelPath,
            "-f", wavURL.path,
            "-ojf",
            "-of", outPrefix.path,
            "-l", "auto",
            "-np",
            "-t", "4",
        ]
        if !request.prompt.isEmpty {
            args.append(contentsOf: ["--prompt", request.prompt])
        }
        process.arguments = args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }

        guard process.terminationStatus == 0,
              let data = try? Data(contentsOf: jsonURL)
        else { return [] }

        return WhisperJSONParser.parse(data: data, chunkStartTime: request.chunkStartTime)
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
