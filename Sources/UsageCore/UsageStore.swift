import Combine
import Foundation

public protocol AccountServicing: Sendable {
    func discover() async -> [Account]
    func fetch(_ account: Account) async throws -> UsageSnapshot
}

public struct AccountRow: Identifiable, Equatable, Sendable {
    public let account: Account
    public var snapshot: UsageSnapshot?
    public var failure: FetchFailure?
    public var isLoading: Bool

    public var id: String { account.id }

    public init(account: Account, snapshot: UsageSnapshot? = nil, failure: FetchFailure? = nil, isLoading: Bool = false) {
        self.account = account
        self.snapshot = snapshot
        self.failure = failure
        self.isLoading = isLoading
    }

    var needsLogin: Bool {
        if case .loginRequired = failure { return true }
        return false
    }
}

@MainActor
public final class UsageStore: ObservableObject {
    @Published public private(set) var allRows: [AccountRow] = []
    @Published public private(set) var isRefreshing = false
    @Published public private(set) var lastRefreshAt: Date?
    @Published public private(set) var hiddenAccountIDs: Set<String>

    private let service: AccountServicing
    private let clock: @Sendable () -> Date
    private var inFlight: Task<Void, Never>?
    private var forgotten: Set<String> = []

    public init(
        service: AccountServicing,
        clock: @escaping @Sendable () -> Date = { Date() },
        hiddenAccountIDs: Set<String> = []
    ) {
        self.service = service
        self.clock = clock
        self.hiddenAccountIDs = hiddenAccountIDs
    }

    public var visibleRows: [AccountRow] {
        allRows.filter { !hiddenAccountIDs.contains($0.id) }
    }

    /// 진행 중인 새로고침이 있으면 새로 시작하지 않고 그 결과를 함께 기다린다.
    public func refresh() async {
        if let inFlight {
            await inFlight.value
            return
        }
        await runRound { _ in true }
    }

    /// 계정을 바꾼 직후에 쓴다. 진행 중인 라운드는 바뀌기 전 목록을 보고 있어 끝난 뒤 새로 돈다.
    public func refreshAfterChange() async {
        while let inFlight { await inFlight.value }
        await runRound { _ in true }
    }

    public func refreshIfStale(maxAge: TimeInterval) async {
        if let lastRefreshAt, clock().timeIntervalSince(lastRefreshAt) < maxAge { return }
        await refresh()
    }

    public func setHidden(_ hidden: Bool, accountID: String) {
        if hidden {
            hiddenAccountIDs.insert(accountID)
        } else {
            hiddenAccountIDs.remove(accountID)
        }
    }

    /// 삭제한 계정은 진행 중인 새로고침의 결과로 되살아나지 않는다.
    public func forget(accountID: String) {
        forgotten.insert(accountID)
        allRows.removeAll { $0.id == accountID }
    }

    /// 로그인 창을 연 뒤 결과를 기다린다. 정상 계정의 사용량 API는 건드리지 않는다.
    public func watchAfterLogin(interval: TimeInterval = 10, maxAttempts: Int = 18) async {
        let knownIDs = Set(allRows.map(\.id))
        let waitingIDs = Set(allRows.filter { $0.needsLogin || $0.snapshot == nil }.map(\.id))
        for _ in 0..<maxAttempts {
            try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
            if Task.isCancelled { return }
            while let inFlight { await inFlight.value }
            await runRound { $0.needsLogin || $0.snapshot == nil }
            let hasNewAccount = allRows.contains { !knownIDs.contains($0.id) }
            let isFixed = allRows.contains { waitingIDs.contains($0.id) && $0.failure == nil && $0.snapshot != nil }
            if hasNewAccount || isFixed { return }
        }
    }

    private func runRound(_ eligible: @escaping (AccountRow) -> Bool) async {
        let task = Task {
            await performRound(eligible)
            // 기다리던 쪽이 깨어나기 전에 비워 두어야 라운드가 겹치지 않는다.
            inFlight = nil
        }
        inFlight = task
        await task.value
    }

