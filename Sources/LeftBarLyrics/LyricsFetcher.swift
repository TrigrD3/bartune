import Foundation

actor LyricsFetcher {
    private struct LRCLibRecord: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let trackName: String?
        let artistName: String?
        let duration: Double?
    }

    private var cache: [String: [LyricLine]] = [:]

    func fetchLyrics(for track: TrackInfo) async -> [LyricLine] {
        if let cached = cache[track.id] {
            return cached
        }

        if let exact = await fetchExact(track: track), !exact.isEmpty {
            cache[track.id] = exact
            return exact
        }

        if let searched = await fetchSearch(track: track), !searched.isEmpty {
            cache[track.id] = searched
            return searched
        }

        cache[track.id] = []
        return []
    }

    private func fetchExact(track: TrackInfo) async -> [LyricLine]? {
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
        request.setValue("LeftBarLyrics/1.0 (macOS)", forHTTPHeaderField: "User-Agent")

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

    private func fetchSearch(track: TrackInfo) async -> [LyricLine]? {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "track_name", value: track.title)
        ]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("LeftBarLyrics/1.0 (macOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            let records = try JSONDecoder().decode([LRCLibRecord].self, from: data)
            let best = records
                .filter { ($0.syncedLyrics ?? "").isEmpty == false }
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
