import AppKit
import SwiftUI

/// 利用状況を見る「記録」画面。数字は端末内の記録だけから作る。
@MainActor
struct HaasUsageView: View {
    @ObservedObject private var recorder: HaasUsageRecorder
    @AppStorage("usageDashboardPanel") private var panel = "today"

    init(recorder: HaasUsageRecorder) {
        self.recorder = recorder
    }

    var body: some View {
        // 開いたまま0時をまたいでも「今日」が切り替わるよう、毎分作り直す
        TimelineView(.everyMinute) { context in
            content(HaasUsageSummary(samples: recorder.samples, now: context.date, calendar: .current))
        }
    }

    private func content(_ summary: HaasUsageSummary) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("記録").font(.largeTitle.bold())
                    Spacer()
                    Picker("記録", selection: $panel) {
                        Text("今日").tag("today")
                        Text("いつもと比べる").tag("comparison")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }

                Group {
                    if panel == "comparison" { comparisonPanel(summary) } else { todayPanel(summary) }
                }
                .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    sectionLabel("この1年")
                    UsageGrass(summary: summary)
                    if summary.usedDays == 0 {
                        Text(HaasUsageWording.emptyHistory).font(.callout).foregroundStyle(.secondary)
                    }
                }

                HStack(alignment: .top, spacing: 10) {
                    UsageTile(title: "話した時間", value: HaasUsageWording.duration(summary.totalDuration),
                              note: HaasUsageWording.durationEquivalent(summary.totalDuration))
                    UsageTile(title: "入力した文字", value: HaasUsageWording.characters(summary.totalCharacters),
                              note: HaasUsageWording.characterEquivalent(summary.totalCharacters))
                    UsageTile(title: "使った日", value: "\(summary.usedDays)日",
                              note: summary.longestStreak > 0 ? "最長 \(summary.longestStreak)日連続" : nil)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            .padding(26)
            .frame(maxWidth: 800)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 今日

    private func todayPanel(_ summary: HaasUsageSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("今日")
            todayAmount(summary)
            if let detail = HaasUsageWording.todayDetail(summary) {
                Text(detail).font(.callout).foregroundStyle(.secondary)
            }
            if let streak = HaasUsageWording.streak(summary) {
                Text(streak)
                    .font(.callout)
                    .foregroundStyle(UsagePalette.cheerText)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(UsagePalette.cheerBackground, in: RoundedRectangle(cornerRadius: 8))
                    .padding(.top, 4)
            }
        }
    }

    /// 今日の量。まだ使っていない日は 0 を大きく出さず、誘いの文言にする。
    @ViewBuilder
    private func todayAmount(_ summary: HaasUsageSummary) -> some View {
        if summary.today.isUsed {
            Text(HaasUsageWording.duration(summary.today.duration) + " ・ "
                + HaasUsageWording.characters(summary.today.characters))
                .font(.system(size: 30, weight: .bold))
        } else {
            Text(HaasUsageWording.notUsedToday).font(.title2.bold())
        }
    }

    // MARK: - いつもと比べる

    private func comparisonPanel(_ summary: HaasUsageSummary) -> some View {
        let comparison = HaasUsageWording.comparison(summary)
        return VStack(alignment: .leading, spacing: 12) {
            if let average = summary.recentAverageDuration, average > 0 {
                HStack(spacing: 16) {
                    UsageRing(ratio: HaasUsageWording.comparisonRatio(summary),
                              center: HaasUsageWording.duration(summary.today.duration))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(comparison.headline).font(.title3.bold())
                        Text(comparison.detail).font(.callout).foregroundStyle(.secondary)
                    }
                }
            } else {
                // 平均が出せるまではリングを出さない
                VStack(alignment: .leading, spacing: 4) {
                    todayAmount(summary)
                    Text(comparison.headline).font(.title3.bold()).padding(.top, 4)
                    Text(comparison.detail).font(.callout).foregroundStyle(.secondary)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                sectionLabel("この1週間")
                UsageWeekBars(days: summary.lastSevenDays)
            }
        }
    }

    private func sectionLabel(_ text: String) -> some View {
        Text(text).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
    }
}

// MARK: - 部品

