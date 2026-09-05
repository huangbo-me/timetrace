import Charts
import SwiftUI

struct InsightsView: View {
    @EnvironmentObject private var store: InsightsFeatureStore
    @State private var range = InsightRange.thisWeek
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var trendMetric = TrendMetric.workDuration

    private var model: AppModel { store.application }

    var body: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("统计").font(.largeTitle.weight(.bold))
                    Text(rangeDescription).font(.subheadline).foregroundStyle(TimeTraceDesign.muted)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 9) {
                        ForEach(InsightRange.allCases) { value in
                            Button {
                                withAnimation(.easeInOut(duration: 0.18)) { range = value }
                            } label: {
                                Text(value.title)
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(range == value ? .white : TimeTraceDesign.ink)
                                    .lineLimit(1)
                                    .padding(.horizontal, 15)
                                    .padding(.vertical, 10)
                                    .background(
                                        range == value ? TimeTraceDesign.violet : TimeTraceDesign.card,
                                        in: Capsule()
                                    )
                                    .overlay {
                                        Capsule().stroke(
                                            range == value ? .clear : TimeTraceDesign.border,
                                            lineWidth: 1
                                        )
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 1)
                }

                if range == .custom {
                    TTCard {
                        VStack(spacing: 10) {
                            DatePicker("开始日期", selection: $customStart, in: ...customEnd, displayedComponents: .date)
                            DatePicker("结束日期", selection: $customEnd, in: customStart..., displayedComponents: .date)
                        }
                    }
                }

                if let summary {
                    overview(summary)
                    placeBreakdown
                    TTSectionTitle(title: "趋势")
                    TTCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Picker("趋势指标", selection: $trendMetric) {
                                ForEach(TrendMetric.allCases) { metric in Text(metric.title).tag(metric) }
                            }
                            .pickerStyle(.segmented)
                            if summary.days.isEmpty {
                                ContentUnavailableView("暂无趋势数据", systemImage: "chart.xyaxis.line").frame(height: 190)
                            } else {
                                WorkTrendChart(summary: summary, metric: trendMetric, calendar: workCalendar)
                                    .frame(height: 230)
                                if summary.days.contains(where: \.isIncomplete) {
                                    Label("橙色数据点表示记录不完整", systemImage: "circle.fill")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                    }

                    TTSectionTitle(title: "工作节奏")
                    TTCard {
                        VStack(spacing: 14) {
                            detailRow("平均到达", TimeTraceFormat.clockOffset(summary.averageArrivalOffset), icon: "sunrise.fill", tint: .orange)
                            Divider()
                            detailRow("平均离开", TimeTraceFormat.clockOffset(summary.averageDepartureOffset), icon: "sunset.fill", tint: TimeTraceDesign.violet)
                            if let day = summary.longestWorkDay {
                                Divider()
                                detailRow("最长工作日", TimeTraceFormat.duration(day.totalDuration), icon: "sparkles", tint: TimeTraceDesign.blue)
                            }
                        }
                    }
                } else {
                    ContentUnavailableView("暂无统计数据", systemImage: "chart.bar").frame(minHeight: 350)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 28)
        }
        .timeTraceScreen()
        .toolbar(.hidden, for: .navigationBar)
    }

    private func overview(_ summary: PeriodActivitySummary) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                statTiles(summary)
            }
            VStack(spacing: 12) {
                statTiles(summary)
            }
        }
    }

    @ViewBuilder private func statTiles(_ summary: PeriodActivitySummary) -> some View {
        StatTile(title: "本期工作时长", value: TimeTraceFormat.duration(summary.totalWorkDuration), icon: "clock.fill", tint: TimeTraceDesign.blue)
            .frame(minWidth: 164)
        StatTile(title: "平均每天", value: summary.averageWorkDuration.map(TimeTraceFormat.duration) ?? "—", icon: "calendar", tint: TimeTraceDesign.violet)
            .frame(minWidth: 164)
    }

    private func detailRow(_ title: String, _ value: String, icon: String, tint: Color) -> some View {
        HStack {
            TTIcon(systemName: icon, tint: tint, size: 34)
            Text(title).font(.subheadline).foregroundStyle(TimeTraceDesign.muted)
            Spacer()
            Text(value).font(.headline.weight(.bold)).monospacedDigit()
        }
    }

    @ViewBuilder private var placeBreakdown: some View {
        TTSectionTitle(title: "按地点")
        TTCard {
            if placeSummaries.isEmpty {
                ContentUnavailableView("暂无地点统计", systemImage: "mappin.and.ellipse")
            } else {
                VStack(spacing: 12) {
                    ForEach(Array(placeSummaries.enumerated()), id: \.element.id) { index, summary in
                        HStack(spacing: 12) {
                            TTIcon(systemName: "mappin.and.ellipse", tint: TimeTraceDesign.blue, size: 36)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(placeName(for: summary)).font(.subheadline.weight(.semibold))
                                Text("\(summary.sessionCount) 次记录\(summary.incompleteSessionCount > 0 ? " · \(summary.incompleteSessionCount) 次未完成" : "")")
                                    .font(.caption).foregroundStyle(TimeTraceDesign.muted)
                            }
                            Spacer()
                            Text(TimeTraceFormat.duration(summary.totalDuration))
                                .font(.subheadline.weight(.bold)).monospacedDigit()
                        }
                        if index < placeSummaries.count - 1 { Divider() }
                    }
                }
            }
        }
    }

    private var placeSummaries: [PlaceActivitySummary] {
        model.placeSummaries(interval: intervals.current)
    }

    private func placeName(for summary: PlaceActivitySummary) -> String {
        guard let triggerId = summary.placeTriggerId else { return "未标记地点" }
        return model.workTriggers.first { $0.id == triggerId }?.displayPlaceName ?? "已删除地点"
    }

    private var summary: PeriodActivitySummary? {
        model.periodSummary(interval: intervals.current, previous: intervals.previous)
    }

    private var workCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = TimeTraceLocalization.locale
        calendar.timeZone = TimeZone(identifier: model.workTrigger?.timeZoneIdentifier ?? "") ?? .current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }

    private var intervals: (current: DateInterval, previous: DateInterval) {
        let current = range.interval(
            calendar: workCalendar,
            now: Date(),
            customStart: customStart,
            customEnd: customEnd
        )
        let dayCount = max(
            1,
            workCalendar.dateComponents([.day], from: current.start, to: current.end).day ?? 1
        )
        let previousStart = workCalendar.date(
            byAdding: .day,
            value: -dayCount,
            to: current.start
        ) ?? current.start.addingTimeInterval(-Double(dayCount) * 86_400)
        return (current, DateInterval(start: previousStart, end: current.start))
    }

    private var rangeDescription: String {
        let formatter = DateFormatter()
        formatter.locale = TimeTraceLocalization.locale
        formatter.timeZone = workCalendar.timeZone
        formatter.dateFormat = "yyyy年M月d日"
        let lastDay = workCalendar.date(byAdding: .day, value: -1, to: intervals.current.end)
            ?? intervals.current.end
        return "\(formatter.string(from: intervals.current.start)) – \(formatter.string(from: lastDay)) · 横轴按天"
    }

}

