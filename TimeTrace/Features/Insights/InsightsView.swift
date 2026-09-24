import Charts
import SwiftUI

struct InsightOvertimePresentation {
    let title: String
    let totalOvertime: TimeInterval?

    init?(type: PlaceType?, range: InsightRange, breakdowns: [OvertimeBreakdown?]) {
        guard type == .work else { return nil }
        title = switch range {
        case .today: "今日加班时长"
        case .recentThreeDays: "近三天加班时长"
        case .thisWeek: "本周加班时长"
        case .previousWeek: "上周加班时长"
        case .recentMonth: "最近一个月加班时长"
        case .custom: "自定义期间加班时长"
        }
        totalOvertime = breakdowns.allSatisfy { $0 != nil }
            ? breakdowns.compactMap { $0 }.reduce(0) { $0 + $1.totalOvertime }
            : nil
    }

    var value: String {
        totalOvertime.map(TimeTraceFormat.duration) ?? "—"
    }
}

struct InsightsView: View {
    @Environment(\.timeTraceDesign) private var design

    @EnvironmentObject private var store: InsightsFeatureStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var summaryNow = Date()
    @State private var range = InsightRange.thisWeek
    @State private var customStart = Calendar.current.date(byAdding: .day, value: -6, to: Date()) ?? Date()
    @State private var customEnd = Date()
    @State private var trendMetric = TrendMetric.workDuration
    @State private var selectedType: PlaceType?

    @State private var shareSnapshot: InsightShareSnapshot?
    @State private var showingCustomDates = false
    @State private var selectedFinding: JournalFinding?

    private var model: AppModel { store.application }

