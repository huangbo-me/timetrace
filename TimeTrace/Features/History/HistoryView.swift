import SwiftUI

struct HistoryView: View {
    @EnvironmentObject private var store: HistoryFeatureStore
    @State private var repairingEvent: ActivityEvent?
    @State private var selectedSummary: DailyActivitySummary?
    @State private var addingSession = false
    @State private var displayedHistoryCount = 12

    private let historyPageSize = 12

    private var model: AppModel { store.application }

    var body: some View {
        // A session belongs to exactly one group: pending completion, active, or
        // closed. Open sessions are therefore not also rendered inside date cards.
        let pendingSessions = sessionsNeedingCompletion
        let activeSessions = activeWorkSessions
        let allSummaries = completedSummaries
        let origins = originBySessionID
        let visibleSummaries = Array(allSummaries.prefix(displayedHistoryCount))
        let leftSummaries = visibleSummaries.enumerated().compactMap { index, summary in
            index.isMultiple(of: 2) ? summary : nil
        }
        let rightSummaries = visibleSummaries.enumerated().compactMap { index, summary in
            index.isMultiple(of: 2) ? nil : summary
        }

        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("过去的每一天都值得回顾").font(.subheadline).foregroundStyle(TimeTraceDesign.muted)
                    }
                    Spacer()
                    Button { addingSession = true } label: {
                        Image(systemName: "plus").font(.headline.weight(.bold))
                            .frame(width: 40, height: 40).background(TimeTraceDesign.card, in: Circle())
                    }
                }

                if allSummaries.isEmpty && pendingSessions.isEmpty && activeSessions.isEmpty && model.orphanedWorkExitEvents.isEmpty {
                    ContentUnavailableView("还没有历史记录", systemImage: "calendar")
                        .frame(maxWidth: .infinity, minHeight: 360)
                }

                let pendingCount = pendingSessions.count + model.orphanedWorkExitEvents.count
                if pendingCount > 0 {
                    TTSectionTitle(title: "待补齐（\(pendingCount)）")
                    VStack(spacing: 8) {
                        ForEach(pendingSessions, id: \.id) { session in
                            Button { selectedSummary = singleSessionSummary(session) } label: {
                                HistoryStatusRow(session: session, state: .needsCompletion, origin: origins[session.id] ?? .system)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("补齐这段工作记录的结束时间")
                        }

                        ForEach(model.orphanedWorkExitEvents, id: \.id) { event in
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

                    if !model.orphanedWorkExitEvents.isEmpty {
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
                                HistoryStatusRow(session: session, state: .active, origin: origins[session.id] ?? .system)
                            }
                            .buttonStyle(.plain)
                            .accessibilityHint("查看这段正在记录的工作时间")
                        }
                    }
                }

                if !allSummaries.isEmpty {
                    TTSectionTitle(title: "每日汇总")
                    // Independent columns avoid the large blank area a grid leaves
                    // below a short card when the neighboring card is taller.
                    HStack(alignment: .top, spacing: 8) {
                        LazyVStack(spacing: 8) {
                            ForEach(leftSummaries) { summary in
                                historyCard(summary, visibleSummaries: visibleSummaries, allSummaries: allSummaries)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)

                        LazyVStack(spacing: 8) {
                            ForEach(rightSummaries) { summary in
                                historyCard(summary, visibleSummaries: visibleSummaries, allSummaries: allSummaries)
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
        .sheet(item: $repairingEvent) { RepairOrphanedExitView(event: $0) }
        .sheet(item: $selectedSummary) { HistoryDayDetailView(summary: $0, origins: origins) }
        .sheet(isPresented: $addingSession) { AddSessionView() }
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
            .filter { $0.endAt == nil && $0.status != .active }
            .sorted { $0.startAt > $1.startAt }
    }

    private var activeWorkSessions: [ActivitySession] {
        workSessions
            .filter { $0.endAt == nil && $0.status == .active }
            .sorted { $0.startAt > $1.startAt }
    }

    private var workSessions: [ActivitySession] {
        guard let workActivityId = model.workActivity?.id else { return [] }
        return model.sessions.filter { $0.activityId == workActivityId && $0.deletedAt == nil }
    }

    private var originBySessionID: [UUID: HistoryRecordOrigin] {
        Dictionary(uniqueKeysWithValues: workSessions.map { ($0.id, origin(for: $0)) })
    }

    private func origin(for session: ActivitySession) -> HistoryRecordOrigin {
        let startEvent = model.events.first { $0.id == session.startEventId }

        // An orphaned exit repaired by the user has a manual start event, but it
        // is semantically a backfill rather than a newly-added work session.
        if startEvent?.metadata.values["repairsEventId"] != nil {
            return .backfilled
        }
        if startEvent?.eventType == .manualStart {
            return .manual
        }

        let wasAdjusted = model.events.contains { event in
            event.eventType == .sessionAdjusted &&
            event.metadata.values["sessionId"] == session.id.uuidString
        }
        if wasAdjusted || session.status == .manuallyAdjusted {
            return .backfilled
        }
        return .system
    }

    private func completedSummary(from summary: DailyActivitySummary) -> DailyActivitySummary? {
        let sessions = summary.sessions.filter { $0.endAt != nil }
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
        allSummaries: [DailyActivitySummary]
    ) -> some View {
        Button { selectedSummary = summary } label: {
            HistoryDayCard(
                summary: summary,
                durationTier: durationTier(for: summary.totalDuration),
                origins: originBySessionID
            )
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityHint("打开当天的全部工作时段")
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

private enum HistoryDurationTier {
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

private enum HistoryRecordOrigin {
    case system
    case manual
    case backfilled

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

    var tint: Color {
        switch self {
        case .system: TimeTraceDesign.blue
        case .manual: TimeTraceDesign.violet
        case .backfilled: .orange
        }
    }
}

private struct HistoryOriginBadge: View {
    let origin: HistoryRecordOrigin

    var body: some View {
        Label(origin.label, systemImage: origin.icon)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(origin.tint)
            .lineLimit(1)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(origin.tint.opacity(0.1), in: Capsule())
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

private struct HistoryDayCard: View {
    let summary: DailyActivitySummary
    let durationTier: HistoryDurationTier
    let origins: [UUID: HistoryRecordOrigin]

    private var tint: Color { durationTier.color }

    private var hasOvernightSession: Bool {
        let calendar = Calendar.current
        return summary.sessions.contains { session in
            guard let endAt = session.endAt else { return false }
            return !calendar.isDate(session.startAt, inSameDayAs: endAt)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                Text(TimeTraceFormat.day.string(from: summary.date))
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)

                if hasOvernightSession {
                    Text("跨天")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(TimeTraceDesign.violet)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(TimeTraceDesign.violet.opacity(0.1), in: Capsule())
                        .accessibilityLabel("跨天记录")
                }

            }

            VStack(alignment: .leading, spacing: 5) {
                Text(TimeTraceFormat.duration(summary.totalDuration))
                    .font(.title3.weight(.bold))
                    .foregroundStyle(tint)
                    .minimumScaleFactor(0.8)

                Text("\(summary.sessionCount) 个工作时段 · \(durationTier.label)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 8) {
                ForEach(summary.sessions, id: \.id) { session in
                    HistorySessionItem(
                        session: session,
                        tint: tint,
                        origin: origins[session.id] ?? .system
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
    @Environment(\.dismiss) private var dismiss
    let summary: DailyActivitySummary
    let origins: [UUID: HistoryRecordOrigin]
    @State private var editingSession: ActivitySession?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    LabeledContent("总时长", value: TimeTraceFormat.duration(summary.totalDuration))
                    LabeledContent("工作时段", value: "\(summary.sessionCount) 段")
                    LabeledContent("到达", value: summary.firstArrivalTime.map {
                        TimeTraceFormat.time.string(from: $0)
                    } ?? "—")
                    LabeledContent("离开", value: summary.lastDepartureTime.map {
                        TimeTraceFormat.time.string(from: $0)
                    } ?? "未检测到")
                }

                Section("时段详情") {
                    ForEach(summary.sessions, id: \.id) { session in
                        Button { editingSession = session } label: {
                            HStack(spacing: 10) {
                                HistoryDetailSessionRow(
                                    session: session,
                                    origin: origins[session.id] ?? .system
                                )
                                if session.endAt == nil && session.status != .active {
                                    Text("补齐")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.orange)
                                }
                                Image(systemName: "chevron.right")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(TimeTraceDesign.muted)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("查看并修正这个工作时段")
                    }
                }
            }
            .navigationTitle(TimeTraceFormat.day.string(from: summary.date))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .sheet(item: $editingSession) { EditSessionView(session: $0) }
        }
    }
}

private struct HistoryDetailSessionRow: View {
    let session: ActivitySession
    let origin: HistoryRecordOrigin

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

private struct MasonryLayout: Layout {
    let columns: Int
    let spacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let width = proposal.width, !subviews.isEmpty else { return .zero }
        let itemWidth = columnWidth(for: width)
        var heights = Array(repeating: CGFloat.zero, count: columns)

        for subview in subviews {
            let column = shortestColumn(in: heights)
            let size = subview.sizeThatFits(.init(width: itemWidth, height: nil))
            heights[column] += size.height + spacing
        }

        return CGSize(width: width, height: max(0, (heights.max() ?? 0) - spacing))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let itemWidth = columnWidth(for: bounds.width)
        var heights = Array(repeating: bounds.minY, count: columns)

        for subview in subviews {
            let column = shortestColumn(in: heights)
            let size = subview.sizeThatFits(.init(width: itemWidth, height: nil))
            let x = bounds.minX + CGFloat(column) * (itemWidth + spacing)
            subview.place(
                at: CGPoint(x: x, y: heights[column]),
                anchor: .topLeading,
                proposal: .init(width: itemWidth, height: size.height)
            )
            heights[column] += size.height + spacing
        }
    }

    private func columnWidth(for totalWidth: CGFloat) -> CGFloat {
        (totalWidth - CGFloat(columns - 1) * spacing) / CGFloat(columns)
    }

    private func shortestColumn(in heights: [CGFloat]) -> Int {
        heights.enumerated().min { $0.element < $1.element }?.offset ?? 0
    }
}

struct EditSessionView: View {
    @EnvironmentObject private var store: HistoryFeatureStore
    @Environment(\.dismiss) private var dismiss
    let session: ActivitySession
    @State private var startAt: Date
    @State private var endAt: Date
    @State private var hasEnd: Bool
    @State private var confirmingDeletion = false

    private var model: AppModel { store.application }

    init(session: ActivitySession) {
        self.session = session
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
            .navigationTitle("修正记录")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        model.adjustSession(session, startAt: startAt, endAt: hasEnd ? endAt : nil)
                        dismiss()
                    }.disabled(hasEnd && endAt < startAt)
                }
            }
            .confirmationDialog("删除这条记录？", isPresented: $confirmingDeletion, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    model.deleteSession(session)
                    dismiss()
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
                    Text("凌晨离开时可选择上一天的实际到达时间；保存后会生成一段跨日工作记录。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
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
            .navigationTitle("补录工作时段")
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
