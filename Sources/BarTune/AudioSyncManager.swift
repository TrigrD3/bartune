import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit
import Speech

private final class SystemAudioCapture: NSObject, SCStreamOutput, @unchecked Sendable {
    var onAudioSamples: (([Float], Double) -> Void)?
    private var stream: SCStream?
    private let audioQueue = DispatchQueue(label: "com.arya.bartune.audiocapture", qos: .utility)

    func start(targetBundleIds: Set<String> = []) async throws {
        stop()
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "BarTune.AudioCapture", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "No display available for system audio capture.",
            ])
        }

        let filter: SCContentFilter
        if !targetBundleIds.isEmpty {
            let excludedApps = content.applications.filter { !targetBundleIds.contains($0.bundleIdentifier) }
            filter = SCContentFilter(display: display, excludingApplications: excludedApps, exceptingWindows: [])
        } else {
            filter = SCContentFilter(display: display, excludingWindows: [])
        }
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 16000
        config.channelCount = 1
        // Minimal video footprint since we only consume audio buffers.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() {
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

        var length = 0
        var dataPointer: UnsafeMutablePointer<Int8>?
        let status = CMBlockBufferGetDataPointer(
            blockBuffer,
            atOffset: 0,
            lengthAtOffsetOut: nil,
            totalLengthOut: &length,
            dataPointerOut: &dataPointer
        )
        guard status == kCMBlockBufferNoErr, let rawPtr = dataPointer, length > 0 else { return }

        let channelCount = max(1, Int(asbd.mChannelsPerFrame))
        let isFloat = (asbd.mFormatFlags & kAudioFormatFlagIsFloat) != 0
        let isNonInterleaved = (asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved) != 0

        var monoSamples: [Float] = []
        if isFloat && asbd.mBitsPerChannel == 32 {
            let totalFloats = length / MemoryLayout<Float>.size
            let floatPtr = UnsafeRawPointer(rawPtr).bindMemory(to: Float.self, capacity: totalFloats)
            if isNonInterleaved || channelCount == 1 {
                let frameCount = isNonInterleaved ? (totalFloats / channelCount) : totalFloats
                monoSamples = Array(UnsafeBufferPointer(start: floatPtr, count: frameCount))
            } else {
                let frameCount = totalFloats / channelCount
                monoSamples.reserveCapacity(frameCount)
                for f in 0..<frameCount {
                    var sum: Float = 0
                    for ch in 0..<channelCount {
                        sum += floatPtr[f * channelCount + ch]
                    }
                    monoSamples.append(sum / Float(channelCount))
                }
            }
        } else if !isFloat && asbd.mBitsPerChannel == 16 {
            let totalInt16 = length / MemoryLayout<Int16>.size
            let intPtr = UnsafeRawPointer(rawPtr).bindMemory(to: Int16.self, capacity: totalInt16)
            let frameCount = totalInt16 / channelCount
            monoSamples.reserveCapacity(frameCount)
            for f in 0..<frameCount {
                var sum: Float = 0
                for ch in 0..<channelCount {
                    sum += Float(intPtr[f * channelCount + ch]) / 32768.0
                }
                monoSamples.append(sum / Float(channelCount))
            }
        }

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
    private let state: LyricsState
    private let cache: AudioSyncedLyricsCache
    private let capture = SystemAudioCapture()

    private var activeTrackId: String?
    private var baseLines: [LyricLine] = []
    private var recognizedWords: [RecognizedAudioWord] = []
    private(set) var isLiveSyncActive: Bool = false

    // Apple Speech state
    private var speechRecognizer: SFSpeechRecognizer?
    private var speechRequest: SFSpeechAudioBufferRecognitionRequest?
    private var speechTask: SFSpeechRecognitionTask?
    private var speechStreamAnchorPos: Double = 0
    private var speechAudioFormat: AVAudioFormat?

    // Whisper chunk state
    private var whisperSampleBuffer: [Float] = []
    private var whisperChunkStartPos: Double?
    private var whisperProcessingTask: Task<Void, Never>?
    private var whisperSampleRate: Double = 16000.0
    private let whisperChunkDurationSeconds: Double = 12.0

    init(state: LyricsState, cache: AudioSyncedLyricsCache = .default) {
        self.state = state
        self.cache = cache
    }

    func stop() {
        isLiveSyncActive = false
        capture.onAudioSamples = nil
        capture.stop()
        speechRequest?.endAudio()
        speechTask?.cancel()
        speechRequest = nil
        speechTask = nil
        speechRecognizer = nil
        whisperProcessingTask?.cancel()
        whisperProcessingTask = nil
        whisperSampleBuffer.removeAll(keepingCapacity: false)
        whisperChunkStartPos = nil
    }

    /// Evaluates whether the current track can load cached audio-synced lyrics or needs live alignment.
    func handleTrackLoaded(track: TrackInfo, rawLines: [LyricLine], forceResync: Bool = false) {
        stop()
        activeTrackId = track.id
        baseLines = rawLines
        recognizedWords = []

        guard !rawLines.isEmpty else {
            state.audioSyncStatus = .idle
            return
        }

        let engine = state.audioSyncEngine
        guard engine != .off else {
            state.audioSyncStatus = .idle
            return
        }

        if forceResync {
            cache.remove(trackId: track.id)
        } else if let cached = cache.load(trackId: track.id) {
            if cached.isReliable {
                state.applyAudioSyncedLines(cached.lines)
                state.audioSyncStatus = .cached(cached.engine)
                return
            }
            cache.remove(trackId: track.id)
        } else if !state.replaceLyricsWithTranscription, Self.hasPreexistingWordSync(rawLines) {
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

    /// Maps a BarTune track ID prefix to the exact media player bundle ID(s) for isolated ScreenCaptureKit audio capture.
    nonisolated static func targetBundleIdentifiers(for trackId: String) -> Set<String> {
        if trackId.hasPrefix("spotify:") {
            return ["com.spotify.client"]
        }
        if trackId.hasPrefix("music:") {
            return ["com.apple.Music"]
        }
        if trackId.hasPrefix("browser:") {
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

    func handlePlaybackStateChanged(isPlaying: Bool) {
        guard !isPlaying, isLiveSyncActive else { return }
        // Persist whatever alignment we gathered before pausing/stopping.
        persistCurrentAlignmentIfReady()
    }

    func resyncCurrentTrack() {
        guard let trackId = activeTrackId, !baseLines.isEmpty else { return }
        let track = TrackInfo(id: trackId, title: "", artist: "", album: "", duration: 0, artworkURL: nil)
        handleTrackLoaded(track: track, rawLines: baseLines, forceResync: true)
    }

    private func startLiveSync(for track: TrackInfo, lines: [LyricLine], engine: AudioSyncEngine) {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
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
        let authStatus = SFSpeechRecognizer.authorizationStatus()
        if authStatus == .notDetermined {
            SFSpeechRecognizer.requestAuthorization { [weak self] newStatus in
                Task { @MainActor in
                    guard let self, self.activeTrackId == track.id else { return }
                    if newStatus == .authorized {
                        self.beginAppleSpeechSession(track: track, lines: lines)
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

        beginAppleSpeechSession(track: track, lines: lines)
    }

    private func beginAppleSpeechSession(track: TrackInfo, lines: [LyricLine]) {
        let detectedLocale = LyricsLanguageDetector.detectSpeechLocale(for: lines)
        let preferredRecognizer = SFSpeechRecognizer(locale: detectedLocale)
        guard let recognizer = (preferredRecognizer?.isAvailable == true ? preferredRecognizer : SFSpeechRecognizer()),
              recognizer.isAvailable
        else {
            state.audioSyncStatus = .unavailable("Apple Speech recognizer is unavailable for this locale")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        request.contextualStrings = Array(lines.prefix(40).map(\.text))

        let anchorPos = currentPlaybackPosition()
        speechRecognizer = recognizer
        speechRequest = request
        speechStreamAnchorPos = anchorPos
        speechAudioFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16000, channels: 1, interleaved: false)

        state.audioSyncStatus = .syncing(engine: .appleSpeech, alignedLines: 0, totalLines: lines.count)

        speechTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                guard let self, self.activeTrackId == track.id else { return }
                if let result {
                    let segments = result.bestTranscription.segments
                    let words: [RecognizedAudioWord] = segments.map { seg in
                        RecognizedAudioWord(
                            text: seg.substring,
                            startTime: self.speechStreamAnchorPos + seg.timestamp,
                            duration: max(0.05, seg.duration),
                            confidence: Double(seg.confidence)
                        )
                    }
                    self.recognizedWords = words
                    self.applyAlignment(engine: .appleSpeech)
                }
                if error != nil, self.isLiveSyncActive {
                    self.persistCurrentAlignmentIfReady()
                }
            }
        }

        capture.onAudioSamples = { [weak self] samples, sampleRate in
            Task { @MainActor in
                guard let self, self.isLiveSyncActive, let req = self.speechRequest else { return }
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
            }
        }

        isLiveSyncActive = true
        let targetBundles = Self.targetBundleIdentifiers(for: track.id)
        Task { [weak self] in
            do {
                try await self?.capture.start(targetBundleIds: targetBundles)
            } catch {
                await MainActor.run {
                    self?.isLiveSyncActive = false
                    self?.state.audioSyncStatus = .permissionRequired("Audio capture failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func startWhisperSync(track: TrackInfo, lines: [LyricLine]) {
        guard let cliPath = WhisperModelLocator.locateWhisperCLI() else {
            state.audioSyncStatus = .unavailable("whisper-cli not found (install via: brew install whisper-cpp)")
            return
        }

        let resolvedModelPath = resolveActiveWhisperModelPath()
        guard let modelPath = resolvedModelPath else {
            state.audioSyncStatus = .unavailable("No Whisper GGML model found — pick or download one in Settings")
            return
        }

        whisperSampleBuffer.removeAll(keepingCapacity: true)
        whisperChunkStartPos = nil
        state.audioSyncStatus = .syncing(engine: .whisper, alignedLines: 0, totalLines: lines.count)

        capture.onAudioSamples = { [weak self] samples, sampleRate in
            Task { @MainActor in
                guard let self, self.isLiveSyncActive, self.activeTrackId == track.id else { return }
                self.whisperSampleRate = sampleRate
                if self.whisperChunkStartPos == nil {
                    self.whisperChunkStartPos = self.currentPlaybackPosition()
                }
                self.whisperSampleBuffer.append(contentsOf: samples)

                let targetFrames = Int(sampleRate * self.whisperChunkDurationSeconds)
                if self.whisperSampleBuffer.count >= targetFrames, self.whisperProcessingTask == nil {
                    let chunk = self.whisperSampleBuffer
                    let chunkStart = self.whisperChunkStartPos ?? self.currentPlaybackPosition()
                    self.whisperSampleBuffer.removeAll(keepingCapacity: true)
                    self.whisperChunkStartPos = nil

                    let prompt = self.promptSnippet(around: chunkStart)
                    let trackId = track.id
                    let request = WhisperChunkRequest(
                        cliPath: cliPath,
                        modelPath: modelPath,
                        samples: chunk,
                        sampleRate: Int(sampleRate),
                        chunkStartTime: chunkStart,
                        prompt: prompt
                    )
                    self.whisperProcessingTask = Task { [weak self] in
                        let words = await Task.detached(priority: .utility) {
                            Self.runWhisperChunk(request)
                        }.value
                        guard let self else { return }
                        self.whisperProcessingTask = nil
                        guard self.activeTrackId == trackId else { return }
                        if !words.isEmpty {
                            self.recognizedWords.append(contentsOf: words)
                            self.applyAlignment(engine: .whisper)
                        }
                    }
                }
            }
        }

        isLiveSyncActive = true
        let targetBundles = Self.targetBundleIdentifiers(for: track.id)
        Task { [weak self] in
            do {
                try await self?.capture.start(targetBundleIds: targetBundles)
            } catch {
                await MainActor.run {
                    self?.isLiveSyncActive = false
                    self?.state.audioSyncStatus = .permissionRequired("Audio capture failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private func resolveActiveWhisperModelPath() -> String? {
        let selected = state.whisperModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selected.isEmpty, FileManager.default.fileExists(atPath: selected) {
            return selected
        }
        return WhisperModelLocator.discoverModels(customPath: selected).first?.path
    }

    private func currentPlaybackPosition() -> Double {
        let elapsed = max(0.0, Date().timeIntervalSince(state.playbackAnchorDate))
        return state.playbackAnchorPosition + (state.isPlaying ? elapsed : 0.0)
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
        let record = AudioSyncedLyricsRecord(
            trackId: trackId,
            engine: engine,
            syncedAt: Date(),
            medianOffset: result.medianOffset,
            alignedLineCount: result.matchedLineCount,
            lines: result.lines
        )
        cache.save(record)
    }

    private struct WhisperChunkRequest: Sendable {
        let cliPath: String
        let modelPath: String
        let samples: [Float]
        let sampleRate: Int
        let chunkStartTime: Double
        let prompt: String
    }

    nonisolated private static func runWhisperChunk(_ request: WhisperChunkRequest) -> [RecognizedAudioWord] {
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
        process.standardOutput = Pipe()
        process.standardError = Pipe()

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
