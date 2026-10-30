import XCTest
@testable import UsageCore

final class DeepSeekFetcherTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func fetcher(_ http: FakeHTTP, keychain: FakeKeychain = FakeKeychain(["svc": "sk-key\n"])) -> DeepSeekFetcher {
        DeepSeekFetcher(keychain: keychain, http: http, clock: { [now] in now })
    }

    func testReadsBalanceWithBearerKeyFromKeychain() async throws {
        let http = FakeHTTP { _ in .ok(Fixtures.deepseekBalance) }

        let snapshot = try await fetcher(http).fetch(service: "svc", accountID: "deepseek:1")

        XCTAssertEqual(snapshot.balances, [MoneyBalance(currency: "CNY", total: Decimal(string: "110.00")!)])
        XCTAssertEqual(snapshot.isAvailable, true)
        XCTAssertEqual(http.calls[0].url, "https://api.deepseek.com/user/balance")
        XCTAssertEqual(http.calls[0].headers["Authorization"], "Bearer sk-key")
    }

    func testRejectedKeyAsksForNewKey() async {
        let http = FakeHTTP { _ in .status(401) }
        await assertFailure(.loginRequired(.deepseek(accountID: "deepseek:1"))) {
            try await self.fetcher(http).fetch(service: "svc", accountID: "deepseek:1")
        }
    }

    func testMissingKeyAsksForKeyWithoutNetwork() async {
        let http = FakeHTTP { _ in XCTFail("no request expected"); return .status(500) }
        await assertFailure(.loginRequired(.deepseek(accountID: "deepseek:1"))) {
            try await self.fetcher(http, keychain: FakeKeychain()).fetch(service: "svc", accountID: "deepseek:1")
        }
    }

    func testRateLimitBacksOff() async {
        let http = FakeHTTP { _ in .status(429, retryAfter: 30) }
        await assertFailure(.rateLimited(retryAt: now.addingTimeInterval(30))) {
            try await self.fetcher(http).fetch(service: "svc", accountID: "deepseek:1")
        }
    }

    func testMalformedBodyIsReportedNotShownAsZero() async {
        let http = FakeHTTP { _ in .ok(Data(#"{"balance_infos": "nope"}"#.utf8)) }
        await assertFailure(.unexpectedResponse("DeepSeek 응답을 읽을 수 없음")) {
            try await self.fetcher(http).fetch(service: "svc", accountID: "deepseek:1")
        }
    }
}

final class SecurityKeychainTests: XCTestCase {
    func testReadTrimsNewlineAndTreatsNonZeroAsMissing() async {
        let runner = FakeRunner { _ in CommandResult(status: 0, stdout: Data("value\n".utf8), stderr: Data()) }
        let value = await SecurityKeychain(runner: runner).read(service: "svc")
        XCTAssertEqual(value, "value")
        XCTAssertEqual(runner.calls[0].executable, "/usr/bin/security")
        XCTAssertEqual(runner.calls[0].arguments, ["find-generic-password", "-s", "svc", "-w"])

        let missing = FakeRunner { _ in CommandResult(status: 44, stdout: Data(), stderr: Data()) }
        let absent = await SecurityKeychain(runner: missing).read(service: "svc")
        XCTAssertNil(absent)
    }

    func testWriteNeverPutsSecretInProcessArguments() async throws {
        let runner = FakeRunner { call in
            CommandResult(status: 0, stdout: call.arguments == ["-i"] ? Data() : Data("sk-abc\n".utf8), stderr: Data())
        }
        try await SecurityKeychain(runner: runner).write(service: "svc", value: "sk-abc")

        let call = runner.calls[0]
        XCTAssertEqual(call.arguments, ["-i"])
        let hex = Data("sk-abc".utf8).map { String(format: "%02x", $0) }.joined()
        let script = String(decoding: try XCTUnwrap(call.stdin), as: UTF8.self)
        XCTAssertTrue(script.contains("add-generic-password -U -a UsageIsland -s svc -X \(hex)"), script)
        XCTAssertFalse(script.contains("sk-abc"))
    }

    func testWriteFailureThrows() async {
        let runner = FakeRunner { _ in CommandResult(status: 1, stdout: Data(), stderr: Data()) }
        do {
            try await SecurityKeychain(runner: runner).write(service: "svc", value: "x")
            XCTFail("expected throw")
        } catch {}
    }

    func testWriteThatDidNotStickThrowsEvenWhenInteractiveModeExitsZero() async {
        // `security -i`는 안의 명령이 실패해도 0으로 끝날 수 있어 다시 읽어 확인한다.
        let runner = FakeRunner { _ in CommandResult(status: 0, stdout: Data(), stderr: Data()) }
        do {
            try await SecurityKeychain(runner: runner).write(service: "svc", value: "x")
            XCTFail("expected throw")
        } catch {}
    }
}

final class DeepSeekAccountManagerTests: XCTestCase {
    private func make(http: FakeHTTP, keychain: FakeKeychain = FakeKeychain()) -> (DeepSeekAccountManager, SettingsStore) {
        let settings = SettingsStore(path: makeTempDir() + "/settings.json")
        let fetcher = DeepSeekFetcher(keychain: keychain, http: http)
        return (DeepSeekAccountManager(settings: settings, keychain: keychain, fetcher: fetcher), settings)
    }

    func testValidKeyIsStoredInKeychainAndOnlyLabelInSettings() async throws {
        let keychain = FakeKeychain()
        let (manager, settings) = make(http: FakeHTTP { _ in .ok(Fixtures.deepseekBalance) }, keychain: keychain)

        let config = try await manager.add(label: "  회사  ", apiKey: "  sk-new\n")

        XCTAssertEqual(config.label, "회사")
        XCTAssertEqual(settings.load().deepseekAccounts, [config])
        let stored = await keychain.read(service: DeepSeekAccountManager.service(id: config.id))
        XCTAssertEqual(stored, "sk-new")
    }

    func testRejectedKeyIsNotSaved() async {
        let keychain = FakeKeychain()
        let (manager, settings) = make(http: FakeHTTP { _ in .status(401) }, keychain: keychain)
        do {
            _ = try await manager.add(label: "x", apiKey: "bad")
            XCTFail("expected throw")
        } catch {}
        XCTAssertTrue(settings.load().deepseekAccounts.isEmpty)
    }

    func testBlankLabelGetsDefaultAndBlankKeyIsRejectedWithoutNetwork() async throws {
        let http = FakeHTTP { _ in .ok(Fixtures.deepseekBalance) }
        let (manager, _) = make(http: http)
        do {
            _ = try await manager.add(label: "x", apiKey: "   ")
            XCTFail("expected throw")
        } catch {}
        XCTAssertTrue(http.calls.isEmpty)

        let config = try await manager.add(label: " ", apiKey: "sk-a")
        XCTAssertEqual(config.label, "DeepSeek")
    }

    func testRemoveDeletesKeyAndSettingsEntry() async throws {
        let keychain = FakeKeychain()
        let (manager, settings) = make(http: FakeHTTP { _ in .ok(Fixtures.deepseekBalance) }, keychain: keychain)
        let config = try await manager.add(label: "x", apiKey: "sk-a")

        await manager.remove(id: config.id)

        XCTAssertTrue(settings.load().deepseekAccounts.isEmpty)
        let stored = await keychain.read(service: DeepSeekAccountManager.service(id: config.id))
        XCTAssertNil(stored)
    }
}

final class LoginScriptTests: XCTestCase {
    private let locator = (claude: "/bin/claude", codex: "/bin/codex")

    func testClaudeScriptLogsIntoGivenConfigDir() {
        let text = LoginScript.text(for: .claude(configDir: "/Users/me/.claude-2"), claude: locator.claude, codex: locator.codex)
        XCTAssertTrue(text?.contains("mkdir -p '/Users/me/.claude-2'") == true)
        XCTAssertTrue(text?.contains("export CLAUDE_CONFIG_DIR='/Users/me/.claude-2'") == true)
        XCTAssertTrue(text?.contains("'/bin/claude' auth login") == true)
    }

    func testDefaultClaudeLoginClearsInheritedConfigDir() {
        let text = LoginScript.text(for: .claude(configDir: nil), claude: locator.claude, codex: locator.codex)
        XCTAssertTrue(text?.contains("unset CLAUDE_CONFIG_DIR") == true)
    }

    func testCodexScriptUsesCodexHome() {
        let text = LoginScript.text(for: .codex(home: "/Users/me/.codex-2"), claude: locator.claude, codex: locator.codex)
        XCTAssertTrue(text?.contains("export CODEX_HOME='/Users/me/.codex-2'") == true)
        XCTAssertTrue(text?.contains("'/bin/codex' login") == true)
    }

    func testPathsWithQuotesAreEscaped() {
        let text = LoginScript.text(for: .codex(home: "/Users/me/it's"), claude: locator.claude, codex: locator.codex)
        XCTAssertTrue(text?.contains(#"export CODEX_HOME='/Users/me/it'\''s'"#) == true)
    }

    func testMissingCLIOrDeepSeekHasNoScript() {
        XCTAssertNil(LoginScript.text(for: .claude(configDir: nil), claude: nil, codex: nil))
        XCTAssertNil(LoginScript.text(for: .deepseek(accountID: "1"), claude: "/c", codex: "/c"))
    }

    func testNextConfigDirSkipsExisting() {
        let home = makeTempDir()
        try! FileManager.default.createDirectory(atPath: home + "/.claude-2", withIntermediateDirectories: true)
        XCTAssertEqual(AccountDiscovery(home: home, usersRoot: home).nextConfigDir(prefix: ".claude"), home + "/.claude-3")
        XCTAssertEqual(AccountDiscovery(home: home, usersRoot: home).nextConfigDir(prefix: ".codex"), home + "/.codex-2")
    }
}

final class CommandRunnerTests: XCTestCase {
    func testCapturesOutputEnvironmentAndStdin() async throws {
        let result = try await ProcessRunner().run(
            "/bin/sh",
            ["-c", "printf '%s:' \"$MARK\"; cat"],
            environment: ["MARK": "ok"],
            stdin: Data("input".utf8),
            directory: nil,
            timeout: 5
        )
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "ok:input")
    }

    func testKillsProcessOnTimeout() async {
        let started = Date()
        do {
            _ = try await ProcessRunner().run("/bin/sleep", ["30"], environment: nil, stdin: nil, directory: nil, timeout: 0.3)
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? CommandError, .timedOut)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }
}

final class ClaudeCLIRefresherTests: XCTestCase {
    func testRunsLocalOnlyCommandWithHooksDisabledInConfigDir() async throws {
        let runner = FakeRunner { _ in CommandResult(status: 0, stdout: Data(), stderr: Data()) }
        try await ClaudeCLIRefresher(runner: runner, executable: "/bin/claude").refresh(configDir: "/cfg")

        let call = runner.calls[0]
        XCTAssertEqual(call.executable, "/bin/claude")
        XCTAssertEqual(call.environment?["CLAUDE_CONFIG_DIR"], "/cfg")
        XCTAssertEqual(call.arguments.first, "-p")
        XCTAssertEqual(call.arguments[1], "/cost")
        XCTAssertTrue(call.arguments.contains(#"{"disableAllHooks":true}"#))
        XCTAssertTrue(call.arguments.contains("--strict-mcp-config"))
        XCTAssertTrue(call.arguments.contains("--no-session-persistence"))
    }

    func testDefaultLoginDoesNotSetConfigDir() async throws {
        let runner = FakeRunner { _ in CommandResult(status: 0, stdout: Data(), stderr: Data()) }
        try await ClaudeCLIRefresher(runner: runner, executable: "/bin/claude").refresh(configDir: nil)
        XCTAssertNil(runner.calls[0].environment?["CLAUDE_CONFIG_DIR"])
    }

    func testMissingCLIIsToolMissing() async {
        await assertFailure(.toolMissing("claude")) {
            try await ClaudeCLIRefresher(runner: FakeRunner { _ in fatalError() }, executable: nil).refresh(configDir: nil)
        }
    }
}

final class ToolLocatorTests: XCTestCase {
    func testFindsExecutableInUserLocationsAndSkipsNonExecutable() {
        let home = makeTempDir()
        writeFile(home + "/.local/bin/codex", "#!/bin/sh\n")
        XCTAssertNil(ToolLocator(home: home, extraDirs: []).find("codex"))
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home + "/.local/bin/codex")
        XCTAssertEqual(ToolLocator(home: home, extraDirs: []).find("codex"), home + "/.local/bin/codex")
        XCTAssertNil(ToolLocator(home: home, extraDirs: []).find("nothing"))
    }
}

final class SettingsStoreTests: XCTestCase {
    func testRoundTripsAndDefaultsWhenMissing() {
        let path = makeTempDir() + "/nested/settings.json"
        let store = SettingsStore(path: path)
        XCTAssertEqual(store.load(), AppSettings())

        var settings = AppSettings()
        settings.hiddenAccountIDs = ["claude:a"]
        settings.deepseekAccounts = [DeepSeekAccountConfig(id: "1", label: "main")]
        store.save(settings)

        XCTAssertEqual(SettingsStore(path: path).load(), settings)
    }

    func testCorruptFileFallsBackToDefaultsAndIsKeptAside() {
        let dir = makeTempDir()
        let path = dir + "/settings.json"
        writeFile(path, "{{{")
        XCTAssertEqual(SettingsStore(path: path).load(), AppSettings())
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir + "/settings.corrupt.json"))
    }

    func testSettingsFileNeverContainsApiKeyField() throws {
        let path = makeTempDir() + "/settings.json"
        var settings = AppSettings()
        settings.deepseekAccounts = [DeepSeekAccountConfig(id: "1", label: "main")]
        SettingsStore(path: path).save(settings)
        XCTAssertFalse(try String(contentsOfFile: path, encoding: .utf8).lowercased().contains("key\""))
    }
}

/// 명령 실행 대역.
final class FakeRunner: CommandRunning, @unchecked Sendable {
    struct Call {
        let executable: String
        let arguments: [String]
        let environment: [String: String]?
        let stdin: Data?
    }
    private let lock = NSLock()
    private(set) var calls: [Call] = []
    private let responder: (Call) -> CommandResult

    init(responder: @escaping (Call) -> CommandResult) { self.responder = responder }

    func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]?,
        stdin: Data?,
        directory: String?,
        timeout: TimeInterval
    ) async throws -> CommandResult {
        let call = Call(executable: executable, arguments: arguments, environment: environment, stdin: stdin)
        lock.lock(); calls.append(call); lock.unlock()
        return responder(call)
    }
}
