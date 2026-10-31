import XCTest
@testable import UsageCore

final class ClaudeUsageParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    func testReadsSessionAndWeeklyAsRemaining() throws {
        let snapshot = try ClaudeUsageParser.parse(Fixtures.claudeUsage, now: now, detail: "Max 20x", in: .korean)
        let session = try XCTUnwrap(snapshot.windows.first { $0.id == "session" })
        XCTAssertEqual(session.label, "5시간")
        XCTAssertEqual(session.remainingPercent, 98, accuracy: 0.01)
        let weekly = try XCTUnwrap(snapshot.windows.first { $0.id == "weekly" })
        XCTAssertEqual(weekly.label, "주간")
        XCTAssertEqual(weekly.remainingPercent, 51, accuracy: 0.01)
        XCTAssertEqual(snapshot.detail, "Max 20x")
        XCTAssertEqual(snapshot.fetchedAt, now)
    }

    func testParsesMicrosecondResetTimestamp() throws {
        let snapshot = try ClaudeUsageParser.parse(Fixtures.claudeUsage, now: now, detail: nil)
        let session = try XCTUnwrap(snapshot.windows.first { $0.id == "session" })
        let expected = ISO8601DateFormatter().date(from: "2026-10-30T13:00:00Z")!
        XCTAssertEqual(try XCTUnwrap(session.resetsAt).timeIntervalSince1970, expected.timeIntervalSince1970, accuracy: 1)
    }

    func testIncludesModelScopedWeeklyWindow() throws {
        let snapshot = try ClaudeUsageParser.parse(Fixtures.claudeUsage, now: now, detail: nil)
        let scoped = try XCTUnwrap(snapshot.windows.first { $0.label == "Fable" })
        XCTAssertEqual(scoped.remainingPercent, 93, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows.count, 3)
    }

    func testResponseWithoutAnyKnownWindowIsReportedNotShownAsFull() {
        let data = Data(#"{"five_hour": null, "seven_day": null, "limits": []}"#.utf8)
        XCTAssertThrowsError(try ClaudeUsageParser.parse(data, now: now, detail: nil)) { error in
            guard case FetchFailure.unexpectedResponse = error else {
                return XCTFail("expected unexpectedResponse, got \(error)")
            }
        }
    }

    func testRemainingNeverLeavesZeroToHundred() {
        XCTAssertEqual(UsageWindow(id: "a", label: "a", usedPercent: 130, resetsAt: nil).remainingPercent, 0)
        XCTAssertEqual(UsageWindow(id: "a", label: "a", usedPercent: -5, resetsAt: nil).remainingPercent, 100)
    }
}

