import AVFoundation
@testable import BarTune
import Combine
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

    // MARK: - #64: Engine lifecycle & unbounded sample buffer

    @MainActor
    func testAlignerSessionLaunchesModelOnceAndShutsItDownOnStop() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let launches = LockedBox<Int>(0)
        let chunks = LockedBox<Int>(0)
        let engine = FakeChunkEngine { _ in
            chunks.withLock { $0 += 1 }
            return []
        }

        let deps = makeDependencies(
            capture: fakeCapture,
            launchAligner: { _, _ in
                launches.withLock { $0 += 1 }
                return engine
            },
            chunkDurationSeconds: 1.0
        )
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        for expected in 1...3 {
            fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
            let processed = await waitUntil { chunks.withLock { $0 } == expected && !manager.isChunkProcessing }
            XCTAssertTrue(processed, "chunk \(expected) was not transcribed")
        }

        XCTAssertEqual(launches.withLock { $0 }, 1, "The model must load once per session, not once per chunk")
        XCTAssertEqual(engine.shutdownCount, 0)

        manager.stop()
        XCTAssertEqual(engine.shutdownCount, 1)
    }

    @MainActor
    func testAlignerSessionStopsWhenEngineThrows() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let launches = LockedBox<Int>(0)
        let engine = FakeChunkEngine { _ in throw FakeChunkEngineError.exited }
        let freshChunks = LockedBox<Int>(0)
        let freshEngine = FakeChunkEngine { _ in
            freshChunks.withLock { $0 += 1 }
            return []
        }

        let deps = makeDependencies(
            capture: fakeCapture,
            launchAligner: { _, _ in
                let count = launches.withLock { value -> Int in
                    value += 1
                    return value
                }
                return count == 1 ? engine : freshEngine
            },
            chunkDurationSeconds: 1.0
        )
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)
        let stopsBeforeFailure = fakeCapture.stopCount

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let stopped = await waitUntil { !manager.isLiveSyncActive }
        XCTAssertTrue(stopped, "A failed aligner must end the session instead of listening forever")
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
        let transcribed = await waitUntil { freshChunks.withLock { $0 } == 1 && !manager.isChunkProcessing }
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
    func testAudioChunksAreRaisedToRecognitionLevel() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let fakeCapture = FakeAudioCapture()
        let peaks = LockedBox<[Float]>([])
        let deps = makeDependencies(
            capture: fakeCapture,
            runChunk: { request in
                peaks.withLock { $0.append(request.samples.map { abs($0) }.max() ?? 0) }
                return []
            },
            chunkDurationSeconds: 1.0
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
    func testLyricsAlignmentAppliesAlignedWords() async {
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
            chunkDurationSeconds: 1.0,
            launchLyricsAligner: { lines, _ in
                launchedWith.withLock { $0 = lines.map(\.text) }
                return FakeChunkEngine { _ in aligned }
            }
        )
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started, "capture starts when aligner launches")
        XCTAssertEqual(launchedWith.withLock { $0 }, sampleLines().map(\.text))

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let synced = await waitUntil { state.audioSyncStatus != .syncing(engine: .lyricsAlignment, alignedLines: 0, totalLines: 2) }

        XCTAssertTrue(synced)
        XCTAssertEqual(state.audioSyncStatus, .syncing(engine: .lyricsAlignment, alignedLines: 1, totalLines: 2))
        XCTAssertEqual(state.rawLyricLines.first?.timestamp ?? 0, 11.0, accuracy: 0.01)
    }

    @MainActor
    func testLyricsAlignmentTimesBySyllableWhenTheSettingIsOn() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.syllableTiming = true
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let fakeCapture = FakeAudioCapture()
        let aligned = [
            RecognizedAudioWord(text: "Hello", startTime: 11.0, duration: 0.6, confidence: 0.5, syllables: [
                .init(text: "Hel", startTime: 11.0), .init(text: "lo", startTime: 11.3),
            ]),
        ] + ["world", "from", "test"].enumerated().map { index, word in
            RecognizedAudioWord(text: word, startTime: 11.7 + Double(index) * 0.5, duration: 0.4, confidence: 0.5)
        }
        var deps = makeDependencies(capture: fakeCapture)
        deps.chunkDurationSeconds = 1.0
        deps.launchLyricsAligner = { _, _ in FakeChunkEngine { _ in aligned } }
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let synced = await waitUntil { !(state.rawLyricLines.first?.words.isEmpty ?? true) }

        XCTAssertTrue(synced)
        XCTAssertEqual(state.rawLyricLines.first?.words.map(\.text), ["Hel", "lo ", "world ", "from ", "test"])
        XCTAssertEqual(state.rawLyricLines.first?.words[1].timestamp ?? 0, 11.3, accuracy: 0.001)
    }

    @MainActor
    func testSyllableTimingIsOffByDefaultAndPersists() {
        let state = LyricsState(userDefaults: defaults)
        XCTAssertFalse(state.syllableTiming)
        state.syllableTiming = true
        XCTAssertTrue(LyricsState(userDefaults: defaults).syllableTiming)
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
            alignedLineCount: 2, sourceLineCount: 3, lines: saved, lockedLineIDs: [0, 1]
        ))
        let anchorsSeen = LockedBox<[Int: ClosedRange<Double>]>([:])
        let lineTwo = ["Epsilon", "zeta"].enumerated().map { index, word in
            RecognizedAudioWord(text: word, startTime: 21.2 + Double(index) * 0.5, duration: 0.4, confidence: 0.5)
        }
        let fakeCapture = FakeAudioCapture()
        var deps = makeDependencies(capture: fakeCapture)
        deps.chunkDurationSeconds = 1.0
        deps.launchLyricsAligner = { _, anchors in
            anchorsSeen.withLock { $0 = anchors }
            return FakeChunkEngine { _ in lineTwo }
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
        deps.chunkDurationSeconds = 1.0
        deps.launchLyricsAligner = { _, _ in FakeChunkEngine { _ in words } }
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
    func testLyricsAlignmentListensAgainForALineItHeardButCouldNotAlign() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        // The play covers every line, but only two align.
        let words = ["Alpha", "beta", "Gamma", "delta"].enumerated().map { index, word in
            RecognizedAudioWord(text: word, startTime: [10.7, 11.1, 15.7, 16.1][index], duration: 0.3, confidence: 0.5)
        }
        let launches = LockedBox<[Set<Int>]>([])
        let fakeCapture = FakeAudioCapture()
        var deps = makeDependencies(capture: fakeCapture)
        deps.chunkDurationSeconds = 1.0
        deps.launchLyricsAligner = { _, anchors in
            launches.withLock { $0.append(Set(anchors.keys)) }
            return FakeChunkEngine { _ in words }
        }
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: threeLines())
        _ = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let saved = await waitUntil { cache.load(trackId: self.sampleTrack().id)?.alignedLineCount == 2 }
        XCTAssertTrue(saved)
        XCTAssertEqual(state.audioSyncStatus, .syncing(engine: .lyricsAlignment, alignedLines: 2, totalLines: 3))

        manager.handleTrackLoaded(track: sampleTrack(), rawLines: threeLines())
        let relaunched = await waitUntil { launches.withLock { $0.count } == 2 }
        XCTAssertTrue(relaunched, "the next play listens again for the line that did not align")
        XCTAssertEqual(launches.withLock { $0.last }, [0, 1], "the aligned lines are kept as they are")
    }

    @MainActor
    func testLyricsAlignmentShowsAnUnconfidentLineButDoesNotLockIt() async throws {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let words = ["Alpha", "beta", "Gamma", "delta"].enumerated().map { index, word in
            RecognizedAudioWord(text: word, startTime: [10.7, 11.1, 15.7, 16.1][index], duration: 0.3, confidence: 0.5)
        }
        let anchorsSeen = LockedBox<[Set<Int>]>([])
        let fakeCapture = FakeAudioCapture()
        var deps = makeDependencies(capture: fakeCapture)
        deps.chunkDurationSeconds = 1.0
        deps.launchLyricsAligner = { _, anchors in
            anchorsSeen.withLock { $0.append(Set(anchors.keys)) }
            return FakeChunkEngine(confident: [0]) { _ in words }
        }
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: threeLines())
        _ = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let saved = await waitUntil { cache.load(trackId: self.sampleTrack().id)?.lockedLineIDs == [0] }
        XCTAssertTrue(saved)
        let record = try XCTUnwrap(cache.load(trackId: sampleTrack().id))
        XCTAssertEqual(record.lines[1].words.first?.timestamp, 15.7, "line 1's alignment is shown")

        manager.handleTrackLoaded(track: sampleTrack(), rawLines: threeLines())
        let relaunched = await waitUntil { anchorsSeen.withLock { $0.count } == 2 }
        XCTAssertTrue(relaunched)
        XCTAssertEqual(anchorsSeen.withLock { $0.last }, [0], "only the locked line is kept as it is")
    }

    /// Results after one 7 s chunk from 10 s where line 1 ("Gamma delta", from 15.7 s) is nearly
    /// confident and the sound comes in at `soundStart`.
    @MainActor
    private func nearlyConfidentLineResult(
        soundStart: Double,
        percussive: Bool = false,
        wideTone: Bool = false,
        tailNoiseStart: Double? = nil
    ) async throws -> (locks: [Int], voicedPercent: Float?, pitchFrames: Int, onsetRise: Float?, trimmed: Int, lastWordEnd: Double?, report: String) {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let words = ["Alpha", "beta", "Gamma", "delta"].enumerated().map { index, word in
            RecognizedAudioWord(text: word, startTime: [10.7, 11.1, 15.7, 16.1][index], duration: 0.3, confidence: 0.1)
        }
        let fakeCapture = FakeAudioCapture()
        var deps = makeDependencies(capture: fakeCapture, chunkDurationSeconds: 7.0)
        deps.launchLyricsAligner = { _, _ in
            FakeChunkEngine(confident: [], nearlyConfident: [1]) { _ in
                XCTAssertFalse(Thread.isMainThread)
                return words
            }
        }
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        defer { manager.stop() }
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: threeLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        let rate = 16000
        var noiseState: UInt32 = 0x1234_5678
        let audio = (0..<(7 * rate)).map { index -> Float in
            let time = 10.0 + Double(index) / Double(rate)
            let amplitude: Float = time >= soundStart ? 0.5 : 0.005
            if percussive || (tailNoiseStart.map { time >= $0 } ?? false) {
                noiseState = noiseState &* 1_664_525 &+ 1_013_904_223
                return amplitude * (Float(noiseState >> 8) / Float(1 << 23) - 1)
            }
            return amplitude * sin(2 * Float.pi * 440 * Float(index) / Float(rate))
        }
        for second in 0..<7 {
            let samples = Array(audio[(second * rate)..<((second + 1) * rate)])
            fakeCapture.emit(samples: samples, sampleRate: Double(rate), side: wideTone ? samples : [])
        }
        let processed = await waitUntil(timeout: 5) {
            cache.load(trackId: self.sampleTrack().id) != nil && manager.diagnostics.snapshot?.voicedFramePercent != nil
        }
        XCTAssertTrue(processed)
        let record = try XCTUnwrap(cache.load(trackId: sampleTrack().id))
        return (
            locks: record.lockedLineIDs?.sorted() ?? [],
            voicedPercent: manager.diagnostics.snapshot?.voicedFramePercent,
            pitchFrames: manager.vocalPitchContour.segments.reduce(0) { $0 + $1.f0Hz.count },
            onsetRise: manager.vocalEnvelope.onsetRise(at: 15.7),
            trimmed: manager.diagnostics.snapshot?.waveformRefinement?.harmonicityTrimmed ?? 0,
            lastWordEnd: record.lines[1].words.last.map { $0.timestamp + ($0.duration ?? 0) },
            report: manager.diagnostics.snapshot?.report() ?? ""
        )
    }

    @MainActor
    func testLyricsAlignmentLocksANearlyConfidentLineThatStartsOnAVocalOnset() async throws {
        let result = try await nearlyConfidentLineResult(soundStart: 15.7)
        XCTAssertEqual(result.locks, [1])
        XCTAssertGreaterThan(result.pitchFrames, 0)
        XCTAssertGreaterThan(result.voicedPercent ?? 0, 0)
    }

    @MainActor
    func testLyricsAlignmentDoesNotLockANearlyConfidentLineInsideAHeldNote() async throws {
        let result = try await nearlyConfidentLineResult(soundStart: 10.0)
        XCTAssertEqual(result.locks, [])
    }

    @MainActor
    func testLyricsAlignmentDoesNotLockPercussiveOnsetAsSinging() async throws {
        let result = try await nearlyConfidentLineResult(soundStart: 15.7, percussive: true)
        XCTAssertGreaterThan(result.onsetRise ?? 0, AudioSyncManager.onsetLockRise)
        XCTAssertGreaterThan(result.pitchFrames, 0)
        XCTAssertEqual(result.locks, [])
    }

    @MainActor
    func testBackgroundPitchSuppressesWideStereoTone() async throws {
        let result = try await nearlyConfidentLineResult(soundStart: 15.7, wideTone: true)
        XCTAssertGreaterThan(result.onsetRise ?? 0, AudioSyncManager.onsetLockRise)
        XCTAssertEqual(result.pitchFrames, 700)
        XCTAssertEqual(try XCTUnwrap(result.voicedPercent), 0, accuracy: 0.001)
        XCTAssertEqual(result.locks, [])
    }

    @MainActor
    func testLivePitchTrimsHeldTailWhenLoudNoiseFollowsVowel() async throws {
        let result = try await nearlyConfidentLineResult(soundStart: 15.7, tailNoiseStart: 16.55)
        XCTAssertEqual(result.locks, [1])
        XCTAssertGreaterThan(result.trimmed, 0)
        XCTAssertLessThan(try XCTUnwrap(result.lastWordEnd), 16.7)
        XCTAssertTrue(result.report.contains("Held notes trimmed by harmonicity:"))
        XCTAssertTrue(result.report.contains("Voiced frames:"))
    }

    func testNearlyConfidentLockRequiresVoicingAtLoudOnset() {
        let rate = 16000
        let audio = (0..<(2 * rate)).map { index -> Float in
            let amplitude: Float = index >= rate ? 0.5 : 0.005
            return amplitude * sin(2 * Float.pi * 440 * Float(index) / Float(rate))
        }
        var envelope = VocalEnvelope()
        envelope.append(mid: audio, side: [], sampleRate: Double(rate), startTime: 0, rate: 1)
        XCTAssertGreaterThan(envelope.onsetRise(at: 1) ?? 0, AudioSyncManager.onsetLockRise)

        let line = LyricLine(id: 1, timestamp: 1, duration: 0.8, text: "Gamma delta", words: [
            WordTimestamp(timestamp: 1, duration: 0.35, text: "Gamma "),
            WordTimestamp(timestamp: 1.4, duration: 0.4, text: "delta"),
        ])
        var pitch = VocalPitchContour()
        pitch.merge(.init(start: 0, step: 0.01, f0Hz: [Float](repeating: 0, count: 200), harmonicity: [Float](repeating: 0.1, count: 200)))
        XCTAssertFalse(AudioSyncManager.locks(line, confident: [], nearlyConfident: [1], envelope: envelope, pitchContour: pitch))

        XCTAssertTrue(AudioSyncManager.locks(line, confident: [1], nearlyConfident: [], envelope: envelope, pitchContour: pitch))

        pitch = VocalPitchContour()
        pitch.merge(.init(
            start: 0, step: 0.01,
            f0Hz: [Float](repeating: 0, count: 100) + [Float](repeating: 440, count: 100),
            harmonicity: [Float](repeating: 0.1, count: 100) + [Float](repeating: 0.9, count: 100)
        ))
        XCTAssertTrue(AudioSyncManager.locks(line, confident: [], nearlyConfident: [1], envelope: envelope, pitchContour: pitch))

        let steadyAudio = audio.indices.map { index in Float(0.5) * sin(2 * Float.pi * 440 * Float(index) / Float(rate)) }
        var steadyEnvelope = VocalEnvelope()
        steadyEnvelope.append(mid: steadyAudio, side: [], sampleRate: Double(rate), startTime: 0, rate: 1)
        XCTAssertLessThan(abs(steadyEnvelope.onsetRise(at: 1) ?? .infinity), AudioSyncManager.onsetLockRise)
        XCTAssertTrue(AudioSyncManager.locks(line, confident: [], nearlyConfident: [1], envelope: steadyEnvelope, pitchContour: pitch))
    }

    func testLyricsAlignmentDoesNotLockRunawayWordTiming() {
        let envelope = VocalEnvelope()
        let longWord = LyricLine(id: 1, timestamp: 10, duration: 5.1, text: "Stay with me", words: [
            WordTimestamp(timestamp: 10, duration: 0.4, text: "Stay "),
            WordTimestamp(timestamp: 10.5, duration: 4.2, text: "with "),
            WordTimestamp(timestamp: 14.8, duration: 0.3, text: "me"),
        ])
        let longGap = LyricLine(id: 2, timestamp: 10, duration: 8, text: "Stay with me", words: [
            WordTimestamp(timestamp: 10, duration: 0.4, text: "Stay "),
            WordTimestamp(timestamp: 14.5, duration: 0.3, text: "with "),
            WordTimestamp(timestamp: 15, duration: 0.3, text: "me"),
        ])
        let stretchedLine = LyricLine(id: 4, timestamp: 10, duration: 9, text: "Stay with me", words: [
            WordTimestamp(timestamp: 10, duration: 3.2, text: "Stay "),
            WordTimestamp(timestamp: 13.3, duration: 3.2, text: "with "),
            WordTimestamp(timestamp: 16.6, duration: 2.4, text: "me"),
        ])
        let ordinary = LyricLine(id: 3, timestamp: 10, duration: 1.5, text: "Stay with me", words: [
            WordTimestamp(timestamp: 10, duration: 0.4, text: "Stay "),
            WordTimestamp(timestamp: 10.5, duration: 0.4, text: "with "),
            WordTimestamp(timestamp: 11, duration: 0.4, text: "me"),
        ])

        XCTAssertFalse(AudioSyncManager.locks(longWord, confident: [1], nearlyConfident: [], envelope: envelope))
        XCTAssertFalse(AudioSyncManager.locks(longGap, confident: [2], nearlyConfident: [], envelope: envelope))
        XCTAssertFalse(AudioSyncManager.locks(stretchedLine, confident: [4], nearlyConfident: [], envelope: envelope))
        XCTAssertTrue(AudioSyncManager.locks(ordinary, confident: [3], nearlyConfident: [], envelope: envelope))
    }

    func testLeadAnchorsExcludeBackingVocalsWhenTimedWordsOmitWhitespace() {
        let line = LyricLine(id: 1, timestamp: 10, text: "(ooh yeah) ka", words: [
            WordTimestamp(timestamp: 10, duration: 0.5, text: "(ooh"),
            WordTimestamp(timestamp: 10.5, duration: 0.5, text: "yeah)"),
            WordTimestamp(timestamp: 11, duration: 0.5, text: "ka"),
        ])

        XCTAssertNil(LyricsAudioAligner.tokenGroups(of: line))
        XCTAssertEqual(AudioSyncManager.sungSpan(of: line), 11...11.5)
        XCTAssertEqual(AudioSyncManager.recognizedWords(of: [line]).map(\.text), ["ka"])

        let allSung = LyricLine(id: 2, timestamp: 10, text: "(ooh yeah)", words: Array(line.words.prefix(2)))
        XCTAssertEqual(AudioSyncManager.recognizedWords(of: [allSung]).map(\.text), ["(ooh", "yeah)"])
        let ordinary = LyricLine(id: 3, timestamp: 10, text: "sing out", words: [
            WordTimestamp(timestamp: 10, duration: 0.5, text: "sing"),
            WordTimestamp(timestamp: 10.5, duration: 0.5, text: "out"),
        ])
        XCTAssertEqual(AudioSyncManager.recognizedWords(of: [ordinary]).map(\.text), ["sing", "out"])
    }

    func testLyricsAlignmentLocksALeadLineWithALongBackingVocalTail() throws {
        let line = LyricLine(id: 1, timestamp: 10, text: "ka (one two three four five six seven eight nine ten eleven)")
        let heard = RecognizedAudioWord(text: "ka", startTime: 10, duration: 0.5, confidence: 1, sourceLineId: line.id)
        let result = LyricsAudioAligner.align(lines: [line], recognizedWords: [heard], regroupsCJKWords: false)
        let aligned = try XCTUnwrap(result.lines.first)

        XCTAssertEqual(result.matchedLineIDs, [line.id])
        let leadEnd = try XCTUnwrap(AudioSyncManager.sungSpan(of: aligned)).upperBound
        let duration = try XCTUnwrap(aligned.duration)
        XCTAssertGreaterThan(aligned.timestamp + duration - leadEnd, LyricsForcedAligner.maxWordSpan)
        XCTAssertTrue(AudioSyncManager.locks(aligned, confident: [line.id], nearlyConfident: [], envelope: VocalEnvelope()))

        let extended = LyricLine(
            id: line.id, timestamp: aligned.timestamp, duration: duration + 4, text: aligned.text, words: aligned.words
        )
        XCTAssertFalse(AudioSyncManager.locks(extended, confident: [line.id], nearlyConfident: [], envelope: VocalEnvelope()))
    }

    func testLyricsAlignmentDoesNotLockAnOverlongTrailingTail() {
        let line = LyricLine(id: 1, timestamp: 10, duration: 4.2, text: "Stay", words: [
            WordTimestamp(timestamp: 10, duration: 0.5, text: "Stay"),
        ])

        XCTAssertFalse(AudioSyncManager.locks(line, confident: [1], nearlyConfident: [], envelope: VocalEnvelope()))
    }

    func testLyricsAlignmentRegroupsSyllablesBeforeCheckingWordDuration() {
        let line = LyricLine(id: 1, timestamp: 10, duration: 4, text: "Away", words: [
            WordTimestamp(timestamp: 10, duration: 2, text: "A"),
            WordTimestamp(timestamp: 12, duration: 2, text: "way"),
        ])

        XCTAssertFalse(AudioSyncManager.locks(line, confident: [1], nearlyConfident: [], envelope: VocalEnvelope()))
    }

    func testLyricsAlignmentCountsWordsWhenBoundingASyllableTimedLine() {
        let line = LyricLine(id: 1, timestamp: 10, duration: 6.4, text: "Never ending", words: [
            WordTimestamp(timestamp: 10, duration: 1.4, text: "Nev"),
            WordTimestamp(timestamp: 11.4, duration: 1.4, text: "er "),
            WordTimestamp(timestamp: 13.6, duration: 1.4, text: "end"),
            WordTimestamp(timestamp: 15, duration: 1.4, text: "ing"),
        ])

        XCTAssertFalse(AudioSyncManager.locks(line, confident: [1], nearlyConfident: [], envelope: VocalEnvelope()))
    }

    func testLyricsAlignmentRejectsAStretchedFiveWordLineAndAllowsASlowLine() {
        func line(endingAt end: Double) -> LyricLine {
            LyricLine(id: 1, timestamp: 10, duration: end - 10, text: "Stay with me all night", words: [
                WordTimestamp(timestamp: 10, duration: 1.5, text: "Stay "),
                WordTimestamp(timestamp: 12, duration: 1.5, text: "with "),
                WordTimestamp(timestamp: 14, duration: 1.5, text: "me "),
                WordTimestamp(timestamp: 16, duration: 0.5, text: "all "),
                WordTimestamp(timestamp: 17, duration: end - 17, text: "night"),
            ])
        }
        let envelope = VocalEnvelope()

        XCTAssertFalse(AudioSyncManager.locks(line(endingAt: 18.93), confident: [1], nearlyConfident: [], envelope: envelope))
        XCTAssertTrue(AudioSyncManager.locks(line(endingAt: 18.4), confident: [1], nearlyConfident: [], envelope: envelope))
    }

    @MainActor
    func testLyricsAlignmentDoesNotLockAClampedRunawayLine() async throws {
        let track = sampleTrack()
        let source = [
            LyricLine(id: 0, timestamp: 10, text: "Stay with me"),
            LyricLine(id: 1, timestamp: 12, text: "Next line"),
        ]
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10
        state.playbackAnchorDate = Date()
        let words = [
            RecognizedAudioWord(text: "Stay", startTime: 10, duration: 0.7, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "with", startTime: 12.5, duration: 0.5, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "me", startTime: 15, duration: 0.5, confidence: 0.9, sourceLineId: 0),
        ]
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let capture = FakeAudioCapture()
        var deps = makeDependencies(capture: capture, chunkDurationSeconds: 1)
        deps.launchLyricsAligner = { _, _ in FakeChunkEngine(confident: [0]) { _ in words } }
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        defer { manager.stop() }
        manager.handleTrackLoaded(track: track, rawLines: source)
        let started = await waitUntil { manager.isLiveSyncActive && capture.startCount > 0 }
        XCTAssertTrue(started)

        capture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let saved = await waitUntil { cache.load(trackId: track.id) != nil }
        XCTAssertTrue(saved)
        let record = try XCTUnwrap(cache.load(trackId: track.id))
        XCTAssertEqual(record.lines[0].words.suffix(2).map(\.duration), [0, 0])
        XCTAssertEqual(record.lockedLineIDs, [])
    }

    @MainActor
    func testReplayClearsRejectedUnlockedLineAndKeepsUnattemptedAndLockedLines() async throws {
        let track = sampleTrack()
        let source = threeLines() + [LyricLine(id: 3, timestamp: 25, text: "Eta theta")]
        let locked = LyricLine(id: 0, timestamp: 10.7, duration: 0.7, text: "Alpha beta", words: [
            WordTimestamp(timestamp: 10.7, duration: 0.3, text: "Alpha "),
            WordTimestamp(timestamp: 11.1, duration: 0.3, text: "beta"),
        ])
        let rejected = LyricLine(id: 1, timestamp: 15.7, duration: 0.7, text: "Gamma delta", words: [
            WordTimestamp(timestamp: 15.7, duration: 0.3, text: "Gamma "),
            WordTimestamp(timestamp: 16.1, duration: 0.3, text: "delta"),
        ])
        let unattempted = LyricLine(id: 2, timestamp: 20.7, duration: 0.7, text: "Epsilon zeta", words: [
            WordTimestamp(timestamp: 20.7, duration: 0.3, text: "Epsilon "),
            WordTimestamp(timestamp: 21.1, duration: 0.3, text: "zeta"),
        ])
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        cache.save(AudioSyncedLyricsRecord(
            trackId: track.id, engine: .lyricsAlignment, syncedAt: Date(), medianOffset: 0.7,
            alignedLineCount: 3, sourceLineCount: 4, lines: [locked, rejected, unattempted, source[3]],
            lockedLineIDs: [0], attemptedLineIDs: [2], lockedAtPlayStart: 1
        ))
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 15
        state.playbackAnchorDate = Date()
        let fakeCapture = FakeAudioCapture()
        var deps = makeDependencies(capture: fakeCapture)
        deps.chunkDurationSeconds = 1
        deps.launchLyricsAligner = { _, _ in
            FakeChunkEngine(attempted: [1], confident: []) { _ in [] }
        }
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: track, rawLines: source)
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let cleared = await waitUntil { cache.load(trackId: track.id)?.lines[1].words.isEmpty == true }
        XCTAssertTrue(cleared)
        let saved = try XCTUnwrap(cache.load(trackId: track.id))
        XCTAssertEqual(saved.lockedLineIDs, [0])
        XCTAssertEqual(saved.lines[0].words, locked.words)
        XCTAssertEqual(saved.lines[1].timestamp, source[1].timestamp)
        XCTAssertEqual(saved.lines[2].words, unattempted.words)
        XCTAssertEqual(saved.attemptedLineIDs, [1, 2])
        XCTAssertEqual(saved.alignedLineCount, 2)
        manager.stop()
    }

    @MainActor
    func testReplayRestoresTheOnlySavedLockAfterRejectingAnUnlockedLine() async throws {
        let track = sampleTrack()
        let source = threeLines()
        let locked = LyricLine(id: 0, timestamp: 10.7, duration: 0.7, text: "Alpha beta", words: [
            WordTimestamp(timestamp: 10.7, duration: 0.3, text: "Alpha "),
            WordTimestamp(timestamp: 11.1, duration: 0.3, text: "beta"),
        ])
        let rejected = LyricLine(id: 1, timestamp: 15.7, duration: 0.7, text: "Gamma delta", words: [
            WordTimestamp(timestamp: 15.7, duration: 0.3, text: "Gamma "),
            WordTimestamp(timestamp: 16.1, duration: 0.3, text: "delta"),
        ])
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        cache.save(AudioSyncedLyricsRecord(
            trackId: track.id, engine: .lyricsAlignment, syncedAt: Date(), medianOffset: 0.7,
            alignedLineCount: 2, sourceLineCount: 3, lines: [locked, rejected, source[2]],
            lockedLineIDs: [0], attemptedLineIDs: [], lockedAtPlayStart: 1
        ))
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 15
        state.playbackAnchorDate = Date()
        let capture = FakeAudioCapture()
        let launches = LockedBox<[[Int: ClosedRange<Double>]]>([])
        var deps = makeDependencies(capture: capture, chunkDurationSeconds: 1)
        deps.launchLyricsAligner = { _, anchors in
            launches.withLock { $0.append(anchors) }
            return FakeChunkEngine(attempted: [1], confident: []) { _ in [] }
        }
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        defer { manager.stop() }
        manager.handleTrackLoaded(track: track, rawLines: source)
        let started = await waitUntil { manager.isLiveSyncActive && capture.startCount == 1 }
        XCTAssertTrue(started)

        capture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let dropped = await waitUntil { cache.load(trackId: track.id)?.alignedLineCount == 1 }
        XCTAssertTrue(dropped)
        let saved = try XCTUnwrap(cache.load(trackId: track.id))
        XCTAssertEqual(saved.lockedLineIDs, [0])
        XCTAssertTrue(saved.lines[1].words.isEmpty)
        XCTAssertFalse(saved.isReliable, "a single lock still falls short of complete-cache validation")

        state.setTrack(track, lyrics: source)
        manager.handleTrackLoaded(track: track, rawLines: source)
        let resumed = await waitUntil { manager.isLiveSyncActive && capture.startCount == 2 }
        XCTAssertTrue(resumed, "the unheard line still needs live alignment")
        XCTAssertEqual(launches.withLock { $0.last }, [0: 10.7...11.4])
        XCTAssertEqual(state.rawLyricLines[0].words, locked.words)
    }

    @MainActor
    func testReplayResumesWithTheOnlyUnattemptedUnlockedPlacement() async throws {
        let track = sampleTrack()
        let source = threeLines()
        let rejected = LyricLine(id: 0, timestamp: 10.7, duration: 0.7, text: source[0].text, words: [
            WordTimestamp(timestamp: 10.7, duration: 0.7, text: source[0].text),
        ])
        let unattempted = LyricLine(id: 1, timestamp: 15.7, duration: 0.7, text: source[1].text, words: [
            WordTimestamp(timestamp: 15.7, duration: 0.7, text: source[1].text),
        ])
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        cache.save(AudioSyncedLyricsRecord(
            trackId: track.id, engine: .lyricsAlignment, syncedAt: Date(), medianOffset: 0.7,
            alignedLineCount: 2, sourceLineCount: 3, lines: [rejected, unattempted, source[2]],
            lockedLineIDs: [], attemptedLineIDs: [], lockedAtPlayStart: 0
        ))
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10
        let capture = FakeAudioCapture()
        let launches = LockedBox(0)
        var deps = makeDependencies(capture: capture, chunkDurationSeconds: 1)
        deps.launchLyricsAligner = { _, _ in
            let attempt = launches.withLock { count in
                count += 1
                return count == 1 ? 0 : 2
            }
            return FakeChunkEngine(attempted: [attempt], confident: []) { _ in [] }
        }
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        defer { manager.stop() }
        manager.handleTrackLoaded(track: track, rawLines: source)
        let started = await waitUntil { manager.isLiveSyncActive && capture.startCount == 1 }
        XCTAssertTrue(started)

        capture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let dropped = await waitUntil { cache.load(trackId: track.id)?.alignedLineCount == 1 }
        XCTAssertTrue(dropped)
        let saved = try XCTUnwrap(cache.load(trackId: track.id))
        XCTAssertEqual(saved.lockedLineIDs, [])
        XCTAssertEqual(saved.heardWords ?? [], [])
        XCTAssertEqual(saved.lines[1].words, unattempted.words)
        XCTAssertFalse(saved.isReliable)

        state.setTrack(track, lyrics: source)
        manager.handleTrackLoaded(track: track, rawLines: source)
        let resumed = await waitUntil { manager.isLiveSyncActive && capture.startCount == 2 }
        XCTAssertTrue(resumed)
        XCTAssertEqual(state.rawLyricLines[1].words, unattempted.words)
        XCTAssertEqual(cache.load(trackId: track.id)?.alignedLineCount, 1)

        capture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let replayed = await waitUntil { cache.load(trackId: track.id)?.attemptedLineIDs == [0, 2] }
        XCTAssertTrue(replayed)
        XCTAssertEqual(cache.load(trackId: track.id)?.lines[1].words, unattempted.words)
    }

    @MainActor
    func testLyricsAlignmentSettlesOnceAPlayLocksNothingNew() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        // An earlier play locked lines 0 and 1, so line 2 is worth another listen.
        let saved = [
            LyricLine(id: 0, timestamp: 10.7, text: "Alpha beta", words: [WordTimestamp(timestamp: 10.7, duration: 0.7, text: "Alpha beta")]),
            LyricLine(id: 1, timestamp: 15.7, text: "Gamma delta", words: [WordTimestamp(timestamp: 15.7, duration: 0.7, text: "Gamma delta")]),
            LyricLine(id: 2, timestamp: 20.0, text: "Epsilon zeta"),
        ]
        cache.save(AudioSyncedLyricsRecord(
            trackId: sampleTrack().id, engine: .lyricsAlignment, syncedAt: Date(), medianOffset: 0.7,
            alignedLineCount: 2, sourceLineCount: 3, lines: saved, lockedLineIDs: [0, 1], attemptedLineIDs: [], lockedAtPlayStart: 0
        ))
        let launches = LockedBox<Int>(0)
        let fakeCapture = FakeAudioCapture()
        var deps = makeDependencies(capture: fakeCapture)
        deps.chunkDurationSeconds = 1.0
        deps.launchLyricsAligner = { _, _ in
            launches.withLock { $0 += 1 }
            return FakeChunkEngine(attempted: [2], confident: []) { _ in [] }
        }
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: threeLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        // This play hears line 2 again and locks nothing: the same audio would do the same next time.
        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let settled = await waitUntil { state.audioSyncStatus == .settled(engine: .lyricsAlignment, lockedLines: 2, totalLines: 3) }
        XCTAssertTrue(settled, "status \(state.audioSyncStatus)")
        XCTAssertFalse(manager.isLiveSyncActive)

        manager.handleTrackLoaded(track: sampleTrack(), rawLines: threeLines())
        XCTAssertEqual(state.audioSyncStatus, .settled(engine: .lyricsAlignment, lockedLines: 2, totalLines: 3))
        XCTAssertEqual(launches.withLock { $0 }, 1, "a settled song isn't listened for again")
    }

    @MainActor
    func testSettledSingleLockCacheSkipsAnotherCapture() {
        let source = threeLines()
        let locked = LyricLine(id: 0, timestamp: 10.7, duration: 0.7, text: source[0].text, words: [
            WordTimestamp(timestamp: 10.7, duration: 0.7, text: "Alpha beta"),
        ])
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        cache.save(AudioSyncedLyricsRecord(
            trackId: sampleTrack().id, engine: .lyricsAlignment, syncedAt: Date(), medianOffset: 0.7,
            alignedLineCount: 1, sourceLineCount: 3, lines: [locked, source[1], source[2]],
            lockedLineIDs: [0], attemptedLineIDs: [1, 2], lockedAtPlayStart: 1
        ))
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        let capture = FakeAudioCapture()
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: makeDependencies(capture: capture))
        defer { manager.stop() }

        manager.handleTrackLoaded(track: sampleTrack(), rawLines: source)

        XCTAssertEqual(state.audioSyncStatus, .settled(engine: .lyricsAlignment, lockedLines: 1, totalLines: 3))
        XCTAssertEqual(state.rawLyricLines[0].words, locked.words)
        XCTAssertFalse(manager.isLiveSyncActive)
        XCTAssertEqual(capture.startCount, 0)
    }

    @MainActor
    func testSettledZeroLockCacheKeepsRawLyricsAndSkipsAnotherCapture() {
        let track = sampleTrack()
        let source = threeLines()
        let cachedLines = source.map { line in
            LyricLine(id: line.id, timestamp: line.timestamp + 0.7, text: line.text)
        }
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        cache.save(AudioSyncedLyricsRecord(
            trackId: track.id, engine: .lyricsAlignment, syncedAt: Date(), medianOffset: 0.7,
            alignedLineCount: 0, sourceLineCount: 3, lines: cachedLines,
            lockedLineIDs: [], attemptedLineIDs: [0, 1, 2], lockedAtPlayStart: 0
        ))
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.setTrack(track, lyrics: source)
        let capture = FakeAudioCapture()
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: makeDependencies(capture: capture))
        defer { manager.stop() }

        manager.handleTrackLoaded(track: track, rawLines: source)

        XCTAssertEqual(state.audioSyncStatus, .settled(engine: .lyricsAlignment, lockedLines: 0, totalLines: 3))
        XCTAssertEqual(state.rawLyricLines, source)
        XCTAssertFalse(manager.isLiveSyncActive)
        XCTAssertEqual(capture.startCount, 0)
        XCTAssertNotNil(cache.load(trackId: track.id))
    }

    @MainActor
    func testLyricsAlignmentSendsTheRestOfTheAudioAsTheFinalChunkAtTheTrackEnd() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 178.2 // the track is 180 s long
        state.playbackAnchorDate = Date()
        let requests = LockedBox<[(samples: Int, isFinal: Bool)]>([])
        let fakeCapture = FakeAudioCapture()
        var deps = makeDependencies(capture: fakeCapture)
        deps.chunkDurationSeconds = 1.0
        deps.launchLyricsAligner = { _, _ in
            FakeChunkEngine { request in
                requests.withLock { $0.append((request.samples.count, request.isFinal)) }
                return []
            }
        }
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: threeLines())
        _ = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 30), sampleRate: 100) // up to 178.5 s
        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 60), sampleRate: 100) // up to 179.1 s
        let sent = await waitUntil { !requests.withLock { $0.isEmpty } }
        XCTAssertTrue(sent, "audio within a second of the end is sent without waiting for a whole chunk")
        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 50), sampleRate: 100)
        _ = await waitUntil(timeout: 0.2) { requests.withLock { $0.count } > 1 }

        let sentRequests = requests.withLock { $0 }
        XCTAssertEqual(sentRequests.map(\.samples), [90])
        XCTAssertEqual(sentRequests.map(\.isFinal), [true])
    }

    @MainActor
    func testResyncCurrentTrackPreservesTrackDurationForFinalChunk() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 178.2 // the track is 180 s long
        state.playbackAnchorDate = Date()
        let requests = LockedBox<[(samples: Int, isFinal: Bool)]>([])
        let fakeCapture = FakeAudioCapture()
        var deps = makeDependencies(capture: fakeCapture)
        deps.chunkDurationSeconds = 1.0
        deps.launchLyricsAligner = { _, _ in
            FakeChunkEngine { request in
                requests.withLock { $0.append((request.samples.count, request.isFinal)) }
                return []
            }
        }
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: threeLines())
        _ = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount == 1 }

        manager.resyncCurrentTrack()
        let restarted = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount == 2 }
        XCTAssertTrue(restarted)

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 90), sampleRate: 100) // up to 179.1 s
        let sent = await waitUntil { !requests.withLock { $0.isEmpty } }
        XCTAssertTrue(sent, "resyncCurrentTrack must keep activeTrackDuration so final chunks still flush")
        XCTAssertEqual(requests.withLock { $0.map(\.isFinal) }, [true])
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
        deps.chunkDurationSeconds = 1.0
        deps.launchLyricsAligner = { _, _ in FakeChunkEngine { _ in words } }
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: threeLines())
        _ = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let saved = await waitUntil { cache.load(trackId: sampleTrack().id)?.alignedLineCount == 1 }
        XCTAssertTrue(saved)
        XCTAssertTrue(manager.isLiveSyncActive, "line 2 has not been heard yet")
        XCTAssertEqual(state.audioSyncStatus, .syncing(engine: .lyricsAlignment, alignedLines: 1, totalLines: 3))
    }

    func testLyricsAlignmentProgressCountsLockedLinesAndFinishesOnceTheRestAreSettled() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "Alpha"),
            LyricLine(id: 1, timestamp: 20.0, text: "Beta"),
            LyricLine(id: 2, timestamp: 40.0, text: "Omega"),
            LyricLine(id: 3, timestamp: 44.0, text: "♪"),
        ]
        let all = AudioSyncManager.lyricsAlignmentProgress(lockedIDs: [0, 1, 2], settledIDs: [], lines: lines)
        XCTAssertEqual(all, .init(lockedLines: 3, totalLines: 3, isFinished: true), "♪ has nothing to align")
        XCTAssertEqual(all.status(engine: .lyricsAlignment), .cached(.lyricsAlignment))

        let settled = AudioSyncManager.lyricsAlignmentProgress(lockedIDs: [0, 1], settledIDs: [2], lines: lines)
        XCTAssertEqual(settled, .init(lockedLines: 2, totalLines: 3, isFinished: true))
        XCTAssertEqual(settled.status(engine: .lyricsAlignment), .settled(engine: .lyricsAlignment, lockedLines: 2, totalLines: 3))

        XCTAssertFalse(
            AudioSyncManager.lyricsAlignmentProgress(lockedIDs: [0, 1], settledIDs: [], lines: lines).isFinished,
            "line 2 has not been heard since the locked set last grew"
        )

        let unsupported = [
            LyricLine(id: 0, timestamp: 10.0, text: "Привет мир"),
            LyricLine(id: 1, timestamp: 20.0, text: "Как дела"),
        ]
        XCTAssertEqual(
            AudioSyncManager.lyricsAlignmentProgress(lockedIDs: [], settledIDs: [], lines: unsupported),
            .init(lockedLines: 0, totalLines: 0, isFinished: false),
            "tracks with no alignable letters must not report finished"
        )
    }

    @MainActor
    func testLyricsAlignmentStopsWithUnavailableWhenNoLinesAreReadable() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        let fakeCapture = FakeAudioCapture()
        var deps = makeDependencies(capture: fakeCapture)
        deps.chunkDurationSeconds = 1.0
        deps.launchLyricsAligner = { _, _ in FakeChunkEngine { _ in [] } }
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        let cyrillicLines = [
            LyricLine(id: 0, timestamp: 10.0, text: "Привет мир"),
            LyricLine(id: 1, timestamp: 15.0, text: "Как дела"),
        ]
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: cyrillicLines)
        _ = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let stopped = await waitUntil { !manager.isLiveSyncActive }
        XCTAssertTrue(stopped)
        guard case .unavailable = state.audioSyncStatus else {
            XCTFail("Expected .unavailable for unreadable script, got \(state.audioSyncStatus)")
            return
        }
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
    func testFailedAlignerRestartReleasesThePreviouslyCachedModelAfterIdle() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        let capture = FakeAudioCapture()
        let nextEngine = LockedBox<FakeChunkEngine?>(FakeChunkEngine { _ in [] })
        var deps = makeDependencies(capture: capture, launchAligner: { _, _ in
            nextEngine.withLock { engine in
                defer { engine = nil }
                return engine
            }
        })
        let released = expectation(description: "Released the cached model after restart failed")
        deps.idleModelReleaseSleep = { _ in }
        deps.releaseCachedModel = { released.fulfill() }

        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { capture.startCount == 1 }
        XCTAssertTrue(started)

        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines(), forceResync: true)
        await fulfillment(of: [released], timeout: 2)
        XCTAssertFalse(manager.isLiveSyncActive)
        XCTAssertEqual(capture.startCount, 1)
    }

    @MainActor
    func testAudioSampleBufferIsBoundedAndDispatchesCappedChunks() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false

        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()

        let firstChunkStarted = expectation(description: "First audio chunk started")
        let thirdChunkDispatched = expectation(description: "Third audio chunk dispatched")
        let releaseFirstChunk = DispatchSemaphore(value: 0)
        let recordedRequests = LockedBox<[AudioSyncManager.AudioChunkRequest]>([])

        let deps = makeDependencies(
            capture: fakeCapture,
            runChunk: { request in
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
            chunkDurationSeconds: 1.0
        )

        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let alignerStarted = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(alignerStarted)

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
        XCTAssertLessThanOrEqual(manager.bufferedSampleCount, chunkFrames * 2)
        XCTAssertEqual(manager.currentChunkStartPos ?? -1, 23.0, accuracy: 0.01)

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
        XCTAssertEqual(manager.bufferedSampleCount, 0)
    }

    @MainActor
    func testStopDuringAlignerStartupSkipsCaptureStartAndShutsDownEngine() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let engine = FakeChunkEngine { _ in [] }
        let launchStarted = expectation(description: "Aligner launch started")
        let releaseLaunch = LockedBox<CheckedContinuation<Void, Never>?>(nil)
        let deps = makeDependencies(
            capture: fakeCapture,
            launchAligner: { _, _ in
                launchStarted.fulfill()
                await withCheckedContinuation { continuation in
                    releaseLaunch.withLock { $0 = continuation }
                }
                return engine
            }
        )
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        await fulfillment(of: [launchStarted], timeout: 2.0)

        // Stop while the aligner is still starting up.
        manager.stop()
        releaseLaunch.withLock { continuation in
            continuation?.resume()
            continuation = nil
        }

        let shutDown = await waitUntil { engine.shutdownCount == 1 }
        XCTAssertTrue(shutDown, "Engine returned after stop() must be shut down immediately")
        XCTAssertFalse(manager.isLiveSyncActive)
        XCTAssertEqual(fakeCapture.startCount, 0)
    }

    // MARK: - #63: Late chunk completion after a same-track restart

    @MainActor
    func testLateChunkCompletionCannotMutateRestart() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()

        let chunkAStarted = expectation(description: "Audio chunk A started")
        let chunkBStarted = expectation(description: "Audio chunk B started")
        let releaseA = DispatchSemaphore(value: 0)
        let releaseB = DispatchSemaphore(value: 0)
        let requestCount = LockedBox<Int>(0)
        let matchingWords = ["Hello", "world", "from", "test"].enumerated().map { index, text in
            RecognizedAudioWord(text: text, startTime: 10.0 + Double(index) * 0.4, duration: 0.3, confidence: 0.9)
        }

        let deps = makeDependencies(
            capture: fakeCapture,
            runChunk: { _ in
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
            chunkDurationSeconds: 1.0
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
        XCTAssertTrue(manager.isChunkProcessing, "A must not clear B's processing slot")
        XCTAssertEqual(requestCount.withLock { $0 }, 2, "A third worker must not start while B is pending")
        XCTAssertNil(cache.load(trackId: track.id))
        XCTAssertEqual(state.audioSyncStatus, .syncing(engine: .lyricsAlignment, alignedLines: 0, totalLines: lines.count))

        releaseB.signal()
    }

    // MARK: - #115: Seek discards partial audio chunk

    func testSeekRetainsStereoSuffixAtFirstPostSeekSample() throws {
        let batch = CapturedAudio(
            samples: [1, 2, 3, 4], side: [-1, -2, -3, -4], sampleRate: 4,
            captureDelay: 1.5, capturedAt: 10
        )
        let suffix = try XCTUnwrap(batch.trimmingBefore(10.375, deliveredAt: 11.5))
        XCTAssertEqual(suffix.samples, [3, 4])
        XCTAssertEqual(suffix.side, [-3, -4])
        XCTAssertEqual(suffix.capturedAt, 10.5)
        XCTAssertEqual(suffix.captureDelay, 1)
        XCTAssertNil(batch.trimmingBefore(11, deliveredAt: 11.5))
    }

    func testSeekRetainsSampleExactlyOnBoundary() {
        let batch = CapturedAudio(samples: [1, 2, 3, 4], sampleRate: 10, capturedAt: 10)
        XCTAssertEqual(batch.trimmingBefore(10.3, deliveredAt: 10.4)?.samples, [4])
    }

    @MainActor
    func testAlignerDiscardsPartialChunkOnSameTrackSeek() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let recordedRequests = LockedBox<[AudioSyncManager.AudioChunkRequest]>([])
        let chunkDispatched = expectation(description: "Post-seek audio chunk dispatched")

        let deps = makeDependencies(
            capture: fakeCapture,
            runChunk: { request in
                recordedRequests.withLock { $0.append(request) }
                chunkDispatched.fulfill()
                return []
            },
            chunkDurationSeconds: 1.0
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
        XCTAssertEqual(manager.bufferedSampleCount, 50)
        XCTAssertEqual(manager.currentChunkStartPos ?? -1, 10.0, accuracy: 0.01)

        // Same-track seek to 90.0 while chunk is half full must discard the pre-seek samples.
        manager.handlePlaybackStateChanged(isPlaying: true, position: 90.0)
        XCTAssertEqual(manager.bufferedSampleCount, 0)
        XCTAssertNil(manager.currentChunkStartPos)

        // Emit 60 post-seek frames: must NOT trigger a mixed chunk immediately (50 + 60 >= 100).
        fakeCapture.emit(samples: [Float](repeating: 0.95, count: 60), sampleRate: 100.0)
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertTrue(recordedRequests.withLock { $0.isEmpty })
        XCTAssertEqual(manager.bufferedSampleCount, 60)
        XCTAssertEqual(manager.currentChunkStartPos ?? -1, 90.0, accuracy: 0.01)

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
    func testAlignerDropsQueuedPreSeekSamplesDeliveredAfterSeek() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let recordedRequests = LockedBox<[AudioSyncManager.AudioChunkRequest]>([])
        let chunkDispatched = expectation(description: "Post-seek audio chunk dispatched")

        let deps = makeDependencies(
            capture: fakeCapture,
            runChunk: { request in
                recordedRequests.withLock { $0.append(request) }
                chunkDispatched.fulfill()
                return []
            },
            chunkDurationSeconds: 1.0
        )

        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 50), sampleRate: 100.0)
        for _ in 0..<10 {
            await Task.yield()
        }
        XCTAssertEqual(manager.bufferedSampleCount, 50)

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
    func testAlignerDropsQueuedPreSeekSamplesWhenBufferIsEmpty() async {
        let requests = await runEmptyBufferDiscontinuity { state in
            state.playbackAnchorPosition = 90.0
            state.playbackAnchorDate = Date()
        }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.chunkStartTime ?? -1, 90.0, accuracy: 0.01)
        XCTAssertTrue(requests.first?.samples.allSatisfy { abs($0 - 0.95) < 0.001 } ?? false)
    }

    @MainActor
    func testAlignerDropsQueuedPreRateChangeSamplesWhenBufferIsEmpty() async {
        let requests = await runEmptyBufferDiscontinuity { state in
            state.playbackRate = 2.0
        }
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.playbackRate ?? -1, 2.0, accuracy: 0.001)
        XCTAssertTrue(requests.first?.samples.allSatisfy { abs($0 - 0.95) < 0.001 } ?? false)
    }

    /// Queues pre-change audio with an empty chunk buffer, applies `change` to live state first (as AppDelegate does), then reports it.
    @MainActor
    private func runEmptyBufferDiscontinuity(_ change: (LyricsState) -> Void) async -> [AudioSyncManager.AudioChunkRequest] {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let recordedRequests = LockedBox<[AudioSyncManager.AudioChunkRequest]>([])
        let chunkDispatched = expectation(description: "Post-change audio chunk dispatched")

        let deps = makeDependencies(
            capture: fakeCapture,
            runChunk: { request in
                recordedRequests.withLock { $0.append(request) }
                chunkDispatched.fulfill()
                return []
            },
            chunkDurationSeconds: 1.0
        )

        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)
        XCTAssertEqual(manager.bufferedSampleCount, 0)

        fakeCapture.emit(samples: [Float](repeating: 0.2, count: 30), sampleRate: 100.0)
        change(state)
        manager.handlePlaybackStateChanged(isPlaying: false, position: state.playbackAnchorPosition)
        fakeCapture.emit(samples: [Float](repeating: 0.95, count: 100), sampleRate: 100.0)
        await fulfillment(of: [chunkDispatched], timeout: 2.0)
        return recordedRequests.withLock { $0 }
    }

    @MainActor
    func testAlignerSecondSeekBeforeNextBufferAnchorsChunkToLatestSeek() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let recordedRequests = LockedBox<[AudioSyncManager.AudioChunkRequest]>([])
        let chunkDispatched = expectation(description: "Post-seek audio chunk dispatched")

        let deps = makeDependencies(
            capture: fakeCapture,
            runChunk: { request in
                recordedRequests.withLock { $0.append(request) }
                chunkDispatched.fulfill()
                return []
            },
            chunkDurationSeconds: 1.0
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
    func testAudioChunkRequestCarriesPlaybackRate() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        state.playbackRate = 2.0
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let recordedRequests = LockedBox<[AudioSyncManager.AudioChunkRequest]>([])
        let chunkDispatched = expectation(description: "Audio chunk dispatched")

        let deps = makeDependencies(
            capture: fakeCapture,
            runChunk: { request in
                recordedRequests.withLock { $0.append(request) }
                chunkDispatched.fulfill()
                return []
            },
            chunkDurationSeconds: 1.0
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
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let fakeCapture = FakeAudioCapture()
        let feed = LockedBox<[[RecognizedAudioWord]]>([])
        let deps = alignerDependencies(capture: fakeCapture, feed: feed)
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
        XCTAssertEqual(snapshot?.engine, .lyricsAlignment)
        XCTAssertEqual(snapshot?.localeIdentifier, "lyrics alignment")
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

    /// `tenLines()` as Lyrics Alignment saves them once every line is aligned.
    private func alignedTenLines() -> [LyricLine] {
        tenLines().map { line in
            LyricLine(id: line.id, timestamp: line.timestamp, text: line.text, words: [
                WordTimestamp(timestamp: line.timestamp, duration: 1.0, text: line.text),
            ])
        }
    }

    /// Words for the given lines as the aligner would report them, at track time 10 + 3 s per line.
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

    /// Dependencies whose aligner engine returns `feed`'s batches in order, one per 1 s chunk of 100 Hz samples.
    private func alignerDependencies(
        capture: FakeAudioCapture,
        feed: LockedBox<[[RecognizedAudioWord]]>,
        launchAligner: (@Sendable ([LyricLine], [Int: ClosedRange<Double>]) async -> AudioChunkTranscribing?)? = nil
    ) -> AudioSyncManager.Dependencies {
        makeDependencies(
            capture: capture,
            runChunk: { _ in feed.withLock { $0.isEmpty ? [] : $0.removeFirst() } },
            launchAligner: launchAligner,
            chunkDurationSeconds: 1.0
        )
    }

    /// Delivers one audio chunk that hears `words`, then waits for it to be processed.
    @MainActor
    private func hear(
        _ words: [RecognizedAudioWord],
        manager: AudioSyncManager,
        capture: FakeAudioCapture,
        feed: LockedBox<[[RecognizedAudioWord]]>
    ) async -> Bool {
        feed.withLock { $0.append(words) }
        capture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        return await waitUntil { feed.withLock { $0.isEmpty } && !manager.isChunkProcessing }
    }

    @MainActor
    private func startTenLineSync(
        cache: AudioSyncedLyricsCache
    ) -> (AudioSyncManager, LockedBox<[[RecognizedAudioWord]]>, FakeAudioCapture, LyricsState) {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let fakeCapture = FakeAudioCapture()
        let feed = LockedBox<[[RecognizedAudioWord]]>([])
        let manager = AudioSyncManager(
            state: state,
            cache: cache,
            dependencies: alignerDependencies(capture: fakeCapture, feed: feed)
        )
        state.setTrack(sampleTrack(), lyrics: tenLines())
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: tenLines())
        return (manager, feed, fakeCapture, state)
    }

    @MainActor
    func testLiveSyncKeepsListeningUntilAllLinesAreHeard() async {
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let (manager, feed, capture, state) = startTenLineSync(cache: cache)
        let started = await waitUntil { manager.isLiveSyncActive && capture.startCount > 0 }
        XCTAssertTrue(started)

        let firstChunk = await hear(heardWords(lines: 0..<3), manager: manager, capture: capture, feed: feed)
        XCTAssertTrue(firstChunk)
        XCTAssertEqual(manager.diagnostics.snapshot?.matchedLineCount, 3)
        XCTAssertTrue(manager.isLiveSyncActive, "3 of 10 lines must not end the sync")
        XCTAssertEqual(state.audioSyncStatus, .syncing(engine: .lyricsAlignment, alignedLines: 3, totalLines: 10))
        XCTAssertEqual(cache.load(trackId: sampleTrack().id)?.alignedLineCount, 3, "partial progress is saved")

        _ = await hear(heardWords(lines: 3..<10), manager: manager, capture: capture, feed: feed)
        let finished = await waitUntil { state.audioSyncStatus == .cached(.lyricsAlignment) }
        XCTAssertTrue(finished, "10 of 10 lines completes the sync; status \(state.audioSyncStatus)")
        XCTAssertFalse(manager.isLiveSyncActive)
    }

    @MainActor
    func testLiveCaptureRecoversRepeatedLineAfterFirstChorusLocks() async throws {
        let (record, diagnostics) = try await runRepeatedChorus()
        XCTAssertEqual(diagnostics.chorusRecoveredCount, 1)
        XCTAssertEqual(record.alignedLineCount, 2)
        XCTAssertEqual(record.lockedLineIDs, [0], "chroma recovery must not promote a line to a direct audio lock")
        XCTAssertTrue(record.isReliable(expectedSourceLineCount: 3))
        XCTAssertEqual(record.lines[1].timestamp - record.lines[0].timestamp, 10, accuracy: 0.025)
        XCTAssertEqual(record.lines[1].words.map(\.text), record.lines[0].words.map(\.text))
        XCTAssertTrue(diagnostics.report().contains("Repeated lines recovered: 1"))
    }

    @MainActor
    func testLiveCaptureKeepsFreshDirectMatchBelowLockConfidence() async throws {
        let directWords = [
            ("Beautiful", 20.35), ("day", 20.85), ("comes", 21.35), ("again", 21.75),
        ].map {
            RecognizedAudioWord(text: $0.0, startTime: $0.1, duration: 0.2, confidence: 0.9, sourceLineId: 1)
        }
        let (record, diagnostics) = try await runRepeatedChorus(secondWords: directWords)
        XCTAssertEqual(record.alignedLineCount, 2)
        XCTAssertEqual(record.lockedLineIDs, [0])
        XCTAssertEqual(diagnostics.chorusRecoveredCount, 0)
        let firstDirectWord = try XCTUnwrap(record.lines[1].words.first)
        XCTAssertEqual(firstDirectWord.timestamp, directWords[0].startTime, accuracy: 0.06)
    }

    @MainActor
    func testLiveCaptureReplacesClampedRunawayDirectMatchWithChroma() async throws {
        let (record, diagnostics) = try await runRepeatedChorus(secondWords: runawayChorusWords)
        XCTAssertEqual(diagnostics.chorusRecoveredCount, 1)
        XCTAssertEqual(record.alignedLineCount, 2)
        XCTAssertEqual(record.lockedLineIDs, [0])
        XCTAssertEqual(record.lines[1].timestamp - record.lines[0].timestamp, 10, accuracy: 0.025)
        XCTAssertEqual(record.lines[1].words.map(\.duration), record.lines[0].words.map(\.duration))
    }

    @MainActor
    func testLiveCaptureKeepsClampedRunawayDirectMatchWithoutQualifyingChroma() async throws {
        let (record, diagnostics) = try await runRepeatedChorus(secondWords: runawayChorusWords, transposeSecondBy: 6)
        XCTAssertEqual(diagnostics.chorusRecoveredCount, 0)
        XCTAssertEqual(record.alignedLineCount, 2)
        XCTAssertEqual(record.lockedLineIDs, [0])
        let direct = record.lines[1]
        XCTAssertEqual(direct.timestamp, runawayChorusWords[0].startTime, accuracy: 0.06)
        XCTAssertEqual(direct.timestamp + (direct.duration ?? 0), record.lines[2].timestamp, accuracy: 0.001)
    }

    private var runawayChorusWords: [RecognizedAudioWord] {
        [
            ("Beautiful", 20.35, 0.2), ("day", 20.85, 0.2), ("comes", 21.35, 0.2), ("again", 21.75, 8.0),
        ].map {
            RecognizedAudioWord(text: $0.0, startTime: $0.1, duration: $0.2, confidence: 0.9, sourceLineId: 1)
        }
    }

    @MainActor
    func testLiveChromaUsesPostGapCaptureTimeWithinChunk() async throws {
        let (record, diagnostics) = try await runRepeatedChorus(captureGap: 0.5)
        XCTAssertEqual(diagnostics.chorusRecoveredCount, 1)
        XCTAssertEqual(record.lines[1].timestamp - record.lines[0].timestamp, 10, accuracy: 0.025)
    }

    @MainActor
    private func runRepeatedChorus(
        secondWords: [RecognizedAudioWord] = [], captureGap: Double = 0, transposeSecondBy: Double = 0
    ) async throws -> (AudioSyncedLyricsRecord, AudioSyncDiagnostics) {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let track = TrackInfo(
            id: "spotify:track:repeated-chorus", title: "Repeat", artist: "Artist", album: "",
            duration: 30, artworkURL: nil
        )
        let lines = [
            LyricLine(id: 0, timestamp: 10, text: "Beautiful day comes again"),
            LyricLine(id: 1, timestamp: 20.5, text: "Beautiful day comes again"),
            LyricLine(id: 2, timestamp: 25, text: "Another distinct lyric line"),
        ]
        let capture = FakeAudioCapture()
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let batches = LockedBox(0)
        let firstWords = [
            ("Beautiful", 10.1), ("day", 10.7), ("comes", 11.1), ("again", 11.6),
        ].map {
            RecognizedAudioWord(text: $0.0, startTime: $0.1, duration: 0.25, confidence: 0.95, sourceLineId: 0)
        }
        let deps = makeDependencies(
            capture: capture,
            launchAligner: { _, _ in
                FakeChunkEngine(confident: [0]) { _ in
                    batches.withLock { count in
                        defer { count += 1 }
                        return count == 0 ? firstWords : secondWords
                    }
                }
            },
            chunkDurationSeconds: 12
        )
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        defer { manager.stop() }
        state.setTrack(track, lyrics: lines)
        manager.handleTrackLoaded(track: track, rawLines: lines)
        let started = await waitUntil { manager.isLiveSyncActive && capture.startCount == 1 }
        XCTAssertTrue(started)

        let rate = ChromaTestAudio.sampleRate
        let audio = ChromaTestAudio.repeatedPhrase(transposeSecondBy: transposeSecondBy)
        capture.emit(samples: Array(audio[..<Int(12 * rate)]), sampleRate: rate)
        let firstLocked = await waitUntil(timeout: 5) { cache.load(trackId: track.id)?.lockedLineIDs == [0] }
        XCTAssertTrue(firstLocked)

        state.playbackAnchorPosition = 12
        state.playbackAnchorDate = Date()
        if captureGap > 0 {
            capture.emit(samples: Array(audio[Int(12 * rate)..<Int(15 * rate)]), sampleRate: rate, captureDelay: 0)
            let buffered = await waitUntil { manager.bufferedSampleCount == Int(3 * rate) }
            XCTAssertTrue(buffered)
            state.playbackAnchorPosition = 15 + captureGap
            capture.emit(
                samples: Array(audio[Int((15 + captureGap) * rate)..<Int((24 + captureGap) * rate)]),
                sampleRate: rate, captureDelay: 0
            )
        } else {
            capture.emit(samples: Array(audio[Int(12 * rate)..<Int(24 * rate)]), sampleRate: rate)
        }
        let processed = await waitUntil(timeout: 5) { manager.diagnostics.snapshot?.resultCount == 2 }
        XCTAssertTrue(processed)
        return try (XCTUnwrap(cache.load(trackId: track.id)), XCTUnwrap(manager.diagnostics.snapshot))
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
            trackId: sampleTrack().id, engine: .lyricsAlignment, syncedAt: Date(), medianOffset: 0.5,
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

        // Fresh words tagged to line B must not evict prior words tagged to a different line A.
        let priorTagged = [RecognizedAudioWord(text: "lineA", startTime: 11.7, duration: 0.3, confidence: 0.9, sourceLineId: 0)]
        let currentTagged = [RecognizedAudioWord(text: "lineB", startTime: 12.1, duration: 0.3, confidence: 0.9, sourceLineId: 1)]
        let crossLineMerged = AudioSyncManager.mergeHeardWords(prior: priorTagged, current: currentTagged)
        XCTAssertEqual(crossLineMerged.map(\.text), ["lineA", "lineB"])
    }

    @MainActor
    func testLaterPlayAddsToWordsHeardOnEarlierPlays() async {
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        // Play 1 heard lines 0-3 (track time = 10 + 3 * line).
        let firstPlay = heardWords(lines: 0..<4)
        let firstResult = LyricsAudioAligner.align(lines: tenLines(), recognizedWords: firstPlay)
        XCTAssertEqual(firstResult.matchedLineCount, 4)
        cache.save(AudioSyncedLyricsRecord(
            trackId: sampleTrack().id, engine: .lyricsAlignment, syncedAt: Date(), medianOffset: firstResult.medianOffset,
            alignedLineCount: 4, sourceLineCount: 10, lines: firstResult.lines, heardWords: firstPlay
        ))

        let (manager, feed, capture, state) = startTenLineSync(cache: cache)
        let started = await waitUntil { manager.isLiveSyncActive && capture.startCount > 0 }
        XCTAssertTrue(started)

        // Play 2 catches the remaining lines 4..<10.
        _ = await hear(heardWords(lines: 4..<10), manager: manager, capture: capture, feed: feed)
        let saved = await waitUntil { cache.load(trackId: self.sampleTrack().id)?.alignedLineCount == 10 }

        XCTAssertTrue(saved, "4 earlier + 6 new lines reach 10/10")
        // The record predates locking, so its lines are kept on screen but not locked until heard again.
        XCTAssertEqual(cache.load(trackId: sampleTrack().id)?.lockedLineIDs, Array(4..<10))
        XCTAssertTrue(manager.isLiveSyncActive)
    }

    @MainActor
    func testRecordAlignedToOtherLyricsIsDiscarded() async {
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let oldLyrics = tenLines().map { LyricLine(id: $0.id, timestamp: $0.timestamp, text: $0.text + " / annotation") }
        cache.save(AudioSyncedLyricsRecord(
            trackId: sampleTrack().id, engine: .lyricsAlignment, syncedAt: Date(), medianOffset: 0.2,
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
            trackId: sampleTrack().id, engine: .lyricsAlignment, syncedAt: Date(), medianOffset: 0.2,
            alignedLineCount: 10, sourceLineCount: 10, lines: alignedTenLines(), lockedLineIDs: Array(0..<10)
        ))

        let (manager, _, capture, state) = startTenLineSync(cache: cache)

        XCTAssertEqual(state.audioSyncStatus, .cached(.lyricsAlignment))
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
            trackId: sampleTrack().id, engine: .lyricsAlignment, syncedAt: Date(), medianOffset: 0.5,
            alignedLineCount: 1, sourceLineCount: 10, lines: shiftedLines, heardWords: firstPlay
        ))

        let (manager, feed, capture, state) = startTenLineSync(cache: cache)
        let started = await waitUntil { manager.isLiveSyncActive && capture.startCount > 0 }
        XCTAssertTrue(started)

        // Unreliable timings (+0.5s shift) must not be applied to display.
        state.updatePlayback(isPlaying: true, position: 10.2)
        XCTAssertEqual(state.currentText, "amber river glows")
        state.updatePlayback(isPlaying: false, position: 10.0)

        // Hearing the remaining 9 lines combines with the 1 retained line to reach 10/10 completion.
        _ = await hear(heardWords(lines: 1..<10), manager: manager, capture: capture, feed: feed)
        let completed = await waitUntil { state.audioSyncStatus == .cached(.lyricsAlignment) }
        XCTAssertTrue(completed, "1 retained + 9 new lines must reach 10/10; status \(state.audioSyncStatus)")
        XCTAssertEqual(cache.load(trackId: sampleTrack().id)?.alignedLineCount, 10)
    }

    @MainActor
    func testReplayDiscardsPriorWordsOnlyForTheLineItReattemptsWithoutAMatch() async throws {
        let track = sampleTrack()
        let source = threeLines()
        let priorWords = [
            RecognizedAudioWord(text: "Alpha", startTime: 10.7, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "beta", startTime: 11.1, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "Gamma", startTime: 15.7, duration: 0.3, confidence: 0.9, sourceLineId: 1),
            RecognizedAudioWord(text: "delta", startTime: 16.1, duration: 0.3, confidence: 0.9, sourceLineId: 1),
        ]
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        cache.save(AudioSyncedLyricsRecord(
            trackId: track.id, engine: .lyricsAlignment, syncedAt: Date(), medianOffset: nil,
            alignedLineCount: 1, sourceLineCount: 3, lines: source, heardWords: priorWords,
            lockedLineIDs: [], attemptedLineIDs: [], lockedAtPlayStart: 0
        ))
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10
        state.playbackAnchorDate = Date()
        let capture = FakeAudioCapture()
        var deps = makeDependencies(capture: capture, chunkDurationSeconds: 1)
        deps.launchLyricsAligner = { _, _ in FakeChunkEngine(attempted: [0], confident: []) { _ in [] } }
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        defer { manager.stop() }
        manager.handleTrackLoaded(track: track, rawLines: source)
        let started = await waitUntil { manager.isLiveSyncActive && capture.startCount > 0 }
        XCTAssertTrue(started)

        capture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let retried = await waitUntil { cache.load(trackId: track.id)?.attemptedLineIDs == [0] }
        XCTAssertTrue(retried)
        let saved = try XCTUnwrap(cache.load(trackId: track.id))
        XCTAssertTrue(saved.lines[0].words.isEmpty, "the rejected line must not match stale words")
        XCTAssertEqual(saved.lines[1].words.map(\.timestamp), [15.7, 16.1])
        XCTAssertEqual(saved.heardWords?.compactMap(\.sourceLineId), [1, 1])
    }

    @MainActor
    func testRejectedReplayPersistsRemovalWhenNoLinesRemainMatched() async {
        let track = sampleTrack()
        let source = threeLines()
        let priorWords = [
            RecognizedAudioWord(text: "Alpha", startTime: 10.7, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "beta", startTime: 11.1, duration: 0.3, confidence: 0.9, sourceLineId: 0),
        ]
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        cache.save(AudioSyncedLyricsRecord(
            trackId: track.id, engine: .lyricsAlignment, syncedAt: Date(), medianOffset: nil,
            alignedLineCount: 1, sourceLineCount: 3, lines: source, heardWords: priorWords,
            lockedLineIDs: [], attemptedLineIDs: [], lockedAtPlayStart: 0
        ))
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10
        state.playbackAnchorDate = Date()
        let capture = FakeAudioCapture()
        let processed = LockedBox<Int>(0)
        var deps = makeDependencies(capture: capture, chunkDurationSeconds: 1)
        deps.launchLyricsAligner = { _, _ in
            FakeChunkEngine(attempted: [0], confident: []) { _ in
                processed.withLock { $0 += 1 }
                return []
            }
        }
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        defer { manager.stop() }
        manager.handleTrackLoaded(track: track, rawLines: source)
        let started = await waitUntil { manager.isLiveSyncActive && capture.startCount > 0 }
        XCTAssertTrue(started)

        capture.emit(samples: [Float](repeating: 0.1, count: 100), sampleRate: 100)
        let replayed = await waitUntil { processed.withLock { $0 } == 1 && !manager.isChunkProcessing }
        XCTAssertTrue(replayed)
        let saved = cache.load(trackId: track.id)
        XCTAssertTrue(
            saved == nil || saved?.heardWords?.isEmpty == true,
            "rejected words must be removed from the on-disk record"
        )
    }

    @MainActor
    func testDiagnosticsResetWhenTrackChangesToCachedOrDisabledTrack() async {
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let (manager, feed, capture, state) = startTenLineSync(cache: cache)
        let started = await waitUntil { manager.isLiveSyncActive && capture.startCount > 0 }
        XCTAssertTrue(started)

        _ = await hear(heardWords(lines: 0..<10), manager: manager, capture: capture, feed: feed)
        let completed = await waitUntil { state.audioSyncStatus == .cached(.lyricsAlignment) }
        XCTAssertTrue(completed)
        XCTAssertNotNil(manager.diagnostics.snapshot, "final snapshot is preserved when the same track finishes")

        let trackB = TrackInfo(id: "spotify:track:second", title: "Second Song", artist: "Artist B", album: "", duration: 200, artworkURL: nil)
        cache.save(AudioSyncedLyricsRecord(
            trackId: trackB.id, engine: .lyricsAlignment, syncedAt: Date(), medianOffset: 0.0,
            alignedLineCount: 10, sourceLineCount: 10, lines: alignedTenLines(), lockedLineIDs: Array(0..<10)
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
            trackId: sampleTrack().id, engine: .lyricsAlignment, syncedAt: Date(), medianOffset: priorResult.medianOffset,
            alignedLineCount: 3, sourceLineCount: 10, lines: priorResult.lines, heardWords: priorWords
        ))

        let (manager, feed, capture, state) = startTenLineSync(cache: cache)
        let started = await waitUntil { manager.isLiveSyncActive && capture.startCount > 0 }
        XCTAssertTrue(started)

        // Chunk 1 adds lines 3..<5, reaching 5/10 matched lines (still partial, below 6/10).
        let fiveHeard = await hear(heardWords(lines: 3..<5), manager: manager, capture: capture, feed: feed)
        XCTAssertTrue(fiveHeard)
        XCTAssertEqual(cache.load(trackId: sampleTrack().id)?.alignedLineCount, 5)
        XCTAssertEqual(state.audioSyncStatus, .syncing(engine: .lyricsAlignment, alignedLines: 5, totalLines: 10))

        // Chunk 2 hears garbled speech overlapping prior line 0; accepted session lines must remain preserved.
        let garbledLine0 = [
            RecognizedAudioWord(text: "mumble", startTime: 10.0, duration: 0.4, confidence: 0.5),
            RecognizedAudioWord(text: "static", startTime: 10.6, duration: 0.4, confidence: 0.5),
        ]
        let weakerHeard = await hear(garbledLine0, manager: manager, capture: capture, feed: feed)
        XCTAssertTrue(weakerHeard)
        XCTAssertEqual(
            manager.diagnostics.snapshot?.matchedLineCount,
            5,
            "overlapping garbled words must not downgrade already-accepted session lines"
        )

        // Pause triggers persistCurrentAlignmentIfReady() as well.
        manager.handlePlaybackStateChanged(isPlaying: false, position: 25.0)

        XCTAssertEqual(cache.load(trackId: sampleTrack().id)?.alignedLineCount, 5, "a weaker later revision must not overwrite the 5-line cache")
        XCTAssertEqual(state.audioSyncStatus, .syncing(engine: .lyricsAlignment, alignedLines: 5, totalLines: 10))
    }

    // MARK: - #113: Unrelated speech around a single common word stays absent from displayed & cached lyrics

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
    func testRetiredCaptureStreamCannotDeliverSamplesToNextSession() async throws {
        let target: Set<String> = ["com.spotify.client"]
        let backend = FakeSystemAudioCaptureBackend(initialApps: Array(target))
        let capture = SystemAudioCapture(backend: backend)
        capture.onAudioSamples = { _ in XCTFail("Retired stream delivered audio") }
        try await capture.start(targetBundleIds: target)
        let retired = try XCTUnwrap(backend.startedStreams.last)
        capture.stop()

        let received = LockedBox<[[Float]]>([])
        capture.onAudioSamples = { audio in received.withLock { $0.append(audio.samples) } }
        try await capture.start(targetBundleIds: target)
        let current = try XCTUnwrap(backend.startedStreams.last)

        // Contiguous half-batches would combine if the retired stream could still write to the new batcher.
        retired.emit(CapturedAudio(samples: [1], sampleRate: 10, capturedAt: 100))
        current.emit(CapturedAudio(samples: [2], sampleRate: 10, capturedAt: 100.1))
        XCTAssertTrue(received.withLock { $0.isEmpty })
        current.emit(CapturedAudio(samples: [3], sampleRate: 10, capturedAt: 100.2))
        retired.emit(CapturedAudio(samples: [4], sampleRate: 10, capturedAt: 100.1))
        XCTAssertEqual(received.withLock { $0 }, [[2, 3]])
        capture.stop()
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
        state.audioSyncEngine = .lyricsAlignment
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let launches = LockedBox<[FakeChunkEngine]>([])
        let deps = makeDependencies(
            capture: capture,
            launchAligner: { _, _ in
                let engine = FakeChunkEngine(transcribe: { _ in [] })
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
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let feed = LockedBox<[[RecognizedAudioWord]]>([])
        let deps = alignerDependencies(capture: fakeCapture, feed: feed)
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
    func testUpdateSourceBundleStartsNewAudioChunkAtNewCapturePosition() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        let fakeCapture = FakeAudioCapture()
        let deps = makeDependencies(
            capture: fakeCapture,
            chunkDurationSeconds: 1.0
        )
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)

        manager.handleTrackLoaded(track: browserTrack(sourceBundleId: "com.google.Chrome"), rawLines: sampleLines())
        let chromeStarted = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount == 1 }
        XCTAssertTrue(chromeStarted)

        state.updatePlayback(isPlaying: false, position: 10.0)
        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 80), sampleRate: 100)
        let chromeBuffered = await waitUntil { manager.bufferedSampleCount == 80 }
        XCTAssertTrue(chromeBuffered)
        XCTAssertEqual(manager.currentChunkStartPos, 10.0)

        state.updatePlayback(isPlaying: false, position: 24.0)
        manager.updateSourceBundle(for: browserTrack(sourceBundleId: "com.apple.Safari"))
        XCTAssertEqual(manager.bufferedSampleCount, 0)
        XCTAssertNil(manager.currentChunkStartPos)

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 30), sampleRate: 100)
        let safariBuffered = await waitUntil { manager.bufferedSampleCount == 30 }
        XCTAssertTrue(safariBuffered)
        XCTAssertEqual(manager.currentChunkStartPos, 24.0)
    }

    @MainActor
    func testUpdateSourceBundleDropsQueuedSamplesFromPreviousCapture() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false
        let fakeCapture = FakeAudioCapture()
        let recordedRequests = LockedBox<[AudioSyncManager.AudioChunkRequest]>([])
        let chunkDispatched = expectation(description: "Post-retarget audio chunk dispatched")
        let deps = makeDependencies(
            capture: fakeCapture,
            runChunk: { request in
                recordedRequests.withLock { $0.append(request) }
                chunkDispatched.fulfill()
                return []
            },
            chunkDurationSeconds: 1.0
        )
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)

        manager.handleTrackLoaded(track: browserTrack(sourceBundleId: "com.google.Chrome"), rawLines: sampleLines())
        let chromeStarted = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount == 1 }
        XCTAssertTrue(chromeStarted)

        let chromeHandler = fakeCapture.onAudioSamples
        // Chrome audio captured but still queued for main-actor delivery when the handoff lands.
        fakeCapture.emit(samples: [Float](repeating: 0.2, count: 30), sampleRate: 100.0)
        manager.updateSourceBundle(for: browserTrack(sourceBundleId: "com.apple.Safari"))
        // A Chrome callback already executing on the audio queue can finish after the handoff.
        chromeHandler?(CapturedAudio(samples: [0.2], sampleRate: 100))
        fakeCapture.emit(samples: [Float](repeating: 0.95, count: 100), sampleRate: 100.0)
        await fulfillment(of: [chunkDispatched], timeout: 2.0)

        let requests = recordedRequests.withLock { $0 }
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(requests.first?.samples.allSatisfy { abs($0 - 0.95) < 0.001 } ?? false)
    }

    @MainActor
    func testChunkStartIsBackdatedByTheBufferCaptureDelay() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 50.0
        state.playbackAnchorDate = Date()
        state.isPlaying = true
        let fakeCapture = FakeAudioCapture()
        let deps = alignerDependencies(capture: fakeCapture, feed: LockedBox([]))
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)

        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount == 1 }
        XCTAssertTrue(started)

        fakeCapture.emit(samples: [Float](repeating: 0.1, count: 30), sampleRate: 100, captureDelay: 0.4)
        let buffered = await waitUntil { manager.bufferedSampleCount == 30 }
        XCTAssertTrue(buffered)
        // Audio captured 0.4 s before delivery was played 0.4 s earlier in the track.
        XCTAssertEqual(manager.currentChunkStartPos ?? -1, 49.6, accuracy: 0.1)
        XCTAssertEqual(manager.vocalEnvelope.segments.first?.start ?? -1, 49.6, accuracy: 0.1)
    }

    @MainActor
    func testAlignedWordsFollowTheCapturedVocalWaveform() async throws {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
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
        var deps = makeDependencies(capture: fakeCapture, chunkDurationSeconds: 6.0)
        deps.launchLyricsAligner = { _, _ in
            FakeChunkEngine(transcribe: { _ in feed.withLock { $0.isEmpty ? [] : $0.removeFirst() } })
        }
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
        state.audioSyncEngine = .lyricsAlignment
        let fakeCapture = FakeAudioCapture()
        let engine = FakeChunkEngine(transcribe: { _ in [] })
        let deps = alignerDependencies(capture: fakeCapture, feed: LockedBox([]), launchAligner: { _, _ in engine })
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

    @MainActor
    func testTwoChunkLockedLineTrimsHeldTailWhenLaterChunkRecoversEarlierNextLine() async throws {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 14.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false

        let track = TrackInfo(id: "spotify:track:two-chunk-trim", title: "Trim", artist: "Artist", album: "", duration: 60, artworkURL: nil)
        let rawLines = [
            LyricLine(id: 0, timestamp: 16.0, text: "First line held"),
            LyricLine(id: 1, timestamp: 20.0, text: "Second line starts"),
            LyricLine(id: 2, timestamp: 30.0, text: "Third line later"),
        ]
        state.setTrack(track, lyrics: rawLines)

        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let chunkCounter = LockedBox<Int>(0)
        let deps = makeDependencies(
            capture: fakeCapture,
            runChunk: { _ in
                let index = chunkCounter.withLock { n -> Int in
                    n += 1
                    return n
                }
                if index == 1 {
                    return [
                        RecognizedAudioWord(text: "first", startTime: 16.0, duration: 0.6, confidence: 0.95),
                        RecognizedAudioWord(text: "line", startTime: 16.9, duration: 0.6, confidence: 0.95),
                        RecognizedAudioWord(text: "held", startTime: 18.2, duration: 1.4, confidence: 0.95),
                    ]
                }
                return [
                    RecognizedAudioWord(text: "second", startTime: 18.6, duration: 0.4, confidence: 0.95),
                    RecognizedAudioWord(text: "line", startTime: 19.0, duration: 0.4, confidence: 0.95),
                    RecognizedAudioWord(text: "starts", startTime: 19.4, duration: 0.4, confidence: 0.95),
                ]
            },
            chunkDurationSeconds: 1.0
        )

        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: track, rawLines: rawLines)
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        // Chunk 1 locks line 0 with a held tail ending at 19.6 s.
        fakeCapture.emit(samples: [Float](repeating: 0.2, count: 100), sampleRate: 100)
        let firstLocked = await waitUntil { (cache.load(trackId: track.id)?.alignedLineCount ?? 0) >= 1 }
        XCTAssertTrue(firstLocked)
        let firstRecord = try XCTUnwrap(cache.load(trackId: track.id))
        XCTAssertEqual(firstRecord.lockedLineIDs?.contains(0), true, "chunk 1 must save line 0 as locked")
        let afterFirst = firstRecord.lines
        XCTAssertEqual(afterFirst.count, 3)
        XCTAssertEqual(afterFirst[0].timestamp + (afterFirst[0].duration ?? 0), 19.6, accuracy: 0.05)

        // Chunk 2 recovers line 1 starting at 18.6 s; restoring locked line 0 must trim its tail to 18.6 s.
        fakeCapture.emit(samples: [Float](repeating: 0.2, count: 100), sampleRate: 100)
        let secondAligned = await waitUntil { (cache.load(trackId: track.id)?.alignedLineCount ?? 0) >= 2 }
        XCTAssertTrue(secondAligned)

        let published = state.rawLyricLines
        XCTAssertEqual(published[1].timestamp, 18.6, accuracy: 0.05)
        XCTAssertLessThanOrEqual(published[0].timestamp + (published[0].duration ?? 0), 18.61)
        let publishedLastWord = try XCTUnwrap(published[0].words.last)
        XCTAssertEqual(publishedLastWord.text.trimmingCharacters(in: .whitespaces), "held")
        XCTAssertLessThanOrEqual(publishedLastWord.timestamp + (publishedLastWord.duration ?? 0), 18.61)

        let persisted = cache.load(trackId: track.id)?.lines ?? []
        XCTAssertEqual(persisted[1].timestamp, 18.6, accuracy: 0.05)
        XCTAssertLessThanOrEqual(persisted[0].timestamp + (persisted[0].duration ?? 0), 18.61)
        let persistedLastWord = try XCTUnwrap(persisted[0].words.last)
        XCTAssertEqual(persistedLastWord.text.trimmingCharacters(in: .whitespaces), "held")
        XCTAssertLessThanOrEqual(persistedLastWord.timestamp + (persistedLastWord.duration ?? 0), 18.61)
    }

    @MainActor
    func testRestoringShiftedLockedLinePreservesDurationAndOrderAcrossStaleBlank() async throws {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false

        let track = TrackInfo(id: "spotify:track:shifted-locked-blank", title: "BlankOrder", artist: "Artist", album: "", duration: 60, artworkURL: nil)
        let rawLines = [
            LyricLine(id: 0, timestamp: 5.0, text: "Opening line"),
            LyricLine(id: 1, timestamp: 10.0, text: "Locked intro"),
            LyricLine(id: 2, timestamp: 11.0, text: ""),
            LyricLine(id: 3, timestamp: 14.0, text: "Later chorus"),
            LyricLine(id: 4, timestamp: 18.0, text: "Final line"),
        ]
        state.setTrack(track, lyrics: rawLines)

        let cache = AudioSyncedLyricsCache(directory: tempDir)
        // Seed a reliable partial cache where L1 locked late at 11.5..12.5 (past blank B2's raw 11.0)
        // and has no re-matchable anchored words in `fresh` (equivalent to silence-gated intro words).
        cache.save(
            AudioSyncedLyricsRecord(
                trackId: track.id,
                engine: .lyricsAlignment,
                syncedAt: Date(),
                medianOffset: 0.0,
                alignedLineCount: 2,
                sourceLineCount: 4,
                lines: [
                    LyricLine(
                        id: 0,
                        timestamp: 5.0,
                        duration: 1.0,
                        text: "Opening line",
                        words: [
                            WordTimestamp(timestamp: 5.0, duration: 0.5, text: "Opening "),
                            WordTimestamp(timestamp: 5.5, duration: 0.5, text: "line"),
                        ]
                    ),
                    LyricLine(id: 1, timestamp: 11.5, duration: 1.0, text: "Locked intro"),
                    LyricLine(id: 2, timestamp: 12.5, text: ""),
                    LyricLine(id: 3, timestamp: 14.0, text: "Later chorus"),
                    LyricLine(id: 4, timestamp: 18.0, text: "Final line"),
                ],
                lockedLineIDs: [0, 1]
            )
        )

        let fakeCapture = FakeAudioCapture()
        let deps = makeDependencies(
            capture: fakeCapture,
            runChunk: { _ in
                [
                    RecognizedAudioWord(text: "later", startTime: 14.0, duration: 0.4, confidence: 0.95, sourceLineId: 3),
                    RecognizedAudioWord(text: "chorus", startTime: 14.5, duration: 0.5, confidence: 0.95, sourceLineId: 3),
                ]
            },
            chunkDurationSeconds: 1.0
        )

        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: track, rawLines: rawLines)
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        fakeCapture.emit(samples: [Float](repeating: 0.2, count: 100), sampleRate: 100)
        let updated = await waitUntil { (cache.load(trackId: track.id)?.alignedLineCount ?? 0) >= 3 }
        XCTAssertTrue(updated)

        let saved = try XCTUnwrap(cache.load(trackId: track.id))
        XCTAssertTrue(saved.isReliable, "restored locked line + blank must remain strictly monotonic and reliable")
        XCTAssertEqual(saved.lines[1].timestamp, 11.5, accuracy: 0.01)
        XCTAssertEqual(saved.lines[1].duration ?? 0, 1.0, accuracy: 0.01)
        XCTAssertEqual(saved.lines[2].timestamp, 12.5, accuracy: 0.01)
        XCTAssertEqual(saved.lines[3].timestamp, 14.0, accuracy: 0.01)
    }

    @MainActor
    func testLiveDisplayEnvelopeReadsNewFramesImmediatelyAfterCachedRead() async {
        let (manager, _, capture, _) = startTenLineSync(cache: AudioSyncedLyricsCache(directory: tempDir))
        let started = await waitUntil { capture.startCount == 1 }
        XCTAssertTrue(started)
        let frame = [Float](repeating: 0.2, count: 10)
        let trackId = sampleTrack().id

        capture.emit(samples: frame, sampleRate: 1000)
        let firstCaptured = await waitUntil { manager.bufferedSampleCount == 10 }
        XCTAssertTrue(firstCaptured)
        XCTAssertEqual(manager.vocalEnvelope(for: trackId)?.segments.first?.levels.count, 1)

        capture.emit(samples: frame, sampleRate: 1000)
        let secondCaptured = await waitUntil { manager.bufferedSampleCount == 20 }
        XCTAssertTrue(secondCaptured)
        XCTAssertEqual(manager.vocalEnvelope(for: trackId)?.segments.first?.levels.count, 2)
    }

    @MainActor
    func testFirstCompletedVocalEnvelopeFramePublishesImmediatelyAfterPartialDelivery() async {
        let (manager, _, capture, _) = startTenLineSync(cache: AudioSyncedLyricsCache(directory: tempDir))
        let started = await waitUntil { capture.startCount == 1 }
        XCTAssertTrue(started)
        var publishedFrameCounts: [Int] = []
        let sub = manager.vocalEnvelopeDidChange.sink { trackId in
            publishedFrameCounts.append(manager.vocalEnvelope(for: trackId)?.segments.first?.levels.count ?? 0)
        }
        defer { sub.cancel() }

        let halfFrame = [Float](repeating: 0.2, count: 5)
        capture.emit(samples: halfFrame, sampleRate: 1000)
        let partialCaptured = await waitUntil { manager.bufferedSampleCount == 5 }
        XCTAssertTrue(partialCaptured)
        XCTAssertTrue(publishedFrameCounts.isEmpty)

        capture.emit(samples: halfFrame, sampleRate: 1000)
        let frameCaptured = await waitUntil { manager.bufferedSampleCount == 10 }
        XCTAssertTrue(frameCaptured)
        XCTAssertEqual(publishedFrameCounts, [1])
    }

    private final class ControlledNotifyClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: ContinuousClock.Instant = .now
        private var waiters: [(deadline: ContinuousClock.Instant, continuation: CheckedContinuation<Void, Error>)] = []

        func now() -> ContinuousClock.Instant {
            lock.withLock { current }
        }

        func sleep(until deadline: ContinuousClock.Instant) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { cont in
                    enum Action {
                        case resume
                        case cancel
                        case enqueued
                    }
                    let action: Action = lock.withLock {
                        if Task.isCancelled {
                            return .cancel
                        }
                        if current >= deadline {
                            return .resume
                        }
                        waiters.append((deadline, cont))
                        return .enqueued
                    }
                    switch action {
                    case .resume:
                        cont.resume()
                    case .cancel:
                        cont.resume(throwing: CancellationError())
                    case .enqueued:
                        break
                    }
                }
            } onCancel: {
                let cancelled: [CheckedContinuation<Void, Error>] = lock.withLock {
                    let pending = waiters.map(\.continuation)
                    waiters.removeAll()
                    return pending
                }
                for cont in cancelled {
                    cont.resume(throwing: CancellationError())
                }
            }
        }

        func advance(by duration: Duration) {
            let ready: [CheckedContinuation<Void, Error>] = lock.withLock {
                current = current.advanced(by: duration)
                let readyWaiters = waiters.filter { current >= $0.deadline }
                waiters.removeAll { current >= $0.deadline }
                return readyWaiters.map(\.continuation)
            }
            for cont in ready {
                cont.resume()
            }
        }

        var hasPendingWaiter: Bool {
            lock.withLock { !waiters.isEmpty }
        }
    }

    @MainActor
    func testThrottledVocalEnvelopePublishesLatestFramesAfterPlaybackPauses() async {
        // Use a controllable notification clock so the 200 ms deadline stays deterministically pending
        // until after playback pauses, regardless of CI scheduling speed.
        let clock = ControlledNotifyClock()
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = true

        let capture = FakeAudioCapture()
        var deps = makeDependencies(capture: capture, chunkDurationSeconds: 12.0)
        deps.vocalEnvelopeNow = { clock.now() }
        deps.vocalEnvelopeSleep = { try await clock.sleep(until: $0) }
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        let track = sampleTrack()
        state.setTrack(track, lyrics: tenLines())
        manager.handleTrackLoaded(track: track, rawLines: tenLines())
        let started = await waitUntil { capture.startCount == 1 }
        XCTAssertTrue(started)

        var publishedFrameCounts: [Int] = []
        let sub = manager.vocalEnvelopeDidChange.sink { _ in
            publishedFrameCounts.append(manager.vocalEnvelope.segments.first?.levels.count ?? 0)
        }
        defer { sub.cancel() }

        let frame = [Float](repeating: 0.2, count: 10)
        for _ in 0..<3 {
            capture.emit(samples: frame, sampleRate: 1000)
        }
        let captured = await waitUntil { manager.bufferedSampleCount == 30 && clock.hasPendingWaiter }
        XCTAssertTrue(captured)
        XCTAssertEqual(publishedFrameCounts, [1], "burst within throttle window must hold frames 2 and 3 for trailing delivery")

        state.isPlaying = false
        manager.handlePlaybackStateChanged(isPlaying: false, position: state.playbackAnchorPosition)
        XCTAssertEqual(publishedFrameCounts, [1], "trailing notification is still pending before deadline elapses")

        clock.advance(by: .milliseconds(250))
        let delivered = await waitUntil { publishedFrameCounts == [1, 3] }
        XCTAssertTrue(delivered, "post-pause deadline must deliver a new event exposing all 3 frames")
    }

    @MainActor
    func testLiveVocalEnvelopeRefreshesAtCapacityWhenFrameCountStaysConstant() async throws {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false

        let capture = FakeAudioCapture()
        let deps = makeDependencies(capture: capture, chunkDurationSeconds: 2000.0)
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        // Use a long track duration (> 20 min) so filling VocalEnvelope.maxFrames does not trigger final-chunk flush.
        let track = TrackInfo(id: "spotify:track:envelope-capacity", title: "Long Mix", artist: "Artist", album: "", duration: 3000.0, artworkURL: nil)
        state.setTrack(track, lyrics: tenLines())
        manager.handleTrackLoaded(track: track, rawLines: tenLines())
        let started = await waitUntil { capture.startCount == 1 }
        XCTAssertTrue(started)
        let trackId = track.id

        // At 100 Hz (1 sample per 0.01 s frame), VocalEnvelope.maxFrames samples fills the envelope to capacity.
        let fillSamples = [Float](repeating: 0.2, count: VocalEnvelope.maxFrames)
        capture.emit(samples: fillSamples, sampleRate: 100)
        let filled = await waitUntil { manager.bufferedSampleCount == VocalEnvelope.maxFrames }
        XCTAssertTrue(filled)
        let endAtCapacity = try XCTUnwrap(manager.vocalEnvelope(for: trackId)?.segments.last?.end)

        var notified = false
        let sub = manager.vocalEnvelopeDidChange.sink { id in
            if id == trackId { notified = true }
        }
        defer { sub.cancel() }

        // Appending 5 more frames trims 5 old frames so total frame count stays at maxFrames,
        // yet last segment's end advances and display cache + publisher must refresh.
        let extraSamples = [Float](repeating: 0.4, count: 5)
        capture.emit(samples: extraSamples, sampleRate: 100)
        let appended = await waitUntil { manager.bufferedSampleCount == VocalEnvelope.maxFrames + 5 }
        XCTAssertTrue(appended)
        let updatedEnd = try XCTUnwrap(manager.vocalEnvelope(for: trackId)?.segments.last?.end)
        XCTAssertGreaterThan(updatedEnd, endAtCapacity)
        let gotNotification = await waitUntil { notified }
        XCTAssertTrue(gotNotification)
    }

    @MainActor
    func testKeepingLockedAndAcceptedScalesManyInterveningBlanksBetweenLockedAndFreshLines() async throws {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false

        let track = TrackInfo(id: "spotify:track:many-blanks-bound", title: "ManyBlanks", artist: "Artist", album: "", duration: 60, artworkURL: nil)
        // Raw lyrics place line 1 at 9.0 s so alignHeardWords matches line 53 at 10.60 s;
        // the cached lock then restores line 1 late to 10.0..10.30 s, forcing keepingLockedAndAccepted
        // to fit 50 intervening blanks and unmatched line 52 inside [10.0, 10.60].
        var rawLines: [LyricLine] = [
            LyricLine(id: 0, timestamp: 5.0, text: "Opening line"),
            LyricLine(id: 1, timestamp: 9.0, text: "Locked line"),
        ]
        var cachedLines: [LyricLine] = [
            LyricLine(
                id: 0,
                timestamp: 5.0,
                duration: 1.0,
                text: "Opening line",
                words: [
                    WordTimestamp(timestamp: 5.0, duration: 0.5, text: "Opening "),
                    WordTimestamp(timestamp: 5.5, duration: 0.5, text: "line"),
                ]
            ),
            LyricLine(id: 1, timestamp: 10.0, duration: 0.30, text: "Locked line"),
        ]
        for blankOffset in 0..<50 {
            let id = 2 + blankOffset
            rawLines.append(LyricLine(id: id, timestamp: 9.10 + Double(blankOffset) * 0.002, text: ""))
            cachedLines.append(LyricLine(id: id, timestamp: 10.05 + Double(blankOffset) * 0.002, text: ""))
        }
        rawLines.append(LyricLine(id: 52, timestamp: 10.20, text: "Unmatched middle"))
        rawLines.append(LyricLine(id: 53, timestamp: 10.60, text: "Fresh match"))
        cachedLines.append(LyricLine(id: 52, timestamp: 10.40, text: "Unmatched middle"))
        cachedLines.append(LyricLine(id: 53, timestamp: 11.0, text: "Fresh match"))
        state.setTrack(track, lyrics: rawLines)

        let cache = AudioSyncedLyricsCache(directory: tempDir)
        cache.save(
            AudioSyncedLyricsRecord(
                trackId: track.id,
                engine: .lyricsAlignment,
                syncedAt: Date(),
                medianOffset: 0.0,
                alignedLineCount: 2,
                sourceLineCount: 4,
                lines: cachedLines,
                lockedLineIDs: [0, 1]
            )
        )

        let fakeCapture = FakeAudioCapture()
        let deps = makeDependencies(
            capture: fakeCapture,
            runChunk: { _ in
                [
                    RecognizedAudioWord(text: "fresh", startTime: 10.60, duration: 0.2, confidence: 0.95, sourceLineId: 53),
                    RecognizedAudioWord(text: "match", startTime: 10.85, duration: 0.2, confidence: 0.95, sourceLineId: 53),
                ]
            },
            chunkDurationSeconds: 1.0
        )
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: track, rawLines: rawLines)
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        fakeCapture.emit(samples: [Float](repeating: 0.2, count: 100), sampleRate: 100)
        let updated = await waitUntil { (cache.load(trackId: track.id)?.alignedLineCount ?? 0) >= 3 }
        XCTAssertTrue(updated)

        let saved = try XCTUnwrap(cache.load(trackId: track.id))
        XCTAssertTrue(saved.isReliable, "compressed intervening blanks must remain monotonic and reliable")
        for idx in 1..<saved.lines.count {
            XCTAssertGreaterThanOrEqual(saved.lines[idx].timestamp, saved.lines[idx - 1].timestamp)
        }
        XCTAssertEqual(saved.lines[1].timestamp, 10.0, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(saved.lines[52].timestamp, 10.15)
        XCTAssertLessThanOrEqual(saved.lines[52].timestamp, 10.451)
        XCTAssertEqual(saved.lines[53].timestamp, 10.60, accuracy: 0.001)
    }

    @MainActor
    func testStopCancelsPendingThrottledVocalEnvelopeNotificationAndSubFrameDeliverySkipsNotify() async throws {
        let clock = ControlledNotifyClock()
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false

        let capture = FakeAudioCapture()
        var deps = makeDependencies(capture: capture, chunkDurationSeconds: 12.0)
        deps.vocalEnvelopeNow = { clock.now() }
        deps.vocalEnvelopeSleep = { try await clock.sleep(until: $0) }
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        let track = sampleTrack()
        state.setTrack(track, lyrics: tenLines())
        manager.handleTrackLoaded(track: track, rawLines: tenLines())
        let started = await waitUntil { capture.startCount == 1 }
        XCTAssertTrue(started)

        var eventCount = 0
        let sub = manager.vocalEnvelopeDidChange.sink { _ in eventCount += 1 }
        defer { sub.cancel() }

        let fullFrame = [Float](repeating: 0.2, count: 10)
        capture.emit(samples: fullFrame, sampleRate: 1000)
        let firstReady = await waitUntil { manager.bufferedSampleCount == 10 }
        XCTAssertTrue(firstReady)
        XCTAssertEqual(eventCount, 1)

        // Sub-frame delivery produces no new drawable frame, so it must not schedule a notification.
        capture.emit(samples: [Float](repeating: 0.2, count: 5), sampleRate: 1000)
        let subFrameBuffered = await waitUntil { manager.bufferedSampleCount == 15 }
        XCTAssertTrue(subFrameBuffered)
        XCTAssertFalse(clock.hasPendingWaiter, "sub-frame delivery without a new frame must not schedule a trailing notify")
        clock.advance(by: .milliseconds(250))
        XCTAssertEqual(eventCount, 1)

        // Establish a guaranteed pending trailing notification on the controlled clock, then stop().
        capture.emit(samples: fullFrame, sampleRate: 1000)
        let secondReady = await waitUntil { manager.bufferedSampleCount == 25 }
        XCTAssertTrue(secondReady)
        capture.emit(samples: fullFrame, sampleRate: 1000)
        let pendingRegistered = await waitUntil { manager.bufferedSampleCount == 35 && clock.hasPendingWaiter }
        XCTAssertTrue(pendingRegistered)
        manager.stop()
        let countAfterStop = eventCount
        clock.advance(by: .milliseconds(250))
        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(eventCount, countAfterStop, "stop() must cancel any pending trailing envelope notification")
    }

    @MainActor
    func testPauseAndResumeRetainsEarlierVocalEnvelopeSegmentsForDisplay() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 5.0
        state.playbackAnchorDate = Date()
        state.isPlaying = false

        let track = TrackInfo(id: "spotify:track:envelope-resume", title: "Resume", artist: "Artist", album: "", duration: 60, artworkURL: nil)
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let deps = makeDependencies(capture: fakeCapture, chunkDurationSeconds: 10.0)
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        var envelopeEvents: [String] = []
        let sub = manager.vocalEnvelopeDidChange.sink { envelopeEvents.append($0) }
        defer { sub.cancel() }

        manager.handleTrackLoaded(track: track, rawLines: sampleLines())
        let startedFirst = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount == 1 }
        XCTAssertTrue(startedFirst)

        // Emit 0.5 s of 1000 Hz voice-band audio at t = 5.0 s.
        let sampleRate = 16000.0
        let halfSecondTone = (0..<8000).map { i in Float(sin(2.0 * .pi * 1000.0 * Double(i) / sampleRate)) * 0.4 }
        envelopeEvents.removeAll()
        fakeCapture.emit(samples: halfSecondTone, sampleRate: sampleRate)
        let capturedFirst = await waitUntil { manager.vocalEnvelope(for: track.id)?.segment(covering: 5.1...5.3) != nil }
        XCTAssertTrue(capturedFirst)
        XCTAssertTrue(envelopeEvents.contains(track.id), "vocalEnvelopeDidChange must publish when audio arrives")

        // Pause -> reload same track at t = 25.0 s -> emit second segment.
        state.playbackAnchorPosition = 25.0
        state.playbackAnchorDate = Date()
        manager.handleTrackLoaded(track: track, rawLines: sampleLines())
        let startedSecond = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount == 2 }
        XCTAssertTrue(startedSecond)

        fakeCapture.emit(samples: halfSecondTone, sampleRate: sampleRate)
        let capturedSecond = await waitUntil { manager.vocalEnvelope(for: track.id)?.segment(covering: 25.1...25.3) != nil }
        XCTAssertTrue(capturedSecond)

        // Display envelope retains pre-pause segment AND new live segment, even after stop().
        XCTAssertNotNil(manager.vocalEnvelope(for: track.id)?.segment(covering: 5.1...5.3))
        XCTAssertNotNil(manager.vocalEnvelope(for: track.id)?.segment(covering: 25.1...25.3))
        manager.stop()
        XCTAssertNotNil(manager.vocalEnvelope(for: track.id)?.segment(covering: 5.1...5.3))
        XCTAssertNotNil(manager.vocalEnvelope(for: track.id)?.segment(covering: 25.1...25.3))
    }

    @MainActor
    func testKeepingLockedAndAcceptedBoundsFallbackBetweenAuthoritativeLinesAndResolvesTightConflicts() async throws {
        // Case 1: Cached lock restores A to 13..14 s, B is unmatched at 12 s, and C freshly matches at 13.2 s
        // (leaving < 0.30 s for intervening non-empty B). C must yield so published and cached lines stay monotonic.
        do {
            let state = LyricsState(userDefaults: defaults)
            state.audioSyncEngine = .lyricsAlignment
            state.playbackAnchorPosition = 12.0
            state.playbackAnchorDate = Date()
            state.isPlaying = false

            let track = TrackInfo(id: "spotify:track:bound-conflict", title: "Conflict", artist: "Artist", album: "", duration: 60, artworkURL: nil)
            let rawLines = [
                LyricLine(id: 0, timestamp: 5.0, text: "Zero anchor"),
                LyricLine(id: 1, timestamp: 11.0, text: "Locked alpha"),
                LyricLine(id: 2, timestamp: 12.0, text: "Unmatched beta"),
                LyricLine(id: 3, timestamp: 14.0, text: "Fresh gamma"),
                LyricLine(id: 4, timestamp: 20.0, text: "Tail delta"),
            ]
            state.setTrack(track, lyrics: rawLines)

            let cache = AudioSyncedLyricsCache(directory: tempDir)
            cache.save(
                AudioSyncedLyricsRecord(
                    trackId: track.id,
                    engine: .lyricsAlignment,
                    syncedAt: Date(),
                    medianOffset: 0.0,
                    alignedLineCount: 2,
                    sourceLineCount: 5,
                    lines: [
                        LyricLine(
                            id: 0,
                            timestamp: 5.0,
                            duration: 1.0,
                            text: "Zero anchor",
                            words: [
                                WordTimestamp(timestamp: 5.0, duration: 0.5, text: "Zero "),
                                WordTimestamp(timestamp: 5.5, duration: 0.5, text: "anchor"),
                            ]
                        ),
                        LyricLine(id: 1, timestamp: 13.0, duration: 1.0, text: "Locked alpha"),
                        LyricLine(id: 2, timestamp: 14.0, text: "Unmatched beta"),
                        LyricLine(id: 3, timestamp: 14.5, text: "Fresh gamma"),
                        LyricLine(id: 4, timestamp: 20.0, text: "Tail delta"),
                    ],
                    lockedLineIDs: [0, 1]
                )
            )

            let fakeCapture = FakeAudioCapture()
            let deps = makeDependencies(
                capture: fakeCapture,
                runChunk: { _ in
                    [
                        RecognizedAudioWord(text: "fresh", startTime: 13.2, duration: 0.2, confidence: 0.95, sourceLineId: 3),
                        RecognizedAudioWord(text: "gamma", startTime: 13.45, duration: 0.2, confidence: 0.95, sourceLineId: 3),
                        RecognizedAudioWord(text: "tail", startTime: 20.0, duration: 0.3, confidence: 0.95, sourceLineId: 4),
                        RecognizedAudioWord(text: "delta", startTime: 20.4, duration: 0.3, confidence: 0.95, sourceLineId: 4),
                    ]
                },
                chunkDurationSeconds: 1.0
            )
            let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
            manager.handleTrackLoaded(track: track, rawLines: rawLines)
            let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
            XCTAssertTrue(started)

            fakeCapture.emit(samples: [Float](repeating: 0.2, count: 100), sampleRate: 100)
            let updated = await waitUntil { (cache.load(trackId: track.id)?.alignedLineCount ?? 0) >= 3 }
            XCTAssertTrue(updated)

            let saved = try XCTUnwrap(cache.load(trackId: track.id))
            XCTAssertTrue(saved.isReliable, "conflicting fresh match C must be resolved before saving")
            XCTAssertEqual(saved.lines[1].timestamp, 13.0, accuracy: 0.01)
            XCTAssertGreaterThanOrEqual(saved.lines[2].timestamp, saved.lines[1].timestamp + 0.15)
            XCTAssertGreaterThanOrEqual(saved.lines[3].timestamp, saved.lines[2].timestamp + 0.15)
            XCTAssertEqual(state.rawLyricLines[2].timestamp, saved.lines[2].timestamp, accuracy: 0.01)
            XCTAssertEqual(state.rawLyricLines[3].timestamp, saved.lines[3].timestamp, accuracy: 0.01)
            manager.stop()
        }

        // Case 2: Cached lock restores A to 13..14 s, B is unmatched at 12 s, and C freshly matches at 13.5 s
        // (valid room >= 0.30 s). B must fit inside [13.15, 13.35] and A's held tail must trim to B.
        do {
            let state = LyricsState(userDefaults: defaults)
            state.audioSyncEngine = .lyricsAlignment
            state.playbackAnchorPosition = 12.0
            state.playbackAnchorDate = Date()
            state.isPlaying = false

            let track = TrackInfo(id: "spotify:track:bound-tight-valid", title: "TightValid", artist: "Artist", album: "", duration: 60, artworkURL: nil)
            let rawLines = [
                LyricLine(id: 0, timestamp: 5.0, text: "Zero anchor"),
                LyricLine(id: 1, timestamp: 11.0, text: "Locked alpha"),
                LyricLine(id: 2, timestamp: 12.0, text: "Unmatched beta"),
                LyricLine(id: 3, timestamp: 14.0, text: "Fresh gamma"),
                LyricLine(id: 4, timestamp: 20.0, text: "Tail delta"),
            ]
            state.setTrack(track, lyrics: rawLines)

            let cache = AudioSyncedLyricsCache(directory: tempDir)
            cache.save(
                AudioSyncedLyricsRecord(
                    trackId: track.id,
                    engine: .lyricsAlignment,
                    syncedAt: Date(),
                    medianOffset: 0.0,
                    alignedLineCount: 2,
                    sourceLineCount: 5,
                    lines: [
                        LyricLine(
                            id: 0,
                            timestamp: 5.0,
                            duration: 1.0,
                            text: "Zero anchor",
                            words: [
                                WordTimestamp(timestamp: 5.0, duration: 0.5, text: "Zero "),
                                WordTimestamp(timestamp: 5.5, duration: 0.5, text: "anchor"),
                            ]
                        ),
                        LyricLine(id: 1, timestamp: 13.0, duration: 1.0, text: "Locked alpha"),
                        LyricLine(id: 2, timestamp: 14.0, text: "Unmatched beta"),
                        LyricLine(id: 3, timestamp: 14.5, text: "Fresh gamma"),
                        LyricLine(id: 4, timestamp: 20.0, text: "Tail delta"),
                    ],
                    lockedLineIDs: [0, 1]
                )
            )

            let fakeCapture = FakeAudioCapture()
            let deps = makeDependencies(
                capture: fakeCapture,
                runChunk: { _ in
                    [
                        RecognizedAudioWord(text: "fresh", startTime: 13.5, duration: 0.2, confidence: 0.95, sourceLineId: 3),
                        RecognizedAudioWord(text: "gamma", startTime: 13.75, duration: 0.2, confidence: 0.95, sourceLineId: 3),
                    ]
                },
                chunkDurationSeconds: 1.0
            )
            let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
            manager.handleTrackLoaded(track: track, rawLines: rawLines)
            let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
            XCTAssertTrue(started)

            fakeCapture.emit(samples: [Float](repeating: 0.2, count: 100), sampleRate: 100)
            let updated = await waitUntil { (cache.load(trackId: track.id)?.alignedLineCount ?? 0) >= 3 }
            XCTAssertTrue(updated)

            let saved = try XCTUnwrap(cache.load(trackId: track.id))
            XCTAssertTrue(saved.isReliable)
            XCTAssertEqual(saved.lines[1].timestamp, 13.0, accuracy: 0.01)
            XCTAssertEqual(saved.lines[2].timestamp, 13.35, accuracy: 0.01)
            XCTAssertEqual(saved.lines[3].timestamp, 13.5, accuracy: 0.01)
            XCTAssertLessThanOrEqual(saved.lines[1].timestamp + (saved.lines[1].duration ?? 0), 13.36)
            manager.stop()
        }
    }

    func testBoundaryReconciliationCannotLockAnErasedMatchedWord() {
        let matched = LyricLine(id: 0, timestamp: 10.0, duration: 6.0, text: "Alpha beta gamma", words: [
            WordTimestamp(timestamp: 10.0, duration: 0.5, text: "Alpha "),
            WordTimestamp(timestamp: 12.5, duration: 0.5, text: "beta "),
            WordTimestamp(timestamp: 15.1, duration: 0.6, text: "gamma"),
        ])
        let envelope = VocalEnvelope()
        XCTAssertTrue(AudioSyncManager.locks(matched, confident: [0], nearlyConfident: [], envelope: envelope))

        var collapsed = [matched, LyricLine(id: 1, timestamp: 15.0, text: "Legacy lock")]
        LyricsAudioAligner.reconcilePrecedingBoundary(in: &collapsed, before: 1, targetStart: 15.0)
        XCTAssertEqual(collapsed[0].words.last?.duration, 0)
        XCTAssertFalse(AudioSyncManager.locks(collapsed[0], confident: [0], nearlyConfident: [], envelope: envelope))

        var shortened = [matched, LyricLine(id: 1, timestamp: 15.4, text: "Later lock")]
        LyricsAudioAligner.reconcilePrecedingBoundary(in: &shortened, before: 1, targetStart: 15.4)
        XCTAssertEqual(shortened[0].words.last?.duration ?? 0, 0.3, accuracy: 0.001)
        XCTAssertTrue(AudioSyncManager.locks(shortened[0], confident: [0], nearlyConfident: [], envelope: envelope))

        let withLeadingPunctuation = LyricLine(id: 0, timestamp: 9.9, duration: 1.2, text: "— Alpha beta", words: [
            WordTimestamp(timestamp: 9.9, duration: 0, text: "— "),
            WordTimestamp(timestamp: 10.0, duration: 0.4, text: "Alpha "),
            WordTimestamp(timestamp: 10.6, duration: 0.4, text: "beta"),
        ])
        XCTAssertTrue(AudioSyncManager.locks(withLeadingPunctuation, confident: [0], nearlyConfident: [], envelope: envelope))
    }

    @MainActor
    func testNewLockPersistsAndAppliesEvenWhenDisplacingMultipleUnlockedCachedLines() async throws {
        let track = sampleTrack()
        let rawLines = [
            LyricLine(id: 0, timestamp: 10.0, text: "Alpha first"),
            LyricLine(id: 1, timestamp: 14.0, text: "Beta second"),
            LyricLine(id: 2, timestamp: 18.0, text: "Gamma third"),
            LyricLine(id: 3, timestamp: 22.0, text: "Delta fourth"),
        ]
        // Seed cache with 1 locked line (id 0) and 3 unlocked aligned lines (ids 1, 2, 3),
        // where unlocked lines 2 and 3 sit at 15.0 s and 15.3 s (both will conflict with line 1 at 16.0 s).
        let cachedLines = [
            LyricLine(
                id: 0, timestamp: 10.0, duration: 1.0, text: "Alpha first",
                words: [
                    WordTimestamp(timestamp: 10.0, duration: 0.4, text: "Alpha "),
                    WordTimestamp(timestamp: 10.5, duration: 0.5, text: "first"),
                ]
            ),
            LyricLine(
                id: 1, timestamp: 14.0, duration: 0.8, text: "Beta second",
                words: [
                    WordTimestamp(timestamp: 14.0, duration: 0.3, text: "Beta "),
                    WordTimestamp(timestamp: 14.4, duration: 0.4, text: "second"),
                ]
            ),
            LyricLine(
                id: 2, timestamp: 15.0, duration: 0.25, text: "Gamma third",
                words: [
                    WordTimestamp(timestamp: 15.0, duration: 0.1, text: "Gamma "),
                    WordTimestamp(timestamp: 15.15, duration: 0.1, text: "third"),
                ]
            ),
            LyricLine(
                id: 3, timestamp: 15.3, duration: 0.25, text: "Delta fourth",
                words: [
                    WordTimestamp(timestamp: 15.3, duration: 0.1, text: "Delta "),
                    WordTimestamp(timestamp: 15.45, duration: 0.1, text: "fourth"),
                ]
            ),
        ]
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        cache.save(AudioSyncedLyricsRecord(
            trackId: track.id,
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: 0,
            alignedLineCount: 4,
            sourceLineCount: 4,
            lines: cachedLines,
            heardWords: nil,
            lockedLineIDs: [0],
            attemptedLineIDs: [],
            lockedAtPlayStart: 1
        ))

        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 16.0
        state.playbackAnchorDate = Date()
        let fakeCapture = FakeAudioCapture()
        let freshLine1Words = [
            RecognizedAudioWord(text: "Beta", startTime: 16.0, duration: 0.3, confidence: 0.95, sourceLineId: 1),
            RecognizedAudioWord(text: "second", startTime: 16.4, duration: 0.4, confidence: 0.95, sourceLineId: 1),
        ]
        var deps = makeDependencies(capture: fakeCapture)
        deps.chunkDurationSeconds = 1.0
        deps.launchLyricsAligner = { _, _ in
            FakeChunkEngine(confident: [1]) { _ in freshLine1Words }
        }

        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: track, rawLines: rawLines)
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        // Fresh confident line 1 at 16.0 s displaces both unlocked lines 2 (15.0 s) and 3 (15.3 s),
        // dropping matchedLineCount from 4 down to 2 (< cachedAlignedLineCount).
        fakeCapture.emit(samples: [Float](repeating: 0.2, count: 100), sampleRate: 100)
        let lockPersisted = await waitUntil {
            (cache.load(trackId: track.id)?.lockedLineIDs ?? []).contains(1)
        }
        XCTAssertTrue(lockPersisted, "new confident lock must persist even when displacing unlocked lines lowers matchedLineCount")

        let saved = try XCTUnwrap(cache.load(trackId: track.id))
        XCTAssertEqual(saved.lockedLineIDs, [0, 1])
        XCTAssertEqual(saved.alignedLineCount, 2)
        XCTAssertEqual(saved.lines[1].timestamp, 16.0, accuracy: 0.01)
        XCTAssertEqual(state.rawLyricLines[1].timestamp, 16.0, accuracy: 0.01)
        manager.stop()
    }

    @MainActor
    func testMonotonicityPrecomputationHandlesSparseMatchesAcrossLongTrack() async throws {
        let track = sampleTrack()
        // 120 rows mixing non-empty lines and blank markers with only two sparse matched lines.
        var rawLines: [LyricLine] = []
        for idx in 0..<120 {
            let text = (idx % 5 == 4) ? "" : "Line \(idx) sample words"
            rawLines.append(LyricLine(id: idx, timestamp: Double(idx) * 1.5, text: text))
        }
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 0.0
        state.playbackAnchorDate = Date()
        let fakeCapture = FakeAudioCapture()
        let sparseWords = [
            RecognizedAudioWord(text: "Line", startTime: 3.0, duration: 0.2, confidence: 0.95, sourceLineId: 2),
            RecognizedAudioWord(text: "2", startTime: 3.25, duration: 0.2, confidence: 0.95, sourceLineId: 2),
            RecognizedAudioWord(text: "sample", startTime: 3.5, duration: 0.2, confidence: 0.95, sourceLineId: 2),
            RecognizedAudioWord(text: "words", startTime: 3.75, duration: 0.2, confidence: 0.95, sourceLineId: 2),
            RecognizedAudioWord(text: "Line", startTime: 147.5, duration: 0.2, confidence: 0.95, sourceLineId: 100),
            RecognizedAudioWord(text: "100", startTime: 147.75, duration: 0.2, confidence: 0.95, sourceLineId: 100),
            RecognizedAudioWord(text: "sample", startTime: 148.0, duration: 0.2, confidence: 0.95, sourceLineId: 100),
            RecognizedAudioWord(text: "words", startTime: 148.25, duration: 0.2, confidence: 0.95, sourceLineId: 100),
        ]
        var deps = makeDependencies(capture: fakeCapture)
        deps.chunkDurationSeconds = 1.0
        deps.launchLyricsAligner = { _, _ in
            FakeChunkEngine(confident: [2, 100]) { _ in sparseWords }
        }

        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: track, rawLines: rawLines)
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)

        fakeCapture.emit(samples: [Float](repeating: 0.2, count: 100), sampleRate: 100)
        let updated = await waitUntil { (cache.load(trackId: track.id)?.alignedLineCount ?? 0) >= 2 }
        XCTAssertTrue(updated)

        let saved = try XCTUnwrap(cache.load(trackId: track.id))
        XCTAssertEqual(saved.lines[2].timestamp, 3.0, accuracy: 0.01)
        XCTAssertEqual(saved.lines[100].timestamp, 147.5, accuracy: 0.01)
        XCTAssertLessThan(saved.lines[99].timestamp, 147.5, "intervening blank/fallback rows must clamp below the early matched anchor")
        for idx in 1..<saved.lines.count {
            XCTAssertGreaterThanOrEqual(
                saved.lines[idx].timestamp,
                saved.lines[idx - 1].timestamp,
                "Row \(idx) must stay monotonic against row \(idx - 1)"
            )
        }
        manager.stop()
    }

    func testAudioCaptureBatcherCoalescesContiguousBuffersAndFlushesOnGapOrFormatChange() throws {
        var batcher = AudioCaptureBatcher(targetDuration: 0.20)
        var emitted: [CapturedAudio] = []
        // Ten contiguous 20 ms stereo buffers at 16 kHz (320 samples each) coalesce into one 200 ms batch.
        for i in 0..<10 {
            let start = 100.0 + Double(i) * 0.02
            let mid = [Float](repeating: Float(i + 1) * 0.01, count: 320)
            let side = [Float](repeating: 0.005, count: 320)
            emitted.append(contentsOf: batcher.append(CapturedAudio(
                samples: mid,
                side: side,
                sampleRate: 16000,
                captureDelay: 0.03,
                capturedAt: start
            ), deliveryUptime: start + 0.03))
        }
        XCTAssertEqual(emitted.count, 1)
        let firstBatch = try XCTUnwrap(emitted.first)
        XCTAssertEqual(firstBatch.samples.count, 3200)
        XCTAssertEqual(firstBatch.side.count, 3200)
        XCTAssertEqual(try XCTUnwrap(firstBatch.capturedAt), 100.0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(firstBatch.captureDelay), 0.21, accuracy: 0.0001)

        // A partial buffer followed by a >50 ms timing gap flushes the prior partial buffer immediately.
        XCTAssertTrue(batcher.append(CapturedAudio(
            samples: [Float](repeating: 0.1, count: 320),
            side: [Float](repeating: 0.0, count: 320),
            sampleRate: 16000,
            captureDelay: 0.02,
            capturedAt: 100.20
        )).isEmpty)
        let gapFlushed = batcher.append(CapturedAudio(
            samples: [Float](repeating: 0.2, count: 320),
            side: [Float](repeating: 0.0, count: 320),
            sampleRate: 16000,
            captureDelay: 0.02,
            capturedAt: 100.50
        ), deliveryUptime: 100.52)
        XCTAssertEqual(gapFlushed.count, 1)
        XCTAssertEqual(gapFlushed[0].samples.count, 320)
        XCTAssertEqual(try XCTUnwrap(gapFlushed[0].capturedAt), 100.20, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(gapFlushed[0].captureDelay), 0.32, accuracy: 0.0001)

        // A mono/sample-rate switch flushes the buffered stereo chunk before starting the new format.
        let formatFlushed = batcher.append(CapturedAudio(
            samples: [Float](repeating: 0.3, count: 320),
            side: [],
            sampleRate: 48000,
            captureDelay: 0.01,
            capturedAt: 100.52
        ))
        XCTAssertEqual(formatFlushed.count, 1)
        XCTAssertEqual(formatFlushed[0].sampleRate, 16000)
        XCTAssertEqual(formatFlushed[0].side.count, 320)

        let remaining = try XCTUnwrap(batcher.flush())
        XCTAssertEqual(remaining.sampleRate, 48000)
        XCTAssertTrue(remaining.side.isEmpty)
        XCTAssertNil(batcher.flush())
    }

    func testStreamConfigurationMinimizesVideoFrameWork() {
        let config = SystemAudioCapture.makeStreamConfiguration()
        XCTAssertTrue(config.capturesAudio)
        XCTAssertTrue(config.excludesCurrentProcessAudio)
        XCTAssertEqual(config.sampleRate, 16000)
        XCTAssertEqual(config.channelCount, 2)
        XCTAssertFalse(config.showsCursor)
        XCTAssertEqual(config.queueDepth, 3)
        XCTAssertGreaterThanOrEqual(config.minimumFrameInterval.seconds, 60.0)
        let isolation = SystemAudioCapture.makeStreamConfiguration(sampleRate: 48000)
        XCTAssertEqual(isolation.sampleRate, 48000)
        XCTAssertEqual(isolation.channelCount, 2)
    }

    @MainActor
    func testVocalIsolationFeedsStemToAlignmentAndEnvelopeAndReleasesModelWhenIdle() async throws {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.isolateVocals = true
        let capture = FakeAudioCapture()
        let request = LockedBox<AudioSyncManager.AudioChunkRequest?>(nil)
        let releaseCount = LockedBox(0)
        let separator = RightChannelVocalSeparator()
        let clock = ControlledNotifyClock()
        var deps = makeDependencies(capture: capture, runChunk: { input in
            request.withLock { $0 = input }
            return []
        }, chunkDurationSeconds: 1)
        deps.launchVocalSeparator = { separator }
        deps.releaseCachedVocalSeparator = { releaseCount.withLock { $0 += 1 } }
        deps.idleModelReleaseSleep = { delay in
            try await clock.sleep(until: clock.now().advanced(by: delay))
        }
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        defer { manager.stop() }

        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { capture.startCount == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(capture.lastSampleRate, 48000)

        // Only the left channel carries music. The fake separator uses the silent right channel as the stem.
        let halfSecond = [Float](repeating: 0.3, count: 24000)
        for _ in 0..<2 {
            capture.emit(samples: halfSecond, sampleRate: 48000, side: halfSecond)
        }
        let processed = await waitUntil { manager.diagnostics.snapshot?.resultCount == 1 }
        XCTAssertTrue(processed)

        let recognized = try XCTUnwrap(request.withLock { $0 })
        XCTAssertEqual(recognized.sampleRate, 16000)
        XCTAssertEqual(recognized.samples.count, 16000)
        XCTAssertLessThan(recognized.samples.map(abs).max() ?? 1, 0.0001)
        let segment = try XCTUnwrap(manager.vocalEnvelope.segments.first)
        XCTAssertEqual(segment.levels.count, 100)
        XCTAssertEqual(segment.maxPeaks.max(), 0)
        XCTAssertEqual(separator.priority.withLock { $0 }, .background)
        let diagnostics = try XCTUnwrap(manager.diagnostics.snapshot)
        XCTAssertEqual(diagnostics.captureSampleRate, 48000)
        XCTAssertGreaterThan(try XCTUnwrap(diagnostics.vocalSeparationSeconds), 0)
        XCTAssertTrue(diagnostics.report().contains("Capture sample rate: 48000 Hz"))
        XCTAssertTrue(diagnostics.report().contains("per chunk"))

        manager.stop()
        let timerArmed = await waitUntil { clock.hasPendingWaiter }
        XCTAssertTrue(timerArmed)
        XCTAssertEqual(releaseCount.withLock { $0 }, 0)
        clock.advance(by: .seconds(60))
        let released = await waitUntil { releaseCount.withLock { $0 == 1 } }
        XCTAssertTrue(released)
    }

    @MainActor
    func testChunkInferenceRunsAtBackgroundPriority() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.playbackAnchorPosition = 10.0
        state.playbackAnchorDate = Date()
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let observedPriority = LockedBox<TaskPriority?>(nil)
        var deps = makeDependencies(capture: fakeCapture, chunkDurationSeconds: 1.0)
        deps.launchVocalSeparator = {
            XCTFail("The separator must load only when isolation is enabled")
            return nil
        }
        deps.launchLyricsAligner = { _, _ in
            FakeChunkEngine { _ in
                observedPriority.withLock { $0 = Task.currentPriority }
                return []
            }
        }
        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { manager.isLiveSyncActive && fakeCapture.startCount > 0 }
        XCTAssertTrue(started)
        XCTAssertEqual(fakeCapture.lastSampleRate, 16000)

        fakeCapture.emit(samples: [Float](repeating: 0.2, count: 100), sampleRate: 100)
        let ran = await waitUntil { observedPriority.withLock { $0 != nil } }
        XCTAssertTrue(ran)
        XCTAssertEqual(observedPriority.withLock { $0 }, .background)
        manager.stop()
    }

    @MainActor
    func testVocalIsolationWithMissingModelAlignsFullMix() async throws {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.isolateVocals = true
        let capture = FakeAudioCapture()
        let request = LockedBox<AudioSyncManager.AudioChunkRequest?>(nil)
        var deps = makeDependencies(capture: capture, runChunk: { input in
            request.withLock { $0 = input }
            return []
        }, chunkDurationSeconds: 1)
        deps.launchVocalSeparator = { nil }
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        defer { manager.stop() }

        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { capture.startCount == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(capture.lastSampleRate, 48000)

        let audio = [Float](repeating: 0.3, count: 48000)
        capture.emit(samples: audio, sampleRate: 48000, side: audio)
        let processed = await waitUntil { manager.diagnostics.snapshot?.resultCount == 1 }
        XCTAssertTrue(processed)
        let recognized = try XCTUnwrap(request.withLock { $0 })
        XCTAssertEqual(recognized.sampleRate, 16000)
        XCTAssertEqual(recognized.samples.count, 16000)
        XCTAssertGreaterThan(try XCTUnwrap(recognized.samples.dropFirst(8000).first), 0.5)
        let segment = try XCTUnwrap(manager.vocalEnvelope.segments.first)
        XCTAssertEqual(try XCTUnwrap(segment.maxPeaks.dropFirst(50).first), 0.6, accuracy: 0.01)
        XCTAssertNil(manager.diagnostics.snapshot?.vocalSeparationSeconds)
    }

    @MainActor
    func testFailed48kHzResamplingStopsAlignmentWithoutSendingTheChunk() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.isolateVocals = true
        let capture = FakeAudioCapture()
        let requests = LockedBox<[Int]>([])
        let attemptedConversion = LockedBox(false)
        var deps = makeDependencies(capture: capture, runChunk: { request in
            requests.withLock { $0.append(request.sampleRate) }
            return []
        }, chunkDurationSeconds: 1)
        deps.launchVocalSeparator = { nil }
        deps.resampleForRecognition = { _, source, target in
            attemptedConversion.withLock { $0 = source == 48000 && target == 16000 }
            return nil
        }
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        defer { manager.stop() }
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { capture.startCount == 1 }
        XCTAssertTrue(started)

        capture.emit(samples: [Float](repeating: 0.3, count: 48000), sampleRate: 48000)
        let finished = await waitUntil { !manager.isLiveSyncActive || !requests.withLock { $0.isEmpty } }
        XCTAssertTrue(finished)
        XCTAssertTrue(attemptedConversion.withLock { $0 })
        XCTAssertTrue(requests.withLock { $0.isEmpty })
        XCTAssertFalse(manager.isLiveSyncActive)
        guard case let .unavailable(message) = state.audioSyncStatus else {
            XCTFail("Expected the resampling failure to be surfaced")
            return
        }
        XCTAssertTrue(message.contains("resample"))
    }

    @MainActor
    func testStoppingBeforeFirstIsolatedChunkCachesStereoFullMixWaveform() async throws {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.isolateVocals = true
        let capture = FakeAudioCapture()
        var deps = makeDependencies(capture: capture, runChunk: { _ in
            XCTFail("A five-second preview should not dispatch a chunk")
            return []
        })
        deps.launchVocalSeparator = { RightChannelVocalSeparator() }
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        let track = sampleTrack()
        manager.handleTrackLoaded(track: track, rawLines: sampleLines())
        let started = await waitUntil { capture.startCount == 1 }
        XCTAssertTrue(started)

        let samples = [Float](repeating: 0.3, count: 5 * 48000)
        capture.emit(samples: samples, sampleRate: 48000, side: samples)
        let buffered = await waitUntil { manager.bufferedSampleCount == samples.count }
        XCTAssertTrue(buffered)
        manager.stop()
        let next = TrackInfo(id: "spotify:track:next", title: "Next", artist: "", album: "", duration: 120, artworkURL: nil)
        manager.handleTrackLoaded(track: next, rawLines: [])

        let segment = try XCTUnwrap(manager.vocalEnvelope(for: track.id)?.segments.first)
        XCTAssertEqual(segment.levels.count, 500)
        XCTAssertEqual(try XCTUnwrap(segment.maxPeaks.dropFirst(250).first), 0.6, accuracy: 0.01)
    }

    @MainActor
    func testSeparatedWaveformAndBufferedFullMixSurviveTranscriptionFailure() async throws {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.isolateVocals = true
        let capture = FakeAudioCapture()
        var deps = makeDependencies(capture: capture, launchAligner: { _, _ in
            FakeChunkEngine { _ in throw FakeChunkEngineError.exited }
        }, chunkDurationSeconds: 1)
        deps.launchVocalSeparator = { RightChannelVocalSeparator() }
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        let track = sampleTrack()
        manager.handleTrackLoaded(track: track, rawLines: sampleLines())
        let started = await waitUntil { capture.startCount == 1 }
        XCTAssertTrue(started)

        let samples = [Float](repeating: 0.3, count: 72000)
        capture.emit(samples: samples, sampleRate: 48000, side: samples)
        let stopped = await waitUntil { !manager.isLiveSyncActive }
        XCTAssertTrue(stopped)
        let next = TrackInfo(id: "spotify:track:next", title: "Next", artist: "", album: "", duration: 120, artworkURL: nil)
        manager.handleTrackLoaded(track: next, rawLines: [])

        let segment = try XCTUnwrap(manager.vocalEnvelope(for: track.id)?.segments.first)
        XCTAssertEqual(segment.levels.count, 150)
        XCTAssertEqual(try XCTUnwrap(segment.maxPeaks.dropFirst(50).first), 0, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(segment.maxPeaks.dropFirst(125).first), 0.6, accuracy: 0.01)
    }

    @MainActor
    func testMonoDeliveryKeepsCurrentChunkAndIsolationResumesWithNextStereoChunk() async throws {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        state.isolateVocals = true
        let capture = FakeAudioCapture()
        let peaks = LockedBox<[Float]>([])
        let receivedChunks = expectation(description: "Recognizer receives two consecutive chunks")
        receivedChunks.expectedFulfillmentCount = 2
        var deps = makeDependencies(capture: capture, runChunk: { input in
            peaks.withLock { $0.append(input.samples.map(abs).max() ?? 0) }
            receivedChunks.fulfill()
            return []
        }, chunkDurationSeconds: 1)
        deps.launchVocalSeparator = { RightChannelVocalSeparator() }
        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        defer { manager.stop() }

        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started = await waitUntil { capture.startCount == 1 }
        XCTAssertTrue(started)

        let quarterSecond = [Float](repeating: 0.3, count: 12000)
        capture.emit(samples: quarterSecond, sampleRate: 48000, side: quarterSecond)
        let bufferedStereo = await waitUntil { manager.bufferedSampleCount == 12000 }
        XCTAssertTrue(bufferedStereo)
        capture.emit(samples: quarterSecond, sampleRate: 48000)
        let bufferedBoth = await waitUntil { manager.bufferedSampleCount == 24000 }
        XCTAssertTrue(bufferedBoth)
        let stereo = [Float](repeating: 0.3, count: 72000)
        capture.emit(samples: stereo, sampleRate: 48000, side: stereo)

        await fulfillment(of: [receivedChunks], timeout: 10)
        let recognizedPeaks = peaks.withLock { $0 }
        XCTAssertGreaterThan(try XCTUnwrap(recognizedPeaks.first), 0.5)
        XCTAssertLessThan(try XCTUnwrap(recognizedPeaks.dropFirst().first), 0.0001)
        let processed = await waitUntil { manager.diagnostics.snapshot?.resultCount == 2 }
        XCTAssertTrue(processed)
        XCTAssertEqual(manager.vocalEnvelope.segments.count, 1)
        let segment = try XCTUnwrap(manager.vocalEnvelope.segments.first)
        XCTAssertEqual(segment.levels.count, 200)
        XCTAssertGreaterThan(try XCTUnwrap(segment.maxPeaks.dropFirst(75).first), 0.5)
        XCTAssertEqual(try XCTUnwrap(segment.maxPeaks.dropFirst(125).first), 0, accuracy: 0.0001)
        XCTAssertNotNil(manager.vocalEnvelope.onsetRise(at: segment.start + 1))
    }

    @MainActor
    func testIdleModelReleaseFiresAfterStopAndCancelsWhenNextTrackStartsSyncing() async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let fakeCapture = FakeAudioCapture()
        let releaseCount = LockedBox<Int>(0)
        let clock = ControlledNotifyClock()
        let cancellations = LockedBox(0)

        var deps = makeDependencies(capture: fakeCapture)
        deps.releaseCachedModel = { releaseCount.withLock { $0 += 1 } }
        deps.idleModelReleaseSleep = { delay in
            try await withTaskCancellationHandler {
                try await clock.sleep(until: clock.now().advanced(by: delay))
            } onCancel: {
                cancellations.withLock { $0 += 1 }
            }
        }

        let manager = AudioSyncManager(state: state, cache: cache, dependencies: deps)
        let track2 = TrackInfo(id: "spotify:track:idle-2", title: "Two", artist: "A", album: "", duration: 120, artworkURL: nil)
        let track3 = TrackInfo(id: "spotify:track:idle-3", title: "Three", artist: "A", album: "", duration: 120, artworkURL: nil)

        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        let started1 = await waitUntil { fakeCapture.startCount == 1 }
        XCTAssertTrue(started1)
        manager.stop()
        let firstTimerArmed = await waitUntil { clock.hasPendingWaiter }
        XCTAssertTrue(firstTimerArmed)

        clock.advance(by: .seconds(59))
        let wordSynced = LyricLine(id: 0, timestamp: 0, text: "Already timed", words: [
            WordTimestamp(timestamp: 0, duration: 1, text: "Already "),
            WordTimestamp(timestamp: 1, duration: 1, text: "timed"),
        ])
        manager.handleTrackLoaded(track: track2, rawLines: [wordSynced])
        XCTAssertEqual(state.audioSyncStatus, .cached(.lyricsAlignment))
        XCTAssertTrue(clock.hasPendingWaiter)
        XCTAssertEqual(cancellations.withLock { $0 }, 0)

        manager.handleTrackLoaded(track: track3, rawLines: sampleLines())
        let started3 = await waitUntil { fakeCapture.startCount == 2 }
        XCTAssertTrue(started3)
        XCTAssertEqual(cancellations.withLock { $0 }, 1)
        XCTAssertFalse(clock.hasPendingWaiter)
        XCTAssertEqual(releaseCount.withLock { $0 }, 0)

        manager.stop()
        let finalTimerArmed = await waitUntil { clock.hasPendingWaiter }
        XCTAssertTrue(finalTimerArmed)
        clock.advance(by: .seconds(60))
        let released = await waitUntil { releaseCount.withLock { $0 == 1 } }
        XCTAssertTrue(released)
    }

    @MainActor
    func testLateCancelledAlignerStartupSchedulesAnotherIdleModelRelease() async {
        await checkLateCancelledStartup(startReplacement: false)
    }

    @MainActor
    func testLateCancelledAlignerStartupDoesNotReleaseActiveReplacement() async {
        await checkLateCancelledStartup(startReplacement: true)
    }

    @MainActor
    private func checkLateCancelledStartup(startReplacement: Bool) async {
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = .lyricsAlignment
        let capture = FakeAudioCapture()
        let clock = ControlledNotifyClock()
        let releaseCount = LockedBox(0)
        let staleEngine = FakeChunkEngine { _ in [] }
        let launchStarted = expectation(description: "First aligner launch started")
        let releaseLaunch = LockedBox<CheckedContinuation<Void, Never>?>(nil)
        let launchCount = LockedBox(0)
        var deps = makeDependencies(capture: capture, launchAligner: { _, _ in
            let count = launchCount.withLock { value -> Int in
                value += 1
                return value
            }
            if count == 1 {
                await withCheckedContinuation { continuation in
                    releaseLaunch.withLock { $0 = continuation }
                    launchStarted.fulfill()
                }
                return staleEngine
            }
            return FakeChunkEngine { _ in [] }
        })
        deps.releaseCachedModel = { releaseCount.withLock { $0 += 1 } }
        deps.idleModelReleaseSleep = { delay in
            try await clock.sleep(until: clock.now().advanced(by: delay))
        }

        let manager = AudioSyncManager(state: state, cache: AudioSyncedLyricsCache(directory: tempDir), dependencies: deps)
        manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines())
        await fulfillment(of: [launchStarted], timeout: 2)
        manager.stop()

        let firstTimerArmed = await waitUntil { clock.hasPendingWaiter }
        XCTAssertTrue(firstTimerArmed)
        clock.advance(by: .seconds(60))
        let firstReleaseFired = await waitUntil { releaseCount.withLock { $0 == 1 } }
        XCTAssertTrue(firstReleaseFired)

        if startReplacement {
            manager.handleTrackLoaded(track: sampleTrack(), rawLines: sampleLines(), forceResync: true)
            let replacementStarted = await waitUntil { manager.isLiveSyncActive }
            XCTAssertTrue(replacementStarted)
        }
        releaseLaunch.withLock { continuation in
            continuation?.resume()
            continuation = nil
        }
        let staleEngineShutDown = await waitUntil { staleEngine.shutdownCount == 1 }
        XCTAssertTrue(staleEngineShutDown)
        if startReplacement {
            XCTAssertFalse(clock.hasPendingWaiter)
            clock.advance(by: .seconds(60))
            XCTAssertEqual(releaseCount.withLock { $0 }, 1)
        } else {
            let secondTimerArmed = await waitUntil { clock.hasPendingWaiter }
            XCTAssertTrue(secondTimerArmed)
            clock.advance(by: .seconds(59))
            XCTAssertTrue(clock.hasPendingWaiter)
            XCTAssertEqual(releaseCount.withLock { $0 }, 1)
            clock.advance(by: .seconds(1))
            let secondReleaseFired = await waitUntil { releaseCount.withLock { $0 == 2 } }
            XCTAssertTrue(secondReleaseFired)
            XCTAssertEqual(capture.startCount, 0)
        }
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
        runChunk: @escaping @Sendable (AudioSyncManager.AudioChunkRequest) -> [RecognizedAudioWord] = { _ in [] },
        launchAligner: (@Sendable ([LyricLine], [Int: ClosedRange<Double>]) async -> AudioChunkTranscribing?)? = nil,
        chunkDurationSeconds: Double = 12.0
    ) -> AudioSyncManager.Dependencies {
        AudioSyncManager.Dependencies(
            capture: capture,
            hasScreenCaptureAccess: { hasScreenCaptureAccess },
            requestScreenCaptureAccess: {},
            chunkDurationSeconds: chunkDurationSeconds,
            launchLyricsAligner: launchAligner ?? { _, _ in FakeChunkEngine(transcribe: runChunk) }
        )
    }
}

