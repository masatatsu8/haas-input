import Foundation

/// 1回の音声入力の記録 (集計の入力)。
struct HaasUsageSample: Equatable, Sendable {
    let timestamp: Date
    let duration: TimeInterval
    let characters: Int

    /// 空白と改行を除いた文字数。
    static func characterCount(_ text: String) -> Int {
        text.filter { !$0.isWhitespace }.count
    }
}

/// 1日分の集計。
struct HaasUsageDay: Equatable, Sendable {
    /// その日の0時
    let day: Date
    let duration: TimeInterval
    let characters: Int
    let recordings: Int

    var isUsed: Bool { recordings > 0 }
}

/// 利用状況の集計。時刻と暦は呼び出し側から渡す。
struct HaasUsageSummary: Equatable, Sendable {
    private static let gridWeeks = 53
    private static let recentDays = 28
    private static let recentMinimumUsedDays = 3

    let today: HaasUsageDay
    /// 6日前から今日まで (古い順)
    let lastSevenDays: [HaasUsageDay]
    /// 53週分。今日を含む週の最後の日まで。
    let grid: [HaasUsageDay]
    let totalDuration: TimeInterval
    let totalCharacters: Int
    let usedDays: Int
    let currentStreak: Int
    let longestStreak: Int
    let recentAverageDuration: TimeInterval?

    /// 使用日の文字数の四分位 (25%・50%・75%) と最大値。使用日がなければ nil。
    private let thresholds: Thresholds?

    private struct Thresholds: Equatable, Sendable {
        let q1: Int
        let q2: Int
        let q3: Int
        let max: Int
    }

    init(samples: [HaasUsageSample], now: Date, calendar: Calendar) {
        var byDay: [Date: HaasUsageDay] = [:]
        for sample in samples where sample.characters > 0 {
            let key = calendar.startOfDay(for: sample.timestamp)
            let current = byDay[key] ?? HaasUsageDay(day: key, duration: 0, characters: 0, recordings: 0)
            byDay[key] = HaasUsageDay(
                day: key,
                duration: current.duration + sample.duration,
                characters: current.characters + sample.characters,
                recordings: current.recordings + 1
            )
        }

        func day(_ key: Date) -> HaasUsageDay {
            byDay[key] ?? HaasUsageDay(day: key, duration: 0, characters: 0, recordings: 0)
        }
        func offset(_ key: Date, days: Int) -> Date {
            calendar.date(byAdding: .day, value: days, to: key) ?? key
        }

        let todayKey = calendar.startOfDay(for: now)
        today = day(todayKey)
        lastSevenDays = (-6...0).map { day(offset(todayKey, days: $0)) }

        // 暦の週の始まり (calendar.firstWeekday) から数えた53週分
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: todayKey)?.start ?? todayKey
        let gridStart = offset(weekStart, days: -7 * (Self.gridWeeks - 1))
        // 今日より後の日は、時計のずれなどで未来の記録があっても未使用として扱う
        grid = (0..<(7 * Self.gridWeeks)).map { index in
            let key = offset(gridStart, days: index)
            return key > todayKey ? HaasUsageDay(day: key, duration: 0, characters: 0, recordings: 0) : day(key)
        }

        let all = Array(byDay.values)
        totalDuration = all.reduce(0) { $0 + $1.duration }
        totalCharacters = all.reduce(0) { $0 + $1.characters }
        usedDays = all.count

        // 今日が未使用でも、昨日までの連続は途切れていないものとして数える
        var cursor = today.isUsed ? todayKey : offset(todayKey, days: -1)
        var streak = 0
        while byDay[cursor] != nil {
            streak += 1
            cursor = offset(cursor, days: -1)
        }
        currentStreak = streak

        var longest = 0
        var run = 0
        var previous: Date?
        for key in byDay.keys.sorted() {
            if let previous, offset(previous, days: 1) == key {
                run += 1
            } else {
                run = 1
            }
            longest = max(longest, run)
            previous = key
        }
        longestStreak = longest

        // 今日を除く直近28日の使用日の平均
        let recentUsed = (1...Self.recentDays).compactMap { byDay[offset(todayKey, days: -$0)] }
        recentAverageDuration = recentUsed.count >= Self.recentMinimumUsedDays
            ? recentUsed.reduce(0) { $0 + $1.duration } / Double(recentUsed.count)
            : nil

        let sorted = all.map(\.characters).sorted()
        if let maximum = sorted.last {
            func quantile(_ p: Double) -> Int { sorted[Int(Double(sorted.count - 1) * p)] }
            thresholds = Thresholds(q1: quantile(0.25), q2: quantile(0.5), q3: quantile(0.75), max: maximum)
        } else {
            thresholds = nil
        }
    }

    /// 草の濃さ (0: 未使用、1〜4: 使用日の文字数の四分位)。
    func level(for day: HaasUsageDay) -> Int {
        guard day.isUsed, let t = thresholds else { return 0 }
        if day.characters >= t.max { return 4 }
        if day.characters <= t.q1 { return 1 }
        if day.characters <= t.q2 { return 2 }
        if day.characters <= t.q3 { return 3 }
        return 4
    }
}
