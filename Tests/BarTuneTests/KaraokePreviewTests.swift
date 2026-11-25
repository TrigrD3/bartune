@testable import BarTune
import SwiftUI
import XCTest

final class KaraokePreviewTests: XCTestCase {
    @MainActor
    private func editor(for line: EditableLine) throws -> LyricTimingEditorModel {
        let suite = "com.bartune.tests.karaoke.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let model = LyricTimingEditorModel(
            state: LyricsState(userDefaults: defaults),
            customLyricsStore: CustomLyricsStore(directory: FileManager.default.temporaryDirectory),
            onSeek: { _, _ in },
            onTogglePlayPause: { _ in },
            onSelectSource: { _, _, _ in [] },
            onSaveCustom: { _, _, _ in },
            onDeleteCustom: { _ in [] }
        )
        model.session = LyricTimingSession(editableLines: [line])
        return model
    }

    @MainActor
    func testShortLineStaysVisibleAfterFinalWordFinishes() throws {
        let word = EditableWord(text: "Oh", timestamp: 10.0)
        let line = EditableLine(text: "Oh", timestamp: 10.0, endTimestamp: 10.1, words: [word])
        let model = try editor(for: line)

        model.syncPlayingHighlight(at: 10.05)
        XCTAssertEqual(model.playingHighlight.playingWordId, word.id)
        XCTAssertEqual(try XCTUnwrap(model.activeLineAndProgress(at: 10.05)).progress, 0.5, accuracy: 0.001)

        model.syncPlayingHighlight(at: 10.2)
        XCTAssertEqual(model.playingHighlight.playingLineId, line.id)
        XCTAssertNil(model.playingHighlight.playingWordId)
        XCTAssertEqual(try XCTUnwrap(model.activeLineAndProgress(at: 10.2)).progress, 1)
        XCTAssertNil(model.activeLineAndProgress(at: 10.9))
    }

    @MainActor
    func testOutOfOrderWordStampsUseLineProgressAndOrderedStampsUseMeasuredBoundaries() throws {
        let first = EditableWord(text: "WWW ", timestamp: 2)
        let second = EditableWord(text: "iii", timestamp: 0)
        let line = EditableLine(text: "WWW iii", timestamp: 0, endTimestamp: 4, words: [first, second])
        let model = try editor(for: line)
        for time in [0.0, 1.0, 2.0, 3.0, 4.0] {
            XCTAssertEqual(try XCTUnwrap(model.activeLineAndProgress(at: time)).progress, time / 4, accuracy: 0.001)
        }

        model.session.setWordTimestamp(lineIndex: 0, wordIndex: 0, to: 0)
        model.session.setWordTimestamp(lineIndex: 0, wordIndex: 1, to: 2)
        let boundary = LyricTimingEditorModel.measureWordBoundaries(pieces: [first.text, second.text])[1]
        XCTAssertGreaterThan(boundary, 0.7)
        XCTAssertEqual(try XCTUnwrap(model.activeLineAndProgress(at: 1)).progress, boundary / 2, accuracy: 0.001)
    }

    @MainActor
    func testLongLineSweepsFullTextBeforeClippingToPreviewWidth() throws {
        let firstPiece = String(repeating: "W", count: 65) + " "
        let secondPiece = String(repeating: "i", count: 150)
        let firstWordEnd = LyricTimingEditorModel.measureWordBoundaries(pieces: [firstPiece, secondPiece])[1]
        XCTAssertLessThan(firstWordEnd, 0.8)

        func pixels(progress: Double) throws -> Data {
            let preview = KaraokePreviewText(text: firstPiece + secondPiece, progress: progress, isRTL: false)
                .accentColor(.red)
                .frame(width: 360)
            let image = try XCTUnwrap(ImageRenderer(content: preview).cgImage)
            XCTAssertEqual(image.width, 360)
            return try XCTUnwrap(image.dataProvider?.data) as Data
        }

        // The first word alone fills the viewport. At its end every visible glyph has been sung.
        let fullySwept = try pixels(progress: 1)
        XCTAssertNotEqual(try pixels(progress: 0), fullySwept)
        XCTAssertEqual(try pixels(progress: firstWordEnd), fullySwept)
    }

    @MainActor
    func testOutOfOrderWordHighlightMatchesTimelineWordLane() throws {
        // Line 10..16 s with text-order stamps A@12 (0.2 s) and B@10 (unbounded -> ends at 16 s).
        // At 13 s, A has finished while B is still active on the timeline and must be active in the inspector too.
        let wordA = EditableWord(text: "A ", timestamp: 12.0, preservedDuration: 0.2)
        let wordB = EditableWord(text: "B", timestamp: 10.0)
        let line = EditableLine(text: "A B", timestamp: 10.0, endTimestamp: 16.0, words: [wordA, wordB])
        let model = try editor(for: line)

        model.syncPlayingHighlight(at: 11.0)
        XCTAssertEqual(model.playingHighlight.playingWordId, wordB.id)
        model.syncPlayingHighlight(at: 12.1)
        XCTAssertEqual(model.playingHighlight.playingWordId, wordA.id)
        model.syncPlayingHighlight(at: 13.0)
        XCTAssertEqual(model.playingHighlight.playingWordId, wordB.id)
    }

    @MainActor
    func testOverlappingWordSpansFallBackToLineProgress() throws {
        // Span A runs 10..14 s while Span B runs 11..12 s: starts are ordered, but overlapping spans
        // cannot use a single leading-edge mask without prematurely marking A complete at 11 s.
        let wordA = EditableWord(text: "WWWW ", timestamp: 10.0, preservedDuration: 4.0)
        let wordB = EditableWord(text: "i", timestamp: 11.0, preservedDuration: 1.0)
        let line = EditableLine(text: "WWWW i", timestamp: 10.0, endTimestamp: 14.0, words: [wordA, wordB])
        let model = try editor(for: line)

        XCTAssertEqual(try XCTUnwrap(model.activeLineAndProgress(at: 11.5)).progress, 1.5 / 4.0, accuracy: 0.001)
    }

    @MainActor
    func testPausedPositionSubTenthSecondMoveRefreshesWordHighlight() async throws {
        let suite = "com.bartune.tests.karaoke.paused.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        let state = LyricsState(userDefaults: defaults)
        let track = TrackInfo(id: "paused-word-boundary", title: "Track", artist: "Artist", album: "", duration: 60, artworkURL: nil)
        state.setTrack(track, lyrics: [
            LyricLine(
                id: 0,
                timestamp: 10.0,
                duration: 2.0,
                text: "Hi there",
                words: [
                    WordTimestamp(timestamp: 10.0, duration: 0.05, text: "Hi "),
                    WordTimestamp(timestamp: 11.0, duration: 0.5, text: "there"),
                ]
            ),
        ])
        state.updatePlayback(isPlaying: false, position: 10.02)
        let model = LyricTimingEditorModel(
            state: state,
            customLyricsStore: CustomLyricsStore(directory: FileManager.default.temporaryDirectory),
            onSeek: { _, _ in },
            onTogglePlayPause: { _ in },
            onSelectSource: { _, _, _ in [] },
            onSaveCustom: { _, _, _ in },
            onDeleteCustom: { _ in [] }
        )
        await model.customRecordLoad?.value
        XCTAssertEqual(model.playingHighlight.playingWordId, model.session.lines[0].words[0].id)

        // Move paused playhead within the same 0.1 s bucket (10.02 -> 10.08) across word end (10.05).
        state.updatePlayback(isPlaying: false, position: 10.08)
        await withCheckedContinuation { continuation in
            RunLoop.main.perform { continuation.resume() }
        }
        XCTAssertNil(model.playingHighlight.playingWordId)
    }
}
