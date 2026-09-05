import XCTest
@testable import TimeTrace

final class ActivitySessionEngineTests: XCTestCase {
    private let activityId = UUID()
    private let engine = ActivitySessionEngine()
    private let calendar = utcCalendar()

    func testEnterExitCreatesCompletedSession() {
        let events = [event(.geofenceEnter, 9), event(.geofenceExit, 18)]
        let result = engine.reconcile(events: events, existingSessions: [], now: date(day: 1, hour: 19))
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions[0].status, .completed)
        XCTAssertEqual(result.sessions[0].duration, 9 * 3600)
    }

    func testMultipleSessionsInOneDay() {
        let events = [event(.geofenceEnter, 9), event(.geofenceExit, 12),
                      event(.geofenceEnter, 13), event(.geofenceExit, 19)]
        let result = engine.reconcile(events: events, existingSessions: [], now: date(day: 1, hour: 20))
        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertEqual(result.sessions.compactMap(\.duration).reduce(0, +), 9 * 3600)
    }

    func testRepeatedEnterIsRedundant() {
        let first = event(.geofenceEnter, 9)
        let duplicate = event(.geofenceEnter, 9, minute: 1)
        let result = engine.reconcile(events: [first, duplicate], existingSessions: [], now: date(day: 1, hour: 10))
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(duplicate.disposition, .redundant)
    }

    func testRepeatedExitDoesNotCreateSession() {
        let secondExit = event(.geofenceExit, 18, minute: 1)
        let result = engine.reconcile(events: [event(.geofenceEnter, 9), event(.geofenceExit, 18), secondExit],
                                      existingSessions: [], now: date(day: 1, hour: 19))
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(secondExit.disposition, .orphaned)
    }

    func testExitWithoutEnterIsOrphaned() {
        let exit = event(.geofenceExit, 18)
        let result = engine.reconcile(events: [exit], existingSessions: [], now: date(day: 1, hour: 19))
        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertEqual(exit.disposition, .orphaned)
    }

    func testCrossDaySessionIsNotSplit() {
        let start = event(.geofenceEnter, 22)
        let end = ActivityEvent(activityId: activityId, eventType: .geofenceExit,
                                timestamp: date(day: 2, hour: 2), source: .coreLocation)
        let result = engine.reconcile(events: [start, end], existingSessions: [], now: date(day: 2, hour: 3))
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions[0].duration, 4 * 3600)
    }

    func testMissingExitRemainsActiveBefore24Hours() {
        let result = engine.reconcile(events: [event(.geofenceEnter, 9)], existingSessions: [],
                                      now: date(day: 2, hour: 8))
        XCTAssertEqual(result.sessions[0].status, .active)
        XCTAssertNil(result.sessions[0].endAt)
    }

    func testMissingExitBecomesIncompleteAfter24Hours() {
        let result = engine.reconcile(events: [event(.geofenceEnter, 9)], existingSessions: [],
                                      now: date(day: 2, hour: 10))
        XCTAssertEqual(result.sessions[0].status, .incomplete)
        XCTAssertNil(result.sessions[0].endAt)
    }

    func testNonWorkPlaceCanRemainActiveAcrossMultipleDays() {
        let home = ActivityEvent(
            activityId: activityId,
            eventType: .geofenceEnter,
            timestamp: date(day: 1, hour: 9),
            source: .coreLocation,
            metadata: EventMetadata(values: ["placeType": PlaceType.home.rawValue])
        )
        let result = engine.reconcile(events: [home], existingSessions: [], now: date(day: 4, hour: 10))
        XCTAssertEqual(result.sessions[0].status, .active)
        XCTAssertNil(result.sessions[0].endAt)
    }

    func testExitAfter24HoursIsOrphanedAndDoesNotInventAnEnd() {
        let start = event(.geofenceEnter, 9)
        let lateExit = ActivityEvent(activityId: activityId, eventType: .geofenceExit,
                                     timestamp: date(day: 2, hour: 10), source: .coreLocation)
        let result = engine.reconcile(events: [start, lateExit], existingSessions: [],
                                      now: date(day: 2, hour: 11))
        XCTAssertEqual(result.sessions[0].status, .incomplete)
        XCTAssertNil(result.sessions[0].endAt)
        XCTAssertEqual(lateExit.disposition, .orphaned)
    }

    func testManualSessionIsManuallyAdjusted() {
        let result = engine.reconcile(events: [event(.manualStart, 10, source: .user),
                                               event(.manualStop, 11, source: .user)],
                                      existingSessions: [], now: date(day: 1, hour: 12))
        XCTAssertEqual(result.sessions[0].status, .manuallyAdjusted)
        XCTAssertEqual(result.sessions[0].duration, 3600)
    }

    func testOutOfOrderEventsAreSorted() {
        let exit = event(.geofenceExit, 18)
        let enter = event(.geofenceEnter, 9)
        let result = engine.reconcile(events: [exit, enter], existingSessions: [], now: date(day: 1, hour: 19))
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions[0].status, .completed)
    }

    func testReprocessingSameEventsIsIdempotent() {
        let events = [event(.geofenceEnter, 9), event(.geofenceExit, 18)]
        let first = engine.reconcile(events: events, existingSessions: [], now: date(day: 1, hour: 19))
        let second = engine.reconcile(events: events, existingSessions: first.sessions, now: date(day: 1, hour: 19))
        XCTAssertEqual(second.sessions.count, 1)
        XCTAssertTrue(second.createdSessions.isEmpty)
    }

    func testDeletedSessionIsNotRecreated() {
        let start = event(.geofenceEnter, 9)
        let end = event(.geofenceExit, 18)
        let deleted = ActivitySession(activityId: activityId, startAt: start.timestamp, endAt: end.timestamp,
                                      status: .completed, startEventId: start.id, endEventId: end.id,
                                      deletedAt: date(day: 2, hour: 1))
        let result = engine.reconcile(events: [start, end], existingSessions: [deleted], now: date(day: 2, hour: 2))
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertTrue(result.createdSessions.isEmpty)
        XCTAssertNotNil(result.sessions[0].deletedAt)
    }

    func testAdjustmentEventDrivesTheExistingSessionProjection() {
        let start = event(.geofenceEnter, 9)
        let end = event(.geofenceExit, 18)
        let original = engine.reconcile(events: [start, end], existingSessions: [], now: date(day: 1, hour: 19)).sessions
        let session = original[0]
        let adjustedStart = date(day: 1, hour: 8, minute: 30)
        let adjustedEnd = date(day: 1, hour: 17, minute: 30)
        let adjustment = ActivityEvent(
            activityId: activityId,
            eventType: .sessionAdjusted,
            timestamp: date(day: 1, hour: 20),
            source: .user,
            metadata: EventMetadata(values: [
                "sessionId": session.id.uuidString,
                "startEventId": start.id.uuidString,
                "newStart": adjustedStart.ISO8601Format(),
                "newEnd": adjustedEnd.ISO8601Format()
            ])
        )

        let replayed = engine.reconcile(events: [start, end, adjustment], existingSessions: original,
                                        now: date(day: 1, hour: 20)).sessions[0]
        XCTAssertEqual(replayed.startAt, adjustedStart)
        XCTAssertEqual(replayed.endAt, adjustedEnd)
        XCTAssertEqual(replayed.status, .manuallyAdjusted)
        XCTAssertEqual(adjustment.disposition, .applied)
    }

    private func event(_ type: ActivityEventType, _ hour: Int, minute: Int = 0,
                       source: ActivityEventSource = .coreLocation) -> ActivityEvent {
        ActivityEvent(activityId: activityId, eventType: type,
                      timestamp: date(day: 1, hour: hour, minute: minute), source: source)
    }

    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }
}

func utcCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    calendar.firstWeekday = 2
    return calendar
}
