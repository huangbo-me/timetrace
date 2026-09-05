import Foundation

enum ChinaWorkCalendar {
    struct DayStatus {
        let isWorkday: Bool
        let label: String
    }

    static func status(for date: Date, calendar: Calendar = .current) -> DayStatus {
        let key = dayKey(for: date, calendar: calendar)
        if let holiday = holidays2026[key] {
            return .init(isWorkday: false, label: holiday)
        }
        if makeUpWorkdays2026.contains(key) {
            return .init(isWorkday: true, label: "调休工作日")
        }
        if calendar.isDateInWeekend(date) {
            return .init(isWorkday: false, label: "周末")
        }
        return .init(isWorkday: true, label: "工作日")
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    // 国务院办公厅 2026 年部分节假日安排；每年公告发布后更新这一张离线表。
    private static let holidays2026: [String: String] = {
        let periods: [(String, String, String)] = [
            ("2026-01-01", "2026-01-03", "元旦假期"),
            ("2026-02-15", "2026-02-23", "春节假期"),
            ("2026-04-04", "2026-04-06", "清明节假期"),
            ("2026-05-01", "2026-05-05", "劳动节假期"),
            ("2026-06-19", "2026-06-21", "端午节假期"),
            ("2026-09-25", "2026-09-27", "中秋节假期"),
            ("2026-10-01", "2026-10-07", "国庆节假期")
        ]
        var result: [String: String] = [:]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        formatter.dateFormat = "yyyy-MM-dd"
        let calendar = Calendar(identifier: .gregorian)
        for (start, end, label) in periods {
            guard let startDate = formatter.date(from: start), let endDate = formatter.date(from: end) else { continue }
            var day = startDate
            while day <= endDate {
                result[formatter.string(from: day)] = label
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            }
        }
        return result
    }()

    private static let makeUpWorkdays2026: Set<String> = [
        "2026-01-04", "2026-02-14", "2026-02-28", "2026-05-09", "2026-09-20", "2026-10-10"
    ]
}
