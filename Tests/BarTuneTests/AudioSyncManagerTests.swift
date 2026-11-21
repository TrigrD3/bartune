import AVFoundation
@testable import BarTune
import CoreMedia
import Foundation
import Speech
import XCTest

final class AudioSyncManagerTests: XCTestCase {
    private var tempDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bartune-audio-sync-manager-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        suiteName = "com.bartune.tests.audiosyncmanager.\(UUID().uuidString)"
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDown() {
        if let suiteName {
            defaults?.removePersistentDomain(forName: suiteName)
        }
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        defaults = nil
        suiteName = nil
        tempDir = nil
        super.tearDown()
    }

    // MARK: - #58: Non-contiguous & unaligned CMBlockBuffer extraction

    func testExtractMonoSamplesHandlesNonContiguousMultiBlockFloat32Buffer() throws {
        let block1Values: [Float] = [0.25, -0.5, 0.75, -1.0]
        let block2Values: [Float] = [0.125, -0.25, 0.5, 0.875]

        let byteCount1 = block1Values.count * MemoryLayout<Float>.size
        let byteCount2 = block2Values.count * MemoryLayout<Float>.size
        let mem1 = UnsafeMutableRawPointer.allocate(byteCount: byteCount1, alignment: MemoryLayout<Float>.alignment)
        let mem2 = UnsafeMutableRawPointer.allocate(byteCount: byteCount2, alignment: MemoryLayout<Float>.alignment)
        defer {
            mem1.deallocate()
            mem2.deallocate()
        }

        block1Values.withUnsafeBytes { UnsafeMutableRawBufferPointer(start: mem1, count: byteCount1).copyMemory(from: $0) }
        block2Values.withUnsafeBytes { UnsafeMutableRawBufferPointer(start: mem2, count: byteCount2).copyMemory(from: $0) }

        var blockBuffer: CMBlockBuffer?
        XCTAssertEqual(
            CMBlockBufferCreateEmpty(
                allocator: kCFAllocatorDefault,
                capacity: 2,
                flags: 0,
                blockBufferOut: &blockBuffer
            ),
            kCMBlockBufferNoErr
        )
        let buffer = try XCTUnwrap(blockBuffer)

        XCTAssertEqual(
            CMBlockBufferAppendMemoryBlock(
                buffer,
                memoryBlock: mem1,
                length: byteCount1,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount1,
                flags: 0
            ),
            kCMBlockBufferNoErr
        )
        XCTAssertEqual(
            CMBlockBufferAppendMemoryBlock(
                buffer,
                memoryBlock: mem2,
                length: byteCount2,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount2,
                flags: 0
            ),
            kCMBlockBufferNoErr
        )

        XCTAssertFalse(CMBlockBufferIsRangeContiguous(buffer, atOffset: 0, length: byteCount1 + byteCount2))

        let asbd = AudioStreamBasicDescription(
            mSampleRate: 16000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let extracted = AudioSampleExtractor.extractMonoSamples(from: buffer, asbd: asbd)
        XCTAssertEqual(extracted, block1Values + block2Values)
    }

    func testExtractMonoSamplesHandlesUnalignedFloat32SubBuffer() throws {
        let expected: [Float] = [0.2, -0.4, 0.6, -0.8]
        let payloadBytes = expected.count * MemoryLayout<Float>.size
        let totalAlloc = payloadBytes + 1
        let rawMem = UnsafeMutableRawPointer.allocate(byteCount: totalAlloc, alignment: MemoryLayout<Float>.alignment)
        defer { rawMem.deallocate() }

        rawMem.storeBytes(of: UInt8(0xAA), as: UInt8.self)
        expected.withUnsafeBytes {
            UnsafeMutableRawBufferPointer(start: rawMem.advanced(by: 1), count: payloadBytes).copyMemory(from: $0)
        }

        var blockBuffer: CMBlockBuffer?
        XCTAssertEqual(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: rawMem,
                blockLength: totalAlloc,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 1,
                dataLength: payloadBytes,
                flags: 0,
                blockBufferOut: &blockBuffer
            ),
            kCMBlockBufferNoErr
        )
        let buffer = try XCTUnwrap(blockBuffer)

        let asbd = AudioStreamBasicDescription(
            mSampleRate: 16000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 1,
            mBitsPerChannel: 32,
            mReserved: 0
        )

        let extracted = AudioSampleExtractor.extractMonoSamples(from: buffer, asbd: asbd)
        XCTAssertEqual(extracted, expected)
    }

