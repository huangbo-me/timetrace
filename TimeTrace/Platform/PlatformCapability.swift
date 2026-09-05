import CoreLocation
import Foundation

/// Capability state is intentionally separate from domain data. A platform
/// failure can therefore be rendered and retried without making records or
/// analytics unavailable.
enum PlatformCapabilityStatus: Equatable {
    case available
    case needsAuthorization
    case restricted
    case unavailable(message: String)

    static func geofence(for status: CLAuthorizationStatus) -> PlatformCapabilityStatus {
        switch status {
        case .authorizedAlways: .available
        case .notDetermined, .authorizedWhenInUse: .needsAuthorization
        case .denied, .restricted: .restricted
        @unknown default: .unavailable(message: "定位服务暂不可用")
        }
    }
}

struct PlatformCapabilitySnapshot: Equatable {
    let geofence: PlatformCapabilityStatus
    let notifications: PlatformCapabilityStatus
    let cloudSync: ICloudSyncStatus
}
