import CryptoKit
import Foundation

struct LyricsDiskCache: Sendable {
    static let limitDefaultsKey = "bartune.lyricsCacheLimit"
    static let defaultMaxEntries = 1000

    let directory: URL
    /// Maximum cached songs (`0` means unlimited).
    let maxEntries: Int

    static func configuredMaxEntries(from ud: UserDefaults = .standard) -> Int {
        guard ud.object(forKey: limitDefaultsKey) != nil else {
            return defaultMaxEntries
        }
        return max(0, ud.integer(forKey: limitDefaultsKey))
    }

    static var `default`: LyricsDiskCache {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("com.arya.BarTune/lyrics", isDirectory: true)
        return LyricsDiskCache(directory: dir, maxEntries: configuredMaxEntries())
    }

    init(directory: URL, maxEntries: Int = defaultMaxEntries) {
        self.directory = directory
        self.maxEntries = max(0, maxEntries)
    }

    private func fileURL(for trackId: String) -> URL {
        let digest = SHA256.hash(data: Data(trackId.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(hex).json")
    }

    func load(trackId: String) -> [LyricLine]? {
        let url = fileURL(for: trackId)
        guard let data = try? Data(contentsOf: url),
              let lines = try? JSONDecoder().decode([LyricLine].self, from: data),
              !lines.isEmpty
        else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return lines
    }

    func save(trackId: String, lines: [LyricLine], maxEntriesOverride: Int? = nil) {
        guard !lines.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(lines) else { return }
        let url = fileURL(for: trackId)
        try? data.write(to: url, options: .atomic)
        prune(to: maxEntriesOverride ?? maxEntries)
    }

    func clear() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            try? fm.removeItem(at: file)
        }
    }

    func stats() -> (count: Int, bytes: Int64) {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return (0, 0) }

        var count = 0
        var totalBytes: Int64 = 0
        for file in files where file.pathExtension == "json" {
            count += 1
            if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                totalBytes += Int64(size)
            }
        }
        return (count, totalBytes)
    }

    func prune(to limit: Int) {
        guard limit > 0 else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let jsonFiles = files.filter { $0.pathExtension == "json" }
        guard jsonFiles.count > limit else { return }

        let sorted = jsonFiles.sorted { lhs, rhs in
            let d1 = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let d2 = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return d1 < d2
        }
        let excess = sorted.count - limit
        for file in sorted.prefix(excess) {
            try? fm.removeItem(at: file)
        }
    }
}

struct NetEaseSongCandidate: Equatable {
    let id: Int
    let name: String
    let artists: [String]
    let durationMs: Double?
}

enum LyricsMatcher {
    private static let unwantedKeywords = [
        "karaoke", "instrumental", "翻自", "cover", "live", "tour", "dome", "remix", "sped up", "slowed",
    ]

    static func normalize(_ text: String) -> String {
        text.lowercased()
            .unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
    }

    static func artistMatches(candidateArtists: [String], expectedArtist: String) -> Bool {
        let expected = normalize(expectedArtist)
        guard !expected.isEmpty else { return true }
        guard !candidateArtists.isEmpty else { return false }

        return candidateArtists.contains { raw in
            let candidate = normalize(raw)
            guard !candidate.isEmpty else { return false }
            return candidate == expected || candidate.contains(expected) || expected.contains(candidate)
        }
    }

    static func isUnwantedVariant(candidateTitle: String, expectedTitle: String) -> Bool {
        let candLower = candidateTitle.lowercased()
        let expLower = expectedTitle.lowercased()
        for keyword in unwantedKeywords where candLower.contains(keyword) && !expLower.contains(keyword) {
            return true
        }
        return false
    }

