@testable import BarTune
import Darwin.Mach
import XCTest

final class ResourceMetricsTrackerTests: XCTestCase {
    func testComputesRunningAverageForCPUAndMemory() {
        var tracker = ResourceMetricsTracker()
        XCTAssertEqual(tracker.sampleCount, 0)
        XCTAssertEqual(tracker.averageCPUPercent, 0)
        XCTAssertEqual(tracker.averageMemoryBytes, 0)

        tracker.record(cpuPercent: 1.0, memoryBytes: 20_000_000)
        tracker.record(cpuPercent: 3.0, memoryBytes: 40_000_000)
        tracker.record(cpuPercent: 5.0, memoryBytes: 30_000_000)

        XCTAssertEqual(tracker.sampleCount, 3)
        XCTAssertEqual(tracker.latestCPUPercent, 5.0, accuracy: 0.001)
        XCTAssertEqual(tracker.latestMemoryBytes, 30_000_000)
        XCTAssertEqual(tracker.averageCPUPercent, 3.0, accuracy: 0.001)
        XCTAssertEqual(tracker.averageMemoryBytes, 30_000_000)
    }

    func testResetClearsSamplesAndAverages() {
        var tracker = ResourceMetricsTracker()
        tracker.record(cpuPercent: 4.5, memoryBytes: 50_000_000)
        tracker.reset()

        XCTAssertEqual(tracker.sampleCount, 0)
        XCTAssertEqual(tracker.latestCPUPercent, 0)
        XCTAssertEqual(tracker.latestMemoryBytes, 0)
        XCTAssertEqual(tracker.averageCPUPercent, 0)
        XCTAssertEqual(tracker.averageMemoryBytes, 0)
    }

    func testCPUSamplerDoesNotLeakMachThreadSendRights() {
        let selfThread = mach_thread_self()
        defer { mach_port_deallocate(mach_task_self_, selfThread) }

        var refsBefore: mach_port_urefs_t = 0
        XCTAssertEqual(
            mach_port_get_refs(mach_task_self_, selfThread, MACH_PORT_RIGHT_SEND, &refsBefore),
            KERN_SUCCESS
        )

        for _ in 0..<10 {
            _ = AppResourceMetrics.sample()
        }

        var refsAfter: mach_port_urefs_t = 0
        XCTAssertEqual(
            mach_port_get_refs(mach_task_self_, selfThread, MACH_PORT_RIGHT_SEND, &refsAfter),
            KERN_SUCCESS
        )

        XCTAssertEqual(refsAfter, refsBefore)
    }
}
