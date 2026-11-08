import Foundation

/// 辞書の読みと一致する誤認識を、正式表記に置き換える。
struct HaasVocabularyMatcher {
    static let minimumKeyLength = 3
    static let maximumSpanTokens = 8

    static let empty = HaasVocabularyMatcher(entries: [])

    /// 照合キー (正規化した読み) から正式表記への対応。曖昧なキーは含まない。
    private let formsByKey: [String: String]

    let writtenForms: [String]

    init(entries: [HaasVocabularyEntry]) {
        var forms: [String: String] = [:]
        var ambiguousKeys: Set<String> = []
        let trimmedForms = entries.map { $0.writtenForm.trimmingCharacters(in: .whitespacesAndNewlines) }
        for (entry, writtenForm) in zip(entries, trimmedForms) {
            for key in Self.matchingKeys(writtenForm: writtenForm, readings: entry.readings) {
                guard !ambiguousKeys.contains(key) else { continue }
                if let existing = forms[key], existing != writtenForm {
                    forms[key] = nil
                    ambiguousKeys.insert(key)
                } else {
                    forms[key] = writtenForm
                }
            }
        }
        formsByKey = forms
        var seen: Set<String> = []
        writtenForms = trimmedForms.compactMap { form in
            !form.isEmpty && seen.insert(form).inserted ? form : nil
        }
    }

    func apply(to text: String, protecting protectedTexts: [String] = []) -> String {
        guard !formsByKey.isEmpty else { return text }
        let tokens = HaasJapaneseReading.tokens(in: text)
        let protectedRanges = protectedTexts.flatMap { Self.occurrences(of: $0, in: text) }
        let writtenFormRanges = writtenForms.flatMap { form in Self.occurrences(of: form, in: text).map { (form, $0) } }
        var output = ""
        var cursor = text.startIndex
        var index = 0
        while index < tokens.count {
            guard tokens[index].isJapanese else {
                index += 1
                continue
            }
            var replaced = false
            for match in candidates(from: index, in: tokens, text: text).reversed() {
                let range = tokens[index].range.lowerBound..<tokens[match.end].range.upperBound
                if Self.hasUnsafeBoundary(tokens[index...match.end], range: range, in: text) { continue }
                if protectedRanges.contains(where: { $0.overlaps(range) }) { continue }
                // 書かれた正式表記は書き換えない。ただし、範囲がそれより長く丸ごと含み、置き換える語にもその表記が
                // 同じ数以上あるときは、長い語の一部として残る (認識が「斎藤」と書いた「斎藤浩」を「斎藤博」にする)
                if writtenFormRanges.contains(where: { form, found in
                    found.overlaps(range)
                        && !(range.lowerBound <= found.lowerBound && found.upperBound <= range.upperBound
                            && found != range
                            && Self.occurrences(of: form, in: match.form).count
                                >= Self.occurrences(of: form, in: String(text[range])).count)
                }) { continue }
                output += text[cursor..<range.lowerBound]
                output += match.form
                cursor = range.upperBound
                index = match.end + 1
                replaced = true
                break
            }
            if !replaced { index += 1 }
        }
        output += text[cursor...]
        return output
    }

    /// start から始まる辞書語との一致を、短い順に返す。
    private func candidates(from start: Int, in tokens: [HaasReadingToken], text: String) -> [(end: Int, form: String)] {
        var found: [(end: Int, form: String)] = []
        var joined = ""
        var end = start
        while end < tokens.count, end - start < Self.maximumSpanTokens {
            let token = tokens[end]
            guard token.isJapanese else { break }
            if end > start {
                let gap = text[tokens[end - 1].range.upperBound..<token.range.lowerBound]
                guard gap.allSatisfy({ $0.isWhitespace || $0 == "・" }) else { break }
            }
            joined += token.key
            if let form = formsByKey[HaasJapaneseReading.matchKey(joined)] {
                found.append((end, form))
            }
            end += 1
        }
        return found
    }

    /// 助詞で始まる/終わる複数語の範囲や、漢字・数字の語の途中で切れる範囲は置換しない。
    private static func hasUnsafeBoundary(_ span: ArraySlice<HaasReadingToken>, range: Range<String.Index>, in text: String) -> Bool {
        if span.count >= 2, let first = span.first, let last = span.last,
           particles.contains(first.surface) || particles.contains(last.surface) {
            return true
        }
        if let first = text[range].first, isKanji(first), range.lowerBound > text.startIndex,
           let before = text[..<range.lowerBound].last, isKanji(before) || isDigit(before) {
            return true
        }
        if let last = text[range].last, isKanji(last), range.upperBound < text.endIndex,
           let after = text[range.upperBound...].first, isKanji(after) || isDigit(after) {
            return true
        }
        return false
    }

    private static let particles: Set<String> = [
        "は", "が", "を", "に", "で", "と", "も", "へ", "の", "や", "か", "ね", "よ", "から", "まで", "より", "など",
    ]

    private static func isKanji(_ character: Character) -> Bool {
        character.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x2FA1F, 0x3005, 0x3006: true
            default: false
            }
        }
    }

    private static func isDigit(_ character: Character) -> Bool {
        character.unicodeScalars.contains { ($0.value >= 0x30 && $0.value <= 0x39) || (0xFF10...0xFF19).contains($0.value) }
    }

    /// 語の照合に使うキー (正規化した読み)。読みと、カナだけの正式表記から作る。短すぎるキーは含まない。
    /// 照合、訂正の候補づくり、登録前の確認で同じものを使う
    static func matchingKeys(writtenForm: String, readings: [String]) -> [String] {
        let form = writtenForm.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !form.isEmpty else { return [] }
        var sources = readings
        if isKanaOnly(form) { sources.append(form) }
        return sources.compactMap { source in
            guard let key = key(forReading: source), key.count >= minimumKeyLength else { return nil }
            return key
        }
    }

    static func matchingKeys(of entry: HaasVocabularyEntry) -> [String] {
        matchingKeys(writtenForm: entry.writtenForm, readings: entry.readings)
    }

    /// 読み1つを照合と同じ方法で正規化したキー。照合に使えない読みなら nil (短さは見ない)
    static func key(forReading reading: String) -> String? {
        if isKanaOnly(reading) {
            let key = HaasJapaneseReading.matchKey(reading)
            return key.isEmpty ? nil : key
        }
        let tokens = HaasJapaneseReading.tokens(in: reading)
        guard !tokens.isEmpty, tokens.allSatisfy(\.isJapanese) else { return nil }
        let key = HaasJapaneseReading.matchKey(tokens.map(\.key).joined())
        return key.isEmpty ? nil : key
    }

    private static func isKanaOnly(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x3041...0x3096, 0x309D...0x309F, 0x30A1...0x30FF, 0x31F0...0x31FF: true
            default: CharacterSet.whitespaces.contains(scalar)
            }
        }
    }

    private static func occurrences(of needle: String, in text: String) -> [Range<String.Index>] {
        guard !needle.isEmpty else { return [] }
        var ranges: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let range = text.range(of: needle, range: searchStart..<text.endIndex) {
            ranges.append(range)
            searchStart = text.index(after: range.lowerBound)
        }
        return ranges
    }
}
