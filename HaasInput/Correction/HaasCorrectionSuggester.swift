import Foundation

/// 直す前と後の文の間で、語単位に見つかった1か所の違い。
struct HaasTextChange: Equatable {
    let before: String
    let after: String
    let beforeReading: String
    let beforeHasReading: Bool
    let beforeRange: Range<String.Index>
}

/// 直す前と後の文を語に分け、置き換わった部分を取り出す。
enum HaasCorrectionDiff {
    /// 最長共通部分列の表の大きさの上限 (前後の共通部分を除いた語の数の積)。
    /// 超えるときは違いを探さない (辞書の候補を出さないだけで、訂正は続ける)
    static let maximumTableCells = 40_000

    static func changes(from original: String, to corrected: String) -> [HaasTextChange] {
        // 同じ文なら語に分けるまでもない
        guard original != corrected else { return [] }
        let old = HaasJapaneseReading.tokens(in: original)
        let new = HaasJapaneseReading.tokens(in: corrected)

        // 前後の共通の語を除き、残りの部分だけで表を作る
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix].surface == new[prefix].surface { prefix += 1 }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
            old[old.count - 1 - suffix].surface == new[new.count - 1 - suffix].surface
        {
            suffix += 1
        }
        let oldEnd = old.count - suffix
        let newEnd = new.count - suffix
        let rows = oldEnd - prefix
        let columns = newEnd - prefix
        guard rows * columns <= maximumTableCells else { return [] }

        // 残りの語の表記の並びで最長共通部分列を取る。table[i][j] は old[prefix + i...] と new[prefix + j...] の長さ
        var table = Array(repeating: Array(repeating: 0, count: columns + 1), count: rows + 1)
        for i in stride(from: rows - 1, through: 0, by: -1) {
            for j in stride(from: columns - 1, through: 0, by: -1) {
                table[i][j] = old[prefix + i].surface == new[prefix + j].surface
                    ? table[i + 1][j + 1] + 1
                    : max(table[i + 1][j], table[i][j + 1])
            }
        }

        var changes: [HaasTextChange] = []
        var i = prefix
        var j = prefix
        var oldStart = prefix
        var newStart = prefix
        func flush(oldEnd: Int, newEnd: Int) {
            // 片側にしかない組 (追加だけ・削除だけ) は返さない。
            guard oldEnd > oldStart, newEnd > newStart else { return }
            let oldTokens = old[oldStart..<oldEnd]
            let newTokens = new[newStart..<newEnd]
            let beforeRange = oldTokens.first!.range.lowerBound..<oldTokens.last!.range.upperBound
            let afterRange = newTokens.first!.range.lowerBound..<newTokens.last!.range.upperBound
            changes.append(HaasTextChange(
                before: String(original[beforeRange]),
                after: String(corrected[afterRange]),
                beforeReading: oldTokens.map(\.reading).joined(),
                beforeHasReading: oldTokens.allSatisfy { $0.isJapanese && $0.hasReading },
                beforeRange: beforeRange
            ))
        }
        while i < oldEnd || j < newEnd {
            if i < oldEnd, j < newEnd, old[i].surface == new[j].surface {
                flush(oldEnd: i, newEnd: j)
                i += 1
                j += 1
                oldStart = i
                newStart = j
            } else if j == newEnd || (i < oldEnd && table[i - prefix + 1][j - prefix] >= table[i - prefix][j - prefix + 1]) {
                i += 1
            } else {
                j += 1
            }
        }
        // 後ろの共通の語の手前で区切る
        flush(oldEnd: i, newEnd: j)
        return changes
    }
}

/// 辞書に登録する候補1件。
struct HaasDictionarySuggestion: Equatable, Identifiable {
    enum Kind: Equatable {
        case newWord
        case addReading(entryID: UUID)
        case replacement
    }

    let id: Int
    let kind: Kind
    let before: String
    let writtenForm: String
    /// replacement のときは空。
    var reading: String
}

struct HaasSuggestionResult: Equatable {
    let suggestions: [HaasDictionarySuggestion]
    /// 変更が辞書の語の表記の内側だったため、候補にしなかった語 (重複なし、出た順)。
    let usedDictionaryForms: [String]
}

