import Foundation

enum HaasPunctuationFormatter {
    private static let sentenceEndings = ["です", "ます", "でした", "ました", "ません", "ください"]
    private static let questionEndings = ["ですか", "ますか", "でしょうか", "ませんか", "でしたか", "ましたか"]
    static let unfinishedEndings = ["ので", "ですが", "あとで", "けれども", "けれど", "けど", "のに", "ながら"]
    private static let punctuation = Set("、。，．,.!?！？".unicodeScalars)
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
