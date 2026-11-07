import Foundation

enum HaasPunctuationFormatter {
    private static let sentenceEndings = ["です", "ます", "でした", "ました", "ません", "ください"]
    private static let questionEndings = ["ですか", "ますか", "でしょうか", "ませんか", "でしたか", "ましたか"]
    /// 間が空いて区切れても文が続く語尾(接続助詞・格助詞など)。末尾に「。」を付けない。
    static let unfinishedEndings = [
        "ので", "ですが", "あとで", "けれども", "けれど", "けど", "のに", "ながら",
        "から", "まで", "けども", "たら", "て", "で", "と", "が", "を", "に", "は", "も", "し", "ば", "や", "へ", "より",
    ]
    /// 区切りの頭がこの形なら、前の区切りの文はまだ続いている。保留した「。」を付けない
    static let continuationStarts = ["けど", "けれど", "けれども", "けども", "ので", "って", "とか"]
    /// 区切り全体がこの語だけなら、前の区切りの語尾の続き。1文字の助詞は語の頭と区別できないので、全体の一致でだけ見る
    static let continuationWholeSegments = ["ね", "よ", "よね", "ねえ", "な", "なあ", "か"]
    private static let punctuation = Set("、。，．,.!?！？".unicodeScalars)
    /// 区切りの頭にあると、保留した「。」を付けない記号。「.NET」などを妨げないよう半角の「,」「.」は含めない
    private static let leadingPunctuation = Set("、。，．？！?!".unicodeScalars)
    private static let openingMarks = Set("「『（([{【〈《“‘\"'".unicodeScalars)
    static let closingMarks = Set("」』）)]}】〉》”’\"'".unicodeScalars)

    static func fast(_ text: String) -> String {
        let scalars = Array(text.unicodeScalars)
        let end = scalars.lastIndex { !CharacterSet.whitespacesAndNewlines.contains($0) }.map { $0 + 1 } ?? 0
        let body = String(String.UnicodeScalarView(scalars[..<end]))
        let mark: String
        if questionEndings.contains(where: body.hasSuffix) {
            mark = "？"
        } else if sentenceEndings.contains(where: body.hasSuffix) {
            mark = "。"
        } else {
            return text
        }
        let candidate = body + mark + String(String.UnicodeScalarView(scalars[end...]))
        return validatedCandidate(candidate, preserving: text) ?? text
    }

    /// 区切りの最後のスカラーが「。」なら、それを外した本文を返す。閉じ括弧の内側や、後ろに空白がある「。」は動かさない
    static func splittingHeldPeriod(_ text: String) -> (body: String, held: Bool) {
        var body = text.unicodeScalars
        guard body.last == "。" else { return (text, false) }
        body.removeLast()
        guard body.contains(where: { !CharacterSet.whitespacesAndNewlines.contains($0) }) else { return (text, false) }
        return (String(body), true)
    }

