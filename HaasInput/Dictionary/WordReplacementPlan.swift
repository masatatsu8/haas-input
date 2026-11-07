import Foundation

struct WordReplacementPlan {
    struct Record: Equatable {
        let id: UUID
        let originalText: String
        let replacementText: String
        let dateAdded: Date
    }

    private struct PreparedRule {
        let original: String
        let replacement: String
        let regex: NSRegularExpression?
    }

    private let rules: [PreparedRule]
    let replacementTexts: [String]

    init(records: [Record]) throws {
        let sortedRules = records
            .flatMap { record in
                WordReplacementVariants.parse(record.originalText).map {
                    (
                        original: $0,
                        replacement: record.replacementText,
                        dateAdded: record.dateAdded,
                        id: record.id.uuidString
                    )
                }
            }
            .sorted {
                if $0.original.count != $1.original.count {
                    return $0.original.count > $1.original.count
                }
                let leftKey = WordReplacementVariants.key(for: $0.original)
                let rightKey = WordReplacementVariants.key(for: $1.original)
                if leftKey != rightKey {
                    return leftKey < rightKey
                }
                if $0.dateAdded != $1.dateAdded {
                    return $0.dateAdded < $1.dateAdded
                }
                return $0.id < $1.id
            }

        var seenTexts = Set<String>()
        replacementTexts = sortedRules.map(\.replacement).filter { !$0.isEmpty && seenTexts.insert($0).inserted }

        rules = try sortedRules.map { rule in
            let escaped = NSRegularExpression.escapedPattern(for: rule.original)
            let pattern: String?
            if rule.original.range(of: "\\A\\p{sc=Han}+\\z", options: .regularExpression) != nil
            {
                pattern = "(?<!\\p{sc=Han})\(escaped)(?!\\p{sc=Han})"
            } else if Self.usesWordBoundaries(for: rule.original) {
                let wordChar = "[[\\p{L}\\p{M}\\p{N}]-[\\p{scx=Han}\\p{scx=Hiragana}\\p{scx=Katakana}\\p{scx=Hangul}\\p{scx=Thai}]]"
                pattern = "(?<!\(wordChar))\(escaped)(?!\(wordChar))"
            } else {
                pattern = nil
            }

            let regex = try pattern.map { try NSRegularExpression(pattern: $0, options: .caseInsensitive) }
            return PreparedRule(original: rule.original, replacement: rule.replacement, regex: regex)
        }
    }

    func apply(to text: String) -> String {
        var result = text
        for rule in rules {
            if let regex = rule.regex {
                let range = NSRange(result.startIndex..., in: result)
                result = regex.stringByReplacingMatches(
                    in: result,
                    options: [],
                    range: range,
                    withTemplate: NSRegularExpression.escapedTemplate(for: rule.replacement)
                )
            } else {
                result = result.replacingOccurrences(of: rule.original, with: rule.replacement, options: .caseInsensitive)
            }
        }
        return result
    }

    private static func usesWordBoundaries(for text: String) -> Bool {
        let nonSpacedScripts: [ClosedRange<UInt32>] = [
            0x3040...0x309F,
            0x30A0...0x30FF,
            0x4E00...0x9FFF,
            0xAC00...0xD7AF,
            0x0E00...0x0E7F,
        ]
        return !text.unicodeScalars.contains { scalar in
            nonSpacedScripts.contains { $0.contains(scalar.value) }
        }
    }
}
