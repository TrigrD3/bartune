import AppKit
import Foundation

struct YouTubeChapter: Equatable {
    let start: Double
    let title: String
}

struct BrowserTabDescriptor: Equatable {
    let windowIndex: Int
    let tabIndex: Int
    let url: String
}

enum BrowserMediaParser {
    static let supportedHosts: [String] = [
        "music.youtube.com",
        "open.spotify.com",
        "soundcloud.com",
        "music.apple.com",
    ]

    static let minChapterVideoDuration: Double = 600.0
    static let maxPlaybackRate: Double = 4.0

    static func isStandardYouTubeHost(_ host: String) -> Bool {
        let normalized = host.lowercased()
        return normalized == "youtube.com" || normalized == "www.youtube.com"
    }

    static func isStandardYouTubeTrackId(_ trackId: String) -> Bool {
        trackId.hasPrefix("browser:www.youtube.com:") || trackId.hasPrefix("browser:youtube.com:")
    }

    static func isSupportedMusicHost(_ host: String, includeYouTubeVideos: Bool = true) -> Bool {
        let normalized = host.lowercased()
        if supportedHosts.contains(where: { normalized == $0 || normalized.hasSuffix("." + $0) }) {
            return true
        }
        guard includeYouTubeVideos else { return false }
        return isStandardYouTubeHost(normalized)
    }

    static func isSupportedMusicURL(_ urlString: String, includeYouTubeVideos: Bool = true) -> Bool {
        guard let url = URL(string: urlString),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              let host = url.host?.lowercased()
        else {
            return false
        }
        if supportedHosts.contains(where: { host == $0 || host.hasSuffix("." + $0) }) {
            return true
        }
        guard includeYouTubeVideos else { return false }
        if isStandardYouTubeHost(host) &&
            (url.path == "/watch" || url.path.hasPrefix("/watch/")) {
            return true
        }
        return false
    }

