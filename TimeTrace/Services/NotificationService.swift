import Foundation
import UserNotifications

enum ReminderNotificationAction {
    case delivered(definitionId: UUID, requestId: String)
    case start(definitionId: UUID, requestId: String)
    case snooze(definitionId: UUID, requestId: String)
    case skip(definitionId: UUID, requestId: String)
    case dismissed(definitionId: UUID, requestId: String)
}

enum GeofenceNotificationTransition: Equatable {
    case entered
    case exited
}

@MainActor
protocol NotificationServicing: AnyObject {
    var onAction: ((ReminderNotificationAction) -> Void)? { get set }
    func registerCategories()
    func requestAuthorization() async throws -> Bool
    func schedule(_ reminder: ReminderDefinition) async throws
    func reconcile(_ reminders: [ReminderDefinition]) async throws
    func cancel(_ reminder: ReminderDefinition) async
    func snooze(definitionId: UUID, name: String) async throws
    func notifyGeofenceTransition(_ transition: GeofenceNotificationTransition,
                                  activityName: String,
                                  placeName: String) async throws
}

/// The notification adapter owns the request diff. Tests replace only the
/// system request store, so they exercise real scheduling and cancellation.
@MainActor
protocol NotificationRequestStore {
    func pending() async -> [UNNotificationRequest]
    func delivered() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
    func removePending(_ identifiers: [String])
    func removeDelivered(_ identifiers: [String])
}

