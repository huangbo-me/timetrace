import CloudKit
import Foundation
import Security

struct InsightAPIError: Error {
    let status: Int
    let code: String
    let retryAfter: TimeInterval?
    /// Only documented codes are safe to expose; never log arbitrary server text.
    var diagnosticCode: String {
        let allowed: Set<String> = ["INVALID_REQUEST", "UNAUTHORIZED", "GENERATION_IN_PROGRESS",
            "RATE_LIMITED", "GENERATION_FAILED", "SERVICE_UNAVAILABLE", "INVALID_RESPONSE", "HTTP_ERROR"]
        return allowed.contains(code) ? code : "HTTP_ERROR"
    }
    static let invalidResponse = Self(status: 0, code: "INVALID_RESPONSE", retryAfter: nil)
}

struct InsightToken: Codable {
    let owner: String
    let accessToken: String
    let expiresAt: Date
}

/// Tokens are never stored in preferences, backups or logs.
struct InsightTokenKeychain {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "TimeTrace.InsightAPI",
         kSecAttrAccount as String: "accessToken"]
    }
    func read() -> InsightToken? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return try? JSONDecoder().decode(InsightToken.self, from: data)
    }
    func write(_ token: InsightToken?) throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw NSError(domain: NSOSStatusErrorDomain, code: Int(status))
        }
        guard let token else { return }
        var query = query
        query[kSecValueData as String] = try JSONEncoder().encode(token)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let added = SecItemAdd(query as CFDictionary, nil)
        guard added == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(added)) }
    }
}

@MainActor
final class InsightAPIClient {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let transport: Transport
    private let readToken: () -> InsightToken?
    private let writeToken: (InsightToken?) throws -> Void
    private let clock: () -> Date
    private let wait: (TimeInterval) async throws -> Void
    private let baseURL: URL
    private var revision = 0

    init(baseURL: URL = URL(string: "https://api.fzbanglian.cn")!,
         transport: @escaping Transport = { request in
             let (data, response) = try await URLSession.shared.data(for: request)
             guard let response = response as? HTTPURLResponse else { throw InsightAPIError.invalidResponse }
             return (data, response)
         }, readToken: @escaping () -> InsightToken? = { InsightTokenKeychain().read() },
         writeToken: @escaping (InsightToken?) throws -> Void = { try InsightTokenKeychain().write($0) },
         clock: @escaping () -> Date = Date.init,
         wait: @escaping (TimeInterval) async throws -> Void = {
             try await Task.sleep(for: .seconds($0))
         }) {
        self.baseURL = baseURL
        self.transport = transport
        self.readToken = readToken
        self.writeToken = writeToken
        self.clock = clock
        self.wait = wait
    }

    func resetIdentity() {
        revision += 1
        try? writeToken(nil)
    }

    private func token(owner: String, force: Bool) async throws -> String {
        if !force, let token = readToken(), token.owner == owner,
           token.expiresAt.timeIntervalSince(clock()) > 60 { return token.accessToken }
        struct AuthRequest: Encodable { let userRecordName: String }
        struct AuthResponse: Decodable { let accessToken: String; let expiresIn: Double }
        let currentRevision = revision
        let started = clock()
        let request = try makeRequest(path: "v1/auth/cloudkit", body: AuthRequest(userRecordName: owner))
        let (data, response) = try await transport(request)
        try check(response, data: data)
        let auth = try JSONDecoder().decode(AuthResponse.self, from: data)
        guard !auth.accessToken.isEmpty, auth.expiresIn.isFinite, auth.expiresIn > 0 else {
            throw InsightAPIError.invalidResponse
        }
        try Task.checkCancellation()
        guard currentRevision == revision else { throw CancellationError() }
        try writeToken(InsightToken(owner: owner, accessToken: auth.accessToken,
            expiresAt: started.addingTimeInterval(min(auth.expiresIn, 86_400))))
        return auth.accessToken
    }

    func generate(_ input: InsightSummaryRequest, owner: String,
                  willSend: () throws -> Void) async throws -> InsightSummaryResponse {
        var accessToken = try await token(owner: owner, force: false)
        try Task.checkCancellation()
        try willSend()
        var refreshed = false
        var polls = 0
        while true {
            try Task.checkCancellation()
            var request = try makeRequest(path: "v1/llm", body: input)
            request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
            request.setValue("insights-\(input.date)", forHTTPHeaderField: "Idempotency-Key")
            let (data, response) = try await transport(request)
            try Task.checkCancellation()
            if response.statusCode == 401, !refreshed {
                refreshed = true
                try writeToken(nil)
                accessToken = try await token(owner: owner, force: true)
                continue
            }
            if response.statusCode == 409, polls < 2,
               let delay = retryDelay(response), delay <= 30 {
                polls += 1
                try await wait(max(1, delay))
                continue
            }
            try check(response, data: data)
            let result = try JSONDecoder().decode(InsightSummaryResponse.self, from: data)
            try result.validate(for: input)
            return result
        }
    }

    private func makeRequest<T: Encodable>(path: String, body: T) throws -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(body)
        return request
    }

    private func retryDelay(_ response: HTTPURLResponse) -> TimeInterval? {
        guard let value = response.value(forHTTPHeaderField: "Retry-After") else { return nil }
        if let seconds = Double(value), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss z"
        return formatter.date(from: value).map { max(0, $0.timeIntervalSince(clock())) }
    }

    private func check(_ response: HTTPURLResponse, data: Data) throws {
        guard (200..<300).contains(response.statusCode) else {
            struct Envelope: Decodable {
                struct Failure: Decodable { let code: String }
                let error: Failure
            }
            let code = (try? JSONDecoder().decode(Envelope.self, from: data).error.code) ?? "HTTP_ERROR"
            throw InsightAPIError(status: response.statusCode, code: code.uppercased(), retryAfter: retryDelay(response))
        }
    }
}
