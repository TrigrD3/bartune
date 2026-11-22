@testable import BarTune
import XCTest

final class WhisperTimingTests: XCTestCase {
    private func parse(_ words: String) -> [RecognizedAudioWord] {
        let json = #"{"segments":[{"start":0,"end":3,"text":"x","words":[\#(words)]}]}"#
        return WhisperJSONParser.parse(data: Data(json.utf8), chunkStartTime: 20)
    }

    func testDTWTimestampsReplaceTheDefaultTokenStart() {
        let words = parse(#"""
        {"word":"忘","start":7.35,"end":7.43,"t_dtw":662,"probability":0.9},
        {"word":"光","start":8.81,"end":9.19,"t_dtw":846,"probability":0.9}
        """#)

        XCTAssertEqual(words.map(\.text), ["忘", "光"])
        XCTAssertEqual(words[0].startTime, 26.62, accuracy: 0.001)
        XCTAssertEqual(words[0].duration, 0.08, accuracy: 0.001)
        XCTAssertEqual(words[1].startTime, 28.46, accuracy: 0.001)
    }

    func testTokensWithoutDTWKeepTheirOwnStart() {
        let words = parse(#"{"word":"光","start":8.81,"end":9.19,"t_dtw":-1,"probability":0.9}"#)
        XCTAssertEqual(words.first?.startTime ?? 0, 28.81, accuracy: 0.001)
    }

    func testDTWPresetFollowsTheModelFile() {
        XCTAssertEqual(WhisperServer.dtwPreset(forModelPath: "/m/ggml-base.bin"), "base")
        XCTAssertEqual(WhisperServer.dtwPreset(forModelPath: "/m/ggml-medium.en.bin"), "medium.en")
        XCTAssertEqual(WhisperServer.dtwPreset(forModelPath: "/m/ggml-large-v3-turbo-q5_0.bin"), "large.v3.turbo")
        XCTAssertEqual(WhisperServer.dtwPreset(forModelPath: "/m/ggml-small-q8_0.bin"), "small")
        XCTAssertNil(WhisperServer.dtwPreset(forModelPath: "/m/ggml-kotoba-whisper.bin"))
        XCTAssertNil(WhisperServer.dtwPreset(forModelPath: "/m/model.bin"))
    }
}