@MainActor
private struct SystemNotificationRequestStore: NotificationRequestStore {
    let center: UNUserNotificationCenter
    func pending() async -> [UNNotificationRequest] { await center.pendingNotificationRequests() }
    func delivered() async -> [UNNotificationRequest] { await center.deliveredNotifications().map(\.request) }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
    func removePending(_ identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func removeDelivered(_ identifiers: [String]) { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
}

enum ReminderOccurrence {
    static func identifier(requestID: String, deliveredAt: Date) -> String {
        "\(requestID).occurrence.\(deliveredAt.timeIntervalSince1970)"
    }
}

@MainActor
final class LocalNotificationService: NSObject, NotificationServicing, UNUserNotificationCenterDelegate {
    static let categoryIdentifier = "ACTIVITY_REMINDER"
    static let startIdentifier = "START_ACTIVITY"
    static let snoozeIdentifier = "SNOOZE_ACTIVITY"
    static let skipIdentifier = "SKIP_ACTIVITY"

    private let center: UNUserNotificationCenter
    private let requests: NotificationRequestStore
    private var operation: Task<Void, Error>?
    var onAction: ((ReminderNotificationAction) -> Void)?

    init(center: UNUserNotificationCenter = .current(), requests: NotificationRequestStore? = nil) {
        self.center = center
        self.requests = requests ?? SystemNotificationRequestStore(center: center)
        super.init()
        center.delegate = self
    }

    private func serialize(_ work: @escaping @MainActor () async throws -> Void) async throws {
        let previous = operation
        let task = Task { @MainActor in
            _ = try? await previous?.value
            try await work()
        }
        operation = task
        try await task.value
    }

    func registerCategories() {
        let start = UNNotificationAction(identifier: Self.startIdentifier, title: "开始")
        let snooze = UNNotificationAction(identifier: Self.snoozeIdentifier, title: "10 分钟后提醒")
        let skip = UNNotificationAction(identifier: Self.skipIdentifier, title: "今天跳过")
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [start, snooze, skip],
            intentIdentifiers: [],
            options: [.customDismissAction]
        )
        center.setNotificationCategories([category])
    }

    func requestAuthorization() async throws -> Bool {
        try await center.requestAuthorization(options: [.alert, .badge, .sound])
    }

    func schedule(_ reminder: ReminderDefinition) async throws {
        try await serialize { [self] in try await scheduleRequests(reminder) }
    }

    private func scheduleRequests(_ reminder: ReminderDefinition) async throws {
        let obsolete = (1...7).filter { !reminder.isEnabled || !reminder.weekdaysMask.containsWeekday($0) }
            .map { requestIdentifier(reminder.id, weekday: $0) }
        requests.removePending(obsolete)
        guard reminder.isEnabled else { return }
        for weekday in 1...7 where reminder.weekdaysMask.containsWeekday(weekday) {
            var components = DateComponents()
            components.calendar = Calendar(identifier: .gregorian)
            components.weekday = weekday
            components.hour = reminder.hour
            components.minute = reminder.minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            try await requests.add(UNNotificationRequest(
                identifier: requestIdentifier(reminder.id, weekday: weekday),
                content: content(definitionId: reminder.id, name: reminder.name), trigger: trigger
            ))
        }
    }

    func reconcile(_ reminders: [ReminderDefinition]) async throws {
        try await serialize { [self] in
            let enabled = reminders.filter(\.isEnabled)
            let validIDs = Set(enabled.map(\.id))
            let pending = await requests.pending()
            let delivered = await requests.delivered()
            func isObsolete(_ request: UNNotificationRequest) -> Bool {
                guard let id = definitionID(in: request) else { return false }
                return !validIDs.contains(id)
            }
            requests.removePending(pending.filter(isObsolete).map(\.identifier))
            requests.removeDelivered(delivered.filter(isObsolete).map(\.identifier))
            for reminder in enabled { try await scheduleRequests(reminder) }
        }
    }

    func cancel(_ reminder: ReminderDefinition) async {
        try? await serialize { [self] in
            let pending = await requests.pending()
            let delivered = await requests.delivered()
            requests.removePending(pending.filter { definitionID(in: $0) == reminder.id }.map(\.identifier))
            requests.removeDelivered(delivered.filter { definitionID(in: $0) == reminder.id }.map(\.identifier))
        }
    }

    nonisolated private func definitionID(in request: UNNotificationRequest) -> UUID? {
        guard let raw = request.content.userInfo["definitionId"] as? String else { return nil }
        return UUID(uuidString: raw)
    }

    func snooze(definitionId: UUID, name: String) async throws {
        try await serialize { [self] in
            let request = UNNotificationRequest(
                identifier: "timetrace.snooze.\(definitionId.uuidString).\(UUID().uuidString)",
                content: content(definitionId: definitionId, name: name),
                trigger: UNTimeIntervalNotificationTrigger(timeInterval: 10 * 60, repeats: false)
            )
            try await requests.add(request)
        }
    }

    func notifyGeofenceTransition(_ transition: GeofenceNotificationTransition,
                                  activityName: String,
                                  placeName: String) async throws {
        let content = UNMutableNotificationContent()
        switch transition {
        case .entered:
            content.title = "已进入\(placeName)"
            content.body = "已自动开始记录\(activityName)时间。"
        case .exited:
            content.title = "已离开\(placeName)"
            content.body = "已自动结束记录\(activityName)时间。"
        }
        content.sound = .default
        let request = UNNotificationRequest(
            identifier: "timetrace.geofence.\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        try await center.add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        await dispatch(.delivered, response: nil, notification: notification)
        return [.banner, .sound]
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse) async {
        let kind: ActionKind
        switch response.actionIdentifier {
        case Self.startIdentifier: kind = .start
        case Self.snoozeIdentifier: kind = .snooze
        case Self.skipIdentifier: kind = .skip
        case UNNotificationDismissActionIdentifier: kind = .dismissed
        default: kind = .start
        }
        await dispatch(kind, response: response, notification: response.notification)
    }

    private enum ActionKind { case delivered, start, snooze, skip, dismissed }

    nonisolated private func dispatch(_ kind: ActionKind, response: UNNotificationResponse?,
                                      notification: UNNotification) async {
        guard let raw = notification.request.content.userInfo["definitionId"] as? String,
              let id = UUID(uuidString: raw) else { return }
        let requestId = ReminderOccurrence.identifier(requestID: notification.request.identifier,
                                                       deliveredAt: notification.date)
        let action: ReminderNotificationAction
        switch kind {
        case .delivered: action = .delivered(definitionId: id, requestId: requestId)
        case .start: action = .start(definitionId: id, requestId: requestId)
        case .snooze: action = .snooze(definitionId: id, requestId: requestId)
        case .skip: action = .skip(definitionId: id, requestId: requestId)
        case .dismissed: action = .dismissed(definitionId: id, requestId: requestId)
        }

        // `didReceive` may be invoked while UIKit is restoring the scene for a
        // notification tap. Mutating SwiftUI state from inside that callback
        // trips UIKit's state-restoration assertion on a cold launch. Return
        // from the delegate first, then forward the action on a later turn.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            self?.onAction?(action)
        }
    }

    private func content(definitionId: UUID, name: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = name
        content.body = "准备开始这项活动了吗？"
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = ["definitionId": definitionId.uuidString]
        return content
    }

    private func requestIdentifier(_ id: UUID, weekday: Int) -> String {
        "timetrace.reminder.\(id.uuidString).\(weekday)"
    }
}
