import Foundation
import os

/// Snapshot of one live audio sync session, shown under Settings → Advanced Diagnostics.
struct AudioSyncDiagnostics: Equatable, Sendable {
    struct LineResult: Equatable, Sendable {
        let text: String
        let sourceTimestamp: Double
        let alignedTimestamp: Double
        let matched: Bool
    }

    static let maxStoredWords = 200

    var engine: AudioSyncEngine
    var trackDescription: String
    var localeIdentifier: String?
    /// Seconds of player audio captured, updated in whole seconds.
    var audioSeconds = 0
    var resultCount = 0
    var totalRecognizedWords = 0
    /// The most recent recognized words, oldest first, capped at `maxStoredWords`.
    var recentWords: [RecognizedAudioWord] = []
    var matchedLineCount = 0
    var matchedWordCount = 0
    var totalLines = 0
    var medianOffset: Double?
    var lineResults: [LineResult] = []
    var note: String?
    var updatedAt = Date()

    mutating func record(words: [RecognizedAudioWord], replacing: Bool) {
        resultCount += 1
        if replacing {
            totalRecognizedWords = words.count
            recentWords = Array(words.suffix(Self.maxStoredWords))
        } else {
            totalRecognizedWords += words.count
            recentWords = Array((recentWords + words).suffix(Self.maxStoredWords))
        }
        updatedAt = Date()
    }

    mutating func record(alignment result: AudioAlignmentResult, sourceLines: [LyricLine]) {
        matchedLineCount = result.matchedLineCount
        matchedWordCount = result.matchedWordCount
        medianOffset = result.medianOffset
        let matchedIds = Set(result.matchedLineIDs)
        let alignedById = Dictionary(result.lines.map { ($0.id, $0.timestamp) }, uniquingKeysWith: { first, _ in first })
        lineResults = sourceLines.map { line in
            LineResult(
                text: line.text,
                sourceTimestamp: line.timestamp,
                alignedTimestamp: alignedById[line.id] ?? line.timestamp,
                matched: matchedIds.contains(line.id)
            )
        }
        totalLines = sourceLines.count
        updatedAt = Date()
    }

    static func formatTime(_ seconds: Double) -> String {
        String(format: "%.2fs", seconds)
    }

    static func formatOffset(_ offset: Double?) -> String {
        guard let offset else { return "—" }
        return String(format: "%+.2fs", offset)
    }

    /// Plain-text report copied by "Copy Diagnostics".
    func report() -> String {
        var out: [String] = []
        out.append("BarTune audio sync diagnostics")
        out.append("Track: \(trackDescription)")
        out.append("Engine: \(engine.title)")
        out.append("Locale: \(localeIdentifier ?? "—")")
        out.append("Audio received: \(audioSeconds)s")
        out.append("Recognizer results: \(resultCount)")
        out.append("Words heard: \(totalRecognizedWords)")
        out.append("Lines matched: \(matchedLineCount)/\(totalLines)")
        out.append("Words matched: \(matchedWordCount)")
        out.append("Timing offset: \(Self.formatOffset(medianOffset))")
        if let note {
            out.append("Note: \(note)")
        }
        out.append("")
        out.append("Recent words (track time, confidence):")
        for word in recentWords {
            out.append("  \(Self.formatTime(word.startTime))  \(word.text)  (\(String(format: "%.2f", word.confidence)))")
        }
        out.append("")
        out.append("Lines (source → aligned):")
        for line in lineResults {
            let mark = line.matched ? "✓" : "·"
            out.append("  \(mark) \(Self.formatTime(line.sourceTimestamp)) → \(Self.formatTime(line.alignedTimestamp))  \(line.text)")
        }
        return out.joined(separator: "\n")
    }
}

@MainActor
final class AudioSyncDiagnosticsModel: ObservableObject {
    @Published private(set) var snapshot: AudioSyncDiagnostics?

    static let logger = Logger(subsystem: "com.arya.BarTune", category: "audio-sync")

    func begin(engine: AudioSyncEngine, track: TrackInfo, totalLines: Int) {
        var fresh = AudioSyncDiagnostics(engine: engine, trackDescription: "\(track.artist) — \(track.title)")
        fresh.totalLines = totalLines
        snapshot = fresh
        Self.logger.info("Live sync started: engine=\(engine.rawValue, privacy: .public) lines=\(totalLines, privacy: .public)")
    }

    func update(_ change: (inout AudioSyncDiagnostics) -> Void) {
        guard var current = snapshot else { return }
        change(&current)
        snapshot = current
    }

    func recordAudio(totalSeconds: Double) {
        let whole = Int(totalSeconds)
        guard let current = snapshot, whole != current.audioSeconds else { return }
        update { $0.audioSeconds = whole }
    }

    func note(_ message: String) {
        update { $0.note = message }
        Self.logger.notice("\(message, privacy: .public)")
    }
}