    static func selectBestNetEaseSong(_ songs: [NetEaseSongCandidate], for track: TrackInfo) -> NetEaseSongCandidate? {
        let nonVariant = songs.filter {
            !isUnwantedVariant(candidateTitle: $0.name, expectedTitle: track.title)
        }

        // 1. Prefer candidates with a matching artist within 6s duration tolerance.
        let artistMatched = nonVariant.filter { song in
            let durDiff = song.durationMs.map { abs($0 / 1000.0 - track.duration) } ?? 0
            return artistMatches(candidateArtists: song.artists, expectedArtist: track.artist) && durDiff <= 6.0
        }
        if let best = artistMatched.min(by: {
            abs(($0.durationMs ?? 0) / 1000.0 - track.duration) < abs(($1.durationMs ?? 0) / 1000.0 - track.duration)
        }) {
            return best
        }

        // 2. Cross-script fallback (e.g. Kanji "澤野弘之" vs Romaji "Sawano Hiroyuki"):
        // require a non-ASCII artist name, exact normalized title, and duration within 1.5s.
        let expectedNormTitle = normalize(track.title)
        guard !expectedNormTitle.isEmpty else { return nil }
        let crossScript = nonVariant.filter { song in
            let hasNonASCIIArtist = song.artists.contains { artist in
                artist.unicodeScalars.contains { !$0.isASCII }
            }
            let durDiff = song.durationMs.map { abs($0 / 1000.0 - track.duration) } ?? 999
            return hasNonASCIIArtist && normalize(song.name) == expectedNormTitle && durDiff <= 1.5
        }
        return crossScript.min {
            abs(($0.durationMs ?? 0) / 1000.0 - track.duration) < abs(($1.durationMs ?? 0) / 1000.0 - track.duration)
        }
    }
}

