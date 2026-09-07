import Foundation

struct SessionEngineResult {
    var sessions: [ActivitySession]
    var createdSessions: [ActivitySession]
}

struct ActivitySessionEngine {
    static let staleInterval: TimeInterval = 24 * 60 * 60
    /// Core Location can deliver the same region exit more than once while it
    /// is settling a boundary transition.  Only treat an immediately repeated
    /// exit as a duplicate; a later exit without a matching arrival remains a
    /// repairable anomaly.
    static let duplicateGeofenceExitInterval: TimeInterval = 5

    private enum Active {
        case automatic(ActivitySession, ActivityEvent, allowsExtendedDuration: Bool)
        case preserved(ActivitySession)
    }

    func reconcile(events: [ActivityEvent], existingSessions: [ActivitySession],
                   now: Date = Date(), timeZoneIdentifier: String = TimeZone.current.identifier) -> SessionEngineResult {
        let ordered = events.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }

        // A completed manual correction is an explicit user decision and must
        // survive replay.  An open manual session is not preserved: it still
        // needs to consume its later manual-stop event.  Treating every
        // `.manuallyAdjusted` session as immutable made a two-step manual
        // entry impossible to close after the first pipeline ingestion.
        let preserved = existingSessions.filter {
            $0.deletedAt != nil || ($0.status == .manuallyAdjusted && $0.endAt != nil)
        }
        var preservedByStart: [UUID: ActivitySession] = [:]
        var preservedEndIds = Set<UUID>()
        for session in preserved {
            if let id = session.startEventId { preservedByStart[id] = session }
            if let id = session.endEventId { preservedEndIds.insert(id) }
        }

        var automaticByStart: [UUID: ActivitySession] = [:]
        for session in existingSessions where session.deletedAt == nil &&
            (session.status != .manuallyAdjusted || session.endAt == nil) {
            if let id = session.startEventId { automaticByStart[id] = session }
        }

        // A single activity may use several physical places.  Location events
        // must therefore be paired by the place that emitted them, not merely
        // by activity ID.  Otherwise an exit from "公司" can close a session
        // that started at "家" and leave the real company exit orphaned.
        var activeByPlace: [UUID: Active] = [:]
        var activeWithoutPlace: Active?
        var latestAppliedExitByPlace: [UUID: Date] = [:]
        var created: [ActivitySession] = []

        for event in ordered {
            activeWithoutPlace = expireIfStale(activeWithoutPlace, before: event, now: now)
            for placeId in Array(activeByPlace.keys) {
                activeByPlace[placeId] = expireIfStale(activeByPlace[placeId], before: event, now: now)
            }

            if let preservedSession = preservedByStart[event.id] {
                event.disposition = .applied
                if let placeId = preservedSession.placeTriggerId {
                    activeByPlace[placeId] = .preserved(preservedSession)
                } else {
                    activeWithoutPlace = .preserved(preservedSession)
                }
                continue
            }

            if preservedEndIds.contains(event.id) {
                event.disposition = .applied
                if let preservedSession = preserved.first(where: { $0.endEventId == event.id }),
                   let placeId = preservedSession.placeTriggerId {
                    activeByPlace[placeId] = nil
                    latestAppliedExitByPlace[placeId] = event.timestamp
                } else {
                    activeWithoutPlace = nil
                }
                continue
            }

            if event.eventType.startsSession {
                let placeId = geofencePlaceId(for: event)
                let currentActive = placeId.flatMap { activeByPlace[$0] }
                    ?? (placeId == nil ? activeWithoutPlace : nil)
                guard currentActive == nil else {
                    event.disposition = .redundant
                    continue
                }
                let isManual = event.eventType == .manualStart || event.source == .user
                let allowsExtendedDuration = allowsExtendedDuration(for: event)
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
                let nextActive = Active.automatic(session, event, allowsExtendedDuration: allowsExtendedDuration)
                if let placeId {
                    activeByPlace[placeId] = nextActive
                } else {
                    activeWithoutPlace = nextActive
                }
            } else if event.eventType.stopsSession {
                let placeId = geofencePlaceId(for: event)
                let currentActive = placeId.flatMap { activeByPlace[$0] }
                    ?? (placeId == nil ? activeWithoutPlace : nil)
                guard let current = currentActive else {
                    // Core Location reports the current state for a newly
                    // registered region, but it cannot reconstruct when the
                    // person originally arrived.  The first later exit is not
                    // a missing record and must not ask the user to invent one.
                    let isImmediateDuplicate = placeId.flatMap { latestAppliedExitByPlace[$0] }
                        .map { event.timestamp.timeIntervalSince($0) <= Self.duplicateGeofenceExitInterval } ?? false
                    event.disposition = event.metadata.values["monitoringBeganInside"] == "true" || isImmediateDuplicate
                        ? .redundant : .orphaned
                    continue
                }
                switch current {
                case .automatic(let session, let startEvent, _):
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
                    if let placeId {
                        activeByPlace[placeId] = nil
                        latestAppliedExitByPlace[placeId] = event.timestamp
                    } else {
                        activeWithoutPlace = nil
                    }
                case .preserved:
                    event.disposition = .redundant
                }
            } else {
                event.disposition = .applied
            }
        }