    static func parseTabList(_ raw: String) -> [BrowserTabDescriptor] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        return trimmed.components(separatedBy: "\u{1E}").compactMap { entry in
            let fields = entry.components(separatedBy: "\u{1F}")
            guard fields.count >= 3,
                  let windowIndex = Int(fields[0]),
                  let tabIndex = Int(fields[1]),
                  windowIndex > 0,
                  tabIndex > 0
            else {
                return nil
            }
            let url = fields[2...].joined(separator: "\u{1F}").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !url.isEmpty else { return nil }
            return BrowserTabDescriptor(windowIndex: windowIndex, tabIndex: tabIndex, url: url)
        }
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
        let seconds: Double
        if !trimmed.contains(":") {
            guard let parsed = SpotifyMonitor.parseLocaleDouble(trimmed) else { return nil }
            seconds = parsed
        } else {
            let rawParts = trimmed.split(separator: ":", omittingEmptySubsequences: false)
            guard rawParts.count == 2 || rawParts.count == 3 else { return nil }
            let parts = rawParts.compactMap { Double($0) }
            guard parts.count == rawParts.count,
                  parts.allSatisfy({ $0.isFinite && $0 >= 0 })
            else { return nil }
            if parts.count == 2 {
                seconds = parts[0] * 60.0 + parts[1]
            } else {
                seconds = parts[0] * 3600.0 + parts[1] * 60.0 + parts[2]
            }
        }
        guard seconds.isFinite, seconds >= 0, Int(exactly: seconds.rounded()) != nil else {
            return nil
        }
        return seconds
    }

    static func parseChapters(_ raw: String) -> [YouTubeChapter] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        var bySecond: [Int: YouTubeChapter] = [:]
        for entry in trimmed.components(separatedBy: "\u{1D}") {
            let fields = entry.components(separatedBy: "\u{1E}")
            guard fields.count >= 2,
                  let start = parseTimestamp(fields[0]),
                  let key = Int(exactly: start.rounded())
            else { continue }
            let title = fields[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }
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

    static func parsePlaybackRate(_ raw: String) -> Double {
        guard let rate = SpotifyMonitor.parseLocaleDouble(raw), rate.isFinite else { return 1.0 }
        return min(max(rate, 0), maxPlaybackRate)
    }

    /// Appends a recording-specific part (media URL id, else rounded duration) so same-titled recordings differ.
    static func recordingTrackId(baseId: String, mediaId: String, duration: Double) -> String {
        let media = mediaId.trimmingCharacters(in: .whitespacesAndNewlines)
        if !media.isEmpty {
            return "\(baseId)|v:\(media)"
        }
        guard duration.isFinite, duration > 0, let seconds = Int(exactly: duration.rounded()) else { return baseId }
        return "\(baseId)|d:\(seconds)"
    }

    static func parsePayload(
        _ raw: String,
        sourceBundleId: String? = nil,
        includeYouTubeVideos: Bool = true
    ) -> PlaybackSnapshot? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "IDLE" else { return nil }

        let parts = trimmed.components(separatedBy: "\u{1F}")
        guard parts.count >= 8 else { return nil }

        let isPlaying = parts[1].lowercased() == "playing"
        guard isPlaying else { return nil }

        var trackId = parts[2]
        guard trackId.hasPrefix("browser:") else { return nil }
        let afterPrefix = trackId.dropFirst("browser:".count)
        guard let hostSeparator = afterPrefix.firstIndex(of: ":") else { return nil }
        let payloadHost = String(afterPrefix[..<hostSeparator])
        guard isSupportedMusicHost(payloadHost, includeYouTubeVideos: includeYouTubeVideos) else { return nil }

        var title = cleanTitle(parts[3])
        guard !title.isEmpty else { return nil }

        var artist = cleanArtist(parts[4])
        let album = parts[5].trimmingCharacters(in: .whitespacesAndNewlines)
        var durationSec = SpotifyMonitor.parseLocaleDouble(parts[6]) ?? 0
        var positionSec = SpotifyMonitor.parseLocaleDouble(parts[7]) ?? 0
        let artworkURL = parts.count >= 9 && !parts[8].isEmpty ? parts[8] : nil
        let playbackRate = parts.count >= 11 ? parsePlaybackRate(parts[10]) : 1.0

        let isStandardYouTube = isStandardYouTubeTrackId(trackId)
        let mediaId = parts.count >= 12 ? parts[11] : ""
        trackId = recordingTrackId(baseId: trackId, mediaId: mediaId, duration: durationSec)

        if isStandardYouTube,
           parts.count >= 10,
           !parts[9].isEmpty,
           let resolved = resolveActiveChapter(
               chapters: parseChapters(parts[9]),
               videoDuration: durationSec,
               currentTime: positionSec
           ) {
            let chapterTitle = cleanChapterTitle(resolved.chapter.title)
            if !chapterTitle.isEmpty, let chapterSecond = Int(exactly: resolved.chapter.start.rounded()) {
                let split = splitYouTubeArtistAndTitle(title: chapterTitle, fallbackArtist: "")
                artist = split.artist
                title = split.title
                durationSec = resolved.duration
                positionSec = resolved.position
                trackId = "\(trackId):ch:\(chapterSecond)"
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
            artworkURL: artworkURL,
            sourceBundleId: sourceBundleId
        )

        return PlaybackSnapshot(
            isRunning: true,
            isPlaying: true,
            track: track,
            position: positionSec,
            playbackRate: playbackRate
        )
    }
}

final class BrowserMediaMonitor: @unchecked Sendable {
    struct BrowserTarget: Equatable {
        let bundleId: String
        let appName: String
        let isSafari: Bool
    }

    static let browsers: [BrowserTarget] = [
        BrowserTarget(bundleId: "com.google.Chrome", appName: "Google Chrome", isSafari: false),
        BrowserTarget(bundleId: "company.thebrowser.Browser", appName: "Arc", isSafari: false),
        BrowserTarget(bundleId: "com.brave.Browser", appName: "Brave Browser", isSafari: false),
        BrowserTarget(bundleId: "com.microsoft.edgemac", appName: "Microsoft Edge", isSafari: false),
        BrowserTarget(bundleId: "com.apple.Safari", appName: "Safari", isSafari: true),
    ]

