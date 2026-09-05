import Foundation

enum TimeTraceLocalization {
    static let locale = Locale(identifier: "zh-Hans-CN")

    static func errorMessage(_ error: Error, fallback: String = "操作失败，请稍后重试。") -> String {
        if let geofenceError = error as? GeofenceError {
            return geofenceError.localizedDescription
        }
        return fallback
    }
}

enum TimeTraceFormat {
    static let time: DateFormatter = {
        let value = DateFormatter()
        value.locale = TimeTraceLocalization.locale
        value.dateFormat = "HH:mm"
        return value
    }()

    static let day: DateFormatter = {
        let value = DateFormatter()
        value.locale = TimeTraceLocalization.locale
        value.dateFormat = "M 月 d 日 EEEE"
        return value
    }()

    static func duration(_ interval: TimeInterval) -> String {
        let totalMinutes = max(0, Int(interval / 60))
        return "\(totalMinutes / 60)小时 \(totalMinutes % 60)分钟"
    }

    static func signedDuration(_ interval: TimeInterval?) -> String {
        guard let interval else { return "暂无可比数据" }
        let prefix = interval >= 0 ? "+" : "−"
        return prefix + duration(abs(interval))
    }

    static func clockOffset(_ offset: TimeInterval?) -> String {
        guard let offset else { return "—" }
        let minutes = Int(offset / 60)
        let day = minutes / (24 * 60)
        let minuteInDay = ((minutes % (24 * 60)) + 24 * 60) % (24 * 60)
        let clock = String(format: "%02d:%02d", minuteInDay / 60, minuteInDay % 60)
        return day > 0 ? "次日 \(clock)" : clock
    }
}
