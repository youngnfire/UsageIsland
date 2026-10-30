import XCTest
@testable import UsageCore

/// 계정 서비스 대역. gate를 걸면 fetch가 풀어 줄 때까지 멈춘다.
actor FakeService: AccountServicing {
    var accounts: [Account]
    var results: [String: Result<UsageSnapshot, FetchFailure>] = [:]
    private(set) var fetchCounts: [String: Int] = [:]
    private(set) var discoverCount = 0
    private var gates: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var gated: Set<String> = []

    init(accounts: [Account]) { self.accounts = accounts }

    func setResult(_ id: String, _ result: Result<UsageSnapshot, FetchFailure>) { results[id] = result }
    func setAccounts(_ accounts: [Account]) { self.accounts = accounts }
    func gate(_ id: String) { gated.insert(id) }
    func release(_ id: String) {
        gated.remove(id)
        gates[id]?.forEach { $0.resume() }
        gates[id] = nil
    }
    func waitingCount(_ id: String) -> Int { gates[id]?.count ?? 0 }

    func discover() async -> [Account] {
        discoverCount += 1
        return accounts
    }

    func fetch(_ account: Account) async throws -> UsageSnapshot {
        fetchCounts[account.id, default: 0] += 1
        if gated.contains(account.id) {
            await withCheckedContinuation { gates[account.id, default: []].append($0) }
        }
        guard let result = results[account.id] else {
            throw FetchFailure.network("no result")
        }
        return try result.get()
    }
}

private func account(_ id: String, _ provider: Provider = .claude) -> Account {
    Account(id: id, provider: provider, title: id, source: .deepseek(keychainService: id))
}

private func snapshot(used: Double, at date: Date) -> UsageSnapshot {
    UsageSnapshot(windows: [UsageWindow(id: "w", label: "주간", usedPercent: used, resetsAt: nil)], fetchedAt: date)
}

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value += seconds; lock.unlock() }
}

