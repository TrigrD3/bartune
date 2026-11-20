import Foundation

struct TrackInfo: Equatable {
    let id: String
    let title: String
    let artist: String
    let album: String
    let duration: Double // seconds
    let artworkURL: String?
}

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let timestamp: Double // seconds
    let text: String
}

enum LRCParser {
    private static let tagRegex = try! NSRegularExpression(
        pattern: #"\[(\d{1,2}):(\d{2})(?:[.:](\d{1,3}))?\]"#
    )

    static func parse(_ lrc: String) -> [LyricLine] {
        var entries: [(Double, String)] = []

        for rawLine in lrc.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }

            let nsLine = line as NSString
            let fullRange = NSRange(location: 0, length: nsLine.length)
            let matches = tagRegex.matches(in: line, range: fullRange)
            guard !matches.isEmpty else { continue }

            var timestamps: [Double] = []
            var lastTagEnd = 0

            for match in matches {
                let minStr = nsLine.substring(with: match.range(at: 1))
                let secStr = nsLine.substring(with: match.range(at: 2))
                var fraction = 0.0
                if match.range(at: 3).location != NSNotFound {
                    let fracStr = nsLine.substring(with: match.range(at: 3))
                    if let fracVal = Double(fracStr) {
                        fraction = fracVal / pow(10.0, Double(fracStr.count))
                    }
                }
                if let minutes = Double(minStr), let seconds = Double(secStr) {
                    timestamps.append(minutes * 60.0 + seconds + fraction)
                }
                lastTagEnd = max(lastTagEnd, match.range.location + match.range.length)
            }

            let text = nsLine.substring(from: lastTagEnd)
                .trimmingCharacters(in: .whitespacesAndNewlines)

            for ts in timestamps {
                entries.append((ts, text))
            }
        }

        entries.sort { $0.0 < $1.0 }

        return entries.enumerated().map { idx, item in
            LyricLine(id: idx, timestamp: item.0, text: item.1)
        }
    }
}