final class ClaudeCredentialTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    func testKeychainServiceForDefaultAndCustomConfigDir() {
        XCTAssertEqual(ClaudeLogin.keychainService(configDir: nil), "Claude Code-credentials")
        // 설정 폴더 경로의 SHA-256 앞 8자리. 실제 Claude Code 키체인 항목 이름과 대조해 확인한 규칙이다.
        XCTAssertEqual(ClaudeLogin.keychainService(configDir: "/Users/alice/.claude"), "Claude Code-credentials-5ac5e874")
        XCTAssertEqual(ClaudeLogin.keychainService(configDir: "/Users/bob/.claude"), "Claude Code-credentials-f6cfe3ca")
    }

    func testZeroExpiryCountsAsExpired() throws {
        let cred = try XCTUnwrap(ClaudeCredential.decode(Fixtures.claudeCredentialJSON(expiresAt: 0)))
        XCTAssertFalse(cred.isAccessValid(at: now))
    }

    func testAccessTokenExpiringWithinOneMinuteIsNotValid() throws {
        let soon = Fixtures.millis(now.addingTimeInterval(30))
        let cred = try XCTUnwrap(ClaudeCredential.decode(Fixtures.claudeCredentialJSON(expiresAt: soon)))
        XCTAssertFalse(cred.isAccessValid(at: now))
        let later = Fixtures.millis(now.addingTimeInterval(600))
        XCTAssertTrue(try XCTUnwrap(ClaudeCredential.decode(Fixtures.claudeCredentialJSON(expiresAt: later))).isAccessValid(at: now))
    }

    func testRefreshAvailabilityFollowsRefreshExpiry() throws {
        let past = Fixtures.millis(now.addingTimeInterval(-86_400))
        let future = Fixtures.millis(now.addingTimeInterval(86_400))
        XCTAssertFalse(try XCTUnwrap(ClaudeCredential.decode(Fixtures.claudeCredentialJSON(refreshExpiresAt: past))).canRefresh(at: now))
        XCTAssertTrue(try XCTUnwrap(ClaudeCredential.decode(Fixtures.claudeCredentialJSON(refreshExpiresAt: future))).canRefresh(at: now))
        XCTAssertFalse(try XCTUnwrap(ClaudeCredential.decode(Fixtures.claudeCredentialJSON(refreshExpiresAt: future, refreshToken: nil))).canRefresh(at: now))
    }

    func testDescriptionNeverContainsToken() throws {
        let cred = try XCTUnwrap(ClaudeCredential.decode(Fixtures.claudeCredentialJSON(token: "sk-secret-value")))
        XCTAssertFalse(String(describing: cred).contains("sk-secret-value"))
        XCTAssertFalse(String(reflecting: cred).contains("sk-secret-value"))
    }

    func testDecodesHexEncodedKeychainOutput() throws {
        let json = Fixtures.claudeCredentialJSON(token: "abc")
        let hex = json.utf8.map { String(format: "%02x", $0) }.joined()
        XCTAssertEqual(try XCTUnwrap(ClaudeCredential.decode(hex)).accessToken, "abc")
    }

    func testPlanLabelUsesTierMultiplier() {
        XCTAssertEqual(UsageFormat.plan(subscription: "max", tier: "default_claude_max_20x"), "Max 20x")
        XCTAssertEqual(UsageFormat.plan(subscription: "max", tier: "default_claude_max_5x"), "Max 5x")
        XCTAssertEqual(UsageFormat.plan(subscription: "pro", tier: nil), "Pro")
        XCTAssertNil(UsageFormat.plan(subscription: nil, tier: nil))
    }
}

final class ClaudeDiscoveryTests: XCTestCase {
    private func claudeJSON(uuid: String, org: String = "org-1", email: String) -> String {
        #"{"oauthAccount": {"accountUuid": "\#(uuid)", "organizationUuid": "\#(org)", "emailAddress": "\#(email)", "organizationName": "\#(email)'s Organization"}}"#
    }

    func testFindsConfigDirsAcrossHomesAndGroupsByAccount() {
        let root = makeTempDir()
        let home = root + "/me"
        writeFile(home + "/.claude.json", claudeJSON(uuid: "A", email: "a@x.com"))
        writeFile(root + "/sua/.claude/.claude.json", claudeJSON(uuid: "A", email: "a@x.com"))
        writeFile(home + "/.claude/.claude.json", claudeJSON(uuid: "B", email: "b@x.com"))
        writeFile(root + "/bring/.claude/.claude.json", claudeJSON(uuid: "B", email: "b@x.com"))
        writeFile(home + "/.claude-work/.claude.json", claudeJSON(uuid: "C", email: "c@x.com"))

        let accounts = AccountDiscovery(home: home, usersRoot: root).claudeAccounts()

        XCTAssertEqual(accounts.map(\.title), ["a@x.com", "b@x.com", "c@x.com"])
        guard case .claude(let logins) = accounts[0].source else { return XCTFail("wrong source") }
        XCTAssertEqual(Set(logins.map(\.configDir)), [nil, root + "/sua/.claude"])
        guard case .claude(let cLogins) = accounts[2].source else { return XCTFail("wrong source") }
        XCTAssertEqual(cLogins.map(\.configDir), [home + "/.claude-work"])
    }

    func testIgnoresDirsWithoutOAuthAccount() {
        let root = makeTempDir()
        let home = root + "/me"
        try! FileManager.default.createDirectory(atPath: home + "/.claude-mem", withIntermediateDirectories: true)
        writeFile(home + "/.claude/.claude.json", #"{"numStartups": 3}"#)
        writeFile(home + "/.claude-broken/.claude.json", "not json")
        XCTAssertTrue(AccountDiscovery(home: home, usersRoot: root).claudeAccounts().isEmpty)
    }

    func testSameAccountInDifferentOrganizationsStaysSeparate() {
        let root = makeTempDir()
        let home = root + "/me"
        writeFile(home + "/.claude/.claude.json", claudeJSON(uuid: "A", org: "org-1", email: "a@x.com"))
        writeFile(home + "/.claude-team/.claude.json", claudeJSON(uuid: "A", org: "org-2", email: "a@x.com"))
        XCTAssertEqual(AccountDiscovery(home: home, usersRoot: root).claudeAccounts().count, 2)
    }
}

final class ClaudeFetcherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func login(_ dir: String?) -> ClaudeLogin {
        ClaudeLogin(configDir: dir, accountKey: "A|org", email: "a@x.com", organization: nil)
    }

