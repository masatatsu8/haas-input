import XCTest
@testable import VoiceInk

final class HaasUsageStatisticsTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        calendar.firstWeekday = 1
        return calendar
    }()

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 12, _ min: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private var now: Date { date(2026, 11, 7, 15) }

    private func sample(_ day: Date, duration: TimeInterval = 10, characters: Int = 10) -> HaasUsageSample {
        HaasUsageSample(timestamp: day, duration: duration, characters: characters)
    }

    private func summary(_ samples: [HaasUsageSample]) -> HaasUsageSummary {
        HaasUsageSummary(samples: samples, now: now, calendar: calendar)
    }

    func testCharacterCountIgnoresWhitespaceAndNewlines() {
        XCTAssertEqual(HaasUsageSample.characterCount("斎藤さんに 資料を\n送ります。"), 13)
        XCTAssertEqual(HaasUsageSample.characterCount(" \n"), 0)
    }

    func testSamplesAreGroupedByLocalDayAcrossMidnight() {
        let result = summary([
            sample(date(2026, 11, 6, 23, 59), duration: 60, characters: 100),
            sample(date(2026, 11, 7, 0, 1), duration: 30, characters: 50),
        ])
        XCTAssertEqual(result.today.characters, 50)
        XCTAssertEqual(result.today.recordings, 1)
        XCTAssertEqual(result.lastSevenDays.count, 7)
        XCTAssertEqual(result.lastSevenDays[5].characters, 100)
        XCTAssertEqual(result.lastSevenDays[6], result.today)
    }

    func testZeroCharacterSamplesAreIgnored() {
        let result = summary([sample(now, duration: 30, characters: 0)])
        XCTAssertEqual(result.usedDays, 0)
        XCTAssertFalse(result.today.isUsed)
        XCTAssertEqual(result.totalDuration, 0)
    }

    func testCurrentStreakSurvivesUntilTodayIsUsed() {
        let threeDays = [date(2026, 11, 4), date(2026, 11, 5), date(2026, 11, 6)].map { sample($0) }
        XCTAssertEqual(summary(threeDays).currentStreak, 3)
        XCTAssertEqual(summary(threeDays + [sample(now)]).currentStreak, 4)
        XCTAssertEqual(summary([sample(date(2026, 11, 4)), sample(date(2026, 11, 6))]).currentStreak, 1)
        XCTAssertEqual(summary([sample(date(2026, 11, 5))]).currentStreak, 0)
    }

    func testLongestStreakSpansWholeHistory() {
        let march = (10...14).map { sample(date(2026, 3, $0)) }
        let november = [sample(date(2026, 11, 6)), sample(now)]
        XCTAssertEqual(summary(march + november).longestStreak, 5)
    }

    func testRecentAverageNeedsThreeUsedDaysExcludingToday() {
        let two = [sample(date(2026, 11, 1), duration: 60), sample(date(2026, 11, 2), duration: 120)]
        XCTAssertNil(summary(two).recentAverageDuration)

        let three = [
            sample(date(2026, 11, 1), duration: 60),
            sample(date(2026, 11, 2), duration: 120),
            sample(date(2026, 11, 3), duration: 180),
            sample(now, duration: 600),
            sample(date(2026, 10, 9), duration: 9000),  // 29日前は対象外
        ]
        XCTAssertEqual(summary(three).recentAverageDuration, 120)
    }

    func testTotalsCountAllSamples() {
        let result = summary([
            sample(date(2026, 3, 1), duration: 10, characters: 5),
            sample(date(2026, 3, 1, 18), duration: 20, characters: 7),
            sample(now, duration: 30, characters: 9),
        ])
        XCTAssertEqual(result.totalDuration, 60)
        XCTAssertEqual(result.totalCharacters, 21)
        XCTAssertEqual(result.usedDays, 2)
    }

    func testGridHas53WeeksEndingWithThisWeek() {
        let result = summary([])
        XCTAssertEqual(result.grid.count, 371)
        XCTAssertEqual(result.grid.last!.day, calendar.startOfDay(for: now))
        XCTAssertEqual(calendar.component(.weekday, from: result.grid.first!.day), 1)
        XCTAssertEqual(calendar.component(.weekday, from: result.grid.last!.day), 7)
    }

    func testGridEndsAtWeekEndAndFutureDaysAreUnused() {
        let wednesday = date(2026, 11, 4, 9)
        let result = HaasUsageSummary(samples: [sample(wednesday)], now: wednesday, calendar: calendar)
        XCTAssertEqual(result.grid.count, 371)
        XCTAssertEqual(result.grid.last!.day, calendar.startOfDay(for: date(2026, 11, 7)))
        XCTAssertTrue(result.grid[result.grid.count - 4].isUsed)
        XCTAssertFalse(result.grid.last!.isUsed)
    }

    func testFutureSampleDoesNotMarkGridDaysAfterTodayOrCountAsToday() {
        let wednesday = date(2026, 11, 4, 9)
        let thursday = date(2026, 11, 5, 9)
        let result = HaasUsageSummary(samples: [sample(thursday)], now: wednesday, calendar: calendar)
        let todayKey = calendar.startOfDay(for: wednesday)
        XCTAssertFalse(result.today.isUsed)
        XCTAssertEqual(result.today.characters, 0)
        XCTAssertTrue(result.grid.filter { $0.day > todayKey }.allSatisfy { !$0.isUsed })
    }

    func testLevelsUseQuartilesOfUsedDays() {
        // 今日から7日前までの8日分 (古い日から 10, 20, ... 80 字)
        let samples = (0..<8).map { sample(date(2026, 10, 31 + $0), characters: ($0 + 1) * 10) }
        let result = summary(samples)
        func level(_ n: Int) -> Int {
            result.level(for: result.grid[result.grid.count - 1 - (8 - n)])
        }
        XCTAssertEqual(level(1), 1)
        XCTAssertEqual(level(8), 4)
        XCTAssertEqual(result.level(for: result.grid[0]), 0)

        let single = summary([sample(now, characters: 5)])
        XCTAssertEqual(single.level(for: single.today), 4)
    }

    func testDayStepsStayAtMidnightWhenDSTStartsAtMidnight() {
        var santiago = calendar
        santiago.timeZone = TimeZone(identifier: "America/Santiago")!
        func at(_ d: Int, _ h: Int) -> Date {
            santiago.date(from: DateComponents(year: 2026, month: 9, day: d, hour: h))!
        }
        let samples = (3...6).map { sample(at($0, 12)) }
        let result = HaasUsageSummary(samples: samples, now: at(6, 15), calendar: santiago)
        XCTAssertEqual(result.currentStreak, 4)
        XCTAssertEqual(result.lastSevenDays.map(\.isUsed), [false, false, false, true, true, true, true])
    }

    func testEmptySamplesProduceEmptySummary() {
        let result = summary([])
        XCTAssertEqual(result.usedDays, 0)
        XCTAssertEqual(result.currentStreak, 0)
        XCTAssertEqual(result.longestStreak, 0)
        XCTAssertNil(result.recentAverageDuration)
        XCTAssertEqual(result.grid.count, 371)
        XCTAssertTrue(result.grid.allSatisfy { !$0.isUsed && result.level(for: $0) == 0 })
    }

    func testDestinationOrderPlacesUsageAfterHome() {
        XCTAssertEqual(HaasDestination.allCases.map(\.rawValue), ["home", "usage", "history", "dictionary", "settings"])
        XCTAssertEqual(HaasDestination.usage.title, "記録")
    }

    func testRecordingCountsTotalAndWithinGrid() {
        let result = summary([
            sample(date(2026, 11, 7)), sample(date(2026, 11, 7, 18)), sample(date(2026, 11, 1)),
            sample(date(2024, 1, 5)),
        ])
        XCTAssertEqual(result.totalRecordings, 4)
        XCTAssertEqual(result.gridRecordings, 3)
    }

    func testGridRecordingsIgnoreFutureSamples() {
        let result = summary([sample(date(2026, 11, 7)), sample(date(2026, 11, 9))])
        XCTAssertEqual(result.gridRecordings, 1)
    }
}
