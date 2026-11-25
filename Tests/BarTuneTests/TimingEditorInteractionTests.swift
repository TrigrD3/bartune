@testable import BarTune
import XCTest

final class TimingEditorInteractionTests: XCTestCase {
    func testBlankLineWithOnlyAnEndTimeRequiresDeletionConfirmation() {
        XCTAssertTrue(EditableLine(text: " ", endTimestamp: 4.5).requiresDeletionConfirmation)
        XCTAssertFalse(EditableLine(text: " ").requiresDeletionConfirmation)
    }

    @MainActor
    func testTimelineDragBlocksStampsUntilRelease() async throws {
        let (_, model, _) = try await makeEditor()
        model.session.beginLinePass()
        model.beginTimelineDrag()
        XCTAssertFalse(model.canStampNow)
        model.stampNow()
        XCTAssertEqual(model.session.nextLineIndex, 0)
        XCTAssertEqual(model.session.lines.first?.timestamp, 3)

        model.endTimelineDrag()
        XCTAssertTrue(model.canStampNow)
        model.stampNow()
        XCTAssertEqual(model.session.nextLineIndex, 1)
    }

    @MainActor
    func testCleanDragAppliesPendingAlignmentAfterRelease() async throws {
        let (state, model, _) = try await makeEditor()
        let originalID = model.session.lines.first?.id
        model.beginTimelineDrag()
        state.audioSyncEngine = .lyricsAlignment
        state.applyAudioSyncedLines([LyricLine(id: 0, timestamp: 4, text: "Aligned")])
        await deliverEditorUpdates()
        XCTAssertEqual(model.selectedSource, .defaultSource)
        XCTAssertEqual(model.session.lines.first?.id, originalID)

        model.endTimelineDrag()
        XCTAssertEqual(model.selectedSource, .automatic)
        XCTAssertEqual(model.session.lines.first?.text, "Aligned")
        XCTAssertFalse(model.hasUnsavedEdits)
    }

    @MainActor
    func testDragRefreshWaitsForFieldEditingAndStampingToFinish() async throws {
        let (state, model, _) = try await makeEditor(engine: .lyricsAlignment)
        model.beginTimelineDrag()
        state.applyAudioSyncedLines([LyricLine(id: 0, timestamp: 9, text: "Aligned")])
        await deliverEditorUpdates()
        model.beginFieldEdit()
        model.session.beginLinePass()

        model.endTimelineDrag()
        XCTAssertEqual(model.session.lines.first?.text, "Original")
        model.endFieldEdit()
        XCTAssertEqual(model.session.lines.first?.text, "Original")
        model.session.stopStamping()
        XCTAssertEqual(model.session.lines.first?.text, "Aligned")
    }

    @MainActor
    func testEditedDragPreservesItsTimingAfterPendingRefresh() async throws {
        let (state, model, _) = try await makeEditor(engine: .lyricsAlignment)
        let originalID = model.session.lines.first?.id
        model.beginTimelineDrag()
        state.applyAudioSyncedLines([LyricLine(id: 0, timestamp: 8, text: "Replacement")])
        await deliverEditorUpdates()
        model.session.setLineTimestamp(at: 0, to: 5.5)
        model.endTimelineDrag()
        XCTAssertEqual(model.session.lines.first?.id, originalID)
        XCTAssertEqual(model.session.lines.first?.text, "Original")
        XCTAssertEqual(model.session.lines.first?.timestamp, 5.5)
        XCTAssertTrue(model.hasUnsavedEdits)
    }

    @MainActor
    func testDefaultLyricsRefreshAfterIdleRetainsRowsUntilNewLyricsArrive() async throws {
        let (state, model, track) = try await makeEditor()
        let originalID = try XCTUnwrap(model.session.lines.first?.id)
        state.setTrack(nil, lyrics: [])
        await deliverEditorUpdates()
        state.setTrack(track, lyrics: [])
        await deliverEditorUpdates()
        XCTAssertEqual(model.session.lines.first?.id, originalID)

        state.setTrack(track, lyrics: [LyricLine(id: 0, timestamp: 7, text: "Fetched again")])
        await deliverEditorUpdates()
        XCTAssertEqual(model.selectedSource, .defaultSource)
        XCTAssertEqual(model.session.lines.first?.text, "Fetched again")
        XCTAssertEqual(model.session.lines.first?.timestamp, 7)
        XCTAssertFalse(model.hasUnsavedEdits)
    }