    func testExtractMonoSamplesHandlesMultiBlockInt16InterleavedAndNonInterleaved() throws {
        // Two frames of stereo Int16 split across two non-contiguous blocks.
        let block1: [Int16] = [16384, -16384] // interleaved frame 0 avg = 0.0; non-interleaved ch0 = [0.5, -0.5]
        let block2: [Int16] = [16384, 16384] // interleaved frame 1 avg = 0.5; non-interleaved ch1 = [0.5, 0.5]

        let byteCount1 = block1.count * MemoryLayout<Int16>.size
        let byteCount2 = block2.count * MemoryLayout<Int16>.size
        let mem1 = UnsafeMutableRawPointer.allocate(byteCount: byteCount1, alignment: MemoryLayout<Int16>.alignment)
        let mem2 = UnsafeMutableRawPointer.allocate(byteCount: byteCount2, alignment: MemoryLayout<Int16>.alignment)
        defer {
            mem1.deallocate()
            mem2.deallocate()
        }

        block1.withUnsafeBytes { UnsafeMutableRawBufferPointer(start: mem1, count: byteCount1).copyMemory(from: $0) }
        block2.withUnsafeBytes { UnsafeMutableRawBufferPointer(start: mem2, count: byteCount2).copyMemory(from: $0) }

        var blockBuffer: CMBlockBuffer?
        XCTAssertEqual(
            CMBlockBufferCreateEmpty(
                allocator: kCFAllocatorDefault,
                capacity: 2,
                flags: 0,
                blockBufferOut: &blockBuffer
            ),
            kCMBlockBufferNoErr
        )
        let buffer = try XCTUnwrap(blockBuffer)
        XCTAssertEqual(
            CMBlockBufferAppendMemoryBlock(
                buffer,
                memoryBlock: mem1,
                length: byteCount1,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount1,
                flags: 0
            ),
            kCMBlockBufferNoErr
        )
        XCTAssertEqual(
            CMBlockBufferAppendMemoryBlock(
                buffer,
                memoryBlock: mem2,
                length: byteCount2,
                blockAllocator: kCFAllocatorNull,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: byteCount2,
                flags: 0
            ),
            kCMBlockBufferNoErr
        )

        let interleavedASBD = AudioStreamBasicDescription(
            mSampleRate: 16000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked,
            mBytesPerPacket: 4,
            mFramesPerPacket: 1,
            mBytesPerFrame: 4,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let interleaved = AudioSampleExtractor.extractMonoSamples(from: buffer, asbd: interleavedASBD)
        XCTAssertEqual(interleaved.count, 2)
        XCTAssertEqual(interleaved[0], 0.0, accuracy: 0.0001)
        XCTAssertEqual(interleaved[1], 0.5, accuracy: 0.0001)

        let nonInterleavedASBD = AudioStreamBasicDescription(
            mSampleRate: 16000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 2,
            mFramesPerPacket: 1,
            mBytesPerFrame: 2,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 16,
            mReserved: 0
        )
        let nonInterleaved = AudioSampleExtractor.extractMonoSamples(from: buffer, asbd: nonInterleavedASBD)
        XCTAssertEqual(nonInterleaved.count, 2)
        XCTAssertEqual(nonInterleaved[0], 0.5, accuracy: 0.0001)
        XCTAssertEqual(nonInterleaved[1], -0.5, accuracy: 0.0001)
    }

    // MARK: - #54: On-device Apple Speech privacy guard

    @MainActor
    func testAppleSpeechRefusesCloudOnlyRecognizersAndNeverStartsCapture() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .appleSpeech
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let preferredRecognizer = FakeSpeechRecognizer(isAvailable: true, supportsOnDeviceRecognition: false)
        let defaultRecognizer = FakeSpeechRecognizer(isAvailable: true, supportsOnDeviceRecognition: false)

        let deps = makeDependencies(
            capture: fakeCapture,
            speechAuthStatus: .authorized,
            makeSpeechRecognizer: { locale in
                locale == nil ? defaultRecognizer : preferredRecognizer
            }
        )
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)

        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        await Task.yield()

