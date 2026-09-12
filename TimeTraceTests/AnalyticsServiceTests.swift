import XCTest
import SwiftUI
import CoreImage
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

    func testPeriodSummaryCanFilterToOnePlaceOrUnmarkedSessions() {
        let office = UUID()
        let clientSite = UUID()
        let values = [
            ActivitySession(activityId: activityId, placeTriggerId: office, startAt: date(day: 1, hour: 9), endAt: date(day: 1, hour: 17), status: .completed),
            ActivitySession(activityId: activityId, placeTriggerId: clientSite, startAt: date(day: 2, hour: 9), endAt: date(day: 2, hour: 15), status: .completed),
            ActivitySession(activityId: activityId, startAt: date(day: 3, hour: 10), endAt: date(day: 3, hour: 14), status: .completed)
        ]
        let period = interval(day: 1, length: 3)
        let previous = interval(day: -2, length: 3)

        let officeSummary = service.periodSummary(
            sessions: values, activityId: activityId, interval: period, previous: previous,
            placeFilter: .place(office), calendar: calendar
        )
        let unmarkedSummary = service.periodSummary(
            sessions: values, activityId: activityId, interval: period, previous: previous,
            placeFilter: .place(nil), calendar: calendar
        )

        XCTAssertEqual(officeSummary.totalWorkDuration, 8 * 3600)
        XCTAssertEqual(unmarkedSummary.totalWorkDuration, 4 * 3600)
    }

    func testTodayWorkDurationExcludesEveryNonWorkPlace() {
        let places = PlaceType.allCases.map {
            ActivityTrigger(activityId: activityId, type: .geofence, placeType: $0)
        }
        let values = places.map { place in
            ActivitySession(activityId: activityId, placeTriggerId: place.id,
                            startAt: date(day: 1, hour: 0),
                            endAt: date(day: 1, hour: 0).addingTimeInterval(place.placeType == .work ? 720 : 36360),
                            status: .completed)
        }
        let summary = TodayWorkSummary(sessions: values, places: places, workActivityIDs: [activityId])
        XCTAssertEqual(summary.duration(now: date(day: 1, hour: 12)), 720)
        XCTAssertEqual(summary.sessions.count, 1)
    }

    func testTodayHomeTenHoursSixMinutesAndOfficeTwelveMinutes() {
        let home = ActivityTrigger(activityId: activityId, type: .geofence, placeType: .home)
        let office = ActivityTrigger(activityId: activityId, type: .geofence, placeType: .work)
        let start = date(day: 1, hour: 0)
        let arrival = start.addingTimeInterval(606 * 60)
        let now = arrival.addingTimeInterval(12 * 60)
        let homeSession = ActivitySession(activityId: activityId, placeTriggerId: home.id,
                                          startAt: start, endAt: arrival, status: .completed)
        let officeSession = ActivitySession(activityId: activityId, placeTriggerId: office.id,
                                            startAt: arrival, endAt: now, status: .completed)
        for active in [false, true] {
            officeSession.endAt = active ? nil : now
            officeSession.status = active ? .active : .completed
            let daily = service.dailySummaries(sessions: [homeSession, officeSession], activityId: activityId,
                                                interval: interval(day: 1, length: 1), calendar: calendar)[0]
            let summary = TodayWorkSummary(sessions: daily.sessions, places: [home, office], workActivityIDs: [activityId])
            XCTAssertEqual(summary.duration(now: now), 720)
            XCTAssertEqual(summary.firstArrivalTime, arrival)
            XCTAssertEqual(daily.sessions.count, 2, "时间线仍保留居家和公司记录")
        }
        homeSession.endAt = nil
        homeSession.status = .active
        XCTAssertEqual(TodayWorkSummary(sessions: [homeSession], places: [home], workActivityIDs: [activityId])
            .duration(now: now), 0)
    }

    func testHeroSwitchesToHomeTotalAndKeepsTicking() {
        let home = ActivityTrigger(activityId: activityId, type: .geofence, placeType: .home)
        let office = ActivityTrigger(activityId: activityId, type: .geofence, placeType: .work)
        let officeSession = ActivitySession(activityId: activityId, placeTriggerId: office.id,
            startAt: date(day: 1, hour: 9), endAt: date(day: 1, hour: 17), status: .completed)
        let earlierHome = ActivitySession(activityId: activityId, placeTriggerId: home.id,
            startAt: date(day: 1, hour: 0), endAt: date(day: 1, hour: 8), status: .completed)
        let activeHome = ActivitySession(activityId: activityId, placeTriggerId: home.id,
            startAt: date(day: 1, hour: 18), status: .active)
        let now = date(day: 1, hour: 19)
        let values = [officeSession, earlierHome, activeHome]
        let summary = TodayHeroSummary(sessions: values, places: [home, office],
            workActivityIDs: [activityId], now: now, calendar: calendar)
        let later = TodayHeroSummary(sessions: values, places: [home, office],
            workActivityIDs: [activityId], now: now.addingTimeInterval(1), calendar: calendar)
        XCTAssertEqual(summary.activeSession?.id, activeHome.id)
        XCTAssertEqual(summary.label, "今日累计居住时长")
        XCTAssertEqual(summary.systemImage, "house.fill")
        XCTAssertEqual(summary.duration, 9 * 3600)
        XCTAssertEqual(later.duration - summary.duration, 1)
        activeHome.endAt = now
        activeHome.status = .completed
        let idle = TodayHeroSummary(sessions: values, places: [home, office],
            workActivityIDs: [activityId], now: now, calendar: calendar)
        XCTAssertEqual(idle.label, "今日累计工作时长")
        XCTAssertEqual(idle.systemImage, "location.fill")
        XCTAssertEqual(idle.duration, 8 * 3600)
        let nextDay = TodayHeroSummary(sessions: values, places: [home, office],
            workActivityIDs: [activityId], now: date(day: 2, hour: 8), calendar: calendar)
        XCTAssertEqual(nextDay.duration, 0)
    }

    func testTodayIconsMatchPlaceTypeAcrossHeroAndTimeline() {
        // All geofences share the work activity; the icon must follow the place type.
        let places = PlaceType.allCases.map {
            ActivityTrigger(activityId: activityId, type: .geofence, placeType: $0)
        }
        for place in places {
            let current = ActivitySession(activityId: activityId, placeTriggerId: place.id,
                startAt: date(day: 1, hour: 9), status: .active)
            let summary = TodayHeroSummary(sessions: [current], places: places,
                workActivityIDs: [activityId], now: date(day: 1, hour: 10), calendar: calendar)
            XCTAssertEqual(summary.systemImage, place.placeType.systemImage)
            XCTAssertEqual(TodayPlacePresentation.systemImage(for: current, places: places),
                           summary.systemImage)
            current.endAt = date(day: 1, hour: 10)
            current.status = .completed
            XCTAssertEqual(TodayPlacePresentation.systemImage(for: current, places: places),
                           place.placeType.systemImage, "已结束记录仍显示自身地点类型")
        }
    }

    func testTodayUnknownAndManualPlacesUseNeutralIcon() {
        for placeID in [nil, UUID()] as [UUID?] {
            let current = ActivitySession(activityId: activityId, placeTriggerId: placeID,
                startAt: date(day: 1, hour: 9), status: .active)
            let unrelatedOffice = ActivityTrigger(activityId: activityId, type: .geofence, placeType: .work)
            let places = [unrelatedOffice]
            let summary = TodayHeroSummary(sessions: [current], places: places,
                workActivityIDs: [activityId], now: date(day: 1, hour: 10), calendar: calendar)
            XCTAssertEqual(summary.systemImage, "location.fill")
            XCTAssertEqual(TodayPlacePresentation.systemImage(for: current, places: places), "location.fill")
        }
    }

    func testHeroClipsOvernightHomeToToday() {
        let home = ActivityTrigger(activityId: activityId, type: .geofence, placeType: .home)
        let overnight = ActivitySession(activityId: activityId, placeTriggerId: home.id,
            startAt: date(day: 1, hour: 22), status: .active)
        let summary = TodayHeroSummary(sessions: [overnight], places: [home],
            workActivityIDs: [activityId], now: date(day: 2, hour: 8), calendar: calendar)
        XCTAssertEqual(summary.duration, 8 * 3600)
        XCTAssertEqual(summary.activeSession?.id, overnight.id)
    }

    func testTodayManualWorkAndMissingPlaceClassification() {
        let manualWork = session(day: 1, start: 9, end: 10)
        let study = ActivitySession(activityId: UUID(), startAt: date(day: 1, hour: 9),
                                    endAt: date(day: 1, hour: 12), status: .completed)
        let missingPlace = ActivitySession(activityId: activityId, placeTriggerId: UUID(),
                                           startAt: date(day: 1, hour: 9), endAt: date(day: 1, hour: 12), status: .completed)
        let incomplete = ActivitySession(activityId: activityId, startAt: date(day: 1, hour: 10), status: .incomplete)
        let deleted = session(day: 1, start: 10, end: 11)
        deleted.deletedAt = date(day: 1, hour: 12)
        let values = [manualWork, study, missingPlace, incomplete, deleted]
        let summary = TodayWorkSummary(sessions: values, places: [], workActivityIDs: [activityId])
        XCTAssertEqual(summary.duration(now: date(day: 1, hour: 12)), 3600)
        XCTAssertTrue(TodayWorkSummary(sessions: values, places: [], workActivityIDs: []).sessions.isEmpty)
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

@MainActor
final class TimeJournalServiceTests: XCTestCase {
    private let service = TimeJournalService()
    private let activityID = UUID()
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private func date(_ day: Int, _ hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }
    private func record(_ day: Int, hours: Int = 2, place: UUID? = nil) -> ActivitySession {
        ActivitySession(activityId: activityID, placeTriggerId: place, startAt: date(day, 9),
                        endAt: date(day, 9 + hours), status: .completed)
    }
    private func journal(_ records: [ActivitySession], places: [ActivityTrigger] = [],
                         filter: PlaceSessionFilter = .all, now: Date? = nil) -> TimeJournal {
        service.make(sessions: records, places: places,
            interval: DateInterval(start: date(7), end: date(14)),
            previous: DateInterval(start: date(0), end: date(7)), filter: filter,
            calendar: calendar, now: now ?? date(14))
    }
    func testEmptyAndSparseRecordsDoNotInventPatterns() {
        let empty = journal([])
        XCTAssertFalse(empty.canShare)
        XCTAssertTrue(empty.findings.isEmpty)
        let sparse = journal([record(7)])
        XCTAssertTrue(sparse.canShare)
        XCTAssertEqual(sparse.findings.map(\.kind), [.memorable])
    }
    func testComparableProgressExcludesTodayAndFutureDates() {
        let records = [record(0), record(1), record(2), record(3, hours: 12),
                       record(7, hours: 4), record(8, hours: 4), record(9, hours: 4),
                       record(10, hours: 1), record(11, hours: 12)]
        let result = journal(records, now: date(10, 18))
        let comparison = result.findings.first { $0.kind == .comparison }
        XCTAssertNotNil(comparison)
        XCTAssertEqual(comparison?.records.count, 6)
        XCTAssertEqual(result.totalDuration, 13 * 3600)
        XCTAssertEqual(result.recordedDays, 4)
        XCTAssertTrue(comparison?.detail.contains("多记录了 6 小时") == true)
    }
    func testIncompleteInEitherPeriodSuppressesComparison() {
        let records = [0, 1, 2].map { record($0) } + [7, 8, 9].map { record($0, hours: 4) }
        for day in [1, 9, 10] {
            let open = ActivitySession(activityId: activityID, startAt: date(day, 15), status: .incomplete)
            XCTAssertFalse(journal(records + [open], now: date(10, 18)).findings.contains { $0.kind == .comparison })
        }
        XCTAssertEqual(journal(records).findings.first?.kind, .comparison)
    }
    func testThresholdAndMinimumDays() {
        let small = [0, 1, 2].map { record($0, hours: 8) } + [7, 8, 9].map { record($0, hours: 9) }
        XCTAssertFalse(journal(small).findings.contains { $0.kind == .comparison })
        XCTAssertFalse(journal([record(0), record(1), record(7, hours: 8), record(8, hours: 8)])
            .findings.contains { $0.kind == .comparison })
    }
    func testRecurringPlaceRequiresDistinctDaysAndFilterIsConsistent() {
        let place = ActivityTrigger(activityId: activityID, type: .geofence, placeName: "私密图书馆", placeType: .study)
        let second = UUID()
        let records = [7, 8, 9].map { record($0, place: place.id) } + [record(7, place: second)]
        let result = journal(records, places: [place], filter: .place(place.id))
        XCTAssertEqual(result.recordCount, 3)
        XCTAssertEqual(result.findings.first?.kind, .recurring)
        XCTAssertTrue(result.findings.first?.detail.contains("学习记录") == true)
        XCTAssertFalse(result.insightBody.contains(place.displayPlaceName))
        XCTAssertFalse(result.privateScope.contains(place.displayPlaceName))
        XCTAssertEqual(result.scope, place.displayPlaceName)
        XCTAssertTrue(result.findings.flatMap(\.records).allSatisfy { $0.placeID == place.id })
        let sameDay = journal([record(7, place: place.id), record(7, place: place.id), record(7, place: place.id)], places: [place])
        XCTAssertFalse(sameDay.findings.contains { $0.kind == .recurring })
    }
    func testDeletedUnmarkedAndBoundaryRecords() {
        let deleted = record(8); deleted.deletedAt = date(9)
        let crossing = ActivitySession(activityId: activityID, startAt: date(7, 23), endAt: date(8, 2), status: .completed)
        let result = journal([record(14), deleted, crossing, record(9, place: UUID())])
        XCTAssertEqual(result.recordCount, 2)
        XCTAssertEqual(result.totalDuration, 5 * 3600)
        XCTAssertEqual(journal([crossing]).totalDuration, 3 * 3600)
        XCTAssertEqual(journal([crossing], filter: .place(nil)).recordCount, 1)
        XCTAssertTrue(result.findings.flatMap(\.records).contains { $0.placeName == "未标记地点" })
    }
    func testSnapshotDoesNotChangeAfterRecordEdit() {
        let record = record(7)
        let before = journal([record])
        record.endAt = date(7, 15)
        let after = journal([record])
        XCTAssertEqual(before.totalDuration, 2 * 3600)
        XCTAssertEqual(after.totalDuration, 6 * 3600)
        XCTAssertEqual(after, journal([record]))
    }
    func testExportCanRetryAfterWriteFailure() throws {
        let result = journal([record(7)])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let url = directory.appendingPathComponent("journal.png")
        XCTAssertThrowsError(try JournalPosterRenderer.write(journal: result, showPlaceName: false, to: url))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try JournalPosterRenderer.write(journal: result, showPlaceName: false, to: url)
        XCTAssertNotNil(UIImage(data: try Data(contentsOf: url)))
        XCTAssertEqual(result, journal([result.findings[0].records[0]].map { value in
            ActivitySession(id: value.id, activityId: activityID, startAt: value.start, endAt: value.end, status: .completed)
        }))
    }

    func testAnalyticsAndJournalUseSameExclusiveEnd() {
        let values = [record(7), record(14)]
        let range = DateInterval(start: date(7), end: date(14))
        XCTAssertEqual(AnalyticsService().dailySummaries(sessions: values, activityId: nil,
            interval: range, calendar: calendar).flatMap(\.sessions).count, 1)
        XCTAssertEqual(AnalyticsService().placeSummaries(sessions: values, activityId: nil,
            interval: range).first?.sessionCount, 1)
        XCTAssertEqual(journal(values).recordCount, 1)
    }

    func testTypeFilterAggregatesMatchingPlacesAcrossBothPeriods() {
        let library = ActivityTrigger(activityId: activityID, type: .geofence, placeName: "图书馆", placeType: .study)
        let classroom = ActivityTrigger(activityId: activityID, type: .geofence, placeName: "教室", placeType: .study)
        let office = ActivityTrigger(activityId: activityID, type: .geofence, placeName: "办公室", placeType: .work)
        let places = [library, classroom, office]
        let records = [record(7, hours: 2, place: library.id), record(8, hours: 3, place: classroom.id),
                       record(7, hours: 8, place: office.id), record(9), record(9, place: UUID()),
                       record(1, hours: 1, place: library.id), record(2, hours: 2, place: classroom.id)]
        let filter = PlaceSessionFilter.forType(.study, places: places)
        let result = journal(records, places: places, filter: filter)
        XCTAssertEqual(result.scope, "学习")
        XCTAssertEqual(result.privateScope, "学习记录")
        XCTAssertEqual(result.recordCount, 2)
        XCTAssertEqual(result.totalDuration, 5 * 3600)
        let analytics = AnalyticsService()
        let current = DateInterval(start: date(7), end: date(14))
        let previous = DateInterval(start: date(0), end: date(7))
        let summary = analytics.periodSummary(sessions: records, activityId: nil, interval: current,
            previous: previous, placeFilter: filter, calendar: calendar)
        XCTAssertEqual(summary.totalWorkDuration, result.totalDuration)
        let older = analytics.periodSummary(sessions: records, activityId: nil, interval: previous,
            previous: DateInterval(start: date(-7), end: date(0)), placeFilter: filter, calendar: calendar)
        XCTAssertEqual(older.totalWorkDuration, 3 * 3600)
        XCTAssertEqual(journal(records, places: places).recordCount, 5)
        let empty = journal(records, places: places, filter: .forType(.exercise, places: places))
        XCTAssertEqual(empty.recordCount, 0)
        XCTAssertFalse(empty.canShare)
    }

    func testPosterDimensionsAndVisualFixtures() throws {
        let place = ActivityTrigger(activityId: activityID, type: .geofence,
            placeName: "一个很长的私人地点名称用于检查分享排版是否越界", placeType: .study)
        let values = [7, 8, 9].map { record($0, place: place.id) }
        let result = journal(values, places: [place], filter: .place(place.id))
        let data = try JournalPosterRenderer.png(journal: result, showPlaceName: false)
        let image = try XCTUnwrap(UIImage(data: data)?.cgImage)
        XCTAssertEqual(image.width, 1080)
        XCTAssertEqual(image.height, 1920)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("journal-visual-check", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("poster.png"))
        for (name, width, size, scheme) in [
            ("screen", 353.0, DynamicTypeSize.large, ColorScheme.light),
            ("small", 335.0, DynamicTypeSize.large, ColorScheme.light),
            ("dark", 353.0, DynamicTypeSize.large, ColorScheme.dark),
            ("accessible", 335.0, DynamicTypeSize.accessibility3, ColorScheme.light)
        ] {
            let renderer = ImageRenderer(content: PeriodInsightCard(journal: result, copy: nil) {}
                .frame(width: width).environment(\.dynamicTypeSize, size).environment(\.colorScheme, scheme))
            renderer.scale = 2
            let png = try XCTUnwrap(renderer.uiImage?.pngData())
            try png.write(to: directory.appendingPathComponent("\(name).png"))
        }
        let longCopy = PeriodInsightCopy(factID: "layout-fixture",
            title: "这段留给自己的时间让平凡日子慢慢有了值得回看的痕迹",
            body: "忙碌之间也有属于自己的片刻，走过的日常被一段段记下，回头看看，那些认真度过的时间一直都在这里。")
        let longPoster = try JournalPosterRenderer.png(journal: result, insightCopy: longCopy,
                                                       showPlaceName: true)
        try longPoster.write(to: directory.appendingPathComponent("poster-long.png"))
        let longImage = try XCTUnwrap(UIImage(data: longPoster)?.cgImage)
        for bitmap in [image, longImage] {
            let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
            let payloads = detector.features(in: CIImage(cgImage: bitmap))
                .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            XCTAssertEqual(payloads, [JournalDownloadCode.url])
        }

        // The fixed header and brand must survive subsequent renders and longer copy.
        func inkPixels(_ bitmap: CGImage, in rect: CGRect) throws -> Int {
            let crop = try XCTUnwrap(bitmap.cropping(to: rect))
            let context = try XCTUnwrap(CGContext(data: nil, width: crop.width, height: crop.height,
                bitsPerComponent: 8, bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            let bytes = try XCTUnwrap(context.data).assumingMemoryBound(to: UInt8.self)
            return stride(from: 0, to: crop.width * crop.height * 4, by: 4).filter {
                Int(bytes[$0]) + Int(bytes[$0 + 1]) + Int(bytes[$0 + 2]) < 450
            }.count
        }
        for region in [CGRect(x: 78, y: 220, width: 800, height: 195),
                       CGRect(x: 78, y: 1480, width: 550, height: 280)] {
            let expected = try inkPixels(image, in: region)
            XCTAssertGreaterThan(expected, 1000)
            XCTAssertGreaterThanOrEqual(try inkPixels(longImage, in: region), expected * 9 / 10,
                "Long copy and repeat exports must preserve the headline and brand")
        }

        print("JOURNAL_VISUAL_PATH=\(directory.path)")
    }


}
