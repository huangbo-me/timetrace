import SwiftUI

struct HistoryMasonryColumns<Element> {
    let left: [Element]
    let right: [Element]
    let leftWeight: Int
    let rightWeight: Int

    static func distribute(_ elements: [Element], weight: (Element) -> Int) -> Self {
        var left: [Element] = []
        var right: [Element] = []
        var leftWeight = 0
        var rightWeight = 0
        for element in elements {
            let value = max(1, weight(element))
            if leftWeight <= rightWeight {
                left.append(element)
                leftWeight += value
            } else {
                right.append(element)
                rightWeight += value
            }
        }
        return Self(left: left, right: right, leftWeight: leftWeight, rightWeight: rightWeight)
    }
}

struct HistoryOvertimePresentation {
    let normalDuration: TimeInterval
    let totalOvertime: TimeInterval
    let earlyOvertime: TimeInterval
    let lateOvertime: TimeInterval
    let workdayOvertime: TimeInterval
    let restDayOvertime: TimeInterval
    private let hasCompleteBreakdown: Bool

    init(_ sessionBreakdowns: [OvertimeBreakdown?]) {
        let breakdowns = sessionBreakdowns.compactMap { $0 }
        hasCompleteBreakdown = !sessionBreakdowns.isEmpty && breakdowns.count == sessionBreakdowns.count
        normalDuration = breakdowns.reduce(0) { $0 + $1.normalDuration }
        totalOvertime = breakdowns.reduce(0) { $0 + $1.totalOvertime }
        earlyOvertime = breakdowns.reduce(0) { $0 + $1.earlyOvertime }
        lateOvertime = breakdowns.reduce(0) { $0 + $1.lateOvertime }
        workdayOvertime = breakdowns.reduce(0) { $0 + $1.workdayOvertime }
        restDayOvertime = breakdowns.reduce(0) { $0 + $1.restDayOvertime }
    }

    var completeTotals: (normalDuration: TimeInterval, totalOvertime: TimeInterval)? {
        guard hasCompleteBreakdown else { return nil }
        return (normalDuration, totalOvertime)
    }

    var totalOvertimeText: String? {
        guard let total = completeTotals?.totalOvertime, total > 0 else { return nil }
        return "加班 \(TimeTraceFormat.duration(total))"
    }

    var workdayOvertimeText: String? {
        guard workdayOvertime > 0 else { return nil }
        return "工作日加班 \(TimeTraceFormat.duration(workdayOvertime))"
    }
}

struct HistoryView: View {
    @Environment(\.timeTraceDesign) private var design

    @EnvironmentObject private var store: HistoryFeatureStore
    @State private var repairingEvent: ActivityEvent?
    @State private var selectedSummary: DailyActivitySummary?
    @State private var addingSession = false
    @State private var displayedHistoryCount = 12
    @State private var selectedType: HistoryTypeFilter = .all

    private let historyPageSize = 12

    private var model: AppModel { store.application }

