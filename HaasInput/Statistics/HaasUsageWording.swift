import Foundation

/// 利用状況の表示文言。数の表記はロケールに依存させない。
enum HaasUsageWording {
    static let notUsedToday = "今日はまだ。1文だけ話してみませんか"
    static let emptyHistory = "最初の1文を話すと、ここに記録が育ちます"

    private static let manuscriptPageCharacters = 400
    private static let shortStoryCharacters = 20_000
    private static let paperbackCharacters = 100_000
    private static let movieSeconds: TimeInterval = 7_200
    private static let keyboardCharactersPerMinute = 60

    /// 分は切り捨て。
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "0分" }
        guard seconds >= 60 else { return "1分未満" }
        let totalMinutes = Int(seconds / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 { return "\(minutes)分" }
        return minutes == 0 ? "\(hours)時間" : "\(hours)時間\(minutes)分"
    }

    static func characters(_ count: Int) -> String {
        guard count >= 10_000 else { return "\(grouped(count))文字" }
        // 小数1桁に四捨五入し、末尾の .0 は付けない
        let tenths = Int((Double(count) / 1_000).rounded())
        let text = tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10).\(tenths % 10)"
        return "\(text)万字"
    }

    static func characterEquivalent(_ count: Int) -> String? {
        if count >= paperbackCharacters {
            return "文庫本 約\(rounded(count, per: paperbackCharacters))冊分"
        }
        if count >= shortStoryCharacters {
            return "短編小説 約\(rounded(count, per: shortStoryCharacters))編分"
        }
        if count >= manuscriptPageCharacters {
            return "原稿用紙 約\(rounded(count, per: manuscriptPageCharacters))枚分"
        }
        return nil
    }

    /// 1分あたり60文字で打つ場合の所要分 (切り上げ)。
    static func keyboardMinutes(_ count: Int) -> Int {
        (count + keyboardCharactersPerMinute - 1) / keyboardCharactersPerMinute
    }

    static func durationEquivalent(_ seconds: TimeInterval) -> String? {
        guard seconds >= movieSeconds else { return nil }
        return "映画 約\(max(1, Int((seconds / movieSeconds).rounded())))本分"
    }

    static func todayDetail(_ summary: HaasUsageSummary) -> String? {
        let today = summary.today
        guard today.isUsed else { return nil }
        let keyboard = "キーボードなら約\(keyboardMinutes(today.characters))分かかる量です"
        guard let equivalent = characterEquivalent(today.characters) else { return keyboard }
        return "\(equivalent)。\(keyboard)"
    }

    static func streak(_ summary: HaasUsageSummary) -> String? {
        guard summary.currentStreak >= 2 else { return nil }
        return "🔥 \(summary.currentStreak)日連続で使っています"
    }

    static func comparison(_ summary: HaasUsageSummary) -> (headline: String, detail: String) {
        guard let average = summary.recentAverageDuration, average > 0 else {
            return ("使い始めの記録を集めています", "3日ほど使うと、いつもの量と比べられるようになります")
        }
        let minutes = max(1, Int((average / 60).rounded()))
        let detail = "最近の1日平均は約\(minutes)分です"
        guard summary.today.isUsed else { return (notUsedToday, detail) }
        let today = summary.today.duration
        if today >= average { return ("いつもを超えました。いい調子です", detail) }
        // 先に100倍してから割り、浮動小数の誤差を避けて切り捨てる。0%と100%は表示しない
        let percent = min(99, max(1, Int((today * 100 / average).rounded(.down))))
        return ("いつもの\(percent)%まで来ました", detail)
    }

    /// 今日 ÷ 平均 (0〜1)。平均がなければ 0。
    static func comparisonRatio(_ summary: HaasUsageSummary) -> Double {
        guard let average = summary.recentAverageDuration, average > 0 else { return 0 }
        return min(1, max(0, summary.today.duration / average))
    }

    private static func rounded(_ count: Int, per unit: Int) -> Int {
        max(1, Int((Double(count) / Double(unit)).rounded()))
    }

    private static func grouped(_ count: Int) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = true
        formatter.groupingSeparator = ","
        formatter.groupingSize = 3
        return formatter.string(from: NSNumber(value: count)) ?? "\(count)"
    }
}
