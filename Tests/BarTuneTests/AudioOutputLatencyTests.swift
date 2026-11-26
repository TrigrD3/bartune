@testable import BarTune
import CoreAudio
import XCTest

final class AudioOutputLatencyTests: XCTestCase {
    @MainActor
    func testRouteLookupRunsOffMainAndOnlyTheCurrentObservationPublishes() async {
        let published = expectation(description: "current observation publishes")
        published.assertForOverFulfill = false
        let monitor = AudioOutputLatencyMonitor(readDefaultDevice: {
            XCTAssertFalse(Thread.isMainThread)
            return AudioDeviceID(kAudioObjectUnknown)
        })

        monitor.start { _ in XCTFail("stopped observation published a latency") }
        monitor.stop()
        monitor.start { latency in
            XCTAssertTrue(Thread.isMainThread)
            XCTAssertEqual(latency, 0)
            published.fulfill()
        }

        await fulfillment(of: [published], timeout: 5)
        monitor.stop()
    }

    func testLatencyIncludesDeviceSafetyAndStreamFrames() {
        XCTAssertEqual(
            AudioOutputLatencyMonitor.computeLatencySeconds(
                deviceFrames: 720, safetyOffsetFrames: 192, streamFrames: 240, sampleRate: 48000
            ),
            0.024,
            accuracy: 1e-9
        )
    }

    func testLatencyCapsAtOneSecondAndHandlesUnavailableSampleRates() {
        XCTAssertEqual(
            AudioOutputLatencyMonitor.computeLatencySeconds(
                deviceFrames: .max, safetyOffsetFrames: .max, streamFrames: .max, sampleRate: 44100
            ),
            1
        )
        for sampleRate in [0, -1, .nan, .infinity] {
            XCTAssertEqual(
                AudioOutputLatencyMonitor.computeLatencySeconds(
                    deviceFrames: 720, safetyOffsetFrames: 192, streamFrames: 240, sampleRate: sampleRate
                ),
                0
            )
        }
    }
}
