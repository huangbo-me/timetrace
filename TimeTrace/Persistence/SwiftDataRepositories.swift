import Foundation
import SwiftData

@MainActor
final class SwiftDataActivityRepository: ActivityRepository {
    private let context: ModelContext
    init(context: ModelContext) { self.context = context }

    func fetchAll() throws -> [ActivityDefinition] {
        try context.fetch(FetchDescriptor<ActivityDefinition>()).sorted { $0.createdAt < $1.createdAt }
    }

    func fetch(id: UUID) throws -> ActivityDefinition? {
        try fetchAll().first { $0.id == id }
    }

    func save(_ activity: ActivityDefinition) throws {
        if try fetch(id: activity.id) == nil { context.insert(activity) }
        activity.updatedAt = Date()
        try context.save()
    }

    func fetchTriggers(activityId: UUID? = nil) throws -> [ActivityTrigger] {
        let values = try context.fetch(FetchDescriptor<ActivityTrigger>())
        return values.filter { activityId == nil || $0.activityId == activityId }
    }

    func save(_ trigger: ActivityTrigger) throws {
        let exists = try context.fetch(FetchDescriptor<ActivityTrigger>()).contains { $0.id == trigger.id }
        if !exists { context.insert(trigger) }
        trigger.updatedAt = Date()
        try context.save()
    }

    func delete(_ trigger: ActivityTrigger) throws {
        context.delete(trigger)
        try context.save()
    }
}

@MainActor
final class SwiftDataActivityEventRepository: ActivityEventRepository {
    private let context: ModelContext
    init(context: ModelContext) { self.context = context }

    @discardableResult
    func append(_ event: ActivityEvent) throws -> Bool {
        guard try !fetchAll().contains(where: { $0.id == event.id }) else { return false }
        context.insert(event)
        try context.save()
        return true
    }

    func fetch(activityId: UUID) throws -> [ActivityEvent] {
        try fetchAll().filter { $0.activityId == activityId }
    }

    func fetchAll() throws -> [ActivityEvent] {
        try context.fetch(FetchDescriptor<ActivityEvent>())
    }

    func delete(_ events: [ActivityEvent]) throws {
        events.forEach(context.delete)
        try context.save()
    }

    func saveProcessingChanges() throws { try context.save() }
}

@MainActor
final class SwiftDataActivitySessionRepository: ActivitySessionRepository {
    private let context: ModelContext
    init(context: ModelContext) { self.context = context }

    func fetch(activityId: UUID? = nil) throws -> [ActivitySession] {
        let values = try context.fetch(FetchDescriptor<ActivitySession>())
        return values.filter { activityId == nil || $0.activityId == activityId }.sorted { $0.startAt < $1.startAt }
    }

    func save(_ session: ActivitySession) throws {
        let exists = try fetch(activityId: nil).contains { $0.id == session.id }
        if !exists { context.insert(session) }
        try context.save()
    }

    func delete(_ sessions: [ActivitySession]) throws {
        sessions.forEach(context.delete)
        try context.save()
    }

    func saveChanges() throws { try context.save() }
}

@MainActor
final class SwiftDataEvidenceRepository: EvidenceRepository {
    private let context: ModelContext
    init(context: ModelContext) { self.context = context }

    func append(_ evidence: ActivityEvidence) throws {
        context.insert(evidence)
        try context.save()
    }

    func fetch(sessionId: UUID? = nil) throws -> [ActivityEvidence] {
        let values = try context.fetch(FetchDescriptor<ActivityEvidence>())
        return values.filter { sessionId == nil || $0.sessionId == sessionId }
    }
}

@MainActor
final class SwiftDataReminderRepository: ReminderRepository {
    private let context: ModelContext
    init(context: ModelContext) { self.context = context }

    func fetchDefinitions() throws -> [ReminderDefinition] {
        try context.fetch(FetchDescriptor<ReminderDefinition>()).sorted { $0.createdAt < $1.createdAt }
    }

    func fetchDefinition(id: UUID) throws -> ReminderDefinition? {
        try fetchDefinitions().first { $0.id == id }
    }

    func save(_ definition: ReminderDefinition) throws {
        if try fetchDefinition(id: definition.id) == nil { context.insert(definition) }
        definition.updatedAt = Date()
        try context.save()
    }

    func delete(_ definition: ReminderDefinition) throws {
        context.delete(definition)
        try context.save()
    }

    func fetchInstances() throws -> [ReminderInstance] {
        try context.fetch(FetchDescriptor<ReminderInstance>()).sorted { $0.scheduledAt > $1.scheduledAt }
    }

    func save(_ instance: ReminderInstance) throws {
        let exists = try fetchInstances().contains { $0.id == instance.id }
        if !exists { context.insert(instance) }
        instance.updatedAt = Date()
        try context.save()
    }

    func saveChanges() throws { try context.save() }
}
