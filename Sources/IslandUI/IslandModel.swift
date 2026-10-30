import AppKit
import SwiftUI
import UsageCore

public struct IslandGeometry: Equatable, Sendable {
    public static let expandedWidth: CGFloat = 486
    /// 아이콘과 섬 사이 간격.
    public static let topInset: CGFloat = 6
    public static let collapsedSize = CGSize(width: 64, height: 28)

    /// 접힌 알약이 아이콘 바로 아래에서 시작하도록 섬 가운데에서 떨어뜨리는 거리.
    /// 화면 끝에서 섬이 안쪽으로 밀렸을 때만 0이 아니다.
    public var anchorOffset: CGFloat

    public init(anchorOffset: CGFloat = 0) {
        self.anchorOffset = anchorOffset
    }
}

public struct IslandActions {
    public var refresh: () -> Void
    public var openLogin: (LoginTarget) -> Void
    public var addAccount: (Provider) -> Void
    public var addDeepSeek: (_ label: String, _ apiKey: String) async throws -> Void
    public var removeDeepSeek: (_ accountID: String) -> Void
    public var setHidden: (_ hidden: Bool, _ accountID: String) -> Void
    public var isLoginItemEnabled: () -> Bool
    /// 실제로 적용된 상태를 돌려준다.
    public var setLoginItemEnabled: (Bool) -> Bool
    public var quit: () -> Void

    public init(
        refresh: @escaping () -> Void,
        openLogin: @escaping (LoginTarget) -> Void,
        addAccount: @escaping (Provider) -> Void,
        addDeepSeek: @escaping (String, String) async throws -> Void,
        removeDeepSeek: @escaping (String) -> Void,
        setHidden: @escaping (Bool, String) -> Void,
        isLoginItemEnabled: @escaping () -> Bool,
        setLoginItemEnabled: @escaping (Bool) -> Bool,
        quit: @escaping () -> Void
    ) {
        self.refresh = refresh
        self.openLogin = openLogin
        self.addAccount = addAccount
        self.addDeepSeek = addDeepSeek
        self.removeDeepSeek = removeDeepSeek
        self.setHidden = setHidden
        self.isLoginItemEnabled = isLoginItemEnabled
        self.setLoginItemEnabled = setLoginItemEnabled
        self.quit = quit
    }
}

@MainActor
public final class IslandModel: ObservableObject {
    public enum Page: Equatable { case usage, settings }

    @Published public var isExpanded = false
    @Published public var page: Page = .usage
    @Published public var isAddingDeepSeek = false
    @Published public var geometry: IslandGeometry
    @Published public var contentHeight: CGFloat = 180

    public let store: UsageStore
    public let actions: IslandActions
    /// 미리보기 렌더링에서 시각을 고정할 때만 쓴다.
    public var fixedNow: Date?

    public init(store: UsageStore, actions: IslandActions, geometry: IslandGeometry) {
        self.store = store
        self.actions = actions
        self.geometry = geometry
    }

    public func showDeepSeekForm() {
        isAddingDeepSeek = true
        page = .settings
    }
}

enum IslandTheme {
    static func tint(_ provider: Provider) -> Color {
        switch provider {
        case .claude: return Color(red: 0.89, green: 0.53, blue: 0.40)
        case .codex: return Color(red: 0.13, green: 0.80, blue: 0.56)
        case .deepseek: return Color(red: 0.45, green: 0.57, blue: 1.00)
        }
    }

    static let warning = Color(red: 1.00, green: 0.80, blue: 0.20)
    static let critical = Color(red: 1.00, green: 0.30, blue: 0.27)

    static func ring(provider: Provider, remaining: Double) -> Color {
        switch UsageSeverity(remaining: remaining) {
        case .normal: return tint(provider)
        case .warning: return warning
        case .critical: return critical
        }
    }

    static func rounded(_ size: CGFloat, _ weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .rounded)
    }
}
