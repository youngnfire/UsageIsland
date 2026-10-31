import XCTest
@testable import UsageCore

final class UsageFormatTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    func testResetCountdownPicksTwoLargestUnits() {
        XCTAssertEqual(UsageFormat.resetCountdown(to: now.addingTimeInterval(3 * 3600 + 52 * 60), now: now, in: .korean), "3시간 52분")
        XCTAssertEqual(UsageFormat.resetCountdown(to: now.addingTimeInterval(4 * 86400 + 5 * 3600 + 30), now: now, in: .korean), "4일 5시간")
        XCTAssertEqual(UsageFormat.resetCountdown(to: now.addingTimeInterval(12 * 60), now: now, in: .korean), "12분")
        XCTAssertEqual(UsageFormat.resetCountdown(to: now.addingTimeInterval(2 * 3600), now: now, in: .korean), "2시간")
    }

    func testResetCountdownEdges() {
        XCTAssertEqual(UsageFormat.resetCountdown(to: now.addingTimeInterval(20), now: now, in: .korean), "1분 미만")
        XCTAssertEqual(UsageFormat.resetCountdown(to: now.addingTimeInterval(-5), now: now, in: .korean), "곧 초기화")
    }

    func testAge() {
        XCTAssertEqual(UsageFormat.age(since: now.addingTimeInterval(-20), now: now, in: .korean), "방금")
        XCTAssertEqual(UsageFormat.age(since: now.addingTimeInterval(-180), now: now, in: .korean), "3분 전")
        XCTAssertEqual(UsageFormat.age(since: now.addingTimeInterval(-7200), now: now, in: .korean), "2시간 전")
    }

    func testWindowLabelFromMinutes() {
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 300, in: .korean), "5시간")
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 10080, in: .korean), "주간")
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 1440, in: .korean), "1일")
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 43200, in: .korean), "30일")
        XCTAssertEqual(UsageFormat.windowLabel(minutes: 90, in: .korean), "90분")
    }

    func testMoney() {
        XCTAssertEqual(UsageFormat.money(MoneyBalance(currency: "CNY", total: Decimal(string: "110.00")!)), "¥110.00")
        XCTAssertEqual(UsageFormat.money(MoneyBalance(currency: "USD", total: Decimal(string: "1234.5")!)), "$1,234.50")
        XCTAssertEqual(UsageFormat.money(MoneyBalance(currency: "EUR", total: Decimal(string: "3")!)), "EUR 3.00")
    }

    func testPercentRoundsDownSoNearlyEmptyIsNotOverstated() {
        XCTAssertEqual(UsageFormat.percent(6), "6%")
        XCTAssertEqual(UsageFormat.percent(0.4), "0%")
        XCTAssertEqual(UsageFormat.percent(99.9), "99%")
    }

    func testFailureTextIsShortAndActionable() {
        XCTAssertEqual(UsageFormat.failureText(.loginRequired(.claude(configDir: nil)), now: now, in: .korean), "로그인 만료")
        XCTAssertEqual(UsageFormat.failureText(.loginRequired(.deepseek(accountID: "1")), now: now, in: .korean), "API 키 확인 필요")
        XCTAssertEqual(UsageFormat.failureText(.rateLimited(retryAt: now.addingTimeInterval(180)), now: now, in: .korean), "요청 제한 · 3분 뒤 재시도")
        XCTAssertEqual(UsageFormat.failureText(.rateLimited(retryAt: now.addingTimeInterval(-1)), now: now, in: .korean), "요청 제한 · 곧 재시도")
        XCTAssertEqual(UsageFormat.failureText(.network("HTTP 503"), now: now, in: .korean), "연결 실패")
        XCTAssertEqual(UsageFormat.failureText(.unexpectedResponse("x"), now: now, in: .korean), "응답을 읽지 못함")
        XCTAssertEqual(UsageFormat.failureText(.toolMissing("codex"), now: now, in: .korean), "codex CLI를 찾을 수 없음")
    }

    func testFailureExposesLoginTargetOnlyWhenHumanMustAct() {
        XCTAssertEqual(FetchFailure.loginRequired(.codex(home: "/h")).loginTarget, .codex(home: "/h"))
        XCTAssertNil(FetchFailure.network("x").loginTarget)
        XCTAssertNil(FetchFailure.rateLimited(retryAt: now).loginTarget)
    }

    func testSeverityThresholds() {
        XCTAssertEqual(UsageSeverity(remaining: 31), .normal)
        XCTAssertEqual(UsageSeverity(remaining: 30), .warning)
        XCTAssertEqual(UsageSeverity(remaining: 11), .warning)
        XCTAssertEqual(UsageSeverity(remaining: 10), .critical)
        XCTAssertEqual(UsageSeverity(remaining: 0), .critical)
    }
}

