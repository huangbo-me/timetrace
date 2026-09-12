import Foundation

struct InsightCopy: Codable, Equatable {
    let title: String
    let body: String
    let style: InsightStyle

    var isValid: Bool {
        zip([title, body], [8, 24]).allSatisfy { text, limit in
            !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.unicodeScalars.count <= limit
        } && style.isValid
    }
}

/// Server-expanded, opaque sRGB colors. Reject malformed styles with the whole response.
struct InsightStyle: Codable, Equatable {
    let backgroundStyle: String
    let palette: String
    let backgroundStart: String
    let backgroundEnd: String
    let textColor: String
    let secondaryTextColor: String
    let accentColor: String

    static func rgb(_ hex: String) -> UInt32? {
        guard hex.utf8.count == 7, hex.first == "#",
              hex.dropFirst().utf8.allSatisfy({
                  (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0)
              }) else { return nil }
        return UInt32(hex.dropFirst(), radix: 16)
    }

    var isValid: Bool {
        ["solid", "linearGradient"].contains(backgroundStyle) &&
        ["warm", "sage", "sky", "lavender", "rose"].contains(palette) &&
        [backgroundStart, backgroundEnd, textColor, secondaryTextColor, accentColor]
            .allSatisfy { Self.rgb($0) != nil } &&
        (backgroundStyle != "solid" || Self.rgb(backgroundStart) == Self.rgb(backgroundEnd))
    }
}

/// JSON uses explicit local dates and seconds; no raw records or place identifiers leave the device.
struct InsightSummaryRequest: Codable, Equatable {
    let scene = "insights_summary"
    let schemaVersion = 2
    let date: String
    let timezone: String
    let locale = "zh-Hans"
    let generatedFrom: String
    let day: Period
    let week: Period
    let periods: [Period]
    var recent: Period? = nil
    var recentSourceID: String? = nil
    // Local-only evidence used to invalidate a saved tip. Explicitly excluded from JSON.
    var tipSources: [String: String] = [:]
    enum CodingKeys: String, CodingKey {
        case scene, schemaVersion, date, timezone, locale, generatedFrom, day, week, periods, recent, recentSourceID
    }

