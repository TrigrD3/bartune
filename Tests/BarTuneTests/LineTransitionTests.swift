@testable import BarTune
import XCTest

@MainActor
final class LineTransitionTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "LineTransitionTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let track = TrackInfo(id: "track:t", title: "T", artist: "A", album: "", duration: 200, artworkURL: nil)
    private let lines = [
        LyricLine(id: 0, timestamp: 1.0, text: "First line"),
        LyricLine(id: 1, timestamp: 5.0, text: "Second line"),
    ]

    func testTransitionSettingsPersist() {
        let state = LyricsState(userDefaults: defaults)
        XCTAssertEqual(state.lineTransitionStyle, .subtle, "today's look stays the default")
        state.lineTransitionStyle = .pop
        state.lineTransitionDuration = 0.45
        state.lineTransitionStartsEarly = true
        state.wordPopEnabled = true

        let reloaded = LyricsState(userDefaults: defaults)
        XCTAssertEqual(reloaded.lineTransitionStyle, .pop)
        XCTAssertEqual(reloaded.lineTransitionDuration, 0.45, accuracy: 0.0001)
        XCTAssertTrue(reloaded.lineTransitionStartsEarly)
        XCTAssertTrue(reloaded.wordPopEnabled)
    }

    func testTransitionSpeedIsClampedToTheSliderRange() {
        let state = LyricsState(userDefaults: defaults)
        state.lineTransitionDuration = 2.0
        XCTAssertEqual(state.lineTransitionDuration, 0.6, accuracy: 0.0001)
        state.lineTransitionDuration = 0.01
        XCTAssertEqual(state.lineTransitionDuration, 0.15, accuracy: 0.0001)
    }

    func testStartEarlyShowsTheNextLineOneTransitionAhead() {
        let state = LyricsState(userDefaults: defaults)
        state.lineTransitionStyle = .slide
        state.lineTransitionDuration = 0.4
        state.setTrack(track, lyrics: lines)

        state.updatePlayback(isPlaying: true, position: 4.7)
        XCTAssertEqual(state.currentLineId, 0, "without Start Early the line changes on its timestamp")

        state.lineTransitionStartsEarly = true
        state.updatePlayback(isPlaying: true, position: 4.71)
        XCTAssertEqual(state.currentLineId, 1)

        state.lineTransitionStyle = .none
        state.updatePlayback(isPlaying: true, position: 4.72)
        XCTAssertEqual(state.currentLineId, 0, "with no transition there is nothing to start early")
    }

    func testWordPopRisesThenFadesOnTheWordBeingSung() throws {
        let words = [
            WordTimestamp(timestamp: 1.0, duration: 0.3, text: "Hi "),
            WordTimestamp(timestamp: 1.4, duration: 0.3, text: "there"),
        ]
        let boundaries = [0.0, 0.4, 1.0]

        XCTAssertNil(LyricsState.wordPop(words: words, boundaries: boundaries, position: 0.9))

        let rising = try XCTUnwrap(LyricsState.wordPop(words: words, boundaries: boundaries, position: 1.44))
        XCTAssertEqual(rising.start, 0.4)
        XCTAssertEqual(rising.end, 1.0)
        XCTAssertEqual(rising.strength, 0.5, accuracy: 0.01)

        let peak = try XCTUnwrap(LyricsState.wordPop(words: words, boundaries: boundaries, position: 1.48))
        XCTAssertEqual(peak.strength, 1.0, accuracy: 0.01)

        let faded = LyricsState.wordPop(words: words, boundaries: boundaries, position: 1.85)
        XCTAssertEqual(faded?.strength ?? 0, 0, accuracy: 0.01)

        XCTAssertNil(LyricsState.wordPop(words: words, boundaries: [0, 1], position: 1.44), "boundaries must match the words")
    }
}
