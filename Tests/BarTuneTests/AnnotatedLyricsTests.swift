@testable import BarTune
import XCTest

final class AnnotatedLyricsTests: XCTestCase {
    private func lines(_ texts: [String]) -> [LyricLine] {
        texts.enumerated().map { LyricLine(id: $0.offset, timestamp: Double($0.offset) * 4, text: $0.element) }
    }

    private let fanUpload = [
        "やたらとしんどい?煩(こいわずら)い / 야타라토 신도이 코이와즈라이 / 몹시도 힘든 상사병",
        "バラバラんなる頭(あたま)とこの身?(しんたい) / 바라바란나루 아타마토 코노 신타이 / 너덜너덜해진 머리와 이 신체",
        "アイリスアウト / 아이리스 아우토 / 아이리스 아웃",
    ]

    func testDetectsLinesAnnotatedInAnotherScript() {
        XCTAssertTrue(AnnotatedLyrics.isAnnotated(lines(fanUpload)))
        XCTAssertTrue(AnnotatedLyrics.isAnnotated(lines(["君の名前 / your name", "夜が明ける / dawn breaks"])))
    }

    func testPlainLyricsAreNotAnnotated() {
        XCTAssertFalse(AnnotatedLyrics.isAnnotated(lines(["君の名前を呼ぶ", "夜が明ける"])))
        XCTAssertFalse(AnnotatedLyrics.isAnnotated(lines(["Yes / No", "Left / Right"])))
        XCTAssertFalse(AnnotatedLyrics.isAnnotated(lines(["行かないで / 行かないで", "夜が明ける"])))
    }

    func testCleanKeepsTheLyricAndDropsKanaReadings() {
        let cleaned = AnnotatedLyrics.clean(lines(fanUpload + ["君(きみ)", "(はやく) はやく"]))
        XCTAssertEqual(cleaned.map(\.text), [
            "やたらとしんどい?煩い",
            "バラバラんなる頭とこの身?",
            "アイリスアウト",
            "君",
            "(はやく) はやく",
        ])
        XCTAssertEqual(cleaned.map(\.timestamp), [0, 4, 8, 12, 16])
    }

    func testSearchPrefersAPlainVersionOverAnnotatedOne() {
        let track = TrackInfo(id: "t", title: "IRIS OUT", artist: "Kenshi Yonezu", album: "", duration: 150, artworkURL: nil)
        let annotated = LyricsFetcher.LRCLibRecord(
            syncedLyrics: "[00:01.00]頭(あたま) / 아타마 / 머리\n[00:05.00]アイリスアウト / 아이리스 아우토 / 아이리스 아웃",
            plainLyrics: nil, trackName: "IRIS OUT", artistName: "Kenshi Yonezu", duration: 150
        )
        let plain = LyricsFetcher.LRCLibRecord(
            syncedLyrics: "[00:01.00]頭\n[00:05.00]アイリスアウト",
            plainLyrics: nil, trackName: "IRIS OUT", artistName: "Kenshi Yonezu", duration: 153
        )
        XCTAssertEqual(LyricsMatcher.selectBestLRCLibRecord([annotated, plain], for: track), plain)
    }

    func testSearchIgnoresUntimedRecordsOverAnnotatedOne() {
        let track = TrackInfo(id: "t", title: "IRIS OUT", artist: "Kenshi Yonezu", album: "", duration: 150, artworkURL: nil)
        let whitespaceOnly = LyricsFetcher.LRCLibRecord(
            syncedLyrics: "   \n  ",
            plainLyrics: nil, trackName: "IRIS OUT", artistName: "Kenshi Yonezu", duration: 150
        )
        let untimed = LyricsFetcher.LRCLibRecord(
            syncedLyrics: "頭\nアイリスアウト",
            plainLyrics: nil, trackName: "IRIS OUT", artistName: "Kenshi Yonezu", duration: 150
        )
        let timestampOnly = LyricsFetcher.LRCLibRecord(
            syncedLyrics: "[00:01.00]\n[00:05.00]   ",
            plainLyrics: nil, trackName: "IRIS OUT", artistName: "Kenshi Yonezu", duration: 150
        )
        let annotated = LyricsFetcher.LRCLibRecord(
            syncedLyrics: "[00:01.00]頭(あたま) / 아타마 / 머리\n[00:05.00]アイリスアウト / 아이리스 아우토 / 아이리스 아웃",
            plainLyrics: nil, trackName: "IRIS OUT", artistName: "Kenshi Yonezu", duration: 150
        )
        XCTAssertEqual(
            LyricsMatcher.selectBestLRCLibRecord([whitespaceOnly, untimed, timestampOnly, annotated], for: track),
            annotated
        )
    }
}

final class AnnotatedLyricsFetchTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("BarTuneAnnotated-\(UUID().uuidString)")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private let track = TrackInfo(id: "spotify:track:iris", title: "IRIS OUT", artist: "Kenshi Yonezu", album: "IRIS OUT", duration: 150, artworkURL: nil)

    private func fetcher(exact: String?, search: String?, defaultStatusCode: Int = 404) -> LyricsFetcher {
        LyricsFetcher(diskCache: LyricsDiskCache(directory: tempDir, maxEntries: 10)) { request in
            let url = try XCTUnwrap(request.url)
            func reply(_ body: String?) throws -> (Data, URLResponse) {
                let response = try XCTUnwrap(HTTPURLResponse(url: url, statusCode: body == nil ? defaultStatusCode : 200, httpVersion: nil, headerFields: nil))
                return (Data((body ?? "").utf8), response)
            }
            if url.host == "lrclib.net", url.path == "/api/get" {
                return try reply(exact.map { #"{"trackName":"IRIS OUT","artistName":"Kenshi Yonezu","duration":150,"syncedLyrics":"\#($0)"}"# })
            }
            if url.host == "lrclib.net", url.path == "/api/search" {
                return try reply(search.map { #"[{"trackName":"IRIS OUT","artistName":"Kenshi Yonezu","duration":150,"syncedLyrics":"\#($0)"}]"# })
            }
            return try reply(nil)
        }
    }

    private let annotated = #"[00:01.00]頭(あたま) / 아타마 / 머리\n[00:05.00]アイリスアウト / 아이리스 아우토 / 아이리스 아웃"#
    private let plainSearch = #"[00:02.00]頭の中\n[00:06.00]アイリスアウト"#

    func testAnnotatedExactMatchGivesWayToAPlainSearchResult() async {
        let lines = await fetcher(exact: annotated, search: plainSearch).fetchLyrics(for: track)
        XCTAssertEqual(lines.map(\.text), ["頭の中", "アイリスアウト"])
        XCTAssertEqual(lines.map(\.timestamp), [2, 6])
    }

    func testOnlyAnnotatedVersionIsCleanedAndCachedClean() async {
        let lines = await fetcher(exact: annotated, search: nil).fetchLyrics(for: track)
        XCTAssertEqual(lines.map(\.text), ["頭", "アイリスアウト"])
        XCTAssertEqual(LyricsDiskCache(directory: tempDir, maxEntries: 10).load(trackId: track.id)?.map(\.text), ["頭", "アイリスアウト"])
    }

    func testAnnotatedDiskEntryIsFetchedAgain() async {
        let disk = LyricsDiskCache(directory: tempDir, maxEntries: 10)
        disk.save(trackId: track.id, lines: LRCParser.parse(annotated.replacingOccurrences(of: #"\n"#, with: "\n")), title: track.title, artist: track.artist)
        let lines = await fetcher(exact: nil, search: plainSearch).fetchLyrics(for: track)
        XCTAssertEqual(lines.map(\.text), ["頭の中", "アイリスアウト"])
        XCTAssertEqual(lines.map(\.timestamp), [2, 6])
    }

    func testAnnotatedDiskEntryFallsBackCleanWhenProvidersFail() async {
        let disk = LyricsDiskCache(directory: tempDir, maxEntries: 10)
        let cachedAnnotated = LRCParser.parse(annotated.replacingOccurrences(of: #"\n"#, with: "\n"))
        disk.save(trackId: track.id, lines: cachedAnnotated, title: track.title, artist: track.artist)

        let lines = await fetcher(exact: nil, search: nil, defaultStatusCode: 503).lookupLyrics(for: track)
        XCTAssertEqual(lines?.map(\.text), ["頭", "アイリスアウト"])
        // Preserve the annotated disk entry so a later online play can still upgrade to plain lyrics.
        XCTAssertEqual(disk.load(trackId: track.id)?.map(\.text), cachedAnnotated.map(\.text))
    }

    func testAnnotatedDiskEntryFallsBackCleanAndCachesWhenProvidersMiss() async {
        let disk = LyricsDiskCache(directory: tempDir, maxEntries: 10)
        disk.save(trackId: track.id, lines: LRCParser.parse(annotated.replacingOccurrences(of: #"\n"#, with: "\n")), title: track.title, artist: track.artist)

        let lines = await fetcher(exact: nil, search: nil, defaultStatusCode: 404).lookupLyrics(for: track)
        XCTAssertEqual(lines?.map(\.text), ["頭", "アイリスアウト"])
        XCTAssertEqual(disk.load(trackId: track.id)?.map(\.text), ["頭", "アイリスアウト"])
    }

    func testTimestampOnlyExactMatchIsRejectedInFavorOfSearchResult() async {
        let lines = await fetcher(exact: #"[00:01.00]\n[00:05.00]   "#, search: plainSearch).fetchLyrics(for: track)
        XCTAssertEqual(lines.map(\.text), ["頭の中", "アイリスアウト"])
        XCTAssertEqual(lines.map(\.timestamp), [2, 6])
    }
}