    struct TypeStats: Codable, Equatable {
        let type: String
        let completedDurationSeconds: Double
        let recordCount: Int
        let unfinishedCount: Int
        let recordedDays: Int?
        var facts: [InsightFact]? = nil

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(type, forKey: .type)
            try values.encode(InsightSummaryRequest.integerSeconds(completedDurationSeconds), forKey: .completedDurationSeconds)
            try values.encode(recordCount, forKey: .recordCount)
            try values.encode(unfinishedCount, forKey: .unfinishedCount)
            try values.encodeIfPresent(facts, forKey: .facts)
            try values.encodeIfPresent(recordedDays, forKey: .recordedDays)
        }
    }

    struct Period: Codable, Equatable {
        let id: String?
        let kind: String?
        let date: String?
        let startDate: String?
        let endDateExclusive: String?
        let completedDurationSeconds: Double
        let recordCount: Int
        let unfinishedCount: Int
        let recordedDays: Int?
        let types: [TypeStats]
        var facts: [InsightFact]? = nil

        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encodeIfPresent(id, forKey: .id)
            try values.encodeIfPresent(kind, forKey: .kind)
            try values.encodeIfPresent(date, forKey: .date)
            try values.encodeIfPresent(startDate, forKey: .startDate)
            try values.encodeIfPresent(endDateExclusive, forKey: .endDateExclusive)
            try values.encode(InsightSummaryRequest.integerSeconds(completedDurationSeconds), forKey: .completedDurationSeconds)
            try values.encode(recordCount, forKey: .recordCount)
            try values.encode(unfinishedCount, forKey: .unfinishedCount)
            try values.encodeIfPresent(facts, forKey: .facts)
            try values.encodeIfPresent(recordedDays, forKey: .recordedDays)
            try values.encode(types, forKey: .types)
        }
    }

    // The backend decodes int64 seconds. Keep Double when reading older cached requests,
    // and discard subsecond precision only when encoding the aggregate for transport/storage.
    private static func integerSeconds(_ duration: Double) throws -> Int64 {
        guard duration >= 0, let seconds = Int64(exactly: duration.rounded(.down)) else {
            throw InsightAPIError.invalidResponse
        }
        return seconds
    }

    static func dateString(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    static func timestamp(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }

    static func parseTimestamp(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: value)
    }

    @MainActor
    static func make(sessions: [ActivitySession], places: [ActivityTrigger], calendar: Calendar,
                     now: Date, additional: [(String, DateInterval)]) -> Self {
        var calendar = calendar
        calendar.firstWeekday = 2
        calendar.minimumDaysInFirstWeek = 4
        let today = calendar.startOfDay(for: now)
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: today)!
        let week = calendar.dateInterval(of: .weekOfYear, for: now)!
        func period(_ interval: DateInterval, day: Bool = false, id: String? = nil) -> Period {
            func journal(_ filter: PlaceSessionFilter) -> TimeJournal {
                TimeJournalService().make(sessions: sessions, places: places, interval: interval,
                    previous: DateInterval(start: calendar.date(byAdding: .day,
                        value: -max(1, calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 1),
                        to: interval.start)!, end: interval.start), filter: filter, calendar: calendar, now: now)
            }
            let all = journal(.all)
            return Period(id: id, kind: id == nil ? nil : "range",
                date: day ? dateString(interval.start, calendar: calendar) : nil,
                startDate: day ? nil : dateString(interval.start, calendar: calendar),
                endDateExclusive: day ? nil : dateString(interval.end, calendar: calendar),
                completedDurationSeconds: all.totalDuration, recordCount: all.recordCount,
                unfinishedCount: all.unfinishedCount, recordedDays: day ? nil : all.recordedDays,
                types: PlaceType.allCases.compactMap { type -> TypeStats? in
                    let value = journal(.forType(type, places: places))
                    guard value.recordCount > 0 else { return nil }
                    return TypeStats(type: type.rawValue, completedDurationSeconds: value.totalDuration,
                        recordCount: value.recordCount, unfinishedCount: value.unfinishedCount,
                        recordedDays: day ? nil : value.recordedDays, facts: value.candidateFacts)
                }, facts: all.candidateFacts)
        }
        var request = Self(date: dateString(now, calendar: calendar), timezone: calendar.timeZone.identifier,
            generatedFrom: timestamp(now), day: period(DateInterval(start: today, end: tomorrow), day: true),
            week: period(week), periods: additional.map { period($0.1, id: $0.0) })
        let recentStart = calendar.date(byAdding: .day, value: -7, to: today)!
        request.recent = period(DateInterval(start: recentStart, end: today), id: "recent_completed_days")
        let placeTypes = Dictionary(places.map { ($0.id, $0.placeType.rawValue) }, uniquingKeysWith: { first, _ in first })
        for session in sessions where session.deletedAt == nil && session.startAt >= recentStart && session.startAt < today {
            let type = session.placeTriggerId.flatMap { placeTypes[$0] } ?? "unknown"
            request.tipSources[session.id.uuidString] = TimeJournal.fingerprint(
                "\(session.startAt)|\(String(describing: session.endAt))|\(type)")
        }
        request.recentSourceID = TimeJournal.fingerprint(request.tipSources.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: "|"))
        return request
    }
}

struct InsightSummaryResponse: Codable, Equatable {
    let schemaVersion: Int
    let summaryDate: String
    let generatedAt: String
    let dataAsOf: String
    let day: Period
    let week: Period
    let periods: [Period]?
    var dailyTip: DailyTipCopy? = nil

    struct TypedCopy: Codable, Equatable {
        let type: String
        let copy: InsightCopy
        var insight: PeriodInsightCopy? = nil
    }
    struct Period: Codable, Equatable {
        let id: String?
        let kind: String?
        let date: String?
        let startDate: String?
        let endDateExclusive: String?
        let copy: InsightCopy
        let types: [TypedCopy]
        var insight: PeriodInsightCopy? = nil
    }

