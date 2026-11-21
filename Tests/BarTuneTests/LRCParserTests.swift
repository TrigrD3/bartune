@testable import BarTune
import XCTest

final class LRCParserTests: XCTestCase {
    func testParsesStandardLRCLinesInSortedOrder() {
        let lrc = """
        [00:12.50]Second line
        [00:05.00]First line
        """

        let lines = LRCParser.parse(lrc)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines[0].text, "First line")
        XCTAssertEqual(lines[0].timestamp, 5.0, accuracy: 0.001)
        XCTAssertEqual(lines[1].text, "Second line")
        XCTAssertEqual(lines[1].timestamp, 12.5, accuracy: 0.001)
    }

    func testParsesEnhancedWordTimestamps() {
        let lrc = "[00:10.00]<00:10.00>Hello <00:10.50>world"
        let lines = LRCParser.parse(lrc)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "Hello world")
        XCTAssertEqual(lines[0].words.count, 2)
        XCTAssertEqual(lines[0].words[0].text, "Hello ")
        XCTAssertEqual(lines[0].words[1].text, "world")
        XCTAssertEqual(lines[0].words[1].timestamp, 10.5, accuracy: 0.001)
    }

    func testFileOffsetShiftsLinesAndWords() {
        let body = "[00:10.00]<00:10.25>Go"

        let advanced = LRCParser.parse("[offset:+500]\n" + body)
        XCTAssertEqual(advanced[0].timestamp, 9.5, accuracy: 0.001)
        XCTAssertEqual(advanced[0].words[0].timestamp, 9.75, accuracy: 0.001)

        let delayed = LRCParser.parse(body + "\n[offset:-500]")
        XCTAssertEqual(delayed[0].timestamp, 10.5, accuracy: 0.001)
        XCTAssertEqual(delayed[0].words[0].timestamp, 10.75, accuracy: 0.001)

        let clamped = LRCParser.parse("[offset:20000]\n" + body)
        XCTAssertEqual(clamped[0].timestamp, 0, accuracy: 0.001)
        XCTAssertEqual(clamped[0].words[0].timestamp, 0, accuracy: 0.001)
    }
}
