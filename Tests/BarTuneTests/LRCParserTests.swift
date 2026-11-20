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
}