    @MainActor
    func testRulerScrubPreviewBlocksLiveStampingUntilEnded() async throws {
        let (_, model, _) = try await makeEditor()
        model.session.beginLinePass(from: 0)
        XCTAssertTrue(model.canStampNow)

        model.previewScrub(to: 80.0)
        XCTAssertFalse(model.canStampNow)
        model.stampNow()
        XCTAssertEqual(model.session.nextLineIndex, 0)
        XCTAssertEqual(model.session.lines.first?.timestamp, 3)

        model.endScrub(commit: false)
        XCTAssertTrue(model.canStampNow)
        model.stampNow()
        XCTAssertEqual(model.session.nextLineIndex, 1)
    }

    func testTranslateAndNudgeLineBoundDeltaByEarliestTimedWord() {
        let initialWords = [
            EditableWord(text: "early ", timestamp: 0.25),
            EditableWord(text: "late", timestamp: 0.75),
        ]
        var dragged = LyricTimingSession(editableLines: [
            EditableLine(text: "early late", timestamp: 2.0, words: initialWords),
        ])
        dragged.translateLine(
            at: 0,
            originStart: 2.0,
            originEnd: nil,
            originWordTimestamps: [0.25, 0.75],
            delta: -2.0
        )
        XCTAssertEqual(dragged.lines[0].timestamp ?? -1, 1.75, accuracy: 0.001)
        XCTAssertEqual(dragged.lines[0].words[0].timestamp ?? -1, 0.0, accuracy: 0.001)
        XCTAssertEqual(dragged.lines[0].words[1].timestamp ?? -1, 0.50, accuracy: 0.001)

        var nudged = LyricTimingSession(editableLines: [
            EditableLine(text: "early late", timestamp: 2.0, words: initialWords),
        ])
        nudged.nudgeLine(at: 0, by: -2.0)
        XCTAssertEqual(nudged.lines[0].timestamp ?? -1, 1.75, accuracy: 0.001)
        XCTAssertEqual(nudged.lines[0].words[0].timestamp ?? -1, 0.0, accuracy: 0.001)
        XCTAssertEqual(nudged.lines[0].words[1].timestamp ?? -1, 0.50, accuracy: 0.001)
    }

    func testDerivedLineEndBoundsManualWordByNextWordStart() {
        let line = EditableLine(
            text: "one two",
            timestamp: 10.0,
            words: [
                EditableWord(text: "one ", timestamp: 16.0, preservedDuration: nil),
                EditableWord(text: "two", timestamp: 16.1, preservedDuration: 0.0),
            ]
        )
        let end = LyricTimingSession.derivedLineEnd(
            for: line,
            nextLaterStart: nil,
            fallbackDuration: TimelineLayoutMath.finalLineFallbackDuration
        )
        XCTAssertEqual(end ?? -1, 16.1, accuracy: 0.001)
    }

    @MainActor
    private func makeEditor(engine: AudioSyncEngine = .off) async throws -> (LyricsState, LyricTimingEditorModel, TrackInfo) {
        let suite = "com.arya.bartune.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let state = LyricsState(userDefaults: defaults)
        state.audioSyncEngine = engine
        let track = TrackInfo(id: "timeline", title: "Track", artist: "Artist", album: "", duration: 120, artworkURL: nil)
        state.setTrack(track, lyrics: [LyricLine(id: 0, timestamp: 3, text: "Original")])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let model = LyricTimingEditorModel(
            state: state,
            customLyricsStore: CustomLyricsStore(directory: directory),
            onSeek: { _, _ in },
            onTogglePlayPause: { _ in },
            onSelectSource: { _, _, _ in [] },
            onSaveCustom: { _, _, _ in },
            onDeleteCustom: { _ in [] }
        )
        await model.customRecordLoad?.value
        return (state, model, track)
    }

    /// The model receives state publications on RunLoop.main. Enqueue behind those deliveries.
    private func deliverEditorUpdates() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform { continuation.resume() }
        }
    }
}
