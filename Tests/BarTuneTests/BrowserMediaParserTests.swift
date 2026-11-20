@testable import BarTune
import XCTest

final class BrowserMediaParserTests: XCTestCase {
    func testRecognizesSupportedMusicURLs() {
        XCTAssertTrue(BrowserMediaParser.isSupportedMusicURL("https://music.youtube.com/watch?v=abc123"))
        XCTAssertTrue(BrowserMediaParser.isSupportedMusicURL("https://www.youtube.com/watch?v=xyz789"))
        XCTAssertTrue(BrowserMediaParser.isSupportedMusicURL("https://open.spotify.com/track/123"))
        XCTAssertTrue(BrowserMediaParser.isSupportedMusicURL("https://soundcloud.com/artist/track"))
        XCTAssertTrue(BrowserMediaParser.isSupportedMusicURL("https://music.apple.com/us/album/test"))

        XCTAssertFalse(BrowserMediaParser.isSupportedMusicURL("https://www.youtube.com/"))
        XCTAssertFalse(BrowserMediaParser.isSupportedMusicURL("https://github.com/TrigrD3/bartune"))
    }

    func testParsesValidBrowserPayloadAndCleansTitle() {
        let sep = "\u{1F}"
        let payload = [
            "BROWSER",
            "playing",
            "browser:music.youtube.com:Night Dancer|imase",
            "Night Dancer - YouTube Music",
            "imase",
            "Bonsai",
            "210,5",
            "42,25",
            "https://lh3.googleusercontent.com/art.jpg",
        ].joined(separator: sep)

        let snapshot = BrowserMediaParser.parsePayload(payload)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.isPlaying, true)
        XCTAssertEqual(snapshot?.track?.title, "Night Dancer")
        XCTAssertEqual(snapshot?.track?.artist, "imase")
        XCTAssertEqual(snapshot?.track?.album, "Bonsai")
        XCTAssertEqual(snapshot?.track?.duration ?? 0, 210.5, accuracy: 0.001)
        XCTAssertEqual(snapshot?.position ?? 0, 42.25, accuracy: 0.001)
        XCTAssertEqual(snapshot?.track?.artworkURL, "https://lh3.googleusercontent.com/art.jpg")
    }

    func testIgnoresIdleOrPausedPayloads() {
        XCTAssertNil(BrowserMediaParser.parsePayload("IDLE"))
        let sep = "\u{1F}"
        let paused = ["BROWSER", "paused", "id", "Song", "Artist", "", "180", "10", ""].joined(separator: sep)
        XCTAssertNil(BrowserMediaParser.parsePayload(paused))
    }

    func testParsesStandardYouTubeVideoTitleAndStripsNoiseTags() {
        let sep = "\u{1F}"
        let payload = [
            "BROWSER",
            "playing",
            "browser:www.youtube.com:ONE OK ROCK - Wherever You Are [Official Music Video]|Fueled By Ramen",
            "(783) ONE OK ROCK - Wherever You Are [Official Music Video] - YouTube",
            "Fueled By Ramen",
            "",
            "295.0",
            "42.0",
            "https://i.ytimg.com/vi/abc/hqdefault.jpg",
        ].joined(separator: sep)

        let snapshot = BrowserMediaParser.parsePayload(payload)
        XCTAssertEqual(snapshot?.track?.artist, "ONE OK ROCK")
        XCTAssertEqual(snapshot?.track?.title, "Wherever You Are")
    }

    func testCleansYouTubeTopicChannelNameWhenTitleHasNoSeparator() {
        let sep = "\u{1F}"
        let payload = [
            "BROWSER",
            "playing",
            "browser:www.youtube.com:Night Dancer|imase - Topic",
            "Night Dancer (Official Audio)",
            "imase - Topic",
            "",
            "210.0",
            "15.0",
            "",
        ].joined(separator: sep)

        let snapshot = BrowserMediaParser.parsePayload(payload)
        XCTAssertEqual(snapshot?.track?.artist, "imase")
        XCTAssertEqual(snapshot?.track?.title, "Night Dancer")
    }

    func testDoesNotSplitHyphenatedTitleOnYouTubeMusic() {
        let sep = "\u{1F}"
        let payload = [
            "BROWSER",
            "playing",
            "browser:music.youtube.com:Unravel - Acoustic Version|TK from Ling tosite sigure",
            "Unravel - Acoustic Version",
            "TK from Ling tosite sigure",
            "Unravel",
            "238.0",
            "20.0",
            "",
        ].joined(separator: sep)

        let snapshot = BrowserMediaParser.parsePayload(payload)
        XCTAssertEqual(snapshot?.track?.artist, "TK from Ling tosite sigure")
        XCTAssertEqual(snapshot?.track?.title, "Unravel - Acoustic Version")
    }

    func testResolvesActiveYouTubeChapterForLongCompilationVideo() {
        let sep = "\u{1F}"
        let gs = "\u{1D}"
        let rs = "\u{1E}"
        let chapters = [
            "0:00\(rs)01. Lemon",
            "2:27\(rs)02. 春雷",
            "7:11\(rs)03. Kenshi Yonezu - KICK BACK",
            "10:26\(rs)04. Uma to Shika",
            // Duplicate chapter rendered in secondary DOM panel should be deduplicated
            "7:11\(rs)03. Kenshi Yonezu - KICK BACK",
        ].joined(separator: gs)

        let payload = [
            "BROWSER",
            "playing",
            "browser:www.youtube.com:Kenshi Yonezu Playlist|CuratorChannel",
            "Kenshi Yonezu Playlist",
            "CuratorChannel",
            "",
            "3600.0",
            "450.0", // 7:30 -> 19s into "KICK BACK" (7:11..10:26 = 195s)
            "https://i.ytimg.com/vi/abc/hqdefault.jpg",
            chapters,
        ].joined(separator: sep)

        let snapshot = BrowserMediaParser.parsePayload(payload)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.track?.artist, "Kenshi Yonezu")
        XCTAssertEqual(snapshot?.track?.title, "KICK BACK")
        XCTAssertEqual(snapshot?.track?.duration ?? 0, 195.0, accuracy: 0.001)
        XCTAssertEqual(snapshot?.position ?? 0, 19.0, accuracy: 0.001)
        XCTAssertEqual(snapshot?.track?.id, "browser:www.youtube.com:Kenshi Yonezu Playlist|CuratorChannel:ch:431")
    }

    func testIgnoresChaptersOnShortSingleSongVideos() {
        let sep = "\u{1F}"
        let gs = "\u{1D}"
        let rs = "\u{1E}"
        let chapters = [
            "0:00\(rs)Intro",
            "0:30\(rs)Chorus",
        ].joined(separator: gs)

        let payload = [
            "BROWSER",
            "playing",
            "browser:www.youtube.com:Kenshi Yonezu - IRIS OUT|Kenshi Yonezu",
            "Kenshi Yonezu - IRIS OUT",
            "Kenshi Yonezu",
            "",
            "153.0",
            "45.0",
            "",
            chapters,
        ].joined(separator: sep)

        let snapshot = BrowserMediaParser.parsePayload(payload)
        XCTAssertEqual(snapshot?.track?.artist, "Kenshi Yonezu")
        XCTAssertEqual(snapshot?.track?.title, "IRIS OUT")
        XCTAssertEqual(snapshot?.track?.duration ?? 0, 153.0, accuracy: 0.001)
        XCTAssertEqual(snapshot?.position ?? 0, 45.0, accuracy: 0.001)
    }

    func testExtractsQuotedYouTubeTitleBeforeDashSplitting() {
        let sep = "\u{1F}"
        let payload = [
            "BROWSER",
            "playing",
            "browser:www.youtube.com:JANE DOE|Kenshi Yonezu",
            "Kenshi Yonezu, Hikaru Utada “JANE DOE” × \"Chainsaw Man – The Movie: Reze Arc\" Special Video",
            "Kenshi Yonezu  米津玄師",
            "",
            "236.641",
            "110.3",
            "",
        ].joined(separator: sep)

        let snapshot = BrowserMediaParser.parsePayload(payload)
        XCTAssertEqual(snapshot?.track?.artist, "Kenshi Yonezu, Hikaru Utada")
        XCTAssertEqual(snapshot?.track?.title, "JANE DOE")
    }

    func testDetectsReversedSongDashArtistYouTubeTitleUsingChannelName() {
        let sep = "\u{1F}"
        let payload = [
            "BROWSER",
            "playing",
            "browser:www.youtube.com:\"Crying for Rain\" - 美波 (Minami) MV|美波",
            "\"Crying for Rain\" - 美波 (Minami) MV",
            "美波",
            "",
            "253.361",
            "60.0",
            "",
        ].joined(separator: sep)

        let snapshot = BrowserMediaParser.parsePayload(payload)
        XCTAssertEqual(snapshot?.track?.artist, "美波")
        XCTAssertEqual(snapshot?.track?.title, "Crying for Rain")
    }
}
