import XCTest
@testable import VoiceInk

final class HaasJapaneseReadingTests: XCTestCase {
    func testMatchKeyNormalizesKanaSpacesAndLongVowels() {
        XCTAssertEqual(HaasJapaneseReading.matchKey("ハース"), "はあす")
        XCTAssertEqual(HaasJapaneseReading.matchKey("ジハン プライム"), "じはんぷらいむ")
        XCTAssertEqual(HaasJapaneseReading.matchKey("トーキョー"), HaasJapaneseReading.matchKey("とうきょう"))
        XCTAssertEqual(HaasJapaneseReading.matchKey("セーフ"), HaasJapaneseReading.matchKey("せいふ"))
        XCTAssertEqual(HaasJapaneseReading.matchKey("ボイス・インク"), "ぼいすいんく")
        XCTAssertEqual(HaasJapaneseReading.matchKey("ヂヅ"), HaasJapaneseReading.matchKey("じず"))
    }

    func testTokensCarryReadingKeysAndMarkNonJapaneseTokens() {
        let tokens = HaasJapaneseReading.tokens(in: "辰美さんとJiHAN 2")
        XCTAssertEqual(tokens.first?.surface, "辰美")
        XCTAssertEqual(tokens.first?.key, "たつみ")
        XCTAssertEqual(tokens.first(where: { $0.surface == "JiHAN" })?.isJapanese, false)
        XCTAssertEqual(tokens.first(where: { $0.surface == "2" })?.isJapanese, false)
        let text = "辰美さんとJiHAN 2"
        XCTAssertTrue(tokens.allSatisfy { String(text[$0.range]) == $0.surface })
    }

    func testTokenKeepsHiraganaReadingBeforeNormalization() {
        let token = HaasJapaneseReading.tokens(in: "東京").first
        XCTAssertEqual(token?.reading, "とうきょう")
        XCTAssertEqual(token?.key, "とおきょお")
        XCTAssertEqual(token?.hasReading, true)
    }
}
