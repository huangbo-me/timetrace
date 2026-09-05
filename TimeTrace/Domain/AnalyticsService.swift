import Foundation

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

    func includes(_ session: ActivitySession) -> Bool {
        switch self {
        case .all: true
        case .place(let triggerId): session.placeTriggerId == triggerId
        }
    }
}

protocol AnalyticsServicing {
    func dailySummaries(sessions: [ActivitySession], activityId: UUID?, interval: DateInterval,
                        calendar: Calendar) -> [DailyActivitySummary]
    func placeSummaries(sessions: [ActivitySession], activityId: UUID, interval: DateInterval) -> [PlaceActivitySummary]
    func periodSummary(sessions: [ActivitySession], activityId: UUID, interval: DateInterval,
                       previous: DateInterval, placeFilter: PlaceSessionFilter,
                       calendar: Calendar) -> PeriodActivitySummary
    func weeklySummary(sessions: [ActivitySession], activityId: UUID, containing date: Date,
                       calendar: Calendar) -> PeriodActivitySummary
    func monthlySummary(sessions: [ActivitySession], activityId: UUID, containing date: Date,
                        calendar: Calendar) -> PeriodActivitySummary
}

struct AnalyticsService: AnalyticsServicing {
    func dailySummaries(sessions: [ActivitySession], activityId: UUID?, interval: DateInterval,
                        calendar: Calendar) -> [DailyActivitySummary] {
        let relevant = sessions.filter { session in
            session.deletedAt == nil && (activityId == nil || session.activityId == activityId) &&
            interval.contains(session.startAt)
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

    func placeSummaries(sessions: [ActivitySession], activityId: UUID, interval: DateInterval) -> [PlaceActivitySummary] {
        let relevant = sessions.filter {
            $0.deletedAt == nil && $0.activityId == activityId && interval.contains($0.startAt)
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

    func weeklySummary(sessions: [ActivitySession], activityId: UUID, containing date: Date,
                       calendar: Calendar) -> PeriodActivitySummary {
        let current = weekInterval(containing: date, calendar: calendar)
        let previous = DateInterval(start: calendar.date(byAdding: .day, value: -7, to: current.start)!, end: current.start)
        return periodSummary(sessions: sessions, activityId: activityId, interval: current,
                             previous: previous, placeFilter: .all, calendar: calendar)
    }

    func monthlySummary(sessions: [ActivitySession], activityId: UUID, containing date: Date,
                        calendar: Calendar) -> PeriodActivitySummary {
        let current = calendar.dateInterval(of: .month, for: date)!
        let previousDate = calendar.date(byAdding: .month, value: -1, to: current.start)!
        let previous = calendar.dateInterval(of: .month, for: previousDate)!
        return periodSummary(sessions: sessions, activityId: activityId, interval: current,
                             previous: previous, placeFilter: .all, calendar: calendar)
    }

    func periodSummary(sessions: [ActivitySession], activityId: UUID, interval: DateInterval,
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
