import AVFoundation
@testable import BarTune
import XCTest

/// Scores Lyrics Alignment against JamendoLyrics word annotations: how far from each sung word start
/// the overlay's sweep enters that word. Opt-in, since it needs the dataset and the installed model:
///
///     scripts/fetch-jamendolyrics.sh <dir> English
///     BARTUNE_EVAL_DIR=<dir> swift test --filter AlignmentEvalTests
final class AlignmentEvalTests: XCTestCase {
    /// LRCLIB lines are rarely on the sung onset: the annotated starts are shifted by this, plus a
    /// per-line jitter of up to `lrcJitter` either way, to stand in for them.
    private static let lrcOffset = 0.3
    private static let lrcJitter = 0.25
    private static let chunkSeconds = 12.0
    private static let sampleRate = 16000

    private struct Song {
        let name: String
        let lines: [String]
        let lineStarts: [Double]
        /// Annotated start of each word of each line.
        let wordStarts: [[Double]]
        let mid: [Float]
        let side: [Float]
        var duration: Double { Double(mid.count) / Double(AlignmentEvalTests.sampleRate) }
    }

    /// The lines shown from `availableAt` (track seconds) on.
    private struct Snapshot {
        let availableAt: Double
        let lines: [LyricLine]
    }

    private struct Errors {
        var values: [Double] = []

        mutating func add(_ other: Errors) {
            values += other.values
        }

        var summary: String {
            guard !values.isEmpty else { return "no words" }
            let absolute = values.map(abs).sorted()
            let mean = absolute.reduce(0, +) / Double(absolute.count)
            let bias = values.reduce(0, +) / Double(values.count)
            let within = { (limit: Double) in Double(absolute.filter { $0 <= limit }.count) / Double(absolute.count) * 100 }
            return String(
                format: "mean %4.0f ms  median %4.0f ms  bias %+5.0f ms  ≤100 ms %5.1f%%  ≤300 ms %5.1f%%  (%d words)",
                mean * 1000, absolute[absolute.count / 2] * 1000, bias * 1000, within(0.1), within(0.3), values.count
            )
        }
    }

    func testAlignmentAgainstAnnotatedSongs() async throws {
        guard let path = ProcessInfo.processInfo.environment["BARTUNE_EVAL_DIR"] else {
            throw XCTSkip("Set BARTUNE_EVAL_DIR to a folder made by scripts/fetch-jamendolyrics.sh")
        }
        let dir = URL(fileURLWithPath: path)
        let stems = try FileManager.default.contentsOfDirectory(atPath: dir.appendingPathComponent("wav").path)
            .filter { $0.hasSuffix(".wav") }
            .map { String($0.dropLast(4)) }
            .sorted()
        XCTAssertFalse(stems.isEmpty, "No songs in \(path)/wav")

        var totals = (lrc: Errors(), firstPlay: Errors(), replay: Errors())
        var alignedLines = 0
        var totalLines = 0
        for stem in stems {
            let song = try Self.loadSong(stem, from: dir)
            let lrcLines = Self.lrcLines(for: song)
            let snapshots = try await Self.liveSession(song, lrcLines: lrcLines)
            let final = try XCTUnwrap(snapshots.last).lines
            let aligned = AudioSyncManager.alignedLineIDs(in: final).count

            let lrc = await Self.errors(song, snapshots: [Snapshot(availableAt: 0, lines: lrcLines)])
            let firstPlay = await Self.errors(song, snapshots: snapshots)
            let replay = await Self.errors(song, snapshots: [Snapshot(availableAt: 0, lines: final)])
            totals.lrc.add(lrc)
            totals.firstPlay.add(firstPlay)
            totals.replay.add(replay)
            alignedLines += aligned
            totalLines += song.lines.count
            print("EVAL \(stem): aligned \(aligned)/\(song.lines.count) lines")
            print("EVAL   LRC only    \(lrc.summary)")
            print("EVAL   first play  \(firstPlay.summary)")
            print("EVAL   replay      \(replay.summary)")
        }
        print("EVAL ALL \(stems.count) songs: aligned \(alignedLines)/\(totalLines) lines")
        print("EVAL   LRC only    \(totals.lrc.summary)")
        print("EVAL   first play  \(totals.firstPlay.summary)")
        print("EVAL   replay      \(totals.replay.summary)")
    }

    // MARK: - Session

    /// Plays `song` through the engine as `AudioSyncManager` does on a first play with no cache: whole
    /// chunks only, every word heard so far refined and aligned after each one, and lines accepted
    /// during the session kept (`currentAlignment` and `applyLyricsAlignment`).
    private static func liveSession(_ song: Song, lrcLines: [LyricLine]) async throws -> [Snapshot] {
        let launched = await LyricsAlignerModel.launch(lines: lrcLines)
        let engine = try XCTUnwrap(launched, "The Lyrics Alignment model isn't installed (Settings → Audio Sync)")
        defer { engine.shutdown() }

        var snapshots = [Snapshot(availableAt: 0, lines: lrcLines)]
        var envelope = VocalEnvelope()
        var heard: [RecognizedAudioWord] = []
        var accepted: [Int: LyricLine] = [:]
        var bestMatchedCount = 0
        let chunkLength = Int(chunkSeconds) * sampleRate
        var start = 0
        while start + chunkLength <= song.mid.count {
            let range = start..<(start + chunkLength)
            let startTime = Double(start) / Double(sampleRate)
            let mid = Array(song.mid[range])
            envelope.append(mid: mid, side: Array(song.side[range]), sampleRate: Double(sampleRate), startTime: startTime, rate: 1)
            heard += try await engine.transcribe(AudioSyncManager.AudioChunkRequest(
                samples: AudioLevel.normalizedForRecognition(mid),
                sampleRate: sampleRate,
                chunkStartTime: startTime,
                playbackRate: 1
            ))
            start += chunkLength

            let refined = WaveformTimingRefiner.refine(heard, envelope: envelope, timingError: 0.06).words
            let result = LyricsAudioAligner.align(lines: lrcLines, recognizedWords: refined, regroupsCJKWords: false)
            let matchedNow = Set(result.matchedLineIDs)
            let matched = matchedNow.union(accepted.keys)
            guard !matched.isEmpty, matched.count >= bestMatchedCount else { continue }
            let shown = result.lines.map { matchedNow.contains($0.id) ? $0 : accepted[$0.id] ?? $0 }
            for line in shown where matched.contains(line.id) {
                accepted[line.id] = line
            }
            bestMatchedCount = matched.count
            snapshots.append(Snapshot(availableAt: Double(start) / Double(sampleRate), lines: shown))
        }
        return snapshots
    }

