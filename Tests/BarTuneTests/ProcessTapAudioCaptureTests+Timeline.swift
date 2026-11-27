@testable import BarTune
import CoreAudio
import Foundation
import XCTest

extension ProcessTapAudioCaptureTests {
    func testFIFOOverflowMarksOnlyTheFirstBufferAfterTheDrop() async {
        guard #available(macOS 14.2, *) else { return }
        let worker = DispatchQueue(label: "test.process-tap-fifo")
        let format = AudioStreamBasicDescription(
            mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM, mFormatFlags: kAudioFormatFlagIsFloat,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 1,
            mBitsPerChannel: 32, mReserved: 0
        )
        let capacity = LiveProcessTapBackend.RawIOBufferHandoff.slotCount
        let lastAccepted = Float(capacity - 1)
        let dropped = Float(capacity)
        let afterDrop = Float(capacity + 1)
        let afterContiguous = Float(capacity + 2)
        let initialDrain = expectation(description: "Drained the original FIFO slots")
        let marked = expectation(description: "Marked the first accepted buffer after overflow")
        let contiguous = expectation(description: "Kept the next contiguous buffer unmarked")
        let fifo = LiveProcessTapBackend.RawIOBufferHandoff(format: format, maxFrames: 1, workerQueue: worker) { buffer in
            switch buffer.channels.first?.first {
            case lastAccepted:
                XCTAssertFalse(buffer.startsNewSpan)
                initialDrain.fulfill()
            case afterDrop:
                XCTAssertTrue(buffer.startsNewSpan)
                marked.fulfill()
            case afterContiguous:
                XCTAssertFalse(buffer.startsNewSpan)
                contiguous.fulfill()
            default:
                XCTAssertNotEqual(buffer.channels.first?.first, dropped)
                XCTAssertFalse(buffer.startsNewSpan)
            }
        }

        func enqueue(_ value: Float) {
            var sample = value
            var timestamp = AudioTimeStamp()
            withUnsafeMutablePointer(to: &sample) { data in
                let buffers = AudioBufferList(mNumberBuffers: 1, mBuffers: AudioBuffer(mNumberChannels: 1, mDataByteSize: 4, mData: data))
                withUnsafePointer(to: buffers) { fifo.enqueue(bufferList: $0, inputTime: &timestamp) }
            }
        }

        worker.suspend()
        for value in 0...capacity {
            enqueue(Float(value))
        }
        worker.resume()
        await fulfillment(of: [initialDrain], timeout: 2)
        worker.sync {}
        worker.suspend()
        enqueue(afterDrop)
        enqueue(afterContiguous)
        worker.resume()
        await fulfillment(of: [marked, contiguous], timeout: 2)
    }

    func testBatcherFlushesOnMarkedTenMillisecondGap() throws {
        var batcher = AudioCaptureBatcher(targetDuration: 0.02)
        let frames = Array(repeating: Float(0.4), count: 480)
        XCTAssertTrue(batcher.append(CapturedAudio(samples: frames, sampleRate: 48000, capturedAt: 10)).isEmpty)
        let beforeDrop = batcher.append(
            CapturedAudio(samples: frames, sampleRate: 48000, capturedAt: 10.02, startsNewSpan: true),
            deliveryUptime: 10.04
        )
        let first = try XCTUnwrap(beforeDrop.first)
        XCTAssertEqual(first.samples.count, 480)
        XCTAssertFalse(first.startsNewSpan)
        let afterDrop = batcher.append(
            CapturedAudio(samples: frames, sampleRate: 48000, capturedAt: 10.03), deliveryUptime: 10.04
        )
        let second = try XCTUnwrap(afterDrop.first)
        XCTAssertEqual(second.samples.count, 960)
        XCTAssertEqual(second.capturedAt, 10.02)
        XCTAssertTrue(second.startsNewSpan)
    }

    @MainActor
    func testOldHALTimestampStillRejectsPreSeekAudio() async throws {
        guard #available(macOS 14.2, *) else { return }
        let target = "com.spotify.client"
        let backend = MockProcessTapBackend(
            processes: [AudioProcessSnapshot(objectID: 42, pid: 1000, bundleIdentifier: target)],
            runningBundles: [target]
        )
        let capture = ProcessTapAudioCapture(backend: backend, excludedPID: 99999)
        defer { capture.stop() }
        let now = ProcessInfo.processInfo.systemUptime
        let hostNanos = AudioConvertHostTimeToNanos(AudioGetCurrentHostTime())
        let oldHostNanos = try XCTUnwrap(hostNanos >= 2_000_000_000 ? hostNanos - 2_000_000_000 : nil)
        let delivered = expectation(description: "Delivered audio captured before the seek")
        capture.onAudioSamples = { batch in
            XCTAssertNil(batch.trimmingBefore(now - 1, deliveredAt: ProcessInfo.processInfo.systemUptime))
            delivered.fulfill()
        }
        try await capture.start(targetBundleIds: [target])
        let signal = [Float](repeating: 0.4, count: 12000)
        backend.emitBuffer(ProcessTapAudioBuffer(channels: [signal, signal], hostTimeNanos: oldHostNanos))
        await fulfillment(of: [delivered], timeout: 2)
    }
}
