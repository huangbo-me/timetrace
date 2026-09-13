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
    var onRegionState: ((UUID, CLRegionState) -> Void)? { get set }
    func requestWhenInUseAuthorization()
    func requestAlwaysAuthorization()
    func requestCurrentLocation() async throws -> CLLocationCoordinate2D
    func register(triggerId: UUID, latitude: Double, longitude: Double, radius: Double) throws -> Double
    func remove(triggerId: UUID)
    func restoreAndRequestState(triggerId: UUID, latitude: Double, longitude: Double, radius: Double)
}

@MainActor
final class CoreLocationGeofenceService: NSObject, GeofenceServicing, @preconcurrency CLLocationManagerDelegate {
    private let manager: CLLocationManager
    private let logger = Logger(subsystem: "com.chronora.time.trace", category: "Geofence")
    private var locationContinuation: CheckedContinuation<CLLocationCoordinate2D, Error>?
    private(set) var lastHorizontalAccuracy: CLLocationAccuracy?
    var onEvent: ((GeofenceSystemEvent) -> Void)?
    var onAuthorizationChange: ((CLAuthorizationStatus) -> Void)?
    var onRegionState: ((UUID, CLRegionState) -> Void)?

    init(manager: CLLocationManager = CLLocationManager()) {
        self.manager = manager
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
        let deviceMaximum = manager.maximumRegionMonitoringDistance > 0
            ? manager.maximumRegionMonitoringDistance : 1_000
        // Core Location accepts small circular regions. 10m is intentionally allowed
        // for users who need a tight boundary, although real-world GPS accuracy may
        // be larger than that (especially indoors).
        let acceptedRadius = min(max(10, radius), max(10, deviceMaximum))
        // Reuse the system registration across foreground and CloudKit refreshes.
        // Stopping an unchanged region discards its monitored transition state.
        if let existing = manager.monitoredRegions.compactMap({ $0 as? CLCircularRegion }).first(where: {
            $0.identifier == regionIdentifier(triggerId) &&
            $0.center.latitude == latitude && $0.center.longitude == longitude &&
            $0.radius == acceptedRadius && $0.notifyOnEntry && $0.notifyOnExit
        }) {
            GeofenceDiagnostics.record("monitor.reused")
            manager.requestState(for: existing)
            return acceptedRadius
        }
        remove(triggerId: triggerId)
        let region = CLCircularRegion(
            center: .init(latitude: latitude, longitude: longitude),
            radius: acceptedRadius,
            identifier: regionIdentifier(triggerId)
        )
        region.notifyOnEntry = true
        region.notifyOnExit = true
        GeofenceDiagnostics.record("monitor.started")
        manager.startMonitoring(for: region)
        // A person may configure a place while already inside it. Asking for
        // the current state lets the app distinguish that first later exit
        // from a genuinely missed arrival.
        manager.requestState(for: region)
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
        GeofenceDiagnostics.record("callback.entered")
        onEvent?(.entered(triggerId: triggerId, timestamp: Date()))
    }

    func locationManager(_ manager: CLLocationManager, didExitRegion region: CLRegion) {
        guard let triggerId = triggerId(from: region.identifier) else { return }
        GeofenceDiagnostics.record("callback.exited")
        onEvent?(.exited(triggerId: triggerId, timestamp: Date()))
    }

    func locationManager(_ manager: CLLocationManager, didDetermineState state: CLRegionState, for region: CLRegion) {
        guard let triggerId = triggerId(from: region.identifier) else { return }
        GeofenceDiagnostics.record("callback.state.\(state.rawValue)")
        onRegionState?(triggerId, state)
        // State checks restore monitoring but are not facts about a boundary crossing.
        logger.info("Region state restored: \(String(describing: state), privacy: .public)")
    }

    func locationManager(_ manager: CLLocationManager, monitoringDidFailFor region: CLRegion?, withError error: Error) {
        GeofenceDiagnostics.record("monitor.failed", errorCode: (error as NSError).code)
        logger.error("Region monitoring failed, code=\((error as NSError).code)")
    }

    private func regionIdentifier(_ triggerId: UUID) -> String { "timetrace.place.\(triggerId.uuidString)" }

    private func triggerId(from identifier: String) -> UUID? {
        UUID(uuidString: identifier.replacingOccurrences(of: "timetrace.place.", with: ""))
    }
}

/// Bounded local diagnostics: no coordinates, place names, identifiers or error bodies.
/// Reading this file from the app container does not require system-log privileges.
@MainActor
enum GeofenceDiagnostics {
    private struct Entry: Codable {
        let timestamp: Date
        let stage: String
        let errorCode: Int?
    }

    static func record(_ stage: String, errorCode: Int? = nil) {
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return }
        let url = directory.appendingPathComponent("GeofenceDiagnostics.json")
        do {
            var entries = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: url))) ?? []
            entries.append(Entry(timestamp: Date(), stage: stage, errorCode: errorCode))
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(entries.suffix(200))).write(to: url, options: .atomic)
        } catch {
            // Diagnostics must never stop a location fact from being persisted.
        }
    }
}
