import CoreLocation
import SwiftData
import XCTest
@testable import TimeTrace

@MainActor
final class RepositoryTests: XCTestCase {
    func testVisibleTimeFormattingUsesSimplifiedChinese() {
        XCTAssertEqual(TimeTraceFormat.duration(8 * 3_600 + 5 * 60), "8小时 5分钟")
        XCTAssertEqual(TimeTraceLocalization.locale.language.languageCode?.identifier, "zh")
        XCTAssertEqual(TimeTraceLocalization.locale.language.script?.identifier, "Hans")
    }

    func testMainlandChinaMapCoordinateRoundTripKeepsSystemGeofenceCoordinate() {
        let systemCoordinate = CLLocationCoordinate2D(latitude: 31.2304, longitude: 121.4737)
        let mapCoordinate = ChinaMapCoordinateConverter.mapCoordinate(fromSystemCoordinate: systemCoordinate)

        XCTAssertGreaterThan(abs(mapCoordinate.latitude - systemCoordinate.latitude), 0.001)
        XCTAssertGreaterThan(abs(mapCoordinate.longitude - systemCoordinate.longitude), 0.001)

        let roundTrip = ChinaMapCoordinateConverter.systemCoordinate(fromMapCoordinate: mapCoordinate)
        XCTAssertEqual(roundTrip.latitude, systemCoordinate.latitude, accuracy: 0.000001)
        XCTAssertEqual(roundTrip.longitude, systemCoordinate.longitude, accuracy: 0.000001)
    }

    func testMapCoordinateOutsideMainlandChinaIsUnchanged() {
        let london = CLLocationCoordinate2D(latitude: 51.5074, longitude: -0.1278)
        let mapped = ChinaMapCoordinateConverter.mapCoordinate(fromSystemCoordinate: london)
        XCTAssertEqual(mapped.latitude, london.latitude)
        XCTAssertEqual(mapped.longitude, london.longitude)
    }

    func testEventAppendIsIdempotentAndPersistsDisposition() throws {
        let persistence = try PersistenceController(inMemory: true)
        let repository = SwiftDataActivityEventRepository(context: persistence.context)
        let event = ActivityEvent(activityId: UUID(), eventType: .geofenceEnter,
                                  timestamp: Date(), source: .coreLocation)
        XCTAssertTrue(try repository.append(event))
        XCTAssertFalse(try repository.append(event))
        event.disposition = .applied
        try repository.saveProcessingChanges()
        XCTAssertEqual(try repository.fetchAll().count, 1)
        XCTAssertEqual(try repository.fetchAll()[0].disposition, .applied)
    }

    func testPipelineSurvivesRepositoryReload() throws {
        let persistence = try PersistenceController(inMemory: true)
        let events = SwiftDataActivityEventRepository(context: persistence.context)
        let sessions = SwiftDataActivitySessionRepository(context: persistence.context)
        let pipeline = EventPipeline(events: events, sessions: sessions)
        let activityId = UUID()
        let start = Date(timeIntervalSince1970: 1_000)
        _ = try pipeline.ingest(ActivityEvent(activityId: activityId, eventType: .geofenceEnter,
                                              timestamp: start, source: .coreLocation), now: start)
        _ = try pipeline.ingest(ActivityEvent(activityId: activityId, eventType: .geofenceExit,
                                              timestamp: start.addingTimeInterval(3600), source: .coreLocation),
                                now: start.addingTimeInterval(3600))
        XCTAssertEqual(try sessions.fetch(activityId: activityId).first?.duration, 3600)
    }

