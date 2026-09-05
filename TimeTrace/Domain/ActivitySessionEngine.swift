import Foundation

struct SessionEngineResult {
    var sessions: [ActivitySession]
    var createdSessions: [ActivitySession]
}

struct ActivitySessionEngine {
    static let staleInterval: TimeInterval = 24 * 60 * 60

    func reconcile(events: [ActivityEvent], existingSessions: [ActivitySession],
                   now: Date = Date(), timeZoneIdentifier: String = TimeZone.current.identifier) -> SessionEngineResult {
        let ordered = events.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }

        let preserved = existingSessions.filter { $0.deletedAt != nil || $0.status == .manuallyAdjusted }
        var preservedByStart: [UUID: ActivitySession] = [:]
        var preservedEndIds = Set<UUID>()
        for session in preserved {
            if let id = session.startEventId { preservedByStart[id] = session }
            if let id = session.endEventId { preservedEndIds.insert(id) }
        }

        var automaticByStart: [UUID: ActivitySession] = [:]
        for session in existingSessions where session.deletedAt == nil && session.status != .manuallyAdjusted {
            if let id = session.startEventId { automaticByStart[id] = session }
        }

        enum Active {
            case automatic(ActivitySession, ActivityEvent)
            case preserved(ActivitySession)
        }

        var active: Active?
        var created: [ActivitySession] = []

        for event in ordered {
            if let currentActive = active {
                let start: Date
                switch currentActive {
                case .automatic(_, let startEvent): start = startEvent.timestamp
                case .preserved(let session): start = session.startAt
                }
                if event.timestamp.timeIntervalSince(start) >= Self.staleInterval {
                    if case .automatic(let session, _) = currentActive {
                        session.endAt = nil
                        session.endEventId = nil
                        session.status = .incomplete
                        session.confidence = .uncertain
                        session.updatedAt = now
                    }
                    active = nil
                }
            }

            if let preservedSession = preservedByStart[event.id] {
                event.disposition = .applied
                active = .preserved(preservedSession)
                continue
            }

            if preservedEndIds.contains(event.id) {
                event.disposition = .applied
                active = nil
                continue
            }

            if event.eventType.startsSession {
                guard active == nil else {
                    event.disposition = .redundant
                    continue
                }
                let isManual = event.eventType == .manualStart || event.source == .user
                let session: ActivitySession
                if let existing = automaticByStart[event.id] {
                    session = existing
                    session.placeTriggerId = UUID(uuidString: event.metadata.values["placeTriggerId"] ?? "")
                    session.startAt = event.timestamp
                    session.endAt = nil
                    session.endEventId = nil
                    session.status = isManual ? .manuallyAdjusted : .active
                    session.confidence = isManual ? .confirmed : .confirmed
                    session.updatedAt = now
                } else {
                    session = ActivitySession(
                        activityId: event.activityId,
                        placeTriggerId: UUID(uuidString: event.metadata.values["placeTriggerId"] ?? ""),
                        startAt: event.timestamp,
                        status: isManual ? .manuallyAdjusted : .active,
                        startEventId: event.id,
                        confidence: .confirmed,
                        timeZoneIdentifier: event.metadata.values["timeZoneIdentifier"] ?? timeZoneIdentifier
                    )
                    automaticByStart[event.id] = session
                    created.append(session)
                }
                event.disposition = .applied
                active = .automatic(session, event)
            } else if event.eventType.stopsSession {
                guard let current = active else {
                    event.disposition = .orphaned
                    continue
                }
                switch current {
                case .automatic(let session, let startEvent):
                    guard event.timestamp >= startEvent.timestamp else {
                        event.disposition = .orphaned
                        continue
                    }
                    session.endAt = event.timestamp
                    session.endEventId = event.id
                    session.status = (session.status == .manuallyAdjusted || event.eventType == .manualStop || event.source == .user)
                        ? .manuallyAdjusted : .completed
                    session.confidence = .confirmed
                    session.updatedAt = now
                    event.disposition = .applied
                    active = nil
                case .preserved:
                    event.disposition = .redundant
                }
            } else {
                event.disposition = .applied
            }
        }

        if case .automatic(let session, let startEvent) = active {
            if now.timeIntervalSince(startEvent.timestamp) >= Self.staleInterval {
                session.status = .incomplete
                session.confidence = .uncertain
            } else if session.status != .manuallyAdjusted {
                session.status = .active
            }
            session.updatedAt = now
        }

        return SessionEngineResult(sessions: existingSessions + created, createdSessions: created)
    }
}
