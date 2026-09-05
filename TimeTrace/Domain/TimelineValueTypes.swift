import Foundation

/// Immutable domain representations. SwiftData records deliberately remain in
/// the persistence layer; these values are safe to pass through application
/// and presentation modules without leaking a managed object.
struct ActivityValue: Equatable, Identifiable {
    let id: UUID
    let name: String
    let type: ActivityType
    let isEnabled: Bool
}

struct PlaceValue: Equatable, Identifiable {
    let id: UUID
    let activityId: UUID
    let name: String
    let type: PlaceType
    let coordinate: CoordinateValue?
    let radius: Double?
    let isEnabled: Bool
}

struct CoordinateValue: Equatable {
    let latitude: Double
    let longitude: Double
}

struct SessionValue: Equatable, Identifiable {
    let id: UUID
    let activityId: UUID
    let placeId: UUID?
    let startAt: Date
    let endAt: Date?
    let status: ActivitySessionStatus
    let confidence: ActivityConfidence
}

enum TimelineValueMapper {
    static func activity(_ record: ActivityDefinition) -> ActivityValue {
        ActivityValue(id: record.id, name: record.name, type: record.type, isEnabled: record.isEnabled)
    }

    static func place(_ record: ActivityTrigger) -> PlaceValue {
        let coordinate: CoordinateValue? = {
            guard let latitude = record.latitude, let longitude = record.longitude else { return nil }
            return CoordinateValue(latitude: latitude, longitude: longitude)
        }()
        return PlaceValue(id: record.id, activityId: record.activityId,
                          name: record.displayPlaceName, type: record.placeType,
                          coordinate: coordinate, radius: record.radius, isEnabled: record.isEnabled)
    }

    static func session(_ record: ActivitySession) -> SessionValue {
        SessionValue(id: record.id, activityId: record.activityId, placeId: record.placeTriggerId,
                     startAt: record.startAt, endAt: record.endAt, status: record.status,
                     confidence: record.confidence)
    }
}
