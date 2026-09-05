import Foundation

struct ShieldSelection: Equatable {
    let opaqueIdentifiers: Set<String>
}

struct ScreenTimeMonitoringPlan: Equatable {
    let identifier: String
    let startsAt: Date
    let endsAt: Date?
}

protocol ScreenTimeControlling {
    func requestAuthorization() async throws
    func applyShield(_ selection: ShieldSelection) async throws
    func removeShield() async throws
    func startMonitoring(_ plan: ScreenTimeMonitoringPlan) async throws
}

actor StubScreenTimeService: ScreenTimeControlling {
    private(set) var isAuthorized = false
    private(set) var shield: ShieldSelection?
    private(set) var monitoringPlans: [ScreenTimeMonitoringPlan] = []

    func requestAuthorization() async throws { isAuthorized = true }
    func applyShield(_ selection: ShieldSelection) async throws { shield = selection }
    func removeShield() async throws { shield = nil }
    func startMonitoring(_ plan: ScreenTimeMonitoringPlan) async throws { monitoringPlans.append(plan) }
}