@MainActor
final class UsageStoreTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_793_000_000)

    private func eventually(_ condition: () async -> Bool, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<200 {
            if await condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("condition not met", file: file, line: line)
    }

    func testRefreshFillsRowsInProviderOrder() async {
        let service = FakeService(accounts: [account("d", .deepseek), account("a", .claude), account("c", .codex)])
        for id in ["a", "c", "d"] { await service.setResult(id, .success(snapshot(used: 10, at: start))) }
        let clock = Clock(start)
        let store = UsageStore(service: service, clock: { clock.now })

        await store.refresh()

        XCTAssertEqual(store.visibleRows.map(\.account.id), ["a", "c", "d"])
        XCTAssertEqual(store.visibleRows[0].snapshot?.windows[0].remainingPercent, 90)
        XCTAssertEqual(store.lastRefreshAt, start)
        XCTAssertFalse(store.isRefreshing)
    }

    func testRapidRefreshesShareOneRound() async {
        let service = FakeService(accounts: [account("a")])
        await service.setResult("a", .success(snapshot(used: 10, at: start)))
        await service.gate("a")
        let store = UsageStore(service: service, clock: { [start] in start })

        let first = Task { await store.refresh() }
        let second = Task { await store.refresh() }
        let third = Task { await store.refresh() }
        await eventually { await service.waitingCount("a") == 1 }
        await service.release("a")
        await first.value
        await second.value
        await third.value

        let counts = await service.fetchCounts
        XCTAssertEqual(counts["a"], 1)
    }

    func testRefreshAfterChangeSeesAccountAddedDuringInFlightRound() async {
        let service = FakeService(accounts: [account("a")])
        await service.setResult("a", .success(snapshot(used: 1, at: start)))
        await service.setResult("new", .success(snapshot(used: 2, at: start)))
        await service.gate("a")
        let store = UsageStore(service: service, clock: { [start] in start })

        let round = Task { await store.refresh() }
        await eventually { await service.waitingCount("a") == 1 }
        await service.setAccounts([account("a"), account("new")])
        let afterChange = Task { await store.refreshAfterChange() }
        await service.release("a")
        await round.value
        await afterChange.value

        XCTAssertEqual(store.visibleRows.map(\.account.id), ["a", "new"])
        XCTAssertEqual(store.visibleRows.last?.snapshot?.windows[0].usedPercent, 2)
    }

    func testConcurrentRoundsNeverOverlap() async {
        let service = FakeService(accounts: [account("a")])
        await service.setResult("a", .success(snapshot(used: 1, at: start)))
        await service.gate("a")
        let store = UsageStore(service: service, clock: { [start] in start })

        let round = Task { await store.refresh() }
        await eventually { await service.waitingCount("a") == 1 }
        let first = Task { await store.refreshAfterChange() }
        let second = Task { await store.refreshAfterChange() }
        try? await Task.sleep(nanoseconds: 20_000_000)
        var counts = await service.fetchCounts
        XCTAssertEqual(counts["a"], 1, "진행 중인 라운드가 끝나기 전에 새 라운드가 시작되면 안 된다")

        await service.release("a")
        await round.value
        await first.value
        await second.value
        counts = await service.fetchCounts
        XCTAssertEqual(counts["a"], 3)
    }

    func testFailureKeepsLastGoodValueAndMarksIt() async {
        let service = FakeService(accounts: [account("a")])
        await service.setResult("a", .success(snapshot(used: 10, at: start)))
        let store = UsageStore(service: service, clock: { [start] in start })
        await store.refresh()

        await service.setResult("a", .failure(.network("HTTP 503")))
        await store.refresh()

        XCTAssertEqual(store.visibleRows[0].snapshot?.windows[0].usedPercent, 10)
        XCTAssertEqual(store.visibleRows[0].failure, .network("HTTP 503"))
    }

    func testSuccessClearsPreviousFailure() async {
        let service = FakeService(accounts: [account("a")])
        await service.setResult("a", .failure(.network("x")))
        let store = UsageStore(service: service, clock: { [start] in start })
        await store.refresh()
        XCTAssertEqual(store.visibleRows[0].failure, .network("x"))

        await service.setResult("a", .success(snapshot(used: 20, at: start)))
        await store.refresh()

        XCTAssertNil(store.visibleRows[0].failure)
        XCTAssertEqual(store.visibleRows[0].snapshot?.windows[0].usedPercent, 20)
    }

    func testRateLimitedAccountIsNotCalledAgainUntilRetryTime() async {
        let service = FakeService(accounts: [account("a")])
        let clock = Clock(start)
        await service.setResult("a", .failure(.rateLimited(retryAt: start.addingTimeInterval(120))))
        let store = UsageStore(service: service, clock: { clock.now })

        await store.refresh()
        clock.advance(60)
        await store.refresh()
        var counts = await service.fetchCounts
        XCTAssertEqual(counts["a"], 1)

        clock.advance(61)
        await service.setResult("a", .success(snapshot(used: 1, at: start)))
        await store.refresh()
        counts = await service.fetchCounts
        XCTAssertEqual(counts["a"], 2)
        XCTAssertNil(store.visibleRows[0].failure)
    }

    func testAccountRemovedMidRefreshIsNotResurrected() async {
        let service = FakeService(accounts: [account("a"), account("b")])
        await service.setResult("a", .success(snapshot(used: 1, at: start)))
        await service.setResult("b", .success(snapshot(used: 2, at: start)))
        await service.gate("b")
        let store = UsageStore(service: service, clock: { [start] in start })

        let refresh = Task { await store.refresh() }
        await eventually { await service.waitingCount("b") == 1 }
        await service.setAccounts([account("a")])
        store.forget(accountID: "b")
        XCTAssertEqual(store.visibleRows.map(\.account.id), ["a"])
        await service.release("b")
        await refresh.value

        XCTAssertEqual(store.visibleRows.map(\.account.id), ["a"])
    }

    func testAccountForgottenDuringDiscoveryStaysGone() async {
        let service = FakeService(accounts: [account("a"), account("b")])
        await service.setResult("a", .success(snapshot(used: 1, at: start)))
        let store = UsageStore(service: service, clock: { [start] in start })
        store.forget(accountID: "b")

        await store.refresh()

        XCTAssertEqual(store.visibleRows.map(\.account.id), ["a"])
        let counts = await service.fetchCounts
        XCTAssertNil(counts["b"])
    }

    func testSlowAccountDoesNotBlockOthersFromShowing() async {
        let service = FakeService(accounts: [account("a"), account("b")])
        await service.setResult("a", .success(snapshot(used: 1, at: start)))
        await service.setResult("b", .success(snapshot(used: 2, at: start)))
        await service.gate("b")
        let store = UsageStore(service: service, clock: { [start] in start })

        let refresh = Task { await store.refresh() }
        await eventually { store.visibleRows.first { $0.account.id == "a" }?.snapshot != nil }
        XCTAssertNil(store.visibleRows.first { $0.account.id == "b" }?.snapshot)
        XCTAssertEqual(store.visibleRows.first { $0.account.id == "b" }?.isLoading, true)
        await service.release("b")
        await refresh.value
    }

    func testHiddenAccountIsNotShownOrFetched() async {
        let service = FakeService(accounts: [account("a"), account("b")])
        await service.setResult("a", .success(snapshot(used: 1, at: start)))
        let store = UsageStore(service: service, clock: { [start] in start }, hiddenAccountIDs: ["b"])

        await store.refresh()

        XCTAssertEqual(store.visibleRows.map(\.account.id), ["a"])
        XCTAssertEqual(store.allRows.map(\.account.id), ["a", "b"])
        let counts = await service.fetchCounts
        XCTAssertNil(counts["b"])
    }

    func testUnhidingFetchesOnNextRefresh() async {
        let service = FakeService(accounts: [account("b")])
        await service.setResult("b", .success(snapshot(used: 1, at: start)))
        let store = UsageStore(service: service, clock: { [start] in start }, hiddenAccountIDs: ["b"])
        await store.refresh()

        store.setHidden(false, accountID: "b")
        await store.refresh()

        XCTAssertEqual(store.visibleRows.first?.snapshot?.windows[0].usedPercent, 1)
    }

    func testRefreshIfStaleSkipsFreshDataAndRunsOldData() async {
        let service = FakeService(accounts: [account("a")])
        await service.setResult("a", .success(snapshot(used: 1, at: start)))
        let clock = Clock(start)
        let store = UsageStore(service: service, clock: { clock.now })
        await store.refresh()

        clock.advance(30)
        await store.refreshIfStale(maxAge: 60)
        var counts = await service.fetchCounts
        XCTAssertEqual(counts["a"], 1)

        clock.advance(31)
        await store.refreshIfStale(maxAge: 60)
        counts = await service.fetchCounts
        XCTAssertEqual(counts["a"], 2)
    }

    func testAfterLoginWatchOnlyTouchesAccountsThatNeedLoginAndStopsWhenFixed() async {
        let dead = account("dead")
        let live = account("live")
        let service = FakeService(accounts: [dead, live])
        await service.setResult("dead", .failure(.loginRequired(.claude(configDir: "/x"))))
        await service.setResult("live", .success(snapshot(used: 1, at: start)))
        let store = UsageStore(service: service, clock: { [start] in start })
        await store.refresh()

        await service.setResult("dead", .success(snapshot(used: 5, at: start)))
        await store.watchAfterLogin(interval: 0.001, maxAttempts: 5)

        let counts = await service.fetchCounts
        XCTAssertEqual(counts["live"], 1, "정상 계정의 사용량 API를 반복 호출하면 안 된다")
        XCTAssertEqual(counts["dead"], 2)
        XCTAssertNil(store.visibleRows.first { $0.account.id == "dead" }?.failure)
    }

    func testAfterLoginWatchPicksUpNewAccountAndStops() async {
        let service = FakeService(accounts: [account("a")])
        await service.setResult("a", .success(snapshot(used: 1, at: start)))
        let store = UsageStore(service: service, clock: { [start] in start })
        await store.refresh()

        await service.setResult("b", .success(snapshot(used: 2, at: start)))
        await service.setAccounts([account("a"), account("b")])
        await store.watchAfterLogin(interval: 0.001, maxAttempts: 5)

        XCTAssertEqual(store.visibleRows.map(\.account.id), ["a", "b"])
        let discoverCount = await service.discoverCount
        XCTAssertEqual(discoverCount, 2)
    }

    func testAfterLoginWatchGivesUpAtMaxAttempts() async {
        let service = FakeService(accounts: [account("a")])
        await service.setResult("a", .failure(.loginRequired(.claude(configDir: nil))))
        let store = UsageStore(service: service, clock: { [start] in start })
        await store.refresh()

        await store.watchAfterLogin(interval: 0.001, maxAttempts: 3)

        let counts = await service.fetchCounts
        XCTAssertEqual(counts["a"], 4)
    }
}

final class LiveAccountServiceTests: XCTestCase {
    func testDiscoverListsDeepSeekAccountsFromSettings() async {
        let root = makeTempDir()
        let settings = SettingsStore(path: root + "/settings.json")
        var value = AppSettings()
        value.deepseekAccounts = [DeepSeekAccountConfig(id: "1", label: "회사")]
        settings.save(value)
        let service = LiveAccountService.make(
            discovery: AccountDiscovery(home: root + "/me", usersRoot: root),
            settings: settings,
            keychain: FakeKeychain(),
            http: FakeHTTP { _ in .status(500) },
            runner: FakeRunner { _ in CommandResult(status: 0, stdout: Data(), stderr: Data()) },
            locator: ToolLocator(home: root + "/me", extraDirs: [])
        )

        let accounts = await service.discover()

        XCTAssertEqual(accounts.map(\.id), ["deepseek:1"])
        XCTAssertEqual(accounts[0].title, "회사")
        XCTAssertEqual(accounts[0].source, .deepseek(keychainService: "UsageIsland-deepseek-1"))
    }
}
