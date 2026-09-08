import CoreLocation
import SwiftData
import XCTest
import UserNotifications
@testable import TimeTrace

@MainActor
final class RepositoryTests: XCTestCase {
    func testVisibleTimeFormattingUsesSimplifiedChinese() {
        XCTAssertEqual(TimeTraceFormat.duration(8 * 3_600 + 5 * 60), "8小时 5分钟")
        XCTAssertEqual(TimeTraceLocalization.locale.language.languageCode?.identifier, "zh")
        XCTAssertEqual(TimeTraceLocalization.locale.language.script?.identifier, "Hans")
    }

    func testWeekendNonWorkPlaceUsesActivityPresentationRatherThanOvertime() {
        XCTAssertEqual(
            TodayWorkdayRule.mode(
                isWorkday: false,
                activePlaceType: .exercise,
                hasRecordedWork: false,
                hasRecordedActivity: true
            ),
            .activeActivity
        )
    }

    func testTodayTimelineUsesThePlaceBoundToEachSession() {
        let activity = ActivityDefinition(name: "工作", type: .work)
        let home = ActivityTrigger(
            activityId: activity.id,
            type: .geofence,
            latitude: 31.2,
            longitude: 121.4,
            radius: 200,
            placeName: "梧桐湾"
        )
        let office = ActivityTrigger(
            activityId: activity.id,
            type: .geofence,
            latitude: 31.21,
            longitude: 121.41,
            radius: 200,
            placeName: "滴滴出行"
        )
        let officeSession = ActivitySession(
            activityId: activity.id,
            placeTriggerId: office.id,
            startAt: Date(timeIntervalSince1970: 1_000)
        )

        XCTAssertEqual(
            TodayPlacePresentation.name(for: officeSession, places: [home, office]),
            "滴滴出行"
        )
    }

    func testValueMapperDetachesPresentationDataFromSwiftDataRecord() {
        let activity = ActivityDefinition(name: "工作", type: .work)
        let trigger = ActivityTrigger(
            activityId: activity.id,
            type: .geofence,
            latitude: 31.2304,
            longitude: 121.4737,
            radius: 200,
            placeName: "办公室",
            placeType: .work
        )

        let value = TimelineValueMapper.place(trigger)

        XCTAssertEqual(value.id, trigger.id)
        XCTAssertEqual(value.name, "办公室")
        XCTAssertEqual(value.coordinate, CoordinateValue(latitude: 31.2304, longitude: 121.4737))
        trigger.placeName = "已修改"
        XCTAssertEqual(value.name, "办公室", "值对象不应随 SwiftData 记录突变")
    }

    func testFeatureStoresShareChangesWithoutExposingPersistenceToRoot() {
        let application = AppModel(
            inMemory: true,
            geofence: FakeGeofenceService(),
            notifications: FakeNotificationService()
        )
        let container = AppContainer(application: application)

        XCTAssertFalse(container.root.state.isLoaded)
        container.root.loadIfNeeded()
        XCTAssertTrue(container.root.state.isLoaded)
        XCTAssertEqual(container.places.state.placeCount, 0)
        XCTAssertFalse(container.today.state.isOnboarded)
    }

    func testPlatformCapabilityMapsLocationAuthorizationIndependently() {
        XCTAssertEqual(PlatformCapabilityStatus.geofence(for: .authorizedAlways), .available)
        XCTAssertEqual(PlatformCapabilityStatus.geofence(for: .notDetermined), .needsAuthorization)
        XCTAssertEqual(PlatformCapabilityStatus.geofence(for: .denied), .restricted)
    }

    func testPlaceIsPersistedWhenGeofenceRegistrationIsUnavailable() throws {
        let geofence = FakeGeofenceService()
        geofence.shouldFailRegistration = true
        let model = AppModel(inMemory: true, geofence: geofence, notifications: FakeNotificationService())

        model.load()
        model.finishOnboarding(
            latitude: 31.2,
            longitude: 121.4,
            radius: 200,
            weekdaysMask: 0b0111110,
            normalStartMinute: nil,
            normalEndMinute: nil
        )

        XCTAssertTrue(model.isOnboarded)
        XCTAssertEqual(model.workTriggers.count, 1)
        guard case .unavailable = model.geofenceCapabilityStatus else {
            return XCTFail("围栏故障应作为可恢复的能力状态公开")
        }
    }

