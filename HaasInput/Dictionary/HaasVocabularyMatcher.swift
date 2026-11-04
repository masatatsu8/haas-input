import Foundation

/// 辞書の読みと一致する誤認識を、正式表記に置き換える。
struct HaasVocabularyMatcher {
    static let minimumKeyLength = 3
    static let maximumSpanTokens = 8

    static let empty = HaasVocabularyMatcher(entries: [])

    /// 照合キー (正規化した読み) から正式表記への対応。曖昧なキーは含まない。
    private let formsByKey: [String: String]

    var writtenForms: [String]

    init(entries: [HaasVocabularyEntry]) {
        var forms: [String: String] = [:]
        var ambiguousKeys: Set<String> = []
        for entry in entries {
            let writtenForm = entry.writtenForm.trimmingCharacters(in: .whitespacesAndNewlines)
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
        writtenForms = entries.map(\.writtenForm)
    }

    func apply(to text: String, protecting protectedTexts: [String] = []) -> String {
        guard !formsByKey.isEmpty else { return text }
        let tokens = HaasJapaneseReading.tokens(in: text)
        let protectedRanges = protectedTexts.flatMap { Self.occurrences(of: $0, in: text) }
        var replacements: [(range: Range<String.Index>, form: String)] = []
        var index = 0
        while index < tokens.count {
            guard tokens[index].isJapanese, let match = longestMatch(from: index, in: tokens, text: text) else {
                index += 1
                continue
            }
            let range = tokens[index].range.lowerBound..<tokens[match.end].range.upperBound
            index = match.end + 1
            if text[range] == match.form { continue }
            let blocked = protectedRanges + Self.occurrences(of: match.form, in: text)
            if blocked.contains(where: { $0.overlaps(range) }) { continue }
            replacements.append((range, match.form))
        }
        var result = text
        for replacement in replacements.reversed() {
            result.replaceSubrange(replacement.range, with: replacement.form)
        }
        return result
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
