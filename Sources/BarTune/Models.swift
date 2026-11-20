import Foundation

struct TrackInfo: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double // seconds
    let artworkURL: String?
}

struct WordTimestamp: Equatable {
    let timestamp: Double // seconds
    let text: String
}

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let timestamp: Double // seconds
    let text: String
    let words: [WordTimestamp]

    init(id: Int, timestamp: Double, text: String, words: [WordTimestamp] = []) {
        self.id = id
        self.timestamp = timestamp
        self.text = text
        self.words = words
    }
}

enum LRCParser {
    private static let lineTagRegex = try! NSRegularExpression(
        pattern: #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#
    )
    private static let wordTagRegex = try! NSRegularExpression(
        pattern: #"<(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?>"#
    )

    static func parse(_ lrc: String) -> [LyricLine] {
        var entries: [(Double, String, [WordTimestamp])] = []

        for rawLine in lrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            let matches = lineTagRegex.matches(in: line, range: fullRange)
            guard !matches.isEmpty else { continue }

            var timestamps: [Double] = []
            var lastTagEnd = 0

            for match in matches {
                if let ts = parseTimestamp(nsLine: nsLine, match: match) {
                    timestamps.append(ts)
                }
                lastTagEnd = max(lastTagEnd, match.range.location + match.range.length)
            }

            let rawBody = nsLine.substring(from: lastTagEnd)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let (cleanText, wordTimestamps) = parseEnhancedWords(rawBody)

            for ts in timestamps {
                entries.append((ts, cleanText, wordTimestamps))
            }
        }

        entries.sort { $0.0 < $1.0 }

        return entries.enumerated().map { idx, item in
            LyricLine(id: idx, timestamp: item.0, text: item.1, words: item.2)
        }
    }

    private static func parseTimestamp(nsLine: NSString, match: NSTextCheckingResult) -> Double? {
        let minStr = nsLine.substring(with: match.range(at: 1))
        let secStr = nsLine.substring(with: match.range(at: 2))
        var fraction = 0.0
        if match.range(at: 3).location != NSNotFound {
            let fracStr = nsLine.substring(with: match.range(at: 3))
            if let fracVal = Double(fracStr) {
                fraction = fracVal / pow(10.0, Double(fracStr.count))
            }
        }
        guard let minutes = Double(minStr), let seconds = Double(secStr) else { return nil }
        return minutes * 60.0 + seconds + fraction
    }

    /// Parses enhanced LRC word tags like `<00:12.34>hello <00:12.80>world`.
    private static func parseEnhancedWords(_ body: String) -> (String, [WordTimestamp]) {
        let nsBody = body as NSString
        let fullRange = NSRange(location: 0, length: nsBody.length)
        let matches = wordTagRegex.matches(in: body, range: fullRange)
        guard !matches.isEmpty else {
            return (body, [])
        }

        var words: [WordTimestamp] = []
        var cleanParts: [String] = []

        for (i, match) in matches.enumerated() {
            guard let ts = parseTimestamp(nsLine: nsBody, match: match) else { continue }
            let textStart = match.range.location + match.range.length
            let textEnd = (i + 1 < matches.count) ? matches[i + 1].range.location : nsBody.length
            let segment = nsBody.substring(with: NSRange(location: textStart, length: max(0, textEnd - textStart)))
            if !segment.isEmpty {
                words.append(WordTimestamp(timestamp: ts, text: segment))
                cleanParts.append(segment)
            }
        }

        let joined = cleanParts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
        return (joined.isEmpty ? body : joined, words)
    }
}