        XCTAssertFalse(manager.isLiveSyncActive)
        XCTAssertEqual(fakeCapture.startCount, 0)
        XCTAssertTrue(preferredRecognizer.startedRequests.isEmpty)
        XCTAssertTrue(defaultRecognizer.startedRequests.isEmpty)
        if case .unavailable = state.audioSyncStatus {
            // Expected
        } else {
            XCTFail("Expected .unavailable status when on-device speech recognition is unsupported, got \(state.audioSyncStatus)")
        }
    }

    @MainActor
    func testAppleSpeechFallsBackToDefaultLocaleOnlyWhenOnDeviceSupported() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .appleSpeech
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let preferredRecognizer = FakeSpeechRecognizer(isAvailable: true, supportsOnDeviceRecognition: false)
        let defaultRecognizer = FakeSpeechRecognizer(isAvailable: true, supportsOnDeviceRecognition: true)

        let deps = makeDependencies(
            capture: fakeCapture,
            speechAuthStatus: .authorized,
            makeSpeechRecognizer: { locale in
                locale == nil ? defaultRecognizer : preferredRecognizer
            }
        )
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)

        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        await Task.yield()

        XCTAssertTrue(manager.isLiveSyncActive)
        XCTAssertEqual(fakeCapture.startCount, 1)
        XCTAssertTrue(preferredRecognizer.startedRequests.isEmpty)
        XCTAssertEqual(defaultRecognizer.startedRequests.count, 1)
        XCTAssertEqual(defaultRecognizer.startedRequests.first?.requiresOnDeviceRecognition, true)
    }

    // MARK: - #55: Stale Speech authorization callback

    @MainActor
    func testStaleSpeechAuthCallbackDoesNotStartCaptureAfterSwitchingOff() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .appleSpeech
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let recognizer = FakeSpeechRecognizer(isAvailable: true, supportsOnDeviceRecognition: true)

        var pendingAuthCallback: (@Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void)?
        let deps = makeDependencies(
            capture: fakeCapture,
            speechAuthStatus: .notDetermined,
            requestSpeechAuth: { handler in
                pendingAuthCallback = handler
            },
            makeSpeechRecognizer: { _ in recognizer }
        )
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        let track = sampleTrack()
        let lines = sampleLines()

        manager.handleTrackLoaded(track: track, rawLines: lines)
        XCTAssertNotNil(pendingAuthCallback)

        // User turns audio sync off while the Speech permission prompt is still open.
        state.audioSyncEngine = .off
        manager.handleTrackLoaded(track: track, rawLines: lines)
        XCTAssertEqual(state.audioSyncStatus, .idle)

        // Stale permission callback arrives later with .authorized.
        pendingAuthCallback?(.authorized)
        for _ in 0..<5 {
            await Task.yield()
        }

        XCTAssertFalse(manager.isLiveSyncActive)
        XCTAssertEqual(fakeCapture.startCount, 0)
        XCTAssertTrue(recognizer.startedRequests.isEmpty)
        XCTAssertEqual(state.audioSyncStatus, .idle)
    }

    @MainActor
    func testStaleSpeechAuthCallbackIsIgnoredAfterRestartOnSameTrackAndEngine() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .appleSpeech
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let recognizer = FakeSpeechRecognizer(isAvailable: true, supportsOnDeviceRecognition: true)

        var authCallbacks: [@Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void] = []
        let deps = makeDependencies(
            capture: fakeCapture,
            speechAuthStatus: .notDetermined,
            requestSpeechAuth: { handler in
                authCallbacks.append(handler)
            },
            makeSpeechRecognizer: { _ in recognizer }
        )
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        let track = sampleTrack()
        let lines = sampleLines()

        // Apple Speech -> off -> Apple Speech on the same track while the first prompt is still pending.
        manager.handleTrackLoaded(track: track, rawLines: lines)
        manager.stop()
        manager.handleTrackLoaded(track: track, rawLines: lines)
        XCTAssertEqual(authCallbacks.count, 2)

        authCallbacks[0](.authorized)
        for _ in 0..<5 {
            await Task.yield()
        }

        XCTAssertTrue(recognizer.startedRequests.isEmpty)
        XCTAssertEqual(fakeCapture.startCount, 0)
        XCTAssertFalse(manager.isLiveSyncActive)

        authCallbacks[1](.authorized)
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }

        XCTAssertTrue(started)
        XCTAssertEqual(recognizer.startedRequests.count, 1)
        XCTAssertEqual(fakeCapture.startCount, 1)
    }

    @MainActor
    func testStaleSpeechAuthCallbackDoesNotClobberWhisperEngine() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .appleSpeech
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let recognizer = FakeSpeechRecognizer(isAvailable: true, supportsOnDeviceRecognition: true)

        var pendingAuthCallback: (@Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void)?
        let deps = makeDependencies(
            capture: fakeCapture,
            speechAuthStatus: .notDetermined,
            requestSpeechAuth: { handler in
                pendingAuthCallback = handler
            },
            makeSpeechRecognizer: { _ in recognizer },
            locateWhisperCLI: { "/usr/local/bin/whisper-cli" },
            resolveWhisperModelPath: { _ in "/tmp/ggml-tiny.bin" }
        )
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        let track = sampleTrack()
        let lines = sampleLines()

        manager.handleTrackLoaded(track: track, rawLines: lines)
        XCTAssertNotNil(pendingAuthCallback)

        // User switches to Whisper before Apple Speech auth completes.
        state.audioSyncEngine = .whisper
        manager.handleTrackLoaded(track: track, rawLines: lines)
        let whisperStarted = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(whisperStarted)

        XCTAssertTrue(manager.isLiveSyncActive)
        XCTAssertEqual(state.audioSyncStatus, .syncing(engine: .whisper, alignedLines: 0, totalLines: lines.count))
        let captureStartsBeforeCallback = fakeCapture.startCount

        pendingAuthCallback?(.authorized)
        for _ in 0..<5 {
            await Task.yield()
        }

        XCTAssertTrue(recognizer.startedRequests.isEmpty)
        XCTAssertEqual(fakeCapture.startCount, captureStartsBeforeCallback)
        XCTAssertEqual(state.audioSyncStatus, .syncing(engine: .whisper, alignedLines: 0, totalLines: lines.count))
    }

    // MARK: - #64: Whisper Pipe deadlock & unbounded sample buffer

    func testRunWhisperChunkDoesNotDeadlockOnLargeStdoutAndStderr() throws {
        let scriptURL = tempDir.appendingPathComponent("fake-whisper.sh")
        let script = """
        #!/bin/sh
        out_prefix=""
        while [ $# -gt 0 ]; do
          if [ "$1" = "-of" ]; then
            out_prefix="$2"
            shift 2
          else
            shift
          fi
        done
        # Emit >128 KB to both stdout and stderr (exceeds macOS 64 KB pipe buffer).
        dd if=/dev/zero bs=1024 count=160 2>/dev/null | tr '\\0' 'O'
        dd if=/dev/zero bs=1024 count=160 2>/dev/null | tr '\\0' 'E' >&2
        cat > "${out_prefix}.json" <<'EOF'
        {"transcription":[{"offsets":{"from":0,"to":1000},"text":" Hello","tokens":[{"text":" Hello","offsets":{"from":100,"to":500},"p":0.95}]}]}
        EOF
        """
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let request = AudioSyncManager.WhisperChunkRequest(
            cliPath: scriptURL.path,
            modelPath: tempDir.appendingPathComponent("dummy.bin").path,
            samples: [Float](repeating: 0.1, count: 160),
            sampleRate: 16000,
            chunkStartTime: 10.0,
            prompt: ""
        )

        let done = expectation(description: "Whisper chunk completes without pipe deadlock")
        let parsedWordsBox = LockedBox<[RecognizedAudioWord]>([])
        DispatchQueue.global(qos: .userInitiated).async {
            let words = AudioSyncManager.runWhisperChunk(request)
            parsedWordsBox.withLock { $0 = words }
            done.fulfill()
        }

        wait(for: [done], timeout: 5.0)
        let parsedWords = parsedWordsBox.withLock { $0 }
        XCTAssertEqual(parsedWords.count, 1)
        XCTAssertEqual(parsedWords.first?.text, "Hello")
        XCTAssertEqual(parsedWords.first?.startTime ?? 0, 10.1, accuracy: 0.01)
    }

    @MainActor
    func testWhisperSampleBufferIsBoundedAndDispatchesCappedChunks() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false

        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()

        let firstChunkStarted = expectation(description: "First Whisper chunk started")
        let thirdChunkDispatched = expectation(description: "Third Whisper chunk dispatched")
        let releaseFirstChunk = DispatchSemaphore(value: 0)
        let recordedRequests = LockedBox<[AudioSyncManager.WhisperChunkRequest]>([])

        let deps = makeDependencies(
            capture: fakeCapture,
            locateWhisperCLI: { "/usr/local/bin/whisper-cli" },
            resolveWhisperModelPath: { _ in "/tmp/ggml-tiny.bin" },
            runWhisperChunk: { request in
                let count = recordedRequests.withLock { list -> Int in
                    list.append(request)
                    return list.count
                }
                if count == 1 {
                    firstChunkStarted.fulfill()
                    releaseFirstChunk.wait()
                } else if count == 3 {
                    thirdChunkDispatched.fulfill()
                }
                return []
            },
            whisperChunkDurationSeconds: 1.0
        )

        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let whisperStarted = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(whisperStarted)

        // 100 Hz sample rate with 1.0s chunks -> targetFrames = 100, maxFrames = 200.
        let sampleRate = 100.0
        let chunkFrames = 100

        // Trigger chunk 1 (in flight, blocked on semaphore).
        fakeCapture.emit(samples: [Float](repeating: 0.1, count: chunkFrames), sampleRate: sampleRate)
        await fulfillment(of: [firstChunkStarted], timeout: 2.0)

        // While chunk 1 is busy, feed 500 samples (5x targetFrames) starting at playback position 20.0.
        state.playbackAnchorPosition = 20.0
        for batch in 0..<5 {
            fakeCapture.emit(samples: [Float](repeating: Float(batch + 1) * 0.1, count: chunkFrames), sampleRate: sampleRate)
        }
        // Let all MainActor audio tasks settle.
        for _ in 0..<20 {
            await Task.yield()
        }

        // Buffer must stay bounded to 2 * targetFrames (200), dropping the oldest 300 samples (+3.0s).
        XCTAssertLessThanOrEqual(manager.bufferedWhisperSampleCount, chunkFrames * 2)
        XCTAssertEqual(manager.currentWhisperChunkStartPos ?? -1, 23.0, accuracy: 0.01)

        // Release chunk 1 without emitting more audio: both retained chunks must be dispatched on worker completion.
        releaseFirstChunk.signal()
        await fulfillment(of: [thirdChunkDispatched], timeout: 2.0)

        let requests = recordedRequests.withLock { $0 }
        XCTAssertEqual(requests.count, 3)
        guard requests.count == 3 else { return }
        XCTAssertEqual(requests[1].samples.count, chunkFrames)
        XCTAssertEqual(requests[2].samples.count, chunkFrames)
        XCTAssertEqual(requests[1].chunkStartTime, 23.0, accuracy: 0.01)
        XCTAssertEqual(requests[2].chunkStartTime, 24.0, accuracy: 0.01)
        XCTAssertEqual(manager.bufferedWhisperSampleCount, 0)
    }

    @MainActor
    func testStopBeforeCaptureStartTaskRunsSkipsCaptureStart() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .appleSpeech
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let recognizer = FakeSpeechRecognizer(
            isAvailable: true,
            supportsOnDeviceRecognition: true
        )

        let deps = makeDependencies(
            capture: fakeCapture,
            speechAuthStatus: .authorized,
            makeSpeechRecognizer: { _ in recognizer }
        )
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        // Stop immediately before the deferred capture.start Task runs.
        manager.stop()

        for _ in 0..<10 {
            await Task.yield()
        }

        XCTAssertFalse(manager.isLiveSyncActive)
        XCTAssertEqual(fakeCapture.startCount, 0)
    }

    @MainActor
    func testStopDuringAsyncWhisperModelDiscoverySkipsCaptureStart() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()

        let discoveryStarted = expectation(description: "Whisper model discovery started off main actor")
        let releaseDiscovery = DispatchSemaphore(value: 0)
        let ranOnMainThread = LockedBox<Bool>(true)

        let deps = makeDependencies(
            capture: fakeCapture,
            locateWhisperCLI: { "/usr/local/bin/whisper-cli" },
            resolveWhisperModelPath: { _ in
                ranOnMainThread.withLock { $0 = Thread.isMainThread }
                discoveryStarted.fulfill()
                releaseDiscovery.wait()
                return "/tmp/ggml-tiny.bin"
            }
        )
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        await fulfillment(of: [discoveryStarted], timeout: 2.0)

        // Stop while model discovery is still in flight, then let discovery finish.
        manager.stop()
        releaseDiscovery.signal()

        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertFalse(ranOnMainThread.withLock { $0 }, "Whisper model discovery must run off the main actor")
        XCTAssertFalse(manager.isLiveSyncActive)
        XCTAssertEqual(fakeCapture.startCount, 0)
    }

    // MARK: - Helpers

    @MainActor
    private func waitUntil(
        timeout: TimeInterval = 2.0,
        _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                return false
            }
            await Task.yield()
        }
        return true
    }

    private func sampleTrack() -> TrackInfo {
        TrackInfo(id: "spotify:track:test-1", title: "Test Song", artist: "Test Artist", album: "Test Album", duration: 180, artworkURL: nil)
    }

    private func sampleLines() -> [LyricLine] {
        [
            LyricLine(id: 0, timestamp: 10.0, text: "Hello world from test"),
            LyricLine(id: 1, timestamp: 15.0, text: "Second line of lyrics"),
        ]
    }

    private func makeDependencies(
        capture: AudioCaptureProviding,
        hasScreenCaptureAccess: Bool = true,
        speechAuthStatus: SFSpeechRecognizerAuthorizationStatus = .authorized,
        requestSpeechAuth: @escaping (@escaping @Sendable (SFSpeechRecognizerAuthorizationStatus) -> Void) -> Void = { _ in },
        makeSpeechRecognizer: @escaping (Locale?) -> SpeechRecognizing? = { _ in nil },
        locateWhisperCLI: @escaping () -> String? = { nil },
        resolveWhisperModelPath: @escaping @Sendable (String) -> String? = { _ in nil },
        runWhisperChunk: @escaping @Sendable (AudioSyncManager.WhisperChunkRequest) -> [RecognizedAudioWord] = { _ in [] },
        whisperChunkDurationSeconds: Double = 12.0
    ) -> AudioSyncManager.Dependencies {
        AudioSyncManager.Dependencies(
            capture: capture,
            hasScreenCaptureAccess: { hasScreenCaptureAccess },
            requestScreenCaptureAccess: {},
            speechAuthorizationStatus: { speechAuthStatus },
            requestSpeechAuthorization: requestSpeechAuth,
            makeSpeechRecognizer: makeSpeechRecognizer,
            locateWhisperCLI: locateWhisperCLI,
            resolveWhisperModelPath: resolveWhisperModelPath,
            runWhisperChunk: runWhisperChunk,
            whisperChunkDurationSeconds: whisperChunkDurationSeconds
        )
    }
}

