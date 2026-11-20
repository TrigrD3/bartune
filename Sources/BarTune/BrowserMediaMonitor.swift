import AppKit
import Foundation

struct YouTubeChapter: Equatable {
    let start: Double
    let title: String
}

enum BrowserMediaParser {
    static let supportedHosts: [String] = [
        "music.youtube.com",
        "open.spotify.com",
        "soundcloud.com",
        "music.apple.com",
    ]

    static let minChapterVideoDuration: Double = 600.0

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
        #"\s+(?:official\s+)?(?:music\s+video|lyric\s+video|official\s+audio|official\s+video|mv|m/v|visualizer)$"#,
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
        // Prefer quoted song titles (e.g. `Artist “Song” × ...` or `Artist「Song」Official MV`)
        // before dash-splitting so dashes in tie-in subtitles aren't mistaken for Artist - Title.
        if let quotedMatch = extractQuotedArtistAndTitle(from: title) {
            return quotedMatch
        }
        for separator in [" - ", " – ", " — "] {
            if let range = title.range(of: separator) {
                let lhs = stripWrappingQuotes(String(title[..<range.lowerBound]))
                let rhs = stripWrappingQuotes(String(title[range.upperBound...]))
                if !lhs.isEmpty && !rhs.isEmpty {
                    // Detect reversed `"Song Title" - Artist` format when channel name matches rhs
                    let normFallback = LyricsMatcher.normalize(fallbackArtist)
                    let normLhs = LyricsMatcher.normalize(lhs)
                    let normRhs = LyricsMatcher.normalize(rhs)
                    if !normFallback.isEmpty,
                       normRhs.contains(normFallback),
                       !normLhs.contains(normFallback) {
                        return (artist: fallbackArtist, title: lhs)
                    }
                    return (artist: lhs, title: rhs)
                }
            }
        }
        return (artist: fallbackArtist, title: stripWrappingQuotes(title))
    }

    private static func stripWrappingQuotes(_ text: String) -> String {
        var out = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("「", "」"), ("『", "』")]
        for (open, close) in pairs where out.first == open && out.last == close && out.count >= 2 {
            out = String(out.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return out
    }

    private static func extractQuotedArtistAndTitle(from title: String) -> (artist: String, title: String)? {
        let pairs: [(open: Character, close: Character)] = [
            ("「", "」"),
            ("『", "』"),
            ("“", "”"),
        ]
        for pair in pairs {
            guard let openIdx = title.firstIndex(of: pair.open),
                  let closeIdx = title[title.index(after: openIdx)...].firstIndex(of: pair.close)
            else { continue }
            let artist = String(title[..<openIdx]).trimmingCharacters(in: .whitespacesAndNewlines)
            let song = String(title[title.index(after: openIdx)..<closeIdx])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !artist.isEmpty && !song.isEmpty {
                return (artist: artist, title: song)
            }
        }
        return nil
    }

    static func parseTimestamp(_ raw: String) -> Double? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if !trimmed.contains(":") {
            return SpotifyMonitor.parseLocaleDouble(trimmed)
        }
        let parts = trimmed.split(separator: ":").compactMap { Double($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        if parts.count == 2 {
            return parts[0] * 60.0 + parts[1]
        }
        return parts[0] * 3600.0 + parts[1] * 60.0 + parts[2]
    }

    static func parseChapters(_ raw: String) -> [YouTubeChapter] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var bySecond: [Int: YouTubeChapter] = [:]
        for entry in trimmed.components(separatedBy: "\u{1D}") {
            let fields = entry.components(separatedBy: "\u{1E}")
            guard fields.count >= 2,
                  let start = parseTimestamp(fields[0]),
                  start >= 0
            else { continue }
            let title = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
            let key = Int(start.rounded())
            if bySecond[key] == nil {
                bySecond[key] = YouTubeChapter(start: start, title: title)
            }
        }
        return bySecond.values.sorted { $0.start < $1.start }
    }

    static func cleanChapterTitle(_ raw: String) -> String {
        var title = cleanTitle(raw)
        // Strip leading track numbers like "01. ", "1) ", "01 - "
        title = title.replacingOccurrences(
            of: #"^\d{1,3}\s*[\.\)\-]\s+"#,
            with: "",
            options: .regularExpression
        )
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func resolveActiveChapter(
        chapters: [YouTubeChapter],
        videoDuration: Double,
        currentTime: Double
    ) -> (chapter: YouTubeChapter, duration: Double, position: Double)? {
        guard chapters.count >= 2, videoDuration >= minChapterVideoDuration else { return nil }
        let sorted = chapters.sorted { $0.start < $1.start }
        var activeIndex: Int?
        for (idx, chapter) in sorted.enumerated() where chapter.start <= currentTime {
            activeIndex = idx
        }
        guard let idx = activeIndex else { return nil }
        let active = sorted[idx]
        let nextStart = (idx + 1 < sorted.count) ? sorted[idx + 1].start : videoDuration
        let chapterDuration = max(0, nextStart - active.start)
        guard chapterDuration > 0 else { return nil }
        let relativePosition = max(0, currentTime - active.start)
        return (chapter: active, duration: chapterDuration, position: relativePosition)
    }

    static func parsePayload(_ raw: String) -> PlaybackSnapshot? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "IDLE" else { return nil }

        let parts = trimmed.components(separatedBy: "\u{1F}")
        guard parts.count >= 8 else { return nil }

        let isPlaying = parts[1].lowercased() == "playing"
        guard isPlaying else { return nil }

        var trackId = parts[2]
        var title = cleanTitle(parts[3])
        guard !title.isEmpty else { return nil }

        var artist = cleanArtist(parts[4])
        let album = parts[5].trimmingCharacters(in: .whitespacesAndNewlines)
        var durationSec = SpotifyMonitor.parseLocaleDouble(parts[6]) ?? 0
        var positionSec = SpotifyMonitor.parseLocaleDouble(parts[7]) ?? 0
        let artworkURL = parts.count >= 9 && !parts[8].isEmpty ? parts[8] : nil

        let isStandardYouTube = trackId.hasPrefix("browser:www.youtube.com:")
            || trackId.hasPrefix("browser:youtube.com:")

        if isStandardYouTube,
           parts.count >= 10,
           !parts[9].isEmpty,
           let resolved = resolveActiveChapter(
               chapters: parseChapters(parts[9]),
               videoDuration: durationSec,
               currentTime: positionSec
           ) {
            let chapterTitle = cleanChapterTitle(resolved.chapter.title)
            if !chapterTitle.isEmpty {
                let split = splitYouTubeArtistAndTitle(title: chapterTitle, fallbackArtist: "")
                artist = split.artist
                title = split.title
                durationSec = resolved.duration
                positionSec = resolved.position
                trackId = "\(trackId):ch:\(Int(resolved.chapter.start.rounded()))"
            }
        } else if isStandardYouTube {
            let split = splitYouTubeArtistAndTitle(title: title, fallbackArtist: artist)
            artist = split.artist
            title = split.title
        }

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

final class BrowserMediaMonitor: @unchecked Sendable {
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
    // plus active <video>/<audio> currentTime and duration, and YouTube chapter markers for long videos.
    private static let jsProbe: String = """
    (function(){try{var els=Array.from(document.querySelectorAll('video,audio'));var m=els.find(function(e){return !e.paused&&isFinite(e.duration)&&e.duration>0;});if(!m)return 'IDLE';var md=(navigator.mediaSession&&navigator.mediaSession.metadata)?navigator.mediaSession.metadata:null;var t=(md&&md.title)||document.title||'';var a=(md&&md.artist)||'';var al=(md&&md.album)||'';var art='';if(md&&md.artwork&&md.artwork.length){art=md.artwork[md.artwork.length-1].src||'';}var ch='';if((location.hostname==='www.youtube.com'||location.hostname==='youtube.com')&&m.duration>=600){var vid=new URLSearchParams(location.search).get('v');if(vid){var gs=String.fromCharCode(29);var rs=String.fromCharCode(30);ch=Array.from(document.querySelectorAll('ytd-macro-markers-list-item-renderer')).map(function(el){var lk=el.querySelector('a[href]');var hr=lk?lk.getAttribute('href'):'';if(hr.indexOf('v='+vid)===-1)return '';var ti=el.querySelector('h4, #details h4');var tm=el.querySelector('#time');var tt=ti?ti.textContent.trim():'';var ts=tm?tm.textContent.trim():'';return (tt&&ts)?(ts+rs+tt):'';}).filter(Boolean).join(gs);}}var id='browser:'+location.hostname+':'+t+'|'+a;var s=String.fromCharCode(31);return ['BROWSER','playing',id,t,a,al,String(m.duration),String(m.currentTime),art,ch].join(s);}catch(e){return 'IDLE';}})()
    """

    private static let escapedJS: String = jsProbe
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "\"", with: "\\\"")

    // Compiled AppleScripts cached per browser bundle ID (accessed serially on SpotifyMonitor's scriptQueue).
    private var compiledScripts: [String: NSAppleScript] = [:]

    func poll(runningBundleIds: Set<String>) -> PlaybackSnapshot? {
        for browser in Self.browsers where runningBundleIds.contains(browser.bundleId) {
            if let raw = queryBrowser(browser),
               let snapshot = BrowserMediaParser.parsePayload(raw) {
                return snapshot
            }
        }
        return nil
    }

    private func script(for browser: BrowserTarget) -> NSAppleScript? {
        if let cached = compiledScripts[browser.bundleId] {
            return cached
        }
        let escapedJS = Self.escapedJS
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

        guard let compiled = NSAppleScript(source: source) else { return nil }
        compiledScripts[browser.bundleId] = compiled
        return compiled
    }

    private func queryBrowser(_ browser: BrowserTarget) -> String? {
        guard let script = script(for: browser) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result.stringValue
    }
}
