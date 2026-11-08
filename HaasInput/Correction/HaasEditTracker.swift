import Foundation

/// 訂正の窓の欄で、利用者が元の文の文字を消して打ち直した1か所。位置は UTF-16 単位
struct HaasEditHunk: Equatable {
    /// 元の文の中の、消えた範囲
    let originalRange: Range<Int>
    /// 今の文の中の、新しく入れた文字の範囲
    let currentRange: Range<Int>
}

/// 訂正の窓の欄で、元の文のどの文字が消え、どこに利用者の文字が入ったかを追う。
/// 欄の置き換えを1回も取りこぼさずに受け取れている間だけ、塊を返す
struct HaasEditTracker {
    private let originalLength: Int
    /// 記録どおりなら欄にあるはずの文
    private var text: String
    /// 今の欄の UTF-16 単位ごとに、元の文の位置か、利用者が入れた文字 (nil)。無効にしたら nil
    private var sources: [Int?]?

    init(original: String) {
        originalLength = original.utf16.count
        text = original
        sources = Array(0..<originalLength)
    }

    var isValid: Bool { sources != nil }

    /// 欄の range を replacement に置き換えた。範囲が今の欄に収まらなければ記録を無効にする
    mutating func apply(range: NSRange, replacement: String) {
        guard let count = sources?.count, range.location != NSNotFound, range.location >= 0, range.length >= 0,
            range.location <= count, range.length <= count - range.location
        else {
            invalidate()
            return
        }
        let inserted = replacement.utf16.count
        sources?.replaceSubrange(
            range.location..<(range.location + range.length), with: repeatElement(nil, count: inserted))
        text = (text as NSString).replacingCharacters(in: range, with: replacement)
    }

    /// 欄の中身が記録と食い違ったら (取りこぼし)、記録を無効にする
    mutating func check(_ current: String) {
        if text != current { invalidate() }
    }

    mutating func invalidate() {
        sources = nil
    }

    /// 残った元の文字の間ごとに、消えた元の範囲と入れた文字の範囲を組にする。両方が空でない組だけを返す。
    /// 記録が無効か、current が記録と違えば空
    func hunks(in current: String) -> [HaasEditHunk] {
        guard let sources, text == current else { return [] }
        var hunks: [HaasEditHunk] = []
        // 文の始まりと終わりも、残った文字とみなして区切る
        var originalStart = 0
        var currentStart = 0
        func flush(originalEnd: Int, currentEnd: Int) {
            guard originalEnd > originalStart, currentEnd > currentStart else { return }
            hunks.append(HaasEditHunk(
                originalRange: originalStart..<originalEnd, currentRange: currentStart..<currentEnd))
        }
        for (offset, source) in sources.enumerated() {
            guard let source else { continue }
            flush(originalEnd: source, currentEnd: offset)
            originalStart = source + 1
            currentStart = offset + 1
        }
        flush(originalEnd: originalLength, currentEnd: sources.count)
        return hunks
    }
}
