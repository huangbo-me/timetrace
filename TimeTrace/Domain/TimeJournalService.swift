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
    var canShare: Bool { recordCount > 0 }
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
            findings: Array(findings.prefix(3)), calendar: calendar)
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