    func testFakeGeofenceCallbacksUseTheEventPipelineAndSendNotifications() async throws {
        let geofence = FakeGeofenceService()
        let notifications = FakeNotificationService()
        let model = AppModel(inMemory: true, geofence: geofence, notifications: notifications)
        model.load()
        model.finishOnboarding(latitude: 31.2, longitude: 121.4, radius: 200,
                               weekdaysMask: 0b0111110, normalStartMinute: 540, normalEndMinute: 1080,
                               placeName: "创意园")
        let triggerId = try XCTUnwrap(model.workTrigger?.id)
        let start = Date().addingTimeInterval(-3600)
        geofence.emit(.entered(triggerId: triggerId, timestamp: start))
        geofence.emit(.exited(triggerId: triggerId, timestamp: start.addingTimeInterval(1800)))
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.sessions[0].status, .completed)
        XCTAssertEqual(model.sessions[0].duration, 1800)
        XCTAssertEqual(model.sessions[0].placeTriggerId, triggerId)
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(notifications.geofenceTransitions.map(\.transition), [.entered, .exited])
        XCTAssertEqual(notifications.geofenceTransitions.map(\.activityName), ["工作", "工作"])
        XCTAssertEqual(notifications.geofenceTransitions.map(\.placeName), ["创意园", "创意园"])
    }

    func testOrphanedExitCanBeRepairedWithManualArrival() throws {
        let geofence = FakeGeofenceService()
        let model = AppModel(inMemory: true, geofence: geofence,
                             notifications: FakeNotificationService())
        model.load()
        model.finishOnboarding(latitude: 31.2, longitude: 121.4, radius: 200,
                               weekdaysMask: 0b0111110, normalStartMinute: nil, normalEndMinute: nil)
        let triggerId = try XCTUnwrap(model.workTrigger?.id)
        let exit = Date().addingTimeInterval(-1800)
        geofence.emit(.exited(triggerId: triggerId, timestamp: exit))
        let event = try XCTUnwrap(model.orphanedWorkExitEvents.first)

        let start = exit.addingTimeInterval(-3600)
        model.repairOrphanedExit(event, startAt: start)

        XCTAssertTrue(model.orphanedWorkExitEvents.isEmpty)
        let session = try XCTUnwrap(model.sessions.first)
        XCTAssertEqual(session.startAt, start)
        XCTAssertEqual(session.endAt, exit)
        XCTAssertEqual(session.status, .manuallyAdjusted)
    }

    func testCanAddMultipleWorkplaces() throws {
        let geofence = FakeGeofenceService()
        let model = AppModel(inMemory: true, geofence: geofence, notifications: FakeNotificationService())
        model.load()
        model.finishOnboarding(latitude: 31.2, longitude: 121.4, radius: 200,
                               weekdaysMask: 0b0111110, normalStartMinute: nil, normalEndMinute: nil,
                               placeName: "办公室")
        model.addWorkplace(
            latitude: 31.21, longitude: 121.41, radius: 150,
            placeName: "客户现场", placeType: .study
        )

        XCTAssertEqual(model.workTriggers.map(\.displayPlaceName), ["办公室", "客户现场"])
        XCTAssertEqual(model.workTriggers.map(\.placeType), [.work, .study])
        XCTAssertEqual(Set(geofence.registeredTriggerIds).count, 2)
    }

    func testDeletingWorkplaceStopsItsGeofenceAndRemovesIt() throws {
        let geofence = FakeGeofenceService()
        let model = AppModel(inMemory: true, geofence: geofence, notifications: FakeNotificationService())
        model.load()
        model.finishOnboarding(latitude: 31.2, longitude: 121.4, radius: 200,
                               weekdaysMask: 0b0111110, normalStartMinute: nil, normalEndMinute: nil)
        let trigger = try XCTUnwrap(model.workTrigger)

        model.deleteWorkplace(trigger)

        XCTAssertTrue(model.workTriggers.isEmpty)
        XCTAssertEqual(geofence.removedTriggerIds, [trigger.id])
    }

    func testOrphanedExitCanBeDismissedWithoutDeletingOriginalEvent() throws {
        let geofence = FakeGeofenceService()
        let model = AppModel(inMemory: true, geofence: geofence,
                             notifications: FakeNotificationService())
        model.load()
        model.finishOnboarding(latitude: 31.2, longitude: 121.4, radius: 200,
                               weekdaysMask: 0b0111110, normalStartMinute: nil, normalEndMinute: nil)
        let triggerId = try XCTUnwrap(model.workTrigger?.id)
        geofence.emit(.exited(triggerId: triggerId, timestamp: Date()))
        let event = try XCTUnwrap(model.orphanedWorkExitEvents.first)

        model.dismissOrphanedEvent(event)

        XCTAssertTrue(model.orphanedWorkExitEvents.isEmpty)
        XCTAssertTrue(model.events.contains { $0.id == event.id })
        XCTAssertTrue(model.events.contains { $0.eventType == .anomalyDismissed })
    }

    func testLocationAuthorizationChangesArePublished() throws {
        let geofence = FakeGeofenceService()
        geofence.authorizationStatus = .authorizedWhenInUse
        let model = AppModel(inMemory: true, geofence: geofence,
                             notifications: FakeNotificationService())

        XCTAssertEqual(model.locationAuthorizationStatus, .authorizedWhenInUse)
        geofence.setAuthorizationStatus(.authorizedAlways)
        XCTAssertEqual(model.locationAuthorizationStatus, .authorizedAlways)
    }

    func testThirtyDayDemoDataPopulatesHistoryWithoutDuplicates() throws {
        let geofence = FakeGeofenceService()
        let model = AppModel(inMemory: true, geofence: geofence,
                             notifications: FakeNotificationService())
        model.load()
        model.finishOnboarding(latitude: 31.2, longitude: 121.4, radius: 200,
                               weekdaysMask: 0b0111110, normalStartMinute: 540, normalEndMinute: 1080)
        let now = try XCTUnwrap(
            Calendar.current.date(from: DateComponents(year: 2026, month: 9, day: 4,
                                                       hour: 22, minute: 30))
        )

        let insertedDays = try XCTUnwrap(model.generateThirtyDayDemoData(endingAt: now))
        XCTAssertGreaterThanOrEqual(insertedDays, 20)
        XCTAssertEqual(model.generateThirtyDayDemoData(endingAt: now), 0)

        let start = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: -29,
                                                        to: Calendar.current.startOfDay(for: now)))
        let end = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1,
                                                      to: Calendar.current.startOfDay(for: now)))
        let summaries = model.dailySummaries(interval: DateInterval(start: start, end: end))
        XCTAssertEqual(summaries.count, insertedDays)
        XCTAssertTrue(summaries.contains(where: { $0.sessionCount > 1 }))
        XCTAssertTrue(summaries.contains(where: \.isIncomplete))

        let demoPlaces = model.workTriggers.filter(\.isDemoData)
        XCTAssertEqual(Set(demoPlaces.map(\.placeType)), Set(PlaceType.allCases))
        XCTAssertEqual(geofence.registeredTriggerIds.count, 1, "示例地点不应注册为真实地理围栏")

        let placeByID = Dictionary(uniqueKeysWithValues: demoPlaces.map { ($0.id, $0.placeType) })
        let recordedTypes = Set(model.sessions.compactMap { session in
            session.placeTriggerId.flatMap { placeByID[$0] }
        })
        XCTAssertEqual(recordedTypes, Set(PlaceType.allCases))

        func starts(for type: PlaceType) -> [Date] {
            model.sessions.compactMap { session in
                guard let id = session.placeTriggerId, placeByID[id] == type else { return nil }
                return session.startAt
            }
        }
        XCTAssertTrue(starts(for: .exercise).allSatisfy { Calendar.current.component(.hour, from: $0) == 7 })
        XCTAssertTrue(starts(for: .dining).allSatisfy { Calendar.current.component(.hour, from: $0) == 12 })
        XCTAssertTrue(starts(for: .study).allSatisfy { Calendar.current.component(.hour, from: $0) == 19 })
        XCTAssertTrue(starts(for: .shopping).allSatisfy { Calendar.current.component(.hour, from: $0) == 14 })
        XCTAssertTrue(starts(for: .healthcare).allSatisfy { Calendar.current.component(.hour, from: $0) == 10 })
        XCTAssertTrue(starts(for: .leisure).allSatisfy { Calendar.current.component(.hour, from: $0) == 19 })
        XCTAssertTrue(starts(for: .home).allSatisfy { Calendar.current.component(.hour, from: $0) == 19 })
        XCTAssertTrue(starts(for: .other).allSatisfy { Calendar.current.component(.hour, from: $0) == 14 })

        XCTAssertGreaterThan(model.clearThirtyDayDemoData(), 0)
        XCTAssertFalse(model.workTriggers.contains(where: \.isDemoData))
        XCTAssertFalse(model.events.contains { $0.metadata.values["demoData"] == "thirtyDay" })
    }

    func testNotificationStartCreatesSessionAndCompletionClosesLoop() async throws {
        let geofence = FakeGeofenceService()
        let notifications = FakeNotificationService()
        let model = AppModel(inMemory: true, geofence: geofence, notifications: notifications)
        model.load()
        model.finishOnboarding(latitude: 31.2, longitude: 121.4, radius: 200,
                               weekdaysMask: 0b0111110, normalStartMinute: nil, normalEndMinute: nil)
        await model.createReminder(name: "英语", type: .study, time: Date(), weekdaysMask: 0b1111111)
        let reminder = try XCTUnwrap(model.reminders.first)
        notifications.emit(.start(definitionId: reminder.id, requestId: "test-start"))
        let instance = try XCTUnwrap(model.activeReminderInstances.first)
        XCTAssertNotNil(instance.sessionId)
        model.finishReminderInstance(instance, abandoned: false)
        XCTAssertEqual(instance.status, .completed)
        XCTAssertNotNil(model.session(for: instance)?.endAt)
    }

    func testNotificationTapDuringColdLaunchWaitsForDataLoad() async throws {
        let geofence = FakeGeofenceService()
        let notifications = FakeNotificationService()
        let model = AppModel(inMemory: true, geofence: geofence, notifications: notifications)
        model.finishOnboarding(latitude: 31.2, longitude: 121.4, radius: 200,
                               weekdaysMask: 0b0111110, normalStartMinute: nil, normalEndMinute: nil)
        await model.createReminder(name: "冷启动提醒", type: .study, time: Date(), weekdaysMask: 0b1111111)
        let reminder = try XCTUnwrap(model.reminders.first)

        notifications.emit(.start(definitionId: reminder.id, requestId: "cold-launch-start"))
        XCTAssertTrue(model.activeReminderInstances.isEmpty)

        model.load()
        XCTAssertEqual(model.activeReminderInstances.count, 1)
        XCTAssertNotNil(model.activeReminderInstances.first?.sessionId)
    }

    func testNotificationSnoozeUsesTenMinuteServicePath() async throws {
        let notifications = FakeNotificationService()
        let model = AppModel(inMemory: true, geofence: FakeGeofenceService(), notifications: notifications)
        model.load()
        model.finishOnboarding(latitude: 31.2, longitude: 121.4, radius: 200,
                               weekdaysMask: 0b0111110, normalStartMinute: nil, normalEndMinute: nil)
        await model.createReminder(name: "阅读", type: .study, time: Date(), weekdaysMask: 0b1111111)
        let reminder = try XCTUnwrap(model.reminders.first)
        notifications.emit(.snooze(definitionId: reminder.id, requestId: "test-snooze"))
        await Task.yield()
        await Task.yield()
        XCTAssertEqual(notifications.snoozedDefinitionIds, [reminder.id])
        XCTAssertEqual(model.reminderInstances.first?.status, .snoozed)
    }

    func testManualCorrectionAndSoftDeletion() throws {
        let model = AppModel(inMemory: true, geofence: FakeGeofenceService(),
                             notifications: FakeNotificationService())
        model.load()
        model.finishOnboarding(latitude: 31.2, longitude: 121.4, radius: 200,
                               weekdaysMask: 0b0111110, normalStartMinute: nil, normalEndMinute: nil)
        let start = Date().addingTimeInterval(-7200)
        model.addManualSession(startAt: start, endAt: start.addingTimeInterval(3600))
        let session = try XCTUnwrap(model.sessions.first)
        let correctedEnd = start.addingTimeInterval(5400)
        model.adjustSession(session, startAt: start, endAt: correctedEnd)
        XCTAssertEqual(session.status, .manuallyAdjusted)
        XCTAssertEqual(session.duration, 5400)
        model.deleteSession(session)
        XCTAssertTrue(model.sessions.isEmpty)
        XCTAssertNotNil(session.deletedAt)
    }
}

