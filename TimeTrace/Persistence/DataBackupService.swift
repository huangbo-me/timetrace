import Foundation
import SwiftData

struct BackupImportResult {
    let insertedCount: Int
    let refreshWarning: String?
}

struct BackupSnapshot: Codable, Sendable {
    var version = 1
    var createdAt = Date()
    var activities: [ActivityDefinitionRecord] = []
    var triggers: [ActivityTriggerRecord] = []
    var events: [ActivityEventRecord] = []
    var sessions: [ActivitySessionRecord] = []
    var evidence: [ActivityEvidenceRecord] = []
    var reminders: [ReminderDefinitionRecord] = []
    var instances: [ReminderInstanceRecord] = []

    var count: Int { activities.count + triggers.count + events.count + sessions.count + evidence.count + reminders.count + instances.count }
}

struct ActivityDefinitionRecord: Codable, Sendable {
    var id: UUID
    var name: String
    var typeRaw: String
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    @MainActor init(_ model: ActivityDefinition) {
        id = model.id
        name = model.name
        typeRaw = model.typeRaw
        isEnabled = model.isEnabled
        createdAt = model.createdAt
        updatedAt = model.updatedAt
    }

    @MainActor func makeModel() -> ActivityDefinition {
        let model = ActivityDefinition(name: "", type: .custom)
        model.id = id
        model.name = name
        model.typeRaw = typeRaw
        model.isEnabled = isEnabled
        model.createdAt = createdAt
        model.updatedAt = updatedAt
        return model
    }
}

struct ActivityTriggerRecord: Codable, Sendable {
    var id: UUID
    var activityId: UUID
    var typeRaw: String
    var isEnabled: Bool
    var isDemoData: Bool
    var latitude: Double?
    var longitude: Double?
    var radius: Double?
    var placeName: String?
    var placeTypeRaw: String
    var regionIdentifier: String?
    var weekdaysMask: Int
    var hour: Int?
    var minute: Int?
    var normalStartMinute: Int?
    var normalEndMinute: Int?
    var timeZoneIdentifier: String
    var workCalendarModeRaw: String?
    var workScheduleModeRaw: String?
    var standardWorkMinutes: Int?
    var restMinutes: Int?
    var workScheduleEnabledOverride: Bool?
    var createdAt: Date
    var updatedAt: Date

    @MainActor init(_ model: ActivityTrigger) {
        id = model.id
        activityId = model.activityId
        typeRaw = model.typeRaw
        isEnabled = model.isEnabled
        isDemoData = model.isDemoData
        latitude = model.latitude
        longitude = model.longitude
        radius = model.radius
        placeName = model.placeName
        placeTypeRaw = model.placeTypeRaw
        regionIdentifier = model.regionIdentifier
        weekdaysMask = model.weekdaysMask
        hour = model.hour
        minute = model.minute
        normalStartMinute = model.normalStartMinute
        normalEndMinute = model.normalEndMinute
        timeZoneIdentifier = model.timeZoneIdentifier
        workCalendarModeRaw = model.workCalendarModeRaw
        workScheduleModeRaw = model.workScheduleModeRaw
        standardWorkMinutes = model.standardWorkMinutes
        restMinutes = model.restMinutes
        workScheduleEnabledOverride = model.workScheduleEnabledOverride
        createdAt = model.createdAt
        updatedAt = model.updatedAt
    }

    @MainActor func makeModel() -> ActivityTrigger {
        let model = ActivityTrigger(
            activityId: activityId,
            type: .manual,
            workCalendarMode: workCalendarModeRaw.flatMap(WorkCalendarMode.init(rawValue:)) ?? .customWeekdays,
            workScheduleMode: workScheduleModeRaw.flatMap(WorkScheduleMode.init(rawValue:)) ?? .fixedWindow,
            standardWorkMinutes: standardWorkMinutes ?? 8 * 60,
            restMinutes: restMinutes ?? 0
        )
        model.id = id
        model.activityId = activityId
        model.typeRaw = typeRaw
        model.isEnabled = isEnabled
        model.isDemoData = isDemoData
        model.latitude = latitude
        model.longitude = longitude
        model.radius = radius
        model.placeName = placeName
        model.placeTypeRaw = placeTypeRaw
        model.regionIdentifier = regionIdentifier
        model.weekdaysMask = weekdaysMask
        model.hour = hour
        model.minute = minute
        model.normalStartMinute = normalStartMinute
        model.normalEndMinute = normalEndMinute
        model.timeZoneIdentifier = timeZoneIdentifier
        model.workScheduleEnabledOverride = workScheduleEnabledOverride
        model.createdAt = createdAt
        model.updatedAt = updatedAt
        return model
    }
}

