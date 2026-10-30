import Foundation
@testable import UsageCore

enum Fixtures {
    // 실제 /api/oauth/usage 응답에서 식별 정보 없는 필드만 추렸다.
    static let claudeUsage = Data(#"""
    {
      "five_hour": {"utilization": 2.0, "resets_at": "2026-10-30T13:00:00.353544+00:00", "locked_reason": null},
      "seven_day": {"utilization": 49.0, "resets_at": "2026-11-04T00:00:00.353562+00:00", "locked_reason": null},
      "seven_day_opus": null,
      "seven_day_sonnet": null,
      "limits": [
        {"kind": "session", "group": "session", "percent": 2, "resets_at": "2026-10-30T13:00:00.353544+00:00", "scope": null},
        {"kind": "weekly_all", "group": "weekly", "percent": 49, "resets_at": "2026-11-04T00:00:00.353562+00:00", "scope": null},
        {"kind": "weekly_scoped", "group": "weekly", "percent": 7, "resets_at": "2026-11-04T00:00:00+00:00",
         "scope": {"model": {"id": null, "display_name": "Fable"}, "surface": null}}
      ]
    }
    """#.utf8)

    // 실제 codex app-server account/rateLimits/read 결과 구조.
    static let codexRateLimits = Data(#"""
    {
      "ordinaryUsageAllowed": true,
      "rateLimits": {
        "limitId": "codex", "limitName": null,
        "primary": {"usedPercent": 94, "windowDurationMins": 10080, "resetsAt": 1793775077},
        "secondary": null,
        "credits": {"hasCredits": true, "unlimited": false, "balance": "2656.0832755000"},
        "planType": "pro"
      },
      "rateLimitsByLimitId": {
        "codex": {
          "limitId": "codex", "limitName": null,
          "primary": {"usedPercent": 94, "windowDurationMins": 10080, "resetsAt": 1793775077},
          "secondary": null
        }
      }
    }
    """#.utf8)

    static let deepseekBalance = Data(#"""
    {
      "is_available": true,
      "balance_infos": [
        {"currency": "CNY", "total_balance": "110.00", "granted_balance": "10.00", "topped_up_balance": "100.00"}
      ]
    }
    """#.utf8)

    static func claudeCredentialJSON(
        token: String = "tok",
        expiresAt: Double? = 0,
        refreshExpiresAt: Double? = nil,
        refreshToken: String? = "refresh",
        subscription: String? = "max",
        tier: String? = "default_claude_max_20x"
    ) -> String {
        var oauth: [String: Any] = ["accessToken": token]
        if let expiresAt { oauth["expiresAt"] = expiresAt }
        if let refreshExpiresAt { oauth["refreshTokenExpiresAt"] = refreshExpiresAt }
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        if let subscription { oauth["subscriptionType"] = subscription }
        if let tier { oauth["rateLimitTier"] = tier }
        let data = try! JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth])
        return String(decoding: data, as: UTF8.self)
    }

    static func millis(_ date: Date) -> Double { date.timeIntervalSince1970 * 1000 }
}

/// 키체인 대역. 호출 순서를 기록해 재조회 여부까지 검증한다.
final class FakeKeychain: KeychainStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String]
    private(set) var reads: [String] = []

    init(_ values: [String: String] = [:]) { self.values = values }

    func read(service: String) async -> String? {
        lock.lock(); defer { lock.unlock() }
        reads.append(service)
        return values[service]
    }

    func write(service: String, value: String) async throws {
        lock.lock(); defer { lock.unlock() }
        values[service] = value
    }

    func delete(service: String) async {
        lock.lock(); defer { lock.unlock() }
        values[service] = nil
    }

    func set(_ service: String, _ value: String) {
        lock.lock(); defer { lock.unlock() }
        values[service] = value
    }
}

/// HTTP 대역. 요청을 기록하고 정해진 응답을 돌려준다.
final class FakeHTTP: HTTPGetting, @unchecked Sendable {
    struct Call: Equatable { let url: String; let headers: [String: String] }
    private let lock = NSLock()
    private(set) var calls: [Call] = []
    var responder: (Call) throws -> HTTPResult

    init(responder: @escaping (Call) throws -> HTTPResult) { self.responder = responder }

    func get(url: URL, headers: [String: String], timeout: TimeInterval) async throws -> HTTPResult {
        let call = Call(url: url.absoluteString, headers: headers)
        lock.lock(); calls.append(call); lock.unlock()
        return try responder(call)
    }
}

extension HTTPResult {
    static func ok(_ body: Data) -> HTTPResult { HTTPResult(status: 200, retryAfter: nil, body: body) }
    static func status(_ code: Int, retryAfter: TimeInterval? = nil) -> HTTPResult {
        HTTPResult(status: code, retryAfter: retryAfter, body: Data())
    }
}

func makeTempDir(file: StaticString = #filePath) -> String {
    let path = NSTemporaryDirectory() + "usageisland-tests-" + UUID().uuidString
    try! FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
    return path
}

func writeFile(_ path: String, _ contents: String) {
    let dir = (path as NSString).deletingLastPathComponent
    try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try! contents.write(toFile: path, atomically: true, encoding: .utf8)
}
