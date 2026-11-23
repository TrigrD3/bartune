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
    let audioSyncCache: AudioSyncedLyricsCache?

    private struct ScannedDiskEntry {
        let url: URL
        let cacheKey: String
        let entry: CachedLyricsEntry
        let sizeBytes: Int64
        let fileModifiedAt: Date
        let sourceTrackId: String?
    }

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
        return LyricsDiskCache(
            directory: dir,
            maxEntries: configuredMaxEntries(),
            audioSyncCache: .default
        )
    }

    init(
        directory: URL,
        maxEntries: Int = defaultMaxEntries,
        audioSyncCache: AudioSyncedLyricsCache? = nil
    ) {
        self.directory = directory
        self.maxEntries = max(0, maxEntries)
        self.audioSyncCache = audioSyncCache
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

    private func scanEntries() -> [ScannedDiskEntry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var scanned: [ScannedDiskEntry] = []
        for file in files where file.pathExtension == "json" {
            let key = file.deletingPathExtension().lastPathComponent
            guard let data = try? Data(contentsOf: file),
                  let entry = Self.decodeEntry(from: data)
            else { continue }

            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let sizeBytes = Int64(values?.fileSize ?? data.count)
            let fileModifiedAt = values?.contentModificationDate ?? entry.cachedAt ?? .distantPast
            let sourceTrackId = entry.trackId.flatMap(LyricsTranslator.sourceTrackId(fromCacheKey:))

            scanned.append(
                ScannedDiskEntry(
                    url: file,
                    cacheKey: key,
                    entry: entry,
                    sizeBytes: sizeBytes,
                    fileModifiedAt: fileModifiedAt,
                    sourceTrackId: sourceTrackId
                )
            )
        }
        return scanned
    }

    func listEntries(audioSyncCache: AudioSyncedLyricsCache = .default) -> [CachedSongSummary] {
        scanEntries()
            .filter { $0.sourceTrackId == nil }
            .map { item in
                let entry = item.entry
                let modifiedAt = entry.cachedAt ?? item.fileModifiedAt
                let fallbackTitle = entry.lines.first(where: {
                    !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                })?.text ?? "Cached Song"
                let title = (entry.title?.isEmpty == false) ? (entry.title ?? fallbackTitle) : fallbackTitle
                let artist = entry.artist ?? ""
                let syncEngine = audioSyncCache.syncEngine(forCacheKey: item.cacheKey)

                return CachedSongSummary(
                    cacheKey: item.cacheKey,
                    trackId: entry.trackId,
                    title: title,
                    artist: artist,
                    lineCount: entry.lines.count,
                    sizeBytes: item.sizeBytes,
                    modifiedAt: modifiedAt,
                    syncEngine: syncEngine
                )
            }
            .sorted { $0.modifiedAt > $1.modifiedAt }
    }

    func clear() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else { return }
        for file in files where file.pathExtension == "json" {
            try? fm.removeItem(at: file)
        }
    }

    func removeTranslations(forTrackId trackId: String) {
        let fm = FileManager.default
        for item in scanEntries() where item.sourceTrackId == trackId {
            try? fm.removeItem(at: item.url)
        }
    }

    func stats() -> (count: Int, bytes: Int64) {
        var primaryCount = 0
        var totalBytes: Int64 = 0
        for item in scanEntries() {
            if item.sourceTrackId == nil {
                primaryCount += 1
            }
            totalBytes += item.sizeBytes
        }
        return (primaryCount, totalBytes)
    }

    func prune(to limit: Int) {
        guard limit > 0 else { return }
        // Skip decoding every file when even counting translations stays within the limit.
        let fileCount = (try? FileManager.default.contentsOfDirectory(atPath: directory.path))?
            .filter { $0.hasSuffix(".json") }.count ?? 0
        guard fileCount > limit else { return }
        let entries = scanEntries()
        var primary: [ScannedDiskEntry] = []
        var translationsByTrackId: [String: [URL]] = [:]

        for item in entries {
            if let sourceTrackId = item.sourceTrackId {
                translationsByTrackId[sourceTrackId, default: []].append(item.url)
            } else {
                primary.append(item)
            }
        }

        guard primary.count > limit else { return }
        let sorted = primary.sorted { $0.fileModifiedAt < $1.fileModifiedAt }
        let excess = sorted.count - limit
        let fm = FileManager.default
        for item in sorted.prefix(excess) {
            try? fm.removeItem(at: item.url)
            audioSyncCache?.removeByCacheKey(item.cacheKey)
            if let trackId = item.entry.trackId {
                for translationURL in translationsByTrackId[trackId] ?? [] {
                    try? fm.removeItem(at: translationURL)
                }
            }
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
        if let trackId = song.trackId {
            lyricsCache.removeTranslations(forTrackId: trackId)
        }
        await fetcher.invalidateMemoryCache(trackId: song.trackId)
        await translator.invalidateMemoryCache(trackId: song.trackId)
    }

    func removeAll() async {
        lyricsCache.clear()
        syncCache.clear()
        await fetcher.invalidateMemoryCache(trackId: nil)
        await translator.clearCache()
    }

    /// Deletes only audio-sync timings; fetched lyrics and translations stay for offline plays.
    func removeAllAudioSync() {
        syncCache.clear()
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

    private static func hasValidDuration(_ duration: Double) -> Bool {
        duration.isFinite && duration > 0 && Int(exactly: duration.rounded()) != nil
    }

    static func selectBestNetEaseSong(_ songs: [NetEaseSongCandidate], for track: TrackInfo) -> NetEaseSongCandidate? {
        let nonVariant = songs.filter {
            !isUnwantedVariant(candidateTitle: $0.name, expectedTitle: track.title)
        }

        let hasValidDuration = hasValidDuration(track.duration)

        // 1. Prefer candidates with matching artist and title within 6s duration tolerance.
        let artistMatched = nonVariant.filter { song in
            let durDiff = (hasValidDuration ? song.durationMs.map { abs($0 / 1000.0 - track.duration) } : nil) ?? 0
            return artistMatches(candidateArtists: song.artists, expectedArtist: track.artist)
                && titleMatches(candidateTitle: song.name, expectedTitle: track.title)
                && durDiff <= 6.0
        }
        if let best = artistMatched.min(by: {
            guard hasValidDuration else { return false }
            return abs(($0.durationMs ?? 0) / 1000.0 - track.duration) < abs(($1.durationMs ?? 0) / 1000.0 - track.duration)
        }) {
            return best
        }

        // 2. Cross-script fallback (e.g. Kanji "澤野弘之" vs Romaji "Sawano Hiroyuki"):
        // require a non-ASCII artist name, exact normalized title, and duration within 1.5s.
        let expectedNormTitle = normalize(track.title)
        guard !expectedNormTitle.isEmpty, hasValidDuration else { return nil }
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
        let hasValidDuration = hasValidDuration(track.duration)
        return records
            .compactMap { record -> (record: LyricsFetcher.LRCLibRecord, isAnnotated: Bool)? in
                guard let synced = record.syncedLyrics, !synced.isEmpty else { return nil }
                if let trackName = record.trackName {
                    guard !isUnwantedVariant(candidateTitle: trackName, expectedTitle: track.title),
                          titleMatches(candidateTitle: trackName, expectedTitle: track.title)
                    else { return nil }
                } else if !normalize(track.title).isEmpty {
                    return nil
                }
                if let artist = record.artistName,
                   !artistMatches(candidateArtists: [artist], expectedArtist: track.artist) {
                    return nil
                }
                if hasValidDuration, let dur = record.duration, abs(dur - track.duration) > 6.0 {
                    return nil
                }
                let parsed = LRCParser.parse(synced)
                guard parsed.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                    return nil
                }
                return (record, AnnotatedLyrics.isAnnotated(parsed))
            }
            .min { lhs, rhs in
                // Prefer plain lyrics over annotated fan uploads, then the closest duration.
                if lhs.isAnnotated != rhs.isAnnotated { return !lhs.isAnnotated }
                guard hasValidDuration else { return false }
                let d1 = abs((lhs.record.duration ?? track.duration) - track.duration)
                let d2 = abs((rhs.record.duration ?? track.duration) - track.duration)
                return d1 < d2
            }?
            .record
    }
}