struct ActivityEventRecord: Codable, Sendable {
    var id: UUID
    var activityId: UUID
    var eventTypeRaw: String
    var timestamp: Date
    var sourceRaw: String
    var metadataData: Data
    var createdAt: Date
    var dispositionRaw: String

    @MainActor init(_ model: ActivityEvent) {
        id = model.id
        activityId = model.activityId
        eventTypeRaw = model.eventTypeRaw
        timestamp = model.timestamp
        sourceRaw = model.sourceRaw
        metadataData = model.metadataData
        createdAt = model.createdAt
        dispositionRaw = model.dispositionRaw
    }

    @MainActor func makeModel() -> ActivityEvent {
        let model = ActivityEvent(activityId: activityId, eventType: .manualStart, timestamp: timestamp, source: .user)
        model.id = id
        model.activityId = activityId
        model.eventTypeRaw = eventTypeRaw
        model.timestamp = timestamp
        model.sourceRaw = sourceRaw
        model.metadataData = metadataData
        model.createdAt = createdAt
        model.dispositionRaw = dispositionRaw
        return model
    }
}

struct ActivitySessionRecord: Codable, Sendable {
    var id: UUID
    var activityId: UUID
    var placeTriggerId: UUID?
    var startAt: Date
    var endAt: Date?
    var statusRaw: String
    var startEventId: UUID?
    var endEventId: UUID?
    var confidenceRaw: String
    var timeZoneIdentifier: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

    @MainActor init(_ model: ActivitySession) {
        id = model.id
        activityId = model.activityId
        placeTriggerId = model.placeTriggerId
        startAt = model.startAt
        endAt = model.endAt
        statusRaw = model.statusRaw
        startEventId = model.startEventId
        endEventId = model.endEventId
        confidenceRaw = model.confidenceRaw
        timeZoneIdentifier = model.timeZoneIdentifier
        createdAt = model.createdAt
        updatedAt = model.updatedAt
        deletedAt = model.deletedAt
    }

    @MainActor func makeModel() -> ActivitySession {
        let model = ActivitySession(activityId: activityId, startAt: startAt)
        model.id = id
        model.activityId = activityId
        model.placeTriggerId = placeTriggerId
        model.startAt = startAt
        model.endAt = endAt
        model.statusRaw = statusRaw
        model.startEventId = startEventId
        model.endEventId = endEventId
        model.confidenceRaw = confidenceRaw
        model.timeZoneIdentifier = timeZoneIdentifier
        model.createdAt = createdAt
        model.updatedAt = updatedAt
        model.deletedAt = deletedAt
        return model
    }
}

struct ActivityEvidenceRecord: Codable, Sendable {
    var id: UUID
    var activityId: UUID
    var sessionId: UUID?
    var typeRaw: String
    var sourceRaw: String
    var timestamp: Date
    var metadataData: Data
    var createdAt: Date

    @MainActor init(_ model: ActivityEvidence) {
        id = model.id
        activityId = model.activityId
        sessionId = model.sessionId
        typeRaw = model.typeRaw
        sourceRaw = model.sourceRaw
        timestamp = model.timestamp
        metadataData = model.metadataData
        createdAt = model.createdAt
    }

    @MainActor func makeModel() -> ActivityEvidence {
        let model = ActivityEvidence(activityId: activityId, type: .system, source: .system, timestamp: timestamp)
        model.id = id
        model.activityId = activityId
        model.sessionId = sessionId
        model.typeRaw = typeRaw
        model.sourceRaw = sourceRaw
        model.timestamp = timestamp
        model.metadataData = metadataData
        model.createdAt = createdAt
        return model
    }
}

struct ReminderDefinitionRecord: Codable, Sendable {
    var id: UUID
    var activityId: UUID
    var name: String
    var hour: Int
    var minute: Int
    var weekdaysMask: Int
    var isEnabled: Bool
    var createdAt: Date
    var updatedAt: Date

    @MainActor init(_ model: ReminderDefinition) {
        id = model.id
        activityId = model.activityId
        name = model.name
        hour = model.hour
        minute = model.minute
        weekdaysMask = model.weekdaysMask
        isEnabled = model.isEnabled
        createdAt = model.createdAt
        updatedAt = model.updatedAt
    }

    @MainActor func makeModel() -> ReminderDefinition {
        let model = ReminderDefinition(activityId: activityId, name: name, hour: hour, minute: minute, weekdaysMask: weekdaysMask)
        model.id = id
        model.activityId = activityId
        model.name = name
        model.hour = hour
        model.minute = minute
        model.weekdaysMask = weekdaysMask
        model.isEnabled = isEnabled
        model.createdAt = createdAt
        model.updatedAt = updatedAt
        return model
    }
}