private struct StatTile: View {
    let title: String
    let value: String
    let icon: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TTIcon(systemName: icon, tint: tint)
            Text(title).font(.caption).foregroundStyle(TimeTraceDesign.muted)
            Text(value).font(.title3.weight(.bold)).lineLimit(2).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .padding(15)
        .background(TimeTraceDesign.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(tint.opacity(0.13), lineWidth: 1) }
    }
}

private enum InsightRange: String, CaseIterable, Identifiable {
    case recentThreeDays
    case thisWeek
    case previousWeek
    case recentMonth
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .recentThreeDays: "近三天"
        case .thisWeek: "本周"
        case .previousWeek: "上一周"
        case .recentMonth: "最近一个月"
        case .custom: "自定义时间"
        }
    }

    func interval(calendar: Calendar, now: Date, customStart: Date, customEnd: Date) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        switch self {
        case .recentThreeDays:
            let start = calendar.date(byAdding: .day, value: -2, to: today) ?? today
            return DateInterval(start: start, end: tomorrow)
        case .thisWeek:
            return calendar.dateInterval(of: .weekOfYear, for: now)
                ?? DateInterval(start: today, end: tomorrow)
        case .previousWeek:
            let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)
                ?? DateInterval(start: today, end: tomorrow)
            let start = calendar.date(byAdding: .day, value: -7, to: thisWeek.start)
                ?? thisWeek.start.addingTimeInterval(-7 * 86_400)
            return DateInterval(start: start, end: thisWeek.start)
        case .recentMonth:
            let start = calendar.date(byAdding: .day, value: -29, to: today) ?? today
            return DateInterval(start: start, end: tomorrow)
        case .custom:
            let start = calendar.startOfDay(for: min(customStart, customEnd))
            let lastDay = calendar.startOfDay(for: max(customStart, customEnd))
            let end = calendar.date(byAdding: .day, value: 1, to: lastDay) ?? tomorrow
            return DateInterval(start: start, end: end)
        }
    }
}

