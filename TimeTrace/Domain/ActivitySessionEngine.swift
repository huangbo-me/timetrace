import Foundation

struct SessionEngineResult {
    var sessions: [ActivitySession]
    var createdSessions: [ActivitySession]
    var supersededSessions: [ActivitySession] = []
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

        // CloudKit may merge a source event before its projected session. Keep
        // one stable record per start event even when both devices replay it.
        let groups = Dictionary(grouping: existingSessions) { $0.startEventId ?? $0.id }
        var canonical: [ActivitySession] = []
        var superseded: [ActivitySession] = []
        var sessionByID: [UUID: ActivitySession] = [:]
        for group in groups.values {
            let ranked = group.sorted {
                if ($0.deletedAt != nil) != ($1.deletedAt != nil) { return $0.deletedAt != nil }
                if ($0.status == .manuallyAdjusted) != ($1.status == .manuallyAdjusted) {
                    return $0.status == .manuallyAdjusted
                }
                if $0.createdAt != $1.createdAt { return $0.createdAt < $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
            guard let survivor = ranked.first else { continue }
            canonical.append(survivor)
            superseded.append(contentsOf: ranked.dropFirst())
            for record in ranked { sessionByID[record.id] = survivor }
        }
        let existingSessions = canonical
        var correctionsByStart: [UUID: [ActivityEvent]] = [:]
        let eventsByID = ordered.reduce(into: [UUID: ActivityEvent]()) { $0[$1.id] = $1 }
        for correction in ordered where correction.eventType == .sessionAdjusted || correction.eventType == .sessionDeleted {
            let values = correction.metadata.values
            let startID = UUID(uuidString: values["startEventId"] ?? "")
                ?? UUID(uuidString: values["sessionId"] ?? "").flatMap { sessionByID[$0]?.startEventId }
            guard let startID else { correction.disposition = .orphaned; continue }
            correctionsByStart[startID, default: []].append(correction)
        }
        for session in existingSessions {
            applyUserCorrections(correctionsByStart[session.startEventId ?? session.id] ?? [],
                                 to: session, eventsByID: eventsByID, now: now)
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
        var pendingPreservedExit: [UUID?: ActivitySession] = [:]
        var latestAppliedExitByPlace: [UUID: Date] = [:]
        var created: [ActivitySession] = []

        for event in ordered {
            activeWithoutPlace = expireIfStale(activeWithoutPlace, before: event, now: now)
            for placeId in Array(activeByPlace.keys) {
                activeByPlace[placeId] = expireIfStale(activeByPlace[placeId], before: event, now: now)
            }

            if let preservedSession = preservedByStart[event.id] {
                event.disposition = .applied
                pendingPreservedExit[preservedSession.placeTriggerId] = preservedSession.endEventId == nil ? preservedSession : nil
                if let placeId = preservedSession.placeTriggerId {
                    activeByPlace[placeId] = .preserved(preservedSession)
                } else {
                    activeWithoutPlace = .preserved(preservedSession)
                }
                continue
            }

            if preservedEndIds.contains(event.id) {
                event.disposition = .applied
                if let preservedSession = preserved.first(where: { $0.endEventId == event.id }) {
                    if let placeId = preservedSession.placeTriggerId {
                        if case .preserved(let active) = activeByPlace[placeId], active.id == preservedSession.id {
                            activeByPlace[placeId] = nil
                        }
                        latestAppliedExitByPlace[placeId] = event.timestamp
                    } else if case .preserved(let active) = activeWithoutPlace, active.id == preservedSession.id {
                        activeWithoutPlace = nil
                    }
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
                pendingPreservedExit[placeId] = nil
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
                        id: event.id,
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
                applyUserCorrections(correctionsByStart[event.id] ?? [], to: session, eventsByID: eventsByID, now: now)
                let nextActive: Active = session.deletedAt != nil || session.endAt != nil
                    ? .preserved(session)
                    : .automatic(session, event, allowsExtendedDuration: allowsExtendedDuration)
                if case .preserved = nextActive, session.endEventId == nil {
                    pendingPreservedExit[placeId] = session
                }
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
                    if let corrected = pendingPreservedExit.removeValue(forKey: placeId) {
                        corrected.endEventId = event.id
                        event.disposition = .applied
                        if let placeId { latestAppliedExitByPlace[placeId] = event.timestamp }
                        continue
                    }
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
                case .preserved(let session):
                    session.endEventId = event.id
                    event.disposition = .applied
                    pendingPreservedExit[placeId] = nil
                    if let placeId {
                        activeByPlace[placeId] = nil
                        latestAppliedExitByPlace[placeId] = event.timestamp
                    } else { activeWithoutPlace = nil }
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

        for session in existingSessions + created {
            applyUserCorrections(correctionsByStart[session.startEventId ?? session.id] ?? [],
                                 to: session, eventsByID: eventsByID, now: now)
        }

        return SessionEngineResult(sessions: existingSessions + created, createdSessions: created,
                                   supersededSessions: superseded)
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
            // A manual end can have no source exit event. Release the slot by
            // its corrected end, rather than swallowing the next day's visits.
            if let end = session.endAt, event.timestamp >= end { return nil }
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
    private func applyUserCorrections(_ events: [ActivityEvent], to session: ActivitySession,
                                      eventsByID: [UUID: ActivityEvent], now: Date) {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func parseDate(_ raw: String) -> Date? {
            formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw)
        }
        // Only the latest adjustment describes the intended boundaries. A
        // deletion remains a tombstone regardless of subsequent replay.
        if let event = events.last(where: { $0.eventType == .sessionAdjusted }) {
            let values = event.metadata.values
            if let startRaw = values["newStart"], let startAt = parseDate(startRaw) {
                let endAt = values["newEnd"].flatMap { $0.isEmpty ? nil : parseDate($0) }
                if endAt == nil || endAt! >= startAt {
                    session.startAt = startAt
                    let laterStop = session.endEventId.flatMap { eventsByID[$0] }
                        .map { $0.timestamp > event.timestamp } ?? false
                    if endAt != nil || !laterStop { session.endAt = endAt }
                    session.status = session.endAt != nil ? .manuallyAdjusted
                        : (session.status == .incomplete ? .incomplete : .active)
                    session.confidence = .confirmed
                    session.updatedAt = now
                    event.disposition = .applied
                } else { event.disposition = .orphaned }
            } else { event.disposition = .orphaned }
        }
        for event in events where event.eventType == .sessionDeleted {
            session.deletedAt = event.timestamp
            session.updatedAt = now
            event.disposition = .applied
        }
    }
}
