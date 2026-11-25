@testable import BarTune
import Combine
import XCTest

final class EditorCustomTimingTests: XCTestCase {
    private let track = TrackInfo(id: "custom-test", title: "First", artist: "Artist", album: "", duration: 60, artworkURL: nil)
    private let store = CustomLyricsStore(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
    private let suite = UUID().uuidString

    @MainActor
    private func state(lines: [LyricLine] = []) throws -> LyricsState {
        addTeardownBlock { [store, suite] in
            try? FileManager.default.removeItem(at: store.directory)
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }
        let state = try LyricsState(userDefaults: XCTUnwrap(UserDefaults(suiteName: suite)))
        state.audioSyncEngine = .off
        state.setTrack(track, lyrics: lines)
        return state
    }

    @MainActor
    private func editor(
        _ state: LyricsState,
        load: (@Sendable (String) -> CustomLyricsRecord?)? = nil,
        loadRetained: (@Sendable (String, TrackLyricSource) -> [LyricLine])? = nil,
        select: @escaping (TrackInfo, TrackLyricSource, [LyricLine]?) -> [LyricLine] = { _, _, customLines in customLines ?? [] },
        save: @escaping (TrackInfo, [LyricLine], Set<Int>) throws -> Void = { _, _, _ in },
        delete: @escaping (TrackInfo) throws -> [LyricLine] = { _ in [] }
    ) -> LyricTimingEditorModel {
        LyricTimingEditorModel(
            state: state, customLyricsStore: store, loadCustomRecord: load, loadRetainedLines: loadRetained,
            onSeek: { _, _ in }, onTogglePlayPause: { _ in },
            onSelectSource: select, onSaveCustom: save, onDeleteCustom: delete
        )
    }

    @MainActor
    func testCustomRecordMissReadsOffMainAndCacheHitsApplySynchronously() async throws {
        let state = try state(lines: [LyricLine(id: 0, timestamp: 2, text: "Fetched")])
        let read = expectation(description: "Read Custom timing")
        read.assertForOverFulfill = true
        var selections = 0
        let model = editor(state, load: { _ in
            XCTAssertFalse(Thread.isMainThread)
            read.fulfill()
            return nil
        }, select: { _, _, _ in
            selections += 1
            return [LyricLine(id: 0, timestamp: 3, text: "Switched")]
        })
        await model.customRecordLoad?.value
        await fulfillment(of: [read], timeout: 5)
        model.selectSource(.automatic)
        XCTAssertEqual(selections, 1)
        XCTAssertEqual(model.session.lines.first?.text, "Switched")
        model.loadCurrentTrack()
        XCTAssertEqual(model.session.lines.first?.text, "Fetched")
        XCTAssertNil(model.customRecordLoad)
    }

    @MainActor
    func testLyricsArrivalDuringCustomReadPreservesExplicitSourceSelection() async throws {
        let state = try state()
        let releaseReads = DispatchGroup()
        releaseReads.enter()
        let model = editor(state, load: { _ in
            XCTAssertEqual(releaseReads.wait(timeout: .now() + 10), .success)
            return nil
        }, select: { track, source, _ in
            state.setLyricSourceChoice(source, for: track.id)
            return state.rawLyricLines
        })
        model.selectSource(.automatic)
        let selection = try XCTUnwrap(model.customRecordLoad)
        let lyricsDelivered = expectation(description: "Delivered the new lyrics to the editor")
        let observer = state.rawLinesDidChange.receive(on: RunLoop.main).first().sink { lyricsDelivered.fulfill() }
        defer { observer.cancel() }
        state.setTrack(track, lyrics: [LyricLine(id: 0, timestamp: 1, text: "Arrived during switch")])
        await fulfillment(of: [lyricsDelivered], timeout: 5)
        releaseReads.leave()
        await selection.value
        XCTAssertEqual(state.lyricSourceChoice(for: track.id), .automatic)
        XCTAssertEqual(model.selectedSource, .automatic)
        XCTAssertEqual(model.session.lines.first?.text, "Arrived during switch")
    }

    @MainActor
    func testLateCustomReadKeepsEditsAndChecksForOverwrite() async throws {
        let state = try state()
        state.setLyricSourceChoice(.custom, for: track.id)
        let lines = [LyricLine(id: 0, timestamp: 3, text: "Saved lyrics")]
        try store.save(CustomLyricsRecord(trackId: track.id, title: track.title, artist: track.artist, savedAt: Date(), lines: lines))
        let model = editor(state)
        let read = try XCTUnwrap(model.customRecordLoad)
        model.pastePlainLyrics("New draft")
        model.session.setLineTimestamp(at: 0, to: 1)
        XCTAssertNil(model.prepareCustomSave(), "A save must wait until existing Custom timing is known.")
        await read.value
        XCTAssertEqual(model.session.lines.map(\.text), ["New draft"])
        XCTAssertTrue(model.hasUnsavedEdits)
        XCTAssertTrue(model.hasCustomLyrics)
        XCTAssertNotNil(model.prepareCustomSave())
    }

    @MainActor
    func testLateCustomReadNeverPublishesPreviousTracksLyrics() async throws {
        let state = try state()
        state.setLyricSourceChoice(.custom, for: track.id)
        try store.save(CustomLyricsRecord(
            trackId: track.id, title: track.title, artist: track.artist,
            savedAt: Date(), lines: [LyricLine(id: 0, timestamp: 2, text: "Old Custom")]
        ))
        let model = editor(state)
        let stale = try XCTUnwrap(model.customRecordLoad)
        var publishedTexts: [String] = []
        let observer = model.$session.sink { publishedTexts += $0.lines.map(\.text) }
        defer { observer.cancel() }
        let next = TrackInfo(id: "next-custom-test", title: "Next", artist: "Artist", album: "", duration: 60, artworkURL: nil)
        let loaded = expectation(description: "Loaded the next track")
        let nextObserver = model.$session.first { $0.lines.first?.text == "Next lyrics" }.sink { _ in loaded.fulfill() }
        defer { nextObserver.cancel() }
        state.setTrack(next, lyrics: [LyricLine(id: 0, timestamp: 1, text: "Next lyrics")])
        await stale.value
        await fulfillment(of: [loaded], timeout: 5)
        XCTAssertFalse(publishedTexts.contains("Old Custom"))
        XCTAssertEqual(model.activeTrack?.id, next.id)
    }

    @MainActor
    func testSupersededSameTrackCustomReadCannotApplyAnOldSourceSelection() async throws {
        let state = try state()
        var applied: [TrackLyricSource] = []
        let model = editor(state, select: { _, source, _ in
            applied.append(source)
            return [LyricLine(id: 0, timestamp: 1, text: source.title)]
        })
        let original = try XCTUnwrap(model.customRecordLoad)
        model.selectSource(.custom)
        let stale = try XCTUnwrap(model.customRecordLoad)
        model.selectSource(.defaultSource)
        model.selectSource(.custom)
        XCTAssertTrue(applied.isEmpty, "A cache miss must defer the source callback.")
        await original.value
        await stale.value
        await model.customRecordLoad?.value
        XCTAssertEqual(applied, [.custom])
        XCTAssertEqual(model.session.lines.first?.text, "Custom")
    }

    @MainActor
    func testOverwriteConfirmationExpiresAfterAnEditOrSameTrackReload() async throws {
        let state = try state(lines: [LyricLine(id: 0, timestamp: 2, text: "Original")])
        state.audioSyncEngine = .lyricsAlignment
        try store.save(CustomLyricsRecord(
            trackId: track.id, title: track.title, artist: track.artist,
            savedAt: Date(), lines: [LyricLine(id: 0, timestamp: 1, text: "Existing Custom")]
        ))
        var saved: [[LyricLine]] = []
        let model = editor(state, save: { _, lines, _ in saved.append(lines) })
        await model.customRecordLoad?.value
        let beforeEdit = try XCTUnwrap(model.prepareCustomSave())
        model.updateLineText(at: 0, to: "Revised")
        XCTAssertFalse(model.commitCustomSave(beforeEdit))
        XCTAssertTrue(try XCTUnwrap(model.statusMessage).contains("save again"))
        XCTAssertTrue(model.hasUnsavedEdits)
        model.loadCurrentTrack()
        XCTAssertTrue(model.hasCustomLyrics)
        XCTAssertEqual(model.selectedSource, .automatic)
        let beforeReload = try XCTUnwrap(model.prepareCustomSave())
        let refreshed = expectation(description: "Loaded updated Automatic timing")
        let observer = model.$session.first { $0.lines.first?.timestamp == 9 }.sink { _ in refreshed.fulfill() }
        defer { observer.cancel() }
        state.applyAudioSyncedLines([LyricLine(id: 0, timestamp: 9, text: "Retimed")])
        await fulfillment(of: [refreshed], timeout: 5)
        XCTAssertFalse(model.commitCustomSave(beforeReload))
        XCTAssertTrue(saved.isEmpty)
        let fresh = try XCTUnwrap(model.prepareCustomSave())
        XCTAssertTrue(model.commitCustomSave(fresh))
        XCTAssertEqual(saved, [fresh.lines])
    }

    @MainActor
    func testAutoFinalLineEndStaysAutoThroughCachedSelectionAndDiskReopen() async throws {
        // The final row derives an Auto end from a later timestamp in an earlier row.
        let state = try state(lines: [
            LyricLine(id: 0, timestamp: 10, text: "Later"),
            LyricLine(id: 1, timestamp: 4, text: "Earlier"),
        ])
        let model = editor(state, save: { [store] track, lines, explicitEnds in
            try store.save(CustomLyricsRecord(
                trackId: track.id, title: track.title, artist: track.artist,
                savedAt: Date(), lines: lines, explicitEndLineIndices: explicitEnds
            ))
            state.setLyricSourceChoice(.custom, for: track.id)
            state.setTrack(track, lyrics: lines)
        })
        await model.customRecordLoad?.value
        let pending = try XCTUnwrap(model.prepareCustomSave())
        XCTAssertEqual(pending.lines.last?.duration, 6)
        XCTAssertTrue(pending.explicitEndIndices.isEmpty)
        XCTAssertTrue(model.commitCustomSave(pending))
        XCTAssertEqual(store.load(trackId: track.id)?.explicitEndLineIndices, [])
        model.selectSource(.custom)
        XCTAssertEqual(model.session.lines.count, 2)
        XCTAssertNil(model.session.lines.last?.endTimestamp)
        let reopened = editor(state)
        await reopened.customRecordLoad?.value
        XCTAssertEqual(reopened.session.lines.count, 2)
        XCTAssertNil(reopened.session.lines.last?.endTimestamp)

        // Files saved before end-index metadata existed still infer an explicit final duration.
        try store.save(CustomLyricsRecord(
            trackId: track.id, title: track.title, artist: track.artist,
            savedAt: Date(), lines: pending.lines, explicitEndLineIndices: nil
        ))
        let legacy = editor(state)
        await legacy.customRecordLoad?.value
        XCTAssertEqual(legacy.session.lines.last?.endTimestamp, 10)
    }

    @MainActor
    func testLateCustomReadDefersDuringActiveStampingAndTrackSwitchDoesNotPolluteStatus() async throws {
        let state = try state(lines: [LyricLine(id: 0, timestamp: 2, text: "Fetched")])
        let releaseRead = DispatchGroup()
        releaseRead.enter()
        let model = editor(state, load: { _ in
            XCTAssertEqual(releaseRead.wait(timeout: .now() + 10), .success)
            return nil
        })
        let readTask = try XCTUnwrap(model.customRecordLoad)
        model.session.beginLinePass(from: 0)
        releaseRead.leave()
        await readTask.value
        XCTAssertEqual(model.session.stampingMode, .lines, "in-flight custom read must not wipe active stamping")
        model.session.stopStamping()
        XCTAssertEqual(model.session.lines.first?.text, "Fetched")

        let pendingForOldTrack = try XCTUnwrap(model.prepareCustomSave())
        let other = TrackInfo(id: "other-track", title: "Other", artist: "Artist", album: "", duration: 60, artworkURL: nil)
        state.setTrack(other, lyrics: [LyricLine(id: 0, timestamp: 1, text: "Other line")])
        model.loadCurrentTrack()
        await model.customRecordLoad?.value
        XCTAssertNil(model.statusMessage)
        XCTAssertFalse(model.commitCustomSave(pendingForOldTrack))
        XCTAssertNil(model.statusMessage, "stale save from previous track must not pollute the new track's status bar")
    }

    @MainActor
    func testEditingDuringPendingSourceSwitchRestoresPickerAndKeepsEdits() async throws {
        let state = try state(lines: [LyricLine(id: 0, timestamp: 2, text: "Default")])
        let releaseRead = DispatchGroup()
        releaseRead.enter()
        var selectCalls = 0
        let model = editor(state, load: { _ in
            XCTAssertEqual(releaseRead.wait(timeout: .now() + 10), .success)
            return nil
        }, select: { _, _, _ in
            selectCalls += 1
            return []
        })
        XCTAssertEqual(model.selectedSource, .defaultSource)
        model.selectSource(.automatic)
        let switchTask = try XCTUnwrap(model.customRecordLoad)
        XCTAssertEqual(model.selectedSource, .automatic)

        // Editing before the async read finishes cancels the source switch and restores the picker.
        let added = model.addLine(after: nil)
        model.updateLineText(at: added, to: "User line")
        releaseRead.leave()
        await switchTask.value

        XCTAssertEqual(selectCalls, 0)
        XCTAssertEqual(model.selectedSource, .defaultSource)
        XCTAssertEqual(model.session.lines.map(\.text), ["User line"])
        XCTAssertTrue(try XCTUnwrap(model.statusMessage).contains("without switching"))
    }

    @MainActor
    func testRetainedTrackSourceSwitchLoadsCacheOffMainActor() async throws {
        let state = try state(lines: [LyricLine(id: 0, timestamp: 2, text: "Draft A")])
        let readOffMain = expectation(description: "Read retained track cache off main actor")
        var selectedPayloads: [[LyricLine]] = []
        let model = editor(state, loadRetained: { _, source in
            XCTAssertFalse(Thread.isMainThread)
            XCTAssertEqual(source, .automatic)
            readOffMain.fulfill()
            return [LyricLine(id: 0, timestamp: 4, text: "Synced Retained A")]
        }, select: { _, _, prefetched in
            let lines = prefetched ?? []
            selectedPayloads.append(lines)
            return lines
        })
        await model.customRecordLoad?.value

        // Dirty draft A so switching playback to B retains A in the editor.
        model.updateLineText(at: 0, to: "Edited A")
        let trackB = TrackInfo(id: "other-playing", title: "Track B", artist: "Artist", album: "", duration: 90, artworkURL: nil)
        state.setTrack(trackB, lyrics: [LyricLine(id: 0, timestamp: 1, text: "Track B")])
        try await Task.sleep(nanoseconds: 40_000_000)
        XCTAssertEqual(model.activeTrack?.id, track.id)

        // User confirms switching retained draft A to Automatic: cache read must run off main actor.
        model.selectSource(.automatic)
        let task = try XCTUnwrap(model.customRecordLoad)
        await task.value
        await fulfillment(of: [readOffMain], timeout: 5)
        XCTAssertEqual(selectedPayloads.first?.first?.text, "Synced Retained A")
        XCTAssertEqual(model.session.lines.first?.text, "Synced Retained A")
        XCTAssertEqual(model.selectedSource, .automatic)
    }

    @MainActor
    func testCancellingRetainedSourceSwitchPreservesExistingRowsAndRestoresAppliedSource() async throws {
        let state = try state(lines: [LyricLine(id: 0, timestamp: 2, text: "Custom A")])
        let releaseRead = DispatchGroup()
        releaseRead.enter()
        let model = editor(state, loadRetained: { _, _ in
            XCTAssertEqual(releaseRead.wait(timeout: .now() + 10), .success)
            return [LyricLine(id: 0, timestamp: 5, text: "Default A")]
        }, save: { [store] track, lines, explicitEnds in
            try store.save(CustomLyricsRecord(
                trackId: track.id, title: track.title, artist: track.artist,
                savedAt: Date(), lines: lines, explicitEndLineIndices: explicitEnds
            ))
            state.setLyricSourceChoice(.custom, for: track.id)
        })
        await model.customRecordLoad?.value

        // Save A as Custom (appliedSource == .custom), then switch playback to B so A is retained.
        let pending = try XCTUnwrap(model.prepareCustomSave())
        XCTAssertTrue(model.commitCustomSave(pending))
        XCTAssertEqual(model.selectedSource, .custom)
        let trackB = TrackInfo(id: "playing-b", title: "B", artist: "Artist", album: "", duration: 90, artworkURL: nil)
        model.updateLineText(at: 0, to: "Custom A Edited")
        state.setTrack(trackB, lyrics: [LyricLine(id: 0, timestamp: 1, text: "B")])
        try await Task.sleep(nanoseconds: 40_000_000)

        // Issue two back-to-back source requests on retained A before either finishes, then edit the draft.
        model.selectSource(.defaultSource)
        model.selectSource(.automatic)
        let switchTask = try XCTUnwrap(model.customRecordLoad)
        let added = model.addLine(after: 0)
        model.updateLineText(at: added, to: "New Row")
        releaseRead.leave()
        await switchTask.value

        // Switch must cancel, restore the last *applied* source (.custom, not uncommitted .defaultSource),
        // and preserve both the original Custom row and the newly added row.
        XCTAssertEqual(model.selectedSource, .custom)
        XCTAssertEqual(model.session.lines.map(\.text), ["Custom A Edited", "New Row"])
        XCTAssertTrue(try XCTUnwrap(model.statusMessage).contains("without switching"))
    }

    @MainActor
    func testFailedCustomDeletionPreservesCachedRecordAndSource() async throws {
        // Removing an already-absent file succeeds cleanly.
        try store.remove(trackId: "nonexistent-track-id")

        let state = try state(lines: [LyricLine(id: 0, timestamp: 2, text: "Saved Custom")])
        let record = CustomLyricsRecord(
            trackId: track.id,
            title: track.title,
            artist: track.artist,
            savedAt: Date(),
            lines: [LyricLine(id: 0, timestamp: 2, text: "Saved Custom")]
        )
        try store.save(record)
        state.setLyricSourceChoice(.custom, for: track.id)

        struct DeleteFailure: LocalizedError {
            var errorDescription: String? { "disk read-only" }
        }
        let model = editor(state, delete: { _ in throw DeleteFailure() })
        await model.customRecordLoad?.value
        XCTAssertTrue(model.hasCustomLyrics)
        XCTAssertEqual(model.selectedSource, .custom)

        model.deleteCustomLyrics(for: track)
        XCTAssertTrue(model.hasCustomLyrics, "failed deletion must keep cached Custom flag intact")
        XCTAssertEqual(model.selectedSource, .custom)
        XCTAssertEqual(model.session.lines.map(\.text), ["Saved Custom"])
        XCTAssertTrue(try XCTUnwrap(model.statusMessage).contains("Could not delete Custom lyrics"))
    }
}
