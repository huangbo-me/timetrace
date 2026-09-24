import Foundation
import SwiftData

enum ActivityType: String, Codable, CaseIterable, Identifiable {
    case work, study, exercise, focus, custom
    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .work: "工作"
        case .study: "学习"
        case .exercise: "健身"
        case .focus: "专注"
        case .custom: "自定义"
        }
    }
}

/// Describes the purpose of a saved place. This is intentionally separate
/// from `ActivityType`: a place can be categorised without changing the
/// activity that a geofence currently records.
enum PlaceType: String, Codable, CaseIterable, Identifiable {
    case work, study, exercise, home, dining, shopping, healthcare, leisure, other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .work: "工作"
        case .study: "学习"
        case .exercise: "运动"
        case .home: "居住"
        case .dining: "餐饮"
        case .shopping: "购物"
        case .healthcare: "医疗"
        case .leisure: "休闲"
        case .other: "其他"
        }
    }

    var systemImage: String {
        switch self {
        case .work: "briefcase.fill"
        case .study: "book.closed.fill"
        case .exercise: "figure.run"
        case .home: "house.fill"
        case .dining: "fork.knife"
        case .shopping: "bag.fill"
        case .healthcare: "cross.case.fill"
        case .leisure: "gamecontroller.fill"
        case .other: "mappin.and.ellipse"
        }
    }
}

enum ActivityTriggerType: String, Codable, CaseIterable {
    case geofence, schedule, manual, appUsage
}

enum ActivityEventType: String, Codable {
    case geofenceEnter, geofenceExit
    case manualStart, manualStop
    case reminderTriggered, reminderStartTapped, reminderSnoozed, reminderSkipped
    case usageThresholdReached
    case sessionAdjusted, sessionDeleted, anomalyDismissed, reminderCompleted, reminderAbandoned

    var startsSession: Bool {
        self == .geofenceEnter || self == .manualStart || self == .reminderStartTapped
    }

    var stopsSession: Bool {
        self == .geofenceExit || self == .manualStop
    }
}

enum ActivityEventSource: String, Codable {
    case coreLocation, notification, user, deviceActivity, system
}

enum EventProcessingDisposition: String, Codable {
    case pending, applied, redundant, orphaned
}

enum ActivitySessionStatus: String, Codable {
    case active, completed, incomplete, manuallyAdjusted
}

enum ActivityConfidence: String, Codable {
    case confirmed, inferred, uncertain
}

enum ReminderStatus: String, Codable {
    case scheduled, reminded, started, snoozed, skipped, ignored, inProgress, completed, abandoned
}

enum EvidenceType: String, Codable {
    case manualConfirmation, locationPresence, appUsage, system
}

struct EventMetadata: Codable, Equatable {
    var version: Int = 1
    var values: [String: String] = [:]

    static let empty = EventMetadata()
}

enum WorkScheduleEditScope: String, Codable {
    case futureOnly
    case allHistory
}

enum WorkCalendarMode: String, Codable, CaseIterable, Identifiable {
    case chinaStatutory
    case customWeekdays

    var id: String { rawValue }
}

enum WorkScheduleMode: String, Codable, CaseIterable, Identifiable {
    case fixedWindow
    case flexibleDuration

    var id: String { rawValue }
}

struct WorkScheduleSnapshot: Codable, Equatable {
    static let adjustmentKind = "workSchedule"

    let weekdaysMask: Int
    let startMinute: Int?
    let endMinute: Int?
    let timeZoneIdentifier: String
    let isEnabled: Bool
    let calendarMode: WorkCalendarMode
    let scheduleMode: WorkScheduleMode
    let standardWorkMinutes: Int
    let restMinutes: Int