/// 色は緑の濃淡と、今日を示すオレンジだけ。ライト/ダークで見え方をそろえる。
private enum UsagePalette {
    static let empty = Color.secondary.opacity(0.15)
    static let today = Color.orange
    static let ring = Color.green
    static let bar = adaptive(light: 0x7BC96F, dark: 0x26A641)
    static let cheerText = adaptive(light: 0x1D6B3A, dark: 0x7EE2A0)
    static let cheerBackground = Color.green.opacity(0.15)
    /// 草の濃さ 1〜4
    static let grass = [
        adaptive(light: 0xC6E48B, dark: 0x0E4429),
        adaptive(light: 0x7BC96F, dark: 0x006D32),
        adaptive(light: 0x239A3B, dark: 0x26A641),
        adaptive(light: 0x196127, dark: 0x39D353),
    ]

    static func grass(level: Int) -> Color {
        level <= 0 ? empty : grass[min(level, grass.count) - 1]
    }

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            rgb(appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light)
        })
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

private enum UsageDateText {
    private static let japanese: Calendar = {
        var calendar = Calendar.current
        calendar.locale = Locale(identifier: "ja_JP")
        return calendar
    }()

    /// 「日」「月」… の1文字
    static func weekday(_ date: Date) -> String {
        japanese.veryShortWeekdaySymbols[japanese.component(.weekday, from: date) - 1]
    }

    /// 「11月7日 12分 ・ 2,340文字」。使っていない日は日付だけ。
    static func help(_ day: HaasUsageDay) -> String {
        let date = day.day.formatted(Date.FormatStyle(locale: Locale(identifier: "ja_JP")).month().day())
        guard day.isUsed else { return date }
        return "\(date) \(HaasUsageWording.duration(day.duration)) ・ \(HaasUsageWording.characters(day.characters))"
    }
}

/// 1年分の草。週ごとの列に並べ、幅に合わせて升目の大きさを変える。
private struct UsageGrass: View {
    let summary: HaasUsageSummary
    private let spacing: CGFloat = 3

    var body: some View {
        let weeks = stride(from: 0, to: summary.grid.count, by: 7).map { Array(summary.grid[$0..<min($0 + 7, summary.grid.count)]) }
        HStack(alignment: .top, spacing: spacing) {
            ForEach(weeks.indices, id: \.self) { index in
                VStack(spacing: spacing) {
                    ForEach(weeks[index], id: \.day) { day in cell(day) }
                }
            }
        }
        .frame(maxWidth: CGFloat(weeks.count) * (12 + spacing), alignment: .leading)
    }

    @ViewBuilder
    private func cell(_ day: HaasUsageDay) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2)
        if day.day > summary.today.day {
            Color.clear.aspectRatio(1, contentMode: .fit)
        } else {
            shape
                .fill(UsagePalette.grass(level: summary.level(for: day)))
                .aspectRatio(1, contentMode: .fit)
                .overlay {
                    if day.day == summary.today.day {
                        shape.stroke(UsagePalette.today, lineWidth: 2).padding(-1.5)
                    }
                }
                .help(UsageDateText.help(day))
        }
    }
}

/// 今日と平均を比べる緑のリング。
private struct UsageRing: View {
    let ratio: Double
    let center: String

    var body: some View {
        ZStack {
            Circle().stroke(UsagePalette.empty, lineWidth: 11)
            if ratio > 0 {
                Circle()
                    .trim(from: 0, to: ratio)
                    .stroke(UsagePalette.ring, style: StrokeStyle(lineWidth: 11, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 1) {
                Text(center).font(.headline)
                Text("今日").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(width: 92, height: 92)
    }
}

/// この1週間の話した時間。今日はオレンジ、ほかは緑。
private struct UsageWeekBars: View {
    let days: [HaasUsageDay]
    private let height: CGFloat = 60

    var body: some View {
        let longest = days.map(\.duration).max() ?? 0
        VStack(spacing: 4) {
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(days.indices, id: \.self) { index in
                    let day = days[index]
                    let isToday = index == days.count - 1
                    UnevenRoundedRectangle(topLeadingRadius: 3, topTrailingRadius: 3)
                        .fill(day.duration > 0 ? (isToday ? UsagePalette.today : UsagePalette.bar) : UsagePalette.empty)
                        .frame(height: longest > 0 && day.duration > 0 ? max(3, height * day.duration / longest) : 3)
                        .frame(maxWidth: .infinity)
                        .help(UsageDateText.help(day))
                }
            }
            .frame(height: height, alignment: .bottom)
            HStack(spacing: 6) {
                ForEach(days.indices, id: \.self) { index in
                    Text(index == days.count - 1 ? "今日" : UsageDateText.weekday(days[index].day))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
}

/// 合計のタイル。
private struct UsageTile: View {
    let title: String
    let value: String
    let note: String?

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(value).font(.title3.bold())
                if let note {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(4)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}
