import AVFoundation
@testable import BarTune
import CoreMedia
import Foundation
import ScreenCaptureKit
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
            locateWhisperServer: { "/usr/local/bin/whisper-server" },
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

    func testWhisperServerKeepsOneProcessAcrossChunksAndStopsOnShutdown() async throws {
        let searchPath = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin"
        let python = searchPath.split(separator: ":").map { "\($0)/python3" }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
        try XCTSkipUnless(python != nil, "python3 runs the fake whisper-server")
        let scriptURL = tempDir.appendingPathComponent("fake-whisper-server")
        let logURL = tempDir.appendingPathComponent("fake-whisper-server.log")
        let script = #"""
        #!/usr/bin/env python3
        import sys
        from http.server import BaseHTTPRequestHandler, HTTPServer

        args = sys.argv[1:]
        port = int(args[args.index("--port") + 1])
        prefix = args[args.index("--request-path") + 1]
        log_path = sys.argv[0] + ".log"
        with open(log_path, "a") as log:
            log.write("load " + args[args.index("-m") + 1] + "\n")

        RESPONSE = b'{"segments":[{"start":0.0,"end":1.0,"text":" Hello","words":[{"word":" Hello","start":0.1,"end":0.5,"probability":0.95}]}]}'

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                self.send_response(200 if self.path == prefix + "/" else 404)
                self.end_headers()

            def do_POST(self):
                body = self.rfile.read(int(self.headers["Content-Length"]))
                if self.path != prefix + "/inference":
                    self.send_response(404)
                    self.end_headers()
                    return
                with open(log_path, "a") as log:
                    log.write("inference verbose_json=%s prompt=%s wav=%s\n" % (b"verbose_json" in body, b"Hello world" in body, b"RIFF" in body))
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(RESPONSE)))
                self.end_headers()
                self.wfile.write(RESPONSE)

            def log_message(self, *args):
                pass

        HTTPServer(("127.0.0.1", port), Handler).serve_forever()
        """#
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)

        let launched = await WhisperServer.launch(serverPath: scriptURL.path, modelPath: "/models/ggml-test.bin", readyTimeout: 10)
        let server = try XCTUnwrap(launched)
        let request = AudioSyncManager.WhisperChunkRequest(
            samples: [Float](repeating: 0.1, count: 160),
            sampleRate: 16000,
            chunkStartTime: 10.0,
            prompt: "Hello world"
        )

        let first = try await server.transcribe(request)
        let second = try await server.transcribe(request)

        XCTAssertEqual(first.map(\.text), ["Hello"])
        XCTAssertEqual(first.first?.startTime ?? 0, 10.1, accuracy: 0.01)
        XCTAssertEqual(second.map(\.text), ["Hello"])
        let log = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(log, [
            "load /models/ggml-test.bin",
            "inference verbose_json=True prompt=True wav=True",
            "inference verbose_json=True prompt=True wav=True",
        ])

        server.shutdown()
        let deadline = Date().addingTimeInterval(2)
        while server.isRunning, Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertFalse(server.isRunning)
        do {
            _ = try await server.transcribe(request)
            XCTFail("A stopped server must report that it exited, not an empty transcript")
        } catch {
            XCTAssertEqual(error as? WhisperServerError, .exited)
        }
    }

    @MainActor
    func testWhisperSessionLaunchesModelOnceAndShutsItDownOnStop() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let launches = LockedBox<Int>(0)
        let chunks = LockedBox<Int>(0)
        let engine = FakeWhisperEngine { _ in
            chunks.withLock { $0 += 1 }
            return []
        }

        let deps = makeDependencies(
            capture: fakeCapture,
            locateWhisperServer: { "/usr/local/bin/whisper-server" },
            resolveWhisperModelPath: { _ in "/tmp/ggml-tiny.bin" },
            launchWhisper: { _, _ in
                launches.withLock { $0 += 1 }
                return engine
            },
            whisperChunkDurationSeconds: 1.0
        )
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        for expected in 1...3 {
            fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
            let processed = await waitUntil { chunks.withLock { $0 } == expected && !manager.isWhisperProcessing }
            XCTAssertTrue(processed, "chunk \(expected) was not transcribed")
        }

        XCTAssertEqual(launches.withLock { $0 }, 1, "The model must load once per session, not once per chunk")
        XCTAssertEqual(engine.shutdownCount, 0)

        manager.stop()
        XCTAssertEqual(engine.shutdownCount, 1)
    }

    @MainActor
    func testWhisperSessionStopsWhenTheServerExits() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let launches = LockedBox<Int>(0)
        let engine = FakeWhisperEngine { _ in throw WhisperServerError.exited }
        let freshChunks = LockedBox<Int>(0)
        let freshEngine = FakeWhisperEngine { _ in
            freshChunks.withLock { $0 += 1 }
            return []
        }

        let deps = makeDependencies(
            capture: fakeCapture,
            locateWhisperServer: { "/usr/local/bin/whisper-server" },
            resolveWhisperModelPath: { _ in "/tmp/ggml-tiny.bin" },
            launchWhisper: { _, _ in
                let count = launches.withLock { value -> Int in
                    value += 1
                    return value
                }
                return count == 1 ? engine : freshEngine
            },
            whisperChunkDurationSeconds: 1.0
        )
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)
        let stopsBeforeFailure = fakeCapture.stopCount

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let stopped = await waitUntil { !manager.isLiveSyncActive }
        XCTAssertTrue(stopped, "A dead whisper-server must end the session instead of listening forever")
        guard case .unavailable = state.audioSyncStatus else {
            XCTFail("Expected .unavailable, got \(state.audioSyncStatus)")
            return
        }
        XCTAssertEqual(engine.shutdownCount, 1)
        XCTAssertEqual(fakeCapture.stopCount, stopsBeforeFailure + 1)
        XCTAssertEqual(launches.withLock { $0 }, 1)

        // The next track starts a fresh server.
        let nextTrack = TrackInfo(id: "spotify:track:test-2", title: "Next", artist: "Test Artist", album: "Test Album", duration: 180, artworkURL: nil)
        manager.handleTrackLoaded(track: nextTrack, rawLines: sampleLines())
        let relaunched = await waitUntil { launches.withLock { $0 } == 2 && manager.isLiveSyncActive }
        XCTAssertTrue(relaunched)
        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let transcribed = await waitUntil { freshChunks.withLock { $0 } == 1 && !manager.isWhisperProcessing }
        XCTAssertTrue(transcribed, "The fresh server must receive the next track's audio")
        XCTAssertTrue(manager.isLiveSyncActive)
        XCTAssertEqual(freshEngine.shutdownCount, 0)
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
            locateWhisperServer: { "/usr/local/bin/whisper-server" },
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
            locateWhisperServer: { "/usr/local/bin/whisper-server" },
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

    // MARK: - #62: Same-track seek re-anchors Apple Speech segment timing

    @MainActor
    func testSameTrackSeekReanchorsSpeech() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .appleSpeech
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let recognizer = FakeSpeechRecognizer(isAvailable: true, supportsOnDeviceRecognition: true)
        let deps = makeDependencies(capture: fakeCapture, makeSpeechRecognizer: { _ in recognizer })
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        // 2 s of audio at track time 10 s, then a seek to 90 s on the same playing track.
        fakeCapture.emit(samples: [Float](repeating: 0, count: 32000), sampleRate: 16000)
        for _ in 0..<10 {
            await Task.yield()
        }
        manager.handlePlaybackStateChanged(isPlaying: true, position: 90.0)

        let segments = [
            SpeechRecognizedSegment(substring: "before", timestamp: 1.0, duration: 0.3, confidence: 0.9),
            SpeechRecognizedSegment(substring: "after", timestamp: 3.0, duration: 0.3, confidence: 0.9),
        ]
        recognizer.resultHandlers.first?(segments, false, nil)
        let delivered = await waitUntil { manager.recognizedWords.count == 2 }
        XCTAssertTrue(delivered)

        XCTAssertEqual(manager.recognizedWords.first?.startTime ?? -1, 11.0, accuracy: 0.01)
        XCTAssertEqual(manager.recognizedWords.last?.startTime ?? -1, 91.0, accuracy: 0.01)
    }

    // MARK: - #65: Terminal recognition error ends the session

    @MainActor
    func testTerminalSpeechErrorStopsCapture() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .appleSpeech
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let recognizer = FakeSpeechRecognizer(isAvailable: true, supportsOnDeviceRecognition: true)
        let deps = makeDependencies(capture: fakeCapture, makeSpeechRecognizer: { _ in recognizer })
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)
        let stopsBeforeError = fakeCapture.stopCount

        let error = NSError(domain: "kAFAssistantErrorDomain", code: 1110, userInfo: [
            NSLocalizedDescriptionKey: "No speech detected",
        ])
        recognizer.resultHandlers.first?(nil, false, error)
        let ended = await waitUntil { !manager.isLiveSyncActive }

        XCTAssertTrue(ended)
        XCTAssertEqual(fakeCapture.stopCount, stopsBeforeError + 1)
        XCTAssertNil(fakeCapture.onAudioSamples)
        XCTAssertEqual(recognizer.createdTasks.first?.isCancelled, true)
        XCTAssertEqual(state.audioSyncStatus, .unavailable("Apple Speech recognition stopped: No speech detected"))
    }

    // MARK: - #63: Late Whisper completion after a same-track restart

    @MainActor
    func testLateWhisperCompletionCannotMutateRestart() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()

        let chunkAStarted = expectation(description: "Whisper chunk A started")
        let chunkBStarted = expectation(description: "Whisper chunk B started")
        let releaseA = DispatchSemaphore(value: 0)
        let releaseB = DispatchSemaphore(value: 0)
        let requestCount = LockedBox<Int>(0)
        let matchingWords = ["Hello", "world", "from", "test"].enumerated().map { index, text in
            RecognizedAudioWord(text: text, startTime: 10.0 + Double(index) * 0.4, duration: 0.3, confidence: 0.9)
        }

        let deps = makeDependencies(
            capture: fakeCapture,
            locateWhisperServer: { "/usr/local/bin/whisper-server" },
            resolveWhisperModelPath: { _ in "/tmp/ggml-tiny.bin" },
            runWhisperChunk: { _ in
                let count = requestCount.withLock { value -> Int in
                    value += 1
                    return value
                }
                if count == 1 {
                    chunkAStarted.fulfill()
                    releaseA.wait()
                    return matchingWords
                }
                if count == 2 {
                    chunkBStarted.fulfill()
                    releaseB.wait()
                }
                return []
            },
            whisperChunkDurationSeconds: 1.0
        )
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        let track = sampleTrack()
        let lines = sampleLines()
        manager.handleTrackLoaded(track: track, rawLines: lines)
        let firstStarted = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount == 1 }
        XCTAssertTrue(firstStarted)
        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        await fulfillment(of: [chunkAStarted], timeout: 2.0)

        // Force resync on the same track and start chunk B while A is still running.
        manager.resyncCurrentTrack()
        let restarted = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount == 2 }
        XCTAssertTrue(restarted)
        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        await fulfillment(of: [chunkBStarted], timeout: 2.0)

        // A completes with matching words while B is pending.
        releaseA.signal()
        for _ in 0..<50 {
            await Task.yield()
        }
        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        for _ in 0..<20 {
            await Task.yield()
        }

        XCTAssertTrue(manager.recognizedWords.isEmpty)
        XCTAssertTrue(manager.isWhisperProcessing, "A must not clear B's processing slot")
        XCTAssertEqual(requestCount.withLock { $0 }, 2, "A third worker must not start while B is pending")
        XCTAssertNil(cache.load(trackId: track.id))
        XCTAssertEqual(state.audioSyncStatus, .syncing(engine: .whisper, alignedLines: 0, totalLines: lines.count))

        releaseB.signal()
    }

    // MARK: - #114: Final Apple Speech result without error ends capture when below threshold

    @MainActor
    func testFinalSpeechResultBelowThresholdWithoutErrorStopsCaptureAndUpdatesStatus() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .appleSpeech
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let recognizer = FakeSpeechRecognizer(isAvailable: true, supportsOnDeviceRecognition: true)
        let spyRequest = SpySpeechRequest()
        let deps = makeDependencies(
            capture: fakeCapture,
            makeSpeechRecognizer: { _ in recognizer },
            makeSpeechRequest: { spyRequest }
        )
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        // Feed audio before completion and confirm the request received it.
        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 1600), sampleRate: 16000)
        let firstAppend = await waitUntil { spyRequest.appendCount == 1 }
        XCTAssertTrue(firstAppend)
        let capturedClosureBeforeFinal = fakeCapture.onAudioSamples
        let stopsBeforeFinal = fakeCapture.stopCount

        // Deliver a final result matching only 1 of 2 lines (below confidentThreshold = 2) with nil error.
        let partialSegments = [
            SpeechRecognizedSegment(substring: "hello", timestamp: 0.1, duration: 0.2, confidence: 0.9),
            SpeechRecognizedSegment(substring: "world", timestamp: 0.4, duration: 0.2, confidence: 0.9),
            SpeechRecognizedSegment(substring: "from", timestamp: 0.7, duration: 0.2, confidence: 0.9),
            SpeechRecognizedSegment(substring: "test", timestamp: 1.0, duration: 0.2, confidence: 0.9),
        ]
        recognizer.resultHandlers.first?(partialSegments, true, nil)
        let ended = await waitUntil { !manager.isLiveSyncActive }

        XCTAssertTrue(ended)
        XCTAssertEqual(fakeCapture.stopCount, stopsBeforeFinal + 1)
        XCTAssertNil(fakeCapture.onAudioSamples)
        XCTAssertEqual(recognizer.createdTasks.first?.isCancelled, true)
        XCTAssertGreaterThanOrEqual(spyRequest.endAudioCount, 1)
        XCTAssertNil(state.audioSyncStatus.overlayBadge, "Visible overlay badge must not stay on Syncing/Listening after capture stops")
        if case .unavailable = state.audioSyncStatus {
            // Expected
        } else {
            XCTFail("Expected .unavailable status after final result below threshold, got \(state.audioSyncStatus)")
        }

        // Subsequent audio callbacks (even through a retained closure) must not reach the old request.
        fakeCapture.emit(samples: [Float](repeating: 0.2, count: 1600), sampleRate: 16000)
        capturedClosureBeforeFinal?([Float](repeating: 0.2, count: 1600), 16000)
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(spyRequest.appendCount, 1)
    }

    // MARK: - #113: Unrelated speech around a single common word stays absent from displayed & cached lyrics

    @MainActor
    func testTranscriptionOverwriteSingleCommonWordAbsentFromDisplayedAndCachedLyrics() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .appleSpeech
        state.replaceLyricsWithTranscription = true
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let recognizer = FakeSpeechRecognizer(isAvailable: true, supportsOnDeviceRecognition: true)
        let deps = makeDependencies(capture: fakeCapture, makeSpeechRecognizer: { _ in recognizer })
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        let track = sampleTrack()
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, duration: 3.0, text: "We are the champions"),
        ]
        state.setTrack(track, lyrics: lines)
        manager.handleTrackLoaded(track: track, rawLines: lines)
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        // One common word ("the") with unrelated speech on either side.
        let mixedSegments = [
            SpeechRecognizedSegment(substring: "unrelated", timestamp: 0.0, duration: 0.2, confidence: 0.95),
            SpeechRecognizedSegment(substring: "the", timestamp: 0.4, duration: 0.2, confidence: 0.95),
            SpeechRecognizedSegment(substring: "chatter", timestamp: 0.8, duration: 0.2, confidence: 0.95),
        ]
        recognizer.resultHandlers.first?(mixedSegments, true, nil)
        for _ in 0..<20 {
            await Task.yield()
        }

        let displayedText = state.rawLyricLines.map(\.text).joined(separator: " ")
        XCTAssertFalse(displayedText.contains("unrelated"))
        XCTAssertFalse(displayedText.contains("chatter"))
        XCTAssertNil(cache.load(trackId: track.id))
    }

    // MARK: - #112: Include-only audio capture isolation & unresolved player handling

    @MainActor
    func testSystemAudioCaptureExcludesNonPlayerLaunchedDuringStartup() async throws {
        let backend = FakeSystemAudioCaptureBackend(initialApps: ["com.spotify.client", "com.apple.Finder"])
        backend.onStartStream = {
            // Simulate a non-player app launching mid-startup while capture starts.
            backend.launchApp(bundleId: "us.zoom.xos")
        }

        let capture = SystemAudioCapture(backend: backend)
        try await capture.start(targetBundleIds: ["com.spotify.client"])

        XCTAssertEqual(backend.startedStreams.count, 1)
        let activeStream = try XCTUnwrap(backend.startedStreams.last)
        XCTAssertEqual(activeStream.capturedBundleIds, ["com.spotify.client"])
        XCTAssertFalse(activeStream.capturedBundleIds.contains("us.zoom.xos"))
    }

    @MainActor
    func testSystemAudioCaptureLeavesCaptureStoppedWhenPlayerUnresolved() async {
        let backend = FakeSystemAudioCaptureBackend(initialApps: ["com.apple.Finder", "com.apple.Safari"])
        let capture = SystemAudioCapture(backend: backend)

        // Player absent from shareable content: must leave capture stopped and throw.
        do {
            try await capture.start(targetBundleIds: ["com.spotify.client"])
            XCTFail("Expected unresolvedPlayer error when target app is not running")
        } catch let error as SystemAudioCaptureError {
            XCTAssertEqual(error, .unresolvedPlayer)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(backend.startedStreams.isEmpty)

        // Empty target bundle IDs: must leave capture stopped without falling back to all-display capture.
        do {
            try await capture.start(targetBundleIds: [])
            XCTFail("Expected unresolvedPlayer error for empty targetBundleIds")
        } catch let error as SystemAudioCaptureError {
            XCTAssertEqual(error, .unresolvedPlayer)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertTrue(backend.startedStreams.isEmpty)

        // AudioSyncManager with an unresolved track prefix must not start capture or recognition.
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .appleSpeech
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let recognizer = FakeSpeechRecognizer(isAvailable: true, supportsOnDeviceRecognition: true)
        let deps = makeDependencies(capture: capture, makeSpeechRecognizer: { _ in recognizer })
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        let unknownTrack = TrackInfo(
            id: "unknown:track:1",
            title: "Unknown",
            artist: "Artist",
            album: "",
            duration: 180,
            artworkURL: nil
        )
        manager.handleTrackLoaded(track: unknownTrack, rawLines: sampleLines())
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertFalse(manager.isLiveSyncActive)
        XCTAssertTrue(backend.startedStreams.isEmpty)
        XCTAssertTrue(recognizer.startedRequests.isEmpty)
        if case .unavailable = state.audioSyncStatus {
            // Expected
        } else {
            XCTFail("Expected .unavailable status for unresolved player, got \(state.audioSyncStatus)")
        }

        // AudioSyncManager with Spotify track when Spotify isn't running must tear down live sync and stop capture.
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let settled = await waitUntil {
            if case .unavailable = state.audioSyncStatus { return !manager.isLiveSyncActive }
            return false
        }
        XCTAssertTrue(settled)
        XCTAssertFalse(manager.isLiveSyncActive)
        XCTAssertTrue(backend.startedStreams.isEmpty)
        XCTAssertEqual(recognizer.createdTasks.first?.isCancelled, true)
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
        makeSpeechRequest: @escaping () -> SFSpeechAudioBufferRecognitionRequest = { SFSpeechAudioBufferRecognitionRequest() },
        locateWhisperServer: @escaping () -> String? = { nil },
        resolveWhisperModelPath: @escaping @Sendable (String) -> String? = { _ in nil },
        runWhisperChunk: @escaping @Sendable (AudioSyncManager.WhisperChunkRequest) -> [RecognizedAudioWord] = { _ in [] },
        launchWhisper: (@Sendable (String, String) async -> WhisperTranscribing?)? = nil,
        whisperChunkDurationSeconds: Double = 12.0
    ) -> AudioSyncManager.Dependencies {
        AudioSyncManager.Dependencies(
            capture: capture,
            hasScreenCaptureAccess: { hasScreenCaptureAccess },
            requestScreenCaptureAccess: {},
            speechAuthorizationStatus: { speechAuthStatus },
            requestSpeechAuthorization: requestSpeechAuth,
            makeSpeechRecognizer: makeSpeechRecognizer,
            makeSpeechRequest: makeSpeechRequest,
            locateWhisperServer: locateWhisperServer,
            resolveWhisperModelPath: resolveWhisperModelPath,
            launchWhisper: launchWhisper ?? { _, _ in FakeWhisperEngine(transcribe: runWhisperChunk) },
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
    private(set) var resultHandlers: [@Sendable ([SpeechRecognizedSegment]?, Bool, Error?) -> Void] = []

    init(isAvailable: Bool, supportsOnDeviceRecognition: Bool) {
        self.isAvailable = isAvailable
        self.supportsOnDeviceRecognition = supportsOnDeviceRecognition
    }

    func startRecognitionTask(
        with request: SFSpeechAudioBufferRecognitionRequest,
        resultHandler: @escaping @Sendable ([SpeechRecognizedSegment]?, Bool, Error?) -> Void
    ) -> SpeechRecognitionTaskHandling {
        startedRequests.append(request)
        resultHandlers.append(resultHandler)
        let task = FakeSpeechTask()
        createdTasks.append(task)
        return task
    }
}

private final class FakeWhisperEngine: WhisperTranscribing, @unchecked Sendable {
    private let handler: @Sendable (AudioSyncManager.WhisperChunkRequest) throws -> [RecognizedAudioWord]
    private let shutdowns = LockedBox<Int>(0)

    var shutdownCount: Int { shutdowns.withLock { $0 } }

    init(transcribe handler: @escaping @Sendable (AudioSyncManager.WhisperChunkRequest) throws -> [RecognizedAudioWord]) {
        self.handler = handler
    }

    // swiftlint:disable:next async_without_await
    func transcribe(_ request: AudioSyncManager.WhisperChunkRequest) async throws -> [RecognizedAudioWord] {
        try handler(request)
    }

    func shutdown() {
        shutdowns.withLock { $0 += 1 }
    }
}

private final class SpySpeechRequest: SFSpeechAudioBufferRecognitionRequest, @unchecked Sendable {
    private let lock = NSLock()
    private var _appendCount = 0
    private var _endAudioCount = 0

    var appendCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _appendCount
    }

    var endAudioCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _endAudioCount
    }

    override func append(_ audioPCMBuffer: AVAudioPCMBuffer) {
        lock.lock()
        _appendCount += 1
        lock.unlock()
        super.append(audioPCMBuffer)
    }

    override func endAudio() {
        lock.lock()
        _endAudioCount += 1
        lock.unlock()
        super.endAudio()
    }
}

private final class FakeSystemAudioStream: SystemAudioStreamControlling, @unchecked Sendable {
    let capturedBundleIds: Set<String>
    private let stopCounter = LockedBox<Int>(0)

    var stopCount: Int { stopCounter.withLock { $0 } }

    init(includedApplications: [CaptureApplication]) {
        capturedBundleIds = Set(includedApplications.map(\.bundleIdentifier))
    }

    func stopCapture() async {
        await Task.yield()
        stopCounter.withLock { $0 += 1 }
    }
}

private final class FakeSystemAudioCaptureBackend: SystemAudioCaptureBackend, @unchecked Sendable {
    private let stateBox: LockedBox<(runningApps: Set<String>, streams: [FakeSystemAudioStream])>
    var onStartStream: (() -> Void)?

    var startedStreams: [FakeSystemAudioStream] {
        stateBox.withLock { $0.streams }
    }

    init(initialApps: [String]) {
        stateBox = LockedBox((Set(initialApps), []))
    }

    func launchApp(bundleId: String) {
        stateBox.withLock { _ = $0.runningApps.insert(bundleId) }
    }

    func fetchShareableContent() async -> CaptureShareableSnapshot {
        await Task.yield()
        let apps = stateBox.withLock { $0.runningApps.sorted().map { CaptureApplication(bundleIdentifier: $0) } }
        return CaptureShareableSnapshot(displays: [CaptureDisplay()], applications: apps)
    }

    @MainActor
    func startStream(
        display: CaptureDisplay,
        includedApplications: [CaptureApplication],
        output: SCStreamOutput,
        audioQueue: DispatchQueue
    ) async -> SystemAudioStreamControlling {
        await Task.yield()
        onStartStream?()
        let stream = FakeSystemAudioStream(includedApplications: includedApplications)
        stateBox.withLock { $0.streams.append(stream) }
        return stream
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
