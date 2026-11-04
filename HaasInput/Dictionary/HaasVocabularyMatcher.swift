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
            guard !writtenForm.isEmpty else { continue }
            var sources = entry.readings
            if Self.isKanaOnly(writtenForm) { sources.append(writtenForm) }
            for source in sources {
                guard let key = Self.key(forReading: source),
                      key.count >= Self.minimumKeyLength,
                      !ambiguousKeys.contains(key) else { continue }
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
        let blockedRanges = (writtenForms + protectedTexts).flatMap { Self.occurrences(of: $0, in: text) }
        var output = ""
        var cursor = text.startIndex
        var index = 0
        while index < tokens.count {
            guard tokens[index].isJapanese, let match = longestMatch(from: index, in: tokens, text: text) else {
                index += 1
                continue
            }
            let range = tokens[index].range.lowerBound..<tokens[match.end].range.upperBound
            let spanTokens = tokens[index...match.end]
            index = match.end + 1
            if Self.hasUnsafeBoundary(spanTokens, range: range, in: text) { continue }
            if blockedRanges.contains(where: { $0.overlaps(range) }) { continue }
            output += text[cursor..<range.lowerBound]
            output += match.form
            cursor = range.upperBound
        }
        output += text[cursor...]
        return output
    }

    private func longestMatch(from start: Int, in tokens: [HaasReadingToken], text: String) -> (end: Int, form: String)? {
        var best: (end: Int, form: String)?
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
                best = (end, form)
            }
            end += 1
        }
        return best
    }

    /// 助詞で始まる/終わる複数語の範囲や、漢字・数字の語の途中で切れる範囲は置換しない。
    private static func hasUnsafeBoundary(_ span: ArraySlice<HaasReadingToken>, range: Range<String.Index>, in text: String) -> Bool {
        if span.count >= 2, let first = span.first, let last = span.last,
           isHiraganaOnly(first.surface) || isHiraganaOnly(last.surface) {
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

    private static func isHiraganaOnly(_ text: String) -> Bool {
        !text.isEmpty && text.unicodeScalars.allSatisfy { (0x3041...0x309F).contains($0.value) }
    }

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

    private static func key(forReading reading: String) -> String? {
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