    // Compact JS evaluated in matched music tabs using the standard Web Media Session API
    // plus active <video>/<audio> currentTime and duration, and YouTube chapter markers for long videos.
    // Re-validates location protocol/hostname/pathname inside the document to prevent TOCTOU navigation races.
    static func jsProbeSource(includeYouTubeVideos: Bool) -> String {
        let youtubeOriginClause = includeYouTubeVideos
            ? "||((h==='youtube.com'||h==='www.youtube.com')&&(location.pathname==='/watch'||location.pathname.indexOf('/watch/')===0))"
            : ""
        let youtubeChaptersBlock = includeYouTubeVideos
            ? "if((h==='www.youtube.com'||h==='youtube.com')&&m.duration>=600){var vid=new URLSearchParams(location.search).get('v');if(vid){var gs=String.fromCharCode(29);var rs=String.fromCharCode(30);ch=Array.from(document.querySelectorAll('ytd-macro-markers-list-item-renderer')).map(function(el){var lk=el.querySelector('a[href]');var hr=lk?lk.getAttribute('href'):'';if(hr.indexOf('v='+vid)===-1)return '';var ti=el.querySelector('h4, #details h4');var tm=el.querySelector('#time');var tt=ti?ti.textContent.trim():'';var ts=tm?tm.textContent.trim():'';return (tt&&ts)?(ts+rs+tt):'';}).filter(Boolean).join(gs);}}"
            : ""
        return """
        (function(){try{var p=location.protocol;if(p!=='https:'&&p!=='http:')return 'IDLE';var h=(location.hostname||'').toLowerCase();var sup=['music.youtube.com','open.spotify.com','soundcloud.com','music.apple.com'];var ok=sup.some(function(d){return h===d||h.endsWith('.'+d);})\(youtubeOriginClause);if(!ok)return 'IDLE';var els=Array.from(document.querySelectorAll('video,audio'));var m=els.find(function(e){return !e.paused&&isFinite(e.duration)&&e.duration>0;});if(!m)return 'IDLE';var md=(navigator.mediaSession&&navigator.mediaSession.metadata)?navigator.mediaSession.metadata:null;var t=(md&&md.title)||document.title||'';var a=(md&&md.artist)||'';var al=(md&&md.album)||'';var art='';if(md&&md.artwork&&md.artwork.length){art=md.artwork[md.artwork.length-1].src||'';}var ch='';\(youtubeChaptersBlock)var id='browser:'+h+':'+t+'|'+a;var rid=new URLSearchParams(location.search).get('v')||'';var s=String.fromCharCode(31);return ['BROWSER','playing',id,t,a,al,String(m.duration),String(m.currentTime),art,ch,String(m.playbackRate),rid].join(s);}catch(e){return 'IDLE';}})()
        """
    }

    static var jsProbe: String {
        jsProbeSource(includeYouTubeVideos: true)
    }

