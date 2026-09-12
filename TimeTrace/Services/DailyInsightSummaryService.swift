import CloudKit
import Combine
import Foundation
import OSLog

@MainActor
final class DailyInsightSummary: ObservableObject {
    @Published private(set) var response: InsightSummaryResponse?
    @Published private(set) var canRetry = false
    @Published private(set) var isLoading = false
    @Published private(set) var message: String?
    @Published private(set) var identityRevision = 0
    @Published private(set) var savedTip: SavedDailyTip?
    private var localCare: SavedDailyTip?
    private let defaults: UserDefaults
    private var tipOwner: String?
    private var latestInput: InsightSummaryRequest?
    private var responseTimezone: String?
    private var task: Task<Void, Never>?
    private var lastAttempt: String?
    private let client: InsightAPIClient
    private let identity: () async throws -> String
    private var accountObservation: AnyCancellable?

    init(client: InsightAPIClient? = nil, defaults: UserDefaults = .standard,
         identity: @escaping () async throws -> String = {
             try await CKContainer.default().userRecordID().recordName
         }) {
        self.defaults = defaults
        self.client = client ?? InsightAPIClient()
        self.identity = identity
        accountObservation = NotificationCenter.default.publisher(for: .CKAccountChanged)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in self?.resetIdentity() }
            }
    }

    func resetIdentity() {
        if let tipOwner { defaults.removeObject(forKey: tipOwner) }
        tipOwner = nil
        savedTip = nil
        latestInput = nil
        localCare = nil
        task?.cancel()
        task = nil
        identityRevision += 1
        client.resetIdentity()
        response = nil
        responseTimezone = nil
        message = nil
        isLoading = false
        lastAttempt = nil
        canRetry = false
    }

    /// Period copy stays in memory; only the daily care line is persisted by verified account.
    /// The task belongs to the feature, so tab switches cannot cancel a spent generation.
    @discardableResult
    func load(_ input: InsightSummaryRequest, retry: Bool = false) -> Task<Void, Never>? {
        latestInput = input
        if localCare?.matches(input) != true {
            localCare = SavedDailyTip(date: input.date, timezone: input.timezone,
                text: input.localTip, sources: input.tipSources)
        }
        if let savedTip, !savedTip.matches(input) {
            self.savedTip = nil
            if let tipOwner { defaults.removeObject(forKey: tipOwner) }
        }
        let context = input.date + "|" + input.timezone
        guard task == nil else { return task }
        guard lastAttempt != context || (retry && canRetry) else { return nil }
        canRetry = false
        lastAttempt = context
        response = nil
        responseTimezone = nil
        message = nil
        isLoading = true
        let revision = identityRevision
        task = Task { [weak self] in
            guard let self else { return }
            defer {
                if revision == identityRevision { isLoading = false; task = nil }
            }
            let attempt = input
            var stage = "identity"
            do {
                let owner = try await identity()
                try Task.checkCancellation()
                guard revision == identityRevision else { return }
                let key = "TimeTrace.dailyCare." + TimeJournal.fingerprint(owner)
                if let previousOwner = tipOwner, previousOwner != key {
                    defaults.removeObject(forKey: previousOwner)
                    savedTip = nil
                }
                tipOwner = key
                if let data = defaults.data(forKey: key),
                   let saved = try? JSONDecoder().decode(SavedDailyTip.self, from: data),
                   saved.matches(latestInput ?? attempt) {
                    savedTip = saved
                } else {
                    defaults.removeObject(forKey: key)
                }
                stage = "authentication-or-generation"
                let result = try await client.generate(attempt, owner: owner) {
                    guard revision == self.identityRevision else { throw CancellationError() }
                    stage = "generation"
                }
                try Task.checkCancellation()
                guard revision == identityRevision else { return }
                response = result
                responseTimezone = attempt.timezone
                if savedTip?.generated != true, let tip = result.dailyTip,
                   tip.isValid, tip.date == attempt.date, tip.sourceID == attempt.recentSourceID {
                    let saved = SavedDailyTip(date: attempt.date, timezone: attempt.timezone,
                        text: tip.text, sources: attempt.tipSources, generated: true)
                    if saved.matches(latestInput ?? attempt) {
                        savedTip = saved
                        defaults.set(try? JSONEncoder().encode(saved), forKey: key)
                    }
                }
                saveLocalCareIfNeeded()
            } catch is CancellationError {
                // Identity changes must not restore another account's text or token.
            } catch {
                guard revision == identityRevision else { return }
                saveLocalCareIfNeeded()
                canRetry = true
                message = Self.failureMessage(error)
                // Log only stage, status and allowlisted code; never identity, tokens or response bodies.
                let status = (error as? InsightAPIError)?.status ?? (error as NSError).code
                let code = (error as? InsightAPIError)?.diagnosticCode ?? "CLIENT_ERROR"
                Logger(subsystem: "com.chronora.time.trace", category: "InsightSummary")
                    .error("Request failed at \(stage, privacy: .public), status \(status), code \(code, privacy: .public)")
            }
        }
        return task
    }

    private static func failureMessage(_ error: Error) -> String {
        let reason: String
        if let error = error as? URLError {
            reason = error.code == .timedOut ? "智能手记请求超时" : "无法连接智能手记服务，请检查网络"
        } else if let error = error as? CKError {
            reason = error.code == .notAuthenticated ? "请先在系统设置登录 iCloud" : "暂时无法获取 iCloud 身份"
        } else if let error = error as? InsightAPIError {
            if error.status == 502 && error.code.uppercased() == "GENERATION_FAILED" {
                return "智能手记生成失败，可稍后重试。当前显示本地文案。"
            }
            switch error.status {
            case 401, 403: reason = "智能手记身份验证失败"
            case 409: reason = "智能手记尚未完成，请稍后重试"
            case 429: reason = "智能手记请求已达服务限制，请稍后重试"
            case 500...599: reason = "智能手记服务暂时异常"
            case 0: reason = "智能手记返回内容校验失败"
            default: reason = "智能手记请求被服务拒绝（\(error.status)）"
            }
        } else if error is DecodingError {
            reason = "智能手记返回格式无法解析"
        } else {
            reason = "智能手记暂不可用"
        }
        return reason + "。当前显示本地文案。"
    }

    private func saveLocalCareIfNeeded() {
        guard savedTip == nil, let tipOwner, let localCare, let latestInput,
              localCare.matches(latestInput) else { return }
        savedTip = localCare
        defaults.set(try? JSONEncoder().encode(localCare), forKey: tipOwner)
    }

    func tip(for input: InsightSummaryRequest) -> String {
        if let savedTip, savedTip.matches(input) { return savedTip.text }
        if let localCare, localCare.matches(input) { return localCare.text }
        return input.localTip
    }

    func insight(journal: TimeJournal, type: PlaceType?, now: Date) -> PeriodInsightCopy? {
        guard responseTimezone == journal.calendar.timeZone.identifier,
              response?.summaryDate == InsightSummaryRequest.dateString(now, calendar: journal.calendar) else { return nil }
        return response?.insight(journal: journal, type: type)
    }

    var dataAsOf: Date? { response.flatMap { InsightSummaryRequest.parseTimestamp($0.dataAsOf) } }

}


struct SavedDailyTip: Codable, Equatable {
    let date: String
    let timezone: String
    let text: String
    let sources: [String: String]
    var generated = false

    func matches(_ input: InsightSummaryRequest) -> Bool {
        guard date == input.date, timezone == input.timezone,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.unicodeScalars.count <= 40 else { return false }
        // New records do not rotate today's line; edited or removed evidence invalidates it.
        // An empty-data tip is no longer applicable once the first record appears.
        if sources.isEmpty { return input.tipSources.isEmpty }
        return sources.allSatisfy { input.tipSources[$0.key] == $0.value }
    }
}