    private func future(_ seconds: TimeInterval) -> Double { Fixtures.millis(now.addingTimeInterval(seconds)) }

    private func makeFetcher(
        keychain: FakeKeychain,
        http: FakeHTTP,
        refresher: FakeClaudeRefresher = FakeClaudeRefresher()
    ) -> ClaudeFetcher {
        ClaudeFetcher(keychain: keychain, http: http, refresher: refresher, clock: { [now] in now })
    }

    func testUsesLongestLivedValidTokenWithRequiredHeaders() async throws {
        let shortLived = ClaudeLogin.keychainService(configDir: "/a")
        let longLived = ClaudeLogin.keychainService(configDir: "/b")
        let keychain = FakeKeychain([
            shortLived: Fixtures.claudeCredentialJSON(token: "short", expiresAt: future(600)),
            longLived: Fixtures.claudeCredentialJSON(token: "long", expiresAt: future(9_000)),
        ])
        let http = FakeHTTP { _ in .ok(Fixtures.claudeUsage) }

        let snapshot = try await makeFetcher(keychain: keychain, http: http).fetch(logins: [login("/a"), login("/b")])

        XCTAssertEqual(snapshot.detail, "Max 20x")
        XCTAssertEqual(http.calls.count, 1)
        XCTAssertEqual(http.calls[0].url, "https://api.anthropic.com/api/oauth/usage")
        XCTAssertEqual(http.calls[0].headers["Authorization"], "Bearer long")
        XCTAssertEqual(http.calls[0].headers["anthropic-beta"], "oauth-2025-04-20")
    }

    func testRejectedTokenFallsThroughToNextValidLogin() async throws {
        let keychain = FakeKeychain([
            ClaudeLogin.keychainService(configDir: "/a"): Fixtures.claudeCredentialJSON(token: "bad", expiresAt: future(9_000)),
            ClaudeLogin.keychainService(configDir: "/b"): Fixtures.claudeCredentialJSON(token: "good", expiresAt: future(600)),
        ])
        let http = FakeHTTP { call in
            call.headers["Authorization"] == "Bearer bad" ? .status(401) : .ok(Fixtures.claudeUsage)
        }

        _ = try await makeFetcher(keychain: keychain, http: http).fetch(logins: [login("/a"), login("/b")])

        XCTAssertEqual(http.calls.map { $0.headers["Authorization"] }, ["Bearer bad", "Bearer good"])
    }

