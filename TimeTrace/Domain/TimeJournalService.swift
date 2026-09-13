import Foundation
import CryptoKit

/// Immutable evidence keeps an open share preview independent of later sync or edits.
struct JournalRecord: Identifiable, Equatable {
    let id: UUID
    let start: Date
    let end: Date?
    let duration: TimeInterval?
    let placeID: UUID?
    let placeName: String
    let placeType: PlaceType?
}

struct JournalFinding: Identifiable, Equatable {
    enum Kind: String { case comparison, recurring, memorable }
    var id: Kind { kind }
    let kind: Kind
    let title: String
    let detail: String
    let records: [JournalRecord]
    var changeSeconds: Double? = nil
}

struct TimeJournal: Identifiable, Equatable {
    var id: String { "\(interval.start.timeIntervalSince1970)-\(scope)" }
    let interval: DateInterval
    let dateLabel: String
    let scope: String
    let privateScope: String
    let totalDuration: TimeInterval
    let recordedDays: Int
    let recordCount: Int
    let unfinishedCount: Int
    let findings: [JournalFinding]
    let calendar: Calendar
    var summaryRecords: [JournalRecord] = []
    var canShare: Bool { recordCount > 0 }

    /// Explicit place categories only; unknown places are never inferred as work or home.
    var summaryMetrics: [JournalSummaryMetric] {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M月d日 HH:mm"
        func clock(_ date: Date) -> TimeInterval {
            let components = calendar.dateComponents([.hour, .minute, .second], from: date)
            return Double((components.hour ?? 0) * 3_600 + (components.minute ?? 0) * 60 + (components.second ?? 0))
        }
        func homeArrivalClock(_ date: Date) -> TimeInterval {
            let value = clock(date)
            // Only the comparison wraps at 06:00. Keep the actual arrival date
            // and the session's calendar-date attribution intact.
            return value < 6 * 3_600 ? value + 86_400 : value
        }
        var result: [JournalSummaryMetric] = []
        for type in PlaceType.allCases {
            let records = summaryRecords.filter { $0.placeType == type }
            guard !records.isEmpty else { continue }
            let total = records.compactMap(\.duration).reduce(0, +)
            let title = type == .work ? "已工作" : type == .home ? "在家待了" : "\(type.displayName)时长"
            if records.contains(where: { $0.duration != nil }) {
                result.append(.init(title: title, value: TimeJournalService.duration(total)))
            }
            if type == .work {
                // Each completed work date gets one vote, even with multiple visits.
                // An unfinished date has no knowable final departure yet.
                let grouped = Dictionary(grouping: records) { calendar.startOfDay(for: $0.start) }
                let completeDays = grouped.filter { $0.value.allSatisfy { $0.duration != nil } }
                if !completeDays.isEmpty {
                    let averageDuration = completeDays.values.reduce(0.0) { total, day in
                        total + day.compactMap(\.duration).reduce(0, +)
                    } / Double(completeDays.count)
                    result.append(.init(title: "平均每天工作", value: TimeJournalService.duration(averageDuration)))
                }
                let departures = completeDays.compactMap { day, visits -> (date: Date, offset: TimeInterval)? in
                    guard let end = visits.compactMap(\.end).max() else { return nil }
                    let dayOffset = calendar.dateComponents([.day], from: day, to: calendar.startOfDay(for: end)).day ?? 0
                    let clock = calendar.dateComponents([.hour, .minute, .second], from: end)
                    let seconds = dayOffset * 86_400 + (clock.hour ?? 0) * 3_600
                        + (clock.minute ?? 0) * 60 + (clock.second ?? 0)
                    return (end, Double(seconds))
                }
                if let latest = departures.max(by: {
                    $0.offset == $1.offset ? $0.date < $1.date : $0.offset < $1.offset
                }) {
                    result.append(.init(title: "最晚下班", value: formatter.string(from: latest.date)))
                    let average = departures.map(\.offset).reduce(0, +) / Double(departures.count)
                    let minutes = Int(average / 60)
                    let dayOffset = minutes / 1_440
                    let prefix = dayOffset == 1 ? "次日 " : dayOffset > 1 ? "第\(dayOffset + 1)天 " : ""
                    let clock = String(format: "%02d:%02d", (minutes % 1_440) / 60, minutes % 60)
                    result.append(.init(title: "平均下班", value: prefix + clock))
                }
            } else if type == .home {
                if let arrival = records.map(\.start).max(by: {
                    let left = homeArrivalClock($0), right = homeArrivalClock($1)
                    return left == right ? $0 < $1 : left < right
                }) {
                    result.append(.init(title: "最晚到家", value: formatter.string(from: arrival)))
                }
                if let departure = records.compactMap(\.end).min(by: { clock($0) < clock($1) }) {
                    result.append(.init(title: "最早离家", value: formatter.string(from: departure)))
                }
            }
        }
        if result.isEmpty {
            result.append(.init(title: "记录摘要", value: unfinishedCount > 0 ? "等待本次记录结束" : "暂无可总结的地点记录"))
        }
        return result
    }