    var body: some View {
        let journal = store.journal(interval: intervals.current, previous: intervals.previous,
                                    filter: trendPlaceFilter, calendar: workCalendar, now: summaryNow)
        let careInput = InsightSummaryRequest.make(sessions: model.workSessions, places: model.workTriggers,
            calendar: workCalendar, now: summaryNow, additional: [])
        let insight = store.dailySummary.insight(journal: journal, type: selectedType, now: summaryNow)
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 18) {
                DailyCareCard(text: store.dailySummary.tip(for: careInput))
                HStack(spacing: 8) {
                    filterBar
                    if journal.canShare {
                        Button {
                            shareSnapshot = InsightShareSnapshot(journal: journal, copy: insight,
                                overtime: overtimePresentation,
                                trend: JournalTrendSnapshot(summary: trendSummary, metric: trendMetric,
                                    presentation: insightPresentation, calendar: workCalendar, now: summaryNow))
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                                .font(.body.weight(.medium))
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(design.violet)
                        .accessibilityLabel("分享当前总结与趋势")
                    }
                }

                PeriodInsightCard(journal: journal, copy: insight, overtime: overtimePresentation,
                                  selectType: { selectedType = $0 }) {
                    selectedFinding = journal.summaryEvidence ?? journal.mainFinding
                }

                VStack(alignment: .leading, spacing: 8) {
                    if insight != nil, let cutoff = store.dailySummary.dataAsOf {
                        Text("洞见文案 · 截至 \(summaryCutoff(cutoff))")
                            .font(.caption2).foregroundStyle(design.muted)
                    } else if store.dailySummary.isLoading {
                        Label("正在写下今天的手记…", systemImage: "sparkles")
                            .font(.caption2).foregroundStyle(design.muted)
                    } else if let message = store.dailySummary.message {
                        Text(message).font(.caption2).foregroundStyle(design.muted)
                        if store.dailySummary.canRetry {
                            Button("重试智能手记") { loadSummary(retry: true) }
                                .font(.caption.weight(.medium))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 4)

                if let summary {
                    TTSectionTitle(title: trendTitle)
                    TTCard {
                        VStack(alignment: .leading, spacing: 14) {
                            Picker("趋势指标", selection: $trendMetric) {
                                ForEach(TrendMetric.allCases) { metric in
                                    Text(metric.title(for: insightPresentation)).tag(metric)
                                }
                            }
                            .pickerStyle(.segmented)
                            if trendSummary.days.isEmpty {
                                ContentUnavailableView("暂无趋势数据", systemImage: "chart.xyaxis.line").frame(height: 190)
                            } else {
                                PlaceTrendChart(
                                    summary: trendSummary,
                                    metric: trendMetric,
                                    presentation: insightPresentation,
                                    calendar: workCalendar, now: summaryNow
                                )
                                    .frame(height: 230)
                                if trendSummary.days.contains(where: \.isIncomplete) {
                                    Label("橙色数据点表示记录不完整", systemImage: "circle.fill")
                                        .font(.caption).foregroundStyle(.orange)
                                }
                            }
                        }
                    }

                    TTSectionTitle(title: "详细统计")
                    overview(trendPlaceFilter == .all ? summary : trendSummary)
                    TTSectionTitle(title: insightPresentation.summaryTitle)
                    TTCard {
                        VStack(spacing: 14) {
                            ForEach(Array(placeSummaryMetrics.enumerated()), id: \.element.id) { index, metric in
                                detailRow(metric.title, metric.value, icon: metric.icon, tint: metric.tint)
                                if index < placeSummaryMetrics.count - 1 {
                                    Divider()
                                }
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
        .timeTraceTabTitle("统计")
        .task(id: summaryTaskID) { loadSummary() }
        .onChange(of: careInput.recentSourceID) { _, _ in loadSummary() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { summaryNow = Date(); loadSummary() }
        }
        .onReceive(Timer.publish(every: 60, on: .main, in: .common).autoconnect()) { date in
            guard scenePhase == .active else { return }
            summaryNow = date
        }
        .sheet(item: $shareSnapshot) { snapshot in
            JournalSharePreview(journal: snapshot.journal, insightCopy: snapshot.copy,
                                overtime: snapshot.overtime, trend: snapshot.trend)
        }
        .sheet(isPresented: $showingCustomDates) {
            NavigationStack {
                Form {
                    DatePicker("开始日期", selection: $customStart, in: ...customEnd, displayedComponents: .date)
                    DatePicker("结束日期", selection: $customEnd, in: customStart..., displayedComponents: .date)
                }
                .scrollContentBackground(.hidden)
                .timeTraceScreen()
                .navigationTitle("自定义时间")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成") { range = .custom; showingCustomDates = false }
                    }
                }
            }
            .presentationDetents([.medium])
        }
        .sheet(item: $selectedFinding) { finding in JournalFindingDetail(finding: finding, calendar: workCalendar) }
    }

    private var summaryTaskID: String {
        "\(InsightSummaryRequest.dateString(summaryNow, calendar: workCalendar))-\(model.isLoaded)-\(model.isOnboarded)-\(model.isRestoringICloudData)-\(model.needsInitialCloudRestoreDecision)-\(store.dailySummary.identityRevision)-\(store.dailySummary.isLoading)-\(workCalendar.timeZone.identifier)"
    }

    private func loadSummary(retry: Bool = false) {
        guard scenePhase == .active else { return }
        let additional = range.summaryRanges(calendar: workCalendar, now: summaryNow,
            customStart: customStart, customEnd: customEnd)
        store.loadDailySummary(calendar: workCalendar, now: summaryNow, additional: additional, retry: retry)
    }

    private func summaryCutoff(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = TimeTraceLocalization.locale
        formatter.timeZone = workCalendar.timeZone
        formatter.dateFormat = "M月d日 HH:mm"
        return formatter.string(from: date)
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
        let average = insightPresentation.averageBySession
            ? averageSessionDuration(in: summary)
            : summary.averageWorkDuration
        StatTile(title: insightPresentation.periodTotalTitle, value: TimeTraceFormat.duration(summary.totalWorkDuration), icon: "clock.fill", tint: design.blue)
            .frame(minWidth: 164)
        StatTile(title: insightPresentation.averageTitle, value: average.map(TimeTraceFormat.duration) ?? "—", icon: "calendar", tint: design.violet)
            .frame(minWidth: 164)
    }

    private func detailRow(_ title: String, _ value: String, icon: String, tint: Color) -> some View {
        HStack {
            TTIcon(systemName: icon, tint: tint, size: 34)
            Text(title).font(.subheadline).foregroundStyle(design.muted)
            Spacer()
            Text(value).font(.headline.weight(.bold)).monospacedDigit()
        }
    }

    private var filterBar: some View {
        HStack(spacing: 0) {
            Menu {
                ForEach(InsightRange.allCases) { value in
                    Button {
                        if value == .custom { showingCustomDates = true }
                        else { range = value }
                    } label: {
                        if range == value { Label(value.title, systemImage: "checkmark") }
                        else { Text(value.title) }
                    }
                }
            } label: {
                filterLabel(range == .custom ? "自定义" : range.title, icon: "calendar")
            }
            .accessibilityLabel("时间范围：\(range.title)")
            .accessibilityIdentifier("insights-range-filter")

            Rectangle().fill(design.border).frame(width: 1, height: 18)

            Menu {
                Picker("地点类型", selection: $selectedType) {
                    Label("全部类型", systemImage: "square.grid.2x2").tag(nil as PlaceType?)
                    ForEach(PlaceType.allCases) { type in
                        Label(type.displayName, systemImage: type.systemImage).tag(Optional(type))
                    }
                }
            } label: {
                filterLabel(selectedType?.displayName ?? "全部类型",
                            icon: selectedType?.systemImage ?? "square.grid.2x2")
            }
            .accessibilityLabel("地点类型：\(selectedType?.displayName ?? "全部类型")")
            .accessibilityIdentifier("insights-type-filter")
        }
        .buttonStyle(.plain)
        .background(design.card, in: RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(design.border) }
    }

    private func filterLabel(_ title: String, icon: String) -> some View {
        HStack(spacing: 6) {
            ViewThatFits(in: .horizontal) {
                Label(title, systemImage: icon)
                Text(title)
            }
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
                .foregroundStyle(design.muted)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(design.ink)
        .frame(maxWidth: .infinity, minHeight: 44)
        .padding(.horizontal, 10)
        .contentShape(Rectangle())
    }

    private var trendPlaceFilter: PlaceSessionFilter {
        guard let selectedType else { return .all }
        return .forType(selectedType, places: model.workTriggers)
    }

    private var summary: PeriodActivitySummary? {
        model.periodSummary(interval: intervals.current, previous: intervals.previous)
    }

    private var trendSummary: PeriodActivitySummary {
        model.periodSummary(
            interval: intervals.current,
            previous: intervals.previous,
            placeFilter: trendPlaceFilter
        ) ?? emptySummary
    }

    private var trendTitle: String {
        selectedType.map { "趋势 · \($0.displayName)" } ?? "趋势"
    }

    private var insightPresentation: PlaceInsightPresentation {
        PlaceInsightPresentation(type: selectedType)
    }

    private var overtimePresentation: InsightOvertimePresentation? {
        let completedSessions = trendSummary.days.flatMap(\.sessions).filter { $0.duration != nil }
        return InsightOvertimePresentation(
            type: selectedType,
            range: range,
            breakdowns: completedSessions.map { model.overtimeBreakdown(for: $0, now: summaryNow) }
        )
    }

    private var placeSummaryMetrics: [PlaceSummaryMetric] {
        let sessions = trendSummary.days.flatMap(\.sessions)
        let completedSessions = sessions.filter { $0.duration != nil }
        let averageStay = completedSessions.isEmpty
            ? nil
            : completedSessions.compactMap(\.duration).reduce(0, +) / Double(completedSessions.count)
        let longestStay = completedSessions.compactMap(\.duration).max()
        let recentVisit = sessions.map(\.startAt).max()

        switch insightPresentation.type {
        case .work:
            return [
                .init("平均到达", TimeTraceFormat.clockOffset(trendSummary.averageArrivalOffset), "sunrise.fill", .orange),
                .init("平均离开", TimeTraceFormat.clockOffset(trendSummary.averageDepartureOffset), "sunset.fill", design.violet),
                .init("最长工作日", trendSummary.longestWorkDay.map { TimeTraceFormat.duration($0.totalDuration) } ?? "—", "sparkles", design.blue)
            ]
        case .study:
            return [
                .init("学习天数", "\(trendSummary.days.count) 天", "calendar", design.violet),
                .init("平均学习时长", trendSummary.averageWorkDuration.map(TimeTraceFormat.duration) ?? "—", "book.closed.fill", design.blue),
                .init("最长学习日", trendSummary.longestWorkDay.map { TimeTraceFormat.duration($0.totalDuration) } ?? "—", "sparkles", .orange)
            ]
        case .exercise:
            return [
                .init("运动次数", "\(sessions.count) 次", "figure.run", .orange),
                .init("平均锻炼时长", averageStay.map(TimeTraceFormat.duration) ?? "—", "timer", design.violet),
                .init("最长锻炼", longestStay.map(TimeTraceFormat.duration) ?? "—", "trophy.fill", design.blue)
            ]
        case .home:
            return [
                .init("到访天数", "\(trendSummary.days.count) 天", "house.fill", design.violet),
                .init("平均停留", averageStay.map(TimeTraceFormat.duration) ?? "—", "timer", design.blue),
                .init("最长停留", longestStay.map(TimeTraceFormat.duration) ?? "—", "moon.stars.fill", .orange)
            ]
        case .dining:
            return [
                .init("用餐次数", "\(sessions.count) 次", "fork.knife", .orange),
                .init("平均用餐时长", averageStay.map(TimeTraceFormat.duration) ?? "—", "timer", design.violet),
                .init("常用到店时间", TimeTraceFormat.clockOffset(trendSummary.averageArrivalOffset), "clock.fill", design.blue)
            ]
        case .shopping:
            return [
                .init("购物次数", "\(sessions.count) 次", "bag.fill", design.violet),
                .init("平均停留", averageStay.map(TimeTraceFormat.duration) ?? "—", "timer", design.blue),
                .init("最长停留", longestStay.map(TimeTraceFormat.duration) ?? "—", "sparkles", .orange)
            ]
        case .healthcare:
            return [
                .init("就诊次数", "\(sessions.count) 次", "cross.case.fill", .red),
                .init("平均就诊时长", averageStay.map(TimeTraceFormat.duration) ?? "—", "timer", design.violet),
                .init("最近就诊", formattedVisitDate(recentVisit), "calendar", design.blue)
            ]
        case .leisure:
            return [
                .init("休闲次数", "\(sessions.count) 次", "gamecontroller.fill", design.violet),
                .init("平均停留", averageStay.map(TimeTraceFormat.duration) ?? "—", "timer", design.blue),
                .init("最长停留", longestStay.map(TimeTraceFormat.duration) ?? "—", "sparkles", .orange)
            ]
        case .other, .none:
            return [
                .init("到访次数", "\(sessions.count) 次", "mappin.and.ellipse", design.violet),
                .init("平均停留", averageStay.map(TimeTraceFormat.duration) ?? "—", "timer", design.blue),
                .init("最长停留", longestStay.map(TimeTraceFormat.duration) ?? "—", "sparkles", .orange)
            ]
        }
    }

    private func formattedVisitDate(_ date: Date?) -> String {
        guard let date else { return "—" }
        let formatter = DateFormatter()
        formatter.locale = TimeTraceLocalization.locale
        formatter.timeZone = workCalendar.timeZone
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    private func averageSessionDuration(in summary: PeriodActivitySummary) -> TimeInterval? {
        let durations = summary.days.flatMap(\.sessions).compactMap(\.duration)
        guard !durations.isEmpty else { return nil }
        return durations.reduce(0, +) / Double(durations.count)
    }

    private var emptySummary: PeriodActivitySummary {
        PeriodActivitySummary(
            start: intervals.current.start,
            end: intervals.current.end,
            workingDays: 0,
            totalWorkDuration: 0,
            averageWorkDuration: nil,
            averageArrivalOffset: nil,
            averageDepartureOffset: nil,
            latestDepartureTime: nil,
            latestDepartureDate: nil,
            earliestArrivalTime: nil,
            longestWorkDay: nil,
            incompleteDays: 0,
            comparison: PeriodComparison(workDurationChange: nil, arrivalTimeChange: nil, departureTimeChange: nil),
            days: []
        )
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
            now: summaryNow,
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


}

private struct StatTile: View {
    @Environment(\.timeTraceDesign) private var design

    let title: String
    let value: String
    let icon: String
    let tint: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TTIcon(systemName: icon, tint: tint)
            Text(title).font(.caption).foregroundStyle(design.muted)
            Text(value).font(.title3.weight(.bold)).lineLimit(2).minimumScaleFactor(0.75)
        }
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .leading)
        .padding(15)
        .timeTraceCardSurface()
    }
}

private struct PlaceSummaryMetric: Identifiable {
    var id: String { title }
    let title: String
    let value: String
    let icon: String
    let tint: Color

    init(_ title: String, _ value: String, _ icon: String, _ tint: Color) {
        self.title = title
        self.value = value
        self.icon = icon
        self.tint = tint
    }
}

struct PlaceInsightPresentation {
    let type: PlaceType?
    let periodTotalTitle: String
    let averageTitle: String
    let averageBySession: Bool
    let summaryTitle: String
    let durationMetricTitle: String
    let arrivalMetricTitle: String
    let departureMetricTitle: String

    init(type: PlaceType?) {
        self.type = type
        switch type {
        case .work:
            periodTotalTitle = "本期工作时长"; averageTitle = "平均每天"; averageBySession = false
            summaryTitle = "工作节奏"; durationMetricTitle = "时长"; arrivalMetricTitle = "到达"; departureMetricTitle = "离开"
        case .study:
            periodTotalTitle = "本期学习时长"; averageTitle = "平均每天"; averageBySession = false
            summaryTitle = "学习概览"; durationMetricTitle = "学习时长"; arrivalMetricTitle = "开始"; departureMetricTitle = "结束"
        case .exercise:
            periodTotalTitle = "本期锻炼时长"; averageTitle = "平均每次"; averageBySession = true
            summaryTitle = "运动习惯"; durationMetricTitle = "锻炼时长"; arrivalMetricTitle = "入馆"; departureMetricTitle = "离馆"
        case .home:
            periodTotalTitle = "本期停留时长"; averageTitle = "平均每次"; averageBySession = true
            summaryTitle = "居住概览"; durationMetricTitle = "停留时长"; arrivalMetricTitle = "到家"; departureMetricTitle = "离家"
        case .dining:
            periodTotalTitle = "本期用餐时长"; averageTitle = "平均每次"; averageBySession = true
            summaryTitle = "用餐概览"; durationMetricTitle = "用餐时长"; arrivalMetricTitle = "到店"; departureMetricTitle = "离店"
        case .shopping:
            periodTotalTitle = "本期购物停留"; averageTitle = "平均每次"; averageBySession = true
            summaryTitle = "购物概览"; durationMetricTitle = "停留时长"; arrivalMetricTitle = "到店"; departureMetricTitle = "离店"
        case .healthcare:
            periodTotalTitle = "本期就诊时长"; averageTitle = "平均每次"; averageBySession = true
            summaryTitle = "就诊概览"; durationMetricTitle = "就诊时长"; arrivalMetricTitle = "到院"; departureMetricTitle = "离院"
        case .leisure:
            periodTotalTitle = "本期休闲时长"; averageTitle = "平均每次"; averageBySession = true
            summaryTitle = "休闲概览"; durationMetricTitle = "停留时长"; arrivalMetricTitle = "到店"; departureMetricTitle = "离店"
        case .other, .none:
            periodTotalTitle = "本期停留时长"; averageTitle = "平均每次"; averageBySession = true
            summaryTitle = "地点概览"; durationMetricTitle = "停留时长"; arrivalMetricTitle = "到达"; departureMetricTitle = "离开"
        }
    }
}

enum InsightRange: String, CaseIterable, Identifiable {
    case today
    case recentThreeDays = "recent_three_days"
    case thisWeek
    case previousWeek = "previous_week"
    case recentMonth = "recent_month"
    case custom

    var id: Self { self }

    var title: String {
        switch self {
        case .today: "今天"
        case .recentThreeDays: "近三天"
        case .thisWeek: "本周"
        case .previousWeek: "上一周"
        case .recentMonth: "最近一个月"
        case .custom: "自定义时间"
        }
    }

    func summaryRanges(calendar: Calendar, now: Date, customStart: Date, customEnd: Date) -> [(String, DateInterval)] {
        let ranges: [InsightRange] = [.recentThreeDays, .recentMonth] + (self == .custom ? [.custom] : [])
        return ranges.compactMap { value in
            let interval = value.interval(calendar: calendar, now: now, customStart: customStart, customEnd: customEnd)
            // The backend accepts only ranges containing today, at most 366 elapsed days.
            // Unsupported ranges still render the local journal.
            let days = Int(interval.duration / 86_400)
            guard interval.start <= now, now < interval.end, (1...366).contains(days) else { return nil }
            return (value.rawValue, interval)
        }
    }

    func interval(calendar: Calendar, now: Date, customStart: Date, customEnd: Date) -> DateInterval {
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today) ?? now
        switch self {
        case .today:
            return DateInterval(start: today, end: tomorrow)
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

enum TrendMetric: String, CaseIterable, Identifiable {
    case workDuration
    case arrival
    case departure

    var id: Self { self }

    func title(for presentation: PlaceInsightPresentation) -> String {
        switch self {
        case .workDuration: presentation.durationMetricTitle
        case .arrival: presentation.arrivalMetricTitle
        case .departure: presentation.departureMetricTitle
        }
    }

    var systemImage: String {
        switch self {
        case .workDuration: "clock"
        case .arrival: "arrow.right.circle"
        case .departure: "arrow.left.circle"
        }
    }

    func color(design: TimeTraceDesign) -> Color {
        switch self {
        case .workDuration: design.blue
        case .arrival: Color(red: 0.34, green: 0.45, blue: 0.30)
        case .departure: design.violet
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

struct PlaceTrendChart: View {
    @Environment(\.timeTraceDesign) private var design
    let summary: PeriodActivitySummary
    let metric: TrendMetric
    let presentation: PlaceInsightPresentation
    let calendar: Calendar
    var now: Date = Date()

    @State private var selectedDate: Date?

    var body: some View {
        Group {
            if points.isEmpty {
                ContentUnavailableView("暂无\(metric.title(for: presentation))数据", systemImage: "chart.xyaxis.line")
            } else {
                chart
            }
        }
        .animation(.easeInOut(duration: 0.25), value: metric)
        .onChange(of: metric) { _, _ in selectedDate = nil }
        .accessibilityLabel("\(metric.title(for: presentation))每日趋势图")
    }

    private var chart: some View {
        Chart {
            if metric == .workDuration {
                ForEach(points) { point in
                    AreaMark(
                        x: .value("日期", point.date),
                        y: .value(metric.title(for: presentation), point.value)
                    )
                    .interpolationMethod(.catmullRom)
                    .foregroundStyle(
                        LinearGradient(
                            colors: [metric.color(design: design).opacity(0.28), metric.color(design: design).opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                }
            }

            ForEach(points) { point in
                LineMark(
                    x: .value("日期", point.date),
                    y: .value(metric.title(for: presentation), point.value)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
                .foregroundStyle(metric.color(design: design))

                PointMark(
                    x: .value("日期", point.date),
                    y: .value(metric.title(for: presentation), point.value)
                )
                .symbolSize(point.isIncomplete ? 75 : 45)
                .foregroundStyle(point.isIncomplete ? .orange : metric.color(design: design))
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
            to: calendar.startOfDay(for: now)
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
