import XCTest
@testable import TimeTrace

final class AnalyticsServiceTests: XCTestCase {
    private let service = AnalyticsService()
    private let activityId = UUID()
    private var calendar = utcCalendar()

    func testDailySummarySumsSessionsRatherThanSpan() {
        let values = [session(day: 1, start: 9, end: 12), session(day: 1, start: 13, end: 19)]
        let result = service.dailySummaries(sessions: values, activityId: activityId,
                                            interval: interval(day: 1, length: 1), calendar: calendar)[0]
        XCTAssertEqual(result.totalDuration, 9 * 3600)
        XCTAssertEqual(result.sessionCount, 2)
        XCTAssertEqual(calendar.component(.hour, from: result.firstArrivalTime!), 9)
        XCTAssertEqual(calendar.component(.hour, from: result.lastDepartureTime!), 19)
    }

    func testCrossDaySessionBelongsToStartDay() {
        let value = ActivitySession(activityId: activityId, startAt: date(day: 1, hour: 22),
                                    endAt: date(day: 2, hour: 2), status: .completed)
        let result = service.dailySummaries(sessions: [value], activityId: activityId,
                                            interval: interval(day: 1, length: 2), calendar: calendar)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].date, date(day: 1, hour: 0))
        XCTAssertEqual(result[0].totalDuration, 4 * 3600)
    }

    func testIncompleteDayExcludedFromAverageDurationButKnownTimeInTotal() {
        let complete = session(day: 1, start: 9, end: 17)
        let partial = session(day: 2, start: 9, end: 12)
        let incomplete = ActivitySession(activityId: activityId, startAt: date(day: 2, hour: 13),
                                         status: .incomplete, confidence: .uncertain)
        let summary = service.weeklySummary(sessions: [complete, partial, incomplete], activityId: activityId,
                                            containing: date(day: 2, hour: 12), calendar: calendar)
        XCTAssertEqual(summary.totalWorkDuration, 11 * 3600)
        XCTAssertEqual(summary.averageWorkDuration, 8 * 3600)
        XCTAssertEqual(summary.incompleteDays, 1)
    }

    func testWeeklyComparison() {
        let current = session(day: 7, start: 9, end: 19)
        let previous = session(day: 0, start: 10, end: 18)
        let summary = service.weeklySummary(sessions: [current, previous], activityId: activityId,
                                            containing: date(day: 7, hour: 12), calendar: calendar)
        XCTAssertEqual(summary.comparison.workDurationChange, 2 * 3600)
        XCTAssertEqual(summary.comparison.arrivalTimeChange, -3600)
        XCTAssertEqual(summary.comparison.departureTimeChange, 3600)
    }

    func testMonthlySummaryAndEmptyComparison() {
        let value = session(day: 3, start: 9, end: 18)
        let summary = service.monthlySummary(sessions: [value], activityId: activityId,
                                             containing: date(day: 10, hour: 12), calendar: calendar)
        XCTAssertEqual(summary.workingDays, 1)
        XCTAssertEqual(summary.totalWorkDuration, 9 * 3600)
        XCTAssertNil(summary.comparison.workDurationChange)
    }

    func testMonthlyComparison() {
        let august = ActivitySession(activityId: activityId,
                                     startAt: calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 9))!,
                                     endAt: calendar.date(from: DateComponents(year: 2026, month: 8, day: 3, hour: 17))!,
                                     status: .completed)
        let september = session(day: 3, start: 9, end: 19)
        let summary = service.monthlySummary(sessions: [august, september], activityId: activityId,
                                             containing: date(day: 10, hour: 12), calendar: calendar)
        XCTAssertEqual(summary.comparison.workDurationChange, 2 * 3600)
    }

    func testDailyGroupingUsesConfiguredTimeZone() {
        var shanghai = Calendar(identifier: .gregorian)
        shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        let start = Date(timeIntervalSince1970: 1_788_280_200) // 2026-09-02 00:30 in Shanghai.
        let value = ActivitySession(activityId: activityId, startAt: start,
                                    endAt: start.addingTimeInterval(3600), status: .completed,
                                    timeZoneIdentifier: "Asia/Shanghai")
        let localDay = shanghai.startOfDay(for: start)
        let result = service.dailySummaries(
            sessions: [value], activityId: activityId,
            interval: DateInterval(start: localDay, end: shanghai.date(byAdding: .day, value: 1, to: localDay)!),
            calendar: shanghai
        )
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].date, localDay)
    }

    func testSoftDeletedSessionIsExcluded() {
        let value = session(day: 1, start: 9, end: 18)
        value.deletedAt = date(day: 2, hour: 0)
        let result = service.dailySummaries(sessions: [value], activityId: activityId,
                                            interval: interval(day: 1, length: 1), calendar: calendar)
        XCTAssertTrue(result.isEmpty)
    }

    func testPlaceSummariesGroupSessionsByPlace() {
        let office = UUID()
        let clientSite = UUID()
        let values = [
            ActivitySession(activityId: activityId, placeTriggerId: office, startAt: date(day: 1, hour: 9), endAt: date(day: 1, hour: 12), status: .completed),
            ActivitySession(activityId: activityId, placeTriggerId: office, startAt: date(day: 2, hour: 9), endAt: date(day: 2, hour: 17), status: .completed),
            ActivitySession(activityId: activityId, placeTriggerId: clientSite, startAt: date(day: 2, hour: 10), endAt: date(day: 2, hour: 16), status: .completed),
            ActivitySession(activityId: activityId, startAt: date(day: 3, hour: 9), status: .incomplete)
        ]

        let result = service.placeSummaries(sessions: values, activityId: activityId,
                                            interval: interval(day: 1, length: 3))
        XCTAssertEqual(result.map(\.placeTriggerId), [office, clientSite, nil])
        XCTAssertEqual(result.map(\.totalDuration), [11 * 3600, 6 * 3600, 0])
        XCTAssertEqual(result.last?.incompleteSessionCount, 1)
    }

    private func session(day: Int, start: Int, end: Int) -> ActivitySession {
        ActivitySession(activityId: activityId, startAt: date(day: day, hour: start),
                        endAt: date(day: day, hour: end), status: .completed)
    }

    private func interval(day: Int, length: Int) -> DateInterval {
        DateInterval(start: date(day: day, hour: 0), end: date(day: day + length, hour: 0))
    }

    private func date(day: Int, hour: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }
}
