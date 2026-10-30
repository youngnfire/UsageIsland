import Foundation

public enum Provider: String, Codable, CaseIterable, Sendable {
    case claude, codex, deepseek

    public var displayName: String {
        switch self {
        case .claude: return "Claude"
        case .codex: return "Codex"
        case .deepseek: return "DeepSeek"
        }
    }
}

public struct UsageWindow: Identifiable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let usedPercent: Double
    public let resetsAt: Date?

    public init(id: String, label: String, usedPercent: Double, resetsAt: Date?) {
        self.id = id
        self.label = label
        self.usedPercent = usedPercent
        self.resetsAt = resetsAt
    }

    public var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }
}

public struct MoneyBalance: Equatable, Sendable {
    public let currency: String
    public let total: Decimal

    public init(currency: String, total: Decimal) {
        self.currency = currency
        self.total = total
    }
}

public struct UsageSnapshot: Equatable, Sendable {
    public var windows: [UsageWindow]
    public var balances: [MoneyBalance]
    /// DeepSeek의 `is_available`. 다른 프로바이더는 nil.
    public var isAvailable: Bool?
    public var detail: String?
    public var fetchedAt: Date

    public init(
        windows: [UsageWindow] = [],
        balances: [MoneyBalance] = [],
        isAvailable: Bool? = nil,
        detail: String? = nil,
        fetchedAt: Date
    ) {
        self.windows = windows
        self.balances = balances
        self.isAvailable = isAvailable
        self.detail = detail
        self.fetchedAt = fetchedAt
    }
}

/// 사람이 다시 로그인하거나 키를 넣어야 할 때 어디에 해야 하는지 가리킨다.
public enum LoginTarget: Equatable, Sendable {
    case claude(configDir: String?)
    case codex(home: String)
    case deepseek(accountID: String)
}

public enum FetchFailure: Error, Equatable, Sendable {
    case loginRequired(LoginTarget)
    case rateLimited(retryAt: Date)
    case network(String)
    case unexpectedResponse(String)
    case toolMissing(String)

    public var loginTarget: LoginTarget? {
        if case .loginRequired(let target) = self { return target }
        return nil
    }
}

public struct ClaudeLogin: Equatable, Sendable {
    /// nil이면 CLAUDE_CONFIG_DIR 없이 실행한 기본 위치(`~/.claude.json`).
    public let configDir: String?
    public let accountKey: String
    public let email: String
    public let organization: String?

    public init(configDir: String?, accountKey: String, email: String, organization: String?) {
        self.configDir = configDir
        self.accountKey = accountKey
        self.email = email
        self.organization = organization
    }
}

public enum AccountSource: Equatable, Sendable {
    /// 같은 계정이 여러 설정 폴더에 로그인돼 있을 수 있어 묶어서 가진다.
    case claude(logins: [ClaudeLogin])
    case codex(home: String)
    case deepseek(keychainService: String)
}

public struct Account: Identifiable, Equatable, Sendable {
    public let id: String
    public let provider: Provider
    public let title: String
    public let source: AccountSource

    public init(id: String, provider: Provider, title: String, source: AccountSource) {
        self.id = id
        self.provider = provider
        self.title = title
        self.source = source
    }
}
