import CoreLocation
import Foundation
import OSLog

enum GeofenceSystemEvent {
    case entered(triggerId: UUID, timestamp: Date)
    case exited(triggerId: UUID, timestamp: Date)
}

enum GeofenceError: LocalizedError {
    case locationUnavailable
    case invalidConfiguration

    var errorDescription: String? {
        switch self {
        case .locationUnavailable: "暂时无法获取当前位置"
        case .invalidConfiguration: "地点配置无效"
        }
    }
}

@MainActor
protocol GeofenceServicing: AnyObject {
    var authorizationStatus: CLAuthorizationStatus { get }
    var accuracyAuthorization: CLAccuracyAuthorization { get }
    var lastHorizontalAccuracy: CLLocationAccuracy? { get }
    var onEvent: ((GeofenceSystemEvent) -> Void)? { get set }
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)? { get set }
    func requestWhenInUseAuthorization()
    func requestAlwaysAuthorization()
    func requestCurrentLocation() async throws -> CLLocationCoordinate2D
    func register(triggerId: UUID, latitude: Double, longitude: Double, radius: Double) throws -> Double
    func remove(triggerId: UUID)
    func restoreAndRequestState(triggerId: UUID, latitude: Double, longitude: Double, radius: Double)
}

@MainActor
final class CoreLocationGeofenceService: NSObject, GeofenceServicing, @preconcurrency CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private let logger = Logger(subsystem: "com.chronora.time.trace", category: "Geofence")
    private var locationContinuation: CheckedContinuation<CLLocationCoordinate2D, Error>?
    private(set) var lastHorizontalAccuracy: CLLocationAccuracy?
    var onEvent: ((GeofenceSystemEvent) -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?

    override init() {
        super.init()
        manager.delegate = self
        // This only affects the explicit one-shot workplace picker request.
        // Region monitoring remains handled by the low-power system service.
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = kCLDistanceFilterNone
    }

    var authorizationStatus: CLAuthorizationStatus { manager.authorizationStatus }
    var accuracyAuthorization: CLAccuracyAuthorization { manager.accuracyAuthorization }

    func requestWhenInUseAuthorization() { manager.requestWhenInUseAuthorization() }
    func requestAlwaysAuthorization() { manager.requestAlwaysAuthorization() }

    func requestCurrentLocation() async throws -> CLLocationCoordinate2D {
        guard locationContinuation == nil else { throw GeofenceError.locationUnavailable }
        return try await withCheckedThrowingContinuation { continuation in
            locationContinuation = continuation
            manager.requestLocation()
        }
    }

    @discardableResult
    func register(triggerId: UUID, latitude: Double, longitude: Double, radius: Double) throws -> Double {
        guard CLLocationCoordinate2DIsValid(.init(latitude: latitude, longitude: longitude)), radius > 0 else {
            throw GeofenceError.invalidConfiguration
        }
        // Migrate the earlier single-workplace region identifier on the first
        // registration after upgrading to independently monitored places.
        for region in manager.monitoredRegions where region.identifier.hasPrefix("timetrace.activity.") {
            manager.stopMonitoring(for: region)
        }
        remove(triggerId: triggerId)
        let deviceMaximum = manager.maximumRegionMonitoringDistance > 0
            ? manager.maximumRegionMonitoringDistance : 1_000
        // Core Location accepts small circular regions. 10m is intentionally allowed
        // for users who need a tight boundary, although real-world GPS accuracy may
        // be larger than that (especially indoors).
        let acceptedRadius = min(max(10, radius), max(10, deviceMaximum))
        let region = CLCircularRegion(
            center: .init(latitude: latitude, longitude: longitude),
            radius: acceptedRadius,
            identifier: regionIdentifier(triggerId)
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true
        manager.startMonitoring(for: region)
        return acceptedRadius
    }

    func remove(triggerId: UUID) {
        let identifier = regionIdentifier(triggerId)
        for region in manager.monitoredRegions where region.identifier == identifier {
            manager.stopMonitoring(for: region)
        }
    }

    func restoreAndRequestState(triggerId: UUID, latitude: Double, longitude: Double, radius: Double) {
        do {
            _ = try register(triggerId: triggerId, latitude: latitude, longitude: longitude, radius: radius)
            if let region = manager.monitoredRegions.first(where: { $0.identifier == regionIdentifier(triggerId) }) {
                manager.requestState(for: region)
            }
        } catch {
            logger.error("Unable to restore geofence: \(error.localizedDescription, privacy: .public)")
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let recentLocations = locations.filter {
            $0.horizontalAccuracy >= 0 &&
            abs($0.timestamp.timeIntervalSinceNow) <= 30 &&
            CLLocationCoordinate2DIsValid($0.coordinate)
        }
        guard let bestLocation = recentLocations.min(by: {
            $0.horizontalAccuracy < $1.horizontalAccuracy
        }) else {
            locationContinuation?.resume(throwing: GeofenceError.locationUnavailable)
            locationContinuation = nil
            return
        }
        lastHorizontalAccuracy = bestLocation.horizontalAccuracy
        locationContinuation?.resume(returning: bestLocation.coordinate)
        locationContinuation = nil
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        locationContinuation?.resume(throwing: error)
        locationContinuation = nil
        logger.error("Location error: \(error.localizedDescription, privacy: .public)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        onAuthorizationChange?(manager.authorizationStatus)
    }

    func locationManager(_ manager: CLLocationManager, didEnterRegion region: CLRegion) {
        guard let triggerId = triggerId(from: region.identifier) else { return }
        onEvent?(.entered(triggerId: triggerId, timestamp: Date()))
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let triggerId = triggerId(from: region.identifier) else { return }
        onEvent?(.exited(triggerId: triggerId, timestamp: Date()))
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        // State checks restore monitoring but are not facts about a boundary crossing.
        logger.info("Region state restored: \(String(describing: state), privacy: .public)")
    }

    private func regionIdentifier(_ triggerId: UUID) -> String { "timetrace.place.\(triggerId.uuidString)" }

    private func triggerId(from identifier: String) -> UUID? {
        UUID(uuidString: identifier.replacingOccurrences(of: "timetrace.place.", with: ""))
    }
}
