@testable import BarTune
import XCTest

final class LyricsMatcherTests: XCTestCase {
    func testRejectsCoverAndKaraokeCandidatesWithMatchingDuration() {
        let track = TrackInfo(
            id: "spotify:track:boombayah",
            title: "BOOMBAYAH - Japanese Version",
            artist: "BLACKPINK",
            album: "BLACKPINK IN YOUR AREA (Japanese Version)",
            duration: 240.613,
            artworkURL: nil
        )

        let candidates: [NetEaseSongCandidate] = [
            NetEaseSongCandidate(
                id: 1_352_968_947,
                name: "BOOMBAYAH (BLACKPINK ARENA TOUR 2018 \"SPECIAL FINAL IN KYOCERA DOME OSAKA\")",
                artists: ["BLACKPINK"],
                durationMs: 244_300
            ),
            NetEaseSongCandidate(
                id: 2_744_284_428,
                name: "BOOMBAYAH - BLACKPINK by Rosie",
                artists: ["Suno.ai"],
                durationMs: 240_024
            ),
            NetEaseSongCandidate(
                id: 2_630_067_591,
                name: "BOOMBAYAH (붐바야) (By BLACKPINK) (Instrumental Karaoke Version)",
                artists: ["ZZang KARAOKE"],
                durationMs: 243_069
            ),
        ]

        XCTAssertNil(LyricsMatcher.selectBestNetEaseSong(candidates, for: track))
    }

    func testSelectsMatchingArtistWithinDurationTolerance() {
        let track = TrackInfo(
            id: "spotify:track:123",
            title: "Night Dancer",
            artist: "imase",
            album: "Bonsai",
            duration: 210.5,
            artworkURL: nil
        )

        let candidates: [NetEaseSongCandidate] = [
            NetEaseSongCandidate(id: 1, name: "Night Dancer", artists: ["Random Cover"], durationMs: 210_500),
            NetEaseSongCandidate(id: 2, name: "Night Dancer", artists: ["imase"], durationMs: 211_200),
            NetEaseSongCandidate(id: 3, name: "Night Dancer (Live)", artists: ["imase"], durationMs: 210_600),
        ]

        let selected = LyricsMatcher.selectBestNetEaseSong(candidates, for: track)
        XCTAssertEqual(selected?.id, 2)
    }
}
