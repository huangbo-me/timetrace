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
        XCTAssertEqual(secondExit.disposition, .applied)
        XCTAssertEqual(result.sessions[0].endAt, secondExit.timestamp)
    }

    func testRepeatedGeofenceExitReplacesTheEndEvent() {
        let officeId = UUID()
        let enter = geofenceEvent(.geofenceEnter, placeId: officeId, hour: 9)
        let exit = geofenceEvent(.geofenceExit, placeId: officeId, hour: 18)
        let duplicateExit = ActivityEvent(
            activityId: activityId,
            eventType: .geofenceExit,
            timestamp: exit.timestamp.addingTimeInterval(1),
            source: .coreLocation,
            metadata: EventMetadata(values: ["placeTriggerId": officeId.uuidString])
        )

        let result = engine.reconcile(
            events: [enter, exit, duplicateExit],
            existingSessions: [],
            now: date(day: 1, hour: 19)
        )

        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions.first?.endEventId, duplicateExit.id)
        XCTAssertEqual(result.sessions.first?.endAt, duplicateExit.timestamp)
        XCTAssertEqual(exit.disposition, .redundant)
        XCTAssertEqual(duplicateExit.disposition, .applied)
    }

    func testConsecutiveGeofenceEventsUseFirstEntryAndLastExitWithoutTimeWindow() {
        let place = UUID()
        let first = geofenceEvent(.geofenceEnter, placeId: place, hour: 8)
        let repeated = geofenceEvent(.geofenceEnter, placeId: place, hour: 9)
        let exit = geofenceEvent(.geofenceExit, placeId: place, hour: 10)
        let last = geofenceEvent(.geofenceExit, placeId: place, hour: 13)
        let next = geofenceEvent(.geofenceEnter, placeId: place, hour: 14)
        let nextExit = geofenceEvent(.geofenceExit, placeId: place, hour: 16)
        let events = [first, repeated, exit, last, next, nextExit]
        var sessions: [ActivitySession] = []
        for index in events.indices {
            sessions = engine.reconcile(events: Array(events.prefix(index + 1)), existingSessions: sessions,
                                        now: events[index].timestamp).sessions
        }
        XCTAssertEqual(sessions.count, 2)
        XCTAssertEqual(sessions.first { $0.startEventId == first.id }?.startAt, first.timestamp)
        XCTAssertEqual(sessions.first { $0.startEventId == first.id }?.endAt, last.timestamp)
        XCTAssertEqual(sessions.first { $0.startEventId == first.id }?.duration, 5 * 3600)
        XCTAssertEqual(repeated.disposition, .redundant)
        XCTAssertEqual(exit.disposition, .redundant)
        let replay = engine.reconcile(events: events.reversed(), existingSessions: sessions,
                                      now: date(day: 1, hour: 17))
        XCTAssertEqual(replay.sessions.count, 2)
        XCTAssertEqual(replay.sessions.first { $0.startEventId == first.id }?.endEventId, last.id)
    }

    func testRepeatedEntryAcrossDaysKeepsFirstEntry() {
        let place = UUID()
        let first = geofenceEvent(.geofenceEnter, placeId: place, hour: 8)
        let repeated = geofenceEvent(.geofenceEnter, placeId: place, hour: 9)
        repeated.timestamp = date(day: 2, hour: 9)
        let exit = geofenceEvent(.geofenceExit, placeId: place, hour: 10)
        exit.timestamp = date(day: 2, hour: 10)
        let result = engine.reconcile(events: [first, repeated, exit], existingSessions: [], now: exit.timestamp)
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.sessions.first?.startAt, first.timestamp)
        XCTAssertEqual(result.sessions.first?.endAt, exit.timestamp)
        XCTAssertEqual(repeated.disposition, .redundant)
    }

    func testLaterExitDoesNotOverwriteManualCorrection() {
        let place = UUID()
        let first = geofenceEvent(.geofenceEnter, placeId: place, hour: 8)
        let exit = geofenceEvent(.geofenceExit, placeId: place, hour: 10)
        let original = engine.reconcile(events: [first, exit], existingSessions: [], now: exit.timestamp)
        let session = original.sessions[0]
        let correction = adjustment(session, start: first.timestamp, end: date(day: 1, hour: 9), hour: 11)
        let repeated = geofenceEvent(.geofenceExit, placeId: place, hour: 12)
        let events = [first, exit, correction, repeated]
        for _ in 0..<2 {
            _ = engine.reconcile(events: events, existingSessions: original.sessions, now: repeated.timestamp)
            XCTAssertEqual(session.endAt, date(day: 1, hour: 9))
            XCTAssertEqual(repeated.disposition, .redundant)
        }
    }

    func testEachGeofencePairsOnlyWithItsOwnExit() {
        let homeId = UUID()
        let officeId = UUID()
        let homeEnter = geofenceEvent(.geofenceEnter, placeId: homeId, hour: 8)
        let officeEnter = geofenceEvent(.geofenceEnter, placeId: officeId, hour: 9)
        let homeExit = geofenceEvent(.geofenceExit, placeId: homeId, hour: 9, minute: 5)
        let officeExit = geofenceEvent(.geofenceExit, placeId: officeId, hour: 18)

        let result = engine.reconcile(
            events: [homeEnter, officeEnter, homeExit, officeExit],
            existingSessions: [],
            now: date(day: 1, hour: 19)
        )

        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertEqual(result.sessions.first { $0.placeTriggerId == homeId }?.endEventId, homeExit.id)
        XCTAssertEqual(result.sessions.first { $0.placeTriggerId == officeId }?.endEventId, officeExit.id)
        XCTAssertEqual(officeEnter.disposition, .applied)
        XCTAssertEqual(officeExit.disposition, .applied)
    }

    func testExitAfterMonitoringBeginsInsideDoesNotAskForAnInventedArrival() {
        let homeId = UUID()
        let initialExit = geofenceEvent(
            .geofenceExit,
            placeId: homeId,
            hour: 8,
            metadata: ["monitoringBeganInside": "true"]
        )

        let result = engine.reconcile(events: [initialExit], existingSessions: [], now: date(day: 1, hour: 9))

        XCTAssertTrue(result.sessions.isEmpty)
        XCTAssertEqual(initialExit.disposition, .redundant)
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

    func testWorkGeofenceRemainsActiveAfter24HoursUntilExit() {
        let place = UUID()
        let start = geofenceEvent(
            .geofenceEnter,
            placeId: place,
            hour: 9,
            metadata: ["placeType": PlaceType.work.rawValue]
        )
        let result = engine.reconcile(events: [start], existingSessions: [],
                                      now: date(day: 2, hour: 10))
        XCTAssertEqual(result.sessions[0].status, .active)
        XCTAssertNil(result.sessions[0].endAt)
    }

    func testManualSessionBecomesIncompleteAfter24Hours() {
        let result = engine.reconcile(events: [event(.manualStart, 9, source: .user)], existingSessions: [],
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

    func testExitAfter24HoursClosesTheOriginalEntry() {
        let start = event(.geofenceEnter, 9)
        let lateExit = ActivityEvent(activityId: activityId, eventType: .geofenceExit,
                                     timestamp: date(day: 2, hour: 10), source: .coreLocation)
        let result = engine.reconcile(events: [start, lateExit], existingSessions: [],
                                      now: date(day: 2, hour: 11))
        XCTAssertEqual(result.sessions[0].status, .completed)
        XCTAssertEqual(result.sessions[0].endAt, lateExit.timestamp)
        XCTAssertEqual(lateExit.disposition, .applied)
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

    func testManuallyClosedOpenSessionDoesNotSwallowNextVisit() {
        let place = UUID()
        let start = geofenceEvent(.geofenceEnter, placeId: place, hour: 9)
        let original = engine.reconcile(events: [start], existingSessions: [], now: date(day: 1, hour: 10))
        let session = original.sessions[0]
        let correction = adjustment(session, start: start.timestamp, end: date(day: 1, hour: 11), hour: 12)
        _ = engine.reconcile(events: [start, correction], existingSessions: original.sessions, now: date(day: 1, hour: 12))
        let nextStart = geofenceEvent(.geofenceEnter, placeId: place, hour: 13)
        let nextEnd = geofenceEvent(.geofenceExit, placeId: place, hour: 14)
        let result = engine.reconcile(events: [start, correction, nextStart, nextEnd], existingSessions: original.sessions,
                                      now: date(day: 1, hour: 15))
        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertEqual(result.sessions.first { $0.startEventId == nextStart.id }?.endAt, nextEnd.timestamp)
        XCTAssertEqual(nextStart.disposition, .applied)
    }

    func testEditingOpenStartDoesNotEraseLaterExitOnRepeatedReplay() {
        let start = event(.geofenceEnter, 9)
        var sessions = engine.reconcile(events: [start], existingSessions: [], now: date(day: 1, hour: 10)).sessions
        let newStart = date(day: 1, hour: 8)
        let correction = adjustment(sessions[0], start: newStart, end: nil, hour: 10)
        sessions = engine.reconcile(events: [start, correction], existingSessions: sessions, now: date(day: 1, hour: 10)).sessions
        let end = event(.geofenceExit, 18)
        for _ in 0..<3 {
            sessions = engine.reconcile(events: [start, correction, end], existingSessions: sessions,
                                        now: date(day: 1, hour: 19)).sessions
            XCTAssertEqual(sessions[0].startAt, newStart)
            XCTAssertEqual(sessions[0].endAt, end.timestamp)
            XCTAssertEqual(sessions[0].duration, 10 * 3600)
        }
    }

    func testDuplicateCloudProjectionsAreCollapsedAndCorrectionSurvives() {
        let start = event(.geofenceEnter, 9)
        let end = event(.geofenceExit, 18)
        let first = ActivitySession(activityId: activityId, startAt: start.timestamp,
                                    endAt: end.timestamp, startEventId: start.id, endEventId: end.id)
        let duplicate = ActivitySession(activityId: activityId, startAt: start.timestamp,
                                        endAt: end.timestamp, startEventId: start.id, endEventId: end.id)
        let correction = adjustment(duplicate, start: date(day: 1, hour: 8), end: end.timestamp, hour: 19)
        let result = engine.reconcile(events: [start, end, correction], existingSessions: [first, duplicate],
                                      now: date(day: 1, hour: 20))
        XCTAssertEqual(result.sessions.count, 1)
        XCTAssertEqual(result.supersededSessions.count, 1)
        XCTAssertEqual(result.sessions[0].duration, 10 * 3600)
        XCTAssertEqual(correction.disposition, .applied)
        XCTAssertTrue(result.createdSessions.isEmpty)
    }

    func testIndependentReplaysUseTheSameSessionIdentity() {
        let start = event(.geofenceEnter, 9)
        let a = engine.reconcile(events: [start], existingSessions: [], now: date(day: 1, hour: 10))
        let b = engine.reconcile(events: [start], existingSessions: [], now: date(day: 1, hour: 10))
        XCTAssertEqual(a.sessions[0].id, b.sessions[0].id)
    }

    func testClosedCorrectionSurvivesFullRebuildWithoutBlockingNextVisit() {
        let start = event(.geofenceEnter, 9)
        let session = ActivitySession(activityId: activityId, startAt: start.timestamp, startEventId: start.id)
        let correction = adjustment(session, start: start.timestamp, end: date(day: 1, hour: 11), hour: 12)
        let nextStart = event(.geofenceEnter, 13)
        let nextEnd = event(.geofenceExit, 14)
        let result = engine.reconcile(events: [start, correction, nextStart, nextEnd], existingSessions: [],
                                      now: date(day: 1, hour: 15))
        XCTAssertEqual(result.sessions.count, 2)
        XCTAssertEqual(result.sessions.first { $0.startEventId == start.id }?.endAt, date(day: 1, hour: 11))
        XCTAssertEqual(result.sessions.first { $0.startEventId == nextStart.id }?.endAt, nextEnd.timestamp)
    }

    func testRebuiltCorrectionConsumesOriginalExitWithoutAnOrphan() {
        let start = event(.geofenceEnter, 9)
        let end = event(.geofenceExit, 18)
        let session = ActivitySession(activityId: activityId, startAt: start.timestamp, startEventId: start.id)
        let correction = adjustment(session, start: start.timestamp, end: date(day: 1, hour: 17), hour: 19)
        let result = engine.reconcile(events: [start, end, correction], existingSessions: [], now: date(day: 1, hour: 20))
        XCTAssertEqual(result.sessions[0].endAt, date(day: 1, hour: 17))
        XCTAssertEqual(result.sessions[0].endEventId, end.id)
        XCTAssertEqual(end.disposition, .applied)
    }

    func testWorkScheduleRevisionDoesNotAdjustSessionBoundariesOrOriginStatus() {
        let placeID = UUID()
        let start = geofenceEvent(.geofenceEnter, placeId: placeID, hour: 9)
        let end = geofenceEvent(.geofenceExit, placeId: placeID, hour: 18)
        let initial = engine.reconcile(events: [start, end], existingSessions: [],
                                       now: date(day: 1, hour: 19)).sessions[0]
        var metadata = EventMetadata(values: [
            "adjustmentKind": WorkScheduleSnapshot.adjustmentKind,
            "sessionId": initial.id.uuidString,
            "startEventId": start.id.uuidString,
            "newStart": initial.startAt.ISO8601Format(),
            "newEnd": initial.endAt!.ISO8601Format()
        ])
        metadata = WorkScheduleSnapshot(
            weekdaysMask: 0b0111110, startMinute: 9 * 60, endMinute: 18 * 60,
            timeZoneIdentifier: "UTC", isEnabled: true
        )!.adding(to: metadata)
        let revision = ActivityEvent(activityId: activityId, eventType: .sessionAdjusted,
                                     timestamp: date(day: 1, hour: 20), source: .user,
                                     metadata: metadata)
        let result = engine.reconcile(events: [start, end, revision], existingSessions: [initial],
                                      now: date(day: 1, hour: 21)).sessions[0]
        XCTAssertEqual(result.startAt, start.timestamp)
        XCTAssertEqual(result.endAt, end.timestamp)
        XCTAssertEqual(result.status, .completed)
        XCTAssertEqual(revision.disposition, .applied)
    }

    func testScheduleRevisionRepairsOldClientManualStatusWithoutHidingRealCorrection() {
        let placeID = UUID()
        let start = geofenceEvent(.geofenceEnter, placeId: placeID, hour: 9)
        let end = geofenceEvent(.geofenceExit, placeId: placeID, hour: 18)
        let projected = engine.reconcile(events: [start, end], existingSessions: [],
                                         now: date(day: 1, hour: 19)).sessions[0]
        projected.status = .manuallyAdjusted // An old client applied the schedule event as a time edit.
        var metadata = EventMetadata(values: [
            "adjustmentKind": WorkScheduleSnapshot.adjustmentKind,
            "sessionId": projected.id.uuidString,
            "startEventId": start.id.uuidString,
            "newStart": projected.startAt.ISO8601Format(),
            "newEnd": projected.endAt!.ISO8601Format()
        ])
        metadata = WorkScheduleSnapshot(
            weekdaysMask: 0b0111110, startMinute: 9 * 60, endMinute: 18 * 60,
            timeZoneIdentifier: "UTC", isEnabled: true
        )!.adding(to: metadata)
        let scheduleRevision = ActivityEvent(
            activityId: activityId, eventType: .sessionAdjusted,
            timestamp: date(day: 1, hour: 20), source: .user, metadata: metadata
        )
        let repaired = engine.reconcile(events: [start, end, scheduleRevision],
                                        existingSessions: [projected],
                                        now: date(day: 1, hour: 21)).sessions[0]
        XCTAssertEqual(repaired.status, .completed)

        let realCorrection = adjustment(repaired, start: date(day: 1, hour: 8),
                                        end: end.timestamp, hour: 22)
        let genuinelyAdjusted = engine.reconcile(
            events: [start, end, scheduleRevision, realCorrection],
            existingSessions: [repaired], now: date(day: 1, hour: 23)
        ).sessions[0]
        XCTAssertEqual(genuinelyAdjusted.status, .manuallyAdjusted)
        XCTAssertEqual(genuinelyAdjusted.startAt, date(day: 1, hour: 8))
    }

    private func adjustment(_ session: ActivitySession, start: Date, end: Date?, hour: Int) -> ActivityEvent {
        ActivityEvent(activityId: activityId, eventType: .sessionAdjusted, timestamp: date(day: 1, hour: hour),
                      source: .user, metadata: EventMetadata(values: [
                        "sessionId": session.id.uuidString,
                        "startEventId": session.startEventId!.uuidString,
                        "newStart": start.ISO8601Format(), "newEnd": end?.ISO8601Format() ?? ""
                      ]))
    }

    private func event(_ type: ActivityEventType, _ hour: Int, minute: Int = 0,
                       source: ActivityEventSource = .coreLocation) -> ActivityEvent {
        ActivityEvent(activityId: activityId, eventType: type,
                      timestamp: date(day: 1, hour: hour, minute: minute), source: source)
    }

    private func geofenceEvent(_ type: ActivityEventType, placeId: UUID, hour: Int, minute: Int = 0,
                                metadata: [String: String] = [:]) -> ActivityEvent {
        var values = metadata
        values["placeTriggerId"] = placeId.uuidString
        return ActivityEvent(
            activityId: activityId,
            eventType: type,
            timestamp: date(day: 1, hour: hour, minute: minute),
            source: .coreLocation,
            metadata: EventMetadata(values: values)
        )
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
