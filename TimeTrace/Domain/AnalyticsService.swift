import Foundation

struct OvertimeBreakdown: Equatable {
    let normalDuration: TimeInterval
    let earlyOvertime: TimeInterval
    let lateOvertime: TimeInterval
    let workdayOvertime: TimeInterval
    let restDayOvertime: TimeInterval

    var totalOvertime: TimeInterval {
        earlyOvertime + lateOvertime + workdayOvertime + restDayOvertime
    }
}

enum SessionDaySpan {
    static func crossedDayCount(from start: Date, to end: Date,
                                timeZoneIdentifier: String) -> Int {
        guard end > start else { return 0 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneIdentifier) ?? .current
        let startDay = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        return max(0, calendar.dateComponents([.day], from: startDay, to: endDay).day ?? 0)
    }
}

enum WorkScheduleCalculator {
    static func breakdown(from start: Date, to end: Date,
                          schedule: WorkScheduleSnapshot) -> OvertimeBreakdown? {
        guard schedule.isEnabled,
              let timeZone = TimeZone(identifier: schedule.timeZoneIdentifier),
              end > start else { return nil }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        switch schedule.scheduleMode {
        case .fixedWindow:
            guard let startMinute = schedule.startMinute,
                  let endMinute = schedule.endMinute else { return nil }
            return fixedWindowBreakdown(
                from: start, to: end,
                startMinute: startMinute, endMinute: endMinute,
                schedule: schedule, calendar: calendar
            )
        case .flexibleDuration:
            return flexibleDurationBreakdown(
                from: start, to: end, schedule: schedule, calendar: calendar
            )
        }
    }

    private struct FixedShift {
        let interval: DateInterval
        let isWorkday: Bool
    }

    private static func fixedWindowBreakdown(
        from start: Date,
        to end: Date,
        startMinute: Int,
        endMinute: Int,
        schedule: WorkScheduleSnapshot,
        calendar: Calendar
    ) -> OvertimeBreakdown? {
        let session = DateInterval(start: start, end: end)
        let firstDay = calendar.date(byAdding: .day, value: -1,
                                     to: calendar.startOfDay(for: start))!
        let lastDay = calendar.startOfDay(for: end)
        let finalGeneratedDay = calendar.date(byAdding: .day, value: 1, to: lastDay)!

        var shifts: [FixedShift] = []
        var allWorkdayShifts: [DateInterval] = []
        var boundaries: Set<Date> = [start, end]
        var day = firstDay
        while day <= finalGeneratedDay {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
            boundaries.insert(day)
            boundaries.insert(nextDay)
            let endBase = endMinute > startMinute ? day : nextDay
            guard let shiftStart = wallClockDate(on: day, minuteOfDay: startMinute,
                                                 calendar: calendar),
                  let shiftEnd = wallClockDate(on: endBase, minuteOfDay: endMinute,
                                               calendar: calendar) else { return nil }
            let interval = DateInterval(start: shiftStart, end: shiftEnd)
            let workday = isWorkday(day, schedule: schedule, calendar: calendar)
            if workday {
                allWorkdayShifts.append(interval)
            }
            if interval.intersects(session) {
                shifts.append(FixedShift(interval: interval, isWorkday: workday))
                boundaries.insert(max(start, shiftStart))
                boundaries.insert(min(end, shiftEnd))
            }
            day = nextDay
        }
        shifts.sort { $0.interval.start < $1.interval.start }

        var normalByShift = Array(repeating: TimeInterval(0), count: shifts.count)
        var early: TimeInterval = 0
        var late: TimeInterval = 0
        var restDay: TimeInterval = 0
        let points = boundaries.filter { $0 >= start && $0 <= end }.sorted()
        guard points.count >= 2 else { return nil }

        for index in 0..<(points.count - 1) {
            let segmentStart = points[index]
            let segmentEnd = points[index + 1]
            guard segmentEnd > segmentStart else { continue }
            let duration = segmentEnd.timeIntervalSince(segmentStart)
            let midpoint = segmentStart.addingTimeInterval(duration / 2)
            if let shiftIndex = shifts.firstIndex(where: { $0.interval.contains(midpoint) }) {
                if shifts[shiftIndex].isWorkday {
                    normalByShift[shiftIndex] += duration
                } else {
                    restDay += duration
                }
                continue
            }

            let localDay = calendar.startOfDay(for: midpoint)
            guard isWorkday(localDay, schedule: schedule, calendar: calendar) else {
                restDay += duration
                continue
            }

            let alreadyWorkedNormal = shifts.contains { shift in
                shift.isWorkday && shift.interval.end > start && shift.interval.end <= segmentStart
            }
            if alreadyWorkedNormal {
                late += duration
                continue
            }
            let previousEnd = allWorkdayShifts.filter { $0.end <= midpoint }.map(\.end).max()
            let nextStart = allWorkdayShifts.filter { $0.start >= midpoint }.map(\.start).min()
            switch (previousEnd, nextStart) {
            case let (previous?, next?) where next.timeIntervalSince(midpoint) < midpoint.timeIntervalSince(previous):
                early += duration
            case (nil, .some):
                early += duration
            default:
                late += duration
            }
        }

        let restDuration = TimeInterval(schedule.restMinutes * 60)
        let normal = normalByShift.reduce(0) { total, duration in
            total + max(0, duration - restDuration)
        }

        return OvertimeBreakdown(
            normalDuration: normal,
            earlyOvertime: early,
            lateOvertime: late,
            workdayOvertime: 0,
            restDayOvertime: restDay
        )
    }

