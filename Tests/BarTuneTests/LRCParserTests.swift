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

    func testEnhancedPrefixAndTerminalBoundary() {
        let lines = LRCParser.parse("[00:10.00]Hello <00:10.50>world<00:11.00>")

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "Hello world")
        XCTAssertEqual(lines[0].words.map(\.text), ["Hello ", "world"])
        XCTAssertEqual(lines[0].words.map(\.timestamp), [10.0, 10.5])
        XCTAssertEqual(lines[0].words.last?.duration ?? 0, 0.5, accuracy: 0.001)
    }

    func testRepeatedEnhancedLineRebasesWordStarts() {
        let lines = LRCParser.parse("[00:10.00][00:30.00]<00:10.25>A <00:10.75>B")

        XCTAssertEqual(lines.map(\.timestamp), [10, 30])
        XCTAssertEqual(lines[0].words.map(\.timestamp), [10.25, 10.75])
        XCTAssertEqual(lines[1].words.map(\.timestamp), [30.25, 30.75])
    }

    func testYRCWordPreservesLiteralParentheses() {
        let lines = YRCParser.parse("[1000,1000](1000,500,0)Hi (echo) (1500,500,0)there")

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].words.map(\.text), ["Hi (echo) ", "there"])
        XCTAssertEqual(lines[0].words.map(\.timestamp), [1.0, 1.5])
        XCTAssertEqual(lines[0].text, "Hi (echo) there")
    }
}
