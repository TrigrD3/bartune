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
        XCTAssertEqual(snapshot?.track?.id, "browser:www.youtube.com:Kenshi Yonezu Playlist|CuratorChannel|d:3600:ch:431")
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

    func testChapterTimestampRequiresRepresentableSecond() {
        XCTAssertNil(BrowserMediaParser.parseTimestamp(String(Double.greatestFiniteMagnitude)))
        XCTAssertNil(BrowserMediaParser.parseTimestamp("inf"))
        XCTAssertNil(BrowserMediaParser.parseTimestamp("nan"))
        XCTAssertNil(BrowserMediaParser.parseTimestamp("1e20:00"))
        XCTAssertNil(BrowserMediaParser.parseTimestamp("9223372036854775808"))
        XCTAssertNil(BrowserMediaParser.parseTimestamp("-5"))
        XCTAssertNil(BrowserMediaParser.parseTimestamp("1:abc:30"))
        XCTAssertEqual(BrowserMediaParser.parseTimestamp("1:05.5") ?? -1, 65.5, accuracy: 0.001)
    }

    func testParseChaptersSkipsOutOfRangeAndMalformedTimestampsWithoutCrashing() {
        let gs = "\u{1D}"
        let rs = "\u{1E}"
        let raw = [
            "0:00\(rs)Intro",
            "\(Double.greatestFiniteMagnitude)\(rs)Overflow Float",
            "inf\(rs)Infinite",
            "nan\(rs)Not a Number",
            "1e20:00\(rs)Overflow Minutes",
            "9223372036854775808\(rs)IntMax Plus One",
            "1:05.5\(rs)Chorus",
        ].joined(separator: gs)

        let chapters = BrowserMediaParser.parseChapters(raw)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0], YouTubeChapter(start: 0.0, title: "Intro"))
        XCTAssertEqual(chapters[1].start, 65.5, accuracy: 0.001)
        XCTAssertEqual(chapters[1].title, "Chorus")
    }

    func testRejectsSpoofedMusicURLsAndUnsupportedPayloadHosts() {
        XCTAssertFalse(BrowserMediaParser.isSupportedMusicURL("https://private.invalid/watch?ref=music.youtube.com"))
        XCTAssertFalse(BrowserMediaParser.isSupportedMusicURL("https://private.invalid/youtube.com/watch?v=abc"))
        XCTAssertFalse(BrowserMediaParser.isSupportedMusicURL("https://music.youtube.com.evil.invalid/watch?v=abc"))
        XCTAssertFalse(BrowserMediaParser.isSupportedMusicURL("https://notmusic.youtube.com/watch?v=abc"))
        XCTAssertFalse(BrowserMediaParser.isSupportedMusicURL("https://music.youtube.com@evil.invalid/watch?v=abc"))
        XCTAssertFalse(BrowserMediaParser.isSupportedMusicURL("https://www.youtube.com/watch-later"))
        XCTAssertFalse(BrowserMediaParser.isSupportedMusicURL("javascript:music.youtube.com"))
        XCTAssertFalse(BrowserMediaParser.isSupportedMusicURL("file://music.youtube.com/track"))

        let sep = "\u{1F}"
        let spoofedPayload = [
            "BROWSER",
            "playing",
            "browser:private.invalid:Confidential Call|Internal",
            "Confidential Call",
            "Internal",
            "",
            "180.0",
            "12.0",
            "",
        ].joined(separator: sep)
        XCTAssertNil(BrowserMediaParser.parsePayload(spoofedPayload))
    }

    func testAdaptersProbeOnlyAllowedOrigins() {
        let sep = "\u{1F}"
        let validPayload = [
            "BROWSER",
            "playing",
            "browser:music.youtube.com:Night Dancer|imase",
            "Night Dancer",
            "imase",
            "Bonsai",
            "210.0",
            "30.0",
            "",
        ].joined(separator: sep)

        let tabs = [
            BrowserTabDescriptor(windowIndex: 1, tabIndex: 1, url: "https://private.invalid/music.youtube.com/watch?v=1"),
            BrowserTabDescriptor(windowIndex: 1, tabIndex: 2, url: "https://private.invalid/call?next=https://open.spotify.com/track/1"),
            BrowserTabDescriptor(windowIndex: 1, tabIndex: 3, url: "https://music.youtube.com.evil.invalid/watch?v=1"),
            BrowserTabDescriptor(windowIndex: 1, tabIndex: 4, url: "https://music.youtube.com/watch?v=abc123"),
        ]

        let targets = BrowserMediaMonitor.browsers.filter {
            $0.bundleId == "com.apple.Safari" || $0.bundleId == "com.google.Chrome"
        }
        XCTAssertEqual(targets.count, 2)

        for target in targets {
            var probedTabs: [BrowserTabDescriptor] = []
            let monitor = BrowserMediaMonitor(
                listTabs: { _ in tabs },
                probeTab: { _, tab in
                    probedTabs.append(tab)
                    return validPayload
                }
            )

            let snapshot = monitor.poll(runningBundleIds: [target.bundleId])
            XCTAssertEqual(probedTabs, [tabs[3]], "Only the allowed origin tab should be probed for \(target.appName)")
            XCTAssertEqual(snapshot?.track?.sourceBundleId, target.bundleId)
            XCTAssertEqual(snapshot?.track?.title, "Night Dancer")

            let listScript = BrowserMediaMonitor.listTabsScriptSource(for: target)
            XCTAssertFalse(listScript.contains("u contains"))
            let probeScript = BrowserMediaMonitor.probeScriptSource(for: target, tab: tabs[3])
            XCTAssertFalse(probeScript.contains("u contains"))
            if target.isSafari {
                XCTAssertTrue(probeScript.contains("do JavaScript"))
            } else {
                XCTAssertTrue(probeScript.contains("execute tab 4 of window 1 javascript"))
            }
        }

        XCTAssertTrue(BrowserMediaMonitor.jsProbe.contains("location.hostname"))
        XCTAssertTrue(BrowserMediaMonitor.jsProbe.contains("location.protocol"))
    }

    func testParseTabListHandlesValidAndMalformedEntries() {
        let us = "\u{1F}"
        let rs = "\u{1E}"
        let raw = [
            "1\(us)1\(us)https://music.youtube.com/watch?v=abc",
            "bad\(us)2\(us)https://open.spotify.com/track/1",
            "2\(us)3\(us)https://private.invalid/path?a=1",
        ].joined(separator: rs)

        let parsed = BrowserMediaParser.parseTabList(raw)
        XCTAssertEqual(parsed, [
            BrowserTabDescriptor(windowIndex: 1, tabIndex: 1, url: "https://music.youtube.com/watch?v=abc"),
            BrowserTabDescriptor(windowIndex: 2, tabIndex: 3, url: "https://private.invalid/path?a=1"),
        ])
    }

    @MainActor
    func testBrowserRateScalesInterpolation() throws {
        let sep = "\u{1F}"
        let fields = ["BROWSER", "playing", "browser:music.youtube.com:Example|A", "Example", "A", "", "180", "20", "", ""]
        let fast = try XCTUnwrap(BrowserMediaParser.parsePayload((fields + ["2"]).joined(separator: sep)))
        XCTAssertEqual(fast.position(after: 0.5), 21.0, accuracy: 0.001)

        let legacy = try XCTUnwrap(BrowserMediaParser.parsePayload(fields.joined(separator: sep)))
        XCTAssertEqual(legacy.position(after: 0.5), 20.5, accuracy: 0.001)

        XCTAssertEqual(BrowserMediaParser.parsePlaybackRate("1,5"), 1.5, accuracy: 0.001)
        XCTAssertEqual(BrowserMediaParser.parsePlaybackRate("100"), BrowserMediaParser.maxPlaybackRate)
        XCTAssertEqual(BrowserMediaParser.parsePlaybackRate("-1"), 0)
        XCTAssertEqual(BrowserMediaParser.parsePlaybackRate("NaN"), 1.0)
        XCTAssertEqual(BrowserMediaParser.parsePlaybackRate("abc"), 1.0)

        let paused = PlaybackSnapshot(isRunning: true, isPlaying: false, track: fast.track, position: 20, playbackRate: 2)
        XCTAssertEqual(paused.position(after: 0.5), 20.0, accuracy: 0.001)

        let suiteName = "com.arya.bartune.tests.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }
        let state = LyricsState(userDefaults: ud)
        let line = LyricLine(id: 0, timestamp: 20.0, duration: 4.0, text: "Line")
        state.setTrack(fast.track, lyrics: [line])
        state.updatePlayback(isPlaying: true, position: fast.position, playbackRate: fast.playbackRate)
        let expected = LyricsState.computeLineProgress(
            line: line,
            nextTimestamp: state.activeLineNextTimestamp,
            position: 21.0
        )
        XCTAssertEqual(state.liveProgress(at: state.playbackAnchorDate.addingTimeInterval(0.5)), expected, accuracy: 0.001)
    }

    func testDistinctRecordingsHaveDistinctIDs() throws {
        let sep = "\u{1F}"
        func payload(mediaId: String?, duration: String, position: String) -> String {
            var fields = [
                "BROWSER", "playing", "browser:www.youtube.com:Example|A", "Example", "A", "", duration, position, "", "", "1",
            ]
            if let mediaId { fields.append(mediaId) }
            return fields.joined(separator: sep)
        }
        func id(_ raw: String) throws -> String {
            try XCTUnwrap(BrowserMediaParser.parsePayload(raw)?.track?.id)
        }

        let first = try id(payload(mediaId: "aaaaaaaaaaa", duration: "180", position: "10"))
        let second = try id(payload(mediaId: "bbbbbbbbbbb", duration: "240", position: "10"))
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(first, try id(payload(mediaId: "aaaaaaaaaaa", duration: "180", position: "95.5")))

        // Without a media id (e.g. legacy payloads), the rounded duration distinguishes recordings.
        let shortTake = try id(payload(mediaId: nil, duration: "180.2", position: "10"))
        XCTAssertNotEqual(shortTake, try id(payload(mediaId: nil, duration: "240", position: "10")))
        XCTAssertEqual(shortTake, try id(payload(mediaId: nil, duration: "180.2", position: "120")))
    }

    func testDisablingOrdinaryYouTubeVideosPreservesYouTubeMusicSupport() {
        XCTAssertFalse(BrowserMediaParser.isSupportedMusicURL("https://www.youtube.com/watch?v=xyz789", includeYouTubeVideos: false))
        XCTAssertFalse(BrowserMediaParser.isSupportedMusicURL("https://youtube.com/watch?v=xyz789", includeYouTubeVideos: false))
        XCTAssertTrue(BrowserMediaParser.isSupportedMusicURL("https://music.youtube.com/watch?v=abc123", includeYouTubeVideos: false))
        XCTAssertTrue(BrowserMediaParser.isSupportedMusicURL("https://open.spotify.com/track/123", includeYouTubeVideos: false))
        XCTAssertTrue(BrowserMediaParser.isSupportedMusicURL("https://www.youtube.com/watch?v=xyz789", includeYouTubeVideos: true))

        let sep = "\u{1F}"
        let ytPayload = [
            "BROWSER", "playing", "browser:www.youtube.com:Talk Title|Channel", "Talk Title", "Channel", "", "300", "20", "",
        ].joined(separator: sep)
        let ytMusicPayload = [
            "BROWSER", "playing", "browser:music.youtube.com:Night Dancer|imase", "Night Dancer", "imase", "Bonsai", "210", "15", "",
        ].joined(separator: sep)

        XCTAssertNil(BrowserMediaParser.parsePayload(ytPayload, includeYouTubeVideos: false))
        XCTAssertNotNil(BrowserMediaParser.parsePayload(ytPayload, includeYouTubeVideos: true))
        XCTAssertEqual(
            BrowserMediaParser.parsePayload(ytMusicPayload, includeYouTubeVideos: false)?.track?.title,
            "Night Dancer"
        )

        let tabs = [
            BrowserTabDescriptor(windowIndex: 1, tabIndex: 1, url: "https://www.youtube.com/watch?v=nonmusic"),
            BrowserTabDescriptor(windowIndex: 1, tabIndex: 2, url: "https://music.youtube.com/watch?v=abc123"),
        ]
        var probedWhenDisabled: [BrowserTabDescriptor] = []
        let monitor = BrowserMediaMonitor(
            listTabs: { _ in tabs },
            probeTab: { _, tab in
                probedWhenDisabled.append(tab)
                return tab.tabIndex == 1 ? ytPayload : ytMusicPayload
            }
        )

        let disabledSnapshot = monitor.poll(runningBundleIds: ["com.google.Chrome"], includeYouTubeVideos: false)
        XCTAssertEqual(probedWhenDisabled, [tabs[1]])
        XCTAssertEqual(disabledSnapshot?.track?.title, "Night Dancer")

        var probedWhenEnabled: [BrowserTabDescriptor] = []
        let enabledMonitor = BrowserMediaMonitor(
            listTabs: { _ in [tabs[0]] },
            probeTab: { _, tab in
                probedWhenEnabled.append(tab)
                return ytPayload
            }
        )
        let enabledSnapshot = enabledMonitor.poll(runningBundleIds: ["com.google.Chrome"], includeYouTubeVideos: true)
        XCTAssertEqual(probedWhenEnabled, [tabs[0]])
        XCTAssertEqual(enabledSnapshot?.track?.title, "Talk Title")

        let restrictedJS = BrowserMediaMonitor.jsProbeSource(includeYouTubeVideos: false)
        XCTAssertFalse(restrictedJS.contains("www.youtube.com"))
        XCTAssertFalse(restrictedJS.contains("h==='youtube.com'"))
        XCTAssertTrue(restrictedJS.contains("music.youtube.com"))

        let permissiveJS = BrowserMediaMonitor.jsProbeSource(includeYouTubeVideos: true)
        XCTAssertTrue(permissiveJS.contains("www.youtube.com"))

        let restrictedAppleScript = BrowserMediaMonitor.probeScriptSource(
            for: BrowserMediaMonitor.browsers[0],
            tab: tabs[1],
            includeYouTubeVideos: false
        )
        XCTAssertFalse(restrictedAppleScript.contains("www.youtube.com"))
    }

    func testOutOfRangeBrowserDurationSkipsLRCLibExactAndCompletesFallback() async throws {
        let sep = "\u{1F}"
        for rawDuration in ["1e20", String(Double.greatestFiniteMagnitude), "9223372036854775808", "inf", "nan", "-5"] {
            let payload = [
                "BROWSER",
                "playing",
                "browser:music.youtube.com:Dawn|Iris",
                "Dawn",
                "Iris",
                "Daybreak",
                rawDuration,
                "12.0",
                "",
            ].joined(separator: sep)
            let parsedTrack = try XCTUnwrap(BrowserMediaParser.parsePayload(payload)?.track)
            XCTAssertTrue(parsedTrack.duration.isFinite)
            XCTAssertGreaterThanOrEqual(parsedTrack.duration, 0)
            XCTAssertNotNil(Int(exactly: parsedTrack.duration.rounded()))
        }

        let payload = [
            "BROWSER",
            "playing",
            "browser:music.youtube.com:Dawn|Iris",
            "Dawn",
            "Iris",
            "Daybreak",
            "1e20",
            "12.0",
            "",
        ].joined(separator: sep)
        let parsedTrack = try XCTUnwrap(BrowserMediaParser.parsePayload(payload)?.track)

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTuneDurationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        final class RequestRecorder: @unchecked Sendable {
            private let lock = NSLock()
            private var paths: [String] = []
            func record(_ path: String) {
                lock.lock()
                defer { lock.unlock() }
                paths.append(path)
            }
            func allPaths() -> [String] {
                lock.lock()
                defer { lock.unlock() }
                return paths
            }
        }

        let recorder = RequestRecorder()
        let fetcher = LyricsFetcher(diskCache: LyricsDiskCache(directory: tempDir, maxEntries: 10)) { request in
            let url = try XCTUnwrap(request.url)
            recorder.record(url.path)
            if url.host == "lrclib.net", url.path == "/api/search" {
                let json = """
                [{"trackName":"Dawn","artistName":"Iris","duration":200.0,"syncedLyrics":"[00:01.00]Fallback line"}]
                """
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (Data(json.utf8), response)
            }
            let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: 404, httpVersion: nil, headerFields: nil))
            return (Data(), response)
        }

        let parsedLines = await fetcher.fetchLyrics(for: parsedTrack)
        XCTAssertEqual(parsedLines.map(\.text), ["Fallback line"])
        XCTAssertFalse(recorder.allPaths().contains("/api/get"))
        XCTAssertTrue(recorder.allPaths().contains("/api/search"))

        // Also verify LyricsFetcher directly guards unrepresented durations passed outside the parser.
        let directTrack = TrackInfo(
            id: "browser:music.youtube.com:Dawn|Iris|direct",
            title: "Dawn",
            artist: "Iris",
            album: "Daybreak",
            duration: 1e20,
            artworkURL: nil
        )
        let directLines = await fetcher.fetchLyrics(for: directTrack)
        XCTAssertEqual(directLines.map(\.text), ["Fallback line"])
        XCTAssertFalse(recorder.allPaths().contains("/api/get"))
    }
}