    init?(weekdaysMask: Int, startMinute: Int?, endMinute: Int?,
          timeZoneIdentifier: String, isEnabled: Bool,
          calendarMode: WorkCalendarMode = .customWeekdays,
          scheduleMode: WorkScheduleMode = .fixedWindow,
          standardWorkMinutes: Int = 8 * 60,
          restMinutes: Int = 0) {
        let boundedMask = weekdaysMask & 0b1111111
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        guard (30...960).contains(standardWorkMinutes), standardWorkMinutes.isMultiple(of: 30),
              (0...720).contains(restMinutes), restMinutes.isMultiple(of: 30) else { return nil }
        if isEnabled && scheduleMode == .fixedWindow {
            guard boundedMask != 0,
                  let startMinute, let endMinute,
                  (0..<1_440).contains(startMinute),
                  (0..<1_440).contains(endMinute),
                  startMinute != endMinute else { return nil }
        } else if isEnabled {
            guard boundedMask != 0 else { return nil }
        }
        self.weekdaysMask = boundedMask
        self.startMinute = startMinute
        self.endMinute = endMinute
        self.timeZoneIdentifier = timeZone.identifier
        self.isEnabled = isEnabled
        self.calendarMode = calendarMode
        self.scheduleMode = scheduleMode
        self.standardWorkMinutes = standardWorkMinutes
        self.restMinutes = restMinutes
    }

    init?(metadata: EventMetadata) {
        let values = metadata.values
        guard let enabledRaw = values["workScheduleEnabled"],
              let enabled = Bool(enabledRaw),
              let maskRaw = values["workScheduleWeekdaysMask"],
              let mask = Int(maskRaw),
              let timeZoneIdentifier = values["workScheduleTimeZoneIdentifier"] else { return nil }
        let start = values["workScheduleStartMinute"].flatMap(Int.init)
        let end = values["workScheduleEndMinute"].flatMap(Int.init)
        let calendarMode: WorkCalendarMode
        if let rawValue = values["workScheduleCalendarMode"] {
            guard let decoded = WorkCalendarMode(rawValue: rawValue) else { return nil }
            calendarMode = decoded
        } else {
            calendarMode = .customWeekdays
        }
        let scheduleMode: WorkScheduleMode
        if let rawValue = values["workScheduleMode"] {
            guard let decoded = WorkScheduleMode(rawValue: rawValue) else { return nil }
            scheduleMode = decoded
        } else {
            scheduleMode = .fixedWindow
        }
        let standardWorkMinutes: Int
        if let rawValue = values["workScheduleStandardMinutes"] {
            guard let decoded = Int(rawValue) else { return nil }
            standardWorkMinutes = decoded
        } else {
            standardWorkMinutes = 8 * 60
        }
        let restMinutes: Int
        if let rawValue = values["workScheduleRestMinutes"] {
            guard let decoded = Int(rawValue) else { return nil }
            restMinutes = decoded
        } else {
            restMinutes = 0
        }
        self.init(weekdaysMask: mask, startMinute: start, endMinute: end,
                  timeZoneIdentifier: timeZoneIdentifier, isEnabled: enabled,
                  calendarMode: calendarMode, scheduleMode: scheduleMode,
                  standardWorkMinutes: standardWorkMinutes, restMinutes: restMinutes)
    }

    func adding(to metadata: EventMetadata) -> EventMetadata {
        var result = metadata
        result.values["workScheduleEnabled"] = String(isEnabled)
        result.values["workScheduleWeekdaysMask"] = String(weekdaysMask)
        result.values["workScheduleTimeZoneIdentifier"] = timeZoneIdentifier
        result.values["workScheduleStartMinute"] = startMinute.map(String.init)
        result.values["workScheduleEndMinute"] = endMinute.map(String.init)
        result.values["workScheduleCalendarMode"] = calendarMode.rawValue
        result.values["workScheduleMode"] = scheduleMode.rawValue
        result.values["workScheduleStandardMinutes"] = String(standardWorkMinutes)
        result.values["workScheduleRestMinutes"] = String(restMinutes)
        return result
    }
}

extension ActivityTrigger {
    var workScheduleSnapshot: WorkScheduleSnapshot? {
        WorkScheduleSnapshot(
            weekdaysMask: weekdaysMask,
            startMinute: normalStartMinute,
            endMinute: normalEndMinute,
            timeZoneIdentifier: timeZoneIdentifier,
            isEnabled: normalStartMinute != nil || normalEndMinute != nil,
            calendarMode: workCalendarMode,
            scheduleMode: workScheduleMode,
            standardWorkMinutes: standardWorkMinutes,
            restMinutes: restMinutes
        )
    }
}

