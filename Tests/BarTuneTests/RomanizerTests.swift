@testable import BarTune
import XCTest

final class RomanizerTests: XCTestCase {
    func testDetectsAndRomanizesKoreanHangul() {
        XCTAssertTrue(KoreanRomanizer.containsHangul("안녕하세요"))
        XCTAssertFalse(KoreanRomanizer.containsHangul("Hello world"))

        let romanized = KoreanRomanizer.romanizeLine("사랑해요")
        XCTAssertFalse(KoreanRomanizer.containsHangul(romanized))
        XCTAssertTrue(romanized.lowercased().contains("sarang"))
    }

    func testLeavesEnglishTextUnchanged() {
        XCTAssertEqual(KoreanRomanizer.romanizeLine("BOOMBAYAH"), "BOOMBAYAH")
        XCTAssertEqual(JapaneseRomanizer.romanizeLine("BOOMBAYAH"), "BOOMBAYAH")
    }

    func testDetectsKoreanTrack() {
        let lines = [
            LyricLine(id: 0, timestamp: 1.0, text: "Blackpink in your area"),
            LyricLine(id: 1, timestamp: 5.0, text: "붐바야"),
        ]
        XCTAssertTrue(KoreanRomanizer.isKoreanTrack(lines))
    }

    func testDetectsAndRomanizesChineseToPinyin() {
        let chineseLines = [
            LyricLine(id: 0, timestamp: 1.0, text: "你好世界"),
            LyricLine(id: 1, timestamp: 5.0, text: "我爱你"),
        ]
        XCTAssertTrue(ChineseRomanizer.isChineseTrack(chineseLines))

        let pinyin = ChineseRomanizer.romanizeLine("你好世界")
        XCTAssertFalse(ChineseRomanizer.containsHan(pinyin))
        XCTAssertTrue(pinyin.lowercased().contains("ni hao"))
        XCTAssertEqual(ChineseRomanizer.romanizeLine("Hello"), "Hello")
    }

    func testDoesNotMisclassifyJapaneseKanjiTrackAsChinese() {
        let japaneseLines = [
            LyricLine(id: 0, timestamp: 1.0, text: "夢ならばどれほどよかったでしょう"),
        ]
        XCTAssertTrue(JapaneseRomanizer.isJapaneseTrack(japaneseLines))
        XCTAssertFalse(ChineseRomanizer.isChineseTrack(japaneseLines))
    }
}