    /// A bounded overview: one tile per represented category, using the same facts as detail.
    var typeSummaries: [JournalTypeSummary] {
        let metrics = Dictionary(uniqueKeysWithValues: summaryMetrics.map { ($0.title, $0.value) })
        return PlaceType.allCases.compactMap { type in
            let records = summaryRecords.filter { $0.placeType == type }
            guard !records.isEmpty else { return nil }
            let durations = records.compactMap(\.duration)
            let total = durations.reduce(0, +)
            let number: String
            let unit: String
            if durations.isEmpty {
                number = "—"
                unit = ""
            } else if total < 3_600 {
                number = String(Int(total / 60))
                unit = "分钟"
            } else {
                // Round down to a tenth of an hour, without overstating recorded time.
                let tenths = Int(total / 360)
                number = tenths % 10 == 0 ? String(tenths / 10) : "\(tenths / 10).\(tenths % 10)"
                unit = "小时"
            }
            let detailTitle: String
            let detailValue: String
            if type == .work {
                detailTitle = "日均工作"
                detailValue = metrics["平均每天工作"] ?? "等待记录结束"
            } else if type == .home {
                detailTitle = "最晚到家"
                detailValue = metrics["最晚到家"] ?? "暂无记录"
            } else {
                detailTitle = "单次最长"
                detailValue = durations.max().map(TimeJournalService.duration) ?? "等待记录结束"
            }
            return JournalTypeSummary(type: type, number: number, unit: unit,
                durationDescription: durations.isEmpty ? "记录中" : TimeJournalService.duration(total),
                detailTitle: detailTitle, detailValue: detailValue)
        }
    }

    /// Readable conclusions, shared verbatim by the screen and exported poster.
    var summaryParagraphs: [String] {
        let metrics = summaryMetrics
        let groups = [
            ["已工作", "平均每天工作"],
            ["最晚下班", "平均下班"],
            ["在家待了"],
            ["最晚到家", "最早离家"]
        ]
        var paragraphs = groups.compactMap { titles -> String? in
            let statements = titles.compactMap { title in metrics.first { $0.title == title }?.statement }
            return statements.isEmpty ? nil : statements.joined(separator: "，") + "。"
        }
        let groupedTitles = Set(groups.flatMap { $0 })
        paragraphs += metrics.filter { !groupedTitles.contains($0.title) }.map { $0.statement + "。" }
        return paragraphs
    }

}

struct JournalSummaryMetric: Equatable, Identifiable {
    var id: String { title }
    let title: String
    let value: String

    var statement: String {
        switch title {
        case "最晚下班": "最晚在\(value)下班"
        case "平均下班": "平均\(value)下班"
        case "最晚到家": "最晚在\(value)到家"
        case "最早离家": "最早在\(value)离家"
        case "记录摘要": value
        default: title + value
        }
    }
}