    func testFreshCloudInstallOffersRestoreChoiceInsteadOfEnteringOnboarding() async {
        let model = AppModel(
            inMemory: true,
            geofence: FakeGeofenceService(),
            notifications: FakeNotificationService(),
            cloudKitEnabledOverride: true,
            initialCloudRestoreDelays: [0],
            cloudStatusProvider: { .enabled }
        )

        model.load()
        XCTAssertFalse(model.isRestoringICloudData)
        for _ in 0..<20 where !model.isLoaded { await Task.yield() }

        XCTAssertTrue(model.isLoaded)
        XCTAssertFalse(model.isOnboarded)
        XCTAssertTrue(model.needsInitialCloudRestoreDecision)
    }

    func testUnavailableCloudStartsNewRecordWithoutRestoring() async {
        for status: ICloudSyncStatus in [.signedOut, .notEnabled, .restricted, .unavailable] {
            let model = AppModel(inMemory: true, geofence: FakeGeofenceService(),
                                 notifications: FakeNotificationService(), cloudKitEnabledOverride: true,
                                 cloudStatusProvider: { status })
            model.load()
            for _ in 0..<20 where !model.isLoaded { await Task.yield() }
            XCTAssertTrue(model.isLoaded)
            XCTAssertFalse(model.needsInitialCloudRestoreDecision)
            XCTAssertFalse(model.isRestoringICloudData)
            XCTAssertFalse(model.isOnboarded)
        }
    }

    func testLocalInstallStartsNewRecordImmediately() {
        let model = AppModel(inMemory: true, geofence: FakeGeofenceService(),
                             notifications: FakeNotificationService(), cloudKitEnabledOverride: false)
        model.load()
        XCTAssertTrue(model.isLoaded)
        XCTAssertFalse(model.needsInitialCloudRestoreDecision)
        XCTAssertFalse(model.isRestoringICloudData)
    }