private enum TrendMetric: String, CaseIterable, Identifiable {
    case workDuration
    case arrival
    case departure

    var id: Self { self }

    var title: String {
        switch self {
        case .workDuration: "时长"
        case .arrival: "到达"
        case .departure: "离开"
        }
    }

    var systemImage: String {
        switch self {
        case .workDuration: "clock"
        case .arrival: "arrow.right.circle"
        case .departure: "arrow.left.circle"
        }
    }

    var color: Color {
        switch self {
        case .workDuration: TimeTraceDesign.blue
        case .arrival: Color(red: 0.34, green: 0.45, blue: 0.30)
        case .departure: TimeTraceDesign.violet
        }
    }

    func value(for day: DailyActivitySummary) -> Double? {
        switch self {
        case .workDuration:
            day.totalDuration / 3_600
        case .arrival:
            day.firstArrivalTime?.timeIntervalSince(day.date).dividedByHours
        case .departure:
            day.lastDepartureTime?.timeIntervalSince(day.date).dividedByHours
        }
    }

    func average(from summary: PeriodActivitySummary) -> Double? {
        switch self {
        case .workDuration: summary.averageWorkDuration?.dividedByHours
        case .arrival: summary.averageArrivalOffset?.dividedByHours
        case .departure: summary.averageDepartureOffset?.dividedByHours
        }
    }

    func formatted(_ value: Double) -> String {
        switch self {
        case .workDuration:
            TimeTraceFormat.duration(value * 3_600)
        case .arrival, .departure:
            TimeTraceFormat.clockOffset(value * 3_600)
        }
    }
}

private struct WorkTrendPoint: Identifiable {
    var id: Date { date }
    let date: Date
    let value: Double
    let isIncomplete: Bool
}

private struct WorkTrendChart: View {
    let summary: PeriodActivitySummary
    let metric: TrendMetric
    let calendar: Calendar

    @State private var selectedDate: Date?

    var body: some View {
        Group {
            if points.isEmpty {
                ContentUnavailableView("暂无\(metric.title)数据", systemImage: "chart.xyaxis.line")
            } else {
                chart
            }
        }
        .animation(.easeInOut(duration: 0.25), value: metric)
        .onChange(of: metric) { _, _ in selectedDate = nil }
        .accessibilityLabel("\(metric.title)每日趋势图")
    }