    private static func escapeForAppleScript(_ js: String) -> String {
        js.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static let escapedJSWithYouTube: String = escapeForAppleScript(jsProbeSource(includeYouTubeVideos: true))
    private static let escapedJSWithoutYouTube: String = escapeForAppleScript(jsProbeSource(includeYouTubeVideos: false))

    // Compiled AppleScripts cached per browser bundle ID (accessed serially on SpotifyMonitor's scriptQueue).
    private var compiledListScripts: [String: NSAppleScript] = [:]
    private var compiledProbeScripts: [String: (windowIndex: Int, tabIndex: Int, includeYouTubeVideos: Bool, script: NSAppleScript)] = [:]

    private let listTabsHandler: ((BrowserTarget) -> [BrowserTabDescriptor])?
    private let probeTabHandler: ((BrowserTarget, BrowserTabDescriptor) -> String?)?

    init(
        listTabs: ((BrowserTarget) -> [BrowserTabDescriptor])? = nil,
        probeTab: ((BrowserTarget, BrowserTabDescriptor) -> String?)? = nil
    ) {
        listTabsHandler = listTabs
        probeTabHandler = probeTab
    }

    func poll(runningBundleIds: Set<String>, includeYouTubeVideos: Bool = false) -> PlaybackSnapshot? {
        for browser in Self.browsers where runningBundleIds.contains(browser.bundleId) {
            if let snapshot = pollBrowser(browser, includeYouTubeVideos: includeYouTubeVideos) {
                return snapshot
            }
        }
        return nil
    }

    func pollBrowser(_ browser: BrowserTarget, includeYouTubeVideos: Bool = false) -> PlaybackSnapshot? {
        let tabs = listTabs(for: browser)
        for tab in tabs where BrowserMediaParser.isSupportedMusicURL(tab.url, includeYouTubeVideos: includeYouTubeVideos) {
            if let raw = probeTab(tab, in: browser, includeYouTubeVideos: includeYouTubeVideos),
               let snapshot = BrowserMediaParser.parsePayload(
                   raw,
                   sourceBundleId: browser.bundleId,
                   includeYouTubeVideos: includeYouTubeVideos
               ) {
                return snapshot
            }
        }
        return nil
    }

    static func listTabsScriptSource(for browser: BrowserTarget) -> String {
        """
        tell application "\(browser.appName)"
            set outLines to {}
            set wCount to count of windows
            repeat with wi from 1 to wCount
                try
                    set tCount to count of tabs of window wi
                    repeat with ti from 1 to tCount
                        try
                            set u to URL of tab ti of window wi
                            if u is not missing value and u is not "" then
                                set end of outLines to (wi as string) & (character id 31) & (ti as string) & (character id 31) & u
                            end if
                        end try
                    end repeat
                end try
            end repeat
            set AppleScript's text item delimiters to (character id 30)
            set res to outLines as string
            set AppleScript's text item delimiters to ""
            return res
        end tell
        """
    }

    static func probeScriptSource(
        for browser: BrowserTarget,
        tab: BrowserTabDescriptor,
        includeYouTubeVideos: Bool = true
    ) -> String {
        let escapedJS = includeYouTubeVideos ? Self.escapedJSWithYouTube : Self.escapedJSWithoutYouTube
        if browser.isSafari {
            return """
            tell application "Safari"
                try
                    set res to do JavaScript "\(escapedJS)" in tab \(tab.tabIndex) of window \(tab.windowIndex)
                    if res is not missing value then return res
                end try
            end tell
            return "IDLE"
            """
        }
        return """
        tell application "\(browser.appName)"
            try
                set res to execute tab \(tab.tabIndex) of window \(tab.windowIndex) javascript "\(escapedJS)"
                if res is not missing value then return res
            end try
        end tell
        return "IDLE"
        """
    }

    private func listTabsScript(for browser: BrowserTarget) -> NSAppleScript? {
        if let cached = compiledListScripts[browser.bundleId] {
            return cached
        }
        guard let compiled = NSAppleScript(source: Self.listTabsScriptSource(for: browser)) else { return nil }
        compiledListScripts[browser.bundleId] = compiled
        return compiled
    }

    private func probeScript(
        for browser: BrowserTarget,
        tab: BrowserTabDescriptor,
        includeYouTubeVideos: Bool
    ) -> NSAppleScript? {
        if let cached = compiledProbeScripts[browser.bundleId],
           cached.windowIndex == tab.windowIndex,
           cached.tabIndex == tab.tabIndex,
           cached.includeYouTubeVideos == includeYouTubeVideos {
            return cached.script
        }
        let source = Self.probeScriptSource(for: browser, tab: tab, includeYouTubeVideos: includeYouTubeVideos)
        guard let compiled = NSAppleScript(source: source) else { return nil }
        compiledProbeScripts[browser.bundleId] = (tab.windowIndex, tab.tabIndex, includeYouTubeVideos, compiled)
        return compiled
    }

    private func listTabs(for browser: BrowserTarget) -> [BrowserTabDescriptor] {
        if let listTabsHandler {
            return listTabsHandler(browser)
        }
        guard let script = listTabsScript(for: browser) else { return [] }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil, let raw = result.stringValue else { return [] }
        return BrowserMediaParser.parseTabList(raw)
    }

    private func probeTab(
        _ tab: BrowserTabDescriptor,
        in browser: BrowserTarget,
        includeYouTubeVideos: Bool
    ) -> String? {
        if let probeTabHandler {
            return probeTabHandler(browser, tab)
        }
        guard let script = probeScript(for: browser, tab: tab, includeYouTubeVideos: includeYouTubeVideos) else { return nil }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return result.stringValue
    }
}
