import SwiftUI

enum TodayHeroMode: Equatable {
    case regular
    case rest
    case overtime
    case activeActivity
}

struct TodayHeroCopy: Equatable {
    let title: String
    let detail: String
    let statusLabel: String
}

/// A timeline row belongs to the place that created its session, rather than
/// to whichever workplace happened to be created first.
enum TodayPlacePresentation {
    static func systemImage(for session: ActivitySession, places: [ActivityTrigger]) -> String {
        places.first { $0.id == session.placeTriggerId }?.placeType.systemImage ?? "location.fill"
    }

    static func name(for session: ActivitySession, places: [ActivityTrigger]) -> String {
        guard let placeTriggerId = session.placeTriggerId,
              let place = places.first(where: { $0.id == placeTriggerId }) else {
            return session.placeTriggerId == nil ? "手动记录" : "未关联地点"
        }
        return place.displayPlaceName
    }
}

/// Work calendars describe the work activity only. A Saturday run, study
/// session, or other configured place is a normal activity, not overtime.
enum TodayWorkdayRule {
    static func mode(isWorkday: Bool, activePlaceType: PlaceType?,
                     hasRecordedWork: Bool, hasRecordedActivity: Bool) -> TodayHeroMode {
        if let activePlaceType, activePlaceType != .work {
            return .activeActivity
        }
        if !isWorkday && (activePlaceType == .work || hasRecordedWork) {
            return .overtime
        }
        if !isWorkday && !hasRecordedActivity {
            return .rest
        }
        return .regular
    }

    static func copy(for mode: TodayHeroMode, isActive: Bool, placeName: String,
                     activityName: String, workdayLabel: String) -> TodayHeroCopy {
        switch mode {
        case .activeActivity:
            TodayHeroCopy(title: "正在\(placeName)", detail: "系统正在记录\(activityName)时间",
                          statusLabel: "\(activityName)不受工作日限制")
        case .overtime:
            TodayHeroCopy(title: isActive ? "休息日加班中" : "休息日加班",
                          detail: "已记录为\(workdayLabel)加班", statusLabel: "已保留加班记录")
        case .rest:
            TodayHeroCopy(title: "今日休息", detail: "今天是\(workdayLabel)，好好休息吧",
                          statusLabel: "休息日到达地点仍会自动记录")
        case .regular:
            TodayHeroCopy(title: isActive ? "正在\(placeName)" : "地点时间记录",
                          detail: isActive ? "系统正在为你记录工作时间" : "系统检测到进出已启用地点时记录",
                          statusLabel: "一切自动记录，无需操作")
        }
    }
}

/// Work totals use place purpose as well as activity identity: home and office
/// geofences can both belong to the default work activity.
struct TodayWorkSummary {
    let sessions: [ActivitySession]

    init(sessions: [ActivitySession], places: [ActivityTrigger], workActivityIDs: Set<UUID>) {
        self.sessions = sessions.filter { session in
            guard session.deletedAt == nil,
                  workActivityIDs.contains(session.activityId) else { return false }
            // Manual work has no place. An unresolved place must not be
            // assumed to be work, since it may have been a home or other place.
            guard let placeId = session.placeTriggerId else { return true }
            return places.first(where: { $0.id == placeId })?.placeType == .work
        }
    }

    var firstArrivalTime: Date? { sessions.map(\.startAt).min() }

    func duration(now: Date) -> TimeInterval {
        sessions.reduce(0) { total, session in
            total + (session.duration ?? (session.status == .active
                ? max(0, now.timeIntervalSince(session.startAt)) : 0))
        }
    }
}

/// The hero's displayed total follows the currently active place category.
struct TodayHeroSummary {
    let activeSession: ActivitySession?
    let activePlace: ActivityTrigger?
    let sessions: [ActivitySession]
    let duration: TimeInterval
    let firstArrivalTime: Date?
    var label: String { activePlace?.placeType == .home && activeSession != nil
        ? "本次在家时长" : "今日累计\(activePlace?.placeType.displayName ?? "工作")时长" }
    var systemImage: String { activePlace?.placeType.systemImage ?? "location.fill" }

