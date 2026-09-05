import SwiftUI

struct TodayView: View {
    @EnvironmentObject private var store: TodayFeatureStore
    @AppStorage("profileNickname") private var profileNickname = ""

    private var model: AppModel { store.application }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    hero(summary: todaySummary, now: timeline.date)
                    if let summary = todaySummary {
                        TTSectionTitle(title: "今日时间线")
                        TTCard {
                            VStack(spacing: 0) {
                                ForEach(Array(summary.sessions.enumerated()), id: \.element.id) { index, session in
                                    TodaySessionRow(
                                        session: session,
                                        now: timeline.date,
                                        placeName: model.workTrigger?.displayPlaceName ?? "工作地点"
                                    )
                                    if index < summary.sessions.count - 1 { Divider().padding(.leading, 50) }
                                }
                            }
                        }
                        if summary.isIncomplete && !summary.sessions.contains(where: { $0.status == .active }) {
                            Label("有一条记录未检测到离开时间", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                    if !model.activeReminderInstances.isEmpty { activeReminders }
                    Spacer(minLength: 24)
                }
                .padding(.horizontal, 20)
                .padding(.top, 12)
            }
            .timeTraceScreen()
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(greeting)\(nicknameSuffix) \(greetingEmoji)")
                        .font(.title2.weight(.bold))
                    Text(TimeTraceFormat.day.string(from: Date()))
                        .font(.subheadline)
                        .foregroundStyle(TimeTraceDesign.muted)
                }
                Spacer()
                Image(systemName: "calendar")
                    .font(.headline)
                    .foregroundStyle(TimeTraceDesign.blue)
                    .frame(width: 38, height: 38)
                    .background(TimeTraceDesign.card, in: Circle())
            }
        }
    }

    @ViewBuilder private func hero(summary: DailyActivitySummary?, now: Date) -> some View {
        let active = summary?.sessions.contains(where: { $0.status == .active }) ?? false
        let dayStatus = ChinaWorkCalendar.status(for: now)
        let isRestDay = !dayStatus.isWorkday
        let hasRecordedWork = !(summary?.sessions.isEmpty ?? true)
        let resting = isRestDay && !active && !hasRecordedWork
        let overtime = isRestDay && (active || hasRecordedWork)
        let placeName = model.workTrigger?.displayPlaceName ?? "工作地点"
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                TTIcon(systemName: active ? "building.2.fill" : "location.fill", tint: .white, size: 48)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text(active ? (dayStatus.isWorkday ? "正在\(placeName)" : "休息日加班中") : (overtime ? "休息日加班" : (resting ? "今日休息" : "自动记录已开启")))
                        .font(.headline)
                    Text(active ? (dayStatus.isWorkday ? "系统正在为你记录工作时间" : "已记录为\(dayStatus.label)加班") : (overtime ? "已记录为\(dayStatus.label)加班" : (resting ? "今天是\(dayStatus.label)，好好休息吧" : "到达\(placeName)后将自动开始记录")))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(resting ? "今日安排" : "今日累计工作时长").font(.caption).foregroundStyle(.white.opacity(0.8))
                Text(summary.map { TimeTraceFormat.duration(liveDuration($0, now: now)) } ?? (resting ? "无需记录" : "尚未开始"))
                    .font(.system(size: 29, weight: .bold, design: .rounded))
                    .monospacedDigit()
                if let summary, let arrival = summary.firstArrivalTime {
                    Text("到达 \(TimeTraceFormat.time.string(from: arrival))")
                        .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.82))
                }
            }
            Label(resting ? "休息日不自动记录" : (overtime ? "已保留加班记录" : "一切自动记录，无需操作"), systemImage: "checkmark.circle.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(.white.opacity(0.12), in: Capsule())
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(TimeTraceDesign.heroGradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: TimeTraceDesign.violet.opacity(0.22), radius: 16, y: 9)
    }

    private var activeReminders: some View {
        VStack(alignment: .leading, spacing: 10) {
            TTSectionTitle(title: "进行中的活动")
            ForEach(model.activeReminderInstances, id: \.id) { instance in
                TTCard {
                    HStack {
                        TTIcon(systemName: "timer", tint: .orange)
                        VStack(alignment: .leading) {
                            Text(reminderName(instance)).font(.headline)
                            if let session = model.session(for: instance) {
                                Text("开始于 \(TimeTraceFormat.time.string(from: session.startAt))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Button("完成") { model.finishReminderInstance(instance, abandoned: false) }
                            .buttonStyle(.borderedProminent).tint(TimeTraceDesign.blue)
                    }
                }
            }
        }
    }

    private var todaySummary: DailyActivitySummary? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return model.dailySummaries(interval: DateInterval(start: start, end: end)).first
    }

    private func liveDuration(_ summary: DailyActivitySummary, now: Date) -> TimeInterval {
        summary.totalDuration + summary.sessions.filter { $0.status == .active }.reduce(0) {
            $0 + max(0, now.timeIntervalSince($1.startAt))
        }
    }

    private func reminderName(_ instance: ReminderInstance) -> String {
        model.reminders.first { $0.id == instance.reminderDefinitionId }?.name ?? "活动"
    }

    private var greeting: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return switch hour {
        case 5..<11: "早上好"
        case 11..<14: "中午好"
        case 14..<18: "下午好"
        case 18..<23: "晚上好"
        case 23: "深夜好"
        default: "凌晨好"
        }
    }

    private var greetingEmoji: String {
        let hour = Calendar.current.component(.hour, from: Date())
        return switch hour {
        case 5..<11: "☀️"
        case 11..<18: "🌤️"
        case 18..<23: "🌙"
        default: "✨"
        }
    }

    private var nicknameSuffix: String {
        let name = profileNickname.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "" : "，\(name)"
    }
}

private struct TodaySessionRow: View {
    let session: ActivitySession
    let now: Date
    let placeName: String
    var body: some View {
        HStack(spacing: 12) {
            TTIcon(systemName: "building.2.fill", size: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(placeName).font(.subheadline.weight(.semibold))
                Text("\(TimeTraceFormat.time.string(from: session.startAt)) · \(session.endAt.map { TimeTraceFormat.time.string(from: $0) } ?? "进行中")")
                    .font(.caption).foregroundStyle(TimeTraceDesign.muted)
            }
            Spacer()
            Text(TimeTraceFormat.duration(session.duration ?? max(0, now.timeIntervalSince(session.startAt))))
                .font(.subheadline.weight(.bold)).foregroundStyle(session.status == .active ? .green : TimeTraceDesign.ink)
        }
        .padding(.vertical, 5)
    }
}

struct SessionRow: View {
    let session: ActivitySession
    var now = Date()

    var body: some View {
        HStack {
            if let endAt = session.endAt {
                Text(TimeTraceFormat.time.string(from: session.startAt))
                Image(systemName: "arrow.right")
                    .foregroundStyle(.secondary)
                Text(TimeTraceFormat.time.string(from: endAt))
            } else {
                Text("开始于 \(TimeTraceFormat.time.string(from: session.startAt))")
                Text(statusText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(session.status == .active ? .green : .orange)
            }
            Spacer()
            Text(TimeTraceFormat.duration(session.duration ?? (session.status == .active ? now.timeIntervalSince(session.startAt) : 0)))
                .foregroundStyle(.secondary)
        }
    }

    private var statusText: String {
        session.status == .active ? "进行中" : "未检测到"
    }
}
