@testable import BarTune
import os
import XCTest

final class VocalSeparatorStatusTests: XCTestCase {
    @MainActor
    func testOlderStatusCheckCannotOverwritePartialRemovalResult() async {
        let firstCheckStarted = expectation(description: "Original status check started")
        let releaseFirstCheck = DispatchSemaphore(value: 0)
        let checkCount = OSAllocatedUnfairLock(initialState: 0)
        let model = VocalSeparatorStatusModel {
            let count = checkCount.withLock { count in
                count += 1
                return count
            }
            guard count == 1 else { return .compiledOnly }
            firstCheckStarted.fulfill()
            _ = releaseFirstCheck.wait(timeout: .now() + 5)
            return .installed
        }

        let original = model.refresh()
        await fulfillment(of: [firstCheckStarted], timeout: 2)
        model.invalidate()
        await model.refresh().value
        XCTAssertEqual(model.status, .compiledOnly)
        releaseFirstCheck.signal()
        await original.value
        XCTAssertEqual(model.status, .compiledOnly)
        XCTAssertFalse(model.isRefreshing)
    }
}
