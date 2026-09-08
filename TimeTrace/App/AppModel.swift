import CoreLocation
import CloudKit
import Foundation
import SwiftUI

enum ICloudSyncStatus: Equatable {
    case checking
    case enabled
    case notEnabled
    case signedOut
    case restricted
    case unavailable

    var title: String {
        switch self {
        case .checking: "正在检查 iCloud"
        case .enabled: "iCloud 同步已开启"
        case .notEnabled: "iCloud 同步未启用"
        case .signedOut: "未登录 iCloud"
        case .restricted: "iCloud 同步受限"
        case .unavailable: "iCloud 暂不可用"
        }
    }

    var detail: String {
        switch self {
        case .checking: "正在确认此设备的同步状态…"
        case .enabled: "地点、围栏设置和记录会自动同步到您的私有 iCloud 数据库"
        case .notEnabled: "请在系统设置中为“时迹”开启 iCloud 同步"
        case .signedOut: "请登录 iCloud 后重新打开时迹以启用同步"
        case .restricted: "请检查屏幕使用时间或设备管理限制"
        case .unavailable: "暂时使用本机存储，可稍后重新检查"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isLoaded = false
    @Published private(set) var isRestoringICloudData = false
    @Published private(set) var needsInitialCloudRestoreDecision = false
    @Published private(set) var activities: [ActivityDefinition] = []
    @Published private(set) var triggers: [ActivityTrigger] = []
    @Published private(set) var events: [ActivityEvent] = []
    @Published private(set) var sessions: [ActivitySession] = []
    @Published private(set) var reminders: [ReminderDefinition] = []
    @Published private(set) var reminderInstances: [ReminderInstance] = []
    @Published private(set) var locationAuthorizationStatus: CLAuthorizationStatus
    @Published private(set) var iCloudSyncStatus: ICloudSyncStatus = .checking
    @Published private(set) var geofenceCapabilityStatus: PlatformCapabilityStatus = .needsAuthorization
    @Published private(set) var notificationCapabilityStatus: PlatformCapabilityStatus = .needsAuthorization
    @Published var lastError: String?

    let geofence: GeofenceServicing
    let notifications: NotificationServicing
    let analytics: AnalyticsServicing

    private let activityRepository: ActivityRepository
    private let eventRepository: ActivityEventRepository
    private let sessionRepository: ActivitySessionRepository
    private let reminderRepository: ReminderRepository
    private let pipeline: EventPipeline
    private var isCloudKitEnabled = false
    private let initialCloudRestoreDelays: [TimeInterval]
    private let cloudStatusProvider: () async -> ICloudSyncStatus
    private var isCheckingCloudStatus = false
    private var isAwaitingInitialCloudStatus = false
    private var hasStartedLoading = false
    /// Places added while the person is already inside have no knowable
    /// arrival time. Their first subsequent exit is informational, not an
    /// anomaly that should ask the person to fabricate an arrival.
    private var monitoringBeganInsideTriggerIDs = Set<UUID>()
    /// A notification tap can arrive while the app is being cold-launched,
    /// before `load()` has restored the SwiftData-backed screen state.
    private var pendingNotificationActions: [ReminderNotificationAction] = []

    var workActivity: ActivityDefinition? { activities.first { $0.type == .work } }
    var workTriggers: [ActivityTrigger] {
        guard let id = workActivity?.id else { return [] }
        return triggers
            .filter { $0.activityId == id && $0.type == .geofence }
            .sorted { $0.createdAt < $1.createdAt }
    }
    var workTrigger: ActivityTrigger? {
        workTriggers.first
    }
    var isOnboarded: Bool { workActivity != nil }
    var activeReminderInstances: [ReminderInstance] { reminderInstances.filter { $0.status == .inProgress } }
    var orphanedWorkExitEvents: [ActivityEvent] {
        guard let activityId = workActivity?.id else { return [] }
        let dismissedIds = Set(events.compactMap { event -> UUID? in
            guard event.eventType == .anomalyDismissed,
                  let value = event.metadata.values["eventId"] else { return nil }
            return UUID(uuidString: value)
        })
        return events.filter {
            $0.activityId == activityId &&
            $0.eventType == .geofenceExit &&
            $0.disposition == .orphaned &&
            !dismissedIds.contains($0.id)
        }
        .sorted { $0.timestamp > $1.timestamp }
    }

    init(inMemory: Bool = false,
         geofence: GeofenceServicing? = nil,
         notifications: NotificationServicing? = nil,
         cloudKitEnabledOverride: Bool? = nil,
         initialCloudRestoreDelays: [TimeInterval] = [1, 3, 6],
         cloudStatusProvider: (() async -> ICloudSyncStatus)? = nil) {
        self.cloudStatusProvider = cloudStatusProvider ?? {
            do {
                let status = try await CKContainer(identifier: PersistenceController.cloudKitContainerIdentifier).accountStatus()
                switch status {
                case .available: return .enabled
                case .noAccount: return .signedOut
                case .restricted: return .restricted
                default: return .unavailable
                }
            } catch {
                return .unavailable
            }
        }
        self.initialCloudRestoreDelays = initialCloudRestoreDelays
        let geofence = geofence ?? CoreLocationGeofenceService()
        self.geofence = geofence
        self.locationAuthorizationStatus = geofence.authorizationStatus
        self.geofenceCapabilityStatus = .geofence(for: geofence.authorizationStatus)
        do {
            let persistence = try PersistenceController(inMemory: inMemory)
            isCloudKitEnabled = cloudKitEnabledOverride ?? persistence.isCloudKitEnabled
            let activities = SwiftDataActivityRepository(context: persistence.context)
            let events = SwiftDataActivityEventRepository(context: persistence.context)
            let sessions = SwiftDataActivitySessionRepository(context: persistence.context)
            let reminders = SwiftDataReminderRepository(context: persistence.context)
            self.activityRepository = activities
            self.eventRepository = events
            self.sessionRepository = sessions
            self.reminderRepository = reminders
            self.pipeline = EventPipeline(events: events, sessions: sessions)
        } catch {
            let activities = UnavailableActivityRepository()
            let events = UnavailableEventRepository()
            let sessions = UnavailableSessionRepository()
            let reminders = UnavailableReminderRepository()
            self.activityRepository = activities
            self.eventRepository = events
            self.sessionRepository = sessions
            self.reminderRepository = reminders
            self.pipeline = EventPipeline(events: events, sessions: sessions)
            self.lastError = "本地存储暂不可用；已以只读模式打开。"
        }
        self.notifications = notifications ?? LocalNotificationService()
        self.analytics = AnalyticsService()

        self.geofence.onEvent = { [weak self] event in self?.handleGeofence(event) }
        self.geofence.onAuthorizationChange = { [weak self] status in
            self?.locationAuthorizationStatus = status
            self?.geofenceCapabilityStatus = .geofence(for: status)
        }
        self.geofence.onRegionState = { [weak self] triggerId, state in
            self?.handleGeofenceRegionState(triggerId: triggerId, state: state)
        }
        self.notifications.onAction = { [weak self] action in self?.receiveNotificationAction(action) }
        self.notifications.registerCategories()
        refreshICloudSyncStatus()
    }

    func load() {
        guard !hasStartedLoading else { return }
        hasStartedLoading = true
        refreshICloudSyncStatus()
        do {
            try refreshDataAndRestoreGeofence()
            if isCloudKitEnabled && !isOnboarded {
                isAwaitingInitialCloudStatus = true
                resolveInitialCloudStatusIfNeeded()
            } else {
                finishLoading()
            }
        } catch {
            lastError = TimeTraceLocalization.errorMessage(error, fallback: "读取本地数据失败，请重新打开应用。")
            finishLoading()
        }
    }

    /// Re-reads data merged by SwiftData/CloudKit and applies the latest
    /// geofence to this device. CloudKit syncs the records automatically, but
    /// Core Location still needs the local device registration refreshed.
    func refreshSyncedData() {
        guard isLoaded else { return }
        do {
            try refreshDataAndRestoreGeofence()
            if isOnboarded { needsInitialCloudRestoreDecision = false }
            Task { [weak self] in await self?.reconcileReminders() }
        } catch {
            lastError = TimeTraceLocalization.errorMessage(error, fallback: "刷新 iCloud 数据失败，请稍后重试。")
        }
    }

    /// A fresh local store is ambiguous while CloudKit is still merging. Never
    /// create a new account's data by treating an empty first fetch as proof
    /// that no older data exists; let the person choose to wait or start over.
    func retryInitialCloudRestore() {
        guard isCloudKitEnabled, iCloudSyncStatus == .enabled, !isOnboarded else { return }
        needsInitialCloudRestoreDecision = false
        isLoaded = false
        restoreInitialCloudDataBeforeOnboarding()
    }

    /// This is an explicit user choice. It only stops waiting for an older
    /// cloud store and never deletes CloudKit records.
    func startNewRecordAfterSkippingCloudRestore() {
        needsInitialCloudRestoreDecision = false
        finishLoading()
    }

    /// CloudKit has no single "all records are synced" callback. This checks
    /// the account and container availability, which is the actionable status
    /// a person can resolve from Settings.
    func refreshICloudSyncStatus() {
        guard isCloudKitEnabled else {
            iCloudSyncStatus = .notEnabled
            resolveInitialCloudStatusIfNeeded()
            return
        }
        guard !isCheckingCloudStatus else { return }
        isCheckingCloudStatus = true
        iCloudSyncStatus = .checking
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.iCloudSyncStatus = await self.cloudStatusProvider()
            self.isCheckingCloudStatus = false
            self.resolveInitialCloudStatusIfNeeded()
            if self.iCloudSyncStatus == .enabled { self.refreshSyncedData() }
        }
    }

    private func resolveInitialCloudStatusIfNeeded() {
        guard isAwaitingInitialCloudStatus, iCloudSyncStatus != .checking else { return }
        isAwaitingInitialCloudStatus = false
        // Account availability only offers restoration; waiting starts on a tap.
        needsInitialCloudRestoreDecision = iCloudSyncStatus == .enabled && !isOnboarded
        finishLoading()
    }

    func finishOnboarding(latitude: Double, longitude: Double, radius: Double,
                          weekdaysMask: Int, normalStartMinute: Int?, normalEndMinute: Int?,
                          placeName: String = "工作地点") {
        do {
            let work = workActivity ?? ActivityDefinition(name: "工作", type: .work)
            try activityRepository.save(work)
            let trigger = ActivityTrigger(
                activityId: work.id,
                type: .geofence,
                latitude: latitude,
                longitude: longitude,
                radius: radius,
                placeName: normalizedPlaceName(placeName),
                regionIdentifier: nil,
                weekdaysMask: weekdaysMask,
                normalStartMinute: normalStartMinute,
                normalEndMinute: normalEndMinute,
                timeZoneIdentifier: TimeZone.current.identifier
            )
            trigger.regionIdentifier = "timetrace.place.\(trigger.id.uuidString)"
            try activityRepository.save(trigger)
            reconcileGeofence(trigger, fallbackMessage: "地点已保存；定位恢复后会自动开启记录。")
            geofence.requestAlwaysAuthorization()
            requestGeofenceNotificationAuthorization()
            // Onboarding normally runs after the root store has loaded.  Do
            // not turn this persistence operation into a second app launch:
            // doing so incorrectly processes cold-launch notification actions
            // before the caller has restored its screen state.
            refreshPublishedData()
        } catch { lastError = TimeTraceLocalization.errorMessage(error, fallback: "保存地点失败，请稍后重试。") }
    }

    func addWorkplace(latitude: Double, longitude: Double, radius: Double, placeName: String,
                      placeType: PlaceType = .work) {
        guard let workActivity else { return }
        addPlace(activityId: workActivity.id, latitude: latitude, longitude: longitude, radius: radius,
                 placeName: placeName, placeType: placeType)
    }

    /// Adds a geofence for any activity.  The existing workplace UI is a
    /// specialised caller of this general use case; it no longer defines the
    /// persistence or runtime boundary of a place.
    func addPlace(activityId: UUID, latitude: Double, longitude: Double, radius: Double, placeName: String,
                  placeType: PlaceType = .other) {
        guard activities.contains(where: { $0.id == activityId }) else { return }
        do {
            let referenceTrigger = triggers.first { $0.activityId == activityId && $0.type == .geofence }
            let trigger = ActivityTrigger(
                activityId: activityId,
                type: .geofence,
                latitude: latitude,
                longitude: longitude,
                radius: radius,
                placeName: normalizedPlaceName(placeName),
                placeType: placeType,
                regionIdentifier: nil,
                weekdaysMask: referenceTrigger?.weekdaysMask ?? 0,
                normalStartMinute: referenceTrigger?.normalStartMinute,
                normalEndMinute: referenceTrigger?.normalEndMinute,
                timeZoneIdentifier: TimeZone.current.identifier
            )
            trigger.regionIdentifier = "timetrace.place.\(trigger.id.uuidString)"
            try activityRepository.save(trigger)
            reconcileGeofence(trigger, fallbackMessage: "地点已保存；定位恢复后会自动开启记录。")
            refreshPublishedData()
        } catch { lastError = TimeTraceLocalization.errorMessage(error, fallback: "添加地点失败，请稍后重试。") }
    }

    func updateWorkplace(triggerId: UUID, latitude: Double, longitude: Double, radius: Double,
                         placeName: String, placeType: PlaceType = .work) {
        updatePlace(triggerId: triggerId, latitude: latitude, longitude: longitude, radius: radius,
                    placeName: placeName, placeType: placeType)
    }

    func updatePlace(triggerId: UUID, latitude: Double, longitude: Double, radius: Double,
                     placeName: String, placeType: PlaceType) {
        guard let trigger = triggers.first(where: { $0.id == triggerId && $0.type == .geofence }) else { return }
        do {
            trigger.latitude = latitude
            trigger.longitude = longitude
            trigger.radius = radius
            trigger.placeName = normalizedPlaceName(placeName)
            trigger.placeType = placeType
            trigger.timeZoneIdentifier = TimeZone.current.identifier
            try activityRepository.save(trigger)
            reconcileGeofence(trigger, fallbackMessage: "地点已更新；定位恢复后会自动开启记录。")
            refreshPublishedData()
        } catch { lastError = TimeTraceLocalization.errorMessage(error, fallback: "更新地点失败，请稍后重试。") }
    }

    func setPlaceEnabled(triggerId: UUID, isEnabled: Bool) {
        guard let trigger = triggers.first(where: { $0.id == triggerId && $0.type == .geofence }) else { return }
        do {
            trigger.isEnabled = isEnabled
            try activityRepository.save(trigger)
            if isEnabled {
                reconcileGeofence(trigger, fallbackMessage: "地点已启用；定位恢复后会自动开启记录。")
            } else {
                geofence.remove(triggerId: trigger.id)
            }
            refreshPublishedData()
        } catch {
            lastError = TimeTraceLocalization.errorMessage(error, fallback: "更新地点状态失败，请稍后重试。")
        }
    }

    func deleteWorkplace(_ trigger: ActivityTrigger) {
        guard workTriggers.contains(where: { $0.id == trigger.id }) else { return }
        do {
            geofence.remove(triggerId: trigger.id)
            try activityRepository.delete(trigger)
            refreshPublishedData()
        } catch {
            lastError = TimeTraceLocalization.errorMessage(error, fallback: "删除地点失败，请稍后重试。")
        }
    }

    func addManualSession(startAt: Date, endAt: Date) {
        guard let workActivity, endAt >= startAt else { return }
        do {
            let metadata = timeZoneMetadata()
            _ = try pipeline.ingest(ActivityEvent(activityId: workActivity.id, eventType: .manualStart,
                                                  timestamp: startAt, source: .user, metadata: metadata),
                                    timeZoneIdentifier: currentTimeZoneIdentifier())
            _ = try pipeline.ingest(ActivityEvent(activityId: workActivity.id, eventType: .manualStop,
                                                  timestamp: endAt, source: .user, metadata: metadata),
                                    timeZoneIdentifier: currentTimeZoneIdentifier())
            refreshPublishedData()
        } catch { lastError = TimeTraceLocalization.errorMessage(error, fallback: "补录工作时间失败，请稍后重试。") }
    }

    #if DEBUG
    /// Adds a month of history that covers every saved-place category. The
    /// location category determines its plausible time window rather than
    /// making every location look like an office visit.
    @discardableResult
    func generateThirtyDayDemoData(endingAt now: Date = Date()) -> Int? {
        guard let workActivity else {
            lastError = "请先完成地点配置"
            return nil
        }

        do {
            let persistedDemoEvents = try eventRepository.fetch(activityId: workActivity.id)
            let legacyDemoEvents = persistedDemoEvents.filter {
                $0.metadata.values["demoData"] == "thirtyDay" &&
                $0.metadata.values["demoVersion"] != "2"
            }
            // Earlier samples were all linked to the primary workplace. They
            // are safe to replace because they are explicitly tagged demo data.
            if !legacyDemoEvents.isEmpty {
                try removeDemoData(events: legacyDemoEvents, removePlaces: false)
            }

            let calendar = workCalendar()
            let today = calendar.startOfDay(for: now)
            guard let firstDay = calendar.date(byAdding: .day, value: -29, to: today),
                  let intervalEnd = calendar.date(byAdding: .day, value: 1, to: today) else {
                return 0
            }

            let interval = DateInterval(start: firstDay, end: intervalEnd)
            let occupiedDays = Set(
                try sessionRepository.fetch(activityId: workActivity.id)
                    .filter { $0.deletedAt == nil && interval.contains($0.startAt) }
                    .map { calendar.startOfDay(for: $0.startAt) }
            )
            let taggedDays: Set<String> = Set(
                try eventRepository.fetch(activityId: workActivity.id).compactMap { event -> String? in
                    guard event.metadata.values["demoData"] == "thirtyDay",
                          event.metadata.values["demoVersion"] == "2" else { return nil }
                    return event.metadata.values["demoDay"]
                }
            )

            let demoPlaces = try ensureDemoPlaces(for: workActivity, calendar: calendar)
            let dayFormatter = DateFormatter()
            dayFormatter.calendar = calendar
            dayFormatter.locale = TimeTraceLocalization.locale
            dayFormatter.timeZone = calendar.timeZone
            dayFormatter.dateFormat = "yyyy-MM-dd"

            var insertedDays = 0
            var incompleteSessionIDs = Set<UUID>()
            for offset in 0..<30 {
                guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { continue }
                let dayKey = dayFormatter.string(from: day)
                guard !occupiedDays.contains(day), !taggedDays.contains(dayKey) else {
                    continue
                }
                let visits = demoVisits(for: day, calendar: calendar, places: demoPlaces)
                guard !visits.isEmpty else { continue }

                var insertedVisit = false
                for (visitIndex, visit) in visits.enumerated() {
                    guard let start = calendar.date(byAdding: .minute, value: visit.startMinute, to: day),
                          let plannedEnd = calendar.date(byAdding: .minute, value: visit.endMinute, to: day),
                          start < now else { break }

                    let metadata = EventMetadata(values: [
                        "timeZoneIdentifier": currentTimeZoneIdentifier(),
                        "demoData": "thirtyDay",
                        "demoDay": dayKey,
                        "demoVersion": "2",
                        "placeTriggerId": visit.place.id.uuidString
                    ])
                    func ingest(_ type: ActivityEventType, at timestamp: Date) throws -> ActivitySession? {
                        return try pipeline.ingest(
                            ActivityEvent(activityId: workActivity.id, eventType: type,
                                          timestamp: timestamp, source: .system,
                                          metadata: metadata, createdAt: timestamp),
                            timeZoneIdentifier: currentTimeZoneIdentifier(),
                            now: now
                        )
                    }

                    let session = try ingest(.geofenceEnter, at: start)
                    insertedVisit = true

                    // Preserve one old incomplete record, and leave the current
                    // visit active when the sample is generated mid-visit.
                    let isIncompleteExample = offset == 8 && visitIndex == visits.count - 1
                    if isIncompleteExample, let session {
                        incompleteSessionIDs.insert(session.id)
                    }
                    if !isIncompleteExample && plannedEnd <= now {
                        try ingest(.geofenceExit, at: plannedEnd)
                    }
                    if plannedEnd > now || isIncompleteExample { break }
                }

                if insertedVisit { insertedDays += 1 }
            }

            // A later generated visit may make the reconciliation engine
            // revisit this old start event. Pin the deliberately incomplete
            // sample after the complete event sequence has been written.
            if !incompleteSessionIDs.isEmpty {
                for session in try sessionRepository.fetch(activityId: workActivity.id)
                    where incompleteSessionIDs.contains(session.id) {
                    session.endAt = nil
                    session.endEventId = nil
                    session.status = .incomplete
                    session.confidence = .uncertain
                    session.updatedAt = now
                    try sessionRepository.save(session)
                }
            }

            refreshPublishedData()
            return insertedDays
        } catch {
            lastError = TimeTraceLocalization.errorMessage(error, fallback: "生成示例数据失败，请稍后重试。")
            return nil
        }
    }

    /// Removes only data created by the local demo-data generator.
    @discardableResult
    func clearThirtyDayDemoData() -> Int {
        do {
            let demoEvents = try eventRepository.fetchAll().filter {
                $0.metadata.values["demoData"] == "thirtyDay"
            }
            let removed = try removeDemoData(events: demoEvents, removePlaces: true)
            refreshPublishedData()
            return removed
        } catch {
            lastError = TimeTraceLocalization.errorMessage(error, fallback: "清除测试数据失败，请稍后重试。")
            return 0
        }
    }

    var activeDemoSessionCount: Int {
        let demoStartEventIDs = Set(events.compactMap { event -> UUID? in
            guard event.metadata.values["demoData"] == "thirtyDay", event.eventType.startsSession else {
                return nil
            }
            return event.id
        })
        return sessions.filter { session in
            guard let startEventId = session.startEventId else { return false }
            return demoStartEventIDs.contains(startEventId)
        }.count
    }

    private struct DemoVisit {
        let place: ActivityTrigger
        let startMinute: Int
        let endMinute: Int
    }

    private struct DemoPlaceDefinition {
        let type: PlaceType
        let name: String
        let latitudeOffset: Double
        let longitudeOffset: Double
    }

    private static let demoPlaceDefinitions: [DemoPlaceDefinition] = [
        .init(type: .work, name: "示例·办公室", latitudeOffset: 0, longitudeOffset: 0),
        .init(type: .study, name: "示例·图书馆", latitudeOffset: 0.012, longitudeOffset: 0.008),
        .init(type: .exercise, name: "示例·健身房", latitudeOffset: -0.009, longitudeOffset: 0.011),
        .init(type: .home, name: "示例·家", latitudeOffset: -0.014, longitudeOffset: -0.008),
        .init(type: .dining, name: "示例·餐厅", latitudeOffset: 0.004, longitudeOffset: -0.006),
        .init(type: .shopping, name: "示例·商场", latitudeOffset: 0.016, longitudeOffset: -0.012),
        .init(type: .healthcare, name: "示例·医院", latitudeOffset: -0.017, longitudeOffset: 0.004),
        .init(type: .leisure, name: "示例·影院", latitudeOffset: 0.009, longitudeOffset: -0.017),
        .init(type: .other, name: "示例·客户现场", latitudeOffset: 0.021, longitudeOffset: 0.016)
    ]

    private func ensureDemoPlaces(for activity: ActivityDefinition,
                                  calendar: Calendar) throws -> [PlaceType: ActivityTrigger] {
        let savedTriggers = try activityRepository.fetchTriggers(activityId: activity.id)
        let existingDemoPlaces = savedTriggers
            .filter { $0.type == .geofence && $0.isDemoData }
            .reduce(into: [PlaceType: ActivityTrigger]()) { $0[$1.placeType] = $1 }
        guard let reference = savedTriggers.first(where: { $0.type == .geofence }),
              let latitude = reference.latitude, let longitude = reference.longitude else {
            throw GeofenceError.invalidConfiguration
        }

        var places = existingDemoPlaces
        for definition in Self.demoPlaceDefinitions where places[definition.type] == nil {
            let trigger = ActivityTrigger(
                activityId: activity.id,
                type: .geofence,
                isEnabled: false,
                isDemoData: true,
                latitude: latitude + definition.latitudeOffset,
                longitude: longitude + definition.longitudeOffset,
                radius: 150,
                placeName: definition.name,
                placeType: definition.type,
                weekdaysMask: 0,
                normalStartMinute: nil,
                normalEndMinute: nil,
                timeZoneIdentifier: calendar.timeZone.identifier
            )
            try activityRepository.save(trigger)
            places[definition.type] = trigger
        }
        return places
    }

    @discardableResult
    private func removeDemoData(events demoEvents: [ActivityEvent], removePlaces: Bool) throws -> Int {
        let demoStartEventIDs = Set(demoEvents.compactMap { event -> UUID? in
            event.eventType.startsSession ? event.id : nil
        })
        let demoSessions = try sessionRepository.fetch(activityId: nil).filter {
            guard let startEventId = $0.startEventId else { return false }
            return demoStartEventIDs.contains(startEventId) && $0.deletedAt == nil
        }
        try sessionRepository.delete(demoSessions)
        try eventRepository.delete(demoEvents)

        if removePlaces {
            let demoPlaces = try activityRepository.fetchTriggers(activityId: nil).filter(\.isDemoData)
            for place in demoPlaces {
                geofence.remove(triggerId: place.id)
                try activityRepository.delete(place)
            }
        }
        return demoSessions.count
    }

    /// Time windows are intentionally centralised here so the sample tells a
    /// coherent story: work in the daytime, exercise in the morning, meals at
    /// lunch, study in the evening, and personal errands on weekends.
    private func demoVisits(for day: Date, calendar: Calendar,
                            places: [PlaceType: ActivityTrigger]) -> [DemoVisit] {
        func visit(_ type: PlaceType, _ start: Int, _ end: Int) -> DemoVisit? {
            guard let place = places[type] else { return nil }
            return DemoVisit(place: place, startMinute: start, endMinute: end)
        }
        let weekday = calendar.component(.weekday, from: day)
        let values: [DemoVisit?]
        switch weekday {
        case 2: // Monday
            values = [visit(.exercise, 7 * 60 + 10, 8 * 60 + 20), visit(.work, 8 * 60 + 55, 18 * 60 + 10)]
        case 3: // Tuesday
            values = [visit(.work, 8 * 60 + 50, 12 * 60 + 5), visit(.dining, 12 * 60 + 15, 13 * 60 + 5),
                      visit(.work, 13 * 60 + 15, 18 * 60 + 25), visit(.study, 19 * 60 + 5, 21 * 60 + 15)]
        case 4: // Wednesday
            values = [visit(.exercise, 7 * 60 + 5, 8 * 60 + 15), visit(.work, 8 * 60 + 48, 10 * 60 + 10),
                      visit(.healthcare, 10 * 60 + 20, 11 * 60 + 35), visit(.work, 11 * 60 + 45, 18 * 60)]
        case 5: // Thursday
            values = [visit(.work, 9 * 60 + 5, 12 * 60), visit(.dining, 12 * 60 + 10, 13 * 60),
                      visit(.work, 13 * 60 + 10, 18 * 60 + 35), visit(.study, 19 * 60 + 10, 21 * 60 + 20)]
        case 6: // Friday
            values = [visit(.exercise, 7 * 60 + 15, 8 * 60 + 25), visit(.work, 9 * 60, 14 * 60),
                      visit(.other, 14 * 60 + 15, 16 * 60 + 35), visit(.work, 16 * 60 + 45, 18 * 60 + 40)]
        case 7: // Saturday
            values = [visit(.shopping, 14 * 60, 16 * 60 + 20), visit(.leisure, 19 * 60, 21 * 60 + 25)]
        default: // Sunday
            values = [visit(.home, 19 * 60 + 30, 22 * 60)]
        }
        return values.compactMap { $0 }
    }
    #endif

    @discardableResult
    func adjustSession(_ session: ActivitySession, startAt: Date, endAt: Date?) -> Bool {
        guard endAt == nil || endAt! >= startAt else { return false }
        do {
            let values = [
                "sessionId": session.id.uuidString,
                "oldStart": session.startAt.ISO8601Format(.init(includingFractionalSeconds: true)),
                "newStart": startAt.ISO8601Format(.init(includingFractionalSeconds: true)),
                "oldEnd": session.endAt?.ISO8601Format(.init(includingFractionalSeconds: true)) ?? "",
                "newEnd": endAt?.ISO8601Format(.init(includingFractionalSeconds: true)) ?? "",
                "startEventId": session.startEventId?.uuidString ?? ""
            ]
            _ = try pipeline.ingest(ActivityEvent(activityId: session.activityId, eventType: .sessionAdjusted,
                                                  timestamp: Date(), source: .user,
                                                  metadata: EventMetadata(values: values)))
            refreshPublishedData()
            return true
        } catch {
            lastError = TimeTraceLocalization.errorMessage(error, fallback: "修改工作记录失败，请稍后重试。")
            return false
        }
    }

    func repairOrphanedExit(_ event: ActivityEvent, startAt: Date) {
        guard event.eventType == .geofenceExit,
              event.disposition == .orphaned,
              startAt <= event.timestamp else { return }
        do {
            let metadata = EventMetadata(values: [
                "timeZoneIdentifier": currentTimeZoneIdentifier(),
                "repairsEventId": event.id.uuidString
            ])
            // Do not send this through the automatic reconciler: the exit was
            // previously classified as orphaned, and an overnight repair must
            // deterministically pair the selected arrival with that exact exit.
            let manualStart = ActivityEvent(
                activityId: event.activityId,
                eventType: .manualStart,
                timestamp: startAt,
                source: .user,
                metadata: metadata
            )
            _ = try eventRepository.append(manualStart)
            event.disposition = .applied
            let session = ActivitySession(
                activityId: event.activityId,
                placeTriggerId: UUID(uuidString: event.metadata.values["placeTriggerId"] ?? ""),
                startAt: startAt,
                endAt: event.timestamp,
                status: .manuallyAdjusted,
                startEventId: manualStart.id,
                endEventId: event.id,
                confidence: .confirmed,
                timeZoneIdentifier: event.metadata.values["timeZoneIdentifier"] ?? currentTimeZoneIdentifier()
            )
            try sessionRepository.save(session)
            try eventRepository.saveProcessingChanges()
            try sessionRepository.saveChanges()
            refreshPublishedData()
        } catch { lastError = TimeTraceLocalization.errorMessage(error, fallback: "修复异常记录失败，请稍后重试。") }
    }

    func dismissOrphanedEvent(_ event: ActivityEvent) {
        do {
            _ = try pipeline.ingest(ActivityEvent(
                activityId: event.activityId,
                eventType: .anomalyDismissed,
                timestamp: Date(),
                source: .user,
                metadata: EventMetadata(values: ["eventId": event.id.uuidString])
            ))
            refreshPublishedData()
        } catch { lastError = TimeTraceLocalization.errorMessage(error, fallback: "忽略异常记录失败，请稍后重试。") }
    }

    @discardableResult
    func deleteSession(_ session: ActivitySession) -> Bool {
        do {
            _ = try pipeline.ingest(ActivityEvent(activityId: session.activityId, eventType: .sessionDeleted,
                                                  timestamp: Date(), source: .user,
                                                  metadata: EventMetadata(values: [
                                                    "sessionId": session.id.uuidString,
                                                    "startEventId": session.startEventId?.uuidString ?? ""
                                                  ])))
            refreshPublishedData()
            return true
        } catch {
            lastError = TimeTraceLocalization.errorMessage(error, fallback: "删除工作记录失败，请稍后重试。")
            return false
        }
    }

    func createReminder(name: String, type: ActivityType, time: Date, weekdaysMask: Int) async {
        do {
            let activity = ActivityDefinition(name: name, type: type)
            try activityRepository.save(activity)
            let parts = Calendar.current.dateComponents([.hour, .minute], from: time)
            let reminder = ReminderDefinition(activityId: activity.id, name: name,
                                              hour: parts.hour ?? 21, minute: parts.minute ?? 0,
                                              weekdaysMask: weekdaysMask)
            let trigger = ActivityTrigger(activityId: activity.id, type: .schedule,
                                          weekdaysMask: weekdaysMask, hour: parts.hour ?? 21,
                                          minute: parts.minute ?? 0,
                                          timeZoneIdentifier: TimeZone.current.identifier)
            try activityRepository.save(trigger)
            try reminderRepository.save(reminder)
            do {
                let authorized = try await notifications.requestAuthorization()
                guard authorized else {
                    notificationCapabilityStatus = .needsAuthorization
                    refreshPublishedData()
                    return
                }
                try await notifications.schedule(reminder)
                notificationCapabilityStatus = .available
            } catch {
                notificationCapabilityStatus = .unavailable(message: "提醒已保存；通知恢复后会自动生效。")
            }
            refreshPublishedData()
        } catch { lastError = TimeTraceLocalization.errorMessage(error, fallback: "创建提醒失败，请稍后重试。") }
    }

    func deleteReminder(_ reminder: ReminderDefinition) async {
        do {
            let scheduleTriggers = try activityRepository.fetchTriggers(activityId: reminder.activityId)
                .filter { $0.type == .schedule }
            for trigger in scheduleTriggers {
                try activityRepository.delete(trigger)
            }
            try reminderRepository.delete(reminder)
            refreshPublishedData()
            await notifications.cancel(reminder)
        } catch { lastError = TimeTraceLocalization.errorMessage(error, fallback: "删除提醒失败，请稍后重试。") }
    }

    /// Notification scheduling is a device-local projection, unlike reminder
    /// definitions which can arrive through CloudKit.  Reconcile it whenever
    /// the application becomes active so a definition created on another
    /// device, or one that previously failed to schedule, becomes actionable
    /// without changing the visible Settings design.
    func reconcileReminders() async {
        do {
            try await notifications.reconcile(reminderRepository.fetchDefinitions())
        } catch {
            notificationCapabilityStatus = .unavailable(message: "提醒已保存；通知恢复后会自动生效。")
        }
    }

    func finishReminderInstance(_ instance: ReminderInstance, abandoned: Bool) {
        do {
            if let session = session(for: instance), session.endAt == nil {
                _ = try pipeline.ingest(ActivityEvent(activityId: session.activityId, eventType: .manualStop,
                                                      timestamp: Date(), source: .user,
                                                      metadata: EventMetadata(values: ["reminderInstanceId": instance.id.uuidString])))
            }
            let eventType: ActivityEventType = abandoned ? .reminderAbandoned : .reminderCompleted
            _ = try pipeline.ingest(ActivityEvent(activityId: instance.activityId, eventType: eventType,
                                                  timestamp: Date(), source: .user,
                                                  metadata: EventMetadata(values: ["reminderInstanceId": instance.id.uuidString])))
            instance.status = abandoned ? .abandoned : .completed
            instance.updatedAt = Date()
            try reminderRepository.saveChanges()
            refreshPublishedData()
        } catch { lastError = TimeTraceLocalization.errorMessage(error, fallback: "更新提醒状态失败，请稍后重试。") }
    }

    func dailySummaries(interval: DateInterval) -> [DailyActivitySummary] {
        guard let workActivity else { return [] }
        return analytics.dailySummaries(sessions: sessions, activityId: workActivity.id,
                                        interval: interval, calendar: workCalendar())
    }

    func weeklySummary(containing date: Date = Date()) -> PeriodActivitySummary? {
        guard let workActivity else { return nil }
        return analytics.weeklySummary(sessions: sessions, activityId: workActivity.id,
                                       containing: date, calendar: workCalendar())
    }

    func monthlySummary(containing date: Date = Date()) -> PeriodActivitySummary? {
        guard let workActivity else { return nil }
        return analytics.monthlySummary(sessions: sessions, activityId: workActivity.id,
                                        containing: date, calendar: workCalendar())
    }

    func periodSummary(interval: DateInterval, previous: DateInterval,
                       placeFilter: PlaceSessionFilter = .all) -> PeriodActivitySummary? {
        guard let workActivity else { return nil }
        return analytics.periodSummary(
            sessions: sessions,
            activityId: workActivity.id,
            interval: interval,
            previous: previous,
            placeFilter: placeFilter,
            calendar: workCalendar()
        )
    }

    func placeSummaries(interval: DateInterval) -> [PlaceActivitySummary] {
        guard let workActivity else { return [] }
        return analytics.placeSummaries(sessions: sessions, activityId: workActivity.id, interval: interval)
    }

    func session(for instance: ReminderInstance) -> ActivitySession? {
        if let direct = sessions.first(where: { $0.id == instance.sessionId }) { return direct }
        // A late cloud projection may have replaced a duplicate session ID.
        let start = events.first {
            $0.eventType.startsSession && $0.metadata.values["reminderInstanceId"] == instance.id.uuidString
        }
        return start.flatMap { event in sessions.first { $0.startEventId == event.id } }
    }

    private func refreshPublishedData() {
        do {
            try normalizeImmediateDuplicateGeofenceExits()
            activities = try activityRepository.fetchAll()
            triggers = try activityRepository.fetchTriggers(activityId: nil)
            events = try eventRepository.fetchAll()
            sessions = try sessionRepository.fetch(activityId: nil).filter { $0.deletedAt == nil }
            reminders = try reminderRepository.fetchDefinitions()
            reminderInstances = try reminderRepository.fetchInstances()
        } catch { lastError = TimeTraceLocalization.errorMessage(error, fallback: "刷新本地数据失败，请稍后重试。") }
    }

    /// Processing disposition is stored with CloudKit-backed events. A remote
    /// merge can therefore briefly restore an old `.orphaned` value after a
    /// newer client has already recognized an immediate duplicate exit. Make
    /// this deterministic from the immutable event sequence every time data
    /// is published, so a completed record never regains a false repair task.
    private func normalizeImmediateDuplicateGeofenceExits() throws {
        let orderedEvents = try eventRepository.fetchAll().sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
        var latestAppliedExitByPlace: [UUID: Date] = [:]
        var changed = false

        for event in orderedEvents where event.eventType == .geofenceExit {
            guard let placeId = UUID(uuidString: event.metadata.values["placeTriggerId"] ?? "") else { continue }
            if event.disposition == .applied {
                latestAppliedExitByPlace[placeId] = event.timestamp
                continue
            }
            guard event.disposition == .orphaned,
                  let precedingExit = latestAppliedExitByPlace[placeId],
                  event.timestamp.timeIntervalSince(precedingExit) <= ActivitySessionEngine.duplicateGeofenceExitInterval else {
                continue
            }
            event.disposition = .redundant
            changed = true
        }

        if changed { try eventRepository.saveProcessingChanges() }
    }

    private func refreshDataAndRestoreGeofence() throws {
        activities = try activityRepository.fetchAll()
        triggers = try activityRepository.fetchTriggers(activityId: nil)
        let activeGeofenceTriggers = triggers.filter {
            $0.type == .geofence && $0.isEnabled && !$0.isDemoData
        }
        let timeZoneByActivity = Dictionary(grouping: activeGeofenceTriggers, by: \.activityId)
            .mapValues { $0.first?.timeZoneIdentifier ?? TimeZone.current.identifier }

        // Sessions and registrations are device-local projections. Rebuild
        // them for every activity after a CloudKit merge, rather than only
        // for the default work activity shown by today's UI.
        for activity in activities {
            try pipeline.refreshStaleSessions(activityId: activity.id,
                                              timeZoneIdentifier: timeZoneByActivity[activity.id] ?? TimeZone.current.identifier)
        }
        for trigger in triggers where trigger.type == .geofence && !trigger.isDemoData {
            guard trigger.isEnabled,
                  let latitude = trigger.latitude,
                  let longitude = trigger.longitude,
                  let radius = trigger.radius else {
                geofence.remove(triggerId: trigger.id)
                continue
            }
            geofence.restoreAndRequestState(triggerId: trigger.id, latitude: latitude,
                                            longitude: longitude, radius: radius)
        }
        if !activeGeofenceTriggers.isEmpty {
            requestGeofenceNotificationAuthorization()
        }
        refreshPublishedData()
    }

    /// A newly installed device can finish its first local fetch before
    /// CloudKit has merged the existing private database. Refresh twice after
    /// launch so a synced workplace is also registered with Core Location.
    private func scheduleInitialCloudRefreshIfNeeded() {
        guard isCloudKitEnabled else { return }
        Task { [weak self] in
            for delay in [2, 6] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                self?.refreshSyncedData()
            }
        }
    }

