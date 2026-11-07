import CoreFoundation
import Foundation

/// 本文中の1語と、その語の照合用の読み。
struct HaasReadingToken: Equatable {
    let range: Range<String.Index>
    let surface: String
    /// 正規化前のひらがなの読み。読みを得られない語は surface と同じ。
    let reading: String
    let key: String
    /// トークナイザーから読みを得られたとき true。surface へのフォールバックでは false。
    let hasReading: Bool
    let isJapanese: Bool
}

/// 日本語の読みを照合用に正規化し、本文を語ごとの読みに分ける。
enum HaasJapaneseReading {
    /// 読みを、表記ゆれを吸収した照合用のひらがな列にする。
    static func matchKey(_ reading: String) -> String {
        let hiragana = reading.applyingTransform(.hiraganaToKatakana, reverse: true) ?? reading
        var result: [Character] = []
        for character in hiragana {
            if character.isWhitespace || character == "・" || character == "=" { continue }
            let mapped = unify(character)
            if mapped == "ー" {
                if let previous = result.last, let vowel = vowel(of: previous) {
                    result.append(vowel)
                } else {
                    result.append(mapped)
                }
                continue
            }
            if let previous = result.last {
                if mapped == "う", vowel(of: previous) == "お" {
                    result.append("お")
                    continue
                }
                if mapped == "い", vowel(of: previous) == "え" {
                    result.append("え")
                    continue
                }
            }
            result.append(mapped)
        }
        return String(result)
    }

    /// 本文を語に分け、語ごとの読みを付ける。
    static func tokens(in text: String) -> [HaasReadingToken] {
        let fullRange = CFRangeMake(0, text.utf16.count)
        guard fullRange.length > 0 else { return [] }
        let tokenizer = CFStringTokenizerCreate(
            kCFAllocatorDefault, text as CFString, fullRange,
            kCFStringTokenizerUnitWord, Locale(identifier: "ja_JP") as CFLocale
        )
        var tokens: [HaasReadingToken] = []
        while !CFStringTokenizerAdvanceToNextToken(tokenizer).isEmpty {
            let cfRange = CFStringTokenizerGetCurrentTokenRange(tokenizer)
            let nsRange = NSRange(location: cfRange.location, length: cfRange.length)
            guard let range = Range(nsRange, in: text) else { continue }
            let surface = String(text[range])
            let transcription = CFStringTokenizerCopyCurrentTokenAttribute(
                tokenizer, kCFStringTokenizerAttributeLatinTranscription
            ) as? String
            let hiragana = transcription.flatMap { $0.applyingTransform(.latinToHiragana, reverse: false) }
            // 髙・𠮷などはトークナイザーが空の読みを返すため、空も「読みなし」とする。
            let obtained = hiragana.flatMap { $0.isEmpty ? nil : $0 }
            // 照合キーは従来どおり (読みが空なら空、読みが nil なら surface から作る)。
            let key = matchKey(hiragana ?? surface)
            // 読みを得られない語の reading は surface と同じ。
            // 照合キーが空でなく日本語の文字を含む語を isJapanese とする。
            // 読みが空の語は key が空になるので対象外、読みが nil の語は surface を読みとして対象になる。
            tokens.append(HaasReadingToken(
                range: range, surface: surface, reading: obtained ?? surface, key: key,
                hasReading: obtained != nil,
                isJapanese: !key.isEmpty && surface.unicodeScalars.contains(where: isJapaneseScalar)
            ))
        }
        return tokens
    }

    private static func unify(_ character: Character) -> Character {
        switch character {
        case "ゔ": "ぶ"
        case "ぢ": "じ"
        case "づ": "ず"
        default: character
        }
    }

    private static func isJapaneseScalar(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3041...0x3096, 0x309D...0x309F, // ひらがな
             0x30A1...0x30FF, 0x31F0...0x31FF, // カタカナ (ー・を含む)
             0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F: // 漢字
            true
        default:
            false
        }
    }

    private static func vowel(of kana: Character) -> Character? {
        let table: [(Character, String)] = [
            ("あ", "ぁあかがさざただなはばぱまゃやらゎわ"),
            ("い", "ぃいきぎしじちぢにひびぴみり"),
            ("う", "ぅうくぐすずつづぬふぶぷむゅゆるゔ"),
            ("え", "ぇえけげせぜてでねへべぺめれ"),
            ("お", "ぉおこごそぞとどのほぼぽもょよろを"),
        ]
        return table.first { $0.1.contains(kana) }?.0
    }
}
