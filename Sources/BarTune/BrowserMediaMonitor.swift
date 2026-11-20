import AppKit
import Foundation

enum BrowserMediaParser {
    static let supportedHosts: [String] = [
        "music.youtube.com",
        "open.spotify.com",
        "soundcloud.com",
        "music.apple.com",
    ]

    static func isSupportedMusicURL(_ urlString: String) -> Bool {
        guard let url = URL(string: urlString), let host = url.host?.lowercased() else {
            return false
        }
        if supportedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return true
        }
        if (host == "youtube.com" || host == "www.youtube.com") && url.path.hasPrefix("/watch") {
            return true
        }
        return false
    }

    private static let youtubeNoisePatterns: [String] = [
        #"\s*[\(\[]\s*(?:official\s+)?(?:music\s+video|lyric\s+video|audio|video|mv|m/v|visualizer|lyrics|hd|4k|hq)\s*[\)\]]"#,
        #"\s+official\s+(?:music\s+video|lyric\s+video|audio|video|mv|visualizer)$"#,
    ]

    static func cleanTitle(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip leading browser notification badge count, e.g. "(783) Song Title"
        title = title.replacingOccurrences(
            of: #"^\(\d+\)\s+"#,
            with: "",
            options: .regularExpression
        )
        for suffix in [" - YouTube Music", " - YouTube", " • Spotify"] where title.hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        for pattern in youtubeNoisePatterns {
            title = title.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func cleanArtist(_ raw: String) -> String {
        var artist = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if artist.hasSuffix(" - Topic") {
            artist = String(artist.dropLast(" - Topic".count)).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return artist
    }

    static func splitYouTubeArtistAndTitle(title: String, fallbackArtist: String) -> (artist: String, title: String) {
        for separator in [" - ", " – ", " — "] {
            if let range = title.range(of: separator) {
                let lhs = String(title[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let rhs = String(title[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !lhs.isEmpty && !rhs.isEmpty {
                    return (artist: lhs, title: rhs)
                }
            }
        }
        return (artist: fallbackArtist, title: title)
    }

    static func parsePayload(_ raw: String) -> PlaybackSnapshot? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "IDLE" else { return nil }

        let parts = trimmed.components(separatedBy: "\u{1F}")
        guard parts.count >= 8 else { return nil }

        let isPlaying = parts[1].lowercased() == "playing"
        guard isPlaying else { return nil }

        let trackId = parts[2]
        var title = cleanTitle(parts[3])
        guard !title.isEmpty else { return nil }

        var artist = cleanArtist(parts[4])
        let isStandardYouTube = trackId.hasPrefix("browser:www.youtube.com:")
            || trackId.hasPrefix("browser:youtube.com:")
        if isStandardYouTube {
            let split = splitYouTubeArtistAndTitle(title: title, fallbackArtist: artist)
            artist = split.artist
            title = split.title
        }

        let album = parts[5].trimmingCharacters(in: .whitespacesAndNewlines)
        let durationSec = SpotifyMonitor.parseLocaleDouble(parts[6]) ?? 0
        let positionSec = SpotifyMonitor.parseLocaleDouble(parts[7]) ?? 0
        let artworkURL = parts.count >= 9 && !parts[8].isEmpty ? parts[8] : nil

        let track = TrackInfo(
            id: trackId,
            title: title,
            artist: artist,
            album: album,
            duration: durationSec,
            artworkURL: artworkURL
        )

        return PlaybackSnapshot(
            isRunning: true,
            isPlaying: true,
            track: track,
            position: positionSec
        )
    }
}

@MainActor
final class BrowserMediaMonitor {
    private struct BrowserTarget {
        let bundleId: String
        let appName: String
        let isSafari: Bool
    }

    private static let browsers: [BrowserTarget] = [
        BrowserTarget(bundleId: "com.google.Chrome", appName: "Google Chrome", isSafari: false),
        BrowserTarget(bundleId: "company.thebrowser.Browser", appName: "Arc", isSafari: false),
        BrowserTarget(bundleId: "com.brave.Browser", appName: "Brave Browser", isSafari: false),
        BrowserTarget(bundleId: "com.microsoft.edgemac", appName: "Microsoft Edge", isSafari: false),
        BrowserTarget(bundleId: "com.apple.Safari", appName: "Safari", isSafari: true),
    ]

    // Compact JS evaluated in matched music tabs using the standard Web Media Session API
    // plus active <video>/<audio> currentTime and duration.
    private static let jsProbe: String = """
    (function(){try{var els=Array.from(document.querySelectorAll('video,audio'));var m=els.find(function(e){return !e.paused&&isFinite(e.duration)&&e.duration>0;});if(!m)return 'IDLE';var md=(navigator.mediaSession&&navigator.mediaSession.metadata)?navigator.mediaSession.metadata:null;var t=(md&&md.title)||document.title||'';var a=(md&&md.artist)||'';var al=(md&&md.album)||'';var art='';if(md&&md.artwork&&md.artwork.length){art=md.artwork[md.artwork.length-1].src||'';}var id='browser:'+location.hostname+':'+t+'|'+a;var s=String.fromCharCode(31);return ['BROWSER','playing',id,t,a,al,String(m.duration),String(m.currentTime),art].join(s);}catch(e){return 'IDLE';}})()
    """

    private static func escapedForAppleScript(_ js: String) -> String {
        js.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    func poll() -> PlaybackSnapshot? {
        let runningBundleIds = Set(
            NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
        )

        for browser in Self.browsers where runningBundleIds.contains(browser.bundleId) {
            if let raw = queryBrowser(browser),
               let snapshot = BrowserMediaParser.parsePayload(raw) {
                return snapshot
            }
        }
        return nil
    }

    private func queryBrowser(_ browser: BrowserTarget) -> String? {
        let escapedJS = Self.escapedForAppleScript(Self.jsProbe)
        let source: String = if browser.isSafari {
            """
            tell application "Safari"
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            set u to URL of t
                            if u contains "music.youtube.com" or u contains "youtube.com/watch" or u contains "open.spotify.com" or u contains "soundcloud.com" or u contains "music.apple.com" then
                                set res to do JavaScript "\(escapedJS)" in t
                                if res is not "IDLE" and res is not "" then return res
                            end if
                        end try
                    end repeat
                end repeat
            end tell
            return "IDLE"
            """
        } else {
            """
            tell application "\(browser.appName)"
                repeat with w in windows
                    repeat with t in tabs of w
                        try
                            set u to URL of t
                            if u contains "music.youtube.com" or u contains "youtube.com/watch" or u contains "open.spotify.com" or u contains "soundcloud.com" or u contains "music.apple.com" then
                                set res to execute t javascript "\(escapedJS)"
                                if res is not "IDLE" and res is not "" then return res
                            end if
                        end try
                    end repeat
                end repeat
            end tell
            return "IDLE"
            """
        }

        guard let script = NSAppleScript(source: source) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result.stringValue
    }
}
