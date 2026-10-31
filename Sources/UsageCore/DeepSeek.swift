import Foundation

public struct DeepSeekFetcher: Sendable {
    static let balanceURL = URL(string: "https://api.deepseek.com/user/balance")!

    private let keychain: KeychainStoring
    private let http: HTTPGetting
    private let clock: @Sendable () -> Date

    public init(keychain: KeychainStoring, http: HTTPGetting, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.keychain = keychain
        self.http = http
        self.clock = clock
    }

    public func fetch(service: String, accountID: String) async throws -> UsageSnapshot {
        guard let key = await keychain.read(service: service), !key.isEmpty else {
            throw FetchFailure.loginRequired(.deepseek(accountID: accountID))
        }
        return try await fetch(apiKey: key.trimmingCharacters(in: .whitespacesAndNewlines), accountID: accountID)
    }

    public func fetch(apiKey: String, accountID: String) async throws -> UsageSnapshot {
        let response: HTTPResult
        do {
            response = try await http.get(
                url: Self.balanceURL,
                headers: ["Authorization": "Bearer \(apiKey)", "Accept": "application/json"],
                timeout: 15
            )
        } catch let failure as FetchFailure {
            throw failure
        } catch {
            throw FetchFailure.network(error.localizedDescription)
        }
        switch response.status {
        case 200:
            return try parse(response.body)
        case 401:
            throw FetchFailure.loginRequired(.deepseek(accountID: accountID))
        case 429:
            throw FetchFailure.rateLimited(retryAt: clock().addingTimeInterval(response.retryAfter ?? 300))
        case 500...599:
            throw FetchFailure.network("HTTP \(response.status)")
        default:
            throw FetchFailure.unexpectedResponse("HTTP \(response.status)")
        }
    }

    private func parse(_ data: Data) throws -> UsageSnapshot {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let infos = root["balance_infos"] as? [[String: Any]]
        else {
            throw FetchFailure.unexpectedResponse("Couldn't read DeepSeek response")
        }
        let balances = infos.compactMap { info -> MoneyBalance? in
            guard
                let currency = info["currency"] as? String,
                let text = info["total_balance"] as? String,
                let total = Decimal(string: text)
            else { return nil }
            return MoneyBalance(currency: currency, total: total)
        }
        return UsageSnapshot(balances: balances, isAvailable: root["is_available"] as? Bool, fetchedAt: clock())
    }
}

public struct DeepSeekAccountManager: Sendable {
    private let settings: SettingsStore
    private let keychain: KeychainStoring
    private let fetcher: DeepSeekFetcher

    public init(settings: SettingsStore, keychain: KeychainStoring, fetcher: DeepSeekFetcher) {
        self.settings = settings
        self.keychain = keychain
        self.fetcher = fetcher
    }

    public static func service(id: String) -> String { "UsageIsland-deepseek-\(id)" }

    /// 잔액 조회가 성공한 키만 저장한다. 설정 파일에는 이름만 남고 키는 키체인에 들어간다.
    public func add(label: String, apiKey: String) async throws -> DeepSeekAccountConfig {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw FetchFailure.unexpectedResponse("API key is empty") }
        let id = UUID().uuidString
        _ = try await fetcher.fetch(apiKey: key, accountID: "deepseek:\(id)")
        try await keychain.write(service: Self.service(id: id), value: key)

        let trimmedLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let config = DeepSeekAccountConfig(id: id, label: trimmedLabel.isEmpty ? "DeepSeek" : trimmedLabel)
        var current = settings.load()
        current.deepseekAccounts.append(config)
        settings.save(current)
        return config
    }

    public func remove(id: String) async {
        var current = settings.load()
        current.deepseekAccounts.removeAll { $0.id == id }
        settings.save(current)
        await keychain.delete(service: Self.service(id: id))
    }
}