        let remainingActive = Array(activeByPlace.values) + (activeWithoutPlace.map { [$0] } ?? [])
        for active in remainingActive {
            if case .automatic(let session, let startEvent, let allowsExtendedDuration) = active {
                if !allowsExtendedDuration && now.timeIntervalSince(startEvent.timestamp) >= Self.staleInterval {
                    session.status = .incomplete
                    session.confidence = .uncertain
                } else if session.status != .manuallyAdjusted {
                    session.status = .active
                }
                session.updatedAt = now
            }
        }

        applyUserCorrections(from: ordered, to: existingSessions + created, now: now)

        return SessionEngineResult(sessions: existingSessions + created, createdSessions: created)
    }

    private func allowsExtendedDuration(for event: ActivityEvent) -> Bool {
        guard event.eventType == .geofenceEnter else { return false }
        let placeType = event.metadata.values["placeType"].flatMap(PlaceType.init(rawValue:))
        return placeType.map { $0 != .work } ?? false
    }

    private func geofencePlaceId(for event: ActivityEvent) -> UUID? {
        guard event.eventType == .geofenceEnter || event.eventType == .geofenceExit else { return nil }
        return UUID(uuidString: event.metadata.values["placeTriggerId"] ?? "")
    }

    private func expireIfStale(_ active: Active?, before event: ActivityEvent, now: Date) -> Active? {
        guard let active else { return nil }
        let start: Date?
        switch active {
        case .automatic(_, let startEvent, let allowsExtendedDuration):
            start = allowsExtendedDuration ? nil : startEvent.timestamp
        case .preserved(let session):
            start = session.startAt
        }
        guard let start, event.timestamp.timeIntervalSince(start) >= Self.staleInterval else { return active }
        if case .automatic(let session, _, _) = active {
            session.endAt = nil
            session.endEventId = nil
            session.status = .incomplete
            session.confidence = .uncertain
            session.updatedAt = now
        }
        return nil
    }

    /// Session records are a projection of immutable activity events.  User
    /// correction events carry the small amount of intent that cannot be
    /// inferred from a geofence transition, so replay keeps the projection in
    /// step with its event history instead of relying on callers to mutate a
    /// managed Session as a second source of truth.
    private func applyUserCorrections(from events: [ActivityEvent], to sessions: [ActivitySession], now: Date) {
        let formatter = ISO8601DateFormatter()
        let sessionsByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let sessionsByStartEvent = Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
            session.startEventId.map { ($0, session) }
        })

        for event in events {
            guard event.eventType == .sessionAdjusted || event.eventType == .sessionDeleted else { continue }
            let values = event.metadata.values
            let target = UUID(uuidString: values["sessionId"] ?? "").flatMap { sessionsByID[$0] }
                ?? UUID(uuidString: values["startEventId"] ?? "").flatMap { sessionsByStartEvent[$0] }
            guard let session = target else {
                event.disposition = .orphaned
                continue
            }

            switch event.eventType {
            case .sessionAdjusted:
                guard let startRaw = values["newStart"], let startAt = formatter.date(from: startRaw) else {
                    event.disposition = .orphaned
                    continue
                }
                let endAt = values["newEnd"].flatMap { $0.isEmpty ? nil : formatter.date(from: $0) }
                guard endAt == nil || endAt! >= startAt else {
                    event.disposition = .orphaned
                    continue
                }
                session.startAt = startAt
                session.endAt = endAt
                session.status = .manuallyAdjusted
                session.confidence = .confirmed
                session.updatedAt = now
                event.disposition = .applied
            case .sessionDeleted:
                session.deletedAt = event.timestamp
                session.updatedAt = now
                event.disposition = .applied
            default:
                break
            }
        }
    }
}
