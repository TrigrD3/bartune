import AVFoundation
@testable import BarTune
import XCTest

/// Scores Lyrics Alignment against JamendoLyrics word annotations: how far from each sung word start
/// the overlay's sweep enters that word, and how far from each aligned line's sung end its sweep
/// finishes (negative: the sweep rushes ahead of a held last note). Opt-in, since it needs the dataset and the installed model:
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
        let lineEnds: [Double]
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
            guard !values.isEmpty else { return "none" }
            let absolute = values.map(abs).sorted()
            let mean = absolute.reduce(0, +) / Double(absolute.count)
            let bias = values.reduce(0, +) / Double(values.count)
            let within = { (limit: Double) in Double(absolute.filter { $0 <= limit }.count) / Double(absolute.count) * 100 }
            return String(
                format: "mean %4.0f ms  median %4.0f ms  bias %+5.0f ms  ≤100 ms %5.1f%%  ≤300 ms %5.1f%%  (%d)",
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

        var totals = (lrc: Errors(), firstPlay: Errors(), replay: Errors(), lineEnds: Errors(), locked: Errors())
        var alignedLines = 0
        var lockedLines = 0
        var totalLines = 0
        var syncedSongs = 0
        var playsByLock: [Int] = []
        for stem in stems {
            let song = try Self.loadSong(stem, from: dir)
            let lrcLines = Self.lrcLines(for: song)

            // Play the song again, carrying locked lines over, until a play could lock nothing more.
            var locked: [Int: LyricLine] = [:]
            var attempted = Set<Int>()
            var plays: [Play] = []
            var progress = AudioSyncManager.lyricsAlignmentProgress(lockedIDs: [], settledIDs: [], lines: lrcLines)
            while plays.count < Self.maxPlays {
                let play = try await Self.liveSession(song, lrcLines: lrcLines, locked: locked)
                plays.append(play)
                let lockedBefore = locked.count
                locked.merge(play.locked) { old, _ in old }
                attempted = locked.count == lockedBefore ? attempted.union(play.attempted) : play.attempted
                let settled = locked.count == lockedBefore ? attempted : []
                progress = AudioSyncManager.lyricsAlignmentProgress(lockedIDs: Set(locked.keys), settledIDs: settled, lines: lrcLines)
                if progress.isFinished { break }
            }
            let snapshots = try XCTUnwrap(plays.first).snapshots
            let final = try XCTUnwrap(plays.last?.snapshots.last).lines
            let aligned = AudioSyncManager.alignedLineIDs(in: final).count
            let synced = progress.lockedLines == progress.totalLines
            if synced { syncedSongs += 1 }
            playsByLock.append(plays.count)

            let lrc = await Self.errors(song, snapshots: [Snapshot(availableAt: 0, lines: lrcLines)])
            let firstPlay = await Self.errors(song, snapshots: snapshots)
            let replay = await Self.errors(song, snapshots: [Snapshot(availableAt: 0, lines: final)])
            let lineEnds = await Self.lineEndErrors(song, lines: final)
            var lockedStarts = Errors()
            lockedStarts.values = locked.values.compactMap { line in line.words.first.map { $0.timestamp - song.wordStarts[line.id][0] } }
            totals.lrc.add(lrc)
            totals.firstPlay.add(firstPlay)
            totals.replay.add(replay)
            totals.lineEnds.add(lineEnds)
            totals.locked.add(lockedStarts)
            alignedLines += aligned
            lockedLines += progress.lockedLines
            totalLines += progress.totalLines
            let perPlay = plays.map { String($0.locked.count) }.joined(separator: "+")
            print("EVAL \(stem): aligned \(aligned)/\(song.lines.count), locked \(progress.lockedLines)/\(progress.totalLines) "
                + "over \(plays.count) plays (\(perPlay))\(synced ? ", synced" : progress.isFinished ? ", settled" : "")")
            print("EVAL   LRC only    \(lrc.summary)")
            print("EVAL   first play  \(firstPlay.summary)")
            print("EVAL   replay      \(replay.summary)")
            print("EVAL   line ends   \(lineEnds.summary)")
            print("EVAL   locked      \(lockedStarts.summary)")
        }
        print("EVAL ALL \(stems.count) songs: aligned \(alignedLines)/\(totalLines) lines, locked \(lockedLines), "
            + "\(syncedSongs) synced, plays \(playsByLock.map(String.init).joined(separator: " "))")
        print("EVAL   LRC only    \(totals.lrc.summary)")
        print("EVAL   first play  \(totals.firstPlay.summary)")
        print("EVAL   replay      \(totals.replay.summary)")
        print("EVAL   line ends   \(totals.lineEnds.summary)")
        print("EVAL   locked      \(totals.locked.summary)")
    }

    // MARK: - Session

    /// Plays past which the eval stops replaying a song that keeps locking lines.
    private static let maxPlays = 5

    private struct Play {
        let snapshots: [Snapshot]
        /// Lines locked on this play.
        let locked: [Int: LyricLine]
        let attempted: Set<Int>
    }

    /// Plays `song` through the engine as `AudioSyncManager` does: whole chunks, then the rest of the audio
    /// as the final chunk, every word heard so far refined and aligned after each one, lines `locked` on
    /// earlier plays kept as they are, and confident lines locked (`currentAlignment` and `applyLyricsAlignment`).
    private static func liveSession(_ song: Song, lrcLines: [LyricLine], locked: [Int: LyricLine]) async throws -> Play {
        let launched = await LyricsAlignerModel.launch(lines: lrcLines, anchors: locked.compactMapValues(AudioSyncManager.sungSpan))
        let engine = try XCTUnwrap(launched, "The Lyrics Alignment model isn't installed (Settings → Audio Sync)")
        defer { engine.shutdown() }
        let reporter = try XCTUnwrap(engine as? LineAttemptReporting)

        var snapshots = [Snapshot(availableAt: 0, lines: lrcLines.map { locked[$0.id] ?? $0 })]
        var envelope = VocalEnvelope()
        var heard = AudioSyncManager.recognizedWords(of: Array(locked.values))
        var accepted: [Int: LyricLine] = [:]
        var lockedNow: [Int: LyricLine] = [:]
        var bestMatchedCount = 0
        let chunkLength = Int(chunkSeconds) * sampleRate
        var start = 0
        while start < song.mid.count {
            let range = start..<min(start + chunkLength, song.mid.count)
            let startTime = Double(start) / Double(sampleRate)
            let mid = Array(song.mid[range])
            envelope.append(mid: mid, side: Array(song.side[range]), sampleRate: Double(sampleRate), startTime: startTime, rate: 1)
            heard += try await engine.transcribe(AudioSyncManager.AudioChunkRequest(
                samples: AudioLevel.normalizedForRecognition(mid),
                sampleRate: sampleRate,
                chunkStartTime: startTime,
                playbackRate: 1,
                isFinal: range.upperBound == song.mid.count
            ))
            start += chunkLength

            let refined = WaveformTimingRefiner.refine(heard.sorted { $0.startTime < $1.startTime }, envelope: envelope, timingError: 0.06).words
            let result = LyricsAudioAligner.align(lines: lrcLines, recognizedWords: refined, regroupsCJKWords: false)
            let matchedNow = Set(result.matchedLineIDs)
            let frozen = locked.merging(lockedNow) { old, _ in old }
            let matched = matchedNow.union(accepted.keys).union(frozen.keys)
            var shown = result.lines.map { frozen[$0.id] ?? (matchedNow.contains($0.id) ? $0 : accepted[$0.id] ?? $0) }
            let confident = reporter.confidentLineIDs, nearlyConfident = reporter.nearlyConfidentLineIDs
            for line in shown where matched.contains(line.id) && frozen[line.id] == nil
                && AudioSyncManager.locks(line, confident: confident, nearlyConfident: nearlyConfident, envelope: envelope) {
                lockedNow[line.id] = line
            }
            shown = shown.map { locked[$0.id] ?? lockedNow[$0.id] ?? $0 }
            guard !matched.isEmpty, matched.count >= bestMatchedCount else { continue }
            for line in shown where matched.contains(line.id) {
                accepted[line.id] = line
            }
            bestMatchedCount = matched.count
            snapshots.append(Snapshot(availableAt: Double(min(start, song.mid.count)) / Double(sampleRate), lines: shown))
        }
        return Play(snapshots: snapshots, locked: lockedNow, attempted: reporter.attemptedLineIDs)
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

    /// For each line aligned on replay, when its sweep finishes minus when its last word is sung out.
    @MainActor
    private static func lineEndErrors(_ song: Song, lines: [LyricLine]) -> Errors {
        var errors = Errors()
        let aligned = AudioSyncManager.alignedLineIDs(in: lines)
        for (index, line) in lines.enumerated() where aligned.contains(line.id) {
            errors.values.append(sweepEntry(line: index, fraction: 0.999, in: lines, songEnd: song.duration) - song.lineEnds[index])
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
            lineEnds: lineRows.compactMap { Double($0[1]) },
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