@MainActor
private final class FakeGeofenceService: GeofenceServicing {
    var authorizationStatus: CLAuthorizationStatus = .authorizedAlways
    var accuracyAuthorization: CLAccuracyAuthorization = .fullAccuracy
    var lastHorizontalAccuracy: CLLocationAccuracy? = 10
    var onEvent: ((GeofenceSystemEvent) -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?
    private(set) var registeredTriggerIds: [UUID] = []
    private(set) var removedTriggerIds: [UUID] = []

    func requestWhenInUseAuthorization() {}
    func requestAlwaysAuthorization() {}
    func requestCurrentLocation() async throws -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 31.2, longitude: 121.4)
    }
    func register(triggerId: UUID, latitude: Double, longitude: Double, radius: Double) throws -> Double {
        registeredTriggerIds.append(triggerId)
        return radius
    }
    func remove(triggerId: UUID) { removedTriggerIds.append(triggerId) }
    func restoreAndRequestState(triggerId: UUID, latitude: Double, longitude: Double, radius: Double) {}
    func emit(_ event: GeofenceSystemEvent) { onEvent?(event) }
    func setAuthorizationStatus(_ status: CLAuthorizationStatus) {
        authorizationStatus = status
        onAuthorizationChange?(status)
    }
}

@MainActor
private final class FakeNotificationService: NotificationServicing {
    var onAction: ((ReminderNotificationAction) -> Void)?
    private(set) var scheduledDefinitionIds: [UUID] = []
    private(set) var snoozedDefinitionIds: [UUID] = []
    private(set) var geofenceTransitions: [(transition: GeofenceNotificationTransition, activityName: String, placeName: String)] = []

    func registerCategories() {}
    func requestAuthorization() async throws -> Bool { true }
    func schedule(_ reminder: ReminderDefinition) async throws { scheduledDefinitionIds.append(reminder.id) }
    func cancel(_ reminder: ReminderDefinition) {}
    func snooze(definitionId: UUID, name: String) async throws { snoozedDefinitionIds.append(definitionId) }
    func notifyGeofenceTransition(_ transition: GeofenceNotificationTransition,
                                  activityName: String,
                                  placeName: String) async throws {
        geofenceTransitions.append((transition, activityName, placeName))
    }
    func emit(_ action: ReminderNotificationAction) { onAction?(action) }
}
