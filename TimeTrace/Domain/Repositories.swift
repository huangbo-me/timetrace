import Foundation

@MainActor
protocol ActivityRepository {
    func fetchAll() throws -> [ActivityDefinition]
    func fetch(id: UUID) throws -> ActivityDefinition?
    func save(_ activity: ActivityDefinition) throws
    func fetchTriggers(activityId: UUID?) throws -> [ActivityTrigger]
    func save(_ trigger: ActivityTrigger) throws
    func delete(_ trigger: ActivityTrigger) throws
}

@MainActor
protocol ActivityEventRepository {
    @discardableResult func append(_ event: ActivityEvent) throws -> Bool
    func fetch(activityId: UUID) throws -> [ActivityEvent]
    func fetchAll() throws -> [ActivityEvent]
    func delete(_ events: [ActivityEvent]) throws
    func saveProcessingChanges() throws
}

@MainActor
protocol ActivitySessionRepository {
    func fetch(activityId: UUID?) throws -> [ActivitySession]
    func save(_ session: ActivitySession) throws
    func delete(_ sessions: [ActivitySession]) throws
    func saveChanges() throws
}

@MainActor
protocol EvidenceRepository {
    func append(_ evidence: ActivityEvidence) throws
    func fetch(sessionId: UUID?) throws -> [ActivityEvidence]
}

@MainActor
protocol ReminderRepository {
    func fetchDefinitions() throws -> [ReminderDefinition]
    func fetchDefinition(id: UUID) throws -> ReminderDefinition?
    func save(_ definition: ReminderDefinition) throws
    func delete(_ definition: ReminderDefinition) throws
    func fetchInstances() throws -> [ReminderInstance]
    func save(_ instance: ReminderInstance) throws
    func saveChanges() throws
}