final class IslandPlacementTests: XCTestCase {
    private func midX(anchor: CGFloat, minX: CGFloat = 0, maxX: CGFloat = 3200, width: CGFloat = 486) -> CGFloat {
        IslandPlacement.midX(anchorMidX: anchor, width: width, screenMinX: minX, screenMaxX: maxX, margin: 10)
    }

    func testCentersUnderIconWhenThereIsRoom() {
        XCTAssertEqual(midX(anchor: 1500), 1500)
    }

    func testPushedInwardWhenIconIsNearRightEdge() {
        XCTAssertEqual(midX(anchor: 3190), 3200 - 10 - 243)
    }

    func testPushedInwardWhenIconIsNearLeftEdge() {
        XCTAssertEqual(midX(anchor: 5), 10 + 243)
    }

    func testWorksOnDisplayWithNegativeCoordinates() {
        XCTAssertEqual(midX(anchor: -20, minX: -5120, maxX: 0), -10 - 243)
        XCTAssertEqual(midX(anchor: -2000, minX: -5120, maxX: 0), -2000)
    }

    func testScreenNarrowerThanIslandCentersOnScreen() {
        XCTAssertEqual(midX(anchor: 50, minX: 100, maxX: 400), 250)
    }

    private let screen = CGRect(x: 0, y: 0, width: 3200, height: 1800)

    func testIconInMenuBarIsUsableAnchor() {
        let icon = CGRect(x: 2500, y: 1776, width: 22, height: 22)
        XCTAssertEqual(IslandPlacement.usableAnchor(icon, in: screen), icon)
    }

    func testIconNotYetPlacedAtOriginIsRejected() {
        // 실행 직후 상태 아이템은 (0,0)에 있어 그대로 쓰면 창 높이가 0이 된다.
        XCTAssertNil(IslandPlacement.usableAnchor(CGRect(x: 0, y: 0, width: 22, height: 22), in: screen))
    }

    func testZeroSizedOrOffscreenIconIsRejected() {
        XCTAssertNil(IslandPlacement.usableAnchor(CGRect(x: 2500, y: 1776, width: 0, height: 0), in: screen))
        XCTAssertNil(IslandPlacement.usableAnchor(CGRect(x: 4000, y: 1776, width: 22, height: 22), in: screen))
    }

    func testIconInMenuBarOfDisplayWithNegativeCoordinatesIsUsable() {
        let display = CGRect(x: -5120, y: -75, width: 5120, height: 2160)
        let icon = CGRect(x: -846, y: 2059, width: 22, height: 22)
        XCTAssertEqual(IslandPlacement.usableAnchor(icon, in: display), icon)
    }
}

final class IslandPresentationTests: XCTestCase {
    func testOpenThenCloseHidesAfterAnimation() {
        var state = IslandPresentation()
        XCTAssertEqual(state.toggle(), .open)
        XCTAssertTrue(state.isExpanded)
        guard case .close(let generation) = state.toggle() else { return XCTFail("expected close") }
        XCTAssertFalse(state.isExpanded)
        XCTAssertTrue(state.closeAnimationFinished(generation: generation))
        XCTAssertEqual(state.phase, .hidden)
    }

    func testRapidReopenCancelsPendingHide() {
        var state = IslandPresentation()
        _ = state.toggle()
        guard case .close(let generation) = state.toggle() else { return XCTFail("expected close") }
        XCTAssertEqual(state.toggle(), .open)
        XCTAssertFalse(state.closeAnimationFinished(generation: generation), "지난 닫기 애니메이션이 다시 연 패널을 숨기면 안 된다")
        XCTAssertEqual(state.phase, .open)
    }

    func testCloseWhenAlreadyHiddenOrClosingIsNoOp() {
        var state = IslandPresentation()
        XCTAssertEqual(state.close(), .none)
        _ = state.toggle()
        guard case .close(let generation) = state.close() else { return XCTFail("expected close") }
        XCTAssertEqual(state.close(), .none)
        XCTAssertTrue(state.closeAnimationFinished(generation: generation))
        XCTAssertEqual(state.close(), .none)
    }

    func testManyRapidTogglesEndInConsistentState() {
        var state = IslandPresentation()
        var pending: [Int] = []
        for _ in 0..<9 {
            if case .close(let generation) = state.toggle() { pending.append(generation) }
        }
        XCTAssertEqual(state.phase, .open)
        for generation in pending {
            XCTAssertFalse(state.closeAnimationFinished(generation: generation))
        }
        XCTAssertEqual(state.phase, .open)
    }
}
