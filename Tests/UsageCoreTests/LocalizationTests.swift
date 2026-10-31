import XCTest
@testable import UsageCore

final class AppLanguageTests: XCTestCase {
    func testFollowsMacLanguageOrder() {
        XCTAssertEqual(AppLanguage.preferred(from: ["ko-KR", "en-KR"]), .korean)
        XCTAssertEqual(AppLanguage.preferred(from: ["en-US", "ko-KR"]), .english)
    }

    func testSkipsUnsupportedLanguagesUntilOneMatches() {
        XCTAssertEqual(AppLanguage.preferred(from: ["de-DE", "ko-KR", "en-US"]), .korean)
        XCTAssertEqual(AppLanguage.preferred(from: ["ja-JP", "en-JP"]), .english)
    }

    func testFallsBackToEnglish() {
        XCTAssertEqual(AppLanguage.preferred(from: ["fr-FR"]), .english)
        XCTAssertEqual(AppLanguage.preferred(from: []), .english)
    }

    func testMatchesWholeLanguageCodeOnly() {
        XCTAssertEqual(AppLanguage.preferred(from: ["ko"]), .korean)
        XCTAssertEqual(AppLanguage.preferred(from: ["ko_KR"]), .korean)
        // 콘칸어(kok)는 ko로 시작해도 한국어가 아니다.
        XCTAssertEqual(AppLanguage.preferred(from: ["kok-IN"]), .english)
    }
}

final class EnglishTextTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    func testResetCountdown() {
        func countdown(_ seconds: TimeInterval) -> String {
            UsageFormat.resetCountdown(to: now.addingTimeInterval(seconds), now: now, in: .english)
        }
        XCTAssertEqual(countdown(3 * 3600 + 52 * 60), "3h 52m")
        XCTAssertEqual(countdown(4 * 86400 + 5 * 3600 + 30), "4d 5h")
        XCTAssertEqual(countdown(86400), "1d")
        XCTAssertEqual(countdown(2 * 3600), "2h")
        XCTAssertEqual(countdown(12 * 60), "12m")
        XCTAssertEqual(countdown(20), "<1m")
        XCTAssertEqual(countdown(-5), "Resets soon")
    }

    func testAge() {
        func age(_ seconds: TimeInterval) -> String {
            UsageFormat.age(since: now.addingTimeInterval(-seconds), now: now, in: .english)
        }
        XCTAssertEqual(age(20), "Just now")
        XCTAssertEqual(age(180), "3m ago")
        XCTAssertEqual(age(7200), "2h ago")
        XCTAssertEqual(age(2 * 86400), "2d ago")
    }

    func testWindowLabel() {
        func label(_ minutes: Int) -> String { UsageFormat.windowLabel(minutes: minutes, in: .english) }
        XCTAssertEqual(label(300), "5-hour")
        XCTAssertEqual(label(10080), "Weekly")
        XCTAssertEqual(label(1440), "1-day")
        XCTAssertEqual(label(43200), "30-day")
        XCTAssertEqual(label(90), "90-min")
    }

    func testFailureText() {
        func text(_ failure: FetchFailure) -> String { UsageFormat.failureText(failure, now: now, in: .english) }
        XCTAssertEqual(text(.loginRequired(.claude(configDir: nil))), "Login expired")
        XCTAssertEqual(text(.loginRequired(.deepseek(accountID: "1"))), "Check API key")
        XCTAssertEqual(text(.rateLimited(retryAt: now.addingTimeInterval(180))), "Rate limited · retry in 3m")
        XCTAssertEqual(text(.rateLimited(retryAt: now.addingTimeInterval(-1))), "Rate limited · retrying soon")
        XCTAssertEqual(text(.network("HTTP 503")), "Connection failed")
        XCTAssertEqual(text(.unexpectedResponse("x")), "Couldn't read response")
        XCTAssertEqual(text(.toolMissing("codex")), "codex CLI not found")
    }

    func testStaleStatusSaysHowOldTheValueIs() {
        func status(_ seconds: TimeInterval, in language: AppLanguage) -> String {
            UsageFormat.staleStatus(since: now.addingTimeInterval(-seconds), now: now, reason: "X", in: language)
        }
        XCTAssertEqual(status(180, in: .english), "From 3m ago · X")
        XCTAssertEqual(status(20, in: .english), "From just now · X")
        XCTAssertEqual(status(180, in: .korean), "3분 전 값 · X")
        XCTAssertEqual(status(20, in: .korean), "방금 값 · X")
    }

    func testClaudeWindowsAreNamedInLanguage() throws {
        let snapshot = try ClaudeUsageParser.parse(Fixtures.claudeUsage, now: now, detail: nil, in: .english)
        XCTAssertEqual(Array(snapshot.windows.map(\.label).prefix(2)), ["5-hour", "Weekly"])
    }

    func testCodexWindowsAndCreditsAreNamedInLanguage() throws {
        let snapshot = try CodexUsageParser.parse(rateLimitsResult: Fixtures.codexRateLimits, now: now, in: .english)
        XCTAssertEqual(snapshot.windows.first?.label, "Weekly")
        XCTAssertEqual(snapshot.detail, "Pro · 2,656 credits")
    }

    func testCodexWindowWithoutDurationAndUnlimitedCredits() throws {
        let data = Data(#"{"rateLimits":{"primary":{"usedPercent":1},"credits":{"unlimited":true}}}"#.utf8)
        let english = try CodexUsageParser.parse(rateLimitsResult: data, now: now, in: .english)
        XCTAssertEqual(english.windows.first?.label, "Limit")
        XCTAssertEqual(english.detail, "Unlimited credits")
        let korean = try CodexUsageParser.parse(rateLimitsResult: data, now: now, in: .korean)
        XCTAssertEqual(korean.windows.first?.label, "한도")
        XCTAssertEqual(korean.detail, "크레딧 무제한")
    }

    func testLoginScriptClosingLine() throws {
        let target = LoginTarget.codex(home: "/h")
        let english = try XCTUnwrap(LoginScript.text(for: target, claude: nil, codex: "/c", in: .english))
        XCTAssertTrue(english.contains("echo 'Done. You can close this window.'"))
        let korean = try XCTUnwrap(LoginScript.text(for: target, claude: nil, codex: "/c", in: .korean))
        XCTAssertTrue(korean.contains("echo '끝났습니다. 이 창은 닫아도 됩니다.'"))
    }
}

/// 번역을 거치지 않은 한국어가 영어 화면에 새지 않게 소스 전체를 검사한다.
final class UntranslatedTextTests: XCTestCase {
    private let hangul = "[가-힣]"

    private func sourceLines() throws -> [(place: String, code: String)] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources")
        let walker = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var lines: [(String, String)] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            let text = try String(contentsOf: url, encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                // 줄 주석은 화면에 나오지 않는다.
                let code = line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? line
                lines.append(("\(url.lastPathComponent):\(index + 1)", code))
            }
        }
        XCTAssertGreaterThan(lines.count, 1000, "소스를 찾지 못하면 검사가 빈손으로 통과한다")
        return lines
    }

    func testKoreanTextOnlyAppearsAsSecondArgumentOfPick() throws {
        let literal = "\"[^\"]*\(hangul)[^\"]*\""
        let englishSlot = "pick\\(\"[^\"]*\(hangul)"
        for (place, code) in try sourceLines() where code.range(of: literal, options: .regularExpression) != nil {
            XCTAssertTrue(code.contains("pick("), "번역 없는 문구: \(place)")
            XCTAssertNil(code.range(of: englishSlot, options: .regularExpression), "영어 자리에 한국어: \(place)")
        }
    }
}