private final class FakeAudioCapture: AudioCaptureProviding {
    var onAudioSamples: (([Float], Double) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var lastTargetBundleIds: Set<String> = []

    @MainActor
    func start(targetBundleIds: Set<String>) {
        startCount += 1
        lastTargetBundleIds = targetBundleIds
    }

    @MainActor
    func stop() {
        stopCount += 1
    }

    func emit(samples: [Float], sampleRate: Double) {
        onAudioSamples?(samples, sampleRate)
    }
}

private final class FakeSpeechTask: SpeechRecognitionTaskHandling {
    private(set) var isCancelled = false

    func cancel() {
        isCancelled = true
    }
}

private final class FakeSpeechRecognizer: SpeechRecognizing {
    let isAvailable: Bool
    let supportsOnDeviceRecognition: Bool
    private(set) var startedRequests: [SFSpeechAudioBufferRecognitionRequest] = []
    private(set) var createdTasks: [FakeSpeechTask] = []
    private(set) var resultHandlers: [@Sendable ([SpeechRecognizedSegment]?, Error?) -> Void] = []

    init(isAvailable: Bool, supportsOnDeviceRecognition: Bool) {
        self.isAvailable = isAvailable
        self.supportsOnDeviceRecognition = supportsOnDeviceRecognition
    }

    func startRecognitionTask(
        with request: SFSpeechAudioBufferRecognitionRequest,
        resultHandler: @escaping @Sendable ([SpeechRecognizedSegment]?, Error?) -> Void
    ) -> SpeechRecognitionTaskHandling {
        startedRequests.append(request)
        resultHandlers.append(resultHandler)
        let task = FakeSpeechTask()
        createdTasks.append(task)
        return task
    }
}

private final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    func withLock<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }
}
