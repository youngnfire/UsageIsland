import CryptoKit
import Foundation

extension ClaudeLogin {
    /// Claude Code가 설정 폴더별로 쓰는 키체인 항목 이름.
    public static func keychainService(configDir: String?) -> String {
        guard let configDir else { return "Claude Code-credentials" }
        let digest = SHA256.hash(data: Data(configDir.utf8))
        let suffix = digest.map { String(format: "%02x", $0) }.joined().prefix(8)
        return "Claude Code-credentials-\(suffix)"
    }

    public var keychainService: String { Self.keychainService(configDir: configDir) }
}

/// 값은 메모리에만 잠깐 둔다. 출력해도 토큰이 드러나지 않게 설명을 가린다.
public struct ClaudeCredential: Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let accessToken: String
    public let expiresAt: Date?
    public let refreshExpiresAt: Date?
    public let hasRefreshToken: Bool
    public let subscriptionType: String?
    public let rateLimitTier: String?

    public var description: String { "ClaudeCredential(redacted)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }

    public func isAccessValid(at now: Date) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt > now.addingTimeInterval(60)
    }

    public func canRefresh(at now: Date) -> Bool {
        guard hasRefreshToken else { return false }
        guard let refreshExpiresAt else { return true }
        return refreshExpiresAt > now
    }

    public static func decode(_ raw: String) -> ClaudeCredential? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // `security -w`는 출력 불가 문자가 있으면 값을 16진수로 돌려준다.
        let data = Self.hexDecoded(trimmed) ?? Data(trimmed.utf8)
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let oauth = root["claudeAiOauth"] as? [String: Any],
            let token = oauth["accessToken"] as? String
        else { return nil }
        return ClaudeCredential(
            accessToken: token,
            expiresAt: (oauth["expiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
            refreshExpiresAt: (oauth["refreshTokenExpiresAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
            hasRefreshToken: (oauth["refreshToken"] as? String)?.isEmpty == false,
            subscriptionType: oauth["subscriptionType"] as? String,
            rateLimitTier: oauth["rateLimitTier"] as? String
        )
    }

    private static func hexDecoded(_ text: String) -> Data? {
        guard text.count % 2 == 0, text.first != "{", text.allSatisfy(\.isHexDigit) else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(text.count / 2)
        var index = text.startIndex
        while index < text.endIndex {
            let next = text.index(index, offsetBy: 2)
            guard let byte = UInt8(text[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }
}

public enum ClaudeUsageParser {
    public static func parse(_ data: Data, now: Date, detail: String?) throws -> UsageSnapshot {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FetchFailure.unexpectedResponse("Claude 응답을 읽을 수 없음")
        }
        var windows: [UsageWindow] = []
        if let window = window(root["five_hour"], id: "session", label: "5시간") { windows.append(window) }
        if let window = window(root["seven_day"], id: "weekly", label: "주간") { windows.append(window) }
        for limit in root["limits"] as? [[String: Any]] ?? [] where limit["kind"] as? String == "weekly_scoped" {
            let scope = limit["scope"] as? [String: Any]
            let model = scope?["model"] as? [String: Any]
            guard let name = model?["display_name"] as? String, let percent = limit["percent"] as? Double else { continue }
            windows.append(UsageWindow(
                id: "scoped-\(name)",
                label: name,
                usedPercent: percent,
                resetsAt: date(limit["resets_at"])
            ))
        }
        // 응답 구조가 바뀌었는데 빈 값을 100%로 보여 주면 안 된다.
        guard !windows.isEmpty else {
            throw FetchFailure.unexpectedResponse("Claude 응답에 사용량 창이 없음")
        }
        return UsageSnapshot(windows: windows, detail: detail, fetchedAt: now)
    }

    private static func window(_ value: Any?, id: String, label: String) -> UsageWindow? {
        guard let dict = value as? [String: Any], let used = dict["utilization"] as? Double else { return nil }
        return UsageWindow(id: id, label: label, usedPercent: used, resetsAt: date(dict["resets_at"]))
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        // 응답의 소수점 초는 마이크로초까지라 ISO8601DateFormatter가 읽지 못한다.
        let trimmed = text.replacingOccurrences(of: #"\.\d+"#, with: "", options: .regularExpression)
        return ISO8601DateFormatter().date(from: trimmed)
    }
}

public protocol ClaudeRefreshing: Sendable {
    func refresh(configDir: String?) async throws
}

/// 토큰을 직접 갱신하지 않는다. 앱이 refresh 토큰을 쓰면 회전으로 Claude Code의 로그인이
/// 풀릴 수 있어서, 만료 시 Claude Code가 스스로 갱신하게 맡기고 키체인을 다시 읽는다.
public actor ClaudeFetcher {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let delegateInterval: TimeInterval = 30 * 60
    static let defaultBackoff: TimeInterval = 5 * 60

    private let keychain: KeychainStoring
    private let http: HTTPGetting
    private let refresher: ClaudeRefreshing
    private let clock: @Sendable () -> Date
    private var lastDelegatedAt: [String: Date] = [:]

    public init(
        keychain: KeychainStoring,
        http: HTTPGetting,
        refresher: ClaudeRefreshing,
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.keychain = keychain
        self.http = http
        self.refresher = refresher
        self.clock = clock
    }

    public func fetch(logins: [ClaudeLogin]) async throws -> UsageSnapshot {
        var loaded = await load(logins)
        var rejected = Set<String>()
        if let snapshot = try await requestWithValidTokens(loaded, rejected: &rejected) {
            return snapshot
        }

        let now = clock()
        let refreshable = loaded
            .filter { $0.credential.canRefresh(at: now) }
            .sorted { Self.lastUsable($0.credential) > Self.lastUsable($1.credential) }
        if let best = refreshable.first, canDelegate(best.login, now: now) {
            lastDelegatedAt[best.login.accountKey] = now
            do {
                try await refresher.refresh(configDir: best.login.configDir)
            } catch FetchFailure.toolMissing(let tool) {
                throw FetchFailure.toolMissing(tool)
            } catch {
                // 성공 여부는 아래에서 키체인을 다시 읽어 판단한다.
            }
            loaded = await load(logins)
            if let snapshot = try await requestWithValidTokens(loaded, rejected: &rejected) {
                return snapshot
            }
        }

        let target = loaded.max { Self.lastUsable($0.credential) < Self.lastUsable($1.credential) }?.login ?? logins.first
        throw FetchFailure.loginRequired(.claude(configDir: target?.configDir))
    }

    private func canDelegate(_ login: ClaudeLogin, now: Date) -> Bool {
        guard let last = lastDelegatedAt[login.accountKey] else { return true }
        return now.timeIntervalSince(last) >= Self.delegateInterval
    }

    private struct Loaded {
        let login: ClaudeLogin
        let credential: ClaudeCredential
    }

    private static func lastUsable(_ credential: ClaudeCredential) -> Date {
        credential.refreshExpiresAt ?? credential.expiresAt ?? .distantPast
    }

    private func load(_ logins: [ClaudeLogin]) async -> [Loaded] {
        var result: [Loaded] = []
        for login in logins {
            var raw = await keychain.read(service: login.keychainService)
            if raw == nil {
                let dir = login.configDir ?? NSHomeDirectory() + "/.claude"
                raw = try? String(contentsOfFile: dir + "/.credentials.json", encoding: .utf8)
            }
            if let raw, let credential = ClaudeCredential.decode(raw) {
                result.append(Loaded(login: login, credential: credential))
            }
        }
        return result
    }

    private func requestWithValidTokens(_ loaded: [Loaded], rejected: inout Set<String>) async throws -> UsageSnapshot? {
        let now = clock()
        let valid = loaded
            .filter { $0.credential.isAccessValid(at: now) && !rejected.contains($0.credential.accessToken) }
            .sorted { ($0.credential.expiresAt ?? .distantPast) > ($1.credential.expiresAt ?? .distantPast) }
        for item in valid {
            let response: HTTPResult
            do {
                response = try await http.get(
                    url: Self.usageURL,
                    headers: [
                        "Authorization": "Bearer \(item.credential.accessToken)",
                        "anthropic-beta": "oauth-2025-04-20",
                        "Accept": "application/json",
                        "User-Agent": "UsageIsland/1.0",
                    ],
                    timeout: 15
                )
            } catch let failure as FetchFailure {
                throw failure
            } catch {
                throw FetchFailure.network(error.localizedDescription)
            }
            switch response.status {
            case 200:
                let plan = UsageFormat.plan(subscription: item.credential.subscriptionType, tier: item.credential.rateLimitTier)
                return try ClaudeUsageParser.parse(response.body, now: clock(), detail: plan)
            case 401:
                rejected.insert(item.credential.accessToken)
            case 429:
                throw FetchFailure.rateLimited(retryAt: clock().addingTimeInterval(response.retryAfter ?? Self.defaultBackoff))
            case 500...599:
                throw FetchFailure.network("HTTP \(response.status)")
            default:
                throw FetchFailure.unexpectedResponse("HTTP \(response.status)")
            }
        }
        return nil
    }
}