actor LyricsFetcher {
    private struct LRCLibRecord: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let trackName: String?
        let artistName: String?
        let duration: Double?
    }

    private struct NetEaseArtist: Decodable {
        let name: String
    }

    private struct NetEaseSearchResponse: Decodable {
        struct Result: Decodable {
            struct Song: Decodable {
                let id: Int
                let name: String
                let duration: Double?
                let artists: [NetEaseArtist]?
            }
            let songs: [Song]?
        }
        let result: Result?
    }

    private struct NetEaseLyricResponse: Decodable {
        struct LyricBlock: Decodable {
            let lyric: String?
        }
        let yrc: LyricBlock?
        let lrc: LyricBlock?
    }

    private var cache: [String: [LyricLine]] = [:]
    private let diskCache: LyricsDiskCache

    init(diskCache: LyricsDiskCache = .default) {
        self.diskCache = diskCache
    }

    func clearCache() {
        cache.removeAll()
        diskCache.clear()
    }

    func fetchLyrics(for track: TrackInfo) async -> [LyricLine] {
        if let cached = cache[track.id] {
            return cached
        }

        if let diskLines = diskCache.load(trackId: track.id) {
            cache[track.id] = diskLines
            return diskLines
        }

        // 1. Try NetEase YRC first for true millisecond word-by-word karaoke sync
        let netEase = await fetchNetEase(track: track)
        if let yrc = netEase.yrc, !yrc.isEmpty {
            cache[track.id] = yrc
            diskCache.save(trackId: track.id, lines: yrc, maxEntriesOverride: LyricsDiskCache.configuredMaxEntries())
            return yrc
        }

        // 2. Fall back to LRCLIB exact match
        if let exact = await fetchLRCLibExact(track: track), !exact.isEmpty {
            cache[track.id] = exact
            diskCache.save(trackId: track.id, lines: exact, maxEntriesOverride: LyricsDiskCache.configuredMaxEntries())
            return exact
        }

        // 3. Fall back to LRCLIB search
        if let searched = await fetchLRCLibSearch(track: track), !searched.isEmpty {
            cache[track.id] = searched
            diskCache.save(trackId: track.id, lines: searched, maxEntriesOverride: LyricsDiskCache.configuredMaxEntries())
            return searched
        }

        // 4. Final fallback: NetEase line-level LRC
        if let lrc = netEase.lrc, !lrc.isEmpty {
            cache[track.id] = lrc
            diskCache.save(trackId: track.id, lines: lrc, maxEntriesOverride: LyricsDiskCache.configuredMaxEntries())
            return lrc
        }

        cache[track.id] = []
        return []
    }

    private func fetchNetEase(track: TrackInfo) async -> (yrc: [LyricLine]?, lrc: [LyricLine]?) {
        var searchComp = URLComponents(string: "https://music.163.com/api/search/get")!
        searchComp.queryItems = [
            URLQueryItem(name: "s", value: "\(track.title) \(track.artist)"),
            URLQueryItem(name: "type", value: "1"),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let searchURL = searchComp.url else { return (nil, nil) }

        var searchReq = URLRequest(url: searchURL)
        searchReq.timeoutInterval = 5
        searchReq.setValue("BarTune/0.2 (macOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (searchData, searchResp) = try await URLSession.shared.data(for: searchReq)
            guard let http = searchResp as? HTTPURLResponse, http.statusCode == 200 else {
                return (nil, nil)
            }
            let decoded = try JSONDecoder().decode(NetEaseSearchResponse.self, from: searchData)
            guard let songs = decoded.result?.songs, !songs.isEmpty else { return (nil, nil) }

            let candidates = songs.map { song in
                NetEaseSongCandidate(
                    id: song.id,
                    name: song.name,
                    artists: (song.artists ?? []).map(\.name),
                    durationMs: song.duration
                )
            }
            guard let song = LyricsMatcher.selectBestNetEaseSong(candidates, for: track) else {
                return (nil, nil)
            }

            guard let lyricURL = URL(string: "https://music.163.com/api/song/lyric?id=\(song.id)&lv=1&yv=1") else {
                return (nil, nil)
            }
            var lyricReq = URLRequest(url: lyricURL)
            lyricReq.timeoutInterval = 5
            lyricReq.setValue("BarTune/0.2 (macOS)", forHTTPHeaderField: "User-Agent")

            let (lyricData, lyricResp) = try await URLSession.shared.data(for: lyricReq)
            guard let lHttp = lyricResp as? HTTPURLResponse, lHttp.statusCode == 200 else {
                return (nil, nil)
            }
            let lyricObj = try JSONDecoder().decode(NetEaseLyricResponse.self, from: lyricData)

            let parsedYRC = lyricObj.yrc?.lyric.flatMap { str -> [LyricLine]? in
                let lines = YRCParser.parse(str)
                return lines.isEmpty ? nil : lines
            }
            let parsedLRC = lyricObj.lrc?.lyric.flatMap { str -> [LyricLine]? in
                let lines = LRCParser.parse(str)
                return lines.isEmpty ? nil : lines
            }
            return (parsedYRC, parsedLRC)
        } catch {
            return (nil, nil)
        }
    }

    private func fetchLRCLibExact(track: TrackInfo) async -> [LyricLine]? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "album_name", value: track.album),
            URLQueryItem(name: "duration", value: String(Int(track.duration.rounded())))
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("BarTune/0.2 (macOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let record = try JSONDecoder().decode(LRCLibRecord.self, from: data)
            guard let synced = record.syncedLyrics, !synced.isEmpty else { return nil }
            return LRCParser.parse(synced)
        } catch {
            return nil
        }
    }

    private func fetchLRCLibSearch(track: TrackInfo) async -> [LyricLine]? {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "track_name", value: track.title)
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("BarTune/0.2 (macOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let records = try JSONDecoder().decode([LRCLibRecord].self, from: data)
            let best = records
                .filter { record in
                    guard (record.syncedLyrics ?? "").isEmpty == false else { return false }
                    if let artist = record.artistName,
                       !LyricsMatcher.artistMatches(candidateArtists: [artist], expectedArtist: track.artist) {
                        return false
                    }
                    if let dur = record.duration, abs(dur - track.duration) > 6.0 {
                        return false
                    }
                    return true
                }
                .min { lhs, rhs in
                    let d1 = abs((lhs.duration ?? track.duration) - track.duration)
                    let d2 = abs((rhs.duration ?? track.duration) - track.duration)
                    return d1 < d2
                }
            guard let synced = best?.syncedLyrics else { return nil }
            return LRCParser.parse(synced)
        } catch {
            return nil
        }
    }
}