/// 直した結果から、辞書に登録する候補を作る。
enum HaasCorrectionSuggester {
    static let maximumCorrectedLength = 20

    private static let ignoredCharacters: Set<Character> = ["、", "。", "？", "?"]

    static func suggestions(
        original: String, corrected: String, entries: [HaasVocabularyEntry]
    ) -> HaasSuggestionResult {
        var suggestions: [HaasDictionarySuggestion] = []
        var usedForms: [String] = []

        for change in HaasCorrectionDiff.changes(from: original, to: corrected) {
            // 1. 句読点と空白を除くと同じ変更は捨てる。
            if stripped(change.before) == stripped(change.after) { continue }
            // 2. 直した後が長すぎる変更は書き直しとみなして捨てる。
            if change.after.count > maximumCorrectedLength { continue }
            // 2a. 置き換えルールの元の語はカンマで分けて保存されるため、カンマを含む変更は捨てる。
            if containsComma(change.before) || containsComma(change.after) { continue }
            // 3. 辞書の語の表記の内側の変更は捨てる。
            let overlapping = entries.map(\.writtenForm).filter { form in
                !form.isEmpty && ranges(of: form, in: original).contains { $0.overlaps(change.beforeRange) }
            }
            if !overlapping.isEmpty {
                for form in overlapping where !usedForms.contains(form) { usedForms.append(form) }
                continue
            }

            let id = suggestions.count
            // 4. 読みが当てにならない、または短すぎる語は置き換えルールにする。
            //    キーは照合 (HaasVocabularyMatcher) と同じ方法で作る。
            guard change.beforeHasReading,
                  let key = HaasVocabularyMatcher.key(forReading: change.beforeReading),
                  key.count >= HaasVocabularyMatcher.minimumKeyLength
            else {
                suggestions.append(replacement(id, change))
                continue
            }
            // 5. 登録で増えるキー (読みと、カナだけの正式表記) を別の語が持っているときは置き換えルールにする。
            //    別の語のキーには、読みのほかにカナだけの正式表記も含む。
            let addedKeys = Set(HaasVocabularyMatcher.matchingKeys(writtenForm: change.after, readings: [change.beforeReading]))
            if entries.contains(where: { entry in
                entry.writtenForm != change.after
                    && !addedKeys.isDisjoint(with: HaasVocabularyMatcher.matchingKeys(of: entry))
            }) {
                suggestions.append(replacement(id, change))
                continue
            }
            // 6. 同じ表記の語があれば、読みの追加か、何もしないかを決める。
            if let existing = entries.first(where: { $0.writtenForm == change.after }) {
                if HaasVocabularyMatcher.matchingKeys(of: existing).contains(key) { continue }
                suggestions.append(HaasDictionarySuggestion(
                    id: id, kind: .addReading(entryID: existing.id),
                    before: change.before, writtenForm: change.after, reading: change.beforeReading
                ))
                continue
            }
            // 7. 新しい語。
            suggestions.append(HaasDictionarySuggestion(
                id: id, kind: .newWord,
                before: change.before, writtenForm: change.after, reading: change.beforeReading
            ))
        }
        return HaasSuggestionResult(suggestions: suggestions, usedDictionaryForms: usedForms)
    }

    private static func replacement(_ id: Int, _ change: HaasTextChange) -> HaasDictionarySuggestion {
        HaasDictionarySuggestion(
            id: id, kind: .replacement, before: change.before, writtenForm: change.after, reading: ""
        )
    }

    private static func stripped(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace && !ignoredCharacters.contains($0) })
    }

    private static func containsComma(_ text: String) -> Bool {
        text.contains(",") || text.contains("，")
    }

    private static func ranges(of form: String, in text: String) -> [Range<String.Index>] {
        var result: [Range<String.Index>] = []
        var searchStart = text.startIndex
        while searchStart < text.endIndex,
              let found = text.range(of: form, range: searchStart..<text.endIndex) {
            result.append(found)
            searchStart = found.lowerBound < text.endIndex ? text.index(after: found.lowerBound) : text.endIndex
        }
        return result
    }
}