    func testAllLoginsDeadAsksHumanToLoginAtMostRecentDirWithoutSpawningCLI() async {
        let keychain = FakeKeychain([
            ClaudeLogin.keychainService(configDir: "/old"): Fixtures.claudeCredentialJSON(
                expiresAt: future(-90_000), refreshExpiresAt: future(-90_000)),
            ClaudeLogin.keychainService(configDir: "/recent"): Fixtures.claudeCredentialJSON(
                expiresAt: 0, refreshExpiresAt: future(-3_600)),
        ])
        let http = FakeHTTP { _ in XCTFail("no request expected"); return .status(500) }
        let refresher = FakeClaudeRefresher()

        do {
            _ = try await makeFetcher(keychain: keychain, http: http, refresher: refresher)
                .fetch(logins: [login("/old"), login("/recent")])
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? FetchFailure, .loginRequired(.claude(configDir: "/recent")))
        }
        XCTAssertEqual(refresher.dirs, [])
    }

    func testExpiredTokenWithLiveRefreshDelegatesToCLIAndRereadsKeychain() async throws {
        let service = ClaudeLogin.keychainService(configDir: "/a")
        let keychain = FakeKeychain([
            service: Fixtures.claudeCredentialJSON(token: "old", expiresAt: future(-60), refreshExpiresAt: future(86_400)),
        ])
        let http = FakeHTTP { _ in .ok(Fixtures.claudeUsage) }
        let refresher = FakeClaudeRefresher { _ in
            keychain.set(service, Fixtures.claudeCredentialJSON(token: "new", expiresAt: self.future(28_800), refreshExpiresAt: self.future(86_400)))
        }

        _ = try await makeFetcher(keychain: keychain, http: http, refresher: refresher).fetch(logins: [login("/a")])

        XCTAssertEqual(refresher.dirs, ["/a"])
        XCTAssertEqual(http.calls.map { $0.headers["Authorization"] }, ["Bearer new"])
    }

    func testCLIRefreshIsAttemptedAtMostOncePerThirtyMinutes() async {
        let service = ClaudeLogin.keychainService(configDir: "/a")
        let keychain = FakeKeychain([
            service: Fixtures.claudeCredentialJSON(expiresAt: future(-60), refreshExpiresAt: future(86_400)),
        ])
        let refresher = FakeClaudeRefresher()
        let fetcher = makeFetcher(keychain: keychain, http: FakeHTTP { _ in .status(500) }, refresher: refresher)

        for _ in 0..<3 {
            do {
                _ = try await fetcher.fetch(logins: [login("/a")])
                XCTFail("expected failure")
            } catch {
                XCTAssertEqual(error as? FetchFailure, .loginRequired(.claude(configDir: "/a")))
            }
        }
        XCTAssertEqual(refresher.dirs, ["/a"])
    }

    func testRateLimitHonorsRetryAfterAndDoesNotTryOtherTokens() async {
        let keychain = FakeKeychain([
            ClaudeLogin.keychainService(configDir: "/a"): Fixtures.claudeCredentialJSON(expiresAt: future(600)),
            ClaudeLogin.keychainService(configDir: "/b"): Fixtures.claudeCredentialJSON(expiresAt: future(500)),
        ])
        let http = FakeHTTP { _ in .status(429, retryAfter: 120) }

        do {
            _ = try await makeFetcher(keychain: keychain, http: http).fetch(logins: [login("/a"), login("/b")])
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? FetchFailure, .rateLimited(retryAt: now.addingTimeInterval(120)))
        }
        XCTAssertEqual(http.calls.count, 1)
    }

    func testRateLimitWithoutHeaderBacksOffFiveMinutes() async {
        let keychain = FakeKeychain([
            ClaudeLogin.keychainService(configDir: "/a"): Fixtures.claudeCredentialJSON(expiresAt: future(600)),
        ])
        do {
            _ = try await makeFetcher(keychain: keychain, http: FakeHTTP { _ in .status(429) }).fetch(logins: [login("/a")])
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? FetchFailure, .rateLimited(retryAt: now.addingTimeInterval(300)))
        }
    }

    func testServerErrorIsNetworkFailure() async {
        let keychain = FakeKeychain([
            ClaudeLogin.keychainService(configDir: "/a"): Fixtures.claudeCredentialJSON(expiresAt: future(600)),
        ])
        do {
            _ = try await makeFetcher(keychain: keychain, http: FakeHTTP { _ in .status(503) }).fetch(logins: [login("/a")])
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? FetchFailure, .network("HTTP 503"))
        }
    }

    func testMissingKeychainItemFallsBackToCredentialsFile() async throws {
        let dir = makeTempDir()
        writeFile(dir + "/.credentials.json", Fixtures.claudeCredentialJSON(token: "fromfile", expiresAt: future(600)))
        let http = FakeHTTP { _ in .ok(Fixtures.claudeUsage) }

        _ = try await makeFetcher(keychain: FakeKeychain(), http: http).fetch(logins: [login(dir)])

        XCTAssertEqual(http.calls.map { $0.headers["Authorization"] }, ["Bearer fromfile"])
    }
}

/// `claude` CLI 위임 대역.
final class FakeClaudeRefresher: ClaudeRefreshing, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var dirs: [String?] = []
    private let onRefresh: (String?) -> Void

    init(onRefresh: @escaping (String?) -> Void = { _ in }) { self.onRefresh = onRefresh }

    func refresh(configDir: String?) async throws {
        lock.lock(); dirs.append(configDir); lock.unlock()
        onRefresh(configDir)
    }
}