    func validate(for request: InsightSummaryRequest) throws {
        let all = [day, week] + (periods ?? [])
        guard schemaVersion == 2, summaryDate == request.date, day.date == summaryDate,
              week.startDate == request.week.startDate,
              week.endDateExclusive == request.week.endDateExclusive,
              InsightSummaryRequest.parseTimestamp(generatedAt) != nil,
              InsightSummaryRequest.parseTimestamp(dataAsOf) != nil,
              all.allSatisfy({ period in
                  period.copy.isValid && period.types.allSatisfy { $0.copy.isValid } &&
                  Set(period.types.map(\.type)).count == period.types.count
              }) else { throw InsightAPIError.invalidResponse }
    }


}


/// Decode new optional fields independently, even when a server returns the wrong JSON shape.
struct DailyTipCopy: Codable, Equatable {
    let date: String
    let text: String
    let sourceID: String
    init(date: String, text: String, sourceID: String = "") { self.date = date; self.text = text; self.sourceID = sourceID }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        date = (try? c?.decode(String.self, forKey: .date)) ?? ""
        text = (try? c?.decode(String.self, forKey: .text)) ?? ""
        sourceID = (try? c?.decode(String.self, forKey: .sourceID)) ?? ""
    }
    var isValid: Bool { validShortText(text, limit: 40) }
}

struct PeriodInsightCopy: Codable, Equatable {
    let factID: String
    let title: String
    let body: String
    init(factID: String, title: String, body: String) {
        self.factID = factID; self.title = title; self.body = body
    }
    init(from decoder: Decoder) throws {
        let c = try? decoder.container(keyedBy: CodingKeys.self)
        factID = (try? c?.decode(String.self, forKey: .factID)) ?? ""
        title = (try? c?.decode(String.self, forKey: .title)) ?? ""
        body = (try? c?.decode(String.self, forKey: .body)) ?? ""
    }
    var isValid: Bool { !factID.isEmpty && validShortText(title, limit: 24) && validShortText(body, limit: 48) }
}

private func validShortText(_ text: String, limit: Int) -> Bool {
    !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && text.unicodeScalars.count <= limit
}

extension InsightSummaryRequest {
    var localTip: String {
        guard let recent, recent.recordCount > 0 else { return "想记的时候，就从今天的一小段日常开始。" }
        if recent.types.contains(where: { $0.type == "exercise" && ($0.recordedDays ?? 0) >= 3 }) {
            return "最近几天给运动留了时间，也记得按自己的步调来。"
        }
        if recent.types.contains(where: { $0.type == "study" && ($0.recordedDays ?? 0) >= 3 }) {
            return "最近留下了几段学习时光，慢慢来，也给自己留点空隙。"
        }
        if recent.types.contains(where: { $0.type == "work" && $0.completedDurationSeconds > 0 }) {
            return "记录里有工作的时间，今天也可以给喜欢的小事留一点位置。"
        }
        return "最近的日常已经留下痕迹，今天也按自己喜欢的步调走吧。"
    }
}

extension InsightSummaryResponse {
    func insight(journal: TimeJournal, type: PlaceType?) -> PeriodInsightCopy? {
        let start = InsightSummaryRequest.dateString(journal.interval.start, calendar: journal.calendar)
        let end = InsightSummaryRequest.dateString(journal.interval.end, calendar: journal.calendar)
        let single = journal.calendar.date(byAdding: .day, value: 1, to: journal.interval.start) == journal.interval.end
        let period = single && day.date == start ? day : ([week] + (periods ?? [])).first {
            $0.startDate == start && $0.endDateExclusive == end
        }
        let copy: PeriodInsightCopy?
        if let type { copy = period?.types.first { $0.type == type.rawValue }?.insight }
        else { copy = period?.insight }
        guard let copy, copy.isValid, copy.factID == journal.candidateFacts.first?.id else { return nil }
        return copy
    }
}
