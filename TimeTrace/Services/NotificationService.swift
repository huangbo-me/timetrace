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
    func cancel(_ reminder: ReminderDefinition)
    func snooze(definitionId: UUID, name: String) async throws
    func notifyGeofenceTransition(_ transition: GeofenceNotificationTransition,
                                  activityName: String,
                                  placeName: String) async throws
}

@MainActor
final class LocalNotificationService: NSObject, NotificationServicing, UNUserNotificationCenterDelegate {
    static let categoryIdentifier = "ACTIVITY_REMINDER"
    static let startIdentifier = "START_ACTIVITY"
    static let snoozeIdentifier = "SNOOZE_ACTIVITY"
    static let skipIdentifier = "SKIP_ACTIVITY"

    private let center = UNUserNotificationCenter.current()
    var onAction: ((ReminderNotificationAction) -> Void)?

    override init() {
        super.init()
        center.delegate = self
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
        cancel(reminder)
        for weekday in 1...7 where reminder.weekdaysMask.containsWeekday(weekday) {
            let content = content(definitionId: reminder.id, name: reminder.name)
            var components = DateComponents()
            components.calendar = Calendar(identifier: .gregorian)
            components.weekday = weekday
            components.hour = reminder.hour
            components.minute = reminder.minute
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            let request = UNNotificationRequest(
                identifier: requestIdentifier(reminder.id, weekday: weekday),
                content: content,
                trigger: trigger
            )
            try await center.add(request)
        }
    }

    func cancel(_ reminder: ReminderDefinition) {
        center.removePendingNotificationRequests(withIdentifiers: (1...7).map { requestIdentifier(reminder.id, weekday: $0) })
    }

    func snooze(definitionId: UUID, name: String) async throws {
        let request = UNNotificationRequest(
            identifier: "timetrace.snooze.\(definitionId.uuidString).\(UUID().uuidString)",
            content: content(definitionId: definitionId, name: name),
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 10 * 60, repeats: false)
        )
        try await center.add(request)
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
        let requestId = notification.request.identifier
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
