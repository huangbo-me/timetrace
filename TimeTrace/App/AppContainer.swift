import Combine
import CoreLocation
import Foundation

/// The composition root for the app.  Views receive feature-specific stores
/// instead of sharing the persistence and platform implementation directly.
@MainActor
final class AppContainer: ObservableObject {
    let application: AppModel
    let root: RootStore
    let onboarding: OnboardingFeatureStore
    let today: TodayFeatureStore
    let insights: InsightsFeatureStore
    let places: PlacesFeatureStore
    let history: HistoryFeatureStore
    let settings: SettingsFeatureStore

    convenience init() {
        self.init(application: AppModel())
    }

    init(application: AppModel) {
        self.application = application
        root = RootStore(application: application)
        onboarding = OnboardingFeatureStore(application: application)
        today = TodayFeatureStore(application: application)
        insights = InsightsFeatureStore(application: application)
        places = PlacesFeatureStore(application: application)
        history = HistoryFeatureStore(application: application)
        settings = SettingsFeatureStore(application: application)
    }
}

/// A deep presentation module: each feature sees a stable store seam while
/// the transition from the legacy aggregate to focused application use cases
/// remains internal to the composition root.
@MainActor
class FeatureStore: ObservableObject {
    let application: AppModel
    private var observation: AnyCancellable?

    init(application: AppModel) {
        self.application = application
        observation = application.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}

@MainActor
final class RootStore: FeatureStore {
    var state: RootState {
        RootState(
            isLoaded: application.isLoaded,
            isRestoringICloudData: application.isRestoringICloudData,
            isOnboarded: application.isOnboarded,
            errorMessage: application.lastError
        )
    }

    func loadIfNeeded() {
        guard !application.isLoaded else { return }
        application.load()
    }

    func becameActive() {
        application.refreshSyncedData()
        application.refreshICloudSyncStatus()
    }

    func dismissError() { application.lastError = nil }
}

struct RootState: Equatable {
    let isLoaded: Bool
    let isRestoringICloudData: Bool
    let isOnboarded: Bool
    let errorMessage: String?
}

@MainActor final class OnboardingFeatureStore: FeatureStore {
    var state: OnboardingState {
        OnboardingState(locationAuthorizationStatus: application.locationAuthorizationStatus)
    }
}
struct OnboardingState: Equatable { let locationAuthorizationStatus: CLAuthorizationStatus }

@MainActor final class TodayFeatureStore: FeatureStore {
    var state: TodayState {
        TodayState(activeReminderCount: application.activeReminderInstances.count,
                   isOnboarded: application.isOnboarded)
    }
}
struct TodayState: Equatable { let activeReminderCount: Int; let isOnboarded: Bool }

@MainActor final class InsightsFeatureStore: FeatureStore {}

@MainActor final class PlacesFeatureStore: FeatureStore {
    var state: PlacesState { PlacesState(placeCount: application.workTriggers.count) }
}
struct PlacesState: Equatable { let placeCount: Int }

@MainActor final class HistoryFeatureStore: FeatureStore {
    var state: HistoryState {
        HistoryState(orphanedExitCount: application.orphanedWorkExitEvents.count)
    }
}
struct HistoryState: Equatable { let orphanedExitCount: Int }

@MainActor final class SettingsFeatureStore: FeatureStore {
    var state: SettingsState {
        SettingsState(
            locationAuthorizationStatus: application.locationAuthorizationStatus,
            iCloudSyncStatus: application.iCloudSyncStatus,
            reminderCount: application.reminders.count
        )
    }
}
struct SettingsState: Equatable {
    let locationAuthorizationStatus: CLAuthorizationStatus
    let iCloudSyncStatus: ICloudSyncStatus
    let reminderCount: Int
}