    private static func flexibleDurationBreakdown(
        from start: Date,
        to end: Date,
        schedule: WorkScheduleSnapshot,
        calendar: Calendar
    ) -> OvertimeBreakdown? {
        let restDuration = TimeInterval(schedule.restMinutes * 60)
        let standardDuration = TimeInterval(schedule.standardWorkMinutes * 60)
        var normal: TimeInterval = 0
        var workdayOvertime: TimeInterval = 0
        var restDayOvertime: TimeInterval = 0
        var day = calendar.startOfDay(for: start)

        while day < end {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
                return nil
            }
            let intervalStart = max(start, day)
            let intervalEnd = min(end, nextDay)
            if intervalEnd > intervalStart {
                let presence = intervalEnd.timeIntervalSince(intervalStart)
                if isWorkday(day, schedule: schedule, calendar: calendar) {
                    let effective = max(0, presence - restDuration)
                    let normalDuration = min(effective, standardDuration)
                    normal += normalDuration
                    workdayOvertime += max(0, effective - normalDuration)
                } else {
                    restDayOvertime += presence
                }
            }
            day = nextDay
        }

        return OvertimeBreakdown(
            normalDuration: normal,
            earlyOvertime: 0,
            lateOvertime: 0,
            workdayOvertime: workdayOvertime,
            restDayOvertime: restDayOvertime
        )
    }

    private static func isWorkday(_ day: Date, schedule: WorkScheduleSnapshot,
                                  calendar: Calendar) -> Bool {
        switch schedule.calendarMode {
        case .chinaStatutory:
            ChinaWorkCalendar.status(for: day, calendar: calendar).isWorkday
        case .customWeekdays:
            schedule.weekdaysMask.containsWeekday(calendar.component(.weekday, from: day))
        }
    }

    private static func wallClockDate(on day: Date, minuteOfDay: Int,
                                      calendar: Calendar) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = minuteOfDay / 60
        components.minute = minuteOfDay % 60
        components.second = 0
        return calendar.date(from: components)
    }
}

struct DailyActivitySummary: Identifiable {
    var id: Date { date }
    let date: Date
    let firstArrivalTime: Date?
    let lastDepartureTime: Date?
    let totalDuration: TimeInterval
    let sessionCount: Int
    let isIncomplete: Bool
    let sessions: [ActivitySession]
}

struct PeriodComparison {
    let workDurationChange: TimeInterval?
    let arrivalTimeChange: TimeInterval?
    let departureTimeChange: TimeInterval?
}

struct PeriodActivitySummary {
    let start: Date
    let end: Date
    let workingDays: Int
    let totalWorkDuration: TimeInterval
    let averageWorkDuration: TimeInterval?
    let averageArrivalOffset: TimeInterval?
    let averageDepartureOffset: TimeInterval?
    let latestDepartureTime: Date?
    let latestDepartureDate: Date?
    let earliestArrivalTime: Date?
    let longestWorkDay: DailyActivitySummary?
    let incompleteDays: Int
    let comparison: PeriodComparison
    let days: [DailyActivitySummary]
}