    private var chart: some View {
        Chart {
            if metric == .workDuration {
                ForEach(points) { point in
                    AreaMark(
                        x: .value("日期", point.date),
                        y: .value(metric.title, point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [metric.color.opacity(0.28), metric.color.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }

            ForEach(points) { point in
                LineMark(
                    x: .value("日期", point.date),
                    y: .value(metric.title, point.value)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .foregroundStyle(metric.color)

                PointMark(
                    x: .value("日期", point.date),
                    y: .value(metric.title, point.value)
                )
                .symbolSize(point.isIncomplete ? 75 : 45)
                .foregroundStyle(point.isIncomplete ? .orange : metric.color)
            }

            if let average = metric.average(from: summary) {
                RuleMark(y: .value("平均", average))
                    .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                    .foregroundStyle(.secondary)
                    .annotation(
                        position: .top,
                        alignment: .leading,
                        overflowResolution: .init(
                            x: .fit(to: .chart),
                            y: .fit(to: .chart)
                        )
                    ) {
                        Text("平均 \(metric.formatted(average))")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
            }

            if let selectedPoint {
                RuleMark(x: .value("所选日期", selectedPoint.date))
                    .foregroundStyle(.secondary.opacity(0.6))
                    .annotation(
                        position: .top,
                        spacing: 8,
                        overflowResolution: .init(
                            x: .fit(to: .chart),
                            y: .fit(to: .chart)
                        )
                    ) {
                        VStack(spacing: 2) {
                            Text(shortDate(selectedPoint.date))
                            Text(metric.formatted(selectedPoint.value))
                                .fontWeight(.semibold)
                        }
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                    }
            }
        }
        .chartYScale(domain: yDomain)
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisGridLine()
                AxisTick()
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(axisLabel(number))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: axisDates) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5))
                AxisTick()
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(axisDate(date))
                    }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
    }

    private var points: [WorkTrendPoint] {
        daySlots.compactMap { date, day in
            if metric == .workDuration {
                return WorkTrendPoint(
                    date: date,
                    value: day.map { metric.value(for: $0) ?? 0 } ?? 0,
                    isIncomplete: day?.isIncomplete ?? false
                )
            }
            guard let day, let value = metric.value(for: day) else { return nil }
            return WorkTrendPoint(date: date, value: value, isIncomplete: day.isIncomplete)
        }
    }

    private var daySlots: [(Date, DailyActivitySummary?)] {
        let summaries = Dictionary(uniqueKeysWithValues: summary.days.map {
            (calendar.startOfDay(for: $0.date), $0)
        })
        let tomorrow = calendar.date(
            byAdding: .day,
            value: 1,
            to: calendar.startOfDay(for: Date())
        ) ?? summary.end
        let displayEnd = min(summary.end, tomorrow)
        var result: [(Date, DailyActivitySummary?)] = []
        var date = calendar.startOfDay(for: summary.start)
        while date < displayEnd {
            result.append((date, summaries[date]))
            guard let next = calendar.date(byAdding: .day, value: 1, to: date), next > date else { break }
            date = next
        }
        return result
    }

    private var selectedPoint: WorkTrendPoint? {
        guard let selectedDate else { return nil }
        return points.min {
            abs($0.date.timeIntervalSince(selectedDate)) < abs($1.date.timeIntervalSince(selectedDate))
        }
    }

    private var yDomain: ClosedRange<Double> {
        guard let minimum = points.map(\.value).min(),
              let maximum = points.map(\.value).max() else { return 0...1 }
        switch metric {
        case .workDuration:
            return 0...max(8, ceil(maximum + 1))
        case .arrival, .departure:
            let lower = floor(minimum - 1)
            let upper = max(lower + 2, ceil(maximum + 1))
            return lower...upper
        }
    }

    private func axisLabel(_ value: Double) -> String {
        switch metric {
        case .workDuration: "\(Int(value.rounded()))小时"
        case .arrival, .departure: TimeTraceFormat.clockOffset(value * 3_600)
        }
    }

    private func axisDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = TimeTraceLocalization.locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = visibleDayCount <= 8 ? "E" : "M/d"
        return formatter.string(from: date)
    }

    private var visibleDayCount: Int { daySlots.count }

    /// Every day remains in the chart. Only the labels are sampled, keeping both
    /// endpoints visible on a narrow screen.
    private var axisDates: [Date] {
        let dates = daySlots.map(\.0)
        guard dates.count > 7 else { return dates }
        let labelCount = min(5, dates.count)
        let indices = Set((0..<labelCount).map { index in
            Int((Double(index) * Double(dates.count - 1) / Double(labelCount - 1)).rounded())
        })
        return indices.sorted().map { dates[$0] }
    }

    private func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = TimeTraceLocalization.locale
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }
}

private extension TimeInterval {
    var dividedByHours: Double { self / 3_600 }
}
