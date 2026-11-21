import Foundation

enum TranslationLanguage: String, CaseIterable, Identifiable, Sendable {
    case english = "en"
    case indonesian = "id"
    case japanese = "ja"
    case korean = "ko"
    case chinese = "zh-CN"
    case spanish = "es"
    case french = "fr"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .english: return "English"
        case .indonesian: return "Indonesian"
        case .japanese: return "Japanese"
        case .korean: return "Korean"
        case .chinese: return "Chinese (Simplified)"
        case .spanish: return "Spanish"
        case .french: return "French"
        }
    }
}

enum LyricsTranslationParser {
    /// Extracts the joined translated text from Google Translate's `translate_a/single` JSON payload.
    static func parseTranslatedText(from data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [Any],
              let sentences = root.first as? [Any]
        else { return nil }

        var output = ""
        for entry in sentences {
            if let pair = entry as? [Any], let segment = pair.first as? String {
                output += segment
            }
        }
        return output.isEmpty ? nil : output
    }

    /// Maps translated lines back onto the original `LyricLine` timestamps while keeping empty/instrumental lines intact.
    static func applyTranslatedLines(_ translatedTexts: [String], to original: [LyricLine]) -> [LyricLine] {
        guard translatedTexts.count == original.count else { return original }
        return zip(original, translatedTexts).map { line, translated in
            let cleaned = translated.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return line }
            // Translated word boundaries differ from source word timestamps, so clear word-level timing
            // and let KaraokeLineView sweep smoothly across the translated line duration.
            return LyricLine(
                id: line.id,
                timestamp: line.timestamp,
                duration: line.duration,
                text: cleaned,
                words: []
            )
        }
    }
}

actor LyricsTranslator {
    typealias DataLoader = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private let diskCache: LyricsDiskCache
    private let dataLoader: DataLoader
    private var memoryCache: [String: [LyricLine]] = [:]

    init(
        diskCache: LyricsDiskCache = .default,
        dataLoader: @escaping DataLoader = { try await URLSession.shared.data(for: $0) }
    ) {
        self.diskCache = diskCache
        self.dataLoader = dataLoader
    }

    func clearCache() {
        memoryCache.removeAll()
    }

    func translate(
        lines: [LyricLine],
        trackId: String,
        targetLanguage: TranslationLanguage
    ) async -> [LyricLine] {
        guard !lines.isEmpty else { return [] }
        let cacheKey = "\(trackId):tr:\(targetLanguage.rawValue)"

        if let mem = memoryCache[cacheKey] {
            return mem
        }
        if let disk = diskCache.load(trackId: cacheKey) {
            memoryCache[cacheKey] = disk
            return disk
        }

        // Batch lines in chunks of 25 to stay well within URL query limits.
        var resultLines: [LyricLine] = []
        resultLines.reserveCapacity(lines.count)
        var allBatchesSucceeded = true
        let chunkSize = 25

        for start in stride(from: 0, to: lines.count, by: chunkSize) {
            if Task.isCancelled {
                return lines
            }
            let end = min(start + chunkSize, lines.count)
            let chunk = Array(lines[start..<end])
            let chunkTexts = chunk.map { line -> String in
                let trimmed = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "♪" : trimmed.replacingOccurrences(of: "\n", with: " ")
            }

            if let translatedChunk = await translateBatch(chunkTexts, to: targetLanguage),
               translatedChunk.count == chunk.count {
                resultLines.append(
                    contentsOf: LyricsTranslationParser.applyTranslatedLines(translatedChunk, to: chunk)
                )
            } else {
                allBatchesSucceeded = false
                resultLines.append(contentsOf: chunk)
            }
        }

        if allBatchesSucceeded, !Task.isCancelled, resultLines != lines {
            memoryCache[cacheKey] = resultLines
            diskCache.save(trackId: cacheKey, lines: resultLines, maxEntriesOverride: LyricsDiskCache.configuredMaxEntries())
        }
        return resultLines
    }

    private func translateBatch(_ texts: [String], to target: TranslationLanguage) async -> [String]? {
        let joined = texts.joined(separator: "\n")
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/single")
        components?.queryItems = [
            URLQueryItem(name: "client", value: "gtx"),
            URLQueryItem(name: "sl", value: "auto"),
            URLQueryItem(name: "tl", value: target.rawValue),
            URLQueryItem(name: "dt", value: "t"),
            URLQueryItem(name: "q", value: joined),
        ]
        guard let url = components?.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        request.setValue("BarTune/0.2 (macOS)", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await dataLoader(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                return nil
            }
            guard let translated = LyricsTranslationParser.parseTranslatedText(from: data) else {
                return nil
            }
            let split = translated.components(separatedBy: "\n")
            return split.count == texts.count ? split : nil
        } catch {
            return nil
        }
    }
}