    /// 次の区切りの整形前の文から、前の区切りの保留した「。」を付けるかを決める。続きの形でなければ文の切れ目とみなす
    static func startsSentence(_ next: String) -> Bool {
        let head = String(String.UnicodeScalarView(next.unicodeScalars.drop {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }))
        guard let first = head.unicodeScalars.first else { return true }
        if leadingPunctuation.contains(first) { return false }
        if continuationStarts.contains(where: head.hasPrefix) { return false }
        return !continuationWholeSegments.contains(head.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// 保留した「。」を区切りの頭に付ける。頭 (空白の後) がすでに句読点なら付けない
    static func attachingHeldPeriod(to text: String) -> String {
        let first = text.unicodeScalars.first { !CharacterSet.whitespacesAndNewlines.contains($0) }
        if let first, leadingPunctuation.contains(first) { return text }
        return "。" + text
    }

    static func validatedCandidate(_ candidate: String, preserving original: String) -> String? {
        let source = Array(original.unicodeScalars)
        let output = Array(candidate.unicodeScalars)
        var characterBoundaries: Set<Int> = [0]
        var boundary = 0
        for character in original {
            boundary += character.unicodeScalars.count
            characterBoundaries.insert(boundary)
        }

        let end = source.lastIndex {
            !CharacterSet.whitespacesAndNewlines.contains($0) && !closingMarks.contains($0)
        }.map { $0 + 1 } ?? 0
        let ending = String(String.UnicodeScalarView(source[..<end]))
        let isUnfinished = unfinishedEndings.contains(where: ending.hasSuffix)
        var consumed = 0
        for (index, scalar) in output.enumerated() {
            if consumed < source.count, source[consumed] == scalar {
                consumed += 1
                continue
            }
            guard scalar == "、" || scalar == "。" || scalar == "？", characterBoundaries.contains(consumed) else { return nil }
            if scalar == "？", consumed == 0 || source[consumed - 1] != "か" { return nil }
            if consumed > 0, consumed < source.count,
                isLatinIdentifierScalar(source[consumed - 1]), isLatinIdentifierScalar(source[consumed])
            { return nil }
            if isWordApostrophe(at: consumed - 1, in: source) || isWordApostrophe(at: consumed, in: source) {
                return nil
            }
            guard source[..<consumed].contains(where: {
                !CharacterSet.whitespacesAndNewlines.contains($0) && !openingMarks.contains($0)
            }) else {
                return nil
            }
            let previous = output[..<index].last { !CharacterSet.whitespacesAndNewlines.contains($0) }
            let next = output[(index + 1)...].first { !CharacterSet.whitespacesAndNewlines.contains($0) }
            if let previous, openingMarks.contains(previous) {
                let isSymmetricQuote = previous == "\"" || previous == "'"
                let quoteCount = source[..<consumed].indices.filter {
                    source[$0] == previous && !isWordApostrophe(at: $0, in: source)
                }.count
                let closesQuote = isSymmetricQuote && quoteCount.isMultiple(of: 2)
                if !closesQuote { return nil }
            }
            if previous.map(punctuation.contains) == true || next.map(punctuation.contains) == true { return nil }
            if scalar == "。", isUnfinished, consumed >= end { return nil }
        }
        return consumed == source.count ? candidate : nil
    }

    /// 続きがある語尾の原文には、モデルが付けた末尾の「。」を残さない。
    static func removingPeriodAfterUnfinishedEnding(_ candidate: String, original: String) -> String {
        let closing = closingMarks
        func trimmedEnd(_ text: String) -> String.UnicodeScalarView.Index {
            let scalars = text.unicodeScalars
            var end = scalars.endIndex
            while end > scalars.startIndex {
                let previous = scalars.index(before: end)
                let scalar = scalars[previous]
                guard CharacterSet.whitespacesAndNewlines.contains(scalar) || closing.contains(scalar) else { break }
                end = previous
            }
            return end
        }
        let originalEnd = trimmedEnd(original)
        guard unfinishedEndings.contains(where: { String(original.unicodeScalars[..<originalEnd]).hasSuffix($0) }) else {
            return candidate
        }
        let end = trimmedEnd(candidate)
        let scalars = candidate.unicodeScalars
        guard end > scalars.startIndex else { return candidate }
        let last = scalars.index(before: end)
        guard scalars[last] == "。" else { return candidate }
        var result = String.UnicodeScalarView(scalars[..<last])
        result.append(contentsOf: scalars[end...])
        return String(result)
    }

    private static func isLatinIdentifierScalar(_ scalar: Unicode.Scalar) -> Bool {
        isLatinLetterOrDigit(scalar) || [45, 95, 0xFF0D, 0xFF3F].contains(scalar.value)
    }

    private static func isWordApostrophe(at index: Int, in scalars: [Unicode.Scalar]) -> Bool {
        guard index > 0, index + 1 < scalars.count, scalars[index] == "'" else { return false }
        return isLatinLetterOrDigit(scalars[index - 1]) && isLatinLetterOrDigit(scalars[index + 1])
    }

    private static func isLatinLetterOrDigit(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 48...57, 65...90, 97...122,
            0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A:
            true
        default:
            false
        }
    }
}
