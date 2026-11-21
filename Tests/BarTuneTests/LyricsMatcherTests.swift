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

    func testMatchesCrossScriptArtistWhenTitleAndDurationMatchTightly() {
        let track = TrackInfo(
            id: "spotify:track:reluctant",
            title: "The Reluctant Heroes",
            artist: "Sawano Hiroyuki",
            album: "Attack on Titan",
            duration: 267.12,
            artworkURL: nil
        )

        let candidates: [NetEaseSongCandidate] = [
            NetEaseSongCandidate(id: 26_562_718, name: "The Reluctant Heroes", artists: ["澤野弘之", "mpi"], durationMs: 267_120),
            NetEaseSongCandidate(id: 29_732_966, name: "The Reluctant Heroes(Instrumental)", artists: ["澤野弘之"], durationMs: 268_333),
        ]

        let selected = LyricsMatcher.selectBestNetEaseSong(candidates, for: track)
        XCTAssertEqual(selected?.id, 26_562_718)
    }

    func testSearchPrefersRequestedTitleOverCloserDuration() async {
        let track = TrackInfo(
            id: "spotify:track:dawn",
            title: "Dawn",
            artist: "Iris",
            album: "Daybreak",
            duration: 200.0,
            artworkURL: nil
        )

        // NetEase: Dusk has exact 200s duration, Dawn is 201s. Must pick Dawn.
        let netEaseCandidates: [NetEaseSongCandidate] = [
            NetEaseSongCandidate(id: 101, name: "Dusk", artists: ["Iris"], durationMs: 200_000),
            NetEaseSongCandidate(id: 102, name: "Dawn", artists: ["Iris"], durationMs: 201_000),
        ]
        let selectedNetEase = LyricsMatcher.selectBestNetEaseSong(netEaseCandidates, for: track)
        XCTAssertEqual(selectedNetEase?.id, 102)

        // LRCLIB search via LyricsFetcher after NetEase and LRCLIB exact miss.
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTuneMatcherTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fetcher = LyricsFetcher(diskCache: LyricsDiskCache(directory: tempDir, maxEntries: 10)) { request in
            let url = try XCTUnwrap(request.url)
            if url.host == "lrclib.net", url.path == "/api/search" {
                let json = """
                [
                  {"trackName":"Dusk","artistName":"Iris","duration":200.0,"syncedLyrics":"[00:01.00]Wrong song dusk"},
                  {"trackName":"Dawn","artistName":"Iris","duration":201.0,"syncedLyrics":"[00:01.00]Right song dawn"}
                ]
                """
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (Data(json.utf8), response)
            }
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        }

        let lines = await fetcher.fetchLyrics(for: track)
        XCTAssertEqual(lines.map(\.text), ["Right song dawn"])
    }

    func testRejectsDifferentSongEvenWhenOnlyCandidateMatchesArtistAndDuration() {
        let track = TrackInfo(
            id: "spotify:track:dawn-only",
            title: "Dawn",
            artist: "Iris",
            album: "",
            duration: 200.0,
            artworkURL: nil
        )
        let candidates: [NetEaseSongCandidate] = [
            NetEaseSongCandidate(id: 101, name: "Dusk", artists: ["Iris"], durationMs: 200_000),
        ]
        XCTAssertNil(LyricsMatcher.selectBestNetEaseSong(candidates, for: track))
    }

    func testAcceptsEditionAndBilingualTitleVariantsWhileRejectingSharedSuffixDifferentSongs() {
        let editionTrack = TrackInfo(
            id: "spotify:track:edition",
            title: "BOOMBAYAH - Japanese Version",
            artist: "BLACKPINK",
            album: "",
            duration: 240.0,
            artworkURL: nil
        )
        let editionCandidates = [
            NetEaseSongCandidate(id: 201, name: "BOOMBAYAH (Japanese Ver.)", artists: ["BLACKPINK"], durationMs: 240_500),
        ]
        XCTAssertEqual(LyricsMatcher.selectBestNetEaseSong(editionCandidates, for: editionTrack)?.id, 201)

        let bilingualTrack = TrackInfo(
            id: "spotify:track:bilingual",
            title: "夜に駆ける",
            artist: "YOASOBI",
            album: "",
            duration: 260.0,
            artworkURL: nil
        )
        let bilingualCandidates = [
            NetEaseSongCandidate(id: 202, name: "Yoru ni Kakeru (夜に駆ける)", artists: ["YOASOBI"], durationMs: 260_000),
        ]
        XCTAssertEqual(LyricsMatcher.selectBestNetEaseSong(bilingualCandidates, for: bilingualTrack)?.id, 202)

        let deluxeTrack = TrackInfo(
            id: "spotify:track:deluxe",
            title: "Dawn (Deluxe Edition)",
            artist: "Iris",
            album: "",
            duration: 200.0,
            artworkURL: nil
        )
        let wrongDeluxe = [
            NetEaseSongCandidate(id: 203, name: "Dusk (Deluxe Edition)", artists: ["Iris"], durationMs: 200_000),
        ]
        XCTAssertNil(LyricsMatcher.selectBestNetEaseSong(wrongDeluxe, for: deluxeTrack))
    }
}