struct PlaceActivitySummary: Identifiable {
    var id: String { placeTriggerId?.uuidString ?? "unmarked" }
    let placeTriggerId: UUID?
    let totalDuration: TimeInterval
    let sessionCount: Int
    let incompleteSessionCount: Int
}

/// Keeps the unmarked-place filter distinct from showing every place.
enum PlaceSessionFilter: Equatable {
    case all
    case place(UUID?)
    case placeType(PlaceType, triggerIDs: Set<UUID>)

    static func forType(_ type: PlaceType, places: [ActivityTrigger]) -> Self {
        .placeType(type, triggerIDs: Set(places.filter { $0.placeType == type }.map(\.id)))
    }

    func includes(_ session: ActivitySession) -> Bool {
        switch self {
        case .all: true
        case .place(let triggerId): session.placeTriggerId == triggerId
        case .placeType(_, let triggerIDs): session.placeTriggerId.map { triggerIDs.contains($0) } ?? false
        }
    }
}

protocol AnalyticsServicing {
    func dailySummaries(sessions: [ActivitySession], activityId: UUID?, interval: DateInterval,
                        calendar: Calendar) -> [DailyActivitySummary]
    func placeSummaries(sessions: [ActivitySession], activityId: UUID?, interval: DateInterval) -> [PlaceActivitySummary]
    func periodSummary(sessions: [ActivitySession], activityId: UUID?, interval: DateInterval,
                       previous: DateInterval, placeFilter: PlaceSessionFilter,
                       calendar: Calendar) -> PeriodActivitySummary
    func weeklySummary(sessions: [ActivitySession], activityId: UUID?, containing date: Date,
                       calendar: Calendar) -> PeriodActivitySummary
    func monthlySummary(sessions: [ActivitySession], activityId: UUID?, containing date: Date,
                        calendar: Calendar) -> PeriodActivitySummary
}

struct AnalyticsService: AnalyticsServicing {
    func dailySummaries(sessions: [ActivitySession], activityId: UUID?, interval: DateInterval,
                        calendar: Calendar) -> [DailyActivitySummary] {
        let relevant = sessions.filter { session in
            session.deletedAt == nil && (activityId == nil || session.activityId == activityId) &&
            session.startAt >= interval.start && session.startAt < interval.end
        }
        let grouped = Dictionary(grouping: relevant) { calendar.startOfDay(for: $0.startAt) }
        return grouped.keys.sorted().map { day in
            let values = grouped[day, default: []].sorted { $0.startAt < $1.startAt }
            let closed = values.filter { $0.endAt != nil }
            return DailyActivitySummary(
                date: day,
                firstArrivalTime: values.first?.startAt,
                lastDepartureTime: closed.compactMap(\.endAt).max(),
                totalDuration: closed.compactMap(\.duration).reduce(0, +),
                sessionCount: values.count,
                isIncomplete: values.contains { $0.endAt == nil },
                sessions: values
            )
        }
    }

    func placeSummaries(sessions: [ActivitySession], activityId: UUID?, interval: DateInterval) -> [PlaceActivitySummary] {
        let relevant = sessions.filter {
            $0.deletedAt == nil && (activityId == nil || $0.activityId == activityId) && $0.startAt >= interval.start && $0.startAt < interval.end
        }
        return Dictionary(grouping: relevant, by: \.placeTriggerId)
            .map { placeTriggerId, values in
                PlaceActivitySummary(
                    placeTriggerId: placeTriggerId,
                    totalDuration: values.compactMap(\.duration).reduce(0, +),
                    sessionCount: values.count,
                    incompleteSessionCount: values.filter { $0.endAt == nil }.count
                )
            }
            .sorted {
                if $0.totalDuration != $1.totalDuration { return $0.totalDuration > $1.totalDuration }
                return $0.id < $1.id
            }
    }

    func weeklySummary(sessions: [ActivitySession], activityId: UUID?, containing date: Date,
                       calendar: Calendar) -> PeriodActivitySummary {
        let current = weekInterval(containing: date, calendar: calendar)
        let previous = DateInterval(start: calendar.date(byAdding: .day, value: -7, to: current.start)!, end: current.start)
        return periodSummary(sessions: sessions, activityId: activityId, interval: current,
                             previous: previous, placeFilter: .all, calendar: calendar)
    }

