@testable import BarTune
import XCTest

@MainActor
final class EditorPlaybackCommandTests: XCTestCase {
    private let track = TrackInfo(id: "song", title: "Song", artist: "Artist", album: "", duration: 120, artworkURL: nil)

    private func makeModel(playing: Bool, onSeek: @escaping (String, Double) -> Void) async throws -> (LyricsState, LyricTimingEditorModel) {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            if FileManager.default.fileExists(atPath: directory.path) {
                try FileManager.default.removeItem(at: directory)
            }
        }
        let state = LyricsState(userDefaults: defaults)
        state.lowCPUMode = false
        state.setTrack(track, lyrics: [LyricLine(id: 0, timestamp: 10, duration: 0.2, text: "One")])
        state.updatePlayback(isPlaying: playing, position: 10)
        let model = LyricTimingEditorModel(
            state: state, customLyricsStore: CustomLyricsStore(directory: directory), onSeek: onSeek,
            onTogglePlayPause: { _ in }, onSelectSource: { _, _, _ in [] }, onSaveCustom: { _, _, _ in }, onDeleteCustom: { _ in [] }
        )
        await model.customRecordLoad?.value
        await deliverPlaybackUpdates()
        return (state, model)
    }

    private func deliverPlaybackUpdates() async {
        await withCheckedContinuation { continuation in
            RunLoop.main.perform { continuation.resume() }
        }
    }

    func testActiveLineLoopBoundsPollingAndSeekCooldownAtFourTimesSpeed() async throws {
        var seeks: [Double] = []
        let (state, model) = try await makeModel(playing: true) { _, pos in seeks.append(pos) }
        model.loopMode = .line
        defer { model.loopMode = .off }
        XCTAssertEqual(model.loopPollingInterval, 0.1)

        state.updatePlayback(isPlaying: true, position: 10, playbackRate: 4)
        await deliverPlaybackUpdates()
        XCTAssertEqual(model.loopPollingInterval, 0.025)
        state.lowCPUMode = true
        await deliverPlaybackUpdates()
        XCTAssertEqual(model.loopPollingInterval, 0.05)

        let now = Date().addingTimeInterval(2)
        seeks.removeAll()
        model.checkLoop(at: 10.2, now: now)
        XCTAssertEqual(seeks, [10])
        // While the first seek is still unacknowledged on the old playback anchor, further timer ticks
        // must not enqueue duplicate seeks even after the 25 ms/50 ms cooldown elapses.
        model.checkLoop(at: 10.2, now: now.addingTimeInterval(0.05))
        XCTAssertEqual(seeks, [10])
        // A pre-seek poll whose anchor is still out of range must not falsely acknowledge the seek either.
        state.updatePlayback(isPlaying: true, position: 10.25, playbackRate: 4)
        model.checkLoop(at: 10.25, now: now.addingTimeInterval(0.08))
        XCTAssertEqual(seeks, [10])
        // Once the player acknowledges the seek back inside range, the next pass repeats after the short cooldown.
        state.updatePlayback(isPlaying: true, position: 10.02, playbackRate: 4)
        model.checkLoop(at: 10.02, now: now.addingTimeInterval(0.09))
        model.checkLoop(at: 10.2, now: now.addingTimeInterval(0.11))
        XCTAssertEqual(seeks, [10, 10])
        // If a seek is never acknowledged, a bounded retry fires after 1.0 s.
        model.checkLoop(at: 10.2, now: now.addingTimeInterval(1.05))
        XCTAssertEqual(seeks, [10, 10])
        model.checkLoop(at: 10.2, now: now.addingTimeInterval(1.15))
        XCTAssertEqual(seeks, [10, 10, 10])
    }

    func testStampSelectedLineEndGuardedOnRetainedTrackAndAllowedWhenPausedOnActiveTrack() async throws {
        let (state, model) = try await makeModel(playing: false) { _, _ in }
        model.seek(to: 11.4)
        XCTAssertTrue(model.canStampSelectedLineEnd)
        model.stampSelectedLineEndNow()
        XCTAssertEqual(try XCTUnwrap(model.session.lines.first?.endTimestamp), 11.4, accuracy: 0.001)

        // Switching playback to another track while keeping a dirty draft freezes the playhead and disables Stamp End,
        // both immediately when state.currentTrack changes and after pendingNewTrack is published.
        model.updateLineText(at: 0, to: "Edited")
        let other = TrackInfo(id: "other", title: "Other", artist: "", album: "", duration: 180, artworkURL: nil)
        state.setTrack(other, lyrics: [])
        XCTAssertFalse(model.canStampSelectedLineEnd)
        model.stampSelectedLineEndNow()
        XCTAssertEqual(try XCTUnwrap(model.session.lines.first?.endTimestamp), 11.4, accuracy: 0.001)

        await deliverPlaybackUpdates()
        XCTAssertEqual(model.pendingNewTrack?.id, other.id)
        XCTAssertFalse(model.canStampSelectedLineEnd)
        model.session.setLineEndTimestamp(at: 0, to: nil)
        model.stampSelectedLineEndNow()
        XCTAssertNil(model.session.lines.first?.endTimestamp)
    }

    func testStaleScrubKeepsRetainedPlayheadAndSuppressesSeek() async throws {
        var targets: [String] = []
        let (state, model) = try await makeModel(playing: false) { id, _ in targets.append(id) }
        model.seek(to: 11)
        XCTAssertEqual(targets, [track.id])
        model.updateLineText(at: 0, to: "Edited")
        model.previewScrub(to: 50)
        let other = TrackInfo(id: "other", title: "Other", artist: "", album: "", duration: 180, artworkURL: nil)
        state.setTrack(other, lyrics: [])
        model.endScrub(commit: true) // Before the track switch reaches the editor's subscriber.
        XCTAssertEqual(model.currentEditorPlaybackPosition(), 11)
        await deliverPlaybackUpdates()
        XCTAssertEqual(model.pendingNewTrack?.id, other.id)
        model.previewScrub(to: 70)
        model.endScrub(commit: true)
        XCTAssertEqual(model.currentEditorPlaybackPosition(), 11)
        XCTAssertEqual(targets, [track.id])

        state.setTrack(nil, lyrics: [])
        await deliverPlaybackUpdates()
        model.seek(to: 25)
        XCTAssertEqual(targets, [track.id, track.id])
        XCTAssertEqual(model.currentEditorPlaybackPosition(), 25)
    }
}
