@testable import BarTune
import JavaScriptCore
import XCTest

final class BrowserPlaybackCommandTests: XCTestCase {
    private let chrome = BrowserMediaMonitor.BrowserTarget(bundleId: "com.google.Chrome", appName: "Google Chrome", isSafari: false)

    func testAdjacentFractionalChapterStartsUseTheSelectedChapterForSeekAndSkip() throws {
        let starts = [0.0, 10.49, 10.51, 20.0]
        let first = try XCTUnwrap(BrowserMediaMonitor.currentChapterInterval(chapterStart: 10.49, chapterStarts: starts))
        XCTAssertEqual(first.start, 10.49)
        XCTAssertEqual(first.end, 10.51)
        let next = try XCTUnwrap(BrowserMediaMonitor.chapterSkipPlan(command: .nextTrack, chapterStart: 10.49, chapterStarts: starts))
        XCTAssertEqual(next.currentStart, 10.49)
        XCTAssertEqual(next.target, 10.51)
        let previous = try XCTUnwrap(BrowserMediaMonitor.chapterSkipPlan(command: .previousTrack, chapterStart: 10.51, chapterStarts: starts))
        XCTAssertEqual(previous.currentStart, 10.51)
        XCTAssertEqual(previous.target, 10.49)
    }

    func testSeekSurvivesPageTitleChangeOnlyWhenTheVideoIDAndURLStillMatch() throws {
        let tab = BrowserTabDescriptor(windowIndex: 1, tabIndex: 1, url: "https://www.youtube.com/watch?v=song")
        var target = BrowserMediaMonitor.ActiveBrowserTarget(
            browser: chrome, tab: tab, trackId: "song", expectedURL: tab.url, chapterStart: 0,
            expectedMediaTitle: "Song", expectedMediaId: "song", expectedRoundedDuration: 90
        )
        let context = try XCTUnwrap(JSContext())
        context.evaluateScript("""
        const location = { href: '\(tab.url)', search: '?v=song' };
        class URLSearchParams { constructor(search) { this.get = key => key === 'v' ? search.slice(3) : null; } }
        const media = { isConnected: true, duration: 90, currentTime: 0 };
        const window = { __barTuneActiveMedia: media };
        const navigator = { mediaSession: null };
        const document = { title: '(2) Song' };
        """)

        func seek() throws -> Double {
            let script = try XCTUnwrap(BrowserMediaMonitor.guardedCommandScriptSource(for: .seek(12), target: target))
            let line = try XCTUnwrap(script.components(separatedBy: " javascript ").last?.components(separatedBy: "\n").first)
            let js = try JSONDecoder().decode(String.self, from: Data(line.utf8))
            let result = context.evaluateScript("media.currentTime = 0; \(js); media.currentTime")
            XCTAssertNil(context.exception)
            return try XCTUnwrap(result).toDouble()
        }

        XCTAssertEqual(try seek(), 12)
        context.evaluateScript("location.href += '&list=mix'")
        XCTAssertEqual(try seek(), 0)
        context.evaluateScript("location.href = '\(tab.url)'")
        target.expectedMediaId = "other"
        XCTAssertEqual(try seek(), 0)

        target.expectedMediaId = ""
        XCTAssertEqual(try seek(), 0)
        context.evaluateScript("document.title = 'Song'")
        XCTAssertEqual(try seek(), 12)
        context.evaluateScript("navigator.mediaSession = { metadata: { title: 'Song', artist: 'Another Artist' } }")
        XCTAssertEqual(try seek(), 0)
        context.evaluateScript("navigator.mediaSession = null")
        context.evaluateScript("media.duration = 100")
        XCTAssertEqual(try seek(), 0)

        // Targets without either a video ID or an expected title (e.g. untitled chaptered tabs)
        // must not reject commands just because document.title is populated.
        context.evaluateScript("document.title = 'Untitled Chapter Video'; media.duration = 90")
        target.expectedMediaTitle = ""
        target.expectedMediaArtist = ""
        target.expectedRoundedDuration = nil
        XCTAssertEqual(try seek(), 12)
    }

    func testNonYouTubeQueryParameterDoesNotIdentifyThePlayingRecording() throws {
        let payload = ["BROWSER", "playing", "browser:open.spotify.com:Song|Artist", "Song", "Artist", "", "90", "0", "", "", "1", "other"]
            .joined(separator: "\u{1F}")
        let item = try XCTUnwrap(BrowserMediaParser.parsePayloadWithChapterStart(payload))
        XCTAssertTrue(item.mediaId.isEmpty)
        XCTAssertEqual(item.roundedDuration, 90)
    }
}
