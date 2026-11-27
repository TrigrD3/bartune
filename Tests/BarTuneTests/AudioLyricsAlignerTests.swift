@testable import BarTune
import Foundation
import XCTest

final class AudioLyricsAlignerTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bartune-audio-sync-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        super.tearDown()
    }

    func testTokenizeLinePreservesExactText() {
        let line = "Hello, world! Don't stop."
        let tokens = LyricsAudioAligner.tokenizeLine(line)
        XCTAssertEqual(tokens.map(\.display).joined(), line)
        XCTAssertEqual(tokens.map(\.normalized), ["hello", "world", "dont", "stop"])
    }

    func testSectionHeadingLetsEarlyLeadVocalAlignAndKeepsItsDisplayRow() {
        let lines = [
            LyricLine(id: 8, timestamp: 6, text: "[Intro]"),
            LyricLine(id: 17, timestamp: 9, text: "sing"),
        ]
        let heard = [RecognizedAudioWord(text: "sing", startTime: 2, duration: 0.3, confidence: 0.9, sourceLineId: 17)]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, [17])
        XCTAssertEqual(result.lines.map(\.id), [8, 17])
        XCTAssertEqual(result.lines.map(\.text), ["[Intro]", "sing"])
        XCTAssertLessThan(result.lines[0].timestamp, result.lines[1].timestamp)
        XCTAssertEqual(result.lines[1].timestamp, 2, accuracy: 0.01)
    }

    func testAlignGeneratesWordTimestampsAndInterpolatesGaps() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "We are the champions"),
        ]
        // Recognize "We" and "champions" — "are" and "the" should be interpolated smoothly in between.
        let recognized = [
            RecognizedAudioWord(text: "we", startTime: 10.5, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "champions", startTime: 12.0, duration: 0.8, confidence: 0.95),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized)
        XCTAssertEqual(result.matchedLineCount, 1)
        XCTAssertEqual(result.matchedWordCount, 2)
        XCTAssertEqual(result.lines.count, 1)

        let aligned = result.lines[0]
        XCTAssertEqual(aligned.words.count, 4)
        XCTAssertEqual(aligned.words.map(\.text).joined(), "We are the champions")
        XCTAssertEqual(aligned.timestamp, 10.5, accuracy: 0.01)
        XCTAssertEqual(aligned.words[0].timestamp, 10.5, accuracy: 0.01)
        XCTAssertEqual(aligned.words[3].timestamp, 12.0, accuracy: 0.01)
        // Interpolated words must remain strictly monotonic between anchor 0 and anchor 3.
        XCTAssertGreaterThan(aligned.words[1].timestamp, aligned.words[0].timestamp)
        XCTAssertGreaterThan(aligned.words[2].timestamp, aligned.words[1].timestamp)
        XCTAssertLessThan(aligned.words[2].timestamp, aligned.words[3].timestamp)
    }

    func testAlignComputesMedianOffsetAndShiftsUnsungLines() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "First line here"),
            LyricLine(id: 1, timestamp: 15.0, text: "Second line now"),
            LyricLine(id: 2, timestamp: 30.0, text: "Future unsung line"),
        ]
        // Actual audio is shifted +2.0s later than fetched LRC.
        let recognized = [
            RecognizedAudioWord(text: "first", startTime: 12.0, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "line", startTime: 12.4, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "here", startTime: 12.8, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "second", startTime: 17.0, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "line", startTime: 17.4, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "now", startTime: 17.8, duration: 0.3, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized)
        XCTAssertEqual(result.matchedLineCount, 2)
        XCTAssertNotNil(result.medianOffset)
        XCTAssertEqual(result.medianOffset ?? 0, 2.0, accuracy: 0.05)
        // Future unsung line should also be shifted by the +2.0s median offset.
        XCTAssertEqual(result.lines[2].timestamp, 32.0, accuracy: 0.05)
    }

    /// Heard words from SiM's "The Rumbling", where "things" was stretched past the next line's first "I".
    func testLineStartingInsideTheStretchedLastWordOfTheLineBeforeStillAligns() throws {
        let lines = [
            LyricLine(id: 0, timestamp: 20.68, text: "All I ever wanted to do was do right things"),
            LyricLine(id: 1, timestamp: 24.43, text: "I never wanted to be the king, I swear"),
        ]
        let heard: [(String, Double, Double)] = [
            ("All", 21.20, 0.16), ("I", 21.40, 0.13), ("ever", 21.56, 0.35), ("wanted", 21.94, 0.48),
            ("to", 22.56, 0.15), ("do", 22.74, 0.17), ("was", 22.94, 0.16), ("do", 23.16, 0.17),
            ("right", 23.36, 0.50), ("things", 23.97, 0.56),
            ("I", 24.09, 0.43), ("never", 24.81, 0.41), ("wanted", 25.25, 0.36), ("to", 25.65, 0.13),
            ("be", 25.85, 0.39), ("the", 26.27, 0.22), ("king,", 26.51, 0.51), ("I", 27.11, 0.56),
            ("swear", 27.69, 3.64),
        ]
        let recognized = heard.map { RecognizedAudioWord(text: $0.0, startTime: $0.1, duration: $0.2, confidence: 0.1) }

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(result.lines[1].timestamp, 24.09, accuracy: 0.01)
        // The first line gives up its overlapping tail instead of the second line losing its match.
        let first = result.lines[0]
        let firstEnd = first.timestamp + (first.duration ?? 0)
        XCTAssertEqual(firstEnd, 24.09, accuracy: 0.01)
        let lastWord = try XCTUnwrap(first.words.last)
        XCTAssertLessThanOrEqual(lastWord.timestamp + (lastWord.duration ?? 0), 24.09 + 0.001)
    }

    func testLineStartingWithin50msOfPreviousLastWordStillAligns() throws {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "love you"),
            LyricLine(id: 1, timestamp: 12.0, text: "now"),
        ]
        let recognized = [
            RecognizedAudioWord(text: "love", startTime: 10.0, duration: 0.4, confidence: 0.9),
            RecognizedAudioWord(text: "you", startTime: 11.90, duration: 0.50, confidence: 0.9),
            RecognizedAudioWord(text: "now", startTime: 11.94, duration: 0.40, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(result.lines[1].timestamp, 11.94, accuracy: 0.005)
        let first = result.lines[0]
        XCTAssertEqual(first.timestamp + (first.duration ?? 0), 11.94, accuracy: 0.005)
        let lastWord = try XCTUnwrap(first.words.last)
        XCTAssertEqual(lastWord.timestamp + (lastWord.duration ?? 0), 11.94, accuracy: 0.005)
    }

    func testLateLyricBlockPullsEarlierAcrossUnmatchedPreviousDurationAndHeldTail() {
        // Case 1: Unmatched previous line has duration running right up to the next line's late timestamp (20.0),
        // while the next line's vocal actually begins 2.6 s earlier at 17.4 s.
        let linesAfterUnmatched = [
            LyricLine(id: 0, timestamp: 10.0, duration: 10.0, text: "Unmatched intro line"),
            LyricLine(id: 1, timestamp: 20.0, text: "Coming down to show you"),
        ]
        let lateWords = [
            RecognizedAudioWord(text: "coming", startTime: 17.4, duration: 0.35, confidence: 0.9),
            RecognizedAudioWord(text: "down", startTime: 17.8, duration: 0.35, confidence: 0.9),
            RecognizedAudioWord(text: "to", startTime: 18.2, duration: 0.25, confidence: 0.9),
            RecognizedAudioWord(text: "show", startTime: 18.5, duration: 0.35, confidence: 0.9),
            RecognizedAudioWord(text: "you", startTime: 18.9, duration: 0.40, confidence: 0.9),
        ]
        let result1 = LyricsAudioAligner.align(lines: linesAfterUnmatched, recognizedWords: lateWords, regroupsCJKWords: false)
        XCTAssertEqual(result1.matchedLineIDs, [1])
        XCTAssertEqual(result1.lines[1].timestamp, 17.4, accuracy: 0.01)
        let prevEnd = result1.lines[0].timestamp + (result1.lines[0].duration ?? 0)
        XCTAssertEqual(prevEnd, 17.4, accuracy: 0.01)

        // Case 2: Matched previous line's held tail runs to 19.6 s while the next late line (20.0 s) starts at 18.6 s
        // and also has later words past 19.6 s; aligner must pick the fuller 4-word match at 18.6 s, not a 2-word suffix.
        let linesAfterMatched = [
            LyricLine(id: 0, timestamp: 15.0, text: "Hold note"),
            LyricLine(id: 1, timestamp: 20.0, text: "Start early then continue"),
        ]
        let overlappedWords = [
            RecognizedAudioWord(text: "hold", startTime: 15.0, duration: 0.4, confidence: 0.9),
            RecognizedAudioWord(text: "note", startTime: 18.0, duration: 1.6, confidence: 0.9),
            RecognizedAudioWord(text: "start", startTime: 18.6, duration: 0.4, confidence: 0.9),
            RecognizedAudioWord(text: "early", startTime: 19.1, duration: 0.4, confidence: 0.9),
            RecognizedAudioWord(text: "then", startTime: 19.8, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "continue", startTime: 20.2, duration: 0.5, confidence: 0.9),
        ]
        let result2 = LyricsAudioAligner.align(lines: linesAfterMatched, recognizedWords: overlappedWords, regroupsCJKWords: false)
        XCTAssertEqual(result2.matchedLineIDs, [0, 1])
        XCTAssertEqual(result2.lines[1].timestamp, 18.6, accuracy: 0.01)
        XCTAssertEqual(result2.lines[1].words.first?.timestamp ?? -1, 18.6, accuracy: 0.01)
        XCTAssertEqual(result2.lines[0].timestamp + (result2.lines[0].duration ?? 0), 18.6, accuracy: 0.01)
    }

    func testEarlyEndingOriginalTimestampsExtendToActualVocalEndWithoutCrossLineBleed() throws {
        // Case 1: Original line has a too-short explicit duration (1.5 s) while next lyric is at 18.0 s
        // and the actual vocal continues through 16.2 s.
        let shortDurationLines = [
            LyricLine(id: 0, timestamp: 10.0, duration: 1.5, text: "Hold this long phrase out"),
            LyricLine(id: 1, timestamp: 18.0, text: "Next line"),
        ]
        let shortDurationWords = [
            RecognizedAudioWord(text: "hold", startTime: 10.0, duration: 0.4, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "this", startTime: 11.2, duration: 0.5, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "long", startTime: 12.6, duration: 0.8, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "phrase", startTime: 14.0, duration: 1.0, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "out", startTime: 15.4, duration: 0.8, confidence: 0.9, sourceLineId: 0),
        ]
        let res1 = LyricsAudioAligner.align(lines: shortDurationLines, recognizedWords: shortDurationWords, regroupsCJKWords: false)
        XCTAssertEqual(res1.matchedLineIDs, [0])
        XCTAssertEqual(res1.lines[0].timestamp + (res1.lines[0].duration ?? 0), 16.2, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(res1.lines[0].words.last).timestamp, 15.4, accuracy: 0.01)

        // Case 2: Next non-empty line's fetched timestamp (12.5 s) is early while line 0 actually finishes at 14.8 s
        // and line 1 actually starts at 15.2 s (sharing repeated words). Line 0 must not be clipped at 12.5 s
        // and must not steal line 1's repeated words.
        let earlyNextLines = [
            LyricLine(id: 0, timestamp: 10.0, text: "Never gonna give you up"),
            LyricLine(id: 1, timestamp: 12.5, text: "Never gonna let you down"),
        ]
        let earlyNextWords = [
            RecognizedAudioWord(text: "never", startTime: 10.0, duration: 0.5, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "gonna", startTime: 10.8, duration: 0.6, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "give", startTime: 11.8, duration: 0.8, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "you", startTime: 13.0, duration: 0.8, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "up", startTime: 14.0, duration: 0.8, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "never", startTime: 15.2, duration: 0.5, confidence: 0.9, sourceLineId: 1),
            RecognizedAudioWord(text: "gonna", startTime: 15.8, duration: 0.5, confidence: 0.9, sourceLineId: 1),
            RecognizedAudioWord(text: "let", startTime: 16.4, duration: 0.4, confidence: 0.9, sourceLineId: 1),
            RecognizedAudioWord(text: "you", startTime: 16.9, duration: 0.4, confidence: 0.9, sourceLineId: 1),
            RecognizedAudioWord(text: "down", startTime: 17.4, duration: 0.6, confidence: 0.9, sourceLineId: 1),
        ]
        let res2 = LyricsAudioAligner.align(lines: earlyNextLines, recognizedWords: earlyNextWords, regroupsCJKWords: false)
        XCTAssertEqual(res2.matchedLineIDs, [0, 1])
        XCTAssertEqual(res2.lines[0].timestamp + (res2.lines[0].duration ?? 0), 14.8, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(res2.lines[0].words.last).timestamp, 14.0, accuracy: 0.01)
        XCTAssertEqual(res2.lines[1].timestamp, 15.2, accuracy: 0.01)

        // Case 3: Early blank marker right after line 0 must not clip line 0, and if line 2 pulls earlier
        // than line 0's tail, line 0 and the intervening blank marker stay strictly monotonic.
        let earlyBlankLines = [
            LyricLine(id: 0, timestamp: 10.0, text: "Hold note"),
            LyricLine(id: 1, timestamp: 11.5, text: ""),
            LyricLine(id: 2, timestamp: 15.0, text: "Come back in"),
        ]
        let earlyBlankWords = [
            RecognizedAudioWord(text: "hold", startTime: 10.0, duration: 0.5, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "note", startTime: 11.2, duration: 3.6, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "come", startTime: 13.5, duration: 0.4, confidence: 0.9, sourceLineId: 2),
            RecognizedAudioWord(text: "back", startTime: 14.0, duration: 0.4, confidence: 0.9, sourceLineId: 2),
            RecognizedAudioWord(text: "in", startTime: 14.5, duration: 0.5, confidence: 0.9, sourceLineId: 2),
        ]
        let res3 = LyricsAudioAligner.align(lines: earlyBlankLines, recognizedWords: earlyBlankWords, regroupsCJKWords: false)
        XCTAssertEqual(res3.matchedLineIDs, [0, 2])
        XCTAssertEqual(res3.lines[2].timestamp, 13.5, accuracy: 0.01)
        let line0End = res3.lines[0].timestamp + (res3.lines[0].duration ?? 0)
        XCTAssertLessThanOrEqual(line0End, res3.lines[1].timestamp + 0.0001)
        XCTAssertGreaterThan(res3.lines[1].timestamp, res3.lines[0].timestamp)
        XCTAssertLessThan(res3.lines[1].timestamp, res3.lines[2].timestamp)

        // Case 4: Moving a blank marker during boundary reconciliation must clear `previousBlankTimestamp`
        // so a later unmatched line (18.0 s) is not pushed past the blank's old clamped timestamp (20.0 s).
        let postBlankLines = [
            LyricLine(id: 0, timestamp: 10.0, duration: 10.0, text: "intro"),
            LyricLine(id: 1, timestamp: 13.0, text: ""),
            LyricLine(id: 2, timestamp: 16.0, text: "hello"),
            LyricLine(id: 3, timestamp: 18.0, text: "world"),
        ]
        let postBlankWords = [
            RecognizedAudioWord(text: "hello", startTime: 15.0, duration: 0.4, confidence: 1.0, sourceLineId: 2),
        ]
        let res4 = LyricsAudioAligner.align(lines: postBlankLines, recognizedWords: postBlankWords, regroupsCJKWords: false)
        XCTAssertEqual(res4.lines[0].timestamp, 10.0, accuracy: 0.01)
        XCTAssertEqual(res4.lines[1].timestamp, 14.99, accuracy: 0.01)
        XCTAssertEqual(res4.lines[2].timestamp, 15.0, accuracy: 0.01)
        XCTAssertEqual(res4.lines[3].timestamp, 18.0, accuracy: 0.01)

        // Case 5: Remapping a cached record when a fetched source inserts a leading blank line updates
        // line IDs, heard-word `sourceLineId`s, and locked/attempted IDs so cached words still match.
        let cachedRecord = AudioSyncedLyricsRecord(
            trackId: "spotify:track:remap",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: 0.0,
            alignedLineCount: 1,
            sourceLineCount: 2,
            lines: [
                LyricLine(id: 0, timestamp: 10.0, duration: 2.0, text: "First line"),
                LyricLine(id: 1, timestamp: 14.0, duration: 2.0, text: "Second line"),
            ],
            heardWords: [
                RecognizedAudioWord(text: "first", startTime: 10.0, duration: 0.5, confidence: 0.9, sourceLineId: 0),
                RecognizedAudioWord(text: "line", startTime: 10.6, duration: 0.5, confidence: 0.9, sourceLineId: 0),
            ],
            lockedLineIDs: [0],
            attemptedLineIDs: [1]
        )
        let refetchedWithBlank = [
            LyricLine(id: 0, timestamp: 0.0, text: ""),
            LyricLine(id: 1, timestamp: 10.0, text: "First line"),
            LyricLine(id: 2, timestamp: 14.0, text: "Second line"),
        ]
        XCTAssertTrue(cachedRecord.matchesSource(refetchedWithBlank))
        let remapped = cachedRecord.remapped(to: refetchedWithBlank)
        XCTAssertEqual(remapped.lockedLineIDs, [1])
        XCTAssertEqual(remapped.attemptedLineIDs, [2])
        XCTAssertEqual(remapped.heardWords?.map(\.sourceLineId), [1, 1])
        let alignedRemapped = LyricsAudioAligner.align(
            lines: refetchedWithBlank,
            recognizedWords: remapped.heardWords ?? [],
            regroupsCJKWords: false
        )
        XCTAssertEqual(alignedRemapped.matchedLineIDs, [1])

        // Case 6: Removing a leading blank row on refetch rebuilds remapped lines with unique IDs
        // (no duplicate ID 0 that would trap Dictionary(uniqueKeysWithValues:)).
        let withLeadingBlank = AudioSyncedLyricsRecord(
            trackId: "spotify:track:remap-drop-blank",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: 0.0,
            alignedLineCount: 2,
            sourceLineCount: 3,
            lines: [
                LyricLine(id: 0, timestamp: 0.0, text: ""),
                LyricLine(id: 1, timestamp: 1.0, duration: 2.0, text: "A"),
                LyricLine(id: 2, timestamp: 4.0, duration: 2.0, text: "B"),
                LyricLine(id: 3, timestamp: 8.0, duration: 2.0, text: "C"),
            ],
            lockedLineIDs: [1, 2]
        )
        let refetchedNoBlank = [
            LyricLine(id: 0, timestamp: 1.0, text: "A"),
            LyricLine(id: 1, timestamp: 4.0, text: "B"),
            LyricLine(id: 2, timestamp: 8.0, text: "C"),
        ]
        let droppedBlankRemapped = withLeadingBlank.remapped(to: refetchedNoBlank)
        XCTAssertEqual(droppedBlankRemapped.lines.map(\.id), [0, 1, 2])
        XCTAssertEqual(Set(droppedBlankRemapped.lines.map(\.id)).count, droppedBlankRemapped.lines.count)
        XCTAssertEqual(droppedBlankRemapped.lockedLineIDs, [0, 1])

        // Case 7: Leading blank marker (5.0 s) before an early first vocal line (4.2 s) relaxes across the blank
        // and pulls the leading blank before 4.2 s.
        let leadingBlankLines = [
            LyricLine(id: 0, timestamp: 5.0, text: ""),
            LyricLine(id: 1, timestamp: 6.0, text: "Hello world"),
        ]
        let earlyFirstWords = [
            RecognizedAudioWord(text: "hello", startTime: 4.2, duration: 0.4, confidence: 0.95, sourceLineId: 1),
            RecognizedAudioWord(text: "world", startTime: 4.7, duration: 0.5, confidence: 0.95, sourceLineId: 1),
        ]
        let leadingRes = LyricsAudioAligner.align(lines: leadingBlankLines, recognizedWords: earlyFirstWords, regroupsCJKWords: false)
        XCTAssertEqual(leadingRes.matchedLineIDs, [1])
        XCTAssertEqual(leadingRes.lines[1].timestamp, 4.2, accuracy: 0.01)
        XCTAssertLessThan(leadingRes.lines[0].timestamp, leadingRes.lines[1].timestamp)

        // Case 8: `reconcilePrecedingBoundary` pushes a stale blank sitting below a shifted preceding line
        // up to `prevEnd` instead of crushing the preceding line's duration to 0.
        var shiftedLines = [
            LyricLine(
                id: 0,
                timestamp: 11.5,
                duration: 1.0,
                text: "Locked late",
                words: [WordTimestamp(timestamp: 11.5, duration: 1.0, text: "Locked late")]
            ),
            LyricLine(id: 1, timestamp: 11.0, text: ""),
            LyricLine(id: 2, timestamp: 14.0, duration: 1.0, text: "Later"),
        ]
        LyricsAudioAligner.reconcilePrecedingBoundary(in: &shiftedLines, before: 2, targetStart: 14.0)
        XCTAssertEqual(shiftedLines[0].duration ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(shiftedLines[0].words[0].duration ?? -1, 1.0, accuracy: 0.001)
        XCTAssertEqual(shiftedLines[1].timestamp, 12.5, accuracy: 0.001)
        XCTAssertLessThan(shiftedLines[1].timestamp, shiftedLines[2].timestamp)
    }

    func testAudioSyncedLyricsCacheDiscardsRemovedEngineRecords() throws {
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        for removedEngine in ["appleSpeech", "whisper"] {
            let trackId = "spotify:track:\(removedEngine)"
            cache.save(
                AudioSyncedLyricsRecord(
                    trackId: trackId,
                    engine: .lyricsAlignment,
                    syncedAt: Date(),
                    medianOffset: 0.1,
                    alignedLineCount: 1,
                    lines: [LyricLine(id: 0, timestamp: 1.0, text: "Line")]
                )
            )
            let url = cache.fileURL(forCacheKey: LyricsDiskCache.cacheKey(for: trackId))
            let json = try String(contentsOf: url, encoding: .utf8)
            try json
                .replacingOccurrences(of: "\"lyricsAlignment\"", with: "\"\(removedEngine)\"")
                .write(to: url, atomically: true, encoding: .utf8)

            XCTAssertNil(cache.load(trackId: trackId))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testAudioSyncedLyricsCacheRoundTripAndClear() {
        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let lines = [
            LyricLine(
                id: 0,
                timestamp: 1.25,
                duration: 2.0,
                text: "Synced line",
                words: [
                    WordTimestamp(timestamp: 1.25, duration: 0.9, text: "Synced "),
                    WordTimestamp(timestamp: 2.15, duration: 1.1, text: "line"),
                ]
            ),
        ]
        let record = AudioSyncedLyricsRecord(
            trackId: "spotify:track:sync-test",
            engine: .lyricsAlignment,
            syncedAt: Date(timeIntervalSince1970: 1_700_000_000),
            medianOffset: 0.4,
            alignedLineCount: 1,
            lines: lines
        )

        cache.save(record)
        let loaded = cache.load(trackId: "spotify:track:sync-test")
        XCTAssertEqual(loaded, record)
        XCTAssertEqual(cache.stats().count, 1)
        XCTAssertGreaterThan(cache.stats().bytes, 0)

        cache.remove(trackId: "spotify:track:sync-test")
        XCTAssertNil(cache.load(trackId: "spotify:track:sync-test"))

        cache.save(record)
        cache.clear()
        XCTAssertEqual(cache.stats().count, 0)
    }

    @MainActor
    func testLyricsStatePersistsAudioSyncSettings() throws {
        let suiteName = "bartune.test.audiosync.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        XCTAssertEqual(state.audioSyncEngine, .off)

        state.audioSyncEngine = .lyricsAlignment

        let reloaded = LyricsState(userDefaults: ud)
        XCTAssertEqual(reloaded.audioSyncEngine, .lyricsAlignment)
    }

    @MainActor
    func testCachedTrackSkipsLiveResyncAndAppliesCachedWordTimestamps() async throws {
        let suiteName = "bartune.test.cachedskip.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        state.audioSyncEngine = .lyricsAlignment

        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let track = TrackInfo(
            id: "spotify:track:already-cached",
            title: "Cached Song",
            artist: "Artist",
            album: "Album",
            duration: 180,
            artworkURL: nil
        )
        let rawLines = [LyricLine(id: 0, timestamp: 10.0, text: "Hello world")]
        let cachedLines = [
            LyricLine(
                id: 0,
                timestamp: 10.4,
                duration: 1.8,
                text: "Hello world",
                words: [
                    WordTimestamp(timestamp: 10.4, duration: 0.8, text: "Hello "),
                    WordTimestamp(timestamp: 11.2, duration: 1.0, text: "world"),
                ]
            ),
        ]
        cache.save(
            AudioSyncedLyricsRecord(
                trackId: track.id,
                engine: .lyricsAlignment,
                syncedAt: Date(),
                medianOffset: 0.4,
                alignedLineCount: 1,
                lines: cachedLines,
                lockedLineIDs: [0]
            )
        )

        state.setTrack(track, lyrics: rawLines)
        let manager = AudioSyncManager(state: state, cache: cache)
        manager.handleTrackLoaded(track: track, rawLines: rawLines)
        await manager.flushCacheOperations()

        XCTAssertFalse(manager.isLiveSyncActive)
        XCTAssertEqual(state.audioSyncStatus, .cached(.lyricsAlignment))
        XCTAssertEqual(state.rawLyricLines, cachedLines)
    }

    func testOverlaySyncBadgeMapsStatusesCorrectly() {
        XCTAssertNil(AudioSyncStatus.idle.overlayBadge)
        XCTAssertNil(AudioSyncStatus.permissionRequired("Needed").overlayBadge)
        XCTAssertNil(AudioSyncStatus.unavailable("Missing").overlayBadge)

        let cachedBadge = AudioSyncStatus.cached(.lyricsAlignment).overlayBadge
        XCTAssertEqual(cachedBadge?.text, "Synced")
        XCTAssertEqual(cachedBadge?.isSynced, true)
        XCTAssertEqual(cachedBadge?.isAnimating, false)

        let settledBadge = AudioSyncStatus.settled(engine: .lyricsAlignment, lockedLines: 2, totalLines: 3).overlayBadge
        XCTAssertEqual(settledBadge?.text, "Synced 2/3")
        XCTAssertEqual(settledBadge?.isSynced, false)
        XCTAssertEqual(settledBadge?.isAnimating, false)

        let listeningBadge = AudioSyncStatus.syncing(engine: .lyricsAlignment, alignedLines: 0, totalLines: 10).overlayBadge
        XCTAssertEqual(listeningBadge?.text, "Listening")
        XCTAssertEqual(listeningBadge?.isSynced, false)
        XCTAssertEqual(listeningBadge?.isAnimating, true)

        let syncingBadge = AudioSyncStatus.syncing(engine: .lyricsAlignment, alignedLines: 3, totalLines: 10).overlayBadge
        XCTAssertEqual(syncingBadge?.text, "Syncing")
        XCTAssertEqual(syncingBadge?.isSynced, false)
        XCTAssertEqual(syncingBadge?.isAnimating, true)
    }

    @MainActor
    func testLyricsStatePersistsShowSyncBadgeSetting() throws {
        let suiteName = "bartune.test.syncbadge.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        XCTAssertTrue(state.showSyncBadge)

        state.showSyncBadge = false
        let reloaded = LyricsState(userDefaults: ud)
        XCTAssertFalse(reloaded.showSyncBadge)
    }

    func testDetectsSpeechLocaleFromLyricsLanguage() {
        let jaLines = [LyricLine(id: 0, timestamp: 1.0, text: "闇夜を駆け抜けて どこへ向かう")]
        XCTAssertEqual(LyricsLanguageDetector.detectSpeechLocale(for: jaLines).identifier, "ja-JP")

        let koLines = [LyricLine(id: 0, timestamp: 1.0, text: "사랑해요 오늘 밤 별이 빛나")]
        XCTAssertEqual(LyricsLanguageDetector.detectSpeechLocale(for: koLines).identifier, "ko-KR")

        let zhLines = [LyricLine(id: 0, timestamp: 1.0, text: "天青色等烟雨而我在等你")]
        XCTAssertEqual(LyricsLanguageDetector.detectSpeechLocale(for: zhLines).identifier, "zh-CN")

        let enLines = [LyricLine(id: 0, timestamp: 1.0, text: "We are the champions my friend")]
        XCTAssertEqual(LyricsLanguageDetector.detectSpeechLocale(for: enLines).identifier, "en-US")
    }

    // MARK: - #139: Japanese recognizer output arrives as characters or whole phrases

    /// Per-character tokens for synthesized Japanese speech.
    private let japaneseCharacterTokens: [(String, Double, Double)] = [
        ("見", 0.00, 0.18), ("つ", 0.18, 0.31), ("け", 0.31, 0.39), ("出", 0.39, 0.52), ("して", 0.52, 0.86),
        ("く", 0.86, 0.92), ("れた", 0.92, 1.19), ("忘", 2.38, 2.51), ("れる", 2.51, 2.92), ("こと", 2.92, 3.18),
        ("ない", 3.18, 3.44), ("君", 3.44, 3.64), ("の", 3.64, 3.84), ("笑", 3.84, 3.97), ("顔", 3.97, 4.30),
    ]

    func testAlignsJapaneseLinesFromPerCharacterWords() {
        let lines = [
            LyricLine(id: 0, timestamp: 20.3, text: "見つけ出してくれた"),
            LyricLine(id: 1, timestamp: 22.6, text: "忘れることない 君の笑顔"),
        ]
        let recognized = japaneseCharacterTokens.map {
            RecognizedAudioWord(text: $0.0, startTime: 20.0 + $0.1, duration: $0.2 - $0.1, confidence: 0.9)
        }

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized)

        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(result.lines[0].timestamp, 20.0, accuracy: 0.01)
        XCTAssertEqual(result.lines[1].timestamp, 22.38, accuracy: 0.01)
        XCTAssertEqual(result.lines[1].words.first(where: { $0.text.hasPrefix("君") })?.timestamp ?? 0, 23.44, accuracy: 0.01)
    }

    func testAlignsJapaneseLineFromOneApplePhraseSegment() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "楽しいことばかり"),
            LyricLine(id: 1, timestamp: 14.0, text: "溢れ出す涙"),
        ]
        let recognized = [
            RecognizedAudioWord(text: "楽しいことばかり", startTime: 10.4, duration: 2.0, confidence: 0.6),
            RecognizedAudioWord(text: "溢れ出す涙", startTime: 14.3, duration: 1.5, confidence: 0.6),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized)

        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(result.lines[0].timestamp, 10.4, accuracy: 0.01)
    }

    func testSpeechLocaleFollowsTheMajorityLanguageOfMixedLyrics() {
        let mostlyEnglish = [
            "\"Do you believe a world of happy endings?\"",
            "Even when the road seems long",
            "Every breath you take will lead you closer to",
            "君の夢が叶うまで",
        ].enumerated().map { LyricLine(id: $0.offset, timestamp: Double($0.offset) * 4, text: $0.element) }
        XCTAssertEqual(LyricsLanguageDetector.detectSpeechLocale(for: mostlyEnglish).identifier, "en-US")

        let mostlyJapanese = [
            "Hello, my friend",
            "見つけ出してくれた 救い出してくれた",
            "忘れることない 君の笑顔",
        ].enumerated().map { LyricLine(id: $0.offset, timestamp: Double($0.offset) * 4, text: $0.element) }
        XCTAssertEqual(LyricsLanguageDetector.detectSpeechLocale(for: mostlyJapanese).identifier, "ja-JP")
    }

    func testTokenizesAndAlignsJapaneseLyricsWithoutSpaces() {
        let text = "闇夜を駆け抜けて"
        let tokens = LyricsAudioAligner.tokenizeLine(text)
        XCTAssertGreaterThan(tokens.count, 1)
        XCTAssertEqual(tokens.map(\.display).joined(), text)

        let lines = [LyricLine(id: 0, timestamp: 5.0, text: text)]
        let recognized = tokens.enumerated().map { idx, tok in
            RecognizedAudioWord(
                text: tok.display,
                startTime: 5.2 + Double(idx) * 0.4,
                duration: 0.35,
                confidence: 0.9
            )
        }
        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized)
        XCTAssertEqual(result.matchedLineCount, 1)
        XCTAssertEqual(result.lines[0].words.map(\.text).joined(), text)
    }

    @MainActor
    func testSkipsLiveSyncWhenTrackAlreadyHasWordLevelTimestamps() async throws {
        let suiteName = "bartune.test.wordsyncskip.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        state.audioSyncEngine = .lyricsAlignment

        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let track = TrackInfo(
            id: "spotify:track:yrc-already-synced",
            title: "YRC Track",
            artist: "Artist",
            album: "Album",
            duration: 180,
            artworkURL: nil
        )
        let yrcLines = [
            LyricLine(
                id: 0,
                timestamp: 1.0,
                duration: 2.0,
                text: "Hello world",
                words: [
                    WordTimestamp(timestamp: 1.0, duration: 0.9, text: "Hello "),
                    WordTimestamp(timestamp: 1.9, duration: 1.1, text: "world"),
                ]
            ),
        ]

        state.setTrack(track, lyrics: yrcLines)
        let manager = AudioSyncManager(state: state, cache: cache)
        manager.handleTrackLoaded(track: track, rawLines: yrcLines)
        await manager.flushCacheOperations()

        XCTAssertFalse(manager.isLiveSyncActive)
        XCTAssertEqual(state.audioSyncStatus, .cached(.lyricsAlignment))
    }

    func testTargetBundleIdentifiersMapToActiveMediaPlayer() {
        XCTAssertEqual(AudioSyncManager.targetBundleIdentifiers(for: "spotify:track:123"), ["com.spotify.client"])
        XCTAssertEqual(AudioSyncManager.targetBundleIdentifiers(for: "music:abc"), ["com.apple.Music"])
        XCTAssertEqual(
            AudioSyncManager.targetBundleIdentifiers(for: "browser:music.youtube.com:xyz", sourceBundleId: "com.google.Chrome"),
            ["com.google.Chrome"]
        )
        XCTAssertTrue(AudioSyncManager.targetBundleIdentifiers(for: "unknown:1").isEmpty)
    }

    func testSafariTrackTargetsOnlySafari() throws {
        let sep = "\u{1F}"
        let payload = [
            "BROWSER",
            "playing",
            "browser:music.youtube.com:Night Dancer|imase",
            "Night Dancer",
            "imase",
            "",
            "210.0",
            "15.0",
            "",
        ].joined(separator: sep)

        let monitor = BrowserMediaMonitor(
            listTabs: { browser in
                if browser.bundleId == "com.apple.Safari" {
                    return [BrowserTabDescriptor(windowIndex: 1, tabIndex: 1, url: "https://music.youtube.com/watch?v=abc")]
                }
                return []
            },
            probeTab: { browser, _ in
                browser.bundleId == "com.apple.Safari" ? payload : nil
            }
        )

        let snapshot = monitor.poll(runningBundleIds: ["com.google.Chrome", "com.apple.Safari"])
        let track = try XCTUnwrap(snapshot?.track)
        XCTAssertEqual(track.sourceBundleId, "com.apple.Safari")
        XCTAssertEqual(AudioSyncManager.targetBundleIdentifiers(for: track), ["com.apple.Safari"])
    }

    func testSingleMatchedLineDoesNotShiftGlobalOffset() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "First line here"),
            LyricLine(id: 1, timestamp: 30.0, text: "Future unsung line"),
        ]
        // Only a single line matches +6.0s away — must NOT shift the entire song.
        let recognized = [
            RecognizedAudioWord(text: "first", startTime: 16.0, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "line", startTime: 16.4, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "here", startTime: 16.8, duration: 0.3, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized)
        XCTAssertNil(result.medianOffset)
        XCTAssertEqual(result.lines[1].timestamp, 30.0, accuracy: 0.01)
    }

    func testCachedRecordReliabilityRejectsSingleLinePartialMatchAndOutlierOffsets() {
        let lines = [
            LyricLine(id: 0, timestamp: 1.0, text: "Line one"),
            LyricLine(id: 1, timestamp: 5.0, text: "Line two"),
            LyricLine(id: 2, timestamp: 9.0, text: "Line three"),
        ]

        let singleLinePartial = AudioSyncedLyricsRecord(
            trackId: "spotify:track:partial",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: 0.2,
            alignedLineCount: 1,
            lines: lines
        )
        XCTAssertFalse(singleLinePartial.isReliable)

        let outlierOffset = AudioSyncedLyricsRecord(
            trackId: "spotify:track:outlier",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: 9.85,
            alignedLineCount: 3,
            lines: lines
        )
        XCTAssertFalse(outlierOffset.isReliable)

        let singleLineTranscriptOnly = AudioSyncedLyricsRecord(
            trackId: "spotify:track:transcript-partial",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: 0.1,
            alignedLineCount: 1,
            sourceLineCount: lines.count,
            lines: [lines[0]]
        )
        XCTAssertFalse(singleLineTranscriptOnly.isReliable)

        let reliable = AudioSyncedLyricsRecord(
            trackId: "spotify:track:good",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: -0.45,
            alignedLineCount: 2,
            sourceLineCount: lines.count,
            lines: lines
        )
        XCTAssertTrue(reliable.isReliable)

        let duplicateTimestamp = AudioSyncedLyricsRecord(
            trackId: "spotify:track:dup",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: nil,
            alignedLineCount: 3,
            lines: [
                LyricLine(id: 0, timestamp: 13.49, text: "Yeah, yeah"),
                LyricLine(id: 1, timestamp: 13.49, text: "Yeah, yeah"),
            ]
        )
        XCTAssertFalse(duplicateTimestamp.isReliable)
    }

    func testPartialCacheRequiresMoreThanSparseLocksAfterManyMisses() {
        let lines = (0..<48).map { id in
            let start = Double(id) * 3
            return LyricLine(id: id, timestamp: start, text: "Verse", words: [
                WordTimestamp(timestamp: start, duration: 0.5, text: "Verse"),
            ])
        }
        func record(locked: Int, missed: Int) -> AudioSyncedLyricsRecord {
            AudioSyncedLyricsRecord(
                trackId: "spotify:track:partial", engine: .lyricsAlignment, syncedAt: Date(), medianOffset: 7.36,
                alignedLineCount: locked, sourceLineCount: lines.count, lines: lines,
                lockedLineIDs: Array(0..<locked), attemptedLineIDs: Array(locked..<(locked + missed))
            )
        }

        let poisoned = record(locked: 4, missed: 44)
        XCTAssertFalse(poisoned.canResumePartial(expectedSourceLineCount: lines.count))
        XCTAssertFalse(poisoned.isReliable)
        XCTAssertTrue(record(locked: 4, missed: 16).canResumePartial(expectedSourceLineCount: lines.count))
        XCTAssertTrue(record(locked: 5, missed: 43).canResumePartial(expectedSourceLineCount: lines.count))
        XCTAssertTrue(record(locked: 2, missed: 9).canResumePartial(expectedSourceLineCount: lines.count))
    }

    func testAlignPreventsCrossLineWordBleedAndOverlappingTimestamps() {
        let lines = [
            LyricLine(id: 0, timestamp: 9.20, text: "We found each other"),
            LyricLine(id: 1, timestamp: 14.50, text: "I helped you out of a broken place"),
            LyricLine(id: 2, timestamp: 19.87, text: "You gave me comfort"),
        ]
        // Stray early hallucination at 3.67s + "you" sung during line 2 at 15.39s.
        let recognized = [
            RecognizedAudioWord(text: "we", startTime: 3.67, duration: 0.25, confidence: 0.8),
            RecognizedAudioWord(text: "found", startTime: 4.10, duration: 0.25, confidence: 0.8),
            RecognizedAudioWord(text: "i", startTime: 14.30, duration: 0.20, confidence: 0.9),
            RecognizedAudioWord(text: "helped", startTime: 14.70, duration: 0.30, confidence: 0.9),
            RecognizedAudioWord(text: "you", startTime: 15.39, duration: 0.25, confidence: 0.9),
            RecognizedAudioWord(text: "out", startTime: 15.80, duration: 0.25, confidence: 0.9),
            RecognizedAudioWord(text: "broken", startTime: 17.50, duration: 0.35, confidence: 0.9),
            RecognizedAudioWord(text: "place", startTime: 18.10, duration: 0.40, confidence: 0.9),
            RecognizedAudioWord(text: "you", startTime: 19.75, duration: 0.25, confidence: 0.9),
            RecognizedAudioWord(text: "gave", startTime: 20.15, duration: 0.30, confidence: 0.9),
            RecognizedAudioWord(text: "me", startTime: 20.55, duration: 0.20, confidence: 0.9),
            RecognizedAudioWord(text: "comfort", startTime: 21.00, duration: 0.50, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized)
        // Line 0 must NOT be pulled back to 3.67s.
        XCTAssertGreaterThan(result.lines[0].timestamp, 8.0)
        // Line 2 must NOT steal "you" from line 1 at 15.39s or overlap line 1.
        XCTAssertGreaterThan(result.lines[2].timestamp, 19.0)
        XCTAssertGreaterThan(result.lines[2].timestamp, result.lines[1].timestamp + 1.0)
    }

    func testHeldLastWordDoesNotHideTheNextLinesFirstWord() {
        // "you" is held up to the moment "now" is sung: its end touches the next line's first word.
        let lines = [
            LyricLine(id: 0, timestamp: 86.0, text: "love you"),
            LyricLine(id: 1, timestamp: 92.0, text: "now your out all night"),
        ]
        let recognized = [
            RecognizedAudioWord(text: "love", startTime: 86.17, duration: 0.40, confidence: 0.9),
            RecognizedAudioWord(text: "you", startTime: 86.57, duration: 5.37, confidence: 0.9),
            RecognizedAudioWord(text: "now", startTime: 91.94, duration: 0.14, confidence: 0.9),
            RecognizedAudioWord(text: "your", startTime: 92.12, duration: 0.16, confidence: 0.9),
            RecognizedAudioWord(text: "out", startTime: 92.32, duration: 0.12, confidence: 0.9),
            RecognizedAudioWord(text: "all", startTime: 92.60, duration: 0.08, confidence: 0.9),
            RecognizedAudioWord(text: "night", startTime: 92.70, duration: 0.44, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized, regroupsCJKWords: false)
        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(result.lines[1].timestamp, 91.94, accuracy: 0.001)
    }

    func testWordBeforeThePreviousLinesEndDoesNotHideALaterEligibleOne() {
        // "now" is heard at 11.9 s, inside the held "you", and again at 12.2 s; only the second may start line 1.
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "love you"),
            LyricLine(id: 1, timestamp: 12.0, text: "now"),
        ]
        let recognized = [
            RecognizedAudioWord(text: "love", startTime: 10.0, duration: 0.4, confidence: 0.9),
            RecognizedAudioWord(text: "you", startTime: 10.5, duration: 1.5, confidence: 0.9),
            RecognizedAudioWord(text: "now", startTime: 11.9, duration: 0.2, confidence: 0.9),
            RecognizedAudioWord(text: "now", startTime: 12.2, duration: 0.2, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized, regroupsCJKWords: false)
        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(result.lines[1].timestamp, 12.2, accuracy: 0.001)
    }

    func testAlignEnforcesMonotonicOrderAcrossFallbackLinesAndConsumedWordBoundaries() {
        // Line 0 matches at 11.2s, while unmatched line 1 has raw timestamp 11.0s.
        let fallbackLines = [
            LyricLine(id: 0, timestamp: 10.0, text: "alpha beta"),
            LyricLine(id: 1, timestamp: 11.0, text: "unmatched second line"),
        ]
        let fallbackRecognized = [
            RecognizedAudioWord(text: "alpha", startTime: 11.2, duration: 0.2, confidence: 0.9),
            RecognizedAudioWord(text: "beta", startTime: 11.5, duration: 0.2, confidence: 0.9),
        ]
        let fallbackResult = LyricsAudioAligner.align(lines: fallbackLines, recognizedWords: fallbackRecognized)
        XCTAssertGreaterThan(fallbackResult.lines[1].timestamp, fallbackResult.lines[0].timestamp)

        // Boundary word at 12.2s must not be consumed by both line 0 and line 1.
        let boundaryLines = [
            LyricLine(id: 0, timestamp: 10.0, text: "alpha beta"),
            LyricLine(id: 1, timestamp: 12.0, text: "beta gamma"),
        ]
        let boundaryRecognized = [
            RecognizedAudioWord(text: "alpha", startTime: 10.0, duration: 0.2, confidence: 0.9),
            RecognizedAudioWord(text: "beta", startTime: 12.2, duration: 0.2, confidence: 0.9),
            RecognizedAudioWord(text: "gamma", startTime: 12.6, duration: 0.2, confidence: 0.9),
        ]
        let boundaryResult = LyricsAudioAligner.align(lines: boundaryLines, recognizedWords: boundaryRecognized)
        XCTAssertGreaterThan(boundaryResult.lines[1].timestamp, boundaryResult.lines[0].timestamp)
        if let firstLastWord = boundaryResult.lines[0].words.last,
           let secondFirstWord = boundaryResult.lines[1].words.first {
            XCTAssertGreaterThanOrEqual(secondFirstWord.timestamp, firstLastWord.timestamp + (firstLastWord.duration ?? 0))
        }
    }

    func testAlignFallbackLineRespectsPreviousLineEnd() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, duration: 1.0, text: "alpha"),
            LyricLine(id: 1, timestamp: 11.0, duration: 1.0, text: "unmatched first"),
            LyricLine(id: 2, timestamp: 12.0, duration: 1.0, text: "unmatched second"),
        ]
        let recognized = [
            RecognizedAudioWord(text: "alpha", startTime: 11.2, duration: 0.2, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized)
        let firstEnd = result.lines[0].timestamp + (result.lines[0].duration ?? 0)
        let secondEnd = result.lines[1].timestamp + (result.lines[1].duration ?? 0)

        XCTAssertGreaterThanOrEqual(result.lines[1].timestamp, firstEnd)
        XCTAssertGreaterThanOrEqual(result.lines[2].timestamp, secondEnd)
    }

    func testCachedRecordReliabilityRejectsIncompleteTranscriptCache() {
        let twoMatchedLines = [
            LyricLine(id: 0, timestamp: 1.0, text: "First matched line"),
            LyricLine(id: 1, timestamp: 5.0, text: "Second matched line"),
        ]

        // Transcript-only mode omits unmatched lines; 2 matched lines of a 40-line song must NOT be reliable.
        let partialTranscript = AudioSyncedLyricsRecord(
            trackId: "spotify:track:partial-transcript-2-of-40",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: 0.1,
            alignedLineCount: 2,
            sourceLineCount: 40,
            lines: twoMatchedLines
        )
        XCTAssertFalse(partialTranscript.isReliable)

        // Complete transcript covering all source lines remains reliable.
        let completeTranscript = AudioSyncedLyricsRecord(
            trackId: "spotify:track:complete-transcript",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: 0.1,
            alignedLineCount: 2,
            sourceLineCount: 2,
            lines: twoMatchedLines
        )
        XCTAssertTrue(completeTranscript.isReliable)

        // Legacy cache (sourceLineCount == nil) with fewer lines than raw source must be rejected when validated.
        let legacyPartial = AudioSyncedLyricsRecord(
            trackId: "spotify:track:legacy-partial",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: 0.1,
            alignedLineCount: 2,
            sourceLineCount: nil,
            lines: twoMatchedLines
        )
        XCTAssertFalse(legacyPartial.isReliable(expectedSourceLineCount: 10))
        XCTAssertTrue(legacyPartial.isReliable(expectedSourceLineCount: 2))
    }

    @MainActor
    func testAlignClampsBlankFallbackLinesMonotonically() throws {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "alpha beta"),
            LyricLine(id: 1, timestamp: 11.0, text: ""),
            LyricLine(id: 2, timestamp: 11.05, text: "   "),
            LyricLine(id: 3, timestamp: 14.0, text: "gamma delta"),
        ]
        let recognized = [
            RecognizedAudioWord(text: "alpha", startTime: 11.2, duration: 0.2, confidence: 0.9),
            RecognizedAudioWord(text: "beta", startTime: 11.5, duration: 0.2, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized)
        XCTAssertEqual(result.lines.count, 4)

        let firstEnd = result.lines[0].timestamp + (result.lines[0].duration ?? 0)
        XCTAssertGreaterThanOrEqual(result.lines[1].timestamp, firstEnd)
        XCTAssertGreaterThan(result.lines[1].timestamp, result.lines[0].timestamp)
        XCTAssertGreaterThan(result.lines[2].timestamp, result.lines[1].timestamp)
        XCTAssertGreaterThan(result.lines[3].timestamp, result.lines[2].timestamp)

        // Binary search in LyricsState must select line 0 at 11.25s instead of the blank line.
        let suiteName = "bartune.test.blankmonotonic.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        let track = TrackInfo(
            id: "spotify:track:blank-monotonic",
            title: "Song",
            artist: "Artist",
            album: "Album",
            duration: 180,
            artworkURL: nil
        )
        state.setTrack(track, lyrics: result.lines)
        state.updatePlayback(isPlaying: true, position: 11.25)
        XCTAssertEqual(state.currentLineId, 0)
        XCTAssertEqual(state.currentText, "alpha beta")
    }

    func testAlignWordInterpolationStaysMonotonicInTightAndOverlappingGaps() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "We are the champions"),
        ]

        // Tight gap: 0.04s between "we" end (10.20) and "champions" start (10.24) for 2 missing words.
        let tightRecognized = [
            RecognizedAudioWord(text: "we", startTime: 10.0, duration: 0.2, confidence: 0.9),
            RecognizedAudioWord(text: "champions", startTime: 10.24, duration: 0.5, confidence: 0.95),
        ]
        let tightResult = LyricsAudioAligner.align(lines: lines, recognizedWords: tightRecognized)
        let tightWords = tightResult.lines[0].words
        XCTAssertEqual(tightWords.count, 4)
        for idx in 0..<(tightWords.count - 1) {
            XCTAssertLessThanOrEqual(tightWords[idx].timestamp, tightWords[idx + 1].timestamp + 0.0001)
        }
        // Interpolated words must not extend past the following word's start.
        XCTAssertLessThanOrEqual(tightWords[1].timestamp + (tightWords[1].duration ?? 0), tightWords[2].timestamp + 0.0001)
        XCTAssertLessThanOrEqual(tightWords[2].timestamp + (tightWords[2].duration ?? 0), tightWords[3].timestamp + 0.0001)

        // Overlapping anchors: "we" ends at 10.35 while "champions" starts at 10.20.
        let overlappingRecognized = [
            RecognizedAudioWord(text: "we", startTime: 10.0, duration: 0.35, confidence: 0.9),
            RecognizedAudioWord(text: "champions", startTime: 10.20, duration: 0.5, confidence: 0.95),
        ]
        let overlapResult = LyricsAudioAligner.align(lines: lines, recognizedWords: overlappingRecognized)
        let overlapWords = overlapResult.lines[0].words
        XCTAssertEqual(overlapWords.count, 4)
        for idx in 0..<(overlapWords.count - 1) {
            XCTAssertLessThanOrEqual(overlapWords[idx].timestamp, overlapWords[idx + 1].timestamp + 0.0001)
        }
        XCTAssertLessThanOrEqual(overlapWords[2].timestamp + (overlapWords[2].duration ?? 0), overlapWords[3].timestamp + 0.0001)
        // The first anchor's recognized duration must be capped by the next word's start.
        XCTAssertLessThanOrEqual(overlapWords[0].timestamp + (overlapWords[0].duration ?? 0), overlapWords[1].timestamp + 0.0001)
    }

    func testCachedRecordReliabilityRejectsOutOfOrderBlankLines() {
        // Caches written before blank lines were clamped can hold a blank marker behind the previous lyric.
        let record = AudioSyncedLyricsRecord(
            trackId: "spotify:track:legacy-blank-order",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: 0.2,
            alignedLineCount: 2,
            sourceLineCount: 2,
            lines: [
                LyricLine(id: 0, timestamp: 10.0, text: "first lyric"),
                LyricLine(id: 1, timestamp: 9.0, text: ""),
                LyricLine(id: 2, timestamp: 14.0, text: "second lyric"),
            ]
        )
        XCTAssertFalse(record.isReliable)
    }

    func testAlignKeepsRecognizedStartAfterClampedBlankLine() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "alpha"),
            LyricLine(id: 1, timestamp: 10.1, text: ""),
            LyricLine(id: 2, timestamp: 10.45, text: "beta"),
        ]
        let recognized = [
            RecognizedAudioWord(text: "alpha", startTime: 10.0, duration: 0.4, confidence: 0.9),
            RecognizedAudioWord(text: "beta", startTime: 10.45, duration: 0.3, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized)
        XCTAssertEqual(result.lines.count, 3)
        XCTAssertEqual(result.matchedLineCount, 2)
        XCTAssertGreaterThan(result.lines[1].timestamp, result.lines[0].timestamp)
        XCTAssertGreaterThan(result.lines[2].timestamp, result.lines[1].timestamp)
        // The blank marker keeps order without imposing full lyric spacing on the next recognized line.
        XCTAssertEqual(result.lines[2].timestamp, 10.45, accuracy: 0.001)
    }

    @MainActor
    func testOfflineRecoveryUsesCachedAudioSyncedLyricsWhenRawLyricsEvicted() async throws {
        let suiteName = "bartune.test.offlinerecovery.\(UUID().uuidString)"
        let ud = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { ud.removePersistentDomain(forName: suiteName) }

        let state = LyricsState(userDefaults: ud)
        state.audioSyncEngine = .lyricsAlignment

        let cache = AudioSyncedLyricsCache(directory: tempDir)
        let track = TrackInfo(
            id: "spotify:track:offline-synced-recovery",
            title: "Night Run",
            artist: "Artist",
            album: "Album",
            duration: 180,
            artworkURL: nil
        )
        let cachedLines = [
            LyricLine(
                id: 0,
                timestamp: 5.0,
                duration: 2.0,
                text: "闇夜を駆け抜けて",
                words: [
                    WordTimestamp(timestamp: 5.0, duration: 1.0, text: "闇夜を"),
                    WordTimestamp(timestamp: 6.0, duration: 1.0, text: "駆け抜けて"),
                ]
            ),
            LyricLine(
                id: 1,
                timestamp: 9.0,
                duration: 2.0,
                text: "どこへ向かう",
                words: [
                    WordTimestamp(timestamp: 9.0, duration: 1.0, text: "どこへ"),
                    WordTimestamp(timestamp: 10.0, duration: 1.0, text: "向かう"),
                ]
            ),
        ]
        cache.save(
            AudioSyncedLyricsRecord(
                trackId: track.id,
                engine: .lyricsAlignment,
                syncedAt: Date(),
                medianOffset: 0.2,
                alignedLineCount: 2,
                sourceLineCount: 2,
                lines: cachedLines
            )
        )

        // Simulate raw lyrics evicted from disk cache while offline.
        state.romanizeJapanese = true
        state.setTrack(track, lyrics: [])
        XCTAssertFalse(state.hasLyrics)

        let manager = AudioSyncManager(state: state, cache: cache)
        manager.handleTrackLoaded(track: track, rawLines: [])
        await manager.flushCacheOperations()

        XCTAssertFalse(manager.isLiveSyncActive)
        XCTAssertEqual(state.audioSyncStatus, .cached(.lyricsAlignment))
        XCTAssertEqual(state.rawLyricLines, cachedLines)
        XCTAssertTrue(state.hasLyrics)
        state.updatePlayback(isPlaying: true, position: 5.5)
        XCTAssertEqual(state.currentLineId, 0)
        XCTAssertFalse(state.currentText.isEmpty)
        XCTAssertNotEqual(state.currentText, cachedLines[0].text)

        // When engine is .off, offline cache recovery must not run.
        state.audioSyncEngine = .off
        state.setTrack(track, lyrics: [])
        manager.handleTrackLoaded(track: track, rawLines: [])
        XCTAssertEqual(state.audioSyncStatus, .idle)
        XCTAssertFalse(state.hasLyrics)

        // Unreliable surviving cache (e.g. partial transcript) must be evicted rather than applied offline.
        state.audioSyncEngine = .lyricsAlignment
        cache.save(
            AudioSyncedLyricsRecord(
                trackId: track.id,
                engine: .lyricsAlignment,
                syncedAt: Date(),
                medianOffset: 0.2,
                alignedLineCount: 2,
                sourceLineCount: 20,
                lines: cachedLines
            )
        )
        state.setTrack(track, lyrics: [])
        manager.handleTrackLoaded(track: track, rawLines: [])
        XCTAssertEqual(state.audioSyncStatus, .idle)
        XCTAssertFalse(state.hasLyrics)
        await manager.flushCacheOperations()
        XCTAssertNil(cache.load(trackId: track.id))
    }

    func testLyricTokenWordsAreMatchedAsTheyAreWithoutJoiningAdjacentLines() {
        // Lyrics Alignment returns each lyric token at its own time; joined into one katakana run,
        // "モラリティ" and "ダーリン" would no longer match either line.
        let lines = [
            LyricLine(id: 0, timestamp: 24.0, text: "モラリティ"),
            LyricLine(id: 1, timestamp: 25.5, text: "ダーリンベイビーダーリン"),
        ]
        let words = [(24.59, "モラ"), (24.91, "リ"), (25.23, "ティ"), (26.25, "ダーリン"), (26.71, "ベイビー"), (27.13, "ダーリン")]
            .map { RecognizedAudioWord(text: $0.1, startTime: $0.0, duration: 0.3, confidence: 0.1) }

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: words, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(result.lines.last?.timestamp ?? 0, 26.25, accuracy: 0.01)
    }

    private func syllableWords() -> [RecognizedAudioWord] {
        [
            RecognizedAudioWord(text: "Beautiful", startTime: 10.0, duration: 1.5, confidence: 0.9, syllables: [
                .init(text: "Beau", startTime: 10.0),
                .init(text: "ti", startTime: 10.6),
                .init(text: "ful", startTime: 11.0),
            ]),
            RecognizedAudioWord(text: "day", startTime: 11.6, duration: 0.5, confidence: 0.9),
        ]
    }

    func testAlignTimesAMatchedWordBySyllableWhenAsked() {
        let lines = [LyricLine(id: 0, timestamp: 10.0, text: "Beautiful day")]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: syllableWords(), splitsSyllables: true)

        let words = result.lines[0].words
        XCTAssertEqual(words.map(\.text), ["Beau", "ti", "ful ", "day"], "the trailing space stays with the word's last syllable")
        XCTAssertEqual(words.map(\.text).joined(), "Beautiful day")
        XCTAssertEqual(words.map(\.timestamp), [10.0, 10.6, 11.0, 11.6])
        XCTAssertEqual(words[0].duration ?? 0, 0.6, accuracy: 0.001)
        XCTAssertEqual(words[2].timestamp + (words[2].duration ?? 0), 11.5, accuracy: 0.001, "the last syllable ends with the word")
    }

    func testAlignKeepsWholeWordsUnlessAskedForSyllables() {
        let lines = [LyricLine(id: 0, timestamp: 10.0, text: "Beautiful day")]
        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: syllableWords())
        XCTAssertEqual(result.lines[0].words.map(\.text), ["Beautiful ", "day"])
    }

    func testTokenGroupsBringASyllableTimedWordBackTogether() throws {
        let lines = [LyricLine(id: 0, timestamp: 10.0, text: "Beautiful day")]
        let aligned = LyricsAudioAligner.align(lines: lines, recognizedWords: syllableWords(), splitsSyllables: true).lines

        let groups = try XCTUnwrap(LyricsAudioAligner.tokenGroups(of: aligned[0]))
        XCTAssertEqual(groups.map { $0.map(\.text) }, [["Beau", "ti", "ful "], ["day"]])
        XCTAssertNil(LyricsAudioAligner.tokenGroups(of: LyricLine(id: 1, timestamp: 0, text: "ab", words: [
            WordTimestamp(timestamp: 0, text: "b"),
        ])))

        // An anchored line's words come back with their syllables, so realigning keeps them.
        let heard = AudioSyncManager.recognizedWords(of: aligned)
        XCTAssertEqual(heard.map(\.text), ["Beautiful", "day"])
        XCTAssertEqual(heard[0].syllables?.map(\.startTime), [10.0, 10.6, 11.0])
        XCTAssertEqual(heard[0].startTime + heard[0].duration, 11.5, accuracy: 0.001)
        XCTAssertNil(heard[1].syllables)
    }

    func testAlignKeepsLineOwnedEarlyOnsetAfterPositiveMedianOffset() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "alpha one"),
            LyricLine(id: 1, timestamp: 20.0, text: "beta two"),
            LyricLine(id: 2, timestamp: 30.0, text: "gamma three"),
        ]
        // First two lines establish a +2.0 s median offset; line 2's forced-alignment onset at 27.5 s
        // lies inside its unshifted forced-alignment window and must not be discarded by the +2.0 s shift.
        let recognized = [
            RecognizedAudioWord(text: "alpha", startTime: 12.0, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "one", startTime: 12.4, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "beta", startTime: 22.0, duration: 0.3, confidence: 0.9, sourceLineId: 1),
            RecognizedAudioWord(text: "two", startTime: 22.4, duration: 0.3, confidence: 0.9, sourceLineId: 1),
            RecognizedAudioWord(text: "gamma", startTime: 27.5, duration: 0.3, confidence: 0.9, sourceLineId: 2),
            RecognizedAudioWord(text: "three", startTime: 27.9, duration: 0.3, confidence: 0.9, sourceLineId: 2),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized, regroupsCJKWords: false)
        XCTAssertEqual(result.matchedLineIDs, [0, 1, 2])
        XCTAssertEqual(result.lines[2].timestamp, 27.5, accuracy: 0.01)
    }

    func testOwnedIntroRecoversBeforeTheRawSearchWindow() {
        let lines = [LyricLine(id: 0, timestamp: 7.04, text: "hello world")]
        let heard = [
            RecognizedAudioWord(text: "hello", startTime: 2.5, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "world", startTime: 2.9, duration: 0.3, confidence: 0.9, sourceLineId: 0),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, [0])
        XCTAssertEqual(result.lines[0].timestamp, 2.5, accuracy: 0.001)
    }

    func testLeadingOwnedLineCanUseTheForcedAlignersTenSecondIntroReach() {
        let line = LyricLine(id: 0, timestamp: 9.5, text: "hello world")
        let heard = [
            RecognizedAudioWord(text: "hello", startTime: 0.5, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "world", startTime: 0.9, duration: 0.3, confidence: 0.9, sourceLineId: 0),
        ]

        let result = LyricsAudioAligner.align(lines: [line], recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, [0])
        XCTAssertEqual(result.lines[0].timestamp, 0.5, accuracy: 0.001)
    }

    func testWellFormedNearlyConfidentLeadingOwnedLineCanAlignEarly() {
        let line = LyricLine(id: 0, timestamp: 7.04, text: "hello world")
        let heard = [
            RecognizedAudioWord(text: "hello", startTime: 2.5, duration: 0.3, confidence: 0.1, sourceLineId: 0),
            RecognizedAudioWord(text: "world", startTime: 2.9, duration: 0.3, confidence: 0.1, sourceLineId: 0),
        ]

        let result = LyricsAudioAligner.align(lines: [line], recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, [0])
        XCTAssertEqual(result.lines[0].timestamp, 2.5, accuracy: 0.001)
    }

    func testEarlyLeadingOffsetDoesNotBlockLaterPositiveOwnedDrift() {
        let lines = [
            LyricLine(id: 0, timestamp: 7.5, text: "hello world"),
            LyricLine(id: 1, timestamp: 12, text: "another phrase"),
        ]
        let heard = [
            RecognizedAudioWord(text: "hello", startTime: 3.5, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "world", startTime: 3.9, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "another", startTime: 15.6, duration: 0.3, confidence: 0.9, sourceLineId: 1),
            RecognizedAudioWord(text: "phrase", startTime: 16, duration: 0.3, confidence: 0.9, sourceLineId: 1),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertNil(result.medianOffset)
        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(result.lines[1].timestamp, 15.6, accuracy: 0.001)
    }

    func testOwnedLinesFollowDriftBeyondRawAndMedianSearchWindows() {
        let offsets = [0.0, 0.2, 0.4, 0.6, 1.8, 3.1, 4.5]
        let lines = offsets.indices.map { LyricLine(id: $0, timestamp: 10 + Double($0) * 8, text: "hello world") }
        let heard = zip(lines, offsets).flatMap { line, offset in [
            RecognizedAudioWord(text: "hello", startTime: line.timestamp + offset, duration: 0.3, confidence: 0.9, sourceLineId: line.id),
            RecognizedAudioWord(text: "world", startTime: line.timestamp + offset + 0.4, duration: 0.3, confidence: 0.9, sourceLineId: line.id),
        ] }

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, lines.map(\.id))
        XCTAssertEqual(result.lines[6].timestamp, lines[6].timestamp + 4.5, accuracy: 0.001)
    }

    func testCorroboratedOwnedOffsetsCanCenterBeyondTheGlobalOffsetLimit() {
        let lines = [
            LyricLine(id: 0, timestamp: 10, text: "hello world"),
            LyricLine(id: 1, timestamp: 20, text: "hello world"),
        ]
        let heard = lines.flatMap { line in [
            RecognizedAudioWord(text: "hello", startTime: line.timestamp + 5.2, duration: 0.3, confidence: 0.9, sourceLineId: line.id),
            RecognizedAudioWord(text: "world", startTime: line.timestamp + 5.6, duration: 0.3, confidence: 0.9, sourceLineId: line.id),
        ] }

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(result.lines[0].timestamp, 15.2, accuracy: 0.001)
        XCTAssertEqual(result.lines[1].timestamp, 25.2, accuracy: 0.001)
    }

    func testCorroboratedEarlyOwnedLinesShiftUnmatchedLyricsAndKeepCacheReliable() throws {
        let lines = [
            LyricLine(id: 0, timestamp: 11.93, text: "first phrase"),
            LyricLine(id: 1, timestamp: 21.93, text: "second phrase"),
            LyricLine(id: 2, timestamp: 31.93, text: "unheard phrase"),
        ]
        let heard = [
            RecognizedAudioWord(text: "first", startTime: 6.43, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "phrase", startTime: 6.83, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "second", startTime: 16.43, duration: 0.3, confidence: 0.9, sourceLineId: 1),
            RecognizedAudioWord(text: "phrase", startTime: 16.83, duration: 0.3, confidence: 0.9, sourceLineId: 1),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(try XCTUnwrap(result.medianOffset), -5.5, accuracy: 0.001)
        XCTAssertEqual(result.lines[0].timestamp, 6.43, accuracy: 0.001)
        XCTAssertEqual(result.lines[1].timestamp, 16.43, accuracy: 0.001)
        XCTAssertEqual(result.lines[2].timestamp, 26.43, accuracy: 0.001)

        let cached = AudioSyncedLyricsRecord(
            trackId: "spotify:track:shifted",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: result.medianOffset,
            alignedLineCount: 2,
            sourceLineCount: lines.count,
            lines: result.lines,
            heardWords: heard,
            lockedLineIDs: [0, 1]
        )
        XCTAssertTrue(cached.isReliable)
        let uncorroborated = AudioSyncedLyricsRecord(
            trackId: "spotify:track:shifted-single-lock",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: -5.5,
            alignedLineCount: 2,
            sourceLineCount: lines.count,
            lines: result.lines,
            lockedLineIDs: [0]
        )
        XCTAssertFalse(uncorroborated.isReliable)
        XCTAssertFalse(AudioSyncedLyricsRecord(
            trackId: "spotify:track:shifted-legacy",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: -5.5,
            alignedLineCount: 2,
            sourceLineCount: lines.count,
            lines: result.lines
        ).isReliable)
        XCTAssertFalse(AudioSyncedLyricsRecord(
            trackId: "spotify:track:shifted-too-far",
            engine: .lyricsAlignment,
            syncedAt: Date(),
            medianOffset: -8.1,
            alignedLineCount: 2,
            sourceLineCount: lines.count,
            lines: result.lines,
            lockedLineIDs: [0, 1]
        ).isReliable)
    }

    func testOwnedOffsetLimitUsesTheMatchedOnsetAfterLeadingPunctuation() {
        let lines = [
            LyricLine(id: 0, timestamp: 20, text: "— first phrase"),
            LyricLine(id: 1, timestamp: 30, text: "— second phrase"),
        ]
        let heard = [
            RecognizedAudioWord(text: "first", startTime: 12.1, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "phrase", startTime: 12.5, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "second", startTime: 22.1, duration: 0.3, confidence: 0.9, sourceLineId: 1),
            RecognizedAudioWord(text: "phrase", startTime: 22.5, duration: 0.3, confidence: 0.9, sourceLineId: 1),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(result.lines[0].timestamp, 11.8, accuracy: 0.001)
        XCTAssertEqual(result.lines[1].timestamp, 21.8, accuracy: 0.001)
    }

    func testOffsetSamplesUseFirstMeaningfulTokenAfterLeadingPunctuation() {
        let lines = [
            LyricLine(id: 0, timestamp: 10, text: "— first phrase"),
            LyricLine(id: 1, timestamp: 20, text: "— second phrase"),
            LyricLine(id: 2, timestamp: 30, text: "unheard phrase"),
        ]
        let heard = [
            RecognizedAudioWord(text: "first", startTime: 12, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "phrase", startTime: 12.4, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "second", startTime: 22, duration: 0.3, confidence: 0.9, sourceLineId: 1),
            RecognizedAudioWord(text: "phrase", startTime: 22.4, duration: 0.3, confidence: 0.9, sourceLineId: 1),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertEqual(result.medianOffset, 2)
        XCTAssertEqual(result.lines[2].timestamp, 32, accuracy: 0.001)

        let missingOnset = heard.filter { $0.text != "second" }
        let partial = LyricsAudioAligner.align(lines: lines, recognizedWords: missingOnset, regroupsCJKWords: false)
        XCTAssertNil(partial.medianOffset)
    }

    func testConfidentOwnedOnsetCanLandFiveSecondsLateOnAShortRow() {
        let lines = [
            LyricLine(id: 0, timestamp: 10, text: "first phrase"),
            LyricLine(id: 1, timestamp: 12, text: "unheard line"),
        ]
        let heard = [
            RecognizedAudioWord(text: "first", startTime: 15.2, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "phrase", startTime: 15.6, duration: 0.3, confidence: 0.9, sourceLineId: 0),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertNil(result.medianOffset)
        XCTAssertEqual(result.matchedLineIDs, [0])
        XCTAssertEqual(result.matchedWordCount, 2)
        XCTAssertEqual(result.lines[0].timestamp, 15.2, accuracy: 0.001)
    }

    func testRepeatedPartialPrefixMatchesDoNotCorroborateAWideOffset() {
        let tokens = ["all", "my", "demons", "run", "wild"]
        let confidences = [0.36, 0.80, 0.18, 0.003, 0.006]
        let lines = [11.93, 21.93].enumerated().map { LyricLine(id: $0, timestamp: $1, text: tokens.joined(separator: " ")) }
        let heard = lines.flatMap { line in
            tokens.enumerated().map {
                RecognizedAudioWord(
                    text: $1, startTime: line.timestamp - 5.5 + Double($0) * 0.4,
                    duration: 0.3, confidence: confidences[$0], sourceLineId: line.id
                )
            }
        }

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertNil(result.medianOffset)
    }

    func testMissingTrailingWordsDoNotCorroborateAWideOwnedOffset() {
        let lines = [10.0, 20.0].enumerated().map {
            LyricLine(id: $0, timestamp: $1, text: "all my demons run wild")
        } + [LyricLine(id: 2, timestamp: 30, text: "unheard phrase")]
        let heard = lines.prefix(2).flatMap { line in
            ["all", "my", "demons"].enumerated().map {
                RecognizedAudioWord(
                    text: $1, startTime: line.timestamp + 5.5 + Double($0) * 0.4,
                    duration: 0.3, confidence: 0.9, sourceLineId: line.id
                )
            }
        }

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertNil(result.medianOffset)
        XCTAssertEqual(result.lines[2].timestamp, 30, accuracy: 0.001)
    }

    func testOwnedWordsAcrossAnInstrumentalGapDoNotShareALine() {
        let lines = [
            LyricLine(id: 0, timestamp: 10, text: "hello world"),
            LyricLine(id: 1, timestamp: 20, text: "another line"),
        ]
        let heard = [
            RecognizedAudioWord(text: "hello", startTime: 10, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "world", startTime: 16, duration: 0.3, confidence: 0.9, sourceLineId: 0),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedWordCount, 1)
        XCTAssertLessThan(result.lines[0].timestamp + (result.lines[0].duration ?? 0), 11)
    }

    func testRunawayOwnedTailDoesNotConsumeTheNextOwnedOnset() {
        let lines = [
            LyricLine(id: 0, timestamp: 10, text: "hold on"),
            LyricLine(id: 1, timestamp: 12.4, text: "again"),
        ]
        let heard = [
            RecognizedAudioWord(text: "hold", startTime: 10, duration: 0.4, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "on", startTime: 12.6, duration: 1.5, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "again", startTime: 12, duration: 0.3, confidence: 0.9, sourceLineId: 1),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(result.lines[1].timestamp, 12, accuracy: 0.001)
        XCTAssertEqual(result.lines[0].timestamp + (result.lines[0].duration ?? 0), 12, accuracy: 0.001)
    }

    func testLateMatchedSuccessorPreservesPrecedingOwnedTailPastFallbackBoundary() throws {
        let lines = [
            LyricLine(id: 0, timestamp: 10, text: "hold this note"),
            LyricLine(id: 1, timestamp: 12, text: "again"),
        ]
        let heard = [
            RecognizedAudioWord(text: "hold", startTime: 10, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "this", startTime: 12.7, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "note", startTime: 15.3, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "again", startTime: 16, duration: 0.3, confidence: 0.9, sourceLineId: 1),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(result.lines[0].timestamp + (result.lines[0].duration ?? 0), 15.6, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.lines[0].words.last).timestamp, 15.3, accuracy: 0.001)
        XCTAssertEqual(result.lines[1].timestamp, 16, accuracy: 0.001)
        XCTAssertTrue(result.clampedRunawayLineIDs.isEmpty)
    }

    func testLateMatchedSuccessorAcrossBlankPreservesPrecedingOwnedTail() {
        let lines = [
            LyricLine(id: 0, timestamp: 10, text: "hold this note"),
            LyricLine(id: 1, timestamp: 11, text: ""),
            LyricLine(id: 2, timestamp: 12, text: "again"),
        ]
        let heard = [
            RecognizedAudioWord(text: "hold", startTime: 10, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "this", startTime: 12.7, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "note", startTime: 15.3, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "again", startTime: 16, duration: 0.3, confidence: 0.9, sourceLineId: 2),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, [0, 2])
        XCTAssertEqual(result.lines[0].timestamp + (result.lines[0].duration ?? 0), 15.6, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(result.lines[1].timestamp, 15.6)
        XCTAssertLessThan(result.lines[1].timestamp, 16)
        XCTAssertEqual(result.lines[2].timestamp, 16, accuracy: 0.001)
        XCTAssertTrue(result.clampedRunawayLineIDs.isEmpty)

        let unmatched = LyricsAudioAligner.align(lines: lines, recognizedWords: Array(heard.dropLast()), regroupsCJKWords: false)
        XCTAssertEqual(unmatched.clampedRunawayLineIDs, [0])
        XCTAssertEqual(unmatched.lines[0].duration ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(unmatched.lines[1].timestamp, 11, accuracy: 0.001)
        XCTAssertEqual(unmatched.lines[2].timestamp, 12, accuracy: 0.001)

        let trailingBlank = LyricsAudioAligner.align(
            lines: Array(lines.dropLast()), recognizedWords: Array(heard.dropLast()), regroupsCJKWords: false
        )
        XCTAssertEqual(trailingBlank.clampedRunawayLineIDs, [0])
        XCTAssertEqual(trailingBlank.lines[0].duration ?? 0, 1, accuracy: 0.001)
        XCTAssertEqual(trailingBlank.lines[1].timestamp, 11, accuracy: 0.001)
    }

    func testHeldTailDoesNotDelayAnUnmatchedLineBetweenMatches() throws {
        let lines = [
            LyricLine(id: 0, timestamp: 10, text: "hold"),
            LyricLine(id: 1, timestamp: 12, duration: 1, text: "unheard"),
            LyricLine(id: 2, timestamp: 14.4, text: "again"),
        ]
        let heard = [
            RecognizedAudioWord(text: "hold", startTime: 10.4, duration: 4, confidence: 0.95, sourceLineId: 0),
            RecognizedAudioWord(text: "again", startTime: 14.8, duration: 0.3, confidence: 0.95, sourceLineId: 2),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, [0, 2])
        XCTAssertTrue(result.clampedRunawayLineIDs.isEmpty)
        XCTAssertEqual(result.lines[1].timestamp, 12.4, accuracy: 0.001)
        XCTAssertEqual(result.lines[1].duration, 1)
        XCTAssertEqual(result.lines[2].timestamp, 14.8, accuracy: 0.001)
        XCTAssertEqual(result.lines[0].timestamp, 10.4, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.lines[0].duration), 2, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.lines[0].words.last?.duration), 2, accuracy: 0.001)
    }

    func testRunawayOwnedTailCannotPushAnUnmatchedLinePastItsExpectedStart() {
        let lines = [
            LyricLine(id: 0, timestamp: 10, text: "hold"),
            LyricLine(id: 1, timestamp: 14, text: "next"),
        ]
        let heard = [RecognizedAudioWord(text: "hold", startTime: 10, duration: 12, confidence: 0.9, sourceLineId: 0)]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, [0])
        XCTAssertEqual(result.lines[1].timestamp, 14, accuracy: 0.001)
        XCTAssertEqual(result.lines[0].timestamp + (result.lines[0].duration ?? 0), 14, accuracy: 0.001)
    }

    func testRunawayTailUsesUnmatchedSuccessorsFallbackInsteadOfRecentOwnedOffset() {
        let lines = [
            LyricLine(id: 0, timestamp: 10, text: "first"),
            LyricLine(id: 1, timestamp: 20, text: "hold"),
            LyricLine(id: 2, timestamp: 25, text: "unheard"),
        ]
        let heard = [
            RecognizedAudioWord(text: "first", startTime: 12, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "hold", startTime: 20, duration: 11, confidence: 0.9, sourceLineId: 1),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertNil(result.medianOffset)
        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(result.clampedRunawayLineIDs, [1])
        XCTAssertEqual(result.lines[1].duration ?? 0, 5, accuracy: 0.001)
        XCTAssertEqual(result.lines[2].timestamp, 25, accuracy: 0.001)
    }

    func testRunawayTailIsClampedWhenUnmatchedSuccessorIsWithinMinimumDuration() {
        let lines = [
            LyricLine(id: 0, timestamp: 10, text: "hold"),
            LyricLine(id: 1, timestamp: 10.28, text: "unheard"),
        ]
        let heard = [RecognizedAudioWord(text: "hold", startTime: 10, duration: 8, confidence: 0.9, sourceLineId: 0)]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertEqual(result.clampedRunawayLineIDs, [0])
        XCTAssertEqual(result.lines[0].duration ?? 0, 0.3, accuracy: 0.001)
        XCTAssertEqual(result.lines[1].timestamp, 10.3, accuracy: 0.001)
    }

    func testNegativeOffsetClampsRunawayTailBeforeNextShiftedLine() throws {
        let lines = [
            LyricLine(id: 0, timestamp: 10, text: "first"),
            LyricLine(id: 1, timestamp: 20, text: "second"),
            LyricLine(id: 2, timestamp: 30, text: "hold this note through now"),
            LyricLine(id: 3, timestamp: 35, text: "next"),
        ]
        let heard = [
            RecognizedAudioWord(text: "first", startTime: 6, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "second", startTime: 16, duration: 0.3, confidence: 0.9, sourceLineId: 1),
            RecognizedAudioWord(text: "hold", startTime: 26, duration: 0.3, confidence: 0.9, sourceLineId: 2),
            RecognizedAudioWord(text: "this", startTime: 28.5, duration: 0.3, confidence: 0.9, sourceLineId: 2),
            RecognizedAudioWord(text: "note", startTime: 31, duration: 0.3, confidence: 0.9, sourceLineId: 2),
            RecognizedAudioWord(text: "through", startTime: 33.5, duration: 0.3, confidence: 0.9, sourceLineId: 2),
            RecognizedAudioWord(text: "now", startTime: 36, duration: 0.3, confidence: 0.9, sourceLineId: 2),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertEqual(result.medianOffset, -4)
        XCTAssertEqual(result.matchedLineIDs, [0, 1, 2])
        XCTAssertEqual(result.lines[2].timestamp + (result.lines[2].duration ?? 0), 31, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(result.lines[2].words.last).duration ?? -1, 0, accuracy: 0.001)
    }

    func testOwnedSearchReachesUnshiftedDeclaredEndBeforeClamping() throws {
        let lines = [
            LyricLine(id: 0, timestamp: 5, text: "one"),
            LyricLine(id: 1, timestamp: 10, text: "two"),
            LyricLine(id: 2, timestamp: 20, duration: 8, text: "hold on through the night"),
            LyricLine(id: 3, timestamp: 27.7, text: "next"),
        ]
        let heard = [
            RecognizedAudioWord(text: "one", startTime: 3, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "two", startTime: 8, duration: 0.3, confidence: 0.9, sourceLineId: 1),
            RecognizedAudioWord(text: "hold", startTime: 18, duration: 1.0, confidence: 0.9, sourceLineId: 2),
            RecognizedAudioWord(text: "on", startTime: 20.6, duration: 1.0, confidence: 0.9, sourceLineId: 2),
            RecognizedAudioWord(text: "through", startTime: 23.4, duration: 1.0, confidence: 0.9, sourceLineId: 2),
            RecognizedAudioWord(text: "the", startTime: 26.2, duration: 1.0, confidence: 0.9, sourceLineId: 2),
            RecognizedAudioWord(text: "night", startTime: 30, duration: 0.3, confidence: 0.9, sourceLineId: 2),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertEqual(result.medianOffset, -2)
        // The last word starts outside the shifted search window but still matches before trimming.
        XCTAssertEqual(result.matchedWordCount, 7)
        XCTAssertEqual(try XCTUnwrap(result.lines[2].words.last).timestamp, 25.7, accuracy: 0.001)
    }

    func testNextOwnedOnsetTrimsInterpolatedTailAcrossBlank() {
        let lines = [
            LyricLine(id: 0, timestamp: 10, text: "alpha bravo charlie delta"),
            LyricLine(id: 1, timestamp: 11, text: ""),
            LyricLine(id: 2, timestamp: 12.4, text: "again"),
        ]
        let heard = [
            RecognizedAudioWord(text: "alpha", startTime: 10, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "bravo", startTime: 10.6, duration: 1.8, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "again", startTime: 11.4, duration: 0.4, confidence: 0.9, sourceLineId: 2),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, [0, 2])
        XCTAssertEqual(result.lines[2].timestamp, 11.4, accuracy: 0.001)
        let blankStart = result.lines[1].timestamp
        XCTAssertLessThan(blankStart, result.lines[2].timestamp)
        XCTAssertEqual(result.lines[0].timestamp + (result.lines[0].duration ?? 0), blankStart, accuracy: 0.001)
        XCTAssertTrue(result.lines[0].words.allSatisfy { $0.timestamp + ($0.duration ?? 0) <= blankStart + 0.001 })
    }

    func testOwnedRunBeatsCloserUntaggedReplayAndPreservesFollowingOnset() {
        let lines = [
            LyricLine(id: 0, timestamp: 10, text: "again"),
            LyricLine(id: 1, timestamp: 12, text: "tomorrow"),
        ]
        let heard = [
            RecognizedAudioWord(text: "again", startTime: 7.2, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "tomorrow", startTime: 11.6, duration: 0.3, confidence: 0.9, sourceLineId: 1),
            RecognizedAudioWord(text: "again", startTime: 12.2, duration: 0.3, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, [0, 1])
        XCTAssertEqual(result.lines[0].timestamp, 7.2, accuracy: 0.001)
        XCTAssertEqual(result.lines[1].timestamp, 11.6, accuracy: 0.001)
    }

    func testUnusableOwnedOnsetFallsBackToUntaggedRun() {
        let lines = [LyricLine(id: 0, timestamp: 10, duration: 8, text: "hold me close")]
        let heard = [
            RecognizedAudioWord(text: "hold", startTime: 10.1, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "me", startTime: 10.5, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "hold", startTime: 16, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "me", startTime: 16.5, duration: 0.3, confidence: 0.9, sourceLineId: 0),
            RecognizedAudioWord(text: "close", startTime: 17, duration: 0.3, confidence: 0.9, sourceLineId: 0),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: heard, regroupsCJKWords: false)

        XCTAssertEqual(result.matchedLineIDs, [0])
        XCTAssertEqual(result.matchedWordCount, 2)
        XCTAssertEqual(result.lines[0].timestamp, 10.1, accuracy: 0.001)
    }

    func testAlignKeepsNextLineCapForLegacyUntaggedWords() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "say yes"),
            LyricLine(id: 1, timestamp: 12.0, text: "yes"),
            LyricLine(id: 2, timestamp: 20.0, text: "closing phrase"),
        ]
        // Legacy cached words carry no sourceLineId; lines 0 and 2 anchor median offset at 0.0 s so
        // line 0's untagged cap stays at 12.4 s and must not steal untagged "yes" at 12.8 s from line 1.
        let recognized = [
            RecognizedAudioWord(text: "say", startTime: 10.0, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "yes", startTime: 12.8, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "closing", startTime: 20.0, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "phrase", startTime: 20.4, duration: 0.3, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized, regroupsCJKWords: false)
        XCTAssertTrue(result.matchedLineIDs.contains(1), "line 1 must keep its own untagged 'yes' at 12.8 s")
        XCTAssertEqual(result.lines[1].timestamp, 12.8, accuracy: 0.01)
    }

    func testLegacyUntaggedMatchDoesNotBlockNextLinesOwnedOnset() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "say yes"),
            LyricLine(id: 1, timestamp: 12.0, text: "now"),
            LyricLine(id: 2, timestamp: 20.0, text: "closing phrase"),
        ]
        // Line 0 matches legacy untagged "yes" at 12.2 s (within its 12.4 s cap), advancing
        // lastConsumedWordStart past 12.2 s. Line 1's valid owned onset at 11.6 s must still win
        // and trim line 0's tail cleanly while preserving start order (10.0 < 11.6).
        let recognized = [
            RecognizedAudioWord(text: "say", startTime: 10.0, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "now", startTime: 11.6, duration: 0.3, confidence: 0.9, sourceLineId: 1),
            RecognizedAudioWord(text: "yes", startTime: 12.2, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "closing", startTime: 20.0, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "phrase", startTime: 20.4, duration: 0.3, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized, regroupsCJKWords: false)
        XCTAssertEqual(result.matchedLineIDs, [0, 1, 2])
        XCTAssertEqual(result.lines[0].timestamp, 10.0, accuracy: 0.01)
        XCTAssertEqual(result.lines[1].timestamp, 11.6, accuracy: 0.01)
        XCTAssertLessThanOrEqual(result.lines[0].timestamp + (result.lines[0].duration ?? 0), 11.61)
    }

    func testAlignKeepsBlankMarkerBoundForLegacyUntaggedWords() {
        let lines = [
            LyricLine(id: 0, timestamp: 10.0, text: "say yes"),
            LyricLine(id: 1, timestamp: 11.0, text: ""),
            LyricLine(id: 2, timestamp: 14.0, text: "yes"),
            LyricLine(id: 3, timestamp: 20.0, text: "closing phrase"),
        ]
        // Untagged "yes" at 13.2 s sits past the 11.0 s blank marker (11.4 s cap), so line 0 must not
        // steal it and line 2 keeps its own onset.
        let recognized = [
            RecognizedAudioWord(text: "say", startTime: 10.0, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "yes", startTime: 13.2, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "closing", startTime: 20.0, duration: 0.3, confidence: 0.9),
            RecognizedAudioWord(text: "phrase", startTime: 20.4, duration: 0.3, confidence: 0.9),
        ]

        let result = LyricsAudioAligner.align(lines: lines, recognizedWords: recognized, regroupsCJKWords: false)
        XCTAssertEqual(result.matchedLineIDs, [0, 2, 3])
        XCTAssertEqual(result.lines[2].timestamp, 13.2, accuracy: 0.01)
    }
}
