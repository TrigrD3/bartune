import AVFoundation
@testable import BarTune
import CoreMedia
import Foundation
import ScreenCaptureKit
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
            dtw = " dtw " + args[args.index("-dtw") + 1] if "-dtw" in args else ""
            log.write("load " + args[args.index("-m") + 1] + dtw + "\n")

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
                    log.write("inference verbose_json=%s prompt=%s wav=%s\n" % (b"verbose_json" in body, b'name="prompt"' in body, b"RIFF" in body))
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

        let launched = await WhisperServer.launch(serverPath: scriptURL.path, modelPath: "/models/ggml-base.bin", readyTimeout: 10)
        let server = try XCTUnwrap(launched)
        let request = AudioSyncManager.WhisperChunkRequest(
            samples: [Float](repeating: 0.1, count: 160),
            sampleRate: 16000,
            chunkStartTime: 10.0,
            playbackRate: 1.0
        )

        let first = try await server.transcribe(request)
        let second = try await server.transcribe(request)

        XCTAssertEqual(first.map(\.text), ["Hello"])
        XCTAssertEqual(first.first?.startTime ?? 0, 10.1, accuracy: 0.01)
        XCTAssertEqual(second.map(\.text), ["Hello"])
        let log = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(log, [
            "load /models/ggml-base.bin dtw base",
            "inference verbose_json=True prompt=False wav=True",
            "inference verbose_json=True prompt=False wav=True",
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

    func testRecognitionLevelRaisesQuietAudioAndLeavesSilenceAlone() {
        let quiet: [Float] = [0.02, -0.024, 0.01, 0]
        let raised = AudioLevel.normalizedForRecognition(quiet)
        XCTAssertEqual(raised.map { abs($0) }.max() ?? 0, 0.95, accuracy: 0.001)
        XCTAssertEqual(raised[0] / raised[2], 2.0, accuracy: 0.001, "one gain for the whole chunk")

        let nearSilence: [Float] = [0.00005, -0.00003]
        XCTAssertEqual(AudioLevel.normalizedForRecognition(nearSilence), nearSilence)

        let faint: [Float] = [0.001, -0.0005]
        XCTAssertEqual(AudioLevel.normalizedForRecognition(faint)[0], 0.1, accuracy: 0.0001, "gain is capped at 100x")
    }

    @MainActor
    func testWhisperChunksAreRaisedToRecognitionLevel() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let fakeCapture = FakeAudioCapture()
        let peaks = LockedBox<[Float]>([])
        let deps = makeDependencies(
            capture: fakeCapture,
            locateWhisperServer: { "/usr/local/bin/whisper-server" },
            resolveWhisperModelPath: { _ in "/tmp/ggml-base.bin" },
            runWhisperChunk: { request in
                peaks.withLock { $0.append(request.samples.map { abs($0) }.max() ?? 0) }
                return []
            },
            whisperChunkDurationSeconds: 1.0
        )
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        // Player volume turned down: the captured chunk peaks at 0.024.
        fakeCapture.emit(samples: (0..<100).map { $0.isMultiple(of: 2) ? 0.024 : -0.012 }, sampleRate: 100)
        let sent = await waitUntil { !peaks.withLock { $0 }.isEmpty }

        XCTAssertTrue(sent)
        XCTAssertEqual(peaks.withLock { $0 }.first ?? 0, 0.95, accuracy: 0.001)
    }

    @MainActor
    func testLyricsAlignmentAppliesAlignedWordsWithoutWhisper() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let fakeCapture = FakeAudioCapture()
        let launchedWith = LockedBox<[String]>([])
        let aligned = ["Hello", "world", "from", "test"].enumerated().map { index, word in
            RecognizedAudioWord(text: word, startTime: 11.0 + Double(index) * 0.5, duration: 0.4, confidence: 0.5)
        }
        let deps = AudioSyncManager.Dependencies(
            capture: fakeCapture,
            hasScreenCaptureAccess: { true },
            requestScreenCaptureAccess: {},
            locateWhisperServer: { nil },
            resolveWhisperModelPath: { _ in nil },
            launchWhisper: { _, _ in nil },
            whisperChunkDurationSeconds: 1.0,
            launchLyricsAligner: { lines, _ in
                launchedWith.withLock { $0 = lines.map(\.text) }
                return FakeWhisperEngine { _ in aligned }
            }
        )
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started, "capture starts without a whisper-server")
        XCTAssertEqual(launchedWith.withLock { $0 }, sampleLines().map(\.text))

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let synced = await waitUntil { state.audioSyncStatus != .syncing(engine: .lyricsAlignment, alignedLines: 0, totalLines: 2) }

        XCTAssertTrue(synced)
        XCTAssertEqual(state.audioSyncStatus, .syncing(engine: .lyricsAlignment, alignedLines: 1, totalLines: 2))
        XCTAssertEqual(state.rawLyricLines.first?.timestamp ?? 0, 11.0, accuracy: 0.01)
    }

    @MainActor
    func testLyricsAlignmentKeepsSavedLinesAndAlignsOnlyTheMissingOnes() async throws {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let source = threeLines()
        // An earlier play aligned lines 0 and 1 (0.7 s late); line 2 kept its LRC time.
        let saved = [
            LyricLine(id: 0, timestamp: 10.7, text: "Alpha beta", words: [
                WordTimestamp(timestamp: 10.7, duration: 0.3, text: "Alpha "),
                WordTimestamp(timestamp: 11.1, duration: 0.3, text: "beta"),
            ]),
            LyricLine(id: 1, timestamp: 15.7, text: "Gamma delta", words: [
                WordTimestamp(timestamp: 15.7, duration: 0.3, text: "Gamma "),
                WordTimestamp(timestamp: 16.1, duration: 0.3, text: "delta"),
            ]),
            LyricLine(id: 2, timestamp: 20.7, text: "Epsilon zeta"),
        ]
        cache.save(AudioSyncedLyricsRecord(
            trackId: sampleTrack().id, engine: .lyricsAlignment, syncedAt: Date(), medianOffset: 0.7,
            alignedLineCount: 2, sourceLineCount: 3, lines: saved
        ))
        let anchorsSeen = LockedBox<[Int: ClosedRange<Double>]>([:])
        let lineTwo = ["Epsilon", "zeta"].enumerated().map { index, word in
            RecognizedAudioWord(text: word, startTime: 21.2 + Double(index) * 0.5, duration: 0.4, confidence: 0.5)
        }
        let fakeCapture = FakeAudioCapture()
        var deps = makeDependencies(capture: fakeCapture)
        deps.whisperChunkDurationSeconds = 1.0
        deps.launchLyricsAligner = { _, anchors in
            anchorsSeen.withLock { $0 = anchors }
            return FakeWhisperEngine { _ in lineTwo }
        }
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: source)

        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started, "two of three lines is not done: the missing line is still listened for")
        let anchors = anchorsSeen.withLock { $0 }
        XCTAssertEqual(anchors.keys.sorted(), [0, 1], "only the saved, aligned lines are anchors")
        XCTAssertEqual(anchors[0]?.upperBound ?? 0, 11.4, accuracy: 0.001)
        XCTAssertEqual(anchors[1]?.lowerBound ?? 0, 15.7, accuracy: 0.001)

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let done = await waitUntil { state.audioSyncStatus == .cached(.lyricsAlignment) }
        XCTAssertTrue(done)

        let record = try XCTUnwrap(cache.load(trackId: sampleTrack().id))
        XCTAssertEqual(record.alignedLineCount, 3)
        XCTAssertEqual(record.lines.map(\.timestamp), [10.7, 15.7, 21.2])
        XCTAssertEqual(record.lines.prefix(2).map(\.words), saved.prefix(2).map(\.words), "saved lines stay as aligned")
        XCTAssertFalse(manager.isLiveSyncActive)
    }

    @MainActor
    func testLyricsAlignmentKeepsListeningPastSixtyPercent() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        let words = ["Alpha", "beta", "Gamma", "delta"].enumerated().map { index, word in
            RecognizedAudioWord(text: word, startTime: [10.7, 11.1, 15.7, 16.1][index], duration: 0.3, confidence: 0.5)
        }
        let fakeCapture = FakeAudioCapture()
        var deps = makeDependencies(capture: fakeCapture)
        deps.whisperChunkDurationSeconds = 1.0
        deps.launchLyricsAligner = { _, _ in FakeWhisperEngine { _ in words } }
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: threeLines())
        _ = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let progressed = await waitUntil { state.audioSyncStatus != .syncing(engine: .lyricsAlignment, alignedLines: 0, totalLines: 3) }

        XCTAssertTrue(progressed)
        XCTAssertEqual(state.audioSyncStatus, .syncing(engine: .lyricsAlignment, alignedLines: 2, totalLines: 3))
        XCTAssertTrue(manager.isLiveSyncActive, "two of three lines is past 60% but not every line")
    }

    @MainActor
    func testLyricsAlignmentIsDoneAfterOnePlayListenedForEveryLine() async throws {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let words = ["Alpha", "beta", "Gamma", "delta"].enumerated().map { index, word in
            RecognizedAudioWord(text: word, startTime: [10.7, 11.1, 15.7, 16.1][index], duration: 0.3, confidence: 0.5)
        }
        // The engine had the audio for every line but could only align two.
        let engine = FakeAttemptingEngine(words: words, attempted: [0, 1, 2])
        let launches = LockedBox<Int>(0)
        let fakeCapture = FakeAudioCapture()
        var deps = makeDependencies(capture: fakeCapture)
        deps.whisperChunkDurationSeconds = 1.0
        deps.launchLyricsAligner = { _, _ in
            launches.withLock { $0 += 1 }
            return engine
        }
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: threeLines())
        _ = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let done = await waitUntil { state.audioSyncStatus == .cached(.lyricsAlignment) }
        XCTAssertTrue(done, "a line listened for once is not listened for again")
        XCTAssertFalse(manager.isLiveSyncActive)
        let record = try XCTUnwrap(cache.load(trackId: sampleTrack().id))
        XCTAssertEqual(record.checkedLineIDs, [2])

        manager.handleTrackLoaded(track: sampleTrack(), rawLines: threeLines())
        XCTAssertEqual(state.audioSyncStatus, .cached(.lyricsAlignment))
        XCTAssertEqual(launches.withLock { $0 }, 1, "the next play loads the saved sync without listening")
    }

    @MainActor
    func testLyricsAlignmentListensAgainForLinesAPartialPlayMissed() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let words = ["Alpha", "beta"].enumerated().map { index, word in
            RecognizedAudioWord(text: word, startTime: [10.7, 11.1][index], duration: 0.3, confidence: 0.5)
        }
        let fakeCapture = FakeAudioCapture()
        var deps = makeDependencies(capture: fakeCapture)
        deps.whisperChunkDurationSeconds = 1.0
        deps.launchLyricsAligner = { _, _ in FakeAttemptingEngine(words: words, attempted: [0, 1]) }
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: threeLines())
        _ = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let saved = await waitUntil { cache.load(trackId: sampleTrack().id)?.checkedLineIDs == [1] }
        XCTAssertTrue(saved)
        XCTAssertTrue(manager.isLiveSyncActive, "line 2 has not been heard yet")
        XCTAssertEqual(state.audioSyncStatus, .syncing(engine: .lyricsAlignment, alignedLines: 1, totalLines: 3))
    }

    func testLyricsAlignmentCountsLinesInTheUnreachedTailOnceTheRestIsDone() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "Alpha"),
            LyricLine(id: 1, timestamp: 20.0, text: "Beta"),
            LyricLine(id: 2, timestamp: 40.0, text: "Omega"),
            LyricLine(id: 3, timestamp: 44.0, text: "♪"),
        ]
        XCTAssertTrue(AudioSyncManager.lyricsAlignmentIsComplete(alignedIDs: [0], checkedIDs: [1], lines: lines, trackDuration: 60))
        XCTAssertFalse(
            AudioSyncManager.lyricsAlignmentIsComplete(alignedIDs: [0], lines: lines, trackDuration: 60),
            "line 1 is not in the tail"
        )
        XCTAssertFalse(
            AudioSyncManager.lyricsAlignmentIsComplete(alignedIDs: [0, 1], lines: lines, trackDuration: 0),
            "with no known duration there is no tail"
        )
        XCTAssertFalse(
            AudioSyncManager.lyricsAlignmentIsComplete(alignedIDs: [0, 1], lines: lines, trackDuration: 120),
            "line 2 is reachable in a longer song"
        )
    }

    @MainActor
    func testLyricsAlignmentReportsAMissingModel() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        let fakeCapture = FakeAudioCapture()
        var deps = makeDependencies(capture: fakeCapture)
        deps.launchLyricsAligner = { _, _ in nil }
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())

        let reported = await waitUntil {
            if case .unavailable = state.audioSyncStatus { return true }
            return false
        }
        XCTAssertTrue(reported)
        XCTAssertEqual(fakeCapture.startCount, 0)
    }

    @MainActor
    func testWhisperChunksCarryTheLyricLanguage() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let fakeCapture = FakeAudioCapture()
        let languages = LockedBox<[String?]>([])
        let deps = makeDependencies(
            capture: fakeCapture,
            locateWhisperServer: { "/usr/local/bin/whisper-server" },
            resolveWhisperModelPath: { _ in "/tmp/ggml-base.bin" },
            runWhisperChunk: { request in
                languages.withLock { $0.append(request.language) }
                return []
            },
            whisperChunkDurationSeconds: 1.0
        )
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        let lines = [
            LyricLine(id: 0, timestamp: 10, text: "君の名前を呼んでいる"),
            LyricLine(id: 1, timestamp: 14, text: "夜が明けるまで歌おう"),
        ]
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: lines)
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let sent = await waitUntil { !languages.withLock { $0 }.isEmpty }

        XCTAssertTrue(sent)
        XCTAssertEqual(languages.withLock { $0 }.first, "ja")
        XCTAssertEqual(manager.diagnostics.snapshot?.localeIdentifier, "ja")
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
        state.audioSyncEngine = .whisper
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let deps = whisperDependencies(capture: fakeCapture, feed: LockedBox([]))
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let launched = await waitUntil { manager.isLiveSyncActive }
        XCTAssertTrue(launched)
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

    // MARK: - #115: Seek discards partial Whisper chunk

    @MainActor
    func testWhisperDiscardsPartialChunkOnSameTrackSeek() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let recordedRequests = LockedBox<[AudioSyncManager.WhisperChunkRequest]>([])
        let chunkDispatched = expectation(description: "Post-seek Whisper chunk dispatched")

        let deps = makeDependencies(
            capture: fakeCapture,
            locateWhisperServer: { "/usr/local/bin/whisper-server" },
            resolveWhisperModelPath: { _ in "/tmp/ggml-tiny.bin" },
            runWhisperChunk: { request in
                recordedRequests.withLock { $0.append(request) }
                chunkDispatched.fulfill()
                return []
            },
            whisperChunkDurationSeconds: 1.0
        )

        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        // Emit half of a 1.0s chunk (50 of 100 frames) at position 10.0.
        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 50), sampleRate: 100.0)
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(manager.bufferedWhisperSampleCount, 50)
        XCTAssertEqual(manager.currentWhisperChunkStartPos ?? -1, 10.0, accuracy: 0.01)

        // Same-track seek to 90.0 while chunk is half full must discard the pre-seek samples.
        manager.handlePlaybackStateChanged(isPlaying: true, position: 90.0)
        XCTAssertEqual(manager.bufferedWhisperSampleCount, 0)
        XCTAssertNil(manager.currentWhisperChunkStartPos)

        // Emit 60 post-seek frames: must NOT trigger a mixed chunk immediately (50 + 60 >= 100).
        fakeCapture.emit(samples: [Float](repeating: 0.95, count: 60), sampleRate: 100.0)
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertTrue(recordedRequests.withLock { $0.isEmpty })
        XCTAssertEqual(manager.bufferedWhisperSampleCount, 60)
        XCTAssertEqual(manager.currentWhisperChunkStartPos ?? -1, 90.0, accuracy: 0.01)

        // Emit remaining 40 post-seek frames to complete the clean post-seek chunk.
        fakeCapture.emit(samples: [Float](repeating: 0.95, count: 40), sampleRate: 100.0)
        await fulfillment(of: [chunkDispatched], timeout: 2.0)

        let requests = recordedRequests.withLock { $0 }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.chunkStartTime ?? -1, 90.0, accuracy: 0.01)
        XCTAssertEqual(requests.first?.samples.count, 100)
        XCTAssertTrue(requests.first?.samples.allSatisfy { abs($0 - 0.95) < 0.001 } ?? false)
    }

    @MainActor
    func testWhisperDropsQueuedPreSeekSamplesDeliveredAfterSeek() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let recordedRequests = LockedBox<[AudioSyncManager.WhisperChunkRequest]>([])
        let chunkDispatched = expectation(description: "Post-seek Whisper chunk dispatched")

        let deps = makeDependencies(
            capture: fakeCapture,
            locateWhisperServer: { "/usr/local/bin/whisper-server" },
            resolveWhisperModelPath: { _ in "/tmp/ggml-tiny.bin" },
            runWhisperChunk: { request in
                recordedRequests.withLock { $0.append(request) }
                chunkDispatched.fulfill()
                return []
            },
            whisperChunkDurationSeconds: 1.0
        )

        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 50), sampleRate: 100.0)
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(manager.bufferedWhisperSampleCount, 50)

        // Pre-seek audio captured but still queued for main-actor delivery when the seek lands.
        fakeCapture.emit(samples: [Float](repeating: 0.2, count: 30), sampleRate: 100.0)
        manager.handlePlaybackStateChanged(isPlaying: true, position: 90.0)
        fakeCapture.emit(samples: [Float](repeating: 0.95, count: 100), sampleRate: 100.0)
        await fulfillment(of: [chunkDispatched], timeout: 2.0)

        let requests = recordedRequests.withLock { $0 }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.chunkStartTime ?? -1, 90.0, accuracy: 0.01)
        XCTAssertTrue(requests.first?.samples.allSatisfy { abs($0 - 0.95) < 0.001 } ?? false)
    }

    @MainActor
    func testWhisperDropsQueuedPreSeekSamplesWhenBufferIsEmpty() async {
        let requests = await runEmptyBufferDiscontinuity { state in
            state.playbackAnchorPosition = 90.0
            state.playbackAnchorDate = Date()
        }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.chunkStartTime ?? -1, 90.0, accuracy: 0.01)
        XCTAssertTrue(requests.first?.samples.allSatisfy { abs($0 - 0.95) < 0.001 } ?? false)
    }

    @MainActor
    func testWhisperDropsQueuedPreRateChangeSamplesWhenBufferIsEmpty() async {
        let requests = await runEmptyBufferDiscontinuity { state in
            state.playbackRate = 2.0
        }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.playbackRate ?? -1, 2.0, accuracy: 0.001)
        XCTAssertTrue(requests.first?.samples.allSatisfy { abs($0 - 0.95) < 0.001 } ?? false)
    }

    /// Queues pre-change audio with an empty chunk buffer, applies `change` to live state first (as AppDelegate does), then reports it.
    @MainActor
    private func runEmptyBufferDiscontinuity(_ change: (LyricsState) -> Void) async -> [AudioSyncManager.WhisperChunkRequest] {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let recordedRequests = LockedBox<[AudioSyncManager.WhisperChunkRequest]>([])
        let chunkDispatched = expectation(description: "Post-change Whisper chunk dispatched")

        let deps = makeDependencies(
            capture: fakeCapture,
            locateWhisperServer: { "/usr/local/bin/whisper-server" },
            resolveWhisperModelPath: { _ in "/tmp/ggml-tiny.bin" },
            runWhisperChunk: { request in
                recordedRequests.withLock { $0.append(request) }
                chunkDispatched.fulfill()
                return []
            },
            whisperChunkDurationSeconds: 1.0
        )

        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)
        XCTAssertEqual(manager.bufferedWhisperSampleCount, 0)

        fakeCapture.emit(samples: [Float](repeating: 0.2, count: 30), sampleRate: 100.0)
        change(state)
        manager.handlePlaybackStateChanged(isPlaying: false, position: state.playbackAnchorPosition)
        fakeCapture.emit(samples: [Float](repeating: 0.95, count: 100), sampleRate: 100.0)
        await fulfillment(of: [chunkDispatched], timeout: 2.0)
        return recordedRequests.withLock { $0 }
    }

    @MainActor
    func testWhisperSecondSeekBeforeNextBufferAnchorsChunkToLatestSeek() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let recordedRequests = LockedBox<[AudioSyncManager.WhisperChunkRequest]>([])
        let chunkDispatched = expectation(description: "Post-seek Whisper chunk dispatched")

        let deps = makeDependencies(
            capture: fakeCapture,
            locateWhisperServer: { "/usr/local/bin/whisper-server" },
            resolveWhisperModelPath: { _ in "/tmp/ggml-tiny.bin" },
            runWhisperChunk: { request in
                recordedRequests.withLock { $0.append(request) }
                chunkDispatched.fulfill()
                return []
            },
            whisperChunkDurationSeconds: 1.0
        )

        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 50), sampleRate: 100.0)
        for _ in 0..<10 {
            await Task.yield()
        }

        // Seek to 90 s, then to 140 s before the next buffer; the caller updates live state first.
        state.playbackAnchorPosition = 90.0
        manager.handlePlaybackStateChanged(isPlaying: false, position: 90.0)
        state.playbackAnchorPosition = 140.0
        manager.handlePlaybackStateChanged(isPlaying: false, position: 140.0)

        fakeCapture.emit(samples: [Float](repeating: 0.95, count: 100), sampleRate: 100.0)
        await fulfillment(of: [chunkDispatched], timeout: 2.0)

        let requests = recordedRequests.withLock { $0 }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.chunkStartTime ?? -1, 140.0, accuracy: 0.01)
    }

    @MainActor
    func testWhisperChunkRequestCarriesPlaybackRate() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        state.playbackRate = 2.0
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let recordedRequests = LockedBox<[AudioSyncManager.WhisperChunkRequest]>([])
        let chunkDispatched = expectation(description: "Whisper chunk dispatched")

        let deps = makeDependencies(
            capture: fakeCapture,
            locateWhisperServer: { "/usr/local/bin/whisper-server" },
            resolveWhisperModelPath: { _ in "/tmp/ggml-tiny.bin" },
            runWhisperChunk: { request in
                recordedRequests.withLock { $0.append(request) }
                chunkDispatched.fulfill()
                return []
            },
            whisperChunkDurationSeconds: 1.0
        )

        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        fakeCapture.emit(samples: [Float](repeating: 0.5, count: 100), sampleRate: 100.0)
        await fulfillment(of: [chunkDispatched], timeout: 2.0)

        XCTAssertEqual(recordedRequests.withLock { $0.first?.playbackRate } ?? -1, 2.0, accuracy: 0.001)
    }

    // MARK: - #137: Diagnostics record recognizer output even when no line matches

    @MainActor
    func testDiagnosticsRecordUnmatchedRecognizerResult() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let fakeCapture = FakeAudioCapture()
        let feed = LockedBox<[[RecognizedAudioWord]]>([])
        let deps = whisperDependencies(capture: fakeCapture, feed: feed)
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 250), sampleRate: 100)
        let audioCounted = await waitUntil { manager.diagnostics.snapshot?.audioSeconds == 2 }
        XCTAssertTrue(audioCounted, "2.5 s of captured audio should read as 2 whole seconds")
        let unrelated = [
            RecognizedAudioWord(text: "banana", startTime: 10.1, duration: 0.2, confidence: 0.4),
            RecognizedAudioWord(text: "orange", startTime: 10.5, duration: 0.2, confidence: 0.3),
        ]
        let heard = await hear(unrelated, manager: manager, capture: fakeCapture, feed: feed)

        XCTAssertTrue(heard)
        let snapshot = manager.diagnostics.snapshot
        XCTAssertEqual(snapshot?.engine, .whisper)
        XCTAssertEqual(snapshot?.localeIdentifier, "en")
        XCTAssertEqual(snapshot?.recentWords.map(\.text), ["banana", "orange"])
        XCTAssertEqual(snapshot?.matchedLineCount, 0)
        XCTAssertEqual(snapshot?.totalLines, 2)
        XCTAssertEqual(snapshot?.lineResults.map(\.matched), [false, false])
    }

    private static let tenLineWords = [
        ["amber", "river", "glows"], ["silver", "moon", "rises"], ["quiet", "forest", "sleeps"],
        ["golden", "field", "sways"], ["distant", "thunder", "rolls"], ["crimson", "petals", "fall"],
        ["frozen", "lake", "shines"], ["wandering", "clouds", "drift"], ["hidden", "valley", "waits"],
        ["burning", "candle", "fades"],
    ]

    private func tenLines() -> [LyricLine] {
        Self.tenLineWords.enumerated().map { index, words in
            LyricLine(id: index, timestamp: 10.0 + Double(index) * 3.0, text: words.joined(separator: " "))
        }
    }

    /// Words for the given lines as Whisper would report them, at track time 10 + 3 s per line.
    private func heardWords(lines range: Range<Int>) -> [RecognizedAudioWord] {
        range.flatMap { index in
            Self.tenLineWords[index].enumerated().map {
                RecognizedAudioWord(
                    text: $0.element,
                    startTime: 10.1 + Double(index) * 3.0 + Double($0.offset) * 0.4,
                    duration: 0.2,
                    confidence: 0.9
                )
            }
        }
    }

    /// Dependencies whose Whisper engine returns `feed`'s batches in order, one per 1 s chunk of 100 Hz samples.
    private func whisperDependencies(
        capture: FakeAudioCapture,
        feed: LockedBox<[[RecognizedAudioWord]]>,
        launchWhisper: (@Sendable (String, String) async -> WhisperTranscribing?)? = nil
    ) -> AudioSyncManager.Dependencies {
        makeDependencies(
            capture: capture,
            locateWhisperServer: { "/usr/local/bin/whisper-server" },
            resolveWhisperModelPath: { _ in "/tmp/ggml-base.bin" },
            runWhisperChunk: { _ in feed.withLock { $0.isEmpty ? [] : $0.removeFirst() } },
            launchWhisper: launchWhisper,
            whisperChunkDurationSeconds: 1.0
        )
    }

    /// Delivers one Whisper chunk that hears `words`, then waits for it to be processed.
    @MainActor
    private func hear(
        _ words: [RecognizedAudioWord],
        manager: AudioSyncManager,
        capture: FakeAudioCapture,
        feed: LockedBox<[[RecognizedAudioWord]]>
    ) async -> Bool {
        feed.withLock { $0.append(words) }
        capture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        return await waitUntil { feed.withLock { $0.isEmpty } && !manager.isWhisperProcessing }
    }

    @MainActor
    private func startTenLineSync(
        cache: AudioSyncedLyricsCache
    ) -> (AudioSyncManager, LockedBox<[[RecognizedAudioWord]]>, FakeAudioCapture, LyricsState) {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let fakeCapture = FakeAudioCapture()
        let feed = LockedBox<[[RecognizedAudioWord]]>([])
        let manager = AudioSyncManager(
            state: state,
            cache: cache,
            dependencies: whisperDependencies(capture: fakeCapture, feed: feed)
        )
        state.setTrack(sampleTrack(), lyrics: tenLines())
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: tenLines())
        return (manager, feed, fakeCapture, state)
    }

    @MainActor
    func testLiveSyncKeepsListeningUntilMostLinesAreHeard() async {
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let (manager, feed, capture, state) = startTenLineSync(cache: cache)
        let started = await waitUntil { manager.isLiveSyncActive && capture.startCount > 0 }
        XCTAssertTrue(started)

        let firstChunk = await hear(heardWords(lines: 0..<3), manager: manager, capture: capture, feed: feed)
        XCTAssertTrue(firstChunk)
        XCTAssertEqual(manager.diagnostics.snapshot?.matchedLineCount, 3)
        XCTAssertTrue(manager.isLiveSyncActive, "3 of 10 lines must not end the sync")
        XCTAssertEqual(state.audioSyncStatus, .syncing(engine: .whisper, alignedLines: 3, totalLines: 10))
        XCTAssertEqual(cache.load(trackId: sampleTrack().id)?.alignedLineCount, 3, "partial progress is saved")

        _ = await hear(heardWords(lines: 3..<6), manager: manager, capture: capture, feed: feed)
        let finished = await waitUntil { state.audioSyncStatus == .cached(.whisper) }
        XCTAssertTrue(finished, "6 of 10 lines completes the sync; status \(state.audioSyncStatus)")
        XCTAssertFalse(manager.isLiveSyncActive)
    }

    @MainActor
    func testPartialCacheIsShownAndRefinedButNeverDowngraded() async {
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        var cachedLines = tenLines()
        for index in 0..<3 {
            cachedLines[index] = LyricLine(
                id: index, timestamp: cachedLines[index].timestamp + 0.5, text: cachedLines[index].text
            )
        }
        cache.save(AudioSyncedLyricsRecord(
            trackId: sampleTrack().id, engine: .whisper, syncedAt: Date(), medianOffset: 0.5,
            alignedLineCount: 3, sourceLineCount: 10, lines: cachedLines
        ))

        let (manager, feed, capture, state) = startTenLineSync(cache: cache)
        let started = await waitUntil { manager.isLiveSyncActive && capture.startCount > 0 }
        XCTAssertTrue(started, "a partial record keeps listening")
        state.updatePlayback(isPlaying: true, position: 10.2)
        XCTAssertNil(state.activeLine, "the partial record's timings are shown while listening")
        state.updatePlayback(isPlaying: false, position: 10.0)

        let oneHeard = await hear(heardWords(lines: 0..<1), manager: manager, capture: capture, feed: feed)
        XCTAssertTrue(oneHeard)
        XCTAssertEqual(manager.diagnostics.snapshot?.matchedLineCount, 1)
        XCTAssertEqual(cache.load(trackId: sampleTrack().id)?.alignedLineCount, 3, "a weaker result must not replace the cache")

        _ = await hear(heardWords(lines: 1..<4), manager: manager, capture: capture, feed: feed)
        let improved = await waitUntil { cache.load(trackId: sampleTrack().id)?.alignedLineCount == 4 }
        XCTAssertTrue(improved)
    }

    func testMergeHeardWordsKeepsEarlierPlaysOnlyWhereThisPlayIsSilent() {
        func word(_ text: String, _ start: Double) -> RecognizedAudioWord {
            RecognizedAudioWord(text: text, startTime: start, duration: 0.3, confidence: 0.9)
        }
        let prior = [word("a", 1), word("b", 5), word("c", 20)]
        let current = [word("B", 5.2), word("d", 30)]

        let merged = AudioSyncManager.mergeHeardWords(prior: prior, current: current)

        XCTAssertEqual(merged.map(\.text), ["a", "B", "c", "d"])
    }

    @MainActor
    func testLaterPlayAddsToWordsHeardOnEarlierPlays() async {
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        // Play 1 heard lines 0-3 (track time = 10 + 3 * line).
        let firstPlay = heardWords(lines: 0..<4)
        let firstResult = LyricsAudioAligner.align(lines: tenLines(), recognizedWords: firstPlay)
        XCTAssertEqual(firstResult.matchedLineCount, 4)
        cache.save(AudioSyncedLyricsRecord(
            trackId: sampleTrack().id, engine: .whisper, syncedAt: Date(), medianOffset: firstResult.medianOffset,
            alignedLineCount: 4, sourceLineCount: 10, lines: firstResult.lines, heardWords: firstPlay
        ))

        let (manager, feed, capture, state) = startTenLineSync(cache: cache)
        let started = await waitUntil { manager.isLiveSyncActive && capture.startCount > 0 }
        XCTAssertTrue(started)

        // Play 2 only catches lines 4 and 5.
        _ = await hear(heardWords(lines: 4..<6), manager: manager, capture: capture, feed: feed)
        let completed = await waitUntil { state.audioSyncStatus == .cached(.whisper) }

        XCTAssertTrue(completed, "4 earlier + 2 new lines reach 6/10; status \(state.audioSyncStatus)")
        XCTAssertEqual(cache.load(trackId: sampleTrack().id)?.alignedLineCount, 6)
    }

    @MainActor
    func testRecordAlignedToOtherLyricsIsDiscarded() async {
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let oldLyrics = tenLines().map { LyricLine(id: $0.id, timestamp: $0.timestamp, text: $0.text + " / annotation") }
        cache.save(AudioSyncedLyricsRecord(
            trackId: sampleTrack().id, engine: .whisper, syncedAt: Date(), medianOffset: 0.2,
            alignedLineCount: 8, sourceLineCount: 10, lines: oldLyrics
        ))

        let (manager, _, capture, state) = startTenLineSync(cache: cache)
        let started = await waitUntil { manager.isLiveSyncActive && capture.startCount > 0 }

        XCTAssertTrue(started, "lyrics changed, so the old alignment must not be used")
        XCTAssertNil(cache.load(trackId: sampleTrack().id))
        state.updatePlayback(isPlaying: true, position: 10.2)
        XCTAssertEqual(state.currentText, "amber river glows")
    }

    @MainActor
    func testCompleteCacheSkipsListening() {
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        cache.save(AudioSyncedLyricsRecord(
            trackId: sampleTrack().id, engine: .whisper, syncedAt: Date(), medianOffset: 0.2,
            alignedLineCount: 6, sourceLineCount: 10, lines: tenLines()
        ))

        let (manager, _, capture, state) = startTenLineSync(cache: cache)

        XCTAssertEqual(state.audioSyncStatus, .cached(.whisper))
        XCTAssertFalse(manager.isLiveSyncActive)
        XCTAssertEqual(capture.startCount, 0)
    }

    @MainActor
    func testUnreliablePartialCacheRetainsHeardWordsWithoutApplyingTimings() async {
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let firstPlay = heardWords(lines: 0..<1)
        var shiftedLines = tenLines()
        shiftedLines[0] = LyricLine(id: 0, timestamp: shiftedLines[0].timestamp + 0.5, text: shiftedLines[0].text)
        cache.save(AudioSyncedLyricsRecord(
            trackId: sampleTrack().id, engine: .whisper, syncedAt: Date(), medianOffset: 0.5,
            alignedLineCount: 1, sourceLineCount: 10, lines: shiftedLines, heardWords: firstPlay
        ))

        let (manager, feed, capture, state) = startTenLineSync(cache: cache)
        let started = await waitUntil { manager.isLiveSyncActive && capture.startCount > 0 }
        XCTAssertTrue(started)

        // Unreliable timings (+0.5s shift) must not be applied to display.
        state.updatePlayback(isPlaying: true, position: 10.2)
        XCTAssertEqual(state.currentText, "amber river glows")
        state.updatePlayback(isPlaying: false, position: 10.0)

        // Hearing 5 more lines combines with the 1 retained line to reach 6/10 completion.
        _ = await hear(heardWords(lines: 1..<6), manager: manager, capture: capture, feed: feed)
        let completed = await waitUntil { state.audioSyncStatus == .cached(.whisper) }
        XCTAssertTrue(completed, "1 retained + 5 new lines must reach 6/10; status \(state.audioSyncStatus)")
        XCTAssertEqual(cache.load(trackId: sampleTrack().id)?.alignedLineCount, 6)
    }

    @MainActor
    func testDiagnosticsResetWhenTrackChangesToCachedOrDisabledTrack() async {
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let (manager, feed, capture, state) = startTenLineSync(cache: cache)
        let started = await waitUntil { manager.isLiveSyncActive && capture.startCount > 0 }
        XCTAssertTrue(started)

        _ = await hear(heardWords(lines: 0..<6), manager: manager, capture: capture, feed: feed)
        let completed = await waitUntil { state.audioSyncStatus == .cached(.whisper) }
        XCTAssertTrue(completed)
        XCTAssertNotNil(manager.diagnostics.snapshot, "final snapshot is preserved when the same track finishes")

        let trackB = TrackInfo(id: "spotify:track:second", title: "Second Song", artist: "Artist B", album: "", duration: 200, artworkURL: nil)
        cache.save(AudioSyncedLyricsRecord(
            trackId: trackB.id, engine: .whisper, syncedAt: Date(), medianOffset: 0.0,
            alignedLineCount: 6, sourceLineCount: 10, lines: tenLines()
        ))
        manager.handleTrackLoaded(track: trackB, rawLines: tenLines())
        XCTAssertNil(manager.diagnostics.snapshot, "switching to a cached track must clear the previous track's diagnostics")

        // Start live sync again on track A, then switch to track C with audio sync disabled.
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: tenLines(), forceResync: true)
        let restarted = await waitUntil { manager.isLiveSyncActive }
        XCTAssertTrue(restarted)
        XCTAssertNotNil(manager.diagnostics.snapshot)

        state.audioSyncEngine = .off
        let trackC = TrackInfo(id: "spotify:track:third", title: "Third Song", artist: "Artist C", album: "", duration: 200, artworkURL: nil)
        manager.handleTrackLoaded(track: trackC, rawLines: tenLines())
        XCTAssertNil(manager.diagnostics.snapshot, "switching to a track with sync disabled must clear previous diagnostics")
    }

    @MainActor
    func testWeakerRevisionInSameSessionDoesNotDowngradeAcceptedAlignment() async {
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let priorWords = heardWords(lines: 0..<3)
        let priorResult = LyricsAudioAligner.align(lines: tenLines(), recognizedWords: priorWords)
        XCTAssertEqual(priorResult.matchedLineCount, 3)
        cache.save(AudioSyncedLyricsRecord(
            trackId: sampleTrack().id, engine: .whisper, syncedAt: Date(), medianOffset: priorResult.medianOffset,
            alignedLineCount: 3, sourceLineCount: 10, lines: priorResult.lines, heardWords: priorWords
        ))

        let (manager, feed, capture, state) = startTenLineSync(cache: cache)
        let started = await waitUntil { manager.isLiveSyncActive && capture.startCount > 0 }
        XCTAssertTrue(started)

        // Chunk 1 adds lines 3..<5, reaching 5/10 matched lines (still partial, below 6/10).
        let fiveHeard = await hear(heardWords(lines: 3..<5), manager: manager, capture: capture, feed: feed)
        XCTAssertTrue(fiveHeard)
        XCTAssertEqual(cache.load(trackId: sampleTrack().id)?.alignedLineCount, 5)
        XCTAssertEqual(state.audioSyncStatus, .syncing(engine: .whisper, alignedLines: 5, totalLines: 10))

        // Chunk 2 hears garbled speech overlapping prior line 0, dropping the merged alignment from 5 to 4 lines.
        let garbledLine0 = [
            RecognizedAudioWord(text: "mumble", startTime: 10.0, duration: 0.4, confidence: 0.5),
            RecognizedAudioWord(text: "static", startTime: 10.6, duration: 0.4, confidence: 0.5),
        ]
        let weakerHeard = await hear(garbledLine0, manager: manager, capture: capture, feed: feed)
        XCTAssertTrue(weakerHeard)
        XCTAssertEqual(
            manager.diagnostics.snapshot?.matchedLineCount,
            4,
            "overlapping garbled words must drop merged alignment to 4 lines (still above initial cache count 3)"
        )

        // Pause triggers persistCurrentAlignmentIfReady() as well.
        manager.handlePlaybackStateChanged(isPlaying: false, position: 25.0)

        XCTAssertEqual(cache.load(trackId: sampleTrack().id)?.alignedLineCount, 5, "a weaker later revision must not overwrite the 5-line cache")
        XCTAssertEqual(state.audioSyncStatus, .syncing(engine: .whisper, alignedLines: 5, totalLines: 10))
    }

    // MARK: - #113: Unrelated speech around a single common word stays absent from displayed & cached lyrics

    @MainActor
    func testTranscriptionOverwriteSingleCommonWordAbsentFromDisplayedAndCachedLyrics() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        state.replaceLyricsWithTranscription = true
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let feed = LockedBox<[[RecognizedAudioWord]]>([])
        let deps = whisperDependencies(capture: fakeCapture, feed: feed)
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
        let mixedWords = [
            RecognizedAudioWord(text: "unrelated", startTime: 10.0, duration: 0.2, confidence: 0.95),
            RecognizedAudioWord(text: "the", startTime: 10.4, duration: 0.2, confidence: 0.95),
            RecognizedAudioWord(text: "chatter", startTime: 10.8, duration: 0.2, confidence: 0.95),
        ]
        let heard = await hear(mixedWords, manager: manager, capture: fakeCapture, feed: feed)
        XCTAssertTrue(heard)

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
        state.audioSyncEngine = .whisper
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let launches = LockedBox<[FakeWhisperEngine]>([])
        let deps = makeDependencies(
            capture: capture,
            locateWhisperServer: { "/usr/local/bin/whisper-server" },
            resolveWhisperModelPath: { _ in "/tmp/ggml-base.bin" },
            launchWhisper: { _, _ in
                let engine = FakeWhisperEngine(transcribe: { _ in [] })
                launches.withLock { $0.append(engine) }
                return engine
            }
        )
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
        XCTAssertTrue(launches.withLock { $0 }.isEmpty)
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
        XCTAssertEqual(launches.withLock { $0 }.first?.shutdownCount, 1)
    }

    // MARK: - #118: Browser handoff updates audio capture target without resetting live alignment

    @MainActor
    func testUpdateSourceBundleRetargetsLiveCaptureAndPreservesAlignedWords() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let feed = LockedBox<[[RecognizedAudioWord]]>([])
        let deps = whisperDependencies(capture: fakeCapture, feed: feed)
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)

        let chromeTrack = TrackInfo(
            id: "browser:www.youtube.com:Test Song|Test Artist|v:abc",
            title: "Test Song",
            artist: "Test Artist",
            album: "",
            duration: 180,
            artworkURL: nil,
            sourceBundleId: "com.google.Chrome"
        )
        let safariTrack = TrackInfo(
            id: "browser:www.youtube.com:Test Song|Test Artist|v:abc",
            title: "Test Song",
            artist: "Test Artist",
            album: "",
            duration: 180,
            artworkURL: nil,
            sourceBundleId: "com.apple.Safari"
        )

        manager.handleTrackLoaded(track: chromeTrack, rawLines: sampleLines())
        let chromeStarted = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount == 1 }
        XCTAssertTrue(chromeStarted)
        XCTAssertEqual(fakeCapture.lastTargetBundleIds, ["com.google.Chrome"])

        _ = await hear(
            [RecognizedAudioWord(text: "Hello", startTime: 10.5, duration: 0.3, confidence: 0.9)],
            manager: manager,
            capture: fakeCapture,
            feed: feed
        )
        let wordRecorded = manager.recognizedWords.count == 1
        XCTAssertTrue(wordRecorded)

        let callsBeforeHandoff = fakeCapture.calls.count
        manager.updateSourceBundle(for: safariTrack)
        let safariStarted = await waitUntil { fakeCapture.startCount == 2 }
        XCTAssertTrue(safariStarted)
        XCTAssertEqual(Array(fakeCapture.calls.dropFirst(callsBeforeHandoff)), ["stop", "start"])
        XCTAssertEqual(fakeCapture.lastTargetBundleIds, ["com.apple.Safari"])
        XCTAssertEqual(manager.recognizedWords.count, 1)

        manager.resyncCurrentTrack()
        let resyncStarted = await waitUntil { fakeCapture.startCount == 3 }
        XCTAssertTrue(resyncStarted)
        XCTAssertEqual(fakeCapture.lastTargetBundleIds, ["com.apple.Safari"])
    }

    @MainActor
    func testUpdateSourceBundleDuringWhisperDiscoveryUsesLatestBrowser() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()

        let discoveryStarted = expectation(description: "Whisper model discovery started")
        let releaseDiscovery = DispatchSemaphore(value: 0)
        let deps = makeDependencies(
            capture: fakeCapture,
            locateWhisperServer: { "/usr/local/bin/whisper-server" },
            resolveWhisperModelPath: { _ in
                discoveryStarted.fulfill()
                releaseDiscovery.wait()
                return "/tmp/ggml-tiny.bin"
            }
        )
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)

        let chromeTrack = TrackInfo(
            id: "browser:www.youtube.com:Test Song|Test Artist|v:abc",
            title: "Test Song",
            artist: "Test Artist",
            album: "",
            duration: 180,
            artworkURL: nil,
            sourceBundleId: "com.google.Chrome"
        )
        let safariTrack = TrackInfo(
            id: "browser:www.youtube.com:Test Song|Test Artist|v:abc",
            title: "Test Song",
            artist: "Test Artist",
            album: "",
            duration: 180,
            artworkURL: nil,
            sourceBundleId: "com.apple.Safari"
        )

        manager.handleTrackLoaded(track: chromeTrack, rawLines: sampleLines())
        await fulfillment(of: [discoveryStarted], timeout: 2.0)

        manager.updateSourceBundle(for: safariTrack)
        releaseDiscovery.signal()

        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(fakeCapture.lastTargetBundleIds, ["com.apple.Safari"])
    }

    @MainActor
    func testUpdateSourceBundleStartsNewWhisperChunkAtNewCapturePosition() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        let fakeCapture = FakeAudioCapture()
        let deps = makeDependencies(
            capture: fakeCapture,
            locateWhisperServer: { "/usr/local/bin/whisper-server" },
            resolveWhisperModelPath: { _ in "/tmp/ggml-tiny.bin" },
            whisperChunkDurationSeconds: 1.0
        )
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)

        manager.handleTrackLoaded(track: browserTrack(sourceBundleId: "com.google.Chrome"), rawLines: sampleLines())
        let chromeStarted = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount == 1 }
        XCTAssertTrue(chromeStarted)

        state.updatePlayback(isPlaying: false, position: 10.0)
        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 80), sampleRate: 100)
        let chromeBuffered = await waitUntil { manager.bufferedWhisperSampleCount == 80 }
        XCTAssertTrue(chromeBuffered)
        XCTAssertEqual(manager.currentWhisperChunkStartPos, 10.0)

        state.updatePlayback(isPlaying: false, position: 24.0)
        manager.updateSourceBundle(for: browserTrack(sourceBundleId: "com.apple.Safari"))
        XCTAssertEqual(manager.bufferedWhisperSampleCount, 0)
        XCTAssertNil(manager.currentWhisperChunkStartPos)

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 30), sampleRate: 100)
        let safariBuffered = await waitUntil { manager.bufferedWhisperSampleCount == 30 }
        XCTAssertTrue(safariBuffered)
        XCTAssertEqual(manager.currentWhisperChunkStartPos, 24.0)
    }

    @MainActor
    func testUpdateSourceBundleDropsQueuedSamplesFromPreviousCapture() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let fakeCapture = FakeAudioCapture()
        let recordedRequests = LockedBox<[AudioSyncManager.WhisperChunkRequest]>([])
        let chunkDispatched = expectation(description: "Post-retarget Whisper chunk dispatched")
        let deps = makeDependencies(
            capture: fakeCapture,
            locateWhisperServer: { "/usr/local/bin/whisper-server" },
            resolveWhisperModelPath: { _ in "/tmp/ggml-tiny.bin" },
            runWhisperChunk: { request in
                recordedRequests.withLock { $0.append(request) }
                chunkDispatched.fulfill()
                return []
            },
            whisperChunkDurationSeconds: 1.0
        )
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)

        manager.handleTrackLoaded(track: browserTrack(sourceBundleId: "com.google.Chrome"), rawLines: sampleLines())
        let chromeStarted = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount == 1 }
        XCTAssertTrue(chromeStarted)

        // Chrome audio captured but still queued for main-actor delivery when the handoff lands.
        fakeCapture.emit(samples: [Float](repeating: 0.2, count: 30), sampleRate: 100.0)
        manager.updateSourceBundle(for: browserTrack(sourceBundleId: "com.apple.Safari"))
        fakeCapture.emit(samples: [Float](repeating: 0.95, count: 100), sampleRate: 100.0)
        await fulfillment(of: [chunkDispatched], timeout: 2.0)

        let requests = recordedRequests.withLock { $0 }
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests.first?.samples.allSatisfy { abs($0 - 0.95) < 0.001 } ?? false)
    }

    @MainActor
    func testChunkStartIsBackdatedByTheBufferCaptureDelay() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        state.playbackAnchorPosition = 50.0
        state.playbackAnchorDate = Date()
        state.isPlaying = true
        let fakeCapture = FakeAudioCapture()
        let deps = whisperDependencies(capture: fakeCapture, feed: LockedBox([]))
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)

        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount == 1 }
        XCTAssertTrue(started)

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 30), sampleRate: 100, captureDelay: 0.4)
        let buffered = await waitUntil { manager.bufferedWhisperSampleCount == 30 }
        XCTAssertTrue(buffered)
        // Audio captured 0.4 s before delivery was played 0.4 s earlier in the track.
        XCTAssertEqual(manager.currentWhisperChunkStartPos ?? -1, 49.6, accuracy: 0.1)
        XCTAssertEqual(manager.vocalEnvelope.segments.first?.start ?? -1, 49.6, accuracy: 0.1)
    }

    @MainActor
    func testAlignedWordsFollowTheCapturedVocalWaveform() async throws {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let fakeCapture = FakeAudioCapture()
        let words = ["Hello", "world", "from", "test"].enumerated().map {
            RecognizedAudioWord(text: $0.element, startTime: 10.0 + Double($0.offset) * 0.3, duration: 0.2, confidence: 0.9)
        } + ["Second", "line", "of", "lyrics"].enumerated().map {
            RecognizedAudioWord(text: $0.element, startTime: 15.0 + Double($0.offset) * 0.3, duration: 0.2, confidence: 0.9)
        }
        let feed = LockedBox<[[RecognizedAudioWord]]>([words])
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let deps = makeDependencies(
            capture: fakeCapture,
            locateWhisperServer: { "/usr/local/bin/whisper-server" },
            resolveWhisperModelPath: { _ in "/tmp/ggml-base.bin" },
            runWhisperChunk: { _ in feed.withLock { $0.isEmpty ? [] : $0.removeFirst() } },
            whisperChunkDurationSeconds: 6.0
        )
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        // One 6 s chunk: a note sung from 10 s to 12 s, then 4 s of silence.
        let rate = 16000
        let note = (0..<(2 * rate)).map { 0.5 * sin(2 * Float.pi * 440 * Float($0) / Float(rate)) }
        let audio = note + [Float](repeating: 0, count: 4 * rate)
        for second in 0..<6 {
            fakeCapture.emit(samples: Array(audio[(second * rate)..<((second + 1) * rate)]), sampleRate: Double(rate))
        }
        let saved = await waitUntil(timeout: 5) { cache.load(trackId: self.sampleTrack().id) != nil }
        XCTAssertTrue(saved)

        let record = try XCTUnwrap(cache.load(trackId: sampleTrack().id))
        let last = try XCTUnwrap(record.lines.first?.words.last)
        XCTAssertEqual(last.timestamp + (last.duration ?? 0), 12.0, accuracy: 0.05, "the last word holds the note to its end")
        XCTAssertEqual(record.alignedLineCount, 1, "the line heard in silence is not aligned")
    }

    func testPlaybackPositionAtCaptureTimeFollowsRate() {
        XCTAssertEqual(AudioSyncManager.playbackPosition(20, capturedAt: 9.5, now: 10, rate: 2), 19, accuracy: 1e-9)
        XCTAssertEqual(AudioSyncManager.playbackPosition(20, capturedAt: 9.5, now: 10, rate: 0), 20, accuracy: 1e-9)
    }

    func testCaptureDelayRejectsImplausibleTimestamps() {
        XCTAssertEqual(AudioSampleExtractor.captureDelay(presentation: 99.88, hostNow: 100) ?? -1, 0.12, accuracy: 1e-9)
        XCTAssertNil(AudioSampleExtractor.captureDelay(presentation: 101, hostNow: 100))
        XCTAssertNil(AudioSampleExtractor.captureDelay(presentation: 3, hostNow: 100))
    }

    func testMidSideSplitsStereoAndPassesMonoThrough() {
        let stereo = AudioSampleExtractor.midSide(channels: [[1, 0.5], [0, 0.5]])
        XCTAssertEqual(stereo.mid, [0.5, 0.5])
        XCTAssertEqual(stereo.side, [0.5, 0])
        let mono = AudioSampleExtractor.midSide(channels: [[0.3, 0.2]])
        XCTAssertEqual(mono.mid, [0.3, 0.2])
        XCTAssertEqual(mono.side, [])
        XCTAssertEqual(AudioSampleExtractor.deinterleave([1, 2, 3, 4, 5, 6], channelCount: 2), [[1, 3, 5], [2, 4, 6]])
    }

    @MainActor
    func testFailedRetargetCaptureTearsDownRecognitionSession() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .whisper
        let fakeCapture = FakeAudioCapture()
        let engine = FakeWhisperEngine(transcribe: { _ in [] })
        let deps = whisperDependencies(capture: fakeCapture, feed: LockedBox([]), launchWhisper: { _, _ in engine })
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)

        manager.handleTrackLoaded(track: browserTrack(sourceBundleId: "com.google.Chrome"), rawLines: sampleLines())
        let chromeStarted = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount == 1 }
        XCTAssertTrue(chromeStarted)

        fakeCapture.startError = FakeCaptureError()
        manager.updateSourceBundle(for: browserTrack(sourceBundleId: "com.apple.Safari"))
        let failed = await waitUntil { fakeCapture.startCount == 2 && !manager.isLiveSyncActive }
        XCTAssertTrue(failed)

        XCTAssertEqual(engine.shutdownCount, 1, "A failed replacement capture must end the recognition session")
        XCTAssertNil(fakeCapture.onAudioSamples)
        if case .permissionRequired = state.audioSyncStatus {} else {
            XCTFail("Expected the capture failure to be reported, got \(state.audioSyncStatus)")
        }
    }

    // MARK: - Helpers

    private func browserTrack(sourceBundleId: String) -> TrackInfo {
        TrackInfo(
            id: "browser:www.youtube.com:Test Song|Test Artist|v:abc",
            title: "Test Song",
            artist: "Test Artist",
            album: "",
            duration: 180,
            artworkURL: nil,
            sourceBundleId: sourceBundleId
        )
    }

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

    private func threeLines() -> [LyricLine] {
        [
            LyricLine(id: 0, timestamp: 10.0, text: "Alpha beta"),
            LyricLine(id: 1, timestamp: 15.0, text: "Gamma delta"),
            LyricLine(id: 2, timestamp: 20.0, text: "Epsilon zeta"),
        ]
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
            locateWhisperServer: locateWhisperServer,
            resolveWhisperModelPath: resolveWhisperModelPath,
            launchWhisper: launchWhisper ?? { _, _ in FakeWhisperEngine(transcribe: runWhisperChunk) },
            whisperChunkDurationSeconds: whisperChunkDurationSeconds
        )
    }
}