    var body: some View {
        // A session belongs to exactly one group: pending completion, active, or
        // closed. Open sessions are therefore not also rendered inside date cards.
        let pendingSessions = sessionsNeedingCompletion
        let activeSessions = activeWorkSessions
        let allSummaries = completedSummaries
        let orphanedEvents = filteredOrphanedEvents
        let origins = originBySessionID
        let overtime = overtimeBySessionID
        let daySpans = crossedDaysBySessionID
        let visibleSummaries = Array(allSummaries.prefix(displayedHistoryCount))
        let columns = HistoryMasonryColumns.distribute(visibleSummaries) { summary in
            let crossDayLine = summary.sessions.contains { (daySpans[$0.id] ?? 0) > 0 } ? 1 : 0
            let overtimeLine = summary.sessions.contains { (overtime[$0.id]?.totalOvertime ?? 0) > 0 } ? 1 : 0
            return 4 + summary.sessionCount * 2 + crossDayLine + overtimeLine
        }

        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("过去的每一天都值得回顾").font(.subheadline).foregroundStyle(design.muted)
                    }
                    Spacer()
                    Button { addingSession = true } label: {
                        Image(systemName: "plus").font(.headline.weight(.bold))
                            .frame(width: 44, height: 44)
                    }
                    .buttonStyle(.glass)
                    .buttonBorderShape(.circle)
                    .accessibilityLabel("添加记录")
                }

                typeFilter

                if allSummaries.isEmpty && pendingSessions.isEmpty && activeSessions.isEmpty && orphanedEvents.isEmpty {
                    ContentUnavailableView(
                        selectedType == .all ? "还没有历史记录" : "暂无\(selectedType.title)记录",
                        systemImage: "calendar",
                        description: Text(selectedType == .all ? "记录活动后，可在这里回顾。" : "可以切换其他类型或查看全部记录。")
                    )
                        .frame(maxWidth: .infinity, minHeight: 360)
                }

                let pendingCount = pendingSessions.count + orphanedEvents.count
                if pendingCount > 0 {
                    TTSectionTitle(title: "待补齐（\(pendingCount)）")
                    VStack(spacing: 8) {
                        ForEach(pendingSessions, id: \.id) { session in
                            Button { selectedSummary = singleSessionSummary(session) } label: {
                                HistoryStatusRow(session: session, state: .needsCompletion,
                                                 origin: origins[session.id] ?? .system,
                                                 crossedDays: daySpans[session.id] ?? 0,
                                                 overtime: overtime[session.id])
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("补齐这段时间记录的结束时间")
                        }

                        ForEach(orphanedEvents, id: \.id) { event in
                            Button { repairingEvent = event } label: {
                                HistoryOrphanedExitRow(event: event)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button("忽略这条异常", systemImage: "eye.slash") {
                                    model.dismissOrphanedEvent(event)
                                }
                            }
                        }
                    }

                    if !orphanedEvents.isEmpty {
                        Text("缺少到达记录的异常可直接补录；原始定位事实会保留。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if !activeSessions.isEmpty {
                    TTSectionTitle(title: "进行中（\(activeSessions.count)）")
                    VStack(spacing: 8) {
                        ForEach(activeSessions, id: \.id) { session in
                            Button { selectedSummary = singleSessionSummary(session) } label: {
                                HistoryStatusRow(session: session, state: .active,
                                                 origin: origins[session.id] ?? .system,
                                                 crossedDays: daySpans[session.id] ?? 0,
                                                 overtime: overtime[session.id])
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("查看这段正在记录的活动时间")
                        }
                    }
                }

                if !allSummaries.isEmpty {
                    TTSectionTitle(title: "每日汇总")
                    // Independent columns avoid the large blank area a grid leaves
                    // below a short card when the neighboring card is taller.
                    HStack(alignment: .top, spacing: 8) {
                        LazyVStack(spacing: 8) {
                            ForEach(columns.left) { summary in
                                historyCard(summary, visibleSummaries: visibleSummaries, allSummaries: allSummaries,
                                            origins: origins, overtime: overtime, crossedDays: daySpans)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)

                        LazyVStack(spacing: 8) {
                            ForEach(columns.right) { summary in
                                historyCard(summary, visibleSummaries: visibleSummaries, allSummaries: allSummaries,
                                            origins: origins, overtime: overtime, crossedDays: daySpans)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }

                    Spacer(minLength: 24)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
        }
        .timeTraceScreen()
        .timeTraceTabTitle("历史记录")
        .onChange(of: selectedType) { _, _ in
            displayedHistoryCount = historyPageSize
        }
        .sheet(item: $repairingEvent) { RepairOrphanedExitView(event: $0) }
        .sheet(item: $selectedSummary) { summary in
            HistoryDayDetailView(summary: summary, origins: origins, overtime: overtime,
                                 crossedDays: daySpans, onSaved: { selectedSummary = nil })
        }
        .sheet(isPresented: $addingSession) { AddSessionView() }
    }

    private var typeFilter: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                ForEach(HistoryTypeFilter.options, id: \.self) { filter in
                    Button {
                        selectedType = filter
                    } label: {
                        Text(filter.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(selectedType == filter ? design.onAccent : design.ink)
                            .padding(.horizontal, 15)
                            .padding(.vertical, 10)
                            .background(
                                selectedType == filter ? design.violet : design.card,
                                in: Capsule()
                            )
                            .overlay {
                                Capsule().stroke(selectedType == filter ? .clear : design.border, lineWidth: 1)
                            }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("类型：\(filter.title)")
                    .accessibilityAddTraits(selectedType == filter ? .isSelected : [])
                }
            }
            .padding(.horizontal, 1)
        }
    }

    private var filteredOrphanedEvents: [ActivityEvent] {
        model.orphanedWorkExitEvents.filter { event in
            selectedType.includes(placeType(
                triggerId: UUID(uuidString: event.metadata.values["placeTriggerId"] ?? ""),
                event: event
            ))
        }
    }

    private func matchesType(_ session: ActivitySession) -> Bool {
        selectedType.includes(placeType(
            triggerId: session.placeTriggerId,
            event: model.events.first { $0.id == session.startEventId }
        ))
    }

    private func placeType(triggerId: UUID?, event: ActivityEvent?) -> PlaceType? {
        if let triggerId, let trigger = model.triggers.first(where: { $0.id == triggerId }) {
            return trigger.placeType
        }
        // Preserve classification from the recorded event after a place is deleted.
        return event?.metadata.values["placeType"].flatMap(PlaceType.init(rawValue:))
    }

    private var completedSummaries: [DailyActivitySummary] {
        let calendar = Calendar.current
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        let start = calendar.date(byAdding: .month, value: -6, to: end)!
        // Only closed sessions belong in the daily history grid. This keeps the
        // status panels above mutually exclusive with the cards below.
        return model.dailySummaries(interval: DateInterval(start: start, end: end))
            .compactMap(completedSummary(from:))
            .sorted { $0.date > $1.date }
    }

    private var sessionsNeedingCompletion: [ActivitySession] {
        workSessions
            .filter { matchesType($0) && $0.endAt == nil && $0.status != .active }
            .sorted { $0.startAt > $1.startAt }
    }

    private var activeWorkSessions: [ActivitySession] {
        workSessions
            .filter { matchesType($0) && $0.endAt == nil && $0.status == .active }
            .sorted { $0.startAt > $1.startAt }
    }

    private var workSessions: [ActivitySession] {
        model.workSessions
    }

    private var originBySessionID: [UUID: HistoryRecordOrigin] {
        HistoryRecordOrigin.map(sessions: workSessions, events: model.events)
    }

    private var overtimeBySessionID: [UUID: OvertimeBreakdown] {
        Dictionary(uniqueKeysWithValues: workSessions.compactMap { session in
            model.overtimeBreakdown(for: session).map { (session.id, $0) }
        })
    }

    private var crossedDaysBySessionID: [UUID: Int] {
        Dictionary(uniqueKeysWithValues: workSessions.map { ($0.id, model.crossedDayCount(for: $0)) })
    }

    private func completedSummary(from summary: DailyActivitySummary) -> DailyActivitySummary? {
        let sessions = summary.sessions.filter { $0.endAt != nil && matchesType($0) }
        guard !sessions.isEmpty else { return nil }
        return DailyActivitySummary(
            date: summary.date,
            firstArrivalTime: sessions.map(\.startAt).min(),
            lastDepartureTime: sessions.compactMap(\.endAt).max(),
            totalDuration: sessions.compactMap(\.duration).reduce(0, +),
            sessionCount: sessions.count,
            isIncomplete: false,
            sessions: sessions
        )
    }

    private func singleSessionSummary(_ session: ActivitySession) -> DailyActivitySummary {
        DailyActivitySummary(
            date: Calendar.current.startOfDay(for: session.startAt),
            firstArrivalTime: session.startAt,
            lastDepartureTime: session.endAt,
            totalDuration: session.duration ?? 0,
            sessionCount: 1,
            isIncomplete: session.endAt == nil,
            sessions: [session]
        )
    }

    @ViewBuilder
    private func historyCard(
        _ summary: DailyActivitySummary,
        visibleSummaries: [DailyActivitySummary],
        allSummaries: [DailyActivitySummary],
        origins: [UUID: HistoryRecordOrigin],
        overtime: [UUID: OvertimeBreakdown],
        crossedDays: [UUID: Int]
    ) -> some View {
        Button { selectedSummary = summary } label: {
            HistoryDayCard(
                summary: summary,
                durationTier: durationTier(for: summary.totalDuration),
                origins: origins,
                overtime: overtime,
                crossedDays: crossedDays
            )
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("打开当天筛选后的记录时段")
        .onAppear {
            guard summary.id == visibleSummaries.last?.id,
                  visibleSummaries.count < allSummaries.count else { return }
            displayedHistoryCount = min(
                displayedHistoryCount + historyPageSize,
                allSummaries.count
            )
        }
    }

    private func durationTier(for duration: TimeInterval) -> HistoryDurationTier {
        switch duration {
        case ..<(6 * 60 * 60): .short
        case ..<(9 * 60 * 60): .regular
        default: .long
        }
    }
}

private enum HistoryTypeFilter: Hashable {
    case all
    case type(PlaceType)
    case unclassified

    static var options: [Self] { [.all] + PlaceType.allCases.map { .type($0) } + [.unclassified] }

    var title: String {
        switch self {
        case .all: "全部"
        case .type(let type): type.displayName
        case .unclassified: "未分类"
        }
    }

    func includes(_ type: PlaceType?) -> Bool {
        switch self {
        case .all: true
        case .type(let selected): type == selected
        case .unclassified: type == nil
        }
    }
}

enum HistoryDurationTier {
    case short
    case regular
    case long

    var color: Color {
        switch self {
        case .short: .orange
        case .regular: .teal
        case .long: .indigo
        }
    }

    var label: String {
        switch self {
        case .short: "偏短"
        case .regular: "常规"
        case .long: "较长"
        }
    }
}

private enum HistorySessionState {
    case needsCompletion
    case active

    var title: String {
        switch self {
        case .needsCompletion: "缺少结束记录"
        case .active: "正在记录"
        }
    }

    var action: String {
        switch self {
        case .needsCompletion: "补齐"
        case .active: "进行中"
        }
    }

    var icon: String {
        switch self {
        case .needsCompletion: "exclamationmark.triangle.fill"
        case .active: "record.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .needsCompletion: .orange
        case .active: .green
        }
    }
}

enum HistoryRecordOrigin {
    case system
    case manual
    case backfilled

    static func map(sessions: [ActivitySession], events: [ActivityEvent]) -> [UUID: Self] {
        let eventsByID = Dictionary(events.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let adjustedSessionIDs = Set(events.compactMap { event -> UUID? in
            guard event.eventType == .sessionAdjusted,
                  event.metadata.values["adjustmentKind"] != WorkScheduleSnapshot.adjustmentKind,
                  let sessionID = event.metadata.values["sessionId"] else { return nil }
            return UUID(uuidString: sessionID)
        })
        return Dictionary(uniqueKeysWithValues: sessions.map { session in
            let startEvent = session.startEventId.flatMap { eventsByID[$0] }
            let origin: Self
            // A repaired orphaned exit has a manual start but is a backfill.
            if startEvent?.metadata.values["repairsEventId"] != nil {
                origin = .backfilled
            } else if startEvent?.eventType == .manualStart {
                origin = .manual
            } else if adjustedSessionIDs.contains(session.id) || session.status == .manuallyAdjusted {
                origin = .backfilled
            } else {
                origin = .system
            }
            return (session.id, origin)
        })
    }

    var label: String {
        switch self {
        case .system: "系统记录"
        case .manual: "手工添加"
        case .backfilled: "后补/修正"
        }
    }

    var icon: String {
        switch self {
        case .system: "location.fill"
        case .manual: "hand.tap.fill"
        case .backfilled: "pencil.line"
        }
    }

    func tint(design: TimeTraceDesign) -> Color {
        switch self {
        case .system: design.blue
        case .manual: design.violet
        case .backfilled: .orange
        }
    }
}

private struct HistoryOriginBadge: View {
    @Environment(\.timeTraceDesign) private var design
    let origin: HistoryRecordOrigin

    var body: some View {
        Label(origin.label, systemImage: origin.icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(origin.tint(design: design))
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(origin.tint(design: design).opacity(0.1), in: Capsule())
            .accessibilityLabel("来源：\(origin.label)")
    }
}

/// A full-width status row keeps open records visually distinct from the
/// completed-session cards. Its wording intentionally avoids an artificial
/// `开始 → 进行中` time range: an open record has no end time yet.
private struct HistoryStatusRow: View {
    let session: ActivitySession
    let state: HistorySessionState
    let origin: HistoryRecordOrigin
    let crossedDays: Int
    let overtime: OvertimeBreakdown?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: state.icon)
                .font(.title3)
                .foregroundStyle(state.tint)
                .frame(width: 32, height: 32)
                .background(state.tint.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(state.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                    HistoryOriginBadge(origin: origin)
                }
                Text("开始于 \(TimeTraceFormat.day.string(from: session.startAt)) \(TimeTraceFormat.time.string(from: session.startAt))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if crossedDays > 0 || (overtime?.totalOvertime ?? 0) > 0 {
                    HStack(spacing: 8) {
                        if crossedDays > 0 { Text("跨 \(crossedDays) 天") }
                        if let overtime, overtime.totalOvertime > 0 {
                            Text("加班 \(TimeTraceFormat.duration(overtime.totalOvertime))")
                        }
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(state.tint)
                }
            }

            Spacer(minLength: 8)

            Text(state.action)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(state.tint)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(state.tint.opacity(0.7))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(state.tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(state.tint.opacity(0.22), lineWidth: 1)
        }
    }
}

private struct HistoryOrphanedExitRow: View {
    let event: ActivityEvent

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)
                .frame(width: 32, height: 32)
                .background(.orange.opacity(0.12), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("缺少到达记录")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text("检测到离开：\(TimeTraceFormat.day.string(from: event.timestamp)) \(TimeTraceFormat.time.string(from: event.timestamp))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text("补录")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.orange)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.bold))
                .foregroundStyle(.orange.opacity(0.7))
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.orange.opacity(0.22), lineWidth: 1)
        }
    }
}

struct HistoryDayCard: View {
    @Environment(\.timeTraceDesign) private var design

    let summary: DailyActivitySummary
    let durationTier: HistoryDurationTier
    let origins: [UUID: HistoryRecordOrigin]
    let overtime: [UUID: OvertimeBreakdown]
    let crossedDays: [UUID: Int]

    private var tint: Color { durationTier.color }

    private var maximumCrossedDays: Int {
        summary.sessions.map { crossedDays[$0.id] ?? 0 }.max() ?? 0
    }

    var overtimePresentation: HistoryOvertimePresentation {
        HistoryOvertimePresentation(summary.sessions.map { overtime[$0.id] })
    }

    var body: some View {
        let presentation = overtimePresentation
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                Text(TimeTraceFormat.day.string(from: summary.date))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                if maximumCrossedDays > 0 {
                    Text("跨 \(maximumCrossedDays) 天")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(design.violet)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(design.violet.opacity(0.1), in: Capsule())
                        .accessibilityLabel("跨天记录")
                }

            }

            VStack(alignment: .leading, spacing: 5) {
                Text(TimeTraceFormat.duration(summary.totalDuration))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(tint)
                    .minimumScaleFactor(0.8)

                Text("\(summary.sessionCount) 个记录时段 · \(durationTier.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let totalText = presentation.totalOvertimeText {
                    Text(totalText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(design.violet)
                }
                if let workdayText = presentation.workdayOvertimeText {
                    Text(workdayText)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(design.violet)
                }
            }

            VStack(spacing: 8) {
                ForEach(summary.sessions, id: \.id) { session in
                    HistorySessionItem(
                        session: session,
                        tint: tint,
                        origin: origins[session.id] ?? .system,
                        overtime: overtime[session.id],
                        crossedDays: crossedDays[session.id] ?? 0
                    )
                }
            }

            Divider().opacity(0.55)
            HStack(spacing: 5) {
                Text("查看详情")
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [tint.opacity(0.16), Color(.secondarySystemGroupedBackground)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(tint.opacity(0.2), lineWidth: 1)
        }
        .shadow(color: tint.opacity(0.08), radius: 10, y: 5)
    }
}

private struct HistoryDayDetailView: View {
    @Environment(\.timeTraceDesign) private var design

    @Environment(\.dismiss) private var dismiss
    let summary: DailyActivitySummary
    let origins: [UUID: HistoryRecordOrigin]
    let overtime: [UUID: OvertimeBreakdown]
    let crossedDays: [UUID: Int]
    let onSaved: () -> Void
    @State private var editingSession: ActivitySession?

    var body: some View {
        let presentation = HistoryOvertimePresentation(summary.sessions.map { overtime[$0.id] })
        NavigationStack {
            List {
                Section {
                    LabeledContent("总时长", value: TimeTraceFormat.duration(summary.totalDuration))
                    LabeledContent("记录时段", value: "\(summary.sessionCount) 段")
                    LabeledContent("到达", value: summary.firstArrivalTime.map {
                        TimeTraceFormat.time.string(from: $0)
                    } ?? "—")
                    LabeledContent("离开", value: summary.lastDepartureTime.map {
                        TimeTraceFormat.time.string(from: $0)
                    } ?? "未检测到")
                    if let totals = presentation.completeTotals {
                        LabeledContent("正常工时", value: TimeTraceFormat.duration(totals.normalDuration))
                        LabeledContent("加班总计", value: TimeTraceFormat.duration(totals.totalOvertime))
                        if presentation.earlyOvertime > 0 {
                            LabeledContent("早到加班", value: TimeTraceFormat.duration(presentation.earlyOvertime))
                        }
                        if presentation.lateOvertime > 0 {
                            LabeledContent("晚走加班", value: TimeTraceFormat.duration(presentation.lateOvertime))
                        }
                        if presentation.restDayOvertime > 0 {
                            LabeledContent("休息日加班", value: TimeTraceFormat.duration(presentation.restDayOvertime))
                        }
                    }
                    if presentation.workdayOvertime > 0 {
                        LabeledContent("工作日加班", value: TimeTraceFormat.duration(presentation.workdayOvertime))
                    }
                }

                Section("时段详情") {
                    ForEach(summary.sessions, id: \.id) { session in
                        Button { editingSession = session } label: {
                            HStack(spacing: 10) {
                                HistoryDetailSessionRow(
                                    session: session,
                                    origin: origins[session.id] ?? .system,
                                    overtime: overtime[session.id],
                                    crossedDays: crossedDays[session.id] ?? 0
                                )
                                if session.endAt == nil && session.status != .active {
                                    Text("补齐")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.orange)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(design.muted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("查看并修正这个记录时段")
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .timeTraceScreen()
            .navigationTitle(TimeTraceFormat.day.string(from: summary.date))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editingSession) { session in
                EditSessionView(session: session, onSaved: onSaved)
            }
        }
    }

}

private struct HistoryDetailSessionRow: View {
    let session: ActivitySession
    let origin: HistoryRecordOrigin
    let overtime: OvertimeBreakdown?
    let crossedDays: Int

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                if let endAt = session.endAt {
                    HStack(spacing: 5) {
                        Text(TimeTraceFormat.time.string(from: session.startAt))
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(TimeTraceFormat.time.string(from: endAt))
                    }
                    .font(.subheadline.monospacedDigit())
                } else {
                    Text("开始于 \(TimeTraceFormat.time.string(from: session.startAt))")
                        .font(.subheadline.monospacedDigit())
                }
                HistoryOriginBadge(origin: origin)
                if crossedDays > 0 {
                    Text("跨 \(crossedDays) 天")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                if let overtime {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("正常 \(TimeTraceFormat.duration(overtime.normalDuration)) · 加班 \(TimeTraceFormat.duration(overtime.totalOvertime))")
                        if overtime.earlyOvertime > 0 {
                            Text("早到 \(TimeTraceFormat.duration(overtime.earlyOvertime))")
                        }
                        if overtime.lateOvertime > 0 {
                            Text("晚走 \(TimeTraceFormat.duration(overtime.lateOvertime))")
                        }
                        if let workdayText = HistoryOvertimePresentation([overtime]).workdayOvertimeText {
                            Text(workdayText)
                        }
                        if overtime.restDayOvertime > 0 {
                            Text("休息日 \(TimeTraceFormat.duration(overtime.restDayOvertime))")
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            Text(durationText)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
        }
    }

    private var durationText: String {
        guard let duration = session.duration else {
            return session.status == .active ? "进行中" : "待补齐"
        }
        return TimeTraceFormat.duration(duration)
    }
}

private struct HistorySessionItem: View {
    let session: ActivitySession
    let tint: Color
    let origin: HistoryRecordOrigin
    let overtime: OvertimeBreakdown?
    let crossedDays: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 4) {
                Text(TimeTraceFormat.time.string(from: session.startAt))
                Image(systemName: "arrow.right")
                    .font(.caption2)
                    .foregroundStyle(tint)
                Text(session.endAt.map { TimeTraceFormat.time.string(from: $0) } ?? statusText)
                    .lineLimit(1)
            }
            .font(.subheadline.weight(.medium).monospacedDigit())

            HStack(spacing: 6) {
                Text(durationText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HistoryOriginBadge(origin: origin)
            }
            if crossedDays > 0 || (overtime?.totalOvertime ?? 0) > 0 {
                HStack(spacing: 8) {
                    if crossedDays > 0 { Text("跨 \(crossedDays) 天") }
                    if let overtime, overtime.totalOvertime > 0 {
                        Text("加班 \(TimeTraceFormat.duration(overtime.totalOvertime))")
                    }
                }
                .font(.caption2.weight(.semibold))
                .foregroundStyle(tint)
            }
            if let overtime, let workdayText = HistoryOvertimePresentation([overtime]).workdayOvertimeText {
                Text(workdayText)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(.background.opacity(0.62), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
    }

    private var statusText: String {
        session.status == .active ? "进行中" : "待补齐"
    }

    private var durationText: String {
        guard let duration = session.duration else {
            return session.status == .active ? "正在记录" : "结束时间缺失"
        }
        return TimeTraceFormat.duration(duration)
    }
}

struct EditSessionView: View {
    @EnvironmentObject private var store: HistoryFeatureStore
    @Environment(\.dismiss) private var dismiss
    let session: ActivitySession
    let onSaved: () -> Void
    @State private var startAt: Date
    @State private var endAt: Date
    @State private var hasEnd: Bool
    @State private var confirmingDeletion = false

    private var model: AppModel { store.application }

    init(session: ActivitySession, onSaved: @escaping () -> Void = {}) {
        self.session = session
        self.onSaved = onSaved
        _startAt = State(initialValue: session.startAt)
        _endAt = State(initialValue: session.endAt ?? Date())
        _hasEnd = State(initialValue: session.endAt != nil)
    }

    var body: some View {
        NavigationStack {
            Form {
                if session.endAt == nil && session.status != .active {
                    Section {
                        Label("这条记录缺少结束时间，请手动补齐。", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Button("使用当前时间补齐") {
                            hasEnd = true
                            endAt = max(Date(), startAt)
                        }
                    } header: {
                        Text("异常数据")
                    }
                }
                DatePicker("开始", selection: $startAt)
                Toggle(session.endAt == nil ? "补齐结束时间" : "有结束时间", isOn: $hasEnd)
                if hasEnd { DatePicker("结束", selection: $endAt) }
                Section {
                    Button("删除这条记录", role: .destructive) { confirmingDeletion = true }
                }
            }
            .scrollContentBackground(.hidden)
            .timeTraceScreen()
            .navigationTitle("修正记录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        if model.adjustSession(session, startAt: startAt, endAt: hasEnd ? endAt : nil) {
                            dismiss()
                            onSaved()
                        }
                    }.disabled(hasEnd && endAt < startAt)
                }
            }
            .confirmationDialog("删除这条记录？", isPresented: $confirmingDeletion, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    if model.deleteSession(session) {
                        dismiss()
                        onSaved()
                    }
                }
                Button("取消", role: .cancel) {}
            } message: {
                Text("记录会从历史和统计中移除，原始事件仍会保留。")
            }
        }
    }
}

struct RepairOrphanedExitView: View {
    @EnvironmentObject private var store: HistoryFeatureStore
    @Environment(\.dismiss) private var dismiss
    let event: ActivityEvent
    @State private var startAt: Date

    private var model: AppModel { store.application }

    init(event: ActivityEvent) {
        self.event = event
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: event.timestamp)
        // An exit in the early morning is commonly an overnight session. Start
        // with a previous-day time while still allowing any earlier arrival.
        let suggestedStart = event.timestamp.addingTimeInterval(hour < 6 ? -8 * 3_600 : -3_600)
        _startAt = State(initialValue: suggestedStart)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("系统记录") {
                    LabeledContent("检测到离开") {
                        Text("\(TimeTraceFormat.day.string(from: event.timestamp)) \(TimeTraceFormat.time.string(from: event.timestamp))")
                    }
                }
                Section("手动补录") {
                    DatePicker("到达日期和时间", selection: $startAt, in: ...event.timestamp)
                    Text("凌晨离开时可选择上一天的实际到达时间；保存后会生成一段跨日时间记录。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .scrollContentBackground(.hidden)
            .timeTraceScreen()
            .navigationTitle("补齐异常记录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        model.repairOrphanedExit(event, startAt: startAt)
                        dismiss()
                    }
                    .disabled(startAt > event.timestamp)
                }
            }
        }
    }
}

struct AddSessionView: View {
    @EnvironmentObject private var store: HistoryFeatureStore
    @Environment(\.dismiss) private var dismiss
    @State private var startAt = Date().addingTimeInterval(-3600)
    @State private var endAt = Date()

    private var model: AppModel { store.application }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("开始", selection: $startAt)
                DatePicker("结束", selection: $endAt)
            }
            .scrollContentBackground(.hidden)
            .timeTraceScreen()
            .navigationTitle("补录时间记录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { model.addManualSession(startAt: startAt, endAt: endAt); dismiss() }
                        .disabled(endAt < startAt)
                }
            }
        }
    }
}