    init(sessions: [ActivitySession], places: [ActivityTrigger], workActivityIDs: Set<UUID>,
         now: Date, calendar: Calendar = .current) {
        let currentSession = sessions.filter {
            $0.deletedAt == nil && $0.status == .active && $0.endAt == nil &&
            $0.startAt <= now && workActivityIDs.contains($0.activityId)
        }.max { $0.startAt < $1.startAt }
        activeSession = currentSession
        activePlace = places.first { $0.id == currentSession?.placeTriggerId }
        if activePlace?.placeType == .home, let currentSession {
            self.sessions = [currentSession]
            duration = max(0, now.timeIntervalSince(currentSession.startAt))
            firstArrivalTime = currentSession.startAt
            return
        }
        let selectedType = activePlace?.placeType ?? .work
        let dayStart = calendar.startOfDay(for: now)
        let selectedSessions = sessions.filter { session in
            guard session.deletedAt == nil, workActivityIDs.contains(session.activityId),
                  session.startAt <= now,
                  (session.endAt ?? (session.status == .active ? now : session.startAt)) > dayStart else {
                return false
            }
            guard let placeId = session.placeTriggerId else { return selectedType == .work }
            return places.first { $0.id == placeId }?.placeType == selectedType
        }
        self.sessions = selectedSessions
        duration = selectedSessions.reduce(0) { total, session in
            guard let end = session.endAt ?? (session.status == .active ? now : nil) else { return total }
            return total + max(0, min(end, now).timeIntervalSince(max(session.startAt, dayStart)))
        }
        firstArrivalTime = selectedSessions.map(\.startAt).min()
    }
}

struct TodayView: View {
    @Environment(\.timeTraceDesign) private var design

    @EnvironmentObject private var store: TodayFeatureStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("profileNickname") private var profileNickname = ""

    private var model: AppModel { store.application }

    var body: some View {
        TimelineView(.periodic(from: .now, by: scenePhase == .active && model.workSessions.contains(where: { $0.status == .active }) ? 1 : 60)) { timeline in
            let summary = todaySummary(now: timeline.date)
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 20) {
                    header
                    TTLocationPermissionNotice(status: model.locationAuthorizationStatus)
                    hero(summary: summary, now: timeline.date)
                    if let summary {
                        TTSectionTitle(title: "今日时间线")
                        TTCard {
                            VStack(spacing: 0) {
                                ForEach(Array(summary.sessions.enumerated()), id: \.element.id) { index, session in
                                    TodaySessionRow(
                                        session: session,
                                        placeName: TodayPlacePresentation.name(for: session, places: model.triggers),
                                        systemImage: TodayPlacePresentation.systemImage(for: session, places: model.triggers)
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
            .timeTraceTabTitle("今天")
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
                        .foregroundStyle(design.muted)
                }
                Spacer()
                TodayRecordingPulse(isActive: model.workSessions.contains { $0.status == .active })
                    .frame(width: 38, height: 38)
                    .background(design.card, in: Circle())
            }
        }
    }

    @ViewBuilder private func hero(summary: DailyActivitySummary?, now: Date) -> some View {
        let heroSummary = TodayHeroSummary(sessions: model.workSessions, places: model.triggers,
                                          workActivityIDs: model.workActivityIDs, now: now)
        let activeSession = heroSummary.activeSession
        let active = activeSession != nil
        let activePlace = heroSummary.activePlace
        let activePlaceType = activePlace?.placeType
        let dayStatus = ChinaWorkCalendar.status(for: now)
        let workSummary = TodayWorkSummary(sessions: summary?.sessions ?? [], places: model.triggers,
                                           workActivityIDs: model.workActivityIDs)
        let hasRecordedWork = !workSummary.sessions.isEmpty || (activePlaceType == nil && !heroSummary.sessions.isEmpty)
        let hasRecordedActivity = !(summary?.sessions.isEmpty ?? true) || !heroSummary.sessions.isEmpty
        let mode = TodayWorkdayRule.mode(
            isWorkday: dayStatus.isWorkday,
            activePlaceType: activePlaceType,
            hasRecordedWork: hasRecordedWork,
            hasRecordedActivity: hasRecordedActivity
        )
        let placeName = activePlace?.displayPlaceName ?? model.workTrigger?.displayPlaceName ?? "工作地点"
        let activityName = activePlaceType?.displayName ?? "活动"
        let copy = TodayWorkdayRule.copy(for: mode, isActive: active, placeName: placeName,
                                         activityName: activityName, workdayLabel: dayStatus.label)
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                TTIcon(systemName: heroSummary.systemImage, tint: .white, size: 48)
                    .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text(copy.title)
                        .font(.headline)
                    Text(copy.detail)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(mode == .rest ? "今日安排" : heroSummary.label)
                    .font(.caption).foregroundStyle(.white.opacity(0.8))
                if summary != nil || !heroSummary.sessions.isEmpty {
                    heroDuration(heroSummary.duration)
                        .font(.system(size: 46, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityLabel(heroSummary.label)
                        .accessibilityValue(TimeTraceFormat.durationWithSeconds(heroSummary.duration))
                } else {
                    Text(mode == .rest ? "尚无记录" : "尚未开始")
                        .font(.system(size: 29, weight: .bold, design: .rounded))
                }
                if let arrival = heroSummary.firstArrivalTime {
                    Text(activePlaceType == .home && active
                         ? "到家 \(arrival.formatted(.dateTime.month().day().hour().minute().locale(TimeTraceLocalization.locale)))"
                         : (arrival < Calendar.current.startOfDay(for: now)
                            ? "今日从 00:00 累计" : "到达 \(TimeTraceFormat.time.string(from: arrival))"))
                        .font(.caption.weight(.medium)).foregroundStyle(.white.opacity(0.82))
                }
            }
            Label(model.automaticRecordingDetail, systemImage: "location.fill")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
                .padding(.horizontal, 11).padding(.vertical, 8)
                .background(.white.opacity(0.12), in: Capsule())
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(design.heroGradient, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: design.violet.opacity(0.22), radius: 16, y: 9)
    }

    private func heroDuration(_ duration: TimeInterval) -> Text {
        let seconds = max(0, Int(duration))
        let hours = String(format: "%02d", seconds / 3600)
        let minutes = String(format: "%02d", seconds / 60 % 60)
        let remainder = String(format: "%02d", seconds % 60)
        let hourUnit = Text("时").font(.system(size: 16, weight: .medium)).foregroundColor(.white.opacity(0.75))
        let minuteUnit = Text("分").font(.system(size: 16, weight: .medium)).foregroundColor(.white.opacity(0.75))
        let secondUnit = Text("秒").font(.system(size: 16, weight: .medium)).foregroundColor(.white.opacity(0.75))
        // A single Text scales all three values and their units together on narrow screens.
        return Text("\(hours)\(hourUnit) \(minutes)\(minuteUnit) \(remainder)\(secondUnit)")
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
                            .buttonStyle(.glassProminent)
                            .foregroundStyle(design.onAccent).tint(design.blue)
                    }
                }
            }
        }
    }

