import XCTest
@testable import VoiceInk

final class HaasUsageWordingTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        calendar.firstWeekday = 1
        return calendar
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }

    private var now: Date { date(2026, 11, 7, 15) }

    private func sample(_ day: Date, duration: TimeInterval, characters: Int) -> HaasUsageSample {
        HaasUsageSample(timestamp: day, duration: duration, characters: characters)
    }

    /// 過去3日 (平均 averageSeconds) と、今日の記録 (today があれば) から集計を作る。
    private func summary(
        average: TimeInterval? = 1020,
        today: (duration: TimeInterval, characters: Int)? = nil,
        streakDays: Int = 0
    ) -> HaasUsageSummary {
        var samples: [HaasUsageSample] = []
        if let average {
            for offset in 2...4 {
                samples.append(sample(date(2026, 11, 7 - offset), duration: average, characters: 100))
            }
        }
        if let today {
            samples.append(sample(now, duration: today.duration, characters: today.characters))
        }
        for offset in 1..<max(streakDays, 1) where streakDays >= 2 {
            samples.append(sample(date(2026, 11, 7 - offset), duration: 10, characters: 10))
        }
        return HaasUsageSummary(samples: samples, now: now, calendar: calendar)
    }

    func testDurationFormatting() {
        XCTAssertEqual(HaasUsageWording.duration(0), "0分")
        XCTAssertEqual(HaasUsageWording.duration(30), "1分未満")
        XCTAssertEqual(HaasUsageWording.duration(12 * 60 + 59), "12分")
        XCTAssertEqual(HaasUsageWording.duration(18 * 3600 + 42 * 60), "18時間42分")
        XCTAssertEqual(HaasUsageWording.duration(7200), "2時間")
    }

    func testCharacterFormatting() {
        XCTAssertEqual(HaasUsageWording.characters(2340), "2,340文字")
        XCTAssertEqual(HaasUsageWording.characters(312_000), "31.2万字")
        XCTAssertEqual(HaasUsageWording.characters(100_000), "10万字")
    }

    func testCharacterEquivalentPicksReadableUnit() {
        XCTAssertNil(HaasUsageWording.characterEquivalent(399))
        XCTAssertEqual(HaasUsageWording.characterEquivalent(2340), "原稿用紙 約6枚分")
        XCTAssertEqual(HaasUsageWording.characterEquivalent(312_000), "文庫本 約3冊分")
        XCTAssertEqual(HaasUsageWording.characterEquivalent(25_000), "短編小説 約1編分")
    }

    func testDurationEquivalentAndKeyboard() {
        XCTAssertNil(HaasUsageWording.durationEquivalent(119 * 60))
        XCTAssertEqual(HaasUsageWording.durationEquivalent(18 * 3600 + 42 * 60), "映画 約9本分")
        XCTAssertEqual(HaasUsageWording.keyboardMinutes(2340), 39)
    }

    func testTodayDetail() {
        XCTAssertNil(HaasUsageWording.todayDetail(summary()))
        XCTAssertEqual(
            HaasUsageWording.todayDetail(summary(today: (60, 2340))),
            "原稿用紙 約6枚分。キーボードなら約39分かかる量です"
        )
        XCTAssertEqual(
            HaasUsageWording.todayDetail(summary(today: (10, 180))),
            "キーボードなら約3分かかる量です"
        )
    }

    func testComparisonNeverScoldsBelowAverage() {
        let below = HaasUsageWording.comparison(summary(today: (734, 100)))
        XCTAssertEqual(below.headline, "いつもの71%まで来ました")
        XCTAssertEqual(below.detail, "最近の1日平均は約17分です")

        let above = summary(today: (2000, 100))
        XCTAssertEqual(HaasUsageWording.comparison(above).headline, "いつもを超えました。いい調子です")
        XCTAssertEqual(HaasUsageWording.comparisonRatio(above), 1)

        let noAverage = HaasUsageWording.comparison(summary(average: nil, today: (60, 100)))
        XCTAssertEqual(noAverage.headline, "使い始めの記録を集めています")
        XCTAssertEqual(noAverage.detail, "3日ほど使うと、いつもの量と比べられるようになります")
        XCTAssertEqual(HaasUsageWording.comparisonRatio(summary(average: nil, today: (60, 100))), 0)

        let unused = HaasUsageWording.comparison(summary())
        XCTAssertEqual(unused.headline, HaasUsageWording.notUsedToday)
        XCTAssertEqual(unused.detail, "最近の1日平均は約17分です")

        let samples = [summary(), summary(today: (734, 100)), summary(today: (2000, 100)), summary(average: nil)]
        for item in samples {
            let headline = HaasUsageWording.comparison(item).headline
            for word in ["足りない", "届かない", "途切れ"] {
                XCTAssertFalse(headline.contains(word))
            }
        }
    }

    func testComparisonPercentIsFlooredWithoutFloatErrorAndClamped() {
        // 1%未満でも「0%」とは言わず、1%に収める
        XCTAssertEqual(
            HaasUsageWording.comparison(summary(today: (5, 10))).headline,
            "いつもの1%まで来ました"
        )
        // 570 / 1000 は浮動小数の誤差で56%になりやすい境界
        XCTAssertEqual(
            HaasUsageWording.comparison(summary(average: 1000, today: (570, 10))).headline,
            "いつもの57%まで来ました"
        )
        // 平均に届く直前でも100%とは表示しない
        XCTAssertEqual(
            HaasUsageWording.comparison(summary(average: 1000, today: (995, 10))).headline,
            "いつもの99%まで来ました"
        )
    }

    func testStreakMessageOnlyFromTwoDays() {
        XCTAssertNil(HaasUsageWording.streak(summary(today: (10, 10))))
        XCTAssertEqual(
            HaasUsageWording.streak(summary(today: (10, 10), streakDays: 7)),
            "🔥 7日連続で使っています"
        )
    }

    private func day(_ d: Date, duration: TimeInterval = 720, characters: Int = 2340, recordings: Int = 8) -> HaasUsageDay {
        HaasUsageDay(day: d, duration: duration, characters: characters, recordings: recordings)
    }

    func testRecordingCountUsesGrouping() {
        XCTAssertEqual(HaasUsageWording.recordings(8), "8回")
        XCTAssertEqual(HaasUsageWording.recordings(1_234), "1,234回")
    }

    func testTodayAmountIncludesRecordingCount() {
        XCTAssertEqual(HaasUsageWording.todayAmount(day(now)), "12分 ・ 2,340文字 ・ 8回")
    }

    func testDayHelpShowsRecordingCountOnlyForUsedDays() {
        XCTAssertEqual(HaasUsageWording.dayHelp(date: "11月7日", day: day(now)), "11月7日 12分 ・ 2,340文字 ・ 8回")
        let unused = day(now, duration: 0, characters: 0, recordings: 0)
        XCTAssertEqual(HaasUsageWording.dayHelp(date: "11月7日", day: unused), "11月7日")
    }

    func testYearHeadline() {
        XCTAssertEqual(HaasUsageWording.yearHeadline(recordings: 1_234), "この1年で 1,234回 入力しました")
        XCTAssertEqual(HaasUsageWording.yearHeadline(recordings: 0), "この1年は、まだ入力がありません")
    }

    func testWeekdayLabelsShowOnlyMondayWednesdayFriday() {
        XCTAssertEqual(HaasUsageWording.weekdayLabels(firstWeekday: 1), [nil, "月", nil, "水", nil, "金", nil])
        XCTAssertEqual(HaasUsageWording.weekdayLabels(firstWeekday: 2), ["月", nil, "水", nil, "金", nil, nil])
    }

    private func weekStarts(from start: Date, count: Int) -> [Date] {
        (0..<count).map { calendar.date(byAdding: .day, value: 7 * $0, to: start)! }
    }

    func testMonthMarksPutLabelOnFirstColumnOfEachMonth() {
        // 2026-10-04 (日) から。10/4, 10/11, 10/18, 10/25, 11/1, 11/8 ...
        let marks = HaasUsageWording.monthMarks(weekStarts: weekStarts(from: date(2026, 10, 4), count: 8), calendar: calendar)
        XCTAssertEqual(marks, [
            HaasUsageMonthMark(column: 0, text: "10月"),
            HaasUsageMonthMark(column: 4, text: "11月"),
        ])
    }

    func testMonthMarksCrossYearBoundary() {
        // 12/6, 12/13, 12/20, 12/27, 1/3, 1/10
        let marks = HaasUsageWording.monthMarks(weekStarts: weekStarts(from: date(2025, 12, 6), count: 6), calendar: calendar)
        XCTAssertEqual(marks.map(\.text), ["12月", "1月"])
        XCTAssertEqual(marks.map(\.column), [0, 4])
    }

    func testMonthMarksDropEarlierLabelWhenTooCloseToNext() {
        // 最初の列が10/30で、次の列 (11/6) で月が変わる。隣り合うので先の10月は出さない
        let marks = HaasUsageWording.monthMarks(weekStarts: weekStarts(from: date(2026, 10, 30), count: 4), calendar: calendar)
        XCTAssertEqual(marks, [HaasUsageMonthMark(column: 1, text: "11月")])
    }

    func testMonthMarksKeepLabelsTwoColumnsApart() {
        let marks = HaasUsageWording.monthMarks(weekStarts: weekStarts(from: date(2026, 10, 24), count: 5), calendar: calendar)
        // 10/24, 10/31, 11/7, 11/14, 11/21 : 列2で11月。列0の10月とは2列離れている
        XCTAssertEqual(marks, [
            HaasUsageMonthMark(column: 0, text: "10月"),
            HaasUsageMonthMark(column: 2, text: "11月"),
        ])
    }

    func testMonthMarksEmptyForNoColumns() {
        XCTAssertEqual(HaasUsageWording.monthMarks(weekStarts: [], calendar: calendar), [])
    }

    func testLegendLabels() {
        XCTAssertEqual(HaasUsageWording.legendLess, "少ない")
        XCTAssertEqual(HaasUsageWording.legendMore, "多い")
    }
}
