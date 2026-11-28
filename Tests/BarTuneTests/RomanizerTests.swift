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

    func testRomanizesComposedAndDecomposedHangulIdentically() {
        let word = "사랑"
        XCTAssertEqual(KoreanRomanizer.romanizeLine(word), "sarang")
        XCTAssertEqual(KoreanRomanizer.romanizeLine(word.decomposedStringWithCanonicalMapping), "sarang")
    }

    func testKoreanDisplaySpansOnlySeparateSyllablesAtSourceWhitespace() {
        func preview(_ tokens: [String]) -> String {
            let words = tokens.map { EditableWord(text: $0) }
            return LyricTimingSession.displayWordSpans(for: words, japanese: false, korean: true)
                .map(\.previewText).joined()
        }

        XCTAssertEqual(preview(["사", "", "랑"]), "sarang")
        XCTAssertEqual(preview(["사", " ", "랑"]), "sa rang")
        XCTAssertEqual(preview(["사", "", " 랑"]), "sa rang")
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

final class JapaneseWordRomanizerTests: XCTestCase {
    func testTimedWordsKeepTheWholeLineReading() {
        let words = ["舵取り", "粘土", "に", "固まっ", "て", "いく", "越し", "が", "曇っ", "て"]
        let romanized = JapaneseRomanizer.romanizeWords(words)

        XCTAssertEqual(romanized.count, words.count)
        XCTAssertEqual(
            romanized.filter { !$0.isEmpty }.joined(separator: " "),
            JapaneseRomanizer.romanizeLine(words.joined())
        )
        XCTAssertTrue(romanized.joined(separator: " ").contains("katamatte"), "\(romanized)")
        XCTAssertFalse(romanized.contains("katama"))
    }

    func testLatinWordsPassThrough() {
        XCTAssertEqual(JapaneseRomanizer.romanizeWords(["hello ", "world"]), ["hello ", "world"])
    }

    func testAlignmentRomanizationMapsParticlesWoAndHeWithoutChangingDisplay() {
        XCTAssertEqual(JapaneseRomanizer.romanizeWords(["空", "へ"], forAlignment: true), ["sora", "e"])
        XCTAssertEqual(
            JapaneseRomanizer.romanizeWords(["君", "を", "愛し", "てる"], forAlignment: true),
            ["kimi", "o", "aishi", "teru"]
        )
        XCTAssertEqual(JapaneseRomanizer.romanizeWords(["海", "へ", "行く"], forAlignment: true), ["umi", "e", "iku"])

        // Non-particle へ inside words must keep its consonant.
        XCTAssertEqual(JapaneseRomanizer.romanizeWords(["部屋", "へ"], forAlignment: true), ["heya", "e"])
        XCTAssertEqual(JapaneseRomanizer.romanizeWords(["平和", "を"], forAlignment: true), ["heiwa", "o"])

        // Display romanization preserves the existing を -> wo and へ -> he convention.
        XCTAssertEqual(JapaneseRomanizer.romanizeWords(["空", "へ"]), ["sora", "he"])
        XCTAssertEqual(
            JapaneseRomanizer.romanizeWords(["君", "を", "愛し", "てる"]),
            ["kimi", "wo", "aishi", "teru"]
        )
        XCTAssertEqual(JapaneseRomanizer.romanizeLine("空へ"), "sora he")
        XCTAssertEqual(JapaneseRomanizer.romanizeLine("君を愛してる"), "kimi wo aishi teru")
        XCTAssertEqual(JapaneseRomanizer.romanizeWordSpans(["海", "へ", "行く"]).map(\.text), ["umi", "he", "iku"])
    }
}
