import Foundation
import OSLog

@MainActor
final class EventPipeline {
    private let events: ActivityEventRepository
    private let sessions: ActivitySessionRepository
    private let engine: ActivitySessionEngine
    private let logger = Logger(subsystem: "com.chronora.time.trace", category: "EventPipeline")

    init(events: ActivityEventRepository, sessions: ActivitySessionRepository,
         engine: ActivitySessionEngine = ActivitySessionEngine()) {
        self.events = events
        self.sessions = sessions
        self.engine = engine
    }

    @discardableResult
    func ingest(_ event: ActivityEvent, timeZoneIdentifier: String = TimeZone.current.identifier,
                now: Date = Date()) throws -> ActivitySession? {
        let inserted = try events.append(event)
        let activityEvents = try events.fetch(activityId: event.activityId)
        let existing = try sessions.fetch(activityId: event.activityId)
        let result = engine.reconcile(events: activityEvents, existingSessions: existing,
                                      now: now, timeZoneIdentifier: timeZoneIdentifier)
        for session in result.createdSessions { try sessions.save(session) }
        try sessions.saveChanges()
        try events.saveProcessingChanges()
        logger.info("Processed event type=\(event.eventTypeRaw, privacy: .public) inserted=\(inserted)")
        return result.sessions.first { $0.startEventId == event.id }
    }

    func refreshStaleSessions(activityId: UUID, timeZoneIdentifier: String,
                              now: Date = Date()) throws {
        let result = engine.reconcile(
            events: try events.fetch(activityId: activityId),
            existingSessions: try sessions.fetch(activityId: activityId),
            now: now,
            timeZoneIdentifier: timeZoneIdentifier
        )
        for session in result.createdSessions { try sessions.save(session) }
        try sessions.saveChanges()
        try events.saveProcessingChanges()
    }
}