    // MARK: - Scoring

    /// For each annotated word, when the sweep first moves into it minus when it is sung; the lines
    /// on screen are those of the latest snapshot available by the time the word is sung.
    @MainActor
    private static func errors(_ song: Song, snapshots: [Snapshot]) -> Errors {
        var errors = Errors()
        for (lineIndex, text) in song.lines.enumerated() {
            let words = text.split(separator: " ")
            var charsBefore = 0
            for (wordIndex, word) in words.enumerated() {
                let sung = song.wordStarts[lineIndex][wordIndex]
                let lines = (snapshots.last { $0.availableAt <= sung } ?? snapshots[0]).lines
                let fraction = Double(charsBefore) / Double(max(1, text.count))
                errors.values.append(sweepEntry(line: lineIndex, fraction: fraction, in: lines, songEnd: song.duration) - sung)
                charsBefore += word.count + 1
            }
        }
        return errors
    }

    /// When the sweep of `lines[line]` first passes `fraction` of its text, or the next line's start
    /// if it never does while the line is on screen.
    @MainActor
    private static func sweepEntry(line index: Int, fraction: Double, in lines: [LyricLine], songEnd: Double) -> Double {
        let line = lines[index]
        let next = index + 1 < lines.count ? lines[index + 1].timestamp : songEnd
        var position = line.timestamp
        while position < next {
            if LyricsState.computeLineProgress(line: line, nextTimestamp: next, position: position) > fraction + 1e-9 {
                return position
            }
            position += 0.005
        }
        return next
    }

    // MARK: - Dataset

    private static func lrcLines(for song: Song) -> [LyricLine] {
        var random = SeededRandom(seed: song.name)
        var previous = -Double.infinity
        return song.lines.enumerated().map { index, text in
            let jittered = song.lineStarts[index] + lrcOffset + (random.next() * 2 - 1) * lrcJitter
            // LRC has centisecond times, in order.
            let timestamp = max(previous + 0.05, (jittered * 100).rounded() / 100)
            previous = timestamp
            return LyricLine(id: index, timestamp: max(0, timestamp), text: text)
        }
    }

    private static func loadSong(_ stem: String, from dir: URL) throws -> Song {
        let lineRows = try csvRows(dir.appendingPathComponent("lines/\(stem).csv"))
        let wordRows = try csvRows(dir.appendingPathComponent("words/\(stem).csv"))
        let lines = lineRows.map { $0[2] }
        var wordStarts: [[Double]] = []
        var nextWord = 0
        for text in lines {
            let count = text.split(separator: " ").count
            guard nextWord + count <= wordRows.count else { throw EvalError.mismatchedAnnotations(stem) }
            wordStarts.append(wordRows[nextWord..<(nextWord + count)].compactMap { Double($0[0]) })
            nextWord += count
        }
        guard nextWord == wordRows.count else { throw EvalError.mismatchedAnnotations(stem) }

        let file = try AVAudioFile(forReading: dir.appendingPathComponent("wav/\(stem).wav"))
        let format = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard format.sampleRate == Double(sampleRate),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else { throw EvalError.unexpectedAudio(stem) }
        try file.read(into: buffer)
        guard let data = buffer.floatChannelData else { throw EvalError.unexpectedAudio(stem) }
        let channels = (0..<Int(format.channelCount)).map { Array(UnsafeBufferPointer(start: data[$0], count: Int(buffer.frameLength))) }
        let (mid, side) = AudioSampleExtractor.midSide(channels: channels)
        return Song(
            name: stem,
            lines: lines,
            lineStarts: lineRows.compactMap { Double($0[0]) },
            wordStarts: wordStarts,
            mid: mid,
            side: side
        )
    }

    /// Rows after the header of a JamendoLyrics annotation CSV, whose lyrics have no commas or quotes.
    private static func csvRows(_ url: URL) throws -> [[String]] {
        try String(contentsOf: url, encoding: .utf8)
            .split(whereSeparator: \.isNewline)
            .dropFirst()
            .map { $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }
    }

    private enum EvalError: Error {
        case mismatchedAnnotations(String)
        case unexpectedAudio(String)
    }

    /// The same jitter on every run (FNV-1a seed, xorshift steps).
    private struct SeededRandom {
        private var state: UInt64

        init(seed: String) {
            state = seed.utf8.reduce(UInt64(14_695_981_039_346_656_037)) { ($0 ^ UInt64($1)) &* 1_099_511_628_211 }
        }

        /// Uniform in 0..<1.
        mutating func next() -> Double {
            state ^= state << 13
            state ^= state >> 7
            state ^= state << 17
            return Double(state >> 11) / Double(1 << 53)
        }
    }
}
