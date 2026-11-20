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
}
