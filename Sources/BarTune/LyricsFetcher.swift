import CryptoKit
import Foundation

struct CachedLyricsEntry: Codable, Equatable, Sendable {
    let trackId: String?
    let title: String?
    let artist: String?
    let cachedAt: Date?
    let lines: [LyricLine]
}

struct CachedSongSummary: Identifiable, Equatable, Sendable {
    let cacheKey: String
    let trackId: String?
    let title: String
    let artist: String
    let lineCount: Int
    let sizeBytes: Int64
    let modifiedAt: Date
    let syncEngine: AudioSyncEngine?

    var id: String { cacheKey }
    var isAudioSynced: Bool { syncEngine != nil }
}

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

    static func cacheKey(for trackId: String) -> String {
        let digest = SHA256.hash(data: Data(trackId.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func fileURL(for trackId: String) -> URL {
        directory.appendingPathComponent("\(Self.cacheKey(for: trackId)).json")
    }

    func fileURL(forCacheKey cacheKey: String) -> URL {
        directory.appendingPathComponent("\(cacheKey).json")
    }

    private static func decodeEntry(from data: Data) -> CachedLyricsEntry? {
        if let entry = try? JSONDecoder().decode(CachedLyricsEntry.self, from: data), !entry.lines.isEmpty {
            return entry
        }
        if let legacyLines = try? JSONDecoder().decode([LyricLine].self, from: data), !legacyLines.isEmpty {
            return CachedLyricsEntry(trackId: nil, title: nil, artist: nil, cachedAt: nil, lines: legacyLines)
        }
        return nil
    }

    func loadEntry(trackId: String) -> CachedLyricsEntry? {
        let url = fileURL(for: trackId)
        guard let data = try? Data(contentsOf: url),
              let entry = Self.decodeEntry(from: data)
        else { return nil }
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
        return entry
    }

    func load(trackId: String) -> [LyricLine]? {
        loadEntry(trackId: trackId)?.lines
    }

    func save(
        trackId: String,
        lines: [LyricLine],
        title: String? = nil,
        artist: String? = nil,
        maxEntriesOverride: Int? = nil
    ) {
        guard !lines.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let entry = CachedLyricsEntry(
            trackId: trackId,
            title: title,
            artist: artist,
            cachedAt: Date(),
            lines: lines
        )
        guard let data = try? JSONEncoder().encode(entry) else { return }
        let url = fileURL(for: trackId)
        try? data.write(to: url, options: .atomic)
        prune(to: maxEntriesOverride ?? maxEntries)
    }

    func loadByCacheKey(_ cacheKey: String) -> CachedLyricsEntry? {
        let url = fileURL(forCacheKey: cacheKey)
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Self.decodeEntry(from: data)
    }

    func saveByCacheKey(_ cacheKey: String, entry: CachedLyricsEntry) {
        guard !entry.lines.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONEncoder().encode(entry) else { return }
        try? data.write(to: fileURL(forCacheKey: cacheKey), options: .atomic)
    }

    func removeByCacheKey(_ cacheKey: String) {
        try? FileManager.default.removeItem(at: fileURL(forCacheKey: cacheKey))
    }

    func listEntries(audioSyncCache: AudioSyncedLyricsCache = .default) -> [CachedSongSummary] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var summaries: [CachedSongSummary] = []
        for file in files where file.pathExtension == "json" {
            let key = file.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: file),
                  let entry = Self.decodeEntry(from: data)
            else { continue }

            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let sizeBytes = Int64(values?.fileSize ?? data.count)
            let modifiedAt = entry.cachedAt ?? values?.contentModificationDate ?? .distantPast
            let fallbackTitle = entry.lines.first(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.text
                ?? "Cached Song"
            let title = (entry.title?.isEmpty == false) ? (entry.title ?? fallbackTitle) : fallbackTitle
            let artist = entry.artist ?? ""
            let syncEngine = audioSyncCache.syncEngine(forCacheKey: key)

            summaries.append(
                CachedSongSummary(
                    cacheKey: key,
                    trackId: entry.trackId,
                    title: title,
                    artist: artist,
                    lineCount: entry.lines.count,
                    sizeBytes: sizeBytes,
                    modifiedAt: modifiedAt,
                    syncEngine: syncEngine
                )
            )
        }

        return summaries.sorted { $0.modifiedAt > $1.modifiedAt }
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

/// Small least-recently-used dictionary that keeps at most `capacity` values in memory.
struct LRUMemoryCache<Value> {
    static var defaultCapacity: Int { 32 }

    let capacity: Int
    private var values: [String: Value] = [:]
    private var order: [String] = []

    init(capacity: Int = defaultCapacity) {
        self.capacity = max(1, capacity)
    }

    subscript(key: String) -> Value? {
        mutating get {
            guard let value = values[key] else { return nil }
            touch(key)
            return value
        }
        set {
            guard let newValue else {
                removeValue(forKey: key)
                return
            }
            values[key] = newValue
            touch(key)
            while order.count > capacity {
                values.removeValue(forKey: order.removeFirst())
            }
        }
    }

    mutating func removeValue(forKey key: String) {
        removeAll { $0 == key }
    }

    mutating func removeAll(where shouldRemove: (String) -> Bool = { _ in true }) {
        order.removeAll(where: shouldRemove)
        values = values.filter { !shouldRemove($0.key) }
    }

    private mutating func touch(_ key: String) {
        order.removeAll { $0 == key }
        order.append(key)
    }
}

/// Removes cached songs from disk and from the live fetcher and translator memory caches.
struct OfflineCacheRemover: Sendable {
    let fetcher: LyricsFetcher
    let translator: LyricsTranslator
    var lyricsCache: LyricsDiskCache = .default
    var syncCache: AudioSyncedLyricsCache = .default

    func remove(_ song: CachedSongSummary) async {
        lyricsCache.removeByCacheKey(song.cacheKey)
        syncCache.removeByCacheKey(song.cacheKey)
        await fetcher.invalidateMemoryCache(trackId: song.trackId)
        await translator.invalidateMemoryCache(trackId: song.trackId)
    }

    func removeAll() async {
        lyricsCache.clear()
        syncCache.clear()
        await fetcher.invalidateMemoryCache(trackId: nil)
        await translator.clearCache()
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

    private static func stripTitleDecorations(_ title: String) -> String {
        var stripped = title.replacingOccurrences(
            of: #"[\(\[\（\【][^\)\]\）\】]*[\)\]\）\】]"#,
            with: " ",
            options: .regularExpression
        )
        for separator in [" - ", " – ", " — "] {
            if let range = stripped.range(of: separator) {
                stripped = String(stripped[..<range.lowerBound])
            }
        }
        stripped = stripped.replacingOccurrences(
            of: #"\s+(?:feat\.?|ft\.?|featuring)\b.*$"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
        return stripped
    }

    private static func alternateTitleSegments(_ title: String) -> [String] {
        var segments: [String] = []

        if let regex = try? NSRegularExpression(pattern: #"[\(\[\（\【]([^\)\]\）\】]+)[\)\]\）\】]"#) {
            let nsTitle = title as NSString
            let range = NSRange(location: 0, length: nsTitle.length)
            for match in regex.matches(in: title, range: range) where match.numberOfRanges > 1 {
                let inner = normalize(nsTitle.substring(with: match.range(at: 1)))
                if !inner.isEmpty {
                    segments.append(inner)
                }
            }
        }

        let core = stripTitleDecorations(title)
        for separator in [" / ", "／"] where core.contains(separator) {
            for part in core.components(separatedBy: separator) {
                let normalizedPart = normalize(part)
                if !normalizedPart.isEmpty {
                    segments.append(normalizedPart)
                }
            }
        }

        return segments
    }

    static func titleMatches(candidateTitle: String, expectedTitle: String) -> Bool {
        let expFull = normalize(expectedTitle)
        guard !expFull.isEmpty else { return true }
        let candFull = normalize(candidateTitle)
        guard !candFull.isEmpty else { return false }

        if candFull == expFull {
            return true
        }

        let candCore = normalize(stripTitleDecorations(candidateTitle))
        let expCore = normalize(stripTitleDecorations(expectedTitle))
        if !candCore.isEmpty, !expCore.isEmpty, candCore == expCore {
            return true
        }
        if !candCore.isEmpty, candCore == expFull {
            return true
        }
        if !expCore.isEmpty, candFull == expCore {
            return true
        }

        let candAlternates = alternateTitleSegments(candidateTitle)
        if candAlternates.contains(where: { $0 == expFull || (!expCore.isEmpty && $0 == expCore) }) {
            return true
        }
        let expAlternates = alternateTitleSegments(expectedTitle)
        if expAlternates.contains(where: { $0 == candFull || (!candCore.isEmpty && $0 == candCore) }) {
            return true
        }

        return false
    }

    static func selectBestNetEaseSong(_ songs: [NetEaseSongCandidate], for track: TrackInfo) -> NetEaseSongCandidate? {
        let nonVariant = songs.filter {
            !isUnwantedVariant(candidateTitle: $0.name, expectedTitle: track.title)
        }

        // 1. Prefer candidates with matching artist and title within 6s duration tolerance.
        let artistMatched = nonVariant.filter { song in
            let durDiff = song.durationMs.map { abs($0 / 1000.0 - track.duration) } ?? 0
            return artistMatches(candidateArtists: song.artists, expectedArtist: track.artist)
                && titleMatches(candidateTitle: song.name, expectedTitle: track.title)
                && durDiff <= 6.0
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

    static func selectBestLRCLibRecord(
        _ records: [LyricsFetcher.LRCLibRecord],
        for track: TrackInfo
    ) -> LyricsFetcher.LRCLibRecord? {
        records
            .filter { record in
                guard (record.syncedLyrics ?? "").isEmpty == false else { return false }
                if let trackName = record.trackName {
                    guard !isUnwantedVariant(candidateTitle: trackName, expectedTitle: track.title),
                          titleMatches(candidateTitle: trackName, expectedTitle: track.title)
                    else { return false }
                } else if !normalize(track.title).isEmpty {
                    return false
                }
                if let artist = record.artistName,
                   !artistMatches(candidateArtists: [artist], expectedArtist: track.artist) {
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
    }
}

actor LyricsFetcher {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    struct LRCLibRecord: Decodable, Equatable {
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

    private var cache: LRUMemoryCache<[LyricLine]>
    private let diskCache: LyricsDiskCache
    private let dataLoader: DataLoader

    init(
        diskCache: LyricsDiskCache = .default,
        memoryCapacity: Int = LRUMemoryCache<[LyricLine]>.defaultCapacity,
        dataLoader: @escaping DataLoader = { try await URLSession.shared.data(for: $0) }
    ) {
        self.diskCache = diskCache
        self.dataLoader = dataLoader
        cache = LRUMemoryCache(capacity: memoryCapacity)
    }

    func clearCache() {
        cache.removeAll()
        diskCache.clear()
    }

    func invalidateMemoryCache(trackId: String?) {
        if let trackId {
            cache.removeValue(forKey: trackId)
        } else {
            cache.removeAll()
        }
    }

    func fetchLyrics(for track: TrackInfo) async -> [LyricLine] {
        if let cached = cache[track.id] {
            return cached
        }

        if let diskEntry = diskCache.loadEntry(trackId: track.id) {
            // Upgrade legacy cache files with track title/artist metadata on next play.
            if diskEntry.title == nil || diskEntry.trackId == nil {
                diskCache.save(
                    trackId: track.id,
                    lines: diskEntry.lines,
                    title: track.title,
                    artist: track.artist,
                    maxEntriesOverride: LyricsDiskCache.configuredMaxEntries()
                )
            }
            cache[track.id] = diskEntry.lines
            return diskEntry.lines
        }

        do {
            // 1. Try NetEase YRC first for true millisecond word-by-word karaoke sync
            try Task.checkCancellation()
            let netEase = try await fetchNetEase(track: track)
            if let yrc = netEase.yrc, !yrc.isEmpty {
                cache[track.id] = yrc
                diskCache.save(
                    trackId: track.id,
                    lines: yrc,
                    title: track.title,
                    artist: track.artist,
                    maxEntriesOverride: LyricsDiskCache.configuredMaxEntries()
                )
                return yrc
            }

            // 2. Fall back to LRCLIB exact match
            try Task.checkCancellation()
            if let exact = try await fetchLRCLibExact(track: track), !exact.isEmpty {
                cache[track.id] = exact
                diskCache.save(
                    trackId: track.id,
                    lines: exact,
                    title: track.title,
                    artist: track.artist,
                    maxEntriesOverride: LyricsDiskCache.configuredMaxEntries()
                )
                return exact
            }

            // 3. Fall back to LRCLIB search
            try Task.checkCancellation()
            if let searched = try await fetchLRCLibSearch(track: track), !searched.isEmpty {
                cache[track.id] = searched
                diskCache.save(
                    trackId: track.id,
                    lines: searched,
                    title: track.title,
                    artist: track.artist,
                    maxEntriesOverride: LyricsDiskCache.configuredMaxEntries()
                )
                return searched
            }

            // 4. Final fallback: NetEase line-level LRC
            try Task.checkCancellation()
            if let lrc = netEase.lrc, !lrc.isEmpty {
                cache[track.id] = lrc
                diskCache.save(
                    trackId: track.id,
                    lines: lrc,
                    title: track.title,
                    artist: track.artist,
                    maxEntriesOverride: LyricsDiskCache.configuredMaxEntries()
                )
                return lrc
            }

            return []
        } catch is CancellationError {
            return []
        } catch {
            return []
        }
    }

    private static func isCancellationError(_ error: Error) -> Bool {
        error is CancellationError
            || (error as? URLError)?.code == .cancelled
            || Task.isCancelled
    }

    private func fetchNetEase(track: TrackInfo) async throws -> (yrc: [LyricLine]?, lrc: [LyricLine]?) {
        try Task.checkCancellation()
        guard var searchComp = URLComponents(string: "https://music.163.com/api/search/get") else {
            return (nil, nil)
        }
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
            let (searchData, searchResp) = try await dataLoader(searchReq)
            try Task.checkCancellation()
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

            let (lyricData, lyricResp) = try await dataLoader(lyricReq)
            try Task.checkCancellation()
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
            if Self.isCancellationError(error) {
                throw CancellationError()
            }
            return (nil, nil)
        }
    }

    private func fetchLRCLibExact(track: TrackInfo) async throws -> [LyricLine]? {
        try Task.checkCancellation()
        guard var components = URLComponents(string: "https://lrclib.net/api/get") else { return nil }
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
            let (data, response) = try await dataLoader(request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let record = try JSONDecoder().decode(LRCLibRecord.self, from: data)
            guard let synced = record.syncedLyrics, !synced.isEmpty else { return nil }
            return LRCParser.parse(synced)
        } catch {
            if Self.isCancellationError(error) {
                throw CancellationError()
            }
            return nil
        }
    }

    private func fetchLRCLibSearch(track: TrackInfo) async throws -> [LyricLine]? {
        try Task.checkCancellation()
        guard var components = URLComponents(string: "https://lrclib.net/api/search") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "track_name", value: track.title)
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("BarTune/0.2 (macOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await dataLoader(request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let records = try JSONDecoder().decode([LRCLibRecord].self, from: data)
            let best = LyricsMatcher.selectBestLRCLibRecord(records, for: track)
            guard let synced = best?.syncedLyrics else { return nil }
            return LRCParser.parse(synced)
        } catch {
            if Self.isCancellationError(error) {
                throw CancellationError()
            }
            return nil
        }
    }
}
