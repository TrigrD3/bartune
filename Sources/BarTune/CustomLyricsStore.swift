import Foundation

enum TrackLyricSource: String, Codable, CaseIterable, Identifiable, Sendable {
    case defaultSource = "default"
    case custom
    case automatic

    var id: String { rawValue }

    var title: String {
        switch self {
        case .defaultSource: return "Default"
        case .custom: return "Custom"
        case .automatic: return "Automatic"
        }
    }
}

struct CustomLyricsRecord: Equatable, Codable, Sendable {
    let trackId: String
    let title: String
    let artist: String
    let savedAt: Date
    let lines: [LyricLine]
}

/// Persists user-timed Custom lyrics under Application Support, outside the lyrics cache so cache
/// clears and pruning never delete them.
struct CustomLyricsStore: Sendable {
    let directory: URL

    static var `default`: CustomLyricsStore {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let dir = base.appendingPathComponent("com.arya.BarTune/custom-lyrics", isDirectory: true)
        return CustomLyricsStore(directory: dir)
    }

    func fileURL(for trackId: String) -> URL {
        directory.appendingPathComponent("\(LyricsDiskCache.cacheKey(for: trackId)).json")
    }

    func load(trackId: String) -> CustomLyricsRecord? {
        let url = fileURL(for: trackId)
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let record = try? decoder.decode(CustomLyricsRecord.self, from: data),
              !record.lines.isEmpty
        else { return nil }
        return record
    }

    func exists(trackId: String) -> Bool {
        load(trackId: trackId) != nil
    }

    func save(_ record: CustomLyricsRecord) {
        guard !record.lines.isEmpty else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return }
        try? data.write(to: fileURL(for: record.trackId), options: .atomic)
    }

    func remove(trackId: String) {
        try? FileManager.default.removeItem(at: fileURL(for: trackId))
    }
}

enum ResolvedLyricAction: Equatable, Sendable {
    case useDefault([LyricLine])
    case useCustom([LyricLine])
    case useAutomatic([LyricLine])
}

/// Pure source-resolution rules shared by AppDelegate and the Lyric Timing Editor.
enum LyricSourceResolver {
    static func effectiveSource(
        choice: TrackLyricSource?,
        hasCustomLyrics: Bool,
        audioSyncEngine: AudioSyncEngine
    ) -> TrackLyricSource {
        switch choice {
        case .defaultSource:
            return .defaultSource
        case .custom:
            if hasCustomLyrics {
                return .custom
            }
            return audioSyncEngine != .off ? .automatic : .defaultSource
        case .automatic:
            return .automatic
        case nil:
            return audioSyncEngine != .off ? .automatic : .defaultSource
        }
    }

    static func resolve(
        choice: TrackLyricSource?,
        customLines: [LyricLine]?,
        fetchedLines: [LyricLine],
        audioSyncEngine: AudioSyncEngine
    ) -> ResolvedLyricAction {
        let validCustom = customLines.flatMap { $0.isEmpty ? nil : $0 }
        switch effectiveSource(
            choice: choice,
            hasCustomLyrics: validCustom != nil,
            audioSyncEngine: audioSyncEngine
        ) {
        case .defaultSource:
            return .useDefault(fetchedLines)
        case .custom:
            if let validCustom {
                return .useCustom(validCustom)
            }
            return audioSyncEngine != .off ? .useAutomatic(fetchedLines) : .useDefault(fetchedLines)
        case .automatic:
            return .useAutomatic(fetchedLines)
        }
    }
}