    func monthlySummary(sessions: [ActivitySession], activityId: UUID?, containing date: Date,
                        calendar: Calendar) -> PeriodActivitySummary {
        let current = calendar.dateInterval(of: .month, for: date)!
        let previousDate = calendar.date(byAdding: .month, value: -1, to: current.start)!
        let previous = calendar.dateInterval(of: .month, for: previousDate)!
        return periodSummary(sessions: sessions, activityId: activityId, interval: current,
                             previous: previous, placeFilter: .all, calendar: calendar)
    }

    func periodSummary(sessions: [ActivitySession], activityId: UUID?, interval: DateInterval,
                       previous: DateInterval, placeFilter: PlaceSessionFilter = .all,
                       calendar: Calendar) -> PeriodActivitySummary {
        let selectedSessions = sessions.filter { placeFilter.includes($0) }
        let days = dailySummaries(sessions: selectedSessions, activityId: activityId, interval: interval, calendar: calendar)
        let previousDays = dailySummaries(sessions: selectedSessions, activityId: activityId, interval: previous, calendar: calendar)
        let metrics = calculate(days: days, calendar: calendar)
        let old = calculate(days: previousDays, calendar: calendar)
        return PeriodActivitySummary(
            start: interval.start, end: interval.end, workingDays: days.count,
            totalWorkDuration: metrics.total, averageWorkDuration: metrics.averageDuration,
            averageArrivalOffset: metrics.averageArrival, averageDepartureOffset: metrics.averageDeparture,
            latestDepartureTime: metrics.latestDeparture?.time,
            latestDepartureDate: metrics.latestDeparture?.day,
            earliestArrivalTime: metrics.earliestArrival,
            longestWorkDay: days.max { $0.totalDuration < $1.totalDuration },
            incompleteDays: days.filter(\.isIncomplete).count,
            comparison: PeriodComparison(
                workDurationChange: difference(metrics.total, old.total, hasCurrent: !days.isEmpty, hasOld: !previousDays.isEmpty),
                arrivalTimeChange: difference(metrics.averageArrival, old.averageArrival),
                departureTimeChange: difference(metrics.averageDeparture, old.averageDeparture)
            ),
            days: days
        )
    }

    private struct Metrics {
        let total: TimeInterval
        let averageDuration: TimeInterval?
        let averageArrival: TimeInterval?
        let averageDeparture: TimeInterval?
        let latestDeparture: (time: Date, day: Date)?
        let earliestArrival: Date?
    }

    private func calculate(days: [DailyActivitySummary], calendar: Calendar) -> Metrics {
        let completeDays = days.filter { !$0.isIncomplete }
        let arrivals = days.compactMap { day -> (Date, TimeInterval)? in
            guard let value = day.firstArrivalTime else { return nil }
            return (value, value.timeIntervalSince(calendar.startOfDay(for: day.date)))
        }
        let departures = days.compactMap { day -> (Date, Date, TimeInterval)? in
            guard let value = day.lastDepartureTime else { return nil }
            return (value, day.date, value.timeIntervalSince(calendar.startOfDay(for: day.date)))
        }
        let latest = departures.max { $0.2 < $1.2 }
        return Metrics(
            total: days.map(\.totalDuration).reduce(0, +),
            averageDuration: average(completeDays.map(\.totalDuration)),
            averageArrival: average(arrivals.map(\.1)),
            averageDeparture: average(departures.map(\.2)),
            latestDeparture: latest.map { ($0.0, $0.1) },
            earliestArrival: arrivals.min { $0.1 < $1.1 }?.0
        )
    }

    private func average(_ values: [TimeInterval]) -> TimeInterval? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func difference(_ lhs: TimeInterval?, _ rhs: TimeInterval?) -> TimeInterval? {
        guard let lhs, let rhs else { return nil }
        return lhs - rhs
    }

    private func difference(_ lhs: TimeInterval, _ rhs: TimeInterval, hasCurrent: Bool, hasOld: Bool) -> TimeInterval? {
        guard hasCurrent, hasOld else { return nil }
        return lhs - rhs
    }

    private func weekInterval(containing date: Date, calendar: Calendar) -> DateInterval {
        var iso = calendar
        iso.firstWeekday = 2
        iso.minimumDaysInFirstWeek = 4
        return iso.dateInterval(of: .weekOfYear, for: date)!
    }
}
