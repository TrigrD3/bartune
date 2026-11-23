@testable import BarTune
import XCTest

@MainActor
final class KaraokeSweepFeatherTests: XCTestCase {
    func testSweepFeatherNeverLightsPastTheSungEdge() {
        for progress in [0.0, 0.05, 0.4, 0.97, 1.0] {
            let feather = KaraokeLineView.sweepFeather(progress: progress, textWidth: 120)
            XCTAssertLessThanOrEqual(feather.clearStart, progress, "progress \(progress) lit unsung text")
            XCTAssertLessThanOrEqual(feather.solidEnd, feather.clearStart)
            XCTAssertGreaterThanOrEqual(feather.solidEnd, 0)
        }
    }

    func testFinishedLineIsFullyLit() {
        let feather = KaraokeLineView.sweepFeather(progress: 1, textWidth: 120)
        XCTAssertEqual(feather.solidEnd, 1)
    }
}