enum WorkScheduleResolver {
    static func snapshot(for session: ActivitySession, events: [ActivityEvent],
                         currentPlace: ActivityTrigger?) -> WorkScheduleSnapshot? {
        guard session.placeTriggerId != nil else { return nil }
        let revisions = events.filter { event in
            event.eventType == .sessionAdjusted &&
            event.metadata.values["adjustmentKind"] == WorkScheduleSnapshot.adjustmentKind &&
            (event.metadata.values["sessionId"] == session.id.uuidString ||
             event.metadata.values["startEventId"] == session.startEventId?.uuidString)
        }
        if let latestRevision = revisions.sorted(by: revisionOrder).last {
            return WorkScheduleSnapshot(metadata: latestRevision.metadata)
        }
        if let startEventId = session.startEventId,
           let startEvent = events.first(where: { $0.id == startEventId }),
           let snapshot = WorkScheduleSnapshot(metadata: startEvent.metadata) {
            return snapshot
        }
        guard let currentPlace,
              currentPlace.id == session.placeTriggerId,
              currentPlace.placeType == .work else { return nil }
        return currentPlace.workScheduleSnapshot
    }

    private static func revisionOrder(_ lhs: ActivityEvent, _ rhs: ActivityEvent) -> Bool {
        if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

@Model
final class ActivityDefinition {
    var id: UUID = UUID()
    var name: String = ""
    var typeRaw: String = ActivityType.custom.rawValue
    var isEnabled: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var type: ActivityType {
        get { ActivityType(rawValue: typeRaw) ?? .custom }
        set { typeRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), name: String, type: ActivityType, isEnabled: Bool = true,
         createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.typeRaw = type.rawValue
        self.isEnabled = isEnabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

@Model
final class ActivityTrigger {
    var id: UUID = UUID()
    var activityId: UUID = UUID()
    var typeRaw: String = ActivityTriggerType.manual.rawValue
    var isEnabled: Bool = true
    /// Debug demo locations are displayed with the generated history, but are
    /// never registered with Core Location or treated as a user's real place.
    var isDemoData: Bool = false
    var latitude: Double?
    var longitude: Double?
    var radius: Double?
    /// A user-facing label for a geofence, kept separate from the activity it records.
    /// Existing stores may not have a value, so this remains optional for migration.
    var placeName: String?
    /// Kept as a raw value so existing SwiftData stores receive the default work type.
    var placeTypeRaw: String = PlaceType.work.rawValue
    var regionIdentifier: String?
    var weekdaysMask: Int = 0
    var hour: Int?
    var minute: Int?
    var normalStartMinute: Int?
    var normalEndMinute: Int?
    var timeZoneIdentifier: String = TimeZone.current.identifier
    var workCalendarModeRaw: String = WorkCalendarMode.customWeekdays.rawValue
    var workScheduleModeRaw: String = WorkScheduleMode.fixedWindow.rawValue
    var standardWorkMinutes: Int = 8 * 60
    var restMinutes: Int = 0
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var type: ActivityTriggerType {
        get { ActivityTriggerType(rawValue: typeRaw) ?? .manual }
        set { typeRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), activityId: UUID, type: ActivityTriggerType, isEnabled: Bool = true,
         isDemoData: Bool = false,
         latitude: Double? = nil, longitude: Double? = nil, radius: Double? = nil,
         placeName: String? = nil, placeType: PlaceType = .work,
         regionIdentifier: String? = nil, weekdaysMask: Int = 0, hour: Int? = nil,
         minute: Int? = nil, normalStartMinute: Int? = nil, normalEndMinute: Int? = nil,
         timeZoneIdentifier: String = TimeZone.current.identifier,
         workCalendarMode: WorkCalendarMode = .customWeekdays,
         workScheduleMode: WorkScheduleMode = .fixedWindow,
         standardWorkMinutes: Int = 8 * 60, restMinutes: Int = 0) {
        self.id = id
        self.activityId = activityId
        self.typeRaw = type.rawValue
        self.isEnabled = isEnabled
        self.isDemoData = isDemoData
        self.latitude = latitude
        self.longitude = longitude
        self.radius = radius
        self.placeName = placeName
        self.placeTypeRaw = placeType.rawValue
        self.regionIdentifier = regionIdentifier
        self.weekdaysMask = weekdaysMask
        self.hour = hour
        self.minute = minute
        self.normalStartMinute = normalStartMinute
        self.normalEndMinute = normalEndMinute
        self.timeZoneIdentifier = timeZoneIdentifier
        self.workCalendarModeRaw = workCalendarMode.rawValue
        self.workScheduleModeRaw = workScheduleMode.rawValue
        self.standardWorkMinutes = standardWorkMinutes
        self.restMinutes = restMinutes
    }

    var displayPlaceName: String {
        let trimmed = placeName?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? "工作地点" : trimmed
    }

    var placeType: PlaceType {
        get { PlaceType(rawValue: placeTypeRaw) ?? .work }
        set { placeTypeRaw = newValue.rawValue }
    }

    var workCalendarMode: WorkCalendarMode {
        get { WorkCalendarMode(rawValue: workCalendarModeRaw) ?? .customWeekdays }
        set { workCalendarModeRaw = newValue.rawValue }
    }

    var workScheduleMode: WorkScheduleMode {
        get { WorkScheduleMode(rawValue: workScheduleModeRaw) ?? .fixedWindow }
        set { workScheduleModeRaw = newValue.rawValue }
    }
}

@Model
final class ActivityEvent {
    var id: UUID = UUID()
    var activityId: UUID = UUID()
    var eventTypeRaw: String = ActivityEventType.manualStart.rawValue
    var timestamp: Date = Date()
    var sourceRaw: String = ActivityEventSource.user.rawValue
    var metadataData: Data = Data()
    var createdAt: Date = Date()
    var dispositionRaw: String = EventProcessingDisposition.pending.rawValue

    var eventType: ActivityEventType {
        get { ActivityEventType(rawValue: eventTypeRaw) ?? .manualStart }
        set { eventTypeRaw = newValue.rawValue }
    }

    var source: ActivityEventSource {
        get { ActivityEventSource(rawValue: sourceRaw) ?? .system }
        set { sourceRaw = newValue.rawValue }
    }

    var disposition: EventProcessingDisposition {
        get { EventProcessingDisposition(rawValue: dispositionRaw) ?? .pending }
        set { dispositionRaw = newValue.rawValue }
    }

    var metadata: EventMetadata {
        get { (try? JSONDecoder().decode(EventMetadata.self, from: metadataData)) ?? .empty }
        set { metadataData = (try? JSONEncoder().encode(newValue)) ?? Data() }
    }

    init(id: UUID = UUID(), activityId: UUID, eventType: ActivityEventType,
         timestamp: Date, source: ActivityEventSource, metadata: EventMetadata = .empty,
         createdAt: Date = Date()) {
        self.id = id
        self.activityId = activityId
        self.eventTypeRaw = eventType.rawValue
        self.timestamp = timestamp
        self.sourceRaw = source.rawValue
        self.metadataData = (try? JSONEncoder().encode(metadata)) ?? Data()
        self.createdAt = createdAt
    }
}

@Model
final class ActivitySession {
    var id: UUID = UUID()
    var activityId: UUID = UUID()
    /// The geofence that started this session. Manual and legacy sessions have no place.
    var placeTriggerId: UUID?
    var startAt: Date = Date()
    var endAt: Date?
    var statusRaw: String = ActivitySessionStatus.active.rawValue
    var startEventId: UUID?
    var endEventId: UUID?
    var confidenceRaw: String = ActivityConfidence.confirmed.rawValue
    var timeZoneIdentifier: String = TimeZone.current.identifier
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var deletedAt: Date?

    var status: ActivitySessionStatus {
        get { ActivitySessionStatus(rawValue: statusRaw) ?? .active }
        set { statusRaw = newValue.rawValue }
    }

    var confidence: ActivityConfidence {
        get { ActivityConfidence(rawValue: confidenceRaw) ?? .uncertain }
        set { confidenceRaw = newValue.rawValue }
    }

    var duration: TimeInterval? {
        guard let endAt else { return nil }
        return max(0, endAt.timeIntervalSince(startAt))
    }

    init(id: UUID = UUID(), activityId: UUID, placeTriggerId: UUID? = nil, startAt: Date, endAt: Date? = nil,
         status: ActivitySessionStatus = .active, startEventId: UUID? = nil,
         endEventId: UUID? = nil, confidence: ActivityConfidence = .confirmed,
         timeZoneIdentifier: String = TimeZone.current.identifier,
         createdAt: Date = Date(), updatedAt: Date = Date(), deletedAt: Date? = nil) {
        self.id = id
        self.activityId = activityId
        self.placeTriggerId = placeTriggerId
        self.startAt = startAt
        self.endAt = endAt
        self.statusRaw = status.rawValue
        self.startEventId = startEventId
        self.endEventId = endEventId
        self.confidenceRaw = confidence.rawValue
        self.timeZoneIdentifier = timeZoneIdentifier
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.deletedAt = deletedAt
    }
}

@Model
final class ActivityEvidence {
    var id: UUID = UUID()
    var activityId: UUID = UUID()
    var sessionId: UUID?
    var typeRaw: String = EvidenceType.system.rawValue
    var sourceRaw: String = ActivityEventSource.system.rawValue
    var timestamp: Date = Date()
    var metadataData: Data = Data()
    var createdAt: Date = Date()

    init(id: UUID = UUID(), activityId: UUID, sessionId: UUID? = nil, type: EvidenceType,
         source: ActivityEventSource, timestamp: Date, metadata: EventMetadata = .empty) {
        self.id = id
        self.activityId = activityId
        self.sessionId = sessionId
        self.typeRaw = type.rawValue
        self.sourceRaw = source.rawValue
        self.timestamp = timestamp
        self.metadataData = (try? JSONEncoder().encode(metadata)) ?? Data()
    }
}

@Model
final class ReminderDefinition {
    var id: UUID = UUID()
    var activityId: UUID = UUID()
    var name: String = ""
    var hour: Int = 21
    var minute: Int = 0
    var weekdaysMask: Int = 0b1111111
    var isEnabled: Bool = true
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    init(id: UUID = UUID(), activityId: UUID, name: String, hour: Int, minute: Int,
         weekdaysMask: Int, isEnabled: Bool = true) {
        self.id = id
        self.activityId = activityId
        self.name = name
        self.hour = hour
        self.minute = minute
        self.weekdaysMask = weekdaysMask
        self.isEnabled = isEnabled
    }
}

@Model
final class ReminderInstance {
    var id: UUID = UUID()
    var reminderDefinitionId: UUID = UUID()
    var activityId: UUID = UUID()
    var scheduledAt: Date = Date()
    var statusRaw: String = ReminderStatus.scheduled.rawValue
    var sessionId: UUID?
    var notificationRequestId: String?
    var createdAt: Date = Date()
    var updatedAt: Date = Date()

    var status: ReminderStatus {
        get { ReminderStatus(rawValue: statusRaw) ?? .scheduled }
        set { statusRaw = newValue.rawValue }
    }

    init(id: UUID = UUID(), reminderDefinitionId: UUID, activityId: UUID,
         scheduledAt: Date, status: ReminderStatus = .scheduled,
         notificationRequestId: String? = nil) {
        self.id = id
        self.reminderDefinitionId = reminderDefinitionId
        self.activityId = activityId
        self.scheduledAt = scheduledAt
        self.statusRaw = status.rawValue
        self.notificationRequestId = notificationRequestId
    }
}

extension Int {
    func containsWeekday(_ calendarWeekday: Int) -> Bool {
        let bit = Swift.max(0, Swift.min(6, calendarWeekday - 1))
        return self & (1 << bit) != 0
    }
}