/// Fan uploads that annotate each line, e.g. `煩(わずら)い / 와즈라이 / 번역`: the original lyric,
/// then " / "-separated pronunciation or translation in another script.
enum AnnotatedLyrics {
    private static let separator = " / "

    static func isAnnotated(_ lines: [LyricLine]) -> Bool {
        let nonEmpty = lines.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !nonEmpty.isEmpty else { return false }
        let annotated = nonEmpty.filter { isAnnotated($0.text) }.count
        return annotated * 2 >= nonEmpty.count
    }

    /// The lyric segment is Japanese/CJK and some later segment is not.
    private static func isAnnotated(_ text: String) -> Bool {
        let segments = text.components(separatedBy: separator)
        guard segments.count >= 2, JapaneseRomanizer.containsJapaneseOrCJK(segments[0]) else { return false }
        return segments.dropFirst().contains { !JapaneseRomanizer.containsJapaneseOrCJK($0) }
    }

    /// Keeps each line's first segment and drops kana readings in brackets after kanji (`頭(あたま)` → `頭`).
    static func clean(_ lines: [LyricLine]) -> [LyricLine] {
        lines.map { line in
            let lyric = isAnnotated(line.text)
                ? line.text.components(separatedBy: separator)[0]
                : line.text
            let text = lyric
                .replacingOccurrences(
                    of: "([\\p{Han}々〆ヶ?？])[(（][\\p{Hiragana}\\p{Katakana}ー]+[)）]",
                    with: "$1",
                    options: .regularExpression
                )
                .trimmingCharacters(in: .whitespaces)
            guard text != line.text else { return line }
            return LyricLine(id: line.id, timestamp: line.timestamp, duration: line.duration, text: text)
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
        await lookupLyrics(for: track) ?? []
    }

    /// `nil` means a provider failed in a way worth retrying; an empty array means no provider has lyrics.
    func lookupLyrics(for track: TrackInfo) async -> [LyricLine]? {
        if let cached = cache[track.id] {
            return cached
        }

        var diskFallback: [LyricLine]?
        if let diskEntry = diskCache.loadEntry(trackId: track.id) {
            if !AnnotatedLyrics.isAnnotated(diskEntry.lines) {
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
            diskFallback = diskEntry.lines
        }

        var transientFailure = false
        // An annotated fan upload is kept only in case no plain version turns up.
        var annotatedFallback: [LyricLine]?
        func accept(_ lines: [LyricLine]?) -> [LyricLine]? {
            guard let lines,
                  lines.contains(where: { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
            else { return nil }
            if AnnotatedLyrics.isAnnotated(lines) {
                if annotatedFallback == nil { annotatedFallback = lines }
                return nil
            }
            return lines
        }
        do {
            // 1. NetEase YRC (word-by-word sync), 2. LRCLIB exact, 3. LRCLIB search, 4. NetEase line-level LRC
            try Task.checkCancellation()
            let netEase = try await fetchNetEase(track: track, transientFailure: &transientFailure)
            var found = accept(netEase.yrc)
            if found == nil {
                try Task.checkCancellation()
                found = try await accept(fetchLRCLibExact(track: track, transientFailure: &transientFailure))
            }
            if found == nil {
                try Task.checkCancellation()
                found = try await accept(fetchLRCLibSearch(track: track, transientFailure: &transientFailure))
            }
            if found == nil {
                try Task.checkCancellation()
                found = accept(netEase.lrc)
            }
            if let lines = found ?? (annotatedFallback ?? diskFallback).map(AnnotatedLyrics.clean) {
                if found != nil || !transientFailure {
                    cache[track.id] = lines
                    diskCache.save(
                        trackId: track.id,
                        lines: lines,
                        title: track.title,
                        artist: track.artist,
                        maxEntriesOverride: LyricsDiskCache.configuredMaxEntries()
                    )
                }
                return lines
            }

            return transientFailure ? nil : []
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

    /// Returns the body of a 200 response; flags network errors and retryable statuses in `transientFailure`.
    private func send(_ request: URLRequest, transientFailure: inout Bool) async throws -> Data? {
        do {
            let (data, response) = try await dataLoader(request)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse else { return nil }
            if http.statusCode == 408 || http.statusCode == 429 || (500...599).contains(http.statusCode) {
                transientFailure = true
            }
            return http.statusCode == 200 ? data : nil
        } catch {
            if Self.isCancellationError(error) {
                throw CancellationError()
            }
            transientFailure = true
            return nil
        }
    }

    private func fetchNetEase(
        track: TrackInfo,
        transientFailure: inout Bool
    ) async throws -> (yrc: [LyricLine]?, lrc: [LyricLine]?) {
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
            guard let searchData = try await send(searchReq, transientFailure: &transientFailure) else {
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

            guard let lyricData = try await send(lyricReq, transientFailure: &transientFailure) else {
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

    private func fetchLRCLibExact(track: TrackInfo, transientFailure: inout Bool) async throws -> [LyricLine]? {
        try Task.checkCancellation()
        guard track.duration.isFinite,
              track.duration > 0,
              let durationSeconds = Int(exactly: track.duration.rounded())
        else { return nil }
        guard var components = URLComponents(string: "https://lrclib.net/api/get") else { return nil }
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "album_name", value: track.album),
            URLQueryItem(name: "duration", value: String(durationSeconds))
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("BarTune/0.2 (macOS)", forHTTPHeaderField: "User-Agent")

        do {
            guard let data = try await send(request, transientFailure: &transientFailure) else {
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

    private func fetchLRCLibSearch(track: TrackInfo, transientFailure: inout Bool) async throws -> [LyricLine]? {
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
            guard let data = try await send(request, transientFailure: &transientFailure) else {
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