struct TimeJournalService {
    func make(sessions: [ActivitySession], places: [ActivityTrigger], interval: DateInterval,
              previous: DateInterval, filter: PlaceSessionFilter, calendar: Calendar,
              now: Date) -> TimeJournal {
        let placeMap = Dictionary(places.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let selected = sessions.filter { $0.deletedAt == nil && $0.startAt <= now && filter.includes($0) }
        let snapshots: [JournalRecord] = selected.map { session in
                let place = session.placeTriggerId.flatMap { placeMap[$0] }
                let closed = session.endAt.map { $0 <= now && $0 >= session.startAt } ?? false
                return JournalRecord(id: session.id, start: session.startAt,
                    end: closed ? session.endAt : nil, duration: closed ? session.duration : nil,
                    placeID: session.placeTriggerId,
                    placeName: session.placeTriggerId == nil ? "未标记地点" : (place?.displayPlaceName ?? "已删除地点"),
                    placeType: place?.placeType)
            }
        let records = snapshots.sorted { left, right in
            if left.start == right.start { return left.id.uuidString < right.id.uuidString }
            return left.start < right.start
        }
        func within(_ range: DateInterval) -> [JournalRecord] {
            records.filter { $0.start >= range.start && $0.start < range.end }
        }
        func groups(_ values: [JournalRecord]) -> [Date: [JournalRecord]] {
            Dictionary(grouping: values) { calendar.startOfDay(for: $0.start) }
        }
        func total(_ values: [JournalRecord]) -> TimeInterval { values.compactMap(\.duration).reduce(0, +) }
        let current = within(interval)
        let grouped = groups(current)
        let duration = total(current)
        let unfinished = current.filter { $0.duration == nil }.count
        let selectedPlace: ActivityTrigger?
        if case .place(let id) = filter { selectedPlace = id.flatMap { placeMap[$0] } } else { selectedPlace = nil }
        let privateScope: String
        let scope: String
        switch filter {
        case .all:
            scope = "全部类型"; privateScope = "生活片段"
        case .place(let id):
            scope = id == nil ? "未标记地点" : (selectedPlace?.displayPlaceName ?? "已删除地点")
            privateScope = selectedPlace.map { "\($0.placeType.displayName)记录" } ?? "地点记录"
        case .placeType(let type, _):
            scope = type.displayName
            privateScope = "\(type.displayName)记录"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_Hans_CN")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "M月d日"
        func date(_ value: Date) -> String { formatter.string(from: value) }
        let lastDay = calendar.date(byAdding: .day, value: -1, to: interval.end) ?? interval.start
        let label = "\(date(interval.start)) — \(date(lastDay))"
        var findings: [JournalFinding] = []

        // Only compare completed calendar dates, with the same elapsed progress in each period.
        let today = calendar.startOfDay(for: now)
        let comparisonEnd = min(interval.end, today)
        let elapsedDays = max(0, calendar.dateComponents([.day], from: interval.start, to: comparisonEnd).day ?? 0)
        let previousEnd = min(previous.end, calendar.date(byAdding: .day, value: elapsedDays, to: previous.start) ?? previous.start)
        let comparable = comparisonEnd > interval.start ? within(DateInterval(start: interval.start, end: comparisonEnd)) : []
        let older = previousEnd > previous.start ? within(DateInterval(start: previous.start, end: previousEnd)) : []
        let oldTotal = total(older)
        let change = total(comparable) - oldTotal
        let hasIncomplete = current.contains { $0.duration == nil } || within(previous).contains { $0.duration == nil }
        if !hasIncomplete, groups(comparable).count >= 3, groups(older).count >= 3,
           oldTotal > 0, abs(change) >= 3600, abs(change) / oldTotal >= 0.15 {
            let direction = change > 0 ? "多" : "少"
            let comparisonLast = calendar.date(byAdding: .day, value: -1, to: comparisonEnd) ?? interval.start
            let previousLast = calendar.date(byAdding: .day, value: -1, to: previousEnd) ?? previous.start
            let detail = "\(date(interval.start))—\(date(comparisonLast))，比 \(date(previous.start))—\(date(previousLast)) \(direction)记录了 \(Self.duration(abs(change)))的停留。"
            findings.append(.init(kind: .comparison, title: "停留时间\(direction)了 \(Self.duration(abs(change)))", detail: detail, records: comparable + older, changeSeconds: change))
        }
        // Unknown/deleted locations cannot establish a meaningful recurring place.
        let recurring = Dictionary(grouping: current.filter { $0.placeID != nil && $0.placeType != nil }, by: \.placeID)
            .values.filter { groups($0).count >= 3 }
            .sorted {
                let left = groups($0).count, right = groups($1).count
                return left == right ? ($0.first?.placeID?.uuidString ?? "") < ($1.first?.placeID?.uuidString ?? "") : left > right
            }.first
        if let recurring, let first = recurring.first {
            let count = groups(recurring).count
            let action = first.placeType == .study ? "学习" : first.placeType == .exercise ? "运动" : "到访"
            let detail = "\(count) 个不同的日子，留下了 \(recurring.count) 段\(action)记录。"
            findings.append(.init(kind: .recurring, title: "有个地方，出现在 \(count) 天里", detail: detail, records: recurring))
        }
        if let longest = current.filter({ $0.duration != nil }).max(by: { ($0.duration ?? 0) < ($1.duration ?? 0) }) {
            findings.append(.init(kind: .memorable, title: "\(date(longest.start))，一段较长的停留", detail: "这段记录持续了 \(Self.duration(longest.duration ?? 0))，是本期已完成记录中最长的一次。", records: [longest]))
        }
        return TimeJournal(interval: interval, dateLabel: label, scope: scope, privateScope: privateScope,
            totalDuration: duration,
            recordedDays: grouped.count, recordCount: current.count, unfinishedCount: unfinished,
            findings: Array(findings.prefix(3)), calendar: calendar, summaryRecords: current)
    }

    static func duration(_ value: TimeInterval) -> String {
        let minutes = max(0, Int(value / 60))
        if minutes < 60 { return "\(minutes) 分钟" }
        return minutes % 60 == 0 ? "\(minutes / 60) 小时" : "\(minutes / 60) 小时 \(minutes % 60) 分钟"
    }
}


/// Only anonymous aggregates cross the API boundary. IDs bind copy to the exact fact snapshot.
struct InsightFact: Codable, Equatable {
    let id: String
    let kind: String
    let completedDurationSeconds: Int
    let recordCount: Int
    let recordedDays: Int
    let changeSeconds: Int?
}

extension TimeJournal {
    var candidateFacts: [InsightFact] {
        findings.map { finding in
            let duration = Int(finding.records.compactMap(\.duration).reduce(0, +))
            let count = finding.records.count
            let days = Set(finding.records.map { calendar.startOfDay(for: $0.start) }).count
            // Includes the local evidence fingerprint, but never sends raw records or identifiers.
            let evidence = finding.records.map {
                "\($0.id)|\($0.start.timeIntervalSince1970)|\($0.end?.timeIntervalSince1970 ?? -1)|\($0.placeType?.rawValue ?? "unknown")"
            }.sorted().joined(separator: ";")
            let seed = "\(interval.start)|\(interval.end)|\(privateScope)|\(totalDuration)|\(recordCount)|\(unfinishedCount)|\(finding.kind.rawValue)|\(finding.changeSeconds ?? 0)|\(evidence)"
            return InsightFact(id: Self.fingerprint(seed), kind: finding.kind.rawValue,
                completedDurationSeconds: duration, recordCount: count, recordedDays: days,
                changeSeconds: finding.changeSeconds.map(Int.init))
        }
    }

    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    var summaryEvidence: JournalFinding? {
        guard !summaryRecords.isEmpty else { return nil }
        return JournalFinding(kind: .memorable, title: "统计依据",
            detail: "按所选范围内记录的开始日期归属。时长仅计已结束记录。平均每天工作多久，以记录完整的工作日期为分母，同一天的多段工作先合并；最晚与平均下班取这些日期的最后一次离开，跨午夜保留次日偏移，未记录的日期不当作零工时。最晚到家以早上 06:00 为跨夜分界，00:00–05:59 排在前一晚之后；最早离家按实际本地钟点比较。均显示实际发生日期，不改动原始记录和日期归属。工作跨午夜离开按该次开始日比较。",
            records: summaryRecords)
    }
    var mainFinding: JournalFinding? { findings.first }
    var insightTitle: String {
        switch mainFinding?.kind {
        case .comparison: "页边的宽窄"
        case .recurring: "日子的叠句"
        case .memorable: "一页慢慢展开"
        case nil: recordCount == 0 ? "纸外，还有生活" : "尚未落下的句点"
        }
    }
    var insightBody: String {
        switch mainFinding?.kind {
        case .comparison: "记录里的笔墨换了疏密，生活的分量，却不只在数字之间。"
        case .recurring: "相似的段落再次落笔，回看时，日子便有了韵脚。"
        case .memorable: "散落的片刻之间，这一段停留，舒展成较长的一行。"
        case nil: recordCount == 0 ? "这一页暂时空着，生活仍在纸外展开。" : "还有片刻尚未收笔，先让这一行留在途中。"
        }
    }
}

struct JournalTypeSummary: Identifiable, Equatable {
    var id: PlaceType { type }
    let type: PlaceType
    let number: String
    let unit: String
    let durationDescription: String
    let detailTitle: String
    let detailValue: String
}
