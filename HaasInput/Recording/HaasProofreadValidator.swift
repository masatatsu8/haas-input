import Foundation

enum HaasProofreadValidator {
    static let maximumEditRatio = 0.2
    static let minimumEditAllowance = 2

    static func validatedCandidate(_ candidate: String, preserving original: String, protectedTerms: [String]) -> String? {
        guard !candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        if !original.contains(where: \.isNewline), candidate.contains(where: \.isNewline) { return nil }

        let normalizedOriginal = normalized(original)
        let normalizedCandidate = normalized(candidate)
        let strippedOriginal = Array(stripPunctuation(normalizedOriginal))
        let strippedCandidate = Array(stripPunctuation(normalizedCandidate))
        let allowance = max(minimumEditAllowance, Int(Double(strippedOriginal.count) * maximumEditRatio))
        guard editDistance(strippedOriginal, strippedCandidate) <= allowance else { return nil }

        guard foreignRuns(in: normalizedOriginal) == foreignRuns(in: normalizedCandidate) else { return nil }

        for term in protectedTerms where !term.isEmpty {
            if occurrences(of: term, in: original) != occurrences(of: term, in: candidate) { return nil }
        }
        return candidate
    }

    private static func normalized(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping
    }

    private static func stripPunctuation(_ text: String) -> String {
        text.filter { $0 != "、" && $0 != "。" }
    }

    private static func isJapanese(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x3041...0x3096, 0x30A1...0x30FA, 0x30FC, 0x30FB, 0x4E00...0x9FFF, 0x3005, 0x3006:
            true
        default:
            false
        }
    }

    private static func isSeparator(_ character: Character) -> Bool {
        character.isWhitespace || character == "、" || character == "。"
            || (character.unicodeScalars.allSatisfy(isJapanese))
    }

    private static func foreignRuns(in text: String) -> [String] {
        var runs: [String] = []
        var current = ""
        for character in text {
            if isSeparator(character) {
                if !current.isEmpty { runs.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }

    private static func occurrences(of term: String, in text: String) -> Int {
        var count = 0
        var range = text.startIndex..<text.endIndex
        while let found = text.range(of: term, range: range) {
            count += 1
            range = found.upperBound..<text.endIndex
        }
        return count
    }

    private static func editDistance(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var row = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                row[j] = min(previous[j] + 1, row[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = row
        }
        return previous[b.count]
    }
}
