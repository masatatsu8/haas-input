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

    /// 違う1か所の、前後の文の語の並びの中の位置
    private struct Span {
        var old: Range<Int>
        var new: Range<Int>
    }

    /// - hunks: 訂正の窓の欄で手で直した塊。重なる変更を、塊の中で打ち直した前後の共通の語まで広げる
    static func changes(from original: String, to corrected: String, hunks: [HaasEditHunk] = []) -> [HaasTextChange] {
        // 同じ文なら語に分けるまでもない
        guard original != corrected else { return [] }
        let old = HaasJapaneseReading.tokens(in: original)
        let new = HaasJapaneseReading.tokens(in: corrected)
        var spans = wordSpans(old: old, new: new)
        if !hunks.isEmpty, !spans.isEmpty {
            spans = widened(spans, by: hunks, original: original, corrected: corrected, old: old, new: new)
        }
        return spans.map { span in
            let oldTokens = old[span.old]
            let beforeRange = range(of: span.old, in: old)
            return HaasTextChange(
                before: String(original[beforeRange]),
                after: String(corrected[range(of: span.new, in: new)]),
                beforeReading: oldTokens.map(\.reading).joined(),
                beforeHasReading: oldTokens.allSatisfy { $0.isJapanese && $0.hasReading },
                beforeRange: beforeRange
            )
        }
    }

    private static func wordSpans(old: [HaasReadingToken], new: [HaasReadingToken]) -> [Span] {
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

        var spans: [Span] = []
        var i = prefix
        var j = prefix
        var oldStart = prefix
        var newStart = prefix
        func flush(oldEnd: Int, newEnd: Int) {
            // 片側にしかない組 (追加だけ・削除だけ) は返さない。
            guard oldEnd > oldStart, newEnd > newStart else { return }
            spans.append(Span(old: oldStart..<oldEnd, new: newStart..<newEnd))
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
        return spans
    }

    /// 手で直した塊に重なる変更を、外側へ向かって、同じ塊の中で消して打ち直した共通の語が続く間だけ広げる。
    /// 広げるのを止める語 (stopsWidening) や、語の間の句読点・記号・空白に当たったら、そこから先は含めない。
    /// 広げた後が長すぎる変更は広げない。広げて重なった変更は1つにまとめ、まとめた後が長すぎれば、
    /// まとめた変更をどれも広げる前の形で返す
    private static func widened(
        _ spans: [Span], by hunks: [HaasEditHunk], original: String, corrected: String,
        old: [HaasReadingToken], new: [HaasReadingToken]
    ) -> [Span] {
        let edited = hunks.compactMap { hunk -> (original: Range<String.Index>, current: Range<String.Index>)? in
            guard let originalRange = characterRange(hunk.originalRange, in: original),
                let currentRange = characterRange(hunk.currentRange, in: corrected)
            else { return nil }
            return (originalRange, currentRange)
        }
        let limit = HaasCorrectionSuggester.maximumCorrectedLength
        func fits(_ span: Span) -> Bool {
            original[range(of: span.old, in: old)].count <= limit && corrected[range(of: span.new, in: new)].count <= limit
        }
        func widen(_ span: Span) -> Span {
            let overlapping = edited.filter { $0.original.overlaps(range(of: span.old, in: old)) }
            guard !overlapping.isEmpty else { return span }
            func retyped(_ i: Int, _ j: Int) -> Bool {
                old[i].surface == new[j].surface && !stopsWidening(old[i].surface)
                    && overlapping.contains { encloses($0.original, old[i].range) && encloses($0.current, new[j].range) }
            }
            // 語の並びの i - 1 番目と i 番目 (後の文は j - 1 番目と j 番目) の間に、句読点・記号・空白がある
            func separated(_ i: Int, _ j: Int) -> Bool {
                hasSeparator(original[old[i - 1].range.upperBound..<old[i].range.lowerBound])
                    || hasSeparator(corrected[new[j - 1].range.upperBound..<new[j].range.lowerBound])
            }
            var wide = span
            while wide.old.lowerBound > 0, wide.new.lowerBound > 0,
                retyped(wide.old.lowerBound - 1, wide.new.lowerBound - 1),
                !separated(wide.old.lowerBound, wide.new.lowerBound)
            {
                wide = Span(
                    old: (wide.old.lowerBound - 1)..<wide.old.upperBound,
                    new: (wide.new.lowerBound - 1)..<wide.new.upperBound)
            }
            while wide.old.upperBound < old.count, wide.new.upperBound < new.count,
                retyped(wide.old.upperBound, wide.new.upperBound),
                !separated(wide.old.upperBound, wide.new.upperBound)
            {
                wide = Span(
                    old: wide.old.lowerBound..<(wide.old.upperBound + 1),
                    new: wide.new.lowerBound..<(wide.new.upperBound + 1))
            }
            return fits(wide) ? wide : span
        }

        // 1つにまとめた変更と、その元になった広げる前の変更
        var groups: [(span: Span, parts: [Span])] = []
        for span in spans {
            var current = (span: widen(span), parts: [span])
            while let last = groups.last,
                last.span.old.overlaps(current.span.old) || last.span.new.overlaps(current.span.new)
            {
                groups.removeLast()
                current = (
                    span: Span(
                        old: min(last.span.old.lowerBound, current.span.old.lowerBound)
                            ..< max(last.span.old.upperBound, current.span.old.upperBound),
                        new: min(last.span.new.lowerBound, current.span.new.lowerBound)
                            ..< max(last.span.new.upperBound, current.span.new.upperBound)),
                    parts: last.parts + current.parts)
            }
            groups.append(current)
        }
        return groups.flatMap { fits($0.span) ? [$0.span] : $0.parts }
    }

    /// ひらがな・句読点・記号・空白だけの語。助詞や「です」のように、名前の一部ではなく消しすぎた分とみなす。
    /// 漢字・カタカナ・英数字を1文字でも含む語は false
    static func stopsWidening(_ surface: String) -> Bool {
        surface.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x3041...0x3096, 0x309D...0x309F: // ひらがな (ゝゞ を含む)
                return true
            // 長音符はひらがなの語にも付く (すごーい) ので、それだけではカタカナの語とみなさない
            case 0x30FC, 0xFF70:
                return true
            default:
                return isSeparator(scalar)
            }
        }
    }

    /// 語の間に句読点・記号・空白がある。トークナイザーはこれらを語にしないので、語の表記とは別に調べる
    private static func hasSeparator(_ gap: Substring) -> Bool {
        gap.unicodeScalars.contains(where: isSeparator)
    }

    private static func isSeparator(_ scalar: Unicode.Scalar) -> Bool {
        CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
            || CharacterSet.whitespacesAndNewlines.contains(scalar)
    }

    private static func range(of indices: Range<Int>, in tokens: [HaasReadingToken]) -> Range<String.Index> {
        tokens[indices.lowerBound].range.lowerBound..<tokens[indices.upperBound - 1].range.upperBound
    }

    private static func encloses(_ outer: Range<String.Index>, _ inner: Range<String.Index>) -> Bool {
        outer.lowerBound <= inner.lowerBound && inner.upperBound <= outer.upperBound
    }

    /// UTF-16 の位置の範囲を、文字の境目まで外側に広げた text の範囲にする。text に収まらなければ nil
    private static func characterRange(_ range: Range<Int>, in text: String) -> Range<String.Index>? {
        let utf16 = text as NSString
        guard range.lowerBound >= 0, range.upperBound <= utf16.length else { return nil }
        return Range(utf16.rangeOfComposedCharacterSequences(for: NSRange(range)), in: text)
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

    /// - hunks: 訂正の窓の欄で手で直した塊 (HaasEditTracker)。語の差分の変更を、消した範囲まで広げる
    static func suggestions(
        original: String, corrected: String, entries: [HaasVocabularyEntry], hunks: [HaasEditHunk] = []
    ) -> HaasSuggestionResult {
        var suggestions: [HaasDictionarySuggestion] = []
        var usedForms: [String] = []

        for change in HaasCorrectionDiff.changes(from: original, to: corrected, hunks: hunks) {
            // 1. 句読点と空白を除くと同じ変更は捨てる。
            if stripped(change.before) == stripped(change.after) { continue }
            // 2. 直した後が長すぎる変更は書き直しとみなして捨てる。
            if change.after.count > maximumCorrectedLength { continue }
            // 2a. 置き換えルールの元の語はカンマで分けて保存されるため、カンマを含む変更は捨てる。
            if containsComma(change.before) || containsComma(change.after) { continue }
            // 3. 辞書の語の表記にかかる変更は捨てる。
            //    ただし、表記を丸ごと含み、直した後にも同じ数以上残る変更 (巽まさひろ → 巽雅洋) は残す。
            let overlapping = entries.map(\.writtenForm).filter { form in
                guard !form.isEmpty else { return false }
                let found = ranges(of: form, in: original).filter { $0.overlaps(change.beforeRange) }
                guard !found.isEmpty else { return false }
                let enclosed = found.allSatisfy {
                    change.beforeRange.lowerBound <= $0.lowerBound && $0.upperBound <= change.beforeRange.upperBound
                }
                return !(enclosed
                    && ranges(of: form, in: change.before).count <= ranges(of: form, in: change.after).count)
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
