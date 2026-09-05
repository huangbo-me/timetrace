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
    @Published private(set) var activities: [ActivityDefinition] = []
    @Published private(set) var triggers: [ActivityTrigger] = []
    @Published private(set) var events: [ActivityEvent] = []
    @Published private(set) var sessions: [ActivitySession] = []
    @Published private(set) var reminders: [ReminderDefinition] = []
    @Published private(set) var reminderInstances: [ReminderInstance] = []
    @Published private(set) var locationAuthorizationStatus: CLAuthorizationStatus
    @Published private(set) var iCloudSyncStatus: ICloudSyncStatus = .checking
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
    var isOnboarded: Bool { workActivity != nil && workTrigger != nil }
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
         notifications: NotificationServicing? = nil) {
        let geofence = geofence ?? CoreLocationGeofenceService()
        self.geofence = geofence
        self.locationAuthorizationStatus = geofence.authorizationStatus
        do {
            let persistence = try PersistenceController(inMemory: inMemory)
            isCloudKitEnabled = persistence.isCloudKitEnabled
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
            fatalError("无法初始化本地数据库：\(error.localizedDescription)")
        }
        self.notifications = notifications ?? LocalNotificationService()
        self.analytics = AnalyticsService()

        self.geofence.onEvent = { [weak self] event in self?.handleGeofence(event) }
        self.geofence.onAuthorizationChange = { [weak self] status in
            self?.locationAuthorizationStatus = status
        }
        self.notifications.onAction = { [weak self] action in self?.receiveNotificationAction(action) }
        self.notifications.registerCategories()
        refreshICloudSyncStatus()
    }

    func load() {
        refreshICloudSyncStatus()
        do {
            try refreshDataAndRestoreGeofence()
            if isCloudKitEnabled && !isOnboarded {
                restoreInitialCloudDataBeforeOnboarding()
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
        } catch {
            lastError = TimeTraceLocalization.errorMessage(error, fallback: "刷新 iCloud 数据失败，请稍后重试。")
        }
    }

    /// CloudKit has no single "all records are synced" callback. This checks
    /// the account and container availability, which is the actionable status
    /// a person can resolve from Settings.
    func refreshICloudSyncStatus() {
        guard isCloudKitEnabled else {
            iCloudSyncStatus = .notEnabled
            return
        }

        iCloudSyncStatus = .checking
        let container = CKContainer(identifier: PersistenceController.cloudKitContainerIdentifier)
        container.accountStatus { [weak self] accountStatus, error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                guard error == nil else {
                    self.iCloudSyncStatus = .unavailable
                    return
                }
                switch accountStatus {
                case .available:
                    self.iCloudSyncStatus = .enabled
                    self.refreshSyncedData()
                case .noAccount:
                    self.iCloudSyncStatus = .signedOut
                case .restricted:
                    self.iCloudSyncStatus = .restricted
                case .couldNotDetermine, .temporarilyUnavailable:
                    self.iCloudSyncStatus = .unavailable
                @unknown default:
                    self.iCloudSyncStatus = .unavailable
                }
            }
        }
    }

    func finishOnboarding(latitude: Double, longitude: Double, radius: Double,
                          weekdaysMask: Int, normalStartMinute: Int?, normalEndMinute: Int?,
                          placeName: String = "工作地点") {
        do {
            let work = ActivityDefinition(name: "工作", type: .work)
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
            let acceptedRadius = try geofence.register(
                triggerId: trigger.id,
                latitude: latitude,
                longitude: longitude,
                radius: radius
            )
            trigger.radius = acceptedRadius
            try activityRepository.save(trigger)
            geofence.requestAlwaysAuthorization()
            requestGeofenceNotificationAuthorization()
            load()
        } catch { lastError = TimeTraceLocalization.errorMessage(error, fallback: "保存地点失败，请稍后重试。") }
    }

    func addWorkplace(latitude: Double, longitude: Double, radius: Double, placeName: String,
                      placeType: PlaceType = .work) {
        guard let workActivity else { return }
        do {
            let referenceTrigger = workTrigger
            let trigger = ActivityTrigger(
                activityId: workActivity.id,
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
            let accepted = try geofence.register(triggerId: trigger.id, latitude: latitude,
                                                  longitude: longitude, radius: radius)
            trigger.radius = accepted
            try activityRepository.save(trigger)
            refreshPublishedData()
        } catch { lastError = TimeTraceLocalization.errorMessage(error, fallback: "添加地点失败，请稍后重试。") }
    }

    func updateWorkplace(triggerId: UUID, latitude: Double, longitude: Double, radius: Double,
                         placeName: String, placeType: PlaceType = .work) {
        guard let trigger = triggers.first(where: { $0.id == triggerId && $0.type == .geofence }) else { return }
        do {
            let accepted = try geofence.register(triggerId: trigger.id, latitude: latitude,
                                                  longitude: longitude, radius: radius)
            trigger.latitude = latitude
            trigger.longitude = longitude
            trigger.radius = accepted
            trigger.placeName = normalizedPlaceName(placeName)
            trigger.placeType = placeType
            trigger.timeZoneIdentifier = TimeZone.current.identifier
            try activityRepository.save(trigger)
            refreshPublishedData()
        } catch { lastError = TimeTraceLocalization.errorMessage(error, fallback: "更新地点失败，请稍后重试。") }
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

    func adjustSession(_ session: ActivitySession, startAt: Date, endAt: Date?) {
        guard endAt == nil || endAt! >= startAt else { return }
        do {
            let values = [
                "sessionId": session.id.uuidString,
                "oldStart": session.startAt.ISO8601Format(),
                "newStart": startAt.ISO8601Format(),
                "oldEnd": session.endAt?.ISO8601Format() ?? "",
                "newEnd": endAt?.ISO8601Format() ?? ""
            ]
            _ = try pipeline.ingest(ActivityEvent(activityId: session.activityId, eventType: .sessionAdjusted,
                                                  timestamp: Date(), source: .user,
                                                  metadata: EventMetadata(values: values)))
            session.startAt = startAt
            session.endAt = endAt
            session.status = .manuallyAdjusted
            session.confidence = .confirmed
            session.updatedAt = Date()
            try sessionRepository.saveChanges()
            refreshPublishedData()
        } catch { lastError = TimeTraceLocalization.errorMessage(error, fallback: "修改工作记录失败，请稍后重试。") }
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

    func deleteSession(_ session: ActivitySession) {
        do {
            _ = try pipeline.ingest(ActivityEvent(activityId: session.activityId, eventType: .sessionDeleted,
                                                  timestamp: Date(), source: .user,
                                                  metadata: EventMetadata(values: ["sessionId": session.id.uuidString])))
            session.deletedAt = Date()
            session.updatedAt = Date()
            try sessionRepository.saveChanges()
            refreshPublishedData()
        } catch { lastError = TimeTraceLocalization.errorMessage(error, fallback: "删除工作记录失败，请稍后重试。") }
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
            _ = try await notifications.requestAuthorization()
            try await notifications.schedule(reminder)
            refreshPublishedData()
        } catch { lastError = TimeTraceLocalization.errorMessage(error, fallback: "创建提醒失败，请稍后重试。") }
    }

    func deleteReminder(_ reminder: ReminderDefinition) {
        do {
            notifications.cancel(reminder)
            try reminderRepository.delete(reminder)
            refreshPublishedData()
        } catch { lastError = TimeTraceLocalization.errorMessage(error, fallback: "删除提醒失败，请稍后重试。") }
    }

    func finishReminderInstance(_ instance: ReminderInstance, abandoned: Bool) {
        do {
            if let sessionId = instance.sessionId,
               let session = sessions.first(where: { $0.id == sessionId && $0.endAt == nil }) {
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

    func periodSummary(interval: DateInterval, previous: DateInterval) -> PeriodActivitySummary? {
        guard let workActivity else { return nil }
        return analytics.periodSummary(
            sessions: sessions,
            activityId: workActivity.id,
            interval: interval,
            previous: previous,
            calendar: workCalendar()
        )
    }

    func placeSummaries(interval: DateInterval) -> [PlaceActivitySummary] {
        guard let workActivity else { return [] }
        return analytics.placeSummaries(sessions: sessions, activityId: workActivity.id, interval: interval)
    }

    func session(for instance: ReminderInstance) -> ActivitySession? {
        sessions.first { $0.id == instance.sessionId }
    }

    private func refreshPublishedData() {
        do {
            activities = try activityRepository.fetchAll()
            triggers = try activityRepository.fetchTriggers(activityId: nil)
            events = try eventRepository.fetchAll()
            sessions = try sessionRepository.fetch(activityId: nil).filter { $0.deletedAt == nil }
            reminders = try reminderRepository.fetchDefinitions()
            reminderInstances = try reminderRepository.fetchInstances()
        } catch { lastError = TimeTraceLocalization.errorMessage(error, fallback: "刷新本地数据失败，请稍后重试。") }
    }

    private func refreshDataAndRestoreGeofence() throws {
        activities = try activityRepository.fetchAll()
        triggers = try activityRepository.fetchTriggers(activityId: nil)
        if let workActivity, let trigger = workTrigger {
            try pipeline.refreshStaleSessions(activityId: workActivity.id,
                                              timeZoneIdentifier: trigger.timeZoneIdentifier)
            for trigger in workTriggers where !trigger.isDemoData {
                if let latitude = trigger.latitude, let longitude = trigger.longitude, let radius = trigger.radius {
                    geofence.restoreAndRequestState(triggerId: trigger.id, latitude: latitude,
                                                    longitude: longitude, radius: radius)
                }
            }
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

    /// SwiftData's CloudKit mirror is asynchronous. On a freshly installed
    /// app, the first fetch is commonly empty even though a private database
    /// already exists. Do not show onboarding until we have given that mirror
    /// a few chances to merge the previous device's data.
    private func restoreInitialCloudDataBeforeOnboarding() {
        guard !isRestoringICloudData else { return }
        isRestoringICloudData = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            for delay in [1, 3, 6] {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { return }
                try? self.refreshDataAndRestoreGeofence()
                if self.isOnboarded { break }
            }
            self.isRestoringICloudData = false
            self.finishLoading()
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
            switch systemEvent {
            case .entered(let id, let date): (triggerId, timestamp, type) = (id, date, .geofenceEnter)
            case .exited(let id, let date): (triggerId, timestamp, type) = (id, date, .geofenceExit)
            }
            guard let trigger = try activityRepository.fetchTriggers(activityId: nil)
                .first(where: { $0.id == triggerId && $0.type == .geofence }) else { return }
            let activityId = trigger.activityId
            var metadata = timeZoneMetadata()
            metadata.values["placeTriggerId"] = trigger.id.uuidString
            _ = try pipeline.ingest(ActivityEvent(activityId: activityId, eventType: type,
                                                  timestamp: timestamp, source: .coreLocation,
                                                  metadata: metadata),
                                    timeZoneIdentifier: currentTimeZoneIdentifier())
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

    private func normalizedPlaceName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "工作地点" : trimmed
    }

    private func requestGeofenceNotificationAuthorization() {
        Task { [notifications = self.notifications] in
            _ = try? await notifications.requestAuthorization()
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
            guard let definition = try reminderRepository.fetchDefinition(id: definitionId) else { return }
            let instance = try reminderRepository.fetchInstances().first {
                $0.notificationRequestId == requestId && ![.completed, .abandoned, .skipped].contains($0.status)
            } ?? ReminderInstance(reminderDefinitionId: definition.id, activityId: definition.activityId,
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
                Task { try? await notifications.snooze(definitionId: definition.id, name: definition.name) }
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
