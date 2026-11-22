@testable import BarTune
import XCTest

final class SpotifyMonitorTests: XCTestCase {
    private func run(_ source: String) throws -> String? {
        let script = try XCTUnwrap(NSAppleScript(source: source))
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        XCTAssertNil(error)
        return result.stringValue
    }

    func testDeniedPlayerDoesNotAbortLaterPlayers() throws {
        let source = SpotifyMonitor.nativePlayerScriptSource(playerBlocks: [
            #"error "Not authorized to send Apple events to Spotify." number -1743"#,
            #"return "MUSIC" & sep & "playing""#,
        ])
        XCTAssertEqual(try run(source), "MUSIC\u{1F}playing")
    }

    func testFirstPlayingPlayerKeepsPriority() throws {
        let source = SpotifyMonitor.nativePlayerScriptSource(playerBlocks: [
            #"return "SPOTIFY""#,
            #"return "MUSIC""#,
        ])
        XCTAssertEqual(try run(source), "SPOTIFY")
        XCTAssertEqual(try run(SpotifyMonitor.nativePlayerScriptSource(playerBlocks: [])), "IDLE")
    }

    func testBrowserSnapshotNeverTargetsNativeTransport() {
        let runningSets: [Set<String>] = [
            ["com.apple.Music"],
            ["com.spotify.client"],
            ["com.spotify.client", "com.apple.Music"],
        ]
        for command in [PlaybackCommand.playPause, .nextTrack, .previousTrack] {
            for running in runningSets {
                XCTAssertNil(SpotifyMonitor.transportScriptSource(
                    for: command,
                    activeTrackId: "browser:www.youtube.com:Example|A",
                    runningBundleIds: running
                ))
            }
        }
    }

    func testNativeTracksRouteToTheirOwnPlayer() {
        let both: Set<String> = ["com.spotify.client", "com.apple.Music"]
        XCTAssertEqual(
            SpotifyMonitor.transportScriptSource(for: .nextTrack, activeTrackId: "music:ABC", runningBundleIds: both),
            "tell application \"Music\" to next track"
        )
        XCTAssertEqual(
            SpotifyMonitor.transportScriptSource(for: .playPause, activeTrackId: "spotify:track:1", runningBundleIds: both),
            "tell application \"Spotify\" to playpause"
        )
    }

    func testAcceptedBrowserSnapshotFiltersStandardYouTubeIndependentlyOfYouTubeMusic() {
        let ytTrack = TrackInfo(
            id: "browser:www.youtube.com:Video Title|Channel|v:abc",
            title: "Video Title",
            artist: "Channel",
            album: "",
            duration: 300,
            artworkURL: nil,
            sourceBundleId: "com.google.Chrome"
        )
        let ytSnap = PlaybackSnapshot(isRunning: true, isPlaying: true, track: ytTrack, position: 12)

        let ytMusicTrack = TrackInfo(
            id: "browser:music.youtube.com:Night Dancer|imase|v:xyz",
            title: "Night Dancer",
            artist: "imase",
            album: "Bonsai",
            duration: 210,
            artworkURL: nil,
            sourceBundleId: "com.google.Chrome"
        )
        let ytMusicSnap = PlaybackSnapshot(isRunning: true, isPlaying: true, track: ytMusicTrack, position: 15)

        XCTAssertNil(
            SpotifyMonitor.acceptedBrowserSnapshot(ytSnap, browserMusicEnabled: true, includeYouTubeVideos: false)
        )
        XCTAssertNotNil(
            SpotifyMonitor.acceptedBrowserSnapshot(ytSnap, browserMusicEnabled: true, includeYouTubeVideos: true)
        )
        XCTAssertEqual(
            SpotifyMonitor.acceptedBrowserSnapshot(ytMusicSnap, browserMusicEnabled: true, includeYouTubeVideos: false)?.track?.id,
            ytMusicTrack.id
        )
        XCTAssertNil(
            SpotifyMonitor.acceptedBrowserSnapshot(ytMusicSnap, browserMusicEnabled: false, includeYouTubeVideos: true)
        )
    }
}