    private func todaySummary(now: Date) -> DailyActivitySummary? {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return model.dailySummaries(interval: DateInterval(start: start, end: end)).first
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

private struct TodayRecordingPulse: View {
    @Environment(\.timeTraceDesign) private var design

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    let isActive: Bool

    var body: some View {
        Group {
            if isActive && !reduceMotion && scenePhase == .active {
                // One gentle beat followed by a rest; only this small indicator animates.
                Circle()
                    .fill(Color.mint)
                    .frame(width: 8, height: 8)
                    .keyframeAnimator(initialValue: 0.0, repeating: true) { content, pulse in
                        content
                            .scaleEffect(1 + 0.16 * pulse)
                            .background {
                                Circle()
                                    .fill(Color.mint.opacity(0.08 + 0.08 * pulse))
                                    .frame(width: 16, height: 16)
                                    .scaleEffect(1 + 0.12 * pulse)
                            }
                    } keyframes: { _ in
                        CubicKeyframe(1.0, duration: 0.16)
                        CubicKeyframe(0.0, duration: 0.24)
                        LinearKeyframe(0.0, duration: 0.60)
                    }
            } else {
                Circle()
                    .fill(isActive ? Color.mint : design.muted.opacity(0.5))
                    .frame(width: 8, height: 8)
            }
        }
        .frame(width: 20, height: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(isActive ? "正在记录时间" : "当前没有进行中的记录")
    }
}

private struct TodaySessionRow: View {
    @Environment(\.timeTraceDesign) private var design

    let session: ActivitySession
    let placeName: String
    let systemImage: String
    var body: some View {
        HStack(spacing: 12) {
            TTIcon(systemName: systemImage, size: 38)
            VStack(alignment: .leading, spacing: 4) {
                Text(placeName).font(.subheadline.weight(.semibold))
                Text(session.endAt.map { "\(TimeTraceFormat.time.string(from: session.startAt)) · \(TimeTraceFormat.time.string(from: $0))" }
                     ?? "开始于 \(TimeTraceFormat.time.string(from: session.startAt))")
                    .font(.caption).foregroundStyle(design.muted)
            }
            Spacer()
            Text(session.status == .active ? "记录中" : session.duration.map(TimeTraceFormat.duration) ?? "未检测到离开")
                .font(.subheadline.weight(.bold)).foregroundStyle(session.status == .active ? .green : design.ink)
                .monospacedDigit()
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
