import XCTest
@testable import UsageCore

func assertFailure<T>(
    _ expected: FetchFailure,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ body: () async throws -> T
) async {
    do {
        _ = try await body()
        XCTFail("expected \(expected)", file: file, line: line)
    } catch {
        XCTAssertEqual(error as? FetchFailure, expected, file: file, line: line)
    }
}

final class CodexUsageParserTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    func testWeeklyOnlyPlanIsLabelledFromWindowLengthNotPosition() throws {
        let snapshot = try CodexUsageParser.parse(rateLimitsResult: Fixtures.codexRateLimits, now: now)
        XCTAssertEqual(snapshot.windows.count, 1)
        XCTAssertEqual(snapshot.windows[0].label, "주간")
        XCTAssertEqual(snapshot.windows[0].remainingPercent, 6, accuracy: 0.01)
        XCTAssertEqual(snapshot.windows[0].resetsAt, Date(timeIntervalSince1970: 1_793_775_077))
    }

    func testDetailShowsPlanAndWholeCredits() throws {
        let snapshot = try CodexUsageParser.parse(rateLimitsResult: Fixtures.codexRateLimits, now: now)
        XCTAssertEqual(snapshot.detail, "Pro · 크레딧 2,656")
    }

    func testPrimaryAndSecondaryWindowsAndExtraNamedLimit() throws {
        let data = Data(#"""
        {"rateLimits": {"limitId": "codex",
           "primary": {"usedPercent": 10, "windowDurationMins": 300, "resetsAt": 1793000100},
           "secondary": {"usedPercent": 20, "windowDurationMins": 10080, "resetsAt": 1793000200},
           "planType": "plus"},
         "rateLimitsByLimitId": {
           "codex": {"limitId": "codex", "primary": {"usedPercent": 10, "windowDurationMins": 300, "resetsAt": 1793000100}},
           "spark": {"limitId": "spark", "limitName": "Spark", "primary": {"usedPercent": 30, "windowDurationMins": 10080, "resetsAt": 1793000300}}
         }}
        """#.utf8)
        let snapshot = try CodexUsageParser.parse(rateLimitsResult: data, now: now)
        XCTAssertEqual(snapshot.windows.map(\.label), ["5시간", "주간", "Spark"])
        XCTAssertEqual(snapshot.detail, "Plus")
    }

    func testMissingRateLimitsIsReportedNotShownAsFull() {
        XCTAssertThrowsError(try CodexUsageParser.parse(rateLimitsResult: Data("{}".utf8), now: now)) { error in
            guard case FetchFailure.unexpectedResponse = error else { return XCTFail("got \(error)") }
        }
    }
}

final class CodexDiscoveryTests: XCTestCase {
    private func idToken(email: String) -> String {
        let payload = try! JSONSerialization.data(withJSONObject: ["email": email])
        let encoded = payload.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "e30.\(encoded).sig"
    }

    private func authJSON(accountID: String, email: String) -> String {
        #"{"auth_mode":"chatgpt","tokens":{"access_token":"x","refresh_token":"y","id_token":"\#(idToken(email: email))","account_id":"\#(accountID)"}}"#
    }

    func testFindsHomesAndDedupesSameAccountPreferringNewestLogin() throws {
        let root = makeTempDir()
        let home = root + "/me"
        writeFile(home + "/.codex/auth.json", authJSON(accountID: "acc", email: "a@x.com"))
        writeFile(root + "/other/.codex/auth.json", authJSON(accountID: "acc", email: "a@x.com"))
        writeFile(home + "/.codex-work/auth.json", authJSON(accountID: "acc2", email: "b@x.com"))
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: home + "/.codex/auth.json")

        let accounts = AccountDiscovery(home: home, usersRoot: root).codexAccounts()

        XCTAssertEqual(accounts.map(\.title), ["a@x.com", "b@x.com"])
        XCTAssertEqual(accounts[0].source, .codex(home: root + "/other/.codex"))
        XCTAssertEqual(accounts[1].source, .codex(home: home + "/.codex-work"))
    }

    func testIgnoresApiKeyLoginAndFoldersWithoutAuth() {
        let root = makeTempDir()
        let home = root + "/me"
        writeFile(home + "/.codex/auth.json", #"{"auth_mode":"apikey","OPENAI_API_KEY":"sk-x","tokens":null}"#)
        try! FileManager.default.createDirectory(atPath: home + "/.codex-empty", withIntermediateDirectories: true)
        XCTAssertTrue(AccountDiscovery(home: home, usersRoot: root).codexAccounts().isEmpty)
    }
}

final class CodexAppServerClientTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    /// 실제 Process 경로를 그대로 타도록 `codex` 자리에 셸 스크립트를 둔다.
    private func fakeCodex(_ body: String) -> String {
        let path = makeTempDir() + "/codex"
        writeFile(path, "#!/bin/sh\n" + body)
        try! FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
        return path
    }

    private func replying(account: String, rateLimits: String) -> String {
        """
        while IFS= read -r line; do
          case "$line" in
            *'"initialize"'*) echo 'not json noise'; echo '{"id":1,"result":{}}' ;;
            *'account/read'*) echo '\(account)' ;;
            *'account/rateLimits/read'*) echo '\(rateLimits)' ;;
          esac
        done
        """
    }

    private var rateLimitsReply: String {
        let compact = try! JSONSerialization.jsonObject(with: Fixtures.codexRateLimits)
        let data = try! JSONSerialization.data(withJSONObject: ["id": 3, "result": compact])
        return String(decoding: data, as: UTF8.self)
    }

    func testReadsSnapshotThroughJsonRpcWithCodexHome() async throws {
        let marker = makeTempDir() + "/env"
        let script = "echo \"$CODEX_HOME $*\" > '\(marker)'\n" + replying(
            account: #"{"id":2,"result":{"account":{"type":"chatgpt","email":"a@x.com","planType":"pro"},"requiresOpenaiAuth":true}}"#,
            rateLimits: rateLimitsReply
        )
        let client = CodexAppServerClient(executable: fakeCodex(script), timeout: 5, clock: { [now] in now })

        let snapshot = try await client.fetch(home: "/some/home")

        XCTAssertEqual(snapshot.windows.first?.label, "주간")
        XCTAssertEqual(snapshot.detail, "Pro · 크레딧 2,656")
        let recorded = try String(contentsOfFile: marker, encoding: .utf8)
        XCTAssertTrue(recorded.hasPrefix("/some/home "), recorded)
        XCTAssertTrue(recorded.contains("-s read-only -a never app-server"), recorded)
    }

    func testNoAccountMeansLoginRequired() async {
        let script = replying(
            account: #"{"id":2,"result":{"account":null,"requiresOpenaiAuth":true}}"#,
            rateLimits: #"{"id":3,"error":{"code":-32600,"message":"codex account authentication required"}}"#
        )
        let client = CodexAppServerClient(executable: fakeCodex(script), timeout: 5, clock: { [now] in now })
        await assertFailure(.loginRequired(.codex(home: "/h"))) { try await client.fetch(home: "/h") }
    }

    func testRpcErrorUnrelatedToAuthIsUnexpected() async {
        let script = replying(
            account: #"{"id":2,"result":{"account":{"type":"chatgpt","email":"a@x.com"}}}"#,
            rateLimits: #"{"id":3,"error":{"code":-32603,"message":"backend exploded"}}"#
        )
        let client = CodexAppServerClient(executable: fakeCodex(script), timeout: 5, clock: { [now] in now })
        await assertFailure(.unexpectedResponse("backend exploded")) { try await client.fetch(home: "/h") }
    }

    func testRpcErrorAboutConnectivityIsNetwork() async {
        let script = replying(
            account: #"{"id":2,"result":{"account":{"type":"chatgpt","email":"a@x.com"}}}"#,
            rateLimits: #"{"id":3,"error":{"code":-32603,"message":"error sending request for url"}}"#
        )
        let client = CodexAppServerClient(executable: fakeCodex(script), timeout: 5, clock: { [now] in now })
        await assertFailure(.network("error sending request for url")) { try await client.fetch(home: "/h") }
    }

    func testHungServerTimesOutInsteadOfWaitingForever() async {
        let client = CodexAppServerClient(executable: fakeCodex("sleep 30\n"), timeout: 0.5, clock: { [now] in now })
        let started = Date()
        await assertFailure(.network("Codex 응답 시간 초과")) { try await client.fetch(home: "/h") }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
    }

    func testServerExitingEarlyIsNetworkFailure() async {
        let client = CodexAppServerClient(executable: fakeCodex("exit 3\n"), timeout: 5, clock: { [now] in now })
        await assertFailure(.network("Codex가 응답 전에 종료됨")) { try await client.fetch(home: "/h") }
    }

    func testMissingExecutableIsToolMissing() async {
        let client = CodexAppServerClient(executable: nil, timeout: 5, clock: { [now] in now })
        await assertFailure(.toolMissing("codex")) { try await client.fetch(home: "/h") }
    }
}
