import Foundation

actor LyricsFetcher {
    private struct LRCLibRecord: Decodable {
        let syncedLyrics: String?
        let plainLyrics: String?
        let trackName: String?
        let artistName: String?
        let duration: Double?
    }

    private struct NetEaseSearchResponse: Decodable {
        struct Result: Decodable {
            struct Song: Decodable {
                let id: Int
                let name: String
                let duration: Double?
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

    func fetchLyrics(for track: TrackInfo) async -> [LyricLine] {
        if let cached = cache[track.id] {
            return cached
        }

        // 1. Try NetEase YRC first for true millisecond word-by-word karaoke sync
        let netEase = await fetchNetEase(track: track)
        if let yrc = netEase.yrc, !yrc.isEmpty {
            cache[track.id] = yrc
            return yrc
        }

        // 2. Fall back to LRCLIB exact match
        if let exact = await fetchLRCLibExact(track: track), !exact.isEmpty {
            cache[track.id] = exact
            return exact
        }

        // 3. Fall back to LRCLIB search
        if let searched = await fetchLRCLibSearch(track: track), !searched.isEmpty {
            cache[track.id] = searched
            return searched
        }

        // 4. Final fallback: NetEase line-level LRC
        if let lrc = netEase.lrc, !lrc.isEmpty {
            cache[track.id] = lrc
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

            // Pick the song whose duration matches closest (within 6 seconds) to avoid wrong remixes
            let matched = songs.min { lhs, rhs in
                let d1 = abs((lhs.duration ?? 0) / 1000.0 - track.duration)
                let d2 = abs((rhs.duration ?? 0) / 1000.0 - track.duration)
                return d1 < d2
            }
            guard let song = matched else { return (nil, nil) }
            if let durMs = song.duration, abs(durMs / 1000.0 - track.duration) > 6.0 {
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
