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
        XCTAssertEqual(summary.label, "本次在家时长")
        XCTAssertEqual(summary.systemImage, "house.fill")
        XCTAssertEqual(summary.duration, 1 * 3600)
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

    func testHeroKeepsOvernightHomeVisitContinuous() {
        let home = ActivityTrigger(activityId: activityId, type: .geofence, placeType: .home)
        let overnight = ActivitySession(activityId: activityId, placeTriggerId: home.id,
            startAt: date(day: 1, hour: 22), status: .active)
        let summary = TodayHeroSummary(sessions: [overnight], places: [home],
            workActivityIDs: [activityId], now: date(day: 2, hour: 8), calendar: calendar)
        XCTAssertEqual(summary.duration, 10 * 3600)
        XCTAssertEqual(summary.activeSession?.id, overnight.id)
    }

    func testHeroKeepsOvernightWorkVisitContinuous() {
        let office = ActivityTrigger(activityId: activityId, type: .geofence, placeType: .work)
        let overnight = ActivitySession(activityId: activityId, placeTriggerId: office.id,
            startAt: date(day: 1, hour: 22), status: .active)
        let summary = TodayHeroSummary(sessions: [overnight], places: [office],
            workActivityIDs: [activityId], now: date(day: 2, hour: 15), calendar: calendar)
        XCTAssertEqual(summary.label, "本次工作时长")
        XCTAssertEqual(summary.duration, 17 * 3600)
        XCTAssertEqual(summary.firstArrivalTime, overnight.startAt)
    }

    func testWorkScheduleSnapshotRoundTripsModesAndDurations() throws {
        let snapshot = try XCTUnwrap(WorkScheduleSnapshot(
            weekdaysMask: 0b0111110,
            startMinute: nil,
            endMinute: nil,
            timeZoneIdentifier: "Asia/Shanghai",
            isEnabled: true,
            calendarMode: .chinaStatutory,
            scheduleMode: .flexibleDuration,
            standardWorkMinutes: 8 * 60,
            restMinutes: 3 * 60
        ))
        let decoded = try XCTUnwrap(WorkScheduleSnapshot(metadata: snapshot.adding(to: .empty)))
        XCTAssertEqual(decoded, snapshot)
    }

    func testLegacyScheduleMetadataKeepsOldSemantics() throws {
        let metadata = EventMetadata(values: [
            "workScheduleEnabled": "true",
            "workScheduleWeekdaysMask": "62",
            "workScheduleStartMinute": "540",
            "workScheduleEndMinute": "1080",
            "workScheduleTimeZoneIdentifier": "Asia/Shanghai"
        ])
        let snapshot = try XCTUnwrap(WorkScheduleSnapshot(metadata: metadata))
        XCTAssertEqual(snapshot.calendarMode, .customWeekdays)
        XCTAssertEqual(snapshot.scheduleMode, .fixedWindow)
        XCTAssertEqual(snapshot.standardWorkMinutes, 8 * 60)
        XCTAssertEqual(snapshot.restMinutes, 0)
    }

    func testScheduleRejectsOutOfRangeStandardAndRestMinutes() {
        XCTAssertNil(WorkScheduleSnapshot(
            weekdaysMask: 62, startMinute: nil, endMinute: nil,
            timeZoneIdentifier: "Asia/Shanghai", isEnabled: true,
            calendarMode: .chinaStatutory, scheduleMode: .flexibleDuration,
            standardWorkMinutes: 0, restMinutes: 0
        ))
        XCTAssertNil(WorkScheduleSnapshot(
            weekdaysMask: 62, startMinute: 540, endMinute: 1080,
            timeZoneIdentifier: "Asia/Shanghai", isEnabled: true,
            calendarMode: .chinaStatutory, scheduleMode: .fixedWindow,
            standardWorkMinutes: 480, restMinutes: 12 * 60 + 30
        ))
        XCTAssertNil(WorkScheduleSnapshot(
            weekdaysMask: 62, startMinute: nil, endMinute: nil,
            timeZoneIdentifier: "Asia/Shanghai", isEnabled: true,
            calendarMode: .chinaStatutory, scheduleMode: .flexibleDuration,
            standardWorkMinutes: 8 * 60 + 1, restMinutes: 0
        ))
        XCTAssertNil(WorkScheduleSnapshot(
            weekdaysMask: 62, startMinute: 540, endMinute: 1080,
            timeZoneIdentifier: "Asia/Shanghai", isEnabled: true,
            calendarMode: .chinaStatutory, scheduleMode: .fixedWindow,
            standardWorkMinutes: 480, restMinutes: 60 + 1
        ))
    }

    func testFlexibleActivityTriggerProjectsEnabledSnapshotWithoutFixedTimes() throws {
        let trigger = ActivityTrigger(
            activityId: activityId,
            type: .geofence,
            weekdaysMask: 0b0111110,
            normalStartMinute: nil,
            normalEndMinute: nil,
            timeZoneIdentifier: "Asia/Shanghai",
            workCalendarMode: .chinaStatutory,
            workScheduleMode: .flexibleDuration,
            standardWorkMinutes: 8 * 60,
            restMinutes: 3 * 60
        )

        let snapshot = try XCTUnwrap(trigger.workScheduleSnapshot)
        XCTAssertTrue(snapshot.isEnabled)
        XCTAssertEqual(snapshot.scheduleMode, .flexibleDuration)
        XCTAssertNil(snapshot.startMinute)
        XCTAssertNil(snapshot.endMinute)
    }

    func testNightShiftSplitsEarlyAndLateOvertime() throws {
        let schedule = try XCTUnwrap(WorkScheduleSnapshot(
            weekdaysMask: 0b1111111, startMinute: 22 * 60, endMinute: 8 * 60,
            timeZoneIdentifier: "UTC", isEnabled: true
        ))
        let result = try XCTUnwrap(WorkScheduleCalculator.breakdown(
            from: date(day: 1, hour: 21, minute: 30),
            to: date(day: 2, hour: 15), schedule: schedule
        ))
        XCTAssertEqual(result.normalDuration, 10 * 3600, accuracy: 0.1)
        XCTAssertEqual(result.earlyOvertime, 30 * 60, accuracy: 0.1)
        XCTAssertEqual(result.lateOvertime, 7 * 3600, accuracy: 0.1)
        XCTAssertEqual(result.restDayOvertime, 0, accuracy: 0.1)
        XCTAssertEqual(result.totalOvertime, 7.5 * 3600, accuracy: 0.1)
    }

    func testStatutoryHolidayCountsEntirePresenceAsRestDayOvertime() throws {
        let schedule = try XCTUnwrap(statutoryFixedSchedule(restMinutes: 180))
        let start = localDate(year: 2026, month: 9, day: 25, hour: 10)
        let end = localDate(year: 2026, month: 9, day: 25, hour: 21)
        let result = try XCTUnwrap(WorkScheduleCalculator.breakdown(
            from: start, to: end, schedule: schedule
        ))
        XCTAssertEqual(result.restDayOvertime, 11 * 3600, accuracy: 0.1)
        XCTAssertEqual(result.normalDuration, 0, accuracy: 0.1)
    }

    func testMakeUpWeekendUsesNormalWorkdayRules() throws {
        let schedule = try XCTUnwrap(statutoryFixedSchedule(restMinutes: 60))
        let start = localDate(year: 2026, month: 9, day: 20, hour: 9)
        let end = localDate(year: 2026, month: 9, day: 20, hour: 18)
        let result = try XCTUnwrap(WorkScheduleCalculator.breakdown(
            from: start, to: end, schedule: schedule
        ))
        XCTAssertEqual(result.normalDuration, 8 * 3600, accuracy: 0.1)
        XCTAssertEqual(result.totalOvertime, 0, accuracy: 0.1)
    }

    func testFlexibleWorkdaySubtractsRestBeforeOvertime() throws {
        let schedule = try XCTUnwrap(statutoryFlexibleSchedule(
            standardMinutes: 480, restMinutes: 180
        ))
        let result = try XCTUnwrap(WorkScheduleCalculator.breakdown(
            from: localDate(year: 2026, month: 9, day: 21, hour: 10),
            to: localDate(year: 2026, month: 9, day: 21, hour: 21),
            schedule: schedule
        ))
        XCTAssertEqual(result.normalDuration, 8 * 3600, accuracy: 0.1)
        XCTAssertEqual(result.workdayOvertime, 0, accuracy: 0.1)
    }

    func testFlexibleRestDayDoesNotSubtractRest() throws {
        let schedule = try XCTUnwrap(statutoryFlexibleSchedule(
            standardMinutes: 480, restMinutes: 180
        ))
        let result = try XCTUnwrap(WorkScheduleCalculator.breakdown(
            from: localDate(year: 2026, month: 9, day: 26, hour: 10),
            to: localDate(year: 2026, month: 9, day: 26, hour: 21),
            schedule: schedule
        ))
        XCTAssertEqual(result.restDayOvertime, 11 * 3600, accuracy: 0.1)
    }

    func testFixedNightShiftUsesStartDayAndSubtractsRestOnce() throws {
        let schedule = try XCTUnwrap(WorkScheduleSnapshot(
            weekdaysMask: 0b1111111, startMinute: 22 * 60, endMinute: 8 * 60,
            timeZoneIdentifier: "Asia/Shanghai", isEnabled: true,
            calendarMode: .chinaStatutory, scheduleMode: .fixedWindow,
            standardWorkMinutes: 480, restMinutes: 60
        ))
        let result = try XCTUnwrap(WorkScheduleCalculator.breakdown(
            from: localDate(year: 2026, month: 9, day: 24, hour: 21),
            to: localDate(year: 2026, month: 9, day: 25, hour: 10),
            schedule: schedule
        ))
        XCTAssertEqual(result.earlyOvertime, 1 * 3600, accuracy: 0.1)
        XCTAssertEqual(result.normalDuration, 9 * 3600, accuracy: 0.1)
        XCTAssertEqual(result.restDayOvertime, 2 * 3600, accuracy: 0.1)
        XCTAssertEqual(result.totalOvertime, 3 * 3600, accuracy: 0.1)
    }

    func testRestDayStartedNightShiftIsEntirelyRestDayOvertime() throws {
        let schedule = try XCTUnwrap(WorkScheduleSnapshot(
            weekdaysMask: 0b1111111, startMinute: 22 * 60, endMinute: 8 * 60,
            timeZoneIdentifier: "Asia/Shanghai", isEnabled: true,
            calendarMode: .chinaStatutory, scheduleMode: .fixedWindow,
            standardWorkMinutes: 480, restMinutes: 60
        ))
        let result = try XCTUnwrap(WorkScheduleCalculator.breakdown(
            from: localDate(year: 2026, month: 9, day: 25, hour: 22),
            to: localDate(year: 2026, month: 9, day: 26, hour: 8),
            schedule: schedule
        ))
        XCTAssertEqual(result.normalDuration, 0, accuracy: 0.1)
        XCTAssertEqual(result.restDayOvertime, 10 * 3600, accuracy: 0.1)
    }

    func testFlexibleFridayToSundayAppliesEachDaysOwnRules() throws {
        let schedule = try XCTUnwrap(statutoryFlexibleSchedule(
            standardMinutes: 480, restMinutes: 180
        ))
        let result = try XCTUnwrap(WorkScheduleCalculator.breakdown(
            from: localDate(year: 2026, month: 9, day: 18, hour: 10),
            to: localDate(year: 2026, month: 9, day: 20, hour: 21),
            schedule: schedule
        ))
        XCTAssertEqual(result.normalDuration, 16 * 3600, accuracy: 0.1)
        XCTAssertEqual(result.workdayOvertime, 13 * 3600, accuracy: 0.1)
        XCTAssertEqual(result.restDayOvertime, 24 * 3600, accuracy: 0.1)
        XCTAssertEqual(result.totalOvertime, 37 * 3600, accuracy: 0.1)
    }

    func testLegacyCustomWeekdayIgnoresStatutoryHolidayTable() throws {
        let fridayOnly = 1 << (6 - 1)
        let schedule = try XCTUnwrap(WorkScheduleSnapshot(
            weekdaysMask: fridayOnly, startMinute: 9 * 60, endMinute: 18 * 60,
            timeZoneIdentifier: "Asia/Shanghai", isEnabled: true
        ))
        let result = try XCTUnwrap(WorkScheduleCalculator.breakdown(
            from: localDate(year: 2026, month: 9, day: 25, hour: 9),
            to: localDate(year: 2026, month: 9, day: 25, hour: 18),
            schedule: schedule
        ))
        XCTAssertEqual(result.normalDuration, 9 * 3600, accuracy: 0.1)
        XCTAssertEqual(result.totalOvertime, 0, accuracy: 0.1)
    }

    func testMultiDayScheduleRepeatsWithoutDoubleCounting() throws {
        let schedule = try XCTUnwrap(WorkScheduleSnapshot(
            weekdaysMask: 0b1111111, startMinute: 9 * 60, endMinute: 17 * 60,
            timeZoneIdentifier: "UTC", isEnabled: true
        ))
        let result = try XCTUnwrap(WorkScheduleCalculator.breakdown(
            from: date(day: 1, hour: 8), to: date(day: 3, hour: 18), schedule: schedule
        ))
        XCTAssertEqual(result.normalDuration, 24 * 3600, accuracy: 0.1)
        XCTAssertEqual(result.earlyOvertime, 1 * 3600, accuracy: 0.1)
        XCTAssertEqual(result.lateOvertime, 33 * 3600, accuracy: 0.1)
        XCTAssertEqual(result.restDayOvertime, 0, accuracy: 0.1)
        XCTAssertEqual(result.totalOvertime, 34 * 3600, accuracy: 0.1)
    }

    func testUnselectedDayIsEntirelyRestDayOvertime() throws {
        let mondayOnly = 1 << (2 - 1)
        let schedule = try XCTUnwrap(WorkScheduleSnapshot(
            weekdaysMask: mondayOnly, startMinute: 9 * 60, endMinute: 18 * 60,
            timeZoneIdentifier: "UTC", isEnabled: true
        ))
        // 2026-09-01 is Tuesday.
        let result = try XCTUnwrap(WorkScheduleCalculator.breakdown(
            from: date(day: 1, hour: 9), to: date(day: 1, hour: 17), schedule: schedule
        ))
        XCTAssertEqual(result.normalDuration, 0, accuracy: 0.1)
        XCTAssertEqual(result.restDayOvertime, 8 * 3600, accuracy: 0.1)
        XCTAssertEqual(result.totalOvertime, 8 * 3600, accuracy: 0.1)
    }

    func testLateArrivalAndEarlyDepartureDoNotCreateOvertime() throws {
        let schedule = try XCTUnwrap(WorkScheduleSnapshot(
            weekdaysMask: 0b1111111, startMinute: 9 * 60, endMinute: 18 * 60,
            timeZoneIdentifier: "UTC", isEnabled: true
        ))
        let result = try XCTUnwrap(WorkScheduleCalculator.breakdown(
            from: date(day: 1, hour: 10), to: date(day: 1, hour: 17), schedule: schedule
        ))
        XCTAssertEqual(result.normalDuration, 7 * 3600, accuracy: 0.1)
        XCTAssertEqual(result.totalOvertime, 0, accuracy: 0.1)
    }

    func testDayShiftUsesWallClockAcrossDSTTransitions() throws {
        let timeZoneIdentifier = "America/New_York"
        let schedule = try XCTUnwrap(WorkScheduleSnapshot(
            weekdaysMask: 0b1111111, startMinute: 9 * 60, endMinute: 18 * 60,
            timeZoneIdentifier: timeZoneIdentifier, isEnabled: true
        ))
        for (month, day) in [(3, 8), (11, 1)] {
            let start = localDate(year: 2026, month: month, day: day, hour: 9,
                                  timeZoneIdentifier: timeZoneIdentifier)
            let end = localDate(year: 2026, month: month, day: day, hour: 18,
                                timeZoneIdentifier: timeZoneIdentifier)
            let result = try XCTUnwrap(WorkScheduleCalculator.breakdown(
                from: start, to: end, schedule: schedule
            ))
            XCTAssertEqual(result.normalDuration, end.timeIntervalSince(start), accuracy: 0.1)
            XCTAssertEqual(result.totalOvertime, 0, accuracy: 0.1)
        }
    }

    func testOvernightShiftUsesWallClockAcrossDSTTransitions() throws {
        let timeZoneIdentifier = "America/New_York"
        let schedule = try XCTUnwrap(WorkScheduleSnapshot(
            weekdaysMask: 0b1111111, startMinute: 22 * 60, endMinute: 8 * 60,
            timeZoneIdentifier: timeZoneIdentifier, isEnabled: true
        ))
        for (startMonth, startDay, endMonth, endDay) in [(3, 7, 3, 8), (10, 31, 11, 1)] {
            let start = localDate(year: 2026, month: startMonth, day: startDay, hour: 22,
                                  timeZoneIdentifier: timeZoneIdentifier)
            let end = localDate(year: 2026, month: endMonth, day: endDay, hour: 8,
                                timeZoneIdentifier: timeZoneIdentifier)
            let result = try XCTUnwrap(WorkScheduleCalculator.breakdown(
                from: start, to: end, schedule: schedule
            ))
            XCTAssertEqual(result.normalDuration, end.timeIntervalSince(start), accuracy: 0.1)
            XCTAssertEqual(result.totalOvertime, 0, accuracy: 0.1)
        }
    }

    func testScheduleSnapshotRejectsUnknownTimeZone() {
        XCTAssertNil(WorkScheduleSnapshot(
            weekdaysMask: 0b1111111, startMinute: 9 * 60, endMinute: 18 * 60,
            timeZoneIdentifier: "Mars/Olympus_Mons", isEnabled: true
        ))
    }

    func testCrossDayCountUsesCalendarBoundaries() {
        XCTAssertEqual(SessionDaySpan.crossedDayCount(
            from: date(day: 1, hour: 23, minute: 30),
            to: date(day: 2, hour: 0, minute: 30), timeZoneIdentifier: "UTC"
        ), 1)
        XCTAssertEqual(SessionDaySpan.crossedDayCount(
            from: date(day: 1, hour: 1), to: date(day: 1, hour: 23),
            timeZoneIdentifier: "UTC"
        ), 0)
    }

    func testScheduleResolverPrefersRevisionThenEntryThenCurrentPlace() throws {
        let place = ActivityTrigger(activityId: activityId, type: .geofence, placeType: .work,
                                    weekdaysMask: 0b0111110, normalStartMinute: 9 * 60,
                                    normalEndMinute: 18 * 60, timeZoneIdentifier: "UTC")
        let entrySnapshot = try XCTUnwrap(WorkScheduleSnapshot(
            weekdaysMask: 0b0111110, startMinute: 10 * 60, endMinute: 19 * 60,
            timeZoneIdentifier: "UTC", isEnabled: true
        ))
        let start = ActivityEvent(activityId: activityId, eventType: .geofenceEnter,
                                  timestamp: date(day: 1, hour: 9), source: .coreLocation,
                                  metadata: entrySnapshot.adding(to: EventMetadata(values: [
                                    "placeTriggerId": place.id.uuidString
                                  ])))
        let session = ActivitySession(activityId: activityId, placeTriggerId: place.id,
                                      startAt: start.timestamp, startEventId: start.id)
        XCTAssertEqual(WorkScheduleResolver.snapshot(for: session, events: [start], currentPlace: place),
                       entrySnapshot)

        let revisedSnapshot = try XCTUnwrap(WorkScheduleSnapshot(
            weekdaysMask: 0b1111111, startMinute: 22 * 60, endMinute: 8 * 60,
            timeZoneIdentifier: "UTC", isEnabled: true
        ))
        var revisionMetadata = EventMetadata(values: [
            "adjustmentKind": WorkScheduleSnapshot.adjustmentKind,
            "sessionId": session.id.uuidString,
            "startEventId": start.id.uuidString
        ])
        revisionMetadata = revisedSnapshot.adding(to: revisionMetadata)
        let revision = ActivityEvent(activityId: activityId, eventType: .sessionAdjusted,
                                     timestamp: date(day: 2, hour: 20), source: .user,
                                     metadata: revisionMetadata)
        XCTAssertEqual(WorkScheduleResolver.snapshot(
            for: session, events: [start, revision], currentPlace: place
        ), revisedSnapshot)

        let legacy = ActivitySession(activityId: activityId, placeTriggerId: place.id,
                                     startAt: date(day: 1, hour: 9))
        XCTAssertEqual(WorkScheduleResolver.snapshot(for: legacy, events: [], currentPlace: place),
                       place.workScheduleSnapshot)
        let manual = ActivitySession(activityId: activityId, startAt: date(day: 1, hour: 9))
        XCTAssertNil(WorkScheduleResolver.snapshot(for: manual, events: [], currentPlace: place))
    }

    func testScheduleResolverDoesNotFallbackPastLatestMalformedRevision() throws {
        let place = ActivityTrigger(activityId: activityId, type: .geofence, placeType: .work,
                                    weekdaysMask: 0b0111110, normalStartMinute: 9 * 60,
                                    normalEndMinute: 18 * 60, timeZoneIdentifier: "UTC")
        let entrySnapshot = try XCTUnwrap(WorkScheduleSnapshot(
            weekdaysMask: 0b0111110, startMinute: 10 * 60, endMinute: 19 * 60,
            timeZoneIdentifier: "UTC", isEnabled: true
        ))
        let start = ActivityEvent(activityId: activityId, eventType: .geofenceEnter,
                                  timestamp: date(day: 1, hour: 9), source: .coreLocation,
                                  metadata: entrySnapshot.adding(to: EventMetadata(values: [
                                    "placeTriggerId": place.id.uuidString
                                  ])))
        let session = ActivitySession(activityId: activityId, placeTriggerId: place.id,
                                      startAt: start.timestamp, startEventId: start.id)
        let malformedRevision = ActivityEvent(
            activityId: activityId, eventType: .sessionAdjusted,
            timestamp: date(day: 2, hour: 20), source: .user,
            metadata: EventMetadata(values: [
                "adjustmentKind": WorkScheduleSnapshot.adjustmentKind,
                "sessionId": session.id.uuidString,
                "startEventId": start.id.uuidString,
                "workScheduleEnabled": "true",
                "workScheduleWeekdaysMask": "127",
                "workScheduleStartMinute": "540",
                "workScheduleEndMinute": "1080",
                "workScheduleTimeZoneIdentifier": "Mars/Olympus_Mons"
            ])
        )

        XCTAssertNil(WorkScheduleResolver.snapshot(
            for: session, events: [start, malformedRevision], currentPlace: place
        ))
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

    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func localDate(year: Int, month: Int, day: Int, hour: Int,
                           timeZoneIdentifier: String = "Asia/Shanghai") -> Date {
        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.timeZone = TimeZone(identifier: timeZoneIdentifier)!
        return localCalendar.date(from: DateComponents(
            year: year, month: month, day: day, hour: hour
        ))!
    }

    private func statutoryFixedSchedule(restMinutes: Int) -> WorkScheduleSnapshot? {
        WorkScheduleSnapshot(
            weekdaysMask: 0b1111111, startMinute: 9 * 60, endMinute: 18 * 60,
            timeZoneIdentifier: "Asia/Shanghai", isEnabled: true,
            calendarMode: .chinaStatutory, scheduleMode: .fixedWindow,
            standardWorkMinutes: 480, restMinutes: restMinutes
        )
    }

    private func statutoryFlexibleSchedule(standardMinutes: Int,
                                           restMinutes: Int) -> WorkScheduleSnapshot? {
        WorkScheduleSnapshot(
            weekdaysMask: 0b1111111, startMinute: nil, endMinute: nil,
            timeZoneIdentifier: "Asia/Shanghai", isEnabled: true,
            calendarMode: .chinaStatutory, scheduleMode: .flexibleDuration,
            standardWorkMinutes: standardMinutes, restMinutes: restMinutes
        )
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
    func testSummaryMetricsSeparateWorkAndHomeAndUseActualClockExtremes() throws {
        let work = ActivityTrigger(activityId: activityID, type: .geofence, placeType: .work)
        let home = ActivityTrigger(activityId: activityID, type: .geofence, placeType: .home)
        let records = [
            ActivitySession(activityId: activityID, placeTriggerId: work.id,
                startAt: date(7, 9), endAt: date(7, 18), status: .completed),
            ActivitySession(activityId: activityID, placeTriggerId: work.id,
                startAt: date(8, 20), endAt: date(9, 1), status: .completed),
            ActivitySession(activityId: activityID, placeTriggerId: home.id,
                startAt: date(7, 23), endAt: date(8, 6), status: .completed),
            ActivitySession(activityId: activityID, placeTriggerId: home.id,
                startAt: date(9, 20), endAt: date(10, 8), status: .completed),
            ActivitySession(activityId: activityID, placeTriggerId: home.id,
                startAt: date(11, 21), status: .active)
        ]
        let result = journal(records, places: [work, home])
        let metrics = Dictionary(uniqueKeysWithValues: result.summaryMetrics.map { ($0.title, $0.value) })
        XCTAssertEqual(metrics["已工作"], TimeJournalService.duration(14 * 3600))
        XCTAssertEqual(metrics["平均每天工作"], "7 小时")
        XCTAssertEqual(metrics["平均下班"], "21:30")
        XCTAssertEqual(metrics["在家待了"], TimeJournalService.duration(19 * 3600))
        XCTAssertEqual(metrics["最晚下班"], "9月9日 01:00")
        XCTAssertEqual(metrics["最晚到家"], "9月7日 23:00")
        XCTAssertEqual(metrics["最早离家"], "9月8日 06:00")
        XCTAssertEqual(result.unfinishedCount, 1)
        XCTAssertEqual(result.summaryEvidence?.records.count, 5)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("summary-visuals")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JournalPosterRenderer.png(journal: result, showPlaceName: false)
            .write(to: directory.appendingPathComponent("work-home-poster.png"))
        let renderer = ImageRenderer(content: PeriodInsightCard(journal: result) {}
            .frame(width: 350).environment(\.colorScheme, .light))
        renderer.scale = 2
        try XCTUnwrap(renderer.uiImage?.pngData()).write(to: directory.appendingPathComponent("work-home-card.png"))
        let layoutWork = [12, 12, 12, 13, 13].enumerated().map { index, hours in
            ActivitySession(activityId: activityID, placeTriggerId: work.id, startAt: date(7 + index, 11),
                endAt: date(7 + index, 11).addingTimeInterval(Double(hours) * 3600), status: .completed)
        }
        let layoutJournal = journal(layoutWork + records.filter { $0.placeTriggerId == home.id }, places: [work, home])
        XCTAssertEqual(layoutJournal.summaryMetrics.first { $0.title == "最晚下班" }?.value, "9月12日 00:00",
                       "相同最晚钟点选择最近日期，保证卡片与分享多次渲染一致")
        let layoutCopy = PeriodInsightCopy(factID: "layout", title: "日子的留白", body: "工作之外，也记得留一点时间给自己。")
        for (name, width, size, scheme) in [
            ("layout-light", 350.0, DynamicTypeSize.large, ColorScheme.light),
            ("layout-dark", 350.0, DynamicTypeSize.large, ColorScheme.dark),
            ("layout-accessible", 335.0, DynamicTypeSize.accessibility3, ColorScheme.light)
        ] {
            let renderer = ImageRenderer(content: PeriodInsightCard(journal: layoutJournal, copy: layoutCopy) {}
                .frame(width: width).environment(\.dynamicTypeSize, size).environment(\.colorScheme, scheme))
            renderer.scale = 2
            try XCTUnwrap(renderer.uiImage?.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
        }
        try JournalPosterRenderer.png(journal: layoutJournal, insightCopy: layoutCopy, showPlaceName: false)
            .write(to: directory.appendingPathComponent("layout-poster.png"))
        print("SUMMARY_VISUAL_PATH=\(directory.path)")
        let filtered = journal(records, places: [work, home], filter: .forType(.home, places: [work, home]))
        XCTAssertFalse(filtered.summaryMetrics.contains { $0.title == "已工作" })
        XCTAssertEqual(filtered.summaryMetrics.count, 3)
        XCTAssertFalse(journal([record(7)]).summaryMetrics.contains { $0.title == "已工作" })
    }

    func testAllTypesOverviewAndShareStayComplete() throws {
        let places = PlaceType.allCases.map {
            ActivityTrigger(activityId: activityID, type: .geofence, placeType: $0)
        }
        let records = places.enumerated().flatMap { index, place in
            (7...9).map { day in
                ActivitySession(activityId: activityID, placeTriggerId: place.id,
                    startAt: date(day, 9),
                    endAt: date(day, 9).addingTimeInterval(Double(index + 1) * 3_600 + 1_740),
                    status: .completed)
            }
        }
        let result = journal(records, places: places)
        XCTAssertEqual(result.typeSummaries.map(\.type), PlaceType.allCases)
        XCTAssertEqual(result.typeSummaries.first?.number, "4.4")
        XCTAssertEqual(result.typeSummaries.first?.detailValue, "1 小时 29 分钟")
        let work = journal(records, places: places, filter: .forType(.work, places: places))
        XCTAssertEqual(work.typeSummaries.map(\.type), [.work])
        XCTAssertEqual(work.summaryMetrics.count, 4)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("all-types-visuals")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, size) in [("all-types", DynamicTypeSize.large), ("all-types-accessible", .accessibility3)] {
            let renderer = ImageRenderer(content: PeriodInsightCard(journal: result, selectType: { _ in }) {}
                .frame(width: 350).environment(\.dynamicTypeSize, size))
            renderer.scale = 2
            try XCTUnwrap(renderer.uiImage?.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
        }
        let copy = PeriodInsightCopy(factID: "layout", title: "时间里的日常", body: "工作、休息与生活，都在这里留下了记录。")
        for (name, value) in [("all-types-poster", result), ("work-poster", work),
                               ("three-types-poster", journal(records, places: Array(places.prefix(3)),
                                filter: .all))] {
            let data = try JournalPosterRenderer.png(journal: value, insightCopy: copy, showPlaceName: false)
            try data.write(to: directory.appendingPathComponent(name + ".png"))
            let bitmap = try XCTUnwrap(UIImage(data: data)?.cgImage)
            XCTAssertEqual(bitmap.width, 1080)
            XCTAssertGreaterThan(bitmap.height, 0)
            let detector = try XCTUnwrap(CIDetector(ofType: CIDetectorTypeQRCode, context: nil,
                options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]))
            let codes = detector.features(in: CIImage(cgImage: bitmap))
                .compactMap { ($0 as? CIQRCodeFeature)?.messageString }
            XCTAssertTrue(codes.contains(JournalDownloadCode.url), "完整页脚二维码必须保留")
        }
        let active = journal([ActivitySession(activityId: activityID, placeTriggerId: places[0].id,
            startAt: date(13, 9), status: .active)], places: places)
        XCTAssertEqual(active.typeSummaries.first?.number, "—")
        XCTAssertEqual(active.typeSummaries.first?.detailValue, "等待记录结束")
        print("ALL_TYPES_VISUAL_PATH=\(directory.path)")
    }

    func testLatestHomeArrivalTreatsEarlyMorningAsTheEndOfThePreviousEvening() {
        let home = ActivityTrigger(activityId: activityID, type: .geofence, placeType: .home)
        func visit(_ day: Int, _ hour: Int, _ minute: Int = 0) -> ActivitySession {
            let start = calendar.date(byAdding: .minute, value: minute, to: date(day, hour))!
            return ActivitySession(activityId: activityID, placeTriggerId: home.id, startAt: start,
                endAt: start.addingTimeInterval(3600), status: .completed)
        }
        let visits = [visit(7, 23), visit(8, 0), visit(9, 2, 16), visit(10, 6)]
        let result = journal(visits, places: [home])
        XCTAssertEqual(result.summaryMetrics.first { $0.title == "最晚到家" }?.value, "9月9日 02:16")
        let beforeDawn = journal(visits + [visit(11, 5, 59)], places: [home])
        XCTAssertEqual(beforeDawn.summaryMetrics.first { $0.title == "最晚到家" }?.value, "9月11日 05:59")
        let midnight = journal([visit(7, 23), visit(8, 0)], places: [home])
        XCTAssertEqual(midnight.summaryMetrics.first { $0.title == "最晚到家" }?.value, "9月8日 00:00")
        // Earliest departure remains a comparison of the actual morning clock.
        XCTAssertEqual(result.summaryMetrics.first { $0.title == "最早离家" }?.value, "9月8日 00:00")
    }

    func testWorkConclusionsCombineDailyVisitsAndExcludeUnfinishedDaysFromAverages() {
        let work = ActivityTrigger(activityId: activityID, type: .geofence, placeType: .work)
        func visit(_ day: Int, _ start: Int, _ endDay: Int, _ end: Int) -> ActivitySession {
            ActivitySession(activityId: activityID, placeTriggerId: work.id,
                startAt: date(day, start), endAt: date(endDay, end), status: .completed)
        }
        let values = [visit(7, 9, 7, 12), visit(7, 13, 7, 23), visit(8, 20, 9, 1),
                      visit(9, 9, 9, 12), ActivitySession(activityId: activityID,
                        placeTriggerId: work.id, startAt: date(9, 14), status: .active)]
        let result = journal(values, places: [work], now: date(9, 16))
        let metrics = Dictionary(uniqueKeysWithValues: result.summaryMetrics.map { ($0.title, $0.value) })
        XCTAssertEqual(metrics["已工作"], "21 小时")
        XCTAssertEqual(metrics["平均每天工作"], "9 小时")
        XCTAssertEqual(metrics["最晚下班"], "9月9日 01:00")
        XCTAssertEqual(metrics["平均下班"], "次日 00:00")
        XCTAssertEqual(result.summaryParagraphs, [
            "已工作21 小时，平均每天工作9 小时。",
            "最晚在9月9日 01:00下班，平均次日 00:00下班。"
        ])
        let unfinished = journal([values.last!], places: [work], now: date(9, 16))
        XCTAssertFalse(unfinished.summaryMetrics.contains { $0.title == "平均每天工作" || $0.title == "平均下班" })
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
        XCTAssertLessThan(image.height, 1920, "单卡片分享应按内容收紧高度")
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
        XCTAssertGreaterThan(longImage.height, image.height, "长文案应自然增加海报高度")
        for (region, longRegion) in [
            (CGRect(x: 72, y: 85, width: 800, height: 105), CGRect(x: 72, y: 85, width: 800, height: 105)),
            (CGRect(x: 72, y: image.height - 240, width: 650, height: 140),
             CGRect(x: 72, y: longImage.height - 240, width: 650, height: 140))
        ] {
            let expected = try inkPixels(image, in: region)
            XCTAssertGreaterThan(expected, 1000)
            XCTAssertGreaterThanOrEqual(try inkPixels(longImage, in: longRegion), expected * 9 / 10,
                "Long copy and repeat exports must preserve the headline and brand")
        }

        let trendSummary = AnalyticsService().periodSummary(sessions: values, activityId: nil,
            interval: DateInterval(start: date(7), end: date(14)),
            previous: DateInterval(start: date(0), end: date(7)),
            placeFilter: .place(place.id), calendar: calendar)
        for metric in TrendMetric.allCases {
            let trend = JournalTrendSnapshot(summary: trendSummary, metric: metric,
                presentation: PlaceInsightPresentation(type: .study), calendar: calendar, now: date(14))
            let png = try JournalPosterRenderer.png(journal: result, insightCopy: longCopy,
                trend: trend, showPlaceName: false)
            let bitmap = try XCTUnwrap(UIImage(data: png)?.cgImage)
            XCTAssertEqual(bitmap.width, 1080)
            XCTAssertLessThan(bitmap.height, 2820, "总结与趋势之间不应撑开大块留白")
            try png.write(to: directory.appendingPathComponent("summary-trend-\(metric.rawValue).png"))
        }

        print("JOURNAL_VISUAL_PATH=\(directory.path)")
    }


}