    func testCloudRestoreOnlyStartsAfterUserChoice() async {
        let model = AppModel(inMemory: true, geofence: FakeGeofenceService(),
                             notifications: FakeNotificationService(), cloudKitEnabledOverride: true,
                             initialCloudRestoreDelays: [0], cloudStatusProvider: { .enabled })
        model.load()
        for _ in 0..<20 where !model.isLoaded { await Task.yield() }
        XCTAssertTrue(model.needsInitialCloudRestoreDecision)
        XCTAssertFalse(model.isRestoringICloudData)
        model.retryInitialCloudRestore()
        XCTAssertTrue(model.isRestoringICloudData)
        XCTAssertFalse(model.isLoaded)
        for _ in 0..<20 where !model.isLoaded { await Task.yield() }
        XCTAssertTrue(model.needsInitialCloudRestoreDecision)
        model.startNewRecordAfterSkippingCloudRestore()
        XCTAssertTrue(model.isLoaded)
        XCTAssertFalse(model.needsInitialCloudRestoreDecision)
        model.refreshICloudSyncStatus()
        await Task.yield()
        XCTAssertFalse(model.needsInitialCloudRestoreDecision)
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

    func testManualEntryClosesWhenItsEventsArriveInSeparatePipelineIngestions() throws {
        let persistence = try PersistenceController(inMemory: true)
        let events = SwiftDataActivityEventRepository(context: persistence.context)
        let sessions = SwiftDataActivitySessionRepository(context: persistence.context)
        let pipeline = EventPipeline(events: events, sessions: sessions)
        let activityId = UUID()
        let start = Date(timeIntervalSince1970: 1_000)

        _ = try pipeline.ingest(
            ActivityEvent(activityId: activityId, eventType: .manualStart, timestamp: start, source: .user),
            now: start
        )
        _ = try pipeline.ingest(
            ActivityEvent(activityId: activityId, eventType: .manualStop,
                          timestamp: start.addingTimeInterval(3_600), source: .user),
            now: start.addingTimeInterval(3_600)
        )

        let session = try XCTUnwrap(try sessions.fetch(activityId: activityId).first)
        XCTAssertEqual(session.status, .manuallyAdjusted)
        XCTAssertEqual(session.duration, 3_600)
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

    func testPlaceCanBelongToAnActivityOtherThanWorkAndCanBeDisabled() async throws {
        let geofence = FakeGeofenceService()
        let notifications = FakeNotificationService()
        let model = AppModel(inMemory: true, geofence: geofence, notifications: notifications)
        model.load()
        model.finishOnboarding(latitude: 31.2, longitude: 121.4, radius: 200,
                               weekdaysMask: 0b0111110, normalStartMinute: nil, normalEndMinute: nil)
        await model.createReminder(name: "游泳", type: .exercise, time: Date(), weekdaysMask: 0b1111111)
        let exerciseId = try XCTUnwrap(model.reminders.first?.activityId)

        model.addPlace(activityId: exerciseId, latitude: 31.21, longitude: 121.41, radius: 120,
                       placeName: "泳池", placeType: .exercise)
        let pool = try XCTUnwrap(model.triggers.first { $0.activityId == exerciseId && $0.type == .geofence })
        XCTAssertEqual(pool.placeType, .exercise)
        XCTAssertTrue(geofence.registeredTriggerIds.contains(pool.id))

        model.setPlaceEnabled(triggerId: pool.id, isEnabled: false)
        XCTAssertFalse(pool.isEnabled)
        XCTAssertTrue(geofence.removedTriggerIds.contains(pool.id))
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

    func testExitFromPlaceAddedWhileAlreadyInsideDoesNotBecomeAnArrivalAnomaly() throws {
        let geofence = FakeGeofenceService()
        let model = AppModel(inMemory: true, geofence: geofence,
                             notifications: FakeNotificationService())
        model.load()
        model.finishOnboarding(latitude: 31.2, longitude: 121.4, radius: 200,
                               weekdaysMask: 0b0111110, normalStartMinute: nil, normalEndMinute: nil)
        let triggerId = try XCTUnwrap(model.workTrigger?.id)

        geofence.emitState(triggerId: triggerId, state: .inside)
        geofence.emit(.exited(triggerId: triggerId, timestamp: Date()))

        XCTAssertTrue(model.orphanedWorkExitEvents.isEmpty)
        XCTAssertEqual(model.events.last?.disposition, .redundant)
    }

    func testRefreshReprocessesLegacyImmediateDuplicateExit() throws {
        let geofence = FakeGeofenceService()
        let model = AppModel(inMemory: true, geofence: geofence,
                             notifications: FakeNotificationService())
        model.load()
        model.finishOnboarding(latitude: 31.2, longitude: 121.4, radius: 200,
                               weekdaysMask: 0b0111110, normalStartMinute: nil, normalEndMinute: nil,
                               placeName: "家")
        model.addWorkplace(latitude: 31.3, longitude: 121.5, radius: 200,
                           placeName: "公司", placeType: .work)
        let officeId = try XCTUnwrap(model.workTriggers.first { $0.displayPlaceName == "公司" }?.id)
        let arrival = Date().addingTimeInterval(-3_600)
        let departure = Date().addingTimeInterval(-1_800)
        geofence.emit(.entered(triggerId: officeId, timestamp: arrival))
        geofence.emit(.exited(triggerId: officeId, timestamp: departure))
        geofence.emit(.exited(triggerId: officeId, timestamp: departure.addingTimeInterval(1)))
        let duplicate = try XCTUnwrap(model.events.last)
        // Simulate data recorded by a pre-fix release.
        duplicate.disposition = .orphaned

        model.refreshSyncedData()

        XCTAssertEqual(duplicate.disposition, .redundant)
        XCTAssertTrue(model.orphanedWorkExitEvents.isEmpty)
    }

    func testPublishingDataNormalizesLegacyDuplicateExitAfterCloudMerge() throws {
        let geofence = FakeGeofenceService()
        let model = AppModel(inMemory: true, geofence: geofence,
                             notifications: FakeNotificationService())
        model.load()
        model.finishOnboarding(latitude: 31.2, longitude: 121.4, radius: 200,
                               weekdaysMask: 0b0111110, normalStartMinute: nil, normalEndMinute: nil)
        let triggerId = try XCTUnwrap(model.workTrigger?.id)
        let arrival = Date().addingTimeInterval(-3_600)
        let departure = Date().addingTimeInterval(-1_800)
        geofence.emit(.entered(triggerId: triggerId, timestamp: arrival))
        geofence.emit(.exited(triggerId: triggerId, timestamp: departure))
        geofence.emit(.exited(triggerId: triggerId, timestamp: departure.addingTimeInterval(1)))
        let duplicate = try XCTUnwrap(model.events.last)
        duplicate.disposition = .orphaned

        model.refreshSyncedData()

        XCTAssertEqual(duplicate.disposition, .redundant)
        XCTAssertTrue(model.orphanedWorkExitEvents.isEmpty)
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

    func testReminderSchedulingIsReconciledWhenTheApplicationBecomesActive() async throws {
        let notifications = FakeNotificationService()
        let model = AppModel(inMemory: true, geofence: FakeGeofenceService(), notifications: notifications)
        model.load()
        model.finishOnboarding(latitude: 31.2, longitude: 121.4, radius: 200,
                               weekdaysMask: 0b0111110, normalStartMinute: nil, normalEndMinute: nil)
        await model.createReminder(name: "拉伸", type: .exercise, time: Date(), weekdaysMask: 0b1111111)
        let reminder = try XCTUnwrap(model.reminders.first)

        await model.reconcileReminders()

        XCTAssertEqual(notifications.scheduledDefinitionIds.filter { $0 == reminder.id }.count, 2)
    }

    func testDeletingLastPlaceKeepsHistoryAccessibleAndReusesWorkActivity() throws {
        let model = AppModel(inMemory: true, geofence: FakeGeofenceService(), notifications: FakeNotificationService())
        model.load()
        model.finishOnboarding(latitude: 31.2, longitude: 121.4, radius: 200,
                               weekdaysMask: 62, normalStartMinute: nil, normalEndMinute: nil)
        let workID = try XCTUnwrap(model.workActivity?.id)
        model.deleteWorkplace(try XCTUnwrap(model.workTrigger))
        XCTAssertTrue(model.isOnboarded)
        model.finishOnboarding(latitude: 31.3, longitude: 121.5, radius: 200,
                               weekdaysMask: 62, normalStartMinute: nil, normalEndMinute: nil)
        XCTAssertEqual(model.workActivity?.id, workID)
        XCTAssertEqual(model.activities.filter { $0.type == .work }.count, 1)
        XCTAssertEqual(model.workTrigger?.activityId, workID)
    }

    func testPipelineRemovesLateDuplicateCloudSessionFromStorage() throws {
        let persistence = try PersistenceController(inMemory: true)
        let events = SwiftDataActivityEventRepository(context: persistence.context)
        let sessions = SwiftDataActivitySessionRepository(context: persistence.context)
        let pipeline = EventPipeline(events: events, sessions: sessions)
        let start = ActivityEvent(activityId: UUID(), eventType: .geofenceEnter,
                                  timestamp: Date().addingTimeInterval(-3600), source: .coreLocation)
        let first = try XCTUnwrap(pipeline.ingest(start))
        let lateCloudSession = ActivitySession(activityId: start.activityId, startAt: start.timestamp,
                                               startEventId: start.id)
        try sessions.save(lateCloudSession)
        try pipeline.refreshStaleSessions(activityId: start.activityId, timeZoneIdentifier: "UTC")
        XCTAssertEqual(try sessions.fetch(activityId: start.activityId).count, 1)
        XCTAssertEqual(try sessions.fetch(activityId: start.activityId).first?.id, first.id)
    }

    func testNotificationReconcileCancelsDeletedDefinitionsIncludingSnoozes() async throws {
        let requests = FakeNotificationRequestStore()
        let service = LocalNotificationService(requests: requests)
        let removed = ReminderDefinition(activityId: UUID(), name: "删除", hour: 9, minute: 0, weekdaysMask: 127)
        let kept = ReminderDefinition(activityId: UUID(), name: "保留", hour: 10, minute: 0, weekdaysMask: 127)
        try await service.schedule(removed)
        try await service.snooze(definitionId: removed.id, name: removed.name)
        try await service.schedule(kept)
        try await service.snooze(definitionId: kept.id, name: kept.name)
        requests.deliveredRequests = Array(requests.pendingRequests.values)
        try await service.reconcile([kept])
        XCTAssertEqual(requests.pendingRequests.count, 8)
        XCTAssertTrue(requests.pendingRequests.values.allSatisfy { ($0.content.userInfo["definitionId"] as? String) == kept.id.uuidString })
        XCTAssertTrue(requests.deliveredRequests.allSatisfy { ($0.content.userInfo["definitionId"] as? String) == kept.id.uuidString })
        try await service.reconcile([])
        XCTAssertTrue(requests.pendingRequests.isEmpty)
        XCTAssertTrue(requests.deliveredRequests.isEmpty)
    }

    func testDeletingReminderCancelsAlreadyScheduledSnooze() async throws {
        let requests = FakeNotificationRequestStore()
        let service = LocalNotificationService(requests: requests)
        let reminder = ReminderDefinition(activityId: UUID(), name: "阅读", hour: 9, minute: 0, weekdaysMask: 127)
        try await service.schedule(reminder)
        try await service.snooze(definitionId: reminder.id, name: reminder.name)
        XCTAssertEqual(requests.pendingRequests.count, 8)
        await service.cancel(reminder)
        XCTAssertTrue(requests.pendingRequests.isEmpty)
    }

    func testWeeklyDeliveriesKeepIndependentInstancesAndIgnoreRepeatedStart() async throws {
        let notifications = FakeNotificationService()
        let model = AppModel(inMemory: true, geofence: FakeGeofenceService(), notifications: notifications)
        model.load()
        await model.createReminder(name: "阅读", type: .study, time: Date(), weekdaysMask: 127)
        let reminder = try XCTUnwrap(model.reminders.first)
        let firstID = ReminderOccurrence.identifier(requestID: "weekly", deliveredAt: Date(timeIntervalSince1970: 1000))
        let nextID = ReminderOccurrence.identifier(requestID: "weekly", deliveredAt: Date(timeIntervalSince1970: 1000 + 7 * 86400))
        notifications.emit(.start(definitionId: reminder.id, requestId: firstID))
        let first = try XCTUnwrap(model.activeReminderInstances.first)
        let firstSessionID = first.sessionId
        notifications.emit(.start(definitionId: reminder.id, requestId: firstID))
        notifications.emit(.delivered(definitionId: reminder.id, requestId: nextID))
        XCTAssertEqual(model.reminderInstances.count, 2)
        XCTAssertEqual(first.status, .inProgress)
        XCTAssertEqual(first.sessionId, firstSessionID)
        XCTAssertEqual(model.sessions.count, 1)
        XCTAssertEqual(model.activeReminderInstances.count, 1)
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
        XCTAssertEqual(session.duration, 5400, "error=\(model.lastError ?? "none"); adjustments=\(model.events.filter { $0.eventType == .sessionAdjusted }.map { $0.metadata.values })")
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
    var onRegionState: ((UUID, CLRegionState) -> Void)?
    private(set) var registeredTriggerIds: [UUID] = []
    private(set) var removedTriggerIds: [UUID] = []
    var shouldFailRegistration = false

    func requestWhenInUseAuthorization() {}
    func requestAlwaysAuthorization() {}
    func requestCurrentLocation() async throws -> CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: 31.2, longitude: 121.4)
    }
    func register(triggerId: UUID, latitude: Double, longitude: Double, radius: Double) throws -> Double {
        if shouldFailRegistration { throw GeofenceError.locationUnavailable }
        registeredTriggerIds.append(triggerId)
        return radius
    }
    func remove(triggerId: UUID) { removedTriggerIds.append(triggerId) }
    func restoreAndRequestState(triggerId: UUID, latitude: Double, longitude: Double, radius: Double) {}
    func emit(_ event: GeofenceSystemEvent) { onEvent?(event) }
    func emitState(triggerId: UUID, state: CLRegionState) { onRegionState?(triggerId, state) }
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
    func cancel(_ reminder: ReminderDefinition) async {}
    func reconcile(_ reminders: [ReminderDefinition]) async throws {
        for reminder in reminders where reminder.isEnabled { try await schedule(reminder) }
    }
    func snooze(definitionId: UUID, name: String) async throws { snoozedDefinitionIds.append(definitionId) }
    func notifyGeofenceTransition(_ transition: GeofenceNotificationTransition,
                                  activityName: String,
                                  placeName: String) async throws {
        geofenceTransitions.append((transition, activityName, placeName))
    }
    func emit(_ action: ReminderNotificationAction) { onAction?(action) }
}

@MainActor
private final class FakeNotificationRequestStore: NotificationRequestStore {
    var pendingRequests: [String: UNNotificationRequest] = [:]
    var deliveredRequests: [UNNotificationRequest] = []
    func pending() async -> [UNNotificationRequest] { Array(pendingRequests.values) }
    func delivered() async -> [UNNotificationRequest] { deliveredRequests }
    func add(_ request: UNNotificationRequest) async throws { pendingRequests[request.identifier] = request }
    func removePending(_ identifiers: [String]) { identifiers.forEach { pendingRequests[$0] = nil } }
    func removeDelivered(_ identifiers: [String]) {
        deliveredRequests.removeAll { identifiers.contains($0.identifier) }
    }
}
