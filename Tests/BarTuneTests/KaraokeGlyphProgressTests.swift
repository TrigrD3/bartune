@testable import BarTune
import SwiftUI
import XCTest

@MainActor
final class KaraokeGlyphProgressTests: XCTestCase {
    private let font = FontOption.sfPro.nsFont(size: 14, weight: .medium)

    private let track = TrackInfo(id: "t", title: "T", artist: "A", album: "", duration: 200, artworkURL: nil)

    private func words(_ texts: [String], start: Double = 10, step: Double = 1) -> [WordTimestamp] {
        texts.enumerated().map { WordTimestamp(timestamp: start + Double($0.offset) * step, duration: step, text: $0.element) }
    }

    func testBoundariesFollowMeasuredGlyphWidthsNotCharacterCounts() throws {
        // Same character count per word, very different widths.
        let fractions = try XCTUnwrap(
            LyricsState.wordBoundaryFractions(words: words(["iiii ", "WWWW"]), lineText: "iiii WWWW", font: font)
        )

        XCTAssertEqual(fractions.count, 3)
        XCTAssertEqual(fractions[0], 0)
        XCTAssertEqual(fractions[2], 1, accuracy: 0.0001)
        XCTAssertLessThan(fractions[1], 0.35, "narrow \"iiii \" must take far less than its 5/9 character share")
    }

    func testEdgeMovesThroughMeasuredBoundaries() throws {
        let lineWords = words(["iiii ", "WWWW"])
        let line = LyricLine(id: 0, timestamp: 10, duration: 2, text: "iiii WWWW", words: lineWords)
        let fractions = try XCTUnwrap(LyricsState.wordBoundaryFractions(words: lineWords, lineText: line.text, font: font))

        let halfwayThroughSecondWord = LyricsState.computeLineProgress(
            line: line, nextTimestamp: 13, position: 11.5, boundaries: fractions
        )
        let characterShare = LyricsState.computeLineProgress(line: line, nextTimestamp: 13, position: 11.5)

        XCTAssertEqual(halfwayThroughSecondWord, (fractions[1] + fractions[2]) / 2, accuracy: 0.0001)
        XCTAssertEqual(characterShare, (5 + 2) / 9.0, accuracy: 0.0001)
    }

    func testRomanizedWordsWithATrailingSpaceStillMeasure() throws {
        let fractions = try XCTUnwrap(
            LyricsState.wordBoundaryFractions(words: words(["kimi ", "no ", "egao "]), lineText: "kimi no egao", font: font)
        )
        XCTAssertEqual(fractions.last ?? 0, 1, accuracy: 0.0001)
    }

    func testWordsThatDoNotSpellTheLineFallBack() {
        XCTAssertNil(LyricsState.wordBoundaryFractions(words: words(["hello ", "world"]), lineText: "bonjour monde", font: font))
    }

    func testLiveProgressUsesTheOverlayFont() throws {
        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }
        let state = LyricsState(userDefaults: ud)
        state.setTrack(track, lyrics: [LyricLine(id: 0, timestamp: 10, duration: 2, text: "iiii WWWW", words: words(["iiii ", "WWWW"]))])
        state.updatePlayback(isPlaying: true, position: 11.5)

        let measured = state.liveProgress(at: state.playbackAnchorDate, font: font)
        let characterShare = state.liveProgress(at: state.playbackAnchorDate)

        XCTAssertNotEqual(measured, characterShare, accuracy: 0.05)
    }

    /// CoreText must measure what SwiftUI draws, or the edge drifts off the glyphs.
    func testCoreTextWidthMatchesSwiftUITextForEveryFontOption() {
        let text = "Hello Wonderful 世界 iiii WWWW"
        for option in FontOption.allCases {
            for weight in [FontWeightOption.regular, .bold] {
                let nsFont = option.nsFont(size: 14, weight: weight)
                let ctLine = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: nsFont]))
                let coreText = CTLineGetTypographicBounds(ctLine, nil, nil, nil)
                let hosting = NSHostingView(rootView: Text(text).font(option.font(size: 14, weight: weight)).fixedSize())
                let swiftUI = Double(hosting.fittingSize.width)
                XCTAssertEqual(coreText, swiftUI, accuracy: max(1.5, swiftUI * 0.01), "\(option.rawValue) \(weight.rawValue)")
            }
        }
    }
}
