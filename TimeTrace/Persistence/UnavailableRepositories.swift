import Foundation

enum PersistenceUnavailableError: LocalizedError {
    case unavailable

    var errorDescription: String? { "本地存储暂不可用" }
}

/// Safe adapters used only when SwiftData cannot open. They preserve the
/// presentation seam and turn writes into recoverable feature errors instead
/// of terminating the application during composition.
@MainActor
final class UnavailableActivityRepository: ActivityRepository {
    func fetchAll() throws -> [ActivityDefinition] { [] }
    func fetch(id: UUID) throws -> ActivityDefinition? { nil }
    func save(_ activity: ActivityDefinition) throws { throw PersistenceUnavailableError.unavailable }
    func fetchTriggers(activityId: UUID?) throws -> [ActivityTrigger] { [] }
    func save(_ trigger: ActivityTrigger) throws { throw PersistenceUnavailableError.unavailable }
    func delete(_ trigger: ActivityTrigger) throws { throw PersistenceUnavailableError.unavailable }
}

@MainActor
final class UnavailableEventRepository: ActivityEventRepository {
    func append(_ event: ActivityEvent) throws -> Bool { throw PersistenceUnavailableError.unavailable }
    func fetch(activityId: UUID) throws -> [ActivityEvent] { [] }
    func fetchAll() throws -> [ActivityEvent] { [] }
    func delete(_ events: [ActivityEvent]) throws { throw PersistenceUnavailableError.unavailable }
    func saveProcessingChanges() throws { throw PersistenceUnavailableError.unavailable }
}

@MainActor
final class UnavailableSessionRepository: ActivitySessionRepository {
    func fetch(activityId: UUID?) throws -> [ActivitySession] { [] }
    func save(_ session: ActivitySession) throws { throw PersistenceUnavailableError.unavailable }
    func delete(_ sessions: [ActivitySession]) throws { throw PersistenceUnavailableError.unavailable }
    func saveChanges() throws { throw PersistenceUnavailableError.unavailable }
}

@MainActor
final class UnavailableReminderRepository: ReminderRepository {
    func fetchDefinitions() throws -> [ReminderDefinition] { [] }
    func fetchDefinition(id: UUID) throws -> ReminderDefinition? { nil }
    func save(_ definition: ReminderDefinition) throws { throw PersistenceUnavailableError.unavailable }
    func delete(_ definition: ReminderDefinition) throws { throw PersistenceUnavailableError.unavailable }
    func fetchInstances() throws -> [ReminderInstance] { [] }
    func save(_ instance: ReminderInstance) throws { throw PersistenceUnavailableError.unavailable }
    func saveChanges() throws { throw PersistenceUnavailableError.unavailable }
}