struct ReminderInstanceRecord: Codable, Sendable {
    var id: UUID
    var reminderDefinitionId: UUID
    var activityId: UUID
    var scheduledAt: Date
    var statusRaw: String
    var sessionId: UUID?
    var notificationRequestId: String?
    var createdAt: Date
    var updatedAt: Date

    @MainActor init(_ model: ReminderInstance) {
        id = model.id
        reminderDefinitionId = model.reminderDefinitionId
        activityId = model.activityId
        scheduledAt = model.scheduledAt
        statusRaw = model.statusRaw
        sessionId = model.sessionId
        notificationRequestId = model.notificationRequestId
        createdAt = model.createdAt
        updatedAt = model.updatedAt
    }

    @MainActor func makeModel() -> ReminderInstance {
        let model = ReminderInstance(reminderDefinitionId: reminderDefinitionId, activityId: activityId, scheduledAt: scheduledAt)
        model.id = id
        model.reminderDefinitionId = reminderDefinitionId
        model.activityId = activityId
        model.scheduledAt = scheduledAt
        model.statusRaw = statusRaw
        model.sessionId = sessionId
        model.notificationRequestId = notificationRequestId
        model.createdAt = createdAt
        model.updatedAt = updatedAt
        return model
    }
}

/// A separate context commits all seven record types together. Existing UUIDs
/// retain their local values; importing the same file twice is a no-op.
@MainActor
final class DataBackupService {
    private let container: ModelContainer
    init(container: ModelContainer) { self.container = container }

    func snapshot() throws -> BackupSnapshot {
        let context = ModelContext(container)
        var result = BackupSnapshot()
        result.activities = try context.fetch(FetchDescriptor<ActivityDefinition>()).map(ActivityDefinitionRecord.init)
        result.triggers = try context.fetch(FetchDescriptor<ActivityTrigger>()).map(ActivityTriggerRecord.init)
        result.events = try context.fetch(FetchDescriptor<ActivityEvent>()).map(ActivityEventRecord.init)
        result.sessions = try context.fetch(FetchDescriptor<ActivitySession>()).map(ActivitySessionRecord.init)
        result.evidence = try context.fetch(FetchDescriptor<ActivityEvidence>()).map(ActivityEvidenceRecord.init)
        result.reminders = try context.fetch(FetchDescriptor<ReminderDefinition>()).map(ReminderDefinitionRecord.init)
        result.instances = try context.fetch(FetchDescriptor<ReminderInstance>()).map(ReminderInstanceRecord.init)
        return result
    }

    func merge(_ snapshot: BackupSnapshot) throws -> Int {
        guard snapshot.version == 1 else { throw BackupError.unsupportedVersion }
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var inserted = 0
        do {
            var activitiesIDs = Set(try context.fetch(FetchDescriptor<ActivityDefinition>()).map(\.id))
            for record in snapshot.activities where activitiesIDs.insert(record.id).inserted {
                context.insert(record.makeModel())
                inserted += 1
            }
            var triggersIDs = Set(try context.fetch(FetchDescriptor<ActivityTrigger>()).map(\.id))
            for record in snapshot.triggers where triggersIDs.insert(record.id).inserted {
                context.insert(record.makeModel())
                inserted += 1
            }
            var eventsIDs = Set(try context.fetch(FetchDescriptor<ActivityEvent>()).map(\.id))
            for record in snapshot.events where eventsIDs.insert(record.id).inserted {
                context.insert(record.makeModel())
                inserted += 1
            }
            var sessionsIDs = Set(try context.fetch(FetchDescriptor<ActivitySession>()).map(\.id))
            for record in snapshot.sessions where sessionsIDs.insert(record.id).inserted {
                context.insert(record.makeModel())
                inserted += 1
            }
            var evidenceIDs = Set(try context.fetch(FetchDescriptor<ActivityEvidence>()).map(\.id))
            for record in snapshot.evidence where evidenceIDs.insert(record.id).inserted {
                context.insert(record.makeModel())
                inserted += 1
            }
            var remindersIDs = Set(try context.fetch(FetchDescriptor<ReminderDefinition>()).map(\.id))
            for record in snapshot.reminders where remindersIDs.insert(record.id).inserted {
                context.insert(record.makeModel())
                inserted += 1
            }
            var instancesIDs = Set(try context.fetch(FetchDescriptor<ReminderInstance>()).map(\.id))
            for record in snapshot.instances where instancesIDs.insert(record.id).inserted {
                context.insert(record.makeModel())
                inserted += 1
            }
            try context.save()
            return inserted
        } catch {
            context.rollback()
            throw error
        }
    }
}