private final class FakeAudioCapture: AudioCaptureProviding {
    var onAudioSamples: (@Sendable (CapturedAudio) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var lastTargetBundleIds: Set<String> = []
    private(set) var lastSampleRate: Int?
    private(set) var calls: [String] = []
    var startError: Error?

    @MainActor
    func start(targetBundleIds: Set<String>, sampleRate: Int) throws {
        startCount += 1
        calls.append("start")
        lastTargetBundleIds = targetBundleIds
        lastSampleRate = sampleRate
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

private final class RightChannelVocalSeparator: VocalIsolating {
    let priority = LockedBox<TaskPriority?>(nil)

    func vocals(left: [Float], right: [Float]) -> (left: [Float], right: [Float]) {
        priority.withLock { $0 = Task.currentPriority }
        return (right, right)
    }
}

private struct FakeCaptureError: Error {}

private enum FakeChunkEngineError: Error {
    case exited
}

/// Reports every line as aligned confidently unless `confident` says otherwise.
private final class FakeChunkEngine: AudioChunkTranscribing, LineAttemptReporting, @unchecked Sendable {
    private let handler: @Sendable (AudioSyncManager.AudioChunkRequest) throws -> [RecognizedAudioWord]
    private let shutdowns = LockedBox<Int>(0)
    let attemptedLineIDs: Set<Int>
    let confidentLineIDs: Set<Int>
    let nearlyConfidentLineIDs: Set<Int>

    var shutdownCount: Int { shutdowns.withLock { $0 } }

    init(
        attempted: Set<Int> = [],
        confident: Set<Int> = Set(0..<100),
        nearlyConfident: Set<Int> = [],
        transcribe handler: @escaping @Sendable (AudioSyncManager.AudioChunkRequest) throws -> [RecognizedAudioWord]
    ) {
        self.handler = handler
        attemptedLineIDs = attempted
        confidentLineIDs = confident
        nearlyConfidentLineIDs = nearlyConfident
    }

    // swiftlint:disable:next async_without_await
    func transcribe(_ request: AudioSyncManager.AudioChunkRequest) async throws -> [RecognizedAudioWord] {
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

    private let output: AudioCaptureStreamOutput
    private let audioQueue: DispatchQueue

    init(includedApplications: [CaptureApplication], output: AudioCaptureStreamOutput, audioQueue: DispatchQueue) {
        self.output = output
        self.audioQueue = audioQueue
        capturedBundleIds = Set(includedApplications.map(\.bundleIdentifier))
    }

    func emit(_ audio: CapturedAudio) {
        audioQueue.sync { output.append(audio) }
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
        output: AudioCaptureStreamOutput,
        audioQueue: DispatchQueue,
        sampleRate: Int
    ) async -> SystemAudioStreamControlling {
        await Task.yield()
        onStartStream?()
        let stream = FakeSystemAudioStream(includedApplications: includedApplications, output: output, audioQueue: audioQueue)
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
