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
    let duration: Double? // seconds (exact duration when provided by YRC)
    let text: String

    init(timestamp: Double, duration: Double? = nil, text: String) {
        self.timestamp = timestamp
        self.duration = duration
        self.text = text
    }
}

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let timestamp: Double // seconds
    let duration: Double? // seconds (exact line duration when provided by YRC)
    let text: String
    let words: [WordTimestamp]

    init(id: Int, timestamp: Double, duration: Double? = nil, text: String, words: [WordTimestamp] = []) {
        self.id = id
        self.timestamp = timestamp
        self.duration = duration
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

/// Parses NetEase YRC word-level karaoke format: `[lineStartMs,lineDurMs](wordStartMs,wordDurMs,0)word...`
enum YRCParser {
    private static let lineHeaderRegex = try! NSRegularExpression(
        pattern: #"^\[(\d+),(\d+)\](.*)$"#
    )
    private static let wordRegex = try! NSRegularExpression(
        pattern: #"\((\d+),(\d+),\d+\)([^(]*)"#
    )

    static func parse(_ yrc: String) -> [LyricLine] {
        var result: [LyricLine] = []

        for rawLine in yrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("[") else { continue }

            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            guard let header = lineHeaderRegex.firstMatch(in: line, range: fullRange) else { continue }

            guard let startMs = Double(nsLine.substring(with: header.range(at: 1))),
                  let durMs = Double(nsLine.substring(with: header.range(at: 2))) else { continue }

            let body = nsLine.substring(with: header.range(at: 3))
            let nsBody = body as NSString
            let bodyRange = NSRange(location: 0, length: nsBody.length)
            let wordMatches = wordRegex.matches(in: body, range: bodyRange)
            guard !wordMatches.isEmpty else { continue }

            var words: [WordTimestamp] = []
            var joined = ""

            for wm in wordMatches {
                guard let wStartMs = Double(nsBody.substring(with: wm.range(at: 1))),
                      let wDurMs = Double(nsBody.substring(with: wm.range(at: 2))) else { continue }
                let segment = nsBody.substring(with: wm.range(at: 3))
                if !segment.isEmpty {
                    words.append(WordTimestamp(
                        timestamp: wStartMs / 1000.0,
                        duration: max(0.03, wDurMs / 1000.0),
                        text: segment
                    ))
                    joined += segment
                }
            }

            let trimmed = joined.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }

            result.append(LyricLine(
                id: result.count,
                timestamp: startMs / 1000.0,
                duration: max(0.2, durMs / 1000.0),
                text: trimmed,
                words: words
            ))
        }

        return result.sorted { $0.timestamp < $1.timestamp }
            .enumerated()
            .map { idx, line in
                LyricLine(id: idx, timestamp: line.timestamp, duration: line.duration, text: line.text, words: line.words)
            }
    }
}