private final class FakeAudioCapture: AudioCaptureProviding {
    var onAudioSamples: ((CapturedAudio) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var lastTargetBundleIds: Set<String> = []
    private(set) var calls: [String] = []
    var startError: Error?

    @MainActor
    func start(targetBundleIds: Set<String>) throws {
        startCount += 1
        calls.append("start")
        lastTargetBundleIds = targetBundleIds
        if let startError {
            throw startError
        }
    }

    @MainActor
    func stop() {
        stopCount += 1
        calls.append("stop")
    }

    func emit(samples: [Float], sampleRate: Double, side: [Float] = [], captureDelay: Double? = nil) {
        onAudioSamples?(CapturedAudio(samples: samples, side: side, sampleRate: sampleRate, captureDelay: captureDelay))
    }
}

private struct FakeCaptureError: Error {}

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

private final class FakeAttemptingEngine: WhisperTranscribing, LineAttemptReporting, @unchecked Sendable {
    private let words: [RecognizedAudioWord]
    private let attempted: Set<Int>
    private let calls = LockedBox<Int>(0)

    init(words: [RecognizedAudioWord], attempted: Set<Int>) {
        self.words = words
        self.attempted = attempted
    }

    var attemptedLineIDs: Set<Int> { calls.withLock { $0 } > 0 ? attempted : [] }

    // swiftlint:disable:next async_without_await
    func transcribe(_: AudioSyncManager.WhisperChunkRequest) async -> [RecognizedAudioWord] {
        calls.withLock { $0 += 1 }
        return words
    }

    func shutdown() {}
}