    private func performRound(_ eligible: (AccountRow) -> Bool) async {
        isRefreshing = true
        defer { isRefreshing = false }

        merge(await service.discover())

        let now = clock()
        let targets = allRows.filter { row in
            guard !hiddenAccountIDs.contains(row.id), eligible(row) else { return false }
            if case .rateLimited(let retryAt) = row.failure, retryAt > now { return false }
            return true
        }
        for target in targets {
            update(target.id) { $0.isLoading = true }
        }

        let service = self.service
        await withTaskGroup(of: (String, Result<UsageSnapshot, FetchFailure>).self) { group in
            for target in targets {
                let account = target.account
                group.addTask {
                    do {
                        return (account.id, .success(try await service.fetch(account)))
                    } catch let failure as FetchFailure {
                        return (account.id, .failure(failure))
                    } catch {
                        return (account.id, .failure(.network(error.localizedDescription)))
                    }
                }
            }
            for await (id, result) in group {
                update(id) { row in
                    row.isLoading = false
                    switch result {
                    case .success(let snapshot):
                        row.snapshot = snapshot
                        row.failure = nil
                    case .failure(let failure):
                        // 실패해도 마지막 값은 유지하고 오래된 값임을 표시한다.
                        row.failure = failure
                    }
                }
            }
        }
        lastRefreshAt = clock()
    }

    private func merge(_ accounts: [Account]) {
        let existing = Dictionary(uniqueKeysWithValues: allRows.map { ($0.id, $0) })
        let order = Provider.allCases
        allRows = accounts
            .filter { !forgotten.contains($0.id) }
            .map { account -> AccountRow in
                guard let row = existing[account.id] else { return AccountRow(account: account) }
                return AccountRow(account: account, snapshot: row.snapshot, failure: row.failure, isLoading: row.isLoading)
            }
            .enumerated()
            .sorted {
                let left = order.firstIndex(of: $0.element.account.provider) ?? 0
                let right = order.firstIndex(of: $1.element.account.provider) ?? 0
                return (left, $0.offset) < (right, $1.offset)
            }
            .map(\.element)
    }

    private func update(_ id: String, _ change: (inout AccountRow) -> Void) {
        guard let index = allRows.firstIndex(where: { $0.id == id }) else { return }
        change(&allRows[index])
    }
}

public struct LiveAccountService: AccountServicing {
    private let discovery: AccountDiscovery
    private let settings: SettingsStore
    private let claude: ClaudeFetcher
    private let codex: CodexAppServerClient
    private let deepseek: DeepSeekFetcher

    public static func make(
        discovery: AccountDiscovery,
        settings: SettingsStore,
        keychain: KeychainStoring,
        http: HTTPGetting,
        runner: CommandRunning,
        locator: ToolLocator
    ) -> LiveAccountService {
        LiveAccountService(
            discovery: discovery,
            settings: settings,
            claude: ClaudeFetcher(
                keychain: keychain,
                http: http,
                refresher: ClaudeCLIRefresher(runner: runner, executable: locator.find("claude"), searchPath: locator.path)
            ),
            codex: CodexAppServerClient(executable: locator.find("codex"), searchPath: locator.path),
            deepseek: DeepSeekFetcher(keychain: keychain, http: http)
        )
    }

    public func discover() async -> [Account] {
        let deepseekAccounts = settings.load().deepseekAccounts.map { config in
            Account(
                id: "deepseek:\(config.id)",
                provider: .deepseek,
                title: config.label,
                source: .deepseek(keychainService: DeepSeekAccountManager.service(id: config.id))
            )
        }
        return discovery.claudeAccounts() + discovery.codexAccounts() + deepseekAccounts
    }

    public func fetch(_ account: Account) async throws -> UsageSnapshot {
        switch account.source {
        case .claude(let logins):
            return try await claude.fetch(logins: logins)
        case .codex(let home):
            return try await codex.fetch(home: home)
        case .deepseek(let service):
            return try await deepseek.fetch(service: service, accountID: account.id)
        }
    }
}