    /// After the person chooses restoration, give the asynchronous CloudKit
    /// mirror a few chances to merge the previous device's data.
    private func restoreInitialCloudDataBeforeOnboarding() {
        guard !isRestoringICloudData else { return }
        isRestoringICloudData = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            for delay in self.initialCloudRestoreDelays {
                if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
                guard !Task.isCancelled else { return }
                try? self.refreshDataAndRestoreGeofence()
                if self.isOnboarded { break }
            }
            self.isRestoringICloudData = false
            if self.isOnboarded {
                self.finishLoading()
            } else {
                self.needsInitialCloudRestoreDecision = true
                self.isLoaded = true
            }
        }
    }

    private func finishLoading() {
        isLoaded = true
        processPendingNotificationActions()
        scheduleInitialCloudRefreshIfNeeded()
    }

    private func handleGeofence(_ systemEvent: GeofenceSystemEvent) {
        do {
            let triggerId: UUID
            let timestamp: Date
            let type: ActivityEventType
            let monitoringBeganInside: Bool
            switch systemEvent {
            case .entered(let id, let date):
                (triggerId, timestamp, type) = (id, date, .geofenceEnter)
                monitoringBeganInsideTriggerIDs.remove(id)
                monitoringBeganInside = false
            case .exited(let id, let date):
                (triggerId, timestamp, type) = (id, date, .geofenceExit)
                monitoringBeganInside = monitoringBeganInsideTriggerIDs.remove(id) != nil
            }
            guard let trigger = try activityRepository.fetchTriggers(activityId: nil)
                .first(where: { $0.id == triggerId && $0.type == .geofence && $0.isEnabled }) else { return }
            let activityId = trigger.activityId
            var metadata = timeZoneMetadata()
            metadata.values["placeTriggerId"] = trigger.id.uuidString
            metadata.values["placeType"] = trigger.placeType.rawValue
            if monitoringBeganInside {
                metadata.values["monitoringBeganInside"] = "true"
            }
            _ = try pipeline.ingest(ActivityEvent(activityId: activityId, eventType: type,
                                                  timestamp: timestamp, source: .coreLocation,
                                                  metadata: metadata),
                                    timeZoneIdentifier: trigger.timeZoneIdentifier)
            refreshPublishedData()
            let activityName = (try activityRepository.fetch(id: activityId))?.name ?? "工作"
            let placeName = trigger.displayPlaceName
            let transition: GeofenceNotificationTransition = type == .geofenceEnter ? .entered : .exited
            Task { [notifications = self.notifications] in
                try? await notifications.notifyGeofenceTransition(
                    transition,
                    activityName: activityName,
                    placeName: placeName
                )
            }
        } catch { lastError = TimeTraceLocalization.errorMessage(error, fallback: "保存定位事件失败，请稍后重试。") }
    }

    private func handleGeofenceRegionState(triggerId: UUID, state: CLRegionState) {
        guard state == .inside else { return }
        let hasActiveSession = (try? sessionRepository.fetch(activityId: nil))?.contains {
            $0.placeTriggerId == triggerId && $0.deletedAt == nil && $0.endAt == nil
        } ?? false
        guard !hasActiveSession else { return }
        monitoringBeganInsideTriggerIDs.insert(triggerId)
    }

    /// Registration is an adapter concern. Persisting a place must not depend
    /// on Core Location being temporarily available on this device.
    private func reconcileGeofence(_ trigger: ActivityTrigger, fallbackMessage: String) {
        guard let latitude = trigger.latitude, let longitude = trigger.longitude, let radius = trigger.radius else {
            geofenceCapabilityStatus = .unavailable(message: fallbackMessage)
            return
        }
        do {
            let acceptedRadius = try geofence.register(
                triggerId: trigger.id,
                latitude: latitude,
                longitude: longitude,
                radius: radius
            )
            if acceptedRadius != trigger.radius {
                trigger.radius = acceptedRadius
                try activityRepository.save(trigger)
            }
            geofenceCapabilityStatus = .geofence(for: geofence.authorizationStatus)
        } catch {
            geofenceCapabilityStatus = .unavailable(message: fallbackMessage)
        }
    }

    private func normalizedPlaceName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "工作地点" : trimmed
    }

    private func requestGeofenceNotificationAuthorization() {
        Task { @MainActor [weak self, notifications = self.notifications] in
            do {
                self?.notificationCapabilityStatus = try await notifications.requestAuthorization()
                    ? .available : .needsAuthorization
            } catch {
                self?.notificationCapabilityStatus = .unavailable(message: "通知服务暂不可用")
            }
        }
    }

    private func handleNotification(_ action: ReminderNotificationAction) {
        do {
            let definitionId: UUID
            let requestId: String
            switch action {
            case .delivered(let id, let request), .start(let id, let request),
                 .snooze(let id, let request), .skip(let id, let request), .dismissed(let id, let request):
                definitionId = id; requestId = request
            }
            guard let definition = try reminderRepository.fetchDefinition(id: definitionId), definition.isEnabled else { return }
            let existing = try reminderRepository.fetchInstances().first { $0.notificationRequestId == requestId }
            if let existing {
                guard ![.completed, .abandoned, .skipped].contains(existing.status) else { return }
                if existing.status == .inProgress { return }
            }
            let instance = existing ?? ReminderInstance(reminderDefinitionId: definition.id, activityId: definition.activityId,
                                  scheduledAt: Date(), notificationRequestId: requestId)

            let eventType: ActivityEventType
            switch action {
            case .delivered:
                instance.status = .reminded
                eventType = .reminderTriggered
            case .start:
                instance.status = .started
                eventType = .reminderStartTapped
            case .snooze:
                instance.status = .snoozed
                eventType = .reminderSnoozed
                Task { [weak self] in
                    guard let self,
                          let saved = try? self.reminderRepository.fetchDefinition(id: definition.id), saved.isEnabled else { return }
                    try? await self.notifications.snooze(definitionId: saved.id, name: saved.name)
                }
            case .skip:
                instance.status = .skipped
                eventType = .reminderSkipped
            case .dismissed:
                instance.status = .ignored
                eventType = .reminderTriggered
            }
            let event = ActivityEvent(activityId: definition.activityId, eventType: eventType,
                                      timestamp: Date(), source: .notification,
                                      metadata: EventMetadata(values: ["reminderInstanceId": instance.id.uuidString]))
            let startedSession = try pipeline.ingest(event)
            if case .start = action {
                instance.status = .inProgress
                instance.sessionId = startedSession?.id
            }
            try reminderRepository.save(instance)
            refreshPublishedData()
        } catch { lastError = TimeTraceLocalization.errorMessage(error, fallback: "处理提醒失败，请稍后重试。") }
    }

    private func receiveNotificationAction(_ action: ReminderNotificationAction) {
        guard isLoaded else {
            pendingNotificationActions.append(action)
            return
        }
        handleNotification(action)
    }

    private func processPendingNotificationActions() {
        let actions = pendingNotificationActions
        pendingNotificationActions.removeAll()
        actions.forEach(handleNotification)
    }

    private func currentTimeZoneIdentifier() -> String {
        workTrigger?.timeZoneIdentifier ?? TimeZone.current.identifier
    }

    private func timeZoneMetadata() -> EventMetadata {
        EventMetadata(values: ["timeZoneIdentifier": currentTimeZoneIdentifier()])
    }

    private func workCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = TimeTraceLocalization.locale
        calendar.timeZone = TimeZone(identifier: currentTimeZoneIdentifier()) ?? .current
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }
}
