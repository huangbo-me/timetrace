import XCTest
import SwiftUI
@testable import TimeTrace

@MainActor
final class InsightSummaryTests: XCTestCase {
    private static let style = InsightStyle(backgroundStyle: "linearGradient", palette: "warm",
        backgroundStart: "#FFF7ED", backgroundEnd: "#F3E8D8", textColor: "#352B25",
        secondaryTextColor: "#665348", accentColor: "#875137")

    func testBackendV2MockAndCopyLimits() throws {
        let response = try JSONDecoder().decode(InsightSummaryResponse.self, from: Data(Self.backendMock.utf8))
        try response.validate(for: input())
        XCTAssertNil(response.periods)
        XCTAssertEqual(response.day.copy.style, Self.style)
        XCTAssertEqual(response.week.copy.style.palette, "sky")
        XCTAssertEqual(input().schemaVersion, 2)
        XCTAssertTrue(InsightCopy(title: String(repeating: "字", count: 8),
            body: String(repeating: "字", count: 24), style: Self.style).isValid)
        XCTAssertFalse(InsightCopy(title: "标题", body: String(repeating: "字", count: 25), style: Self.style).isValid)
        XCTAssertNil(InsightStyle.rgb("#FFFFFFFF"))
        XCTAssertNil(InsightStyle.rgb("#GG0000"))
        XCTAssertNil(InsightStyle.rgb("FFFFFF"))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.backendMock.utf8)) as? [String: Any])
        json["schemaVersion"] = 1
        let legacy = try JSONDecoder().decode(InsightSummaryResponse.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertThrowsError(try legacy.validate(for: input()))
        for invalid in ["#FFF", "#00000000", "#ZZZZZZ"] {
            var broken = Self.style
            broken = InsightStyle(backgroundStyle: broken.backgroundStyle, palette: broken.palette,
                backgroundStart: invalid, backgroundEnd: broken.backgroundEnd, textColor: broken.textColor,
                secondaryTextColor: broken.secondaryTextColor, accentColor: broken.accentColor)
            XCTAssertFalse(InsightCopy(title: "标题", body: "正文", style: broken).isValid)
        }

    }

    func testCareWindowExcludesTodayAndDeletedRecords() throws {
        let activity = UUID()
        let old = ActivitySession(activityId: activity, startAt: date(3, 9), endAt: date(3, 10), status: .completed)
        let recent = ActivitySession(activityId: activity, startAt: date(4, 9), endAt: date(4, 10), status: .completed)
        let today = ActivitySession(activityId: activity, startAt: date(11, 9), endAt: date(11, 10), status: .completed)
        let deleted = ActivitySession(activityId: activity, startAt: date(10, 9), endAt: date(10, 10), status: .completed)
        deleted.deletedAt = date(11)
        let request = InsightSummaryRequest.make(sessions: [old, recent, today, deleted], places: [],
            calendar: calendar, now: date(11), additional: [])
        XCTAssertEqual(request.recent?.startDate, "2026-09-04")
        XCTAssertEqual(request.recent?.endDateExclusive, "2026-09-11")
        XCTAssertEqual(request.recent?.recordCount, 1)
        XCTAssertEqual(request.recent?.completedDurationSeconds, 3600)
        XCTAssertEqual(Set(request.tipSources.keys), [recent.id.uuidString])
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertFalse(json.contains(recent.id.uuidString))
        XCTAssertFalse(json.contains("tipSources"))
    }

    func testSavedTipStaysStableForAdditionsButInvalidatesChangedEvidence() {
        var request = input()
        request.tipSources = ["a": "original"]
        let saved = SavedDailyTip(date: request.date, timezone: request.timezone, text: "慢慢来。", sources: request.tipSources)
        request.tipSources["b"] = "new"
        XCTAssertTrue(saved.matches(request))
        request.tipSources["a"] = "edited"
        XCTAssertFalse(saved.matches(request))
        request.tipSources.removeValue(forKey: "a")
        XCTAssertFalse(saved.matches(request))
        XCTAssertFalse(saved.matches(input(day: 12)))
        var otherZone = calendar
        otherZone.timeZone = TimeZone(secondsFromGMT: 0)!
        let other = InsightSummaryRequest.make(sessions: [], places: [], calendar: otherZone, now: date(11), additional: [])
        XCTAssertFalse(saved.matches(other))
    }

    func testNewCopyFieldsFailIndependentlyAndKeepLegacyCopy() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(Self.backendMock.utf8)) as? [String: Any])
        for malformed in [42 as Any, ["date": "2026-09-11", "text": String(repeating: "字", count: 41)], ["text": []]] {
            json["dailyTip"] = malformed
            var day = try XCTUnwrap(json["day"] as? [String: Any])
            day["insight"] = ["factID": "wrong", "title": 42, "body": "短句"]
            json["day"] = day
            let response = try JSONDecoder().decode(InsightSummaryResponse.self, from: JSONSerialization.data(withJSONObject: json))
            try response.validate(for: input())
            XCTAssertFalse(response.dailyTip?.isValid ?? true)
            XCTAssertFalse(response.day.insight?.isValid ?? true)
            XCTAssertTrue(response.day.copy.isValid)
        }
        XCTAssertTrue(DailyTipCopy(date: "2026-09-11", text: String(repeating: "字", count: 40)).isValid)
        XCTAssertFalse(PeriodInsightCopy(factID: "fact", title: String(repeating: "字", count: 25), body: "短句").isValid)
        XCTAssertFalse(PeriodInsightCopy(factID: "fact", title: "标题", body: String(repeating: "字", count: 49)).isValid)
    }

    func testInsightIsBoundToCurrentPrimaryEvidenceAndType() throws {
        let activity = UUID()
        let place = ActivityTrigger(activityId: activity, type: .geofence, placeName: "私密地点", placeType: .exercise)
        let session = ActivitySession(activityId: activity, placeTriggerId: place.id,
            startAt: date(11, 8), endAt: date(11, 9), status: .completed)
        func journal(_ type: PlaceType? = nil) -> TimeJournal {
            TimeJournalService().make(sessions: [session], places: [place],
                interval: DateInterval(start: date(11, 0), end: date(12, 0)),
                previous: DateInterval(start: date(10, 0), end: date(11, 0)),
                filter: type.map { .forType($0, places: [place]) } ?? .all, calendar: calendar, now: date(11))
        }
        let original = journal()
        let request = InsightSummaryRequest.make(sessions: [session], places: [place], calendar: calendar, now: date(11), additional: [])
        XCTAssertEqual(request.day.facts, original.candidateFacts)
        var response = result(request)
        let copy = PeriodInsightCopy(factID: try XCTUnwrap(original.candidateFacts.first?.id), title: "一段较长的停留", body: "留给以后的自己。")
        // Mutate via JSON because the legacy envelope is an immutable snapshot.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(response)) as? [String: Any])
        var day = try XCTUnwrap(json["day"] as? [String: Any])
        day["insight"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(copy))
        json["day"] = day
        response = try JSONDecoder().decode(InsightSummaryResponse.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(response.insight(journal: original, type: nil), copy)
        XCTAssertNil(response.insight(journal: journal(.exercise), type: .exercise))
        session.endAt = date(11, 10)
        XCTAssertNil(response.insight(journal: journal(), type: nil))
        session.deletedAt = date(11)
        XCTAssertNil(response.insight(journal: journal(), type: nil))
    }

    func testDailyTipPersistsAcrossRelaunchAndClearsOnAccountReset() async throws {
        let suite = "TimeTraceCareTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let request = input()
        var calls = 0
        let client = InsightAPIClient(transport: { req in
            calls += 1
            if calls > 1 { throw URLError(.timedOut) }
            var response = self.result(request)
            response.dailyTip = .init(date: request.date, text: "给今天留一点喜欢的时间。", sourceID: request.recentSourceID!)
            return (try JSONEncoder().encode(response), self.http(req))
        }, readToken: { .init(owner: "owner", accessToken: "token", expiresAt: self.date(12)) },
            writeToken: { _ in }, clock: { self.date(11) })
        let first = DailyInsightSummary(client: client, defaults: defaults, identity: { "owner" })
        await first.load(request)?.value
        XCTAssertEqual(first.tip(for: request), "给今天留一点喜欢的时间。")
        let relaunched = DailyInsightSummary(client: client, defaults: defaults, identity: { "owner" })
        await relaunched.load(request)?.value
        XCTAssertEqual(relaunched.tip(for: request), first.tip(for: request))
        XCTAssertTrue(relaunched.canRetry)
        let other = DailyInsightSummary(client: client, defaults: defaults, identity: { "other" })
        await other.load(request)?.value
        XCTAssertEqual(other.savedTip?.generated, false)
        relaunched.resetIdentity()
        XCTAssertNil(relaunched.savedTip)
        XCTAssertNil(defaults.data(forKey: "TimeTrace.dailyCare." + TimeJournal.fingerprint("owner")))
    }

    func testStaleTipSourceCannotBeSaved() async throws {
        let suite = "TimeTraceCareTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let request = input()
        let client = InsightAPIClient(transport: { req in
            var response = self.result(request)
            response.dailyTip = .init(date: request.date, text: "旧记录生成的关照。", sourceID: "stale")
            return (try JSONEncoder().encode(response), self.http(req))
        }, readToken: { .init(owner: "owner", accessToken: "token", expiresAt: self.date(12)) },
            writeToken: { _ in }, clock: { self.date(11) })
        let service = DailyInsightSummary(client: client, defaults: defaults, identity: { "owner" })
        await service.load(request)?.value
        XCTAssertEqual(service.savedTip?.generated, false)
        XCTAssertEqual(service.tip(for: request), request.localTip)
        XCTAssertNotNil(service.response)
    }

    func testSourceDeletionDuringGenerationRejectsReturnedTip() async throws {
        let suite = "TimeTraceCareTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var request = input()
        request.tipSources = ["removed-record": "original"]
        request.recentSourceID = "original-source"
        var changed = request
        changed.tipSources = [:]
        changed.recentSourceID = "empty-source"
        var service: DailyInsightSummary!
        let client = InsightAPIClient(transport: { req in
            service.load(changed)
            var response = self.result(request)
            response.dailyTip = .init(date: request.date, text: "不能继续展示的旧关照。", sourceID: request.recentSourceID!)
            return (try JSONEncoder().encode(response), self.http(req))
        }, readToken: { .init(owner: "owner", accessToken: "token", expiresAt: self.date(12)) },
            writeToken: { _ in }, clock: { self.date(11) })
        service = DailyInsightSummary(client: client, defaults: defaults, identity: { "owner" })
        await service.load(request)?.value
        XCTAssertEqual(service.savedTip?.generated, false)
        XCTAssertEqual(service.savedTip?.sources, [:])
        XCTAssertEqual(service.tip(for: changed), changed.localTip)
    }

    func testLocalCareDoesNotRotateWhenRecordsAreAddedAndRelaunchesOffline() async throws {
        let suite = "TimeTraceCareTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let activity = UUID()
        let study = ActivityTrigger(activityId: activity, type: .geofence, placeName: "学习", placeType: .study)
        var sessions = [ActivitySession(activityId: activity, placeTriggerId: study.id,
            startAt: date(8, 8), endAt: date(8, 9), status: .completed)]
        let original = InsightSummaryRequest.make(sessions: sessions, places: [study], calendar: calendar, now: date(11), additional: [])
        let client = InsightAPIClient(transport: { _ in throw URLError(.timedOut) },
            readToken: { .init(owner: "owner", accessToken: "token", expiresAt: self.date(12)) },
            writeToken: { _ in }, clock: { self.date(11) })
        let service = DailyInsightSummary(client: client, defaults: defaults, identity: { "owner" })
        await service.load(original)?.value
        sessions += (9...10).map { ActivitySession(activityId: activity, placeTriggerId: study.id,
            startAt: date($0, 8), endAt: date($0, 9), status: .completed) }
        let added = InsightSummaryRequest.make(sessions: sessions, places: [study], calendar: calendar, now: date(11), additional: [])
        XCTAssertNotEqual(original.localTip, added.localTip)
        await service.load(added)?.value
        XCTAssertEqual(service.tip(for: added), original.localTip)
        let relaunched = DailyInsightSummary(client: client, defaults: defaults, identity: { "owner" })
        await relaunched.load(added)?.value
        XCTAssertEqual(relaunched.tip(for: added), original.localTip)
    }

    func testCareAndInsightVisualFixtures() throws {
        let activity = UUID()
        let place = ActivityTrigger(activityId: activity, type: .geofence, placeName: "运动场", placeType: .exercise)
        let sessions = (8...10).map { day in
            ActivitySession(activityId: activity, placeTriggerId: place.id, startAt: date(day, 8), endAt: date(day, 9), status: .completed)
        }
        let journal = TimeJournalService().make(sessions: sessions, places: [place],
            interval: DateInterval(start: date(7, 0), end: date(14, 0)),
            previous: DateInterval(start: date(1, 0), end: date(7, 0)), filter: .all, calendar: calendar, now: date(11))
        XCTAssertEqual(journal.mainFinding?.kind, .recurring)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("care-visuals")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for (name, scheme, size) in [("light", ColorScheme.light, DynamicTypeSize.large),
                                      ("dark", ColorScheme.dark, DynamicTypeSize.large),
                                      ("dark-accessibility", ColorScheme.dark, DynamicTypeSize.accessibility3)] {
            let view = VStack(alignment: .leading, spacing: 18) {
                DailyCareCard(text: "最近几天给运动留了时间，也记得按自己的步调来。")
                Text("本周 · 全部类型").foregroundStyle(TimeTraceDesign().ink)
                PeriodInsightCard(journal: journal, showEvidence: {})
            }.padding(20).frame(width: 320).background(TimeTraceDesign().canvas)
                .environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            try XCTUnwrap(renderer.uiImage?.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
        }
        print("Care visual fixtures: \(directory.path)")
    }

    private static let backendMock = #"""
    {
      "schemaVersion": 2,
      "summaryDate": "2026-09-11",
      "generatedAt": "2026-09-11T18:30:05+08:00",
      "dataAsOf": "2026-09-11T18:30:00+08:00",
      "day": {
        "date": "2026-09-11",
        "copy": {
          "title": "忙碌，也有留白",
          "body": "时间分给了很多事，也想留一点给自己。",
          "style": {
            "backgroundStyle": "linearGradient",
            "palette": "warm",
            "backgroundStart": "#FFF7ED",
            "backgroundEnd": "#F3E8D8",
            "textColor": "#352B25",
            "secondaryTextColor": "#665348",
            "accentColor": "#875137"
          }
        },
        "types": [
          {
            "type": "work",
            "copy": {
              "title": "工作之外，还有你",
              "body": "愿接下来的时间，也有你喜欢的部分。",
              "style": {
                "backgroundStyle": "linearGradient",
                "palette": "warm",
                "backgroundStart": "#FFF7ED",
                "backgroundEnd": "#F3E8D8",
                "textColor": "#352B25",
                "secondaryTextColor": "#665348",
                "accentColor": "#875137"
              }
            }
          },
          {
            "type": "exercise",
            "copy": {
              "title": "给自己一点空间",
              "body": "不必和谁比快慢，愿你喜欢自己的步调。",
              "style": {
                "backgroundStyle": "linearGradient",
                "palette": "sage",
                "backgroundStart": "#F2F7F0",
                "backgroundEnd": "#DFEBDE",
                "textColor": "#25372B",
                "secondaryTextColor": "#4C6251",
                "accentColor": "#356448"
              }
            }
          }
        ]
      },
      "week": {
        "startDate": "2026-09-07",
        "endDateExclusive": "2026-09-14",
        "copy": {
          "title": "日子有自己的步调",
          "body": "回看这些片段，也给没被记录的生活留白。",
          "style": {
            "backgroundStyle": "linearGradient",
            "palette": "sky",
            "backgroundStart": "#F0F7FC",
            "backgroundEnd": "#DFEBF5",
            "textColor": "#263749",
            "secondaryTextColor": "#4F6378",
            "accentColor": "#365F87"
          }
        },
        "types": [
          {
            "type": "work",
            "copy": {
              "title": "也惦记自己的小事",
              "body": "工作以外的小小心愿，也值得放在心上。",
              "style": {
                "backgroundStyle": "linearGradient",
                "palette": "warm",
                "backgroundStart": "#FFF7ED",
                "backgroundEnd": "#F3E8D8",
                "textColor": "#352B25",
                "secondaryTextColor": "#665348",
                "accentColor": "#875137"
              }
            }
          },
          {
            "type": "exercise",
            "copy": {
              "title": "和自己好好相处",
              "body": "愿这些属于你的片刻，留下舒服的余味。",
              "style": {
                "backgroundStyle": "linearGradient",
                "palette": "sage",
                "backgroundStart": "#F2F7F0",
                "backgroundEnd": "#DFEBDE",
                "textColor": "#25372B",
                "secondaryTextColor": "#4C6251",
                "accentColor": "#356448"
              }
            }
          }
        ]
      }
    }
    """#

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        value.firstWeekday = 2
        return value
    }
    private func date(_ day: Int, _ hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }
    private func input(day: Int = 11) -> InsightSummaryRequest {
        let activity = UUID()
        let place = ActivityTrigger(activityId: activity, type: .geofence, placeName: "测试", placeType: .work)
        let session = ActivitySession(activityId: activity, placeTriggerId: place.id,
            startAt: date(day, 8), endAt: date(day, 9), status: .completed)
        return InsightSummaryRequest.make(sessions: [session], places: [place], calendar: calendar,
            now: date(day), additional: [])
    }
    private func result(_ input: InsightSummaryRequest) -> InsightSummaryResponse {
        let copy = InsightCopy(title: "每一段日常", body: "这些日常都值得被记住。", style: Self.style)
        func period(_ p: InsightSummaryRequest.Period) -> InsightSummaryResponse.Period {
            .init(id: p.id, kind: p.kind, date: p.date, startDate: p.startDate,
                endDateExclusive: p.endDateExclusive, copy: copy,
                types: p.types.map { .init(type: $0.type, copy: copy) })
        }
        return .init(schemaVersion: 2, summaryDate: input.date, generatedAt: input.generatedFrom,
            dataAsOf: input.generatedFrom, day: period(input.day), week: period(input.week),
            periods: input.periods.map(period))
    }
    private func http(_ request: URLRequest, _ status: Int = 200, headers: [String: String]? = nil) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    func testDiagnosticCodeDoesNotExposeArbitraryServerText() {
        XCTAssertEqual(InsightAPIError(status: 400, code: "INVALID_REQUEST", retryAfter: nil).diagnosticCode,
                       "INVALID_REQUEST")
        XCTAssertEqual(InsightAPIError(status: 400, code: "private-user-data", retryAfter: nil).diagnosticCode,
                       "HTTP_ERROR")
    }

    func testAggregationMatchesJournalAndDoesNotUploadPrivateFields() throws {
        let activity = UUID()
        let place = ActivityTrigger(activityId: activity, type: .geofence,
            placeName: "私人地点不能上传", placeType: .work)
        let closed = ActivitySession(activityId: activity, placeTriggerId: place.id,
            startAt: date(11, 8), endAt: date(11, 10), status: .completed)
        let open = ActivitySession(activityId: activity, placeTriggerId: place.id,
            startAt: date(11, 11), status: .active)
        let deleted = ActivitySession(activityId: activity, placeTriggerId: place.id,
            startAt: date(11, 6), endAt: date(11, 7), status: .completed)
        deleted.deletedAt = date(11)
        let future = ActivitySession(activityId: activity, placeTriggerId: place.id,
            startAt: date(11, 15), endAt: date(11, 16), status: .completed)
        let request = InsightSummaryRequest.make(sessions: [closed, open, deleted, future], places: [place],
            calendar: calendar, now: date(11), additional: [])
        XCTAssertEqual(request.day.recordCount, 2)
        XCTAssertEqual(request.day.completedDurationSeconds, 7200)
        XCTAssertEqual(request.day.unfinishedCount, 1)
        XCTAssertEqual(request.week.startDate, "2026-09-07")
        XCTAssertEqual(request.week.endDateExclusive, "2026-09-14")
        XCTAssertEqual(request.week.recordedDays, 1)
        XCTAssertEqual(request.day.types.first { $0.type == "work" }?.completedDurationSeconds, 7200)
        let json = String(decoding: try JSONEncoder().encode(request), as: UTF8.self)
        XCTAssertFalse(json.contains(place.displayPlaceName))
        XCTAssertFalse(json.contains(place.id.uuidString))
        XCTAssertFalse(json.contains("latitude"))
        XCTAssertTrue(json.contains("insights_summary"))
        XCTAssertEqual(request.day.types.map(\.type), ["work"])
    }

    func testFractionalSessionDurationsEncodeAsIntegerSecondsIncludingCachedRequests() throws {
        let activity = UUID()
        let place = ActivityTrigger(activityId: activity, type: .geofence, placeName: "测试", placeType: .work)
        let session = ActivitySession(activityId: activity, placeTriggerId: place.id,
            startAt: date(11, 8), endAt: date(11, 8).addingTimeInterval(60.75), status: .completed)
        let request = InsightSummaryRequest.make(sessions: [session], places: [place], calendar: calendar,
            now: date(11), additional: [("month", DateInterval(start: date(1, 0), end: date(12, 0)))])
        let encoded = try JSONEncoder().encode(request)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for period in [request.day, request.week] + request.periods {
            let data = try JSONEncoder().encode(period)
            let value = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(value["completedDurationSeconds"] as? Double, 60)
            let types = try XCTUnwrap(value["types"] as? [[String: Any]])
            XCTAssertEqual(types.first?["completedDurationSeconds"] as? Double, 60)
        }
        // A failed request saved by the previous app may still contain fractional seconds.
        var day = try XCTUnwrap(json["day"] as? [String: Any])
        day["completedDurationSeconds"] = 60.75
        json["day"] = day
        let cached = try JSONDecoder().decode(InsightSummaryRequest.self,
            from: JSONSerialization.data(withJSONObject: json))
        let retry = try JSONEncoder().encode(cached)
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: retry) as? [String: Any])
        XCTAssertEqual((wire["day"] as? [String: Any])?["completedDurationSeconds"] as? Double, 60)
        XCTAssertEqual(session.duration, 60.75)
    }

    func testGenerationFailureAllowsExplicitRetryAfterRelaunch() async throws {
        var calls = 0
        let client = InsightAPIClient(transport: { req in
            calls += 1
            return (Data(#"{"error":{"code":"generation_failed"}}"#.utf8), self.http(req, 502))
        }, readToken: { .init(owner: "owner", accessToken: "token", expiresAt: self.date(12)) },
            writeToken: { _ in }, clock: { self.date(11) })
        let service = DailyInsightSummary(client: client, identity: { "owner" })
        await service.load(input())?.value
        XCTAssertTrue(service.canRetry)
        XCTAssertTrue(service.message?.contains("重试") == true)
        await service.load(input(), retry: true)?.value
        let restarted = DailyInsightSummary(client: client, identity: { "owner" })
        await restarted.load(input())?.value
        XCTAssertTrue(restarted.canRetry)
        await restarted.load(input(), retry: true)?.value
        let directRetry = DailyInsightSummary(client: client, identity: { "owner" })
        await directRetry.load(input(), retry: true)?.value
        XCTAssertTrue(directRetry.canRetry)
        XCTAssertEqual(calls, 5)
    }

    func testCustomRangeBeyondBackendLimitKeepsLocalCopy() {
        let now = date(11)
        let today = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -366, to: today)!
        let ranges = InsightRange.custom.summaryRanges(calendar: calendar, now: now,
            customStart: start, customEnd: now)
        XCTAssertEqual(ranges.map(\.0), ["recent_three_days", "recent_month"])
        let allowed = InsightRange.custom.summaryRanges(calendar: calendar, now: now,
            customStart: calendar.date(byAdding: .day, value: -365, to: today)!, customEnd: now)
        XCTAssertTrue(allowed.contains { $0.0 == "custom" })
    }

    func testResponseValidationRejectsWrongDateAndLongCopy() throws {
        let request = input()
        let response = result(request)
        try response.validate(for: request)
        XCTAssertThrowsError(try response.validate(for: input(day: 12)))
        XCTAssertFalse(InsightCopy(title: String(repeating: "长", count: 9), body: "正文", style: Self.style).isValid)
    }

    func testSyntheticV2ResponseAndLowercasePeriodIdentifiers() throws {
        let ranges = InsightRange.thisWeek.summaryRanges(calendar: calendar, now: date(11),
            customStart: date(9), customEnd: date(11))
        let request = InsightSummaryRequest.make(sessions: [], places: [], calendar: calendar,
            now: date(11), additional: ranges)
        XCTAssertEqual(request.periods.compactMap(\.id), ["recent_three_days", "recent_month"])
        let historical = InsightRange.custom.summaryRanges(calendar: calendar, now: date(11),
            customStart: date(1), customEnd: date(5))
        XCTAssertFalse(historical.contains { $0.0 == "custom" })
        let response = try JSONDecoder().decode(InsightSummaryResponse.self, from: Data(Self.rangeMockResponse.utf8))
        try response.validate(for: request)

    }

    // Synthetic range fixture adapted to V2; not a live response.
    private static let rangeMockResponse = #"""
    {
      "schemaVersion": 2,
      "summaryDate": "2026-09-11",
      "generatedAt": "2026-09-11T02:11:41+08:00",
      "dataAsOf": "2026-09-11T02:11:41+08:00",
      "day": {
        "date": "2026-09-11",
        "copy": {
          "title": "今天的时间片段",
          "body": "看见此刻，也留点余地。",
          "style": {
            "backgroundStyle": "linearGradient",
            "palette": "warm",
            "backgroundStart": "#FFF7ED",
            "backgroundEnd": "#F3E8D8",
            "textColor": "#352B25",
            "secondaryTextColor": "#665348",
            "accentColor": "#875137"
          }
        },
        "types": [
          {
            "type": "work",
            "copy": {
              "title": "工作的一小时",
              "body": "记下就好，不必苛求。",
              "style": {
                "backgroundStyle": "linearGradient",
                "palette": "warm",
                "backgroundStart": "#FFF7ED",
                "backgroundEnd": "#F3E8D8",
                "textColor": "#352B25",
                "secondaryTextColor": "#665348",
                "accentColor": "#875137"
              }
            }
          },
          {
            "type": "exercise",
            "copy": {
              "title": "运动的半小时",
              "body": "给身体留一点位置。",
              "style": {
                "backgroundStyle": "linearGradient",
                "palette": "warm",
                "backgroundStart": "#FFF7ED",
                "backgroundEnd": "#F3E8D8",
                "textColor": "#352B25",
                "secondaryTextColor": "#665348",
                "accentColor": "#875137"
              }
            }
          }
        ]
      },
      "week": {
        "startDate": "2026-09-07",
        "endDateExclusive": "2026-09-14",
        "copy": {
          "title": "本周的已记录",
          "body": "本周还在展开，慢慢来。",
          "style": {
            "backgroundStyle": "linearGradient",
            "palette": "warm",
            "backgroundStart": "#FFF7ED",
            "backgroundEnd": "#F3E8D8",
            "textColor": "#352B25",
            "secondaryTextColor": "#665348",
            "accentColor": "#875137"
          }
        },
        "types": [
          {
            "type": "work",
            "copy": {
              "title": "本周工作片段",
              "body": "一周很长，片段有限。",
              "style": {
                "backgroundStyle": "linearGradient",
                "palette": "warm",
                "backgroundStart": "#FFF7ED",
                "backgroundEnd": "#F3E8D8",
                "textColor": "#352B25",
                "secondaryTextColor": "#665348",
                "accentColor": "#875137"
              }
            }
          },
          {
            "type": "exercise",
            "copy": {
              "title": "本周运动片段",
              "body": "动过就值得记下。",
              "style": {
                "backgroundStyle": "linearGradient",
                "palette": "warm",
                "backgroundStart": "#FFF7ED",
                "backgroundEnd": "#F3E8D8",
                "textColor": "#352B25",
                "secondaryTextColor": "#665348",
                "accentColor": "#875137"
              }
            }
          }
        ]
      },
      "periods": [
        {
          "id": "recent_three_days",
          "kind": "range",
          "startDate": "2026-09-09",
          "endDateExclusive": "2026-09-12",
          "copy": {
            "title": "近三天记录",
            "body": "范围未满，先看到这里。",
            "style": {
              "backgroundStyle": "linearGradient",
              "palette": "warm",
              "backgroundStart": "#FFF7ED",
              "backgroundEnd": "#F3E8D8",
              "textColor": "#352B25",
              "secondaryTextColor": "#665348",
              "accentColor": "#875137"
            }
          },
          "types": [
            {
              "type": "work",
              "copy": {
                "title": "近三天工作",
                "body": "记录是片段，不是全部。",
                "style": {
                  "backgroundStyle": "linearGradient",
                  "palette": "warm",
                  "backgroundStart": "#FFF7ED",
                  "backgroundEnd": "#F3E8D8",
                  "textColor": "#352B25",
                  "secondaryTextColor": "#665348",
                  "accentColor": "#875137"
                }
              }
            },
            {
              "type": "exercise",
              "copy": {
                "title": "近三天运动",
                "body": "动过的片刻也在。",
                "style": {
                  "backgroundStyle": "linearGradient",
                  "palette": "warm",
                  "backgroundStart": "#FFF7ED",
                  "backgroundEnd": "#F3E8D8",
                  "textColor": "#352B25",
                  "secondaryTextColor": "#665348",
                  "accentColor": "#875137"
                }
              }
            }
          ]
        },
        {
          "id": "recent_month",
          "kind": "range",
          "startDate": "2026-08-13",
          "endDateExclusive": "2026-09-12",
          "copy": {
            "title": "近一个月记录",
            "body": "月还没走完，留白也正常。",
            "style": {
              "backgroundStyle": "linearGradient",
              "palette": "warm",
              "backgroundStart": "#FFF7ED",
              "backgroundEnd": "#F3E8D8",
              "textColor": "#352B25",
              "secondaryTextColor": "#665348",
              "accentColor": "#875137"
            }
          },
          "types": [
            {
              "type": "work",
              "copy": {
                "title": "近一个月工作",
                "body": "把它当作一枚书签。",
                "style": {
                  "backgroundStyle": "linearGradient",
                  "palette": "warm",
                  "backgroundStart": "#FFF7ED",
                  "backgroundEnd": "#F3E8D8",
                  "textColor": "#352B25",
                  "secondaryTextColor": "#665348",
                  "accentColor": "#875137"
                }
              }
            },
            {
              "type": "exercise",
              "copy": {
                "title": "近一个月运动",
                "body": "这小段也值得被看见。",
                "style": {
                  "backgroundStyle": "linearGradient",
                  "palette": "warm",
                  "backgroundStart": "#FFF7ED",
                  "backgroundEnd": "#F3E8D8",
                  "textColor": "#352B25",
                  "secondaryTextColor": "#665348",
                  "accentColor": "#875137"
                }
              }
            }
          ]
        }
      ]
    }
    """#

    func testTokenReuseRefreshAfter401AndRequestContract() async throws {
        let request = input()
        let data = try JSONEncoder().encode(result(request))
        var token: InsightToken? = .init(owner: "owner", accessToken: "old", expiresAt: date(12))
        var paths: [String] = []
        var llmCount = 0
        let client = InsightAPIClient(transport: { req in
            paths.append(req.url!.path)
            if req.url!.path == "/v1/auth/cloudkit" {
                let body = try JSONSerialization.jsonObject(with: req.httpBody!) as! [String: String]
                XCTAssertEqual(body["userRecordName"], "owner")
                return (Data("{\"accessToken\":\"new\",\"expiresIn\":86400}".utf8), self.http(req))
            }
            llmCount += 1
            XCTAssertEqual(req.value(forHTTPHeaderField: "Idempotency-Key"), "insights-2026-09-11")
            XCTAssertEqual(try JSONSerialization.jsonObject(with: req.httpBody!) as? NSDictionary,
                           try JSONSerialization.jsonObject(with: JSONEncoder().encode(request)) as? NSDictionary)
            XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), llmCount == 1 ? "Bearer old" : "Bearer new")
            return (data, self.http(req, llmCount == 1 ? 401 : 200))
        }, readToken: { token }, writeToken: { token = $0 }, clock: { self.date(11) })
        var attempts = 0
        _ = try await client.generate(request, owner: "owner") { attempts += 1 }
        XCTAssertEqual(paths, ["/v1/llm", "/v1/auth/cloudkit", "/v1/llm"])
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(token?.expiresAt, date(12))
    }

    func testExpiredOrOtherAccountTokenAuthenticatesFirst() async throws {
        for stored in [InsightToken(owner: "owner", accessToken: "expired", expiresAt: date(10)),
                       InsightToken(owner: "other", accessToken: "private", expiresAt: date(12))] {
            var token: InsightToken? = stored
            var paths: [String] = []
            let request = input()
            let client = InsightAPIClient(transport: { req in
                paths.append(req.url!.path)
                let data = req.url!.path.contains("auth")
                    ? Data("{\"accessToken\":\"new\",\"expiresIn\":86400}".utf8)
                    : try JSONEncoder().encode(self.result(request))
                return (data, self.http(req))
            }, readToken: { token }, writeToken: { token = $0 }, clock: { self.date(11) })
            _ = try await client.generate(request, owner: "owner", willSend: {})
            XCTAssertEqual(paths, ["/v1/auth/cloudkit", "/v1/llm"])
            XCTAssertEqual(token?.owner, "owner")
        }
    }

    func testSecond401StopsAnd409PollingHonorsRetryAfter() async throws {
        var count = 0
        var waits: [Double] = []
        let request = input()
        let client = InsightAPIClient(transport: { req in
            count += 1
            return (try JSONEncoder().encode(self.result(request)), self.http(req, count < 3 ? 409 : 200,
                headers: ["Retry-After": "2"]))
        }, readToken: { .init(owner: "owner", accessToken: "token", expiresAt: self.date(12)) },
            writeToken: { _ in }, clock: { self.date(11) }, wait: { waits.append($0) })
        _ = try await client.generate(request, owner: "owner", willSend: {})
        XCTAssertEqual(count, 3)
        XCTAssertEqual(waits, [2, 2])
        var authCount = 0
        var llmCount = 0
        let rejecting = InsightAPIClient(transport: { req in
            if req.url!.path.contains("auth") {
                authCount += 1
                return (Data("{\"accessToken\":\"token\",\"expiresIn\":86400}".utf8), self.http(req))
            }
            llmCount += 1
            return (Data(), self.http(req, 401))
        }, readToken: { nil }, writeToken: { _ in }, clock: { self.date(11) })
        do {
            _ = try await rejecting.generate(request, owner: "owner", willSend: {})
            XCTFail("Expected rejection")
        } catch { XCTAssertEqual((error as? InsightAPIError)?.status, 401) }
        XCTAssertEqual(llmCount, 2)
        XCTAssertEqual(authCount, 2)
    }

    func testInvalidResponseAndServerFailureDoNotRetryGeneration() async throws {
        for status in [200, 400, 429, 502, 503] {
            var calls = 0
            let client = InsightAPIClient(transport: { req in
                calls += 1
                return (Data("{\"error\":{\"code\":\"invalid_request\"}}".utf8), self.http(req, status))
            }, readToken: { .init(owner: "owner", accessToken: "token", expiresAt: self.date(12)) },
                writeToken: { _ in }, clock: { self.date(11) })
            do {
                _ = try await client.generate(input(), owner: "owner", willSend: {})
                XCTFail("Malformed response must not become a summary")
            } catch { XCTAssertEqual(calls, 1) }
        }
    }

    func testAppThemeTextContrastInBothAppearances() {
        func luminance(_ rgb: UInt32) -> Double {
            let components = [Double((rgb >> 16) & 255), Double((rgb >> 8) & 255), Double(rgb & 255)]
                .map { value -> Double in
                    let v = value / 255
                    return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
                }
            return components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
        }
        for theme in AppTheme.allCases {
            for colors in [theme.lightColors, theme.darkColors] {
                for background in [colors[0], colors[1]] {
                    for foreground in [colors[2], colors[3], colors[4]] {
                        let a = luminance(background), b = luminance(foreground)
                        XCTAssertGreaterThanOrEqual((max(a, b) + 0.05) / (min(a, b) + 0.05), 4.5,
                                                   "\(theme.rawValue) text must remain readable")
                    }
                }
            }
        }
    }

    func testGeneratedCopyRendersInCardAndPoster() throws {
        let journal = TimeJournalService().make(sessions: [], places: [],
            interval: DateInterval(start: date(7, 0), end: date(14, 0)),
            previous: DateInterval(start: date(1, 0), end: date(7, 0)),
            filter: .all, calendar: calendar, now: date(11))
        let copy = InsightCopy(title: "日子有自己的步调", body: String(repeating: "生活", count: 12), style: Self.style)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("insight-api-visuals")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let poster = try JournalPosterRenderer.png(journal: journal,
            insightCopy: PeriodInsightCopy(factID: "fixture", title: copy.title, body: copy.body), showPlaceName: false)
        let image = try XCTUnwrap(UIImage(data: poster)?.cgImage)
        XCTAssertEqual(image.width, 1080)
        XCTAssertEqual(image.height, 1920)
        try poster.write(to: directory.appendingPathComponent("poster.png"))
        var priorTheme: Data?
        for theme in AppTheme.allCases {
            let themed = try JournalPosterRenderer.png(journal: journal,
                insightCopy: PeriodInsightCopy(factID: "fixture", title: "日子的叠句",
                    body: "相似的段落再次落笔，回看时，日子便有了韵脚。"), showPlaceName: false, theme: theme)
            let bitmap = try XCTUnwrap(UIImage(data: themed)?.cgImage)
            XCTAssertEqual(bitmap.width, 1080)
            XCTAssertEqual(bitmap.height, 1920)
            if let priorTheme { XCTAssertNotEqual(themed, priorTheme, "Theme must change the exported image") }
            priorTheme = themed
            try themed.write(to: directory.appendingPathComponent("theme-" + theme.rawValue + ".png"))
            let card = ImageRenderer(content: PeriodInsightCard(journal: journal, copy: PeriodInsightCopy(factID: "fixture", title: copy.title, body: copy.body)) {}
                .environment(\.timeTraceDesign, TimeTraceDesign(theme: theme))
                .frame(width: 320).environment(\.colorScheme, .dark)
                .environment(\.dynamicTypeSize, .accessibility3))
            card.scale = 2
            try XCTUnwrap(card.uiImage?.pngData()).write(to: directory.appendingPathComponent("theme-" + theme.rawValue + "-large.png"))
        }
        print("Insight visual fixtures: \(directory.path)")
    }

    func testRelaunchRequestsAgainAfterSuccessOrFailure() async throws {
        let request = input()
        var calls = 0
        let client = InsightAPIClient(transport: { req in
            calls += 1
            if calls == 2 { throw URLError(.timedOut) }
            return (try JSONEncoder().encode(self.result(request)), self.http(req))
        }, readToken: { .init(owner: "owner", accessToken: "token", expiresAt: self.date(12)) },
            writeToken: { _ in }, clock: { self.date(11) })
        let first = DailyInsightSummary(client: client, identity: { "owner" })
        await first.load(request)?.value
        XCTAssertNotNil(first.response)
        await first.load(request)?.value
        XCTAssertEqual(calls, 1)

        let second = DailyInsightSummary(client: client, identity: { "owner" })
        await second.load(request)?.value
        XCTAssertEqual(calls, 2)
        XCTAssertTrue(second.canRetry)

        let third = DailyInsightSummary(client: client, identity: { "owner" })
        await third.load(request)?.value
        XCTAssertEqual(calls, 3)
        XCTAssertNotNil(third.response)
    }

    func testIdentityFailureCanRetryWithoutRestart() async throws {
        let request = input()
        var attempts = 0
        let client = InsightAPIClient(transport: { req in
            (try JSONEncoder().encode(self.result(request)), self.http(req))
        }, readToken: { .init(owner: "owner", accessToken: "token", expiresAt: self.date(12)) },
            writeToken: { _ in }, clock: { self.date(11) })
        let service = DailyInsightSummary(client: client, identity: {
            attempts += 1
            if attempts == 1 { throw URLError(.notConnectedToInternet) }
            return "owner"
        })
        await service.load(request)?.value
        XCTAssertTrue(service.canRetry)
        XCTAssertTrue(service.message?.contains("网络") == true)
        await service.load(request, retry: true)?.value
        XCTAssertNotNil(service.response)
        XCTAssertEqual(attempts, 2)
    }

    func testSessionDeduplicationRetryAndAccountIsolation() async throws {
        var owner = "one"
        var token: InsightToken?
        var llmCount = 0
        var shouldFail = false
        var current = input()
        let client = InsightAPIClient(transport: { req in
            if req.url!.path.contains("auth") {
                return (Data("{\"accessToken\":\"token\",\"expiresIn\":86400}".utf8), self.http(req))
            }
            llmCount += 1
            if shouldFail { throw URLError(.timedOut) }
            return (try JSONEncoder().encode(self.result(current)), self.http(req))
        }, readToken: { token }, writeToken: { token = $0 }, clock: { self.date(11) })
        let service = DailyInsightSummary(client: client, identity: { owner })
        let first = service.load(current)
        let concurrent = service.load(current)
        await first?.value
        await concurrent?.value
        XCTAssertEqual(llmCount, 1)
        XCTAssertNotNil(service.response)
        let relaunched = DailyInsightSummary(client: client, identity: { owner })
        await relaunched.load(current)?.value
        XCTAssertEqual(llmCount, 2)
        XCTAssertEqual(relaunched.response, service.response)
        current = input(day: 12)
        shouldFail = true
        await service.load(current)?.value
        XCTAssertEqual(llmCount, 3)
        XCTAssertNil(service.response)
        let afterFailure = DailyInsightSummary(client: client, identity: { owner })
        await afterFailure.load(current)?.value
        XCTAssertEqual(llmCount, 4)
        XCTAssertNil(afterFailure.response)
        shouldFail = false
        await afterFailure.load(current, retry: true)?.value
        XCTAssertEqual(llmCount, 5)
        XCTAssertNotNil(afterFailure.response)
        owner = "two"
        shouldFail = false
        service.resetIdentity()
        await service.load(current)?.value
        XCTAssertEqual(llmCount, 6)
        XCTAssertNotNil(service.response)
    }
}

@MainActor
final class ThemeIconTests: XCTestCase {
    func testOptOutNeverChangesIconAndClearsPreviousFailure() async {
        var requests = 0
        let controller = ThemeIconController(supportsIcons: { true }, currentIcon: { "AppIconSky" },
            setIcon: { _ in
                requests += 1
                throw NSError(domain: "IconTest", code: 1)
            })
        XCTAssertNil(controller.updateIcon(for: .rose, followsTheme: false))
        XCTAssertEqual(requests, 0)
        await controller.updateIcon(for: .rose, followsTheme: true)?.value
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertNil(controller.updateIcon(for: .paper, followsTheme: false))
        XCTAssertEqual(requests, 1)
        XCTAssertNil(controller.errorMessage)
        XCTAssertFalse(controller.isUpdating)
    }

    func testEveryThemeIconIsPackagedInTheApplication() throws {
        let icons = try XCTUnwrap(Bundle.main.infoDictionary?["CFBundleIcons"] as? [String: Any])
        let alternates = try XCTUnwrap(icons["CFBundleAlternateIcons"] as? [String: Any])
        XCTAssertNotNil(icons["CFBundlePrimaryIcon"])
        XCTAssertNil(AppTheme.paper.alternateIconName)
        for theme in AppTheme.allCases where theme != .paper {
            let name = try XCTUnwrap(theme.alternateIconName)
            XCTAssertNotNil(alternates[name], "Missing bundled icon for \(theme)")
        }
    }

    func testRepeatedSelectionDoesNotAskSystemToChangeIconAgain() {
        var requested = false
        let controller = ThemeIconController(supportsIcons: { true },
            currentIcon: { AppTheme.sky.alternateIconName }, setIcon: { _ in requested = true })
        XCTAssertNil(controller.updateIcon(for: .sky, followsTheme: true))
        XCTAssertFalse(requested)
        XCTAssertFalse(controller.isUpdating)
    }

    func testFailureCanBeRetriedAndReturningToPaperRequestsPrimaryIcon() async {
        var requests: [String?] = []
        let controller = ThemeIconController(supportsIcons: { true }, currentIcon: { "AppIconSky" },
            setIcon: { name in
                requests.append(name)
                if requests.count == 1 { throw NSError(domain: "IconTest", code: 1) }
            })
        let first = controller.updateIcon(for: .paper, followsTheme: true)
        XCTAssertTrue(controller.isUpdating)
        XCTAssertNil(controller.updateIcon(for: .rose, followsTheme: true))
        await first?.value
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(controller.isUpdating)
        await controller.updateIcon(for: .paper, followsTheme: true)?.value
        XCTAssertNil(controller.errorMessage)
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0 == nil })
    }

    func testUnsupportedDeviceShowsFailureWithoutRequestingIconChange() {
        var requested = false
        let controller = ThemeIconController(supportsIcons: { false }, currentIcon: { nil },
            setIcon: { _ in requested = true })
        XCTAssertNil(controller.updateIcon(for: .sage, followsTheme: true))
        XCTAssertNotNil(controller.errorMessage)
        XCTAssertFalse(requested)
        XCTAssertFalse(controller.isUpdating)
    }
}
