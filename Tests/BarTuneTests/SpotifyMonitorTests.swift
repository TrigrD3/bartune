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
}
