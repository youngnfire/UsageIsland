import Foundation

/// 화면 언어. 맥의 언어 순서에서 처음 나오는 지원 언어를 쓰고, 없으면 영어로 보여 준다.
public enum AppLanguage: Sendable {
    case english, korean

    public static let current = preferred(from: Locale.preferredLanguages)

    public static func preferred(from languages: [String]) -> AppLanguage {
        for language in languages {
            switch language.split(whereSeparator: { $0 == "-" || $0 == "_" }).first?.lowercased() {
            case "ko": return .korean
            case "en": return .english
            default: continue
            }
        }
        return .english
    }

    /// 두 언어를 나란히 적게 해서 한쪽을 빠뜨리면 컴파일되지 않는다.
    public func pick(_ english: String, _ korean: String) -> String {
        self == .korean ? korean : english
    }
}

/// 패널의 고정 문구. 값에 따라 달라지는 문구는 `UsageFormat`에 있다.
public enum AppText {
    private static let language = AppLanguage.current

    public static let usageTitle = language.pick("Usage left", "남은 사용량")
    public static let checking = language.pick("Checking", "확인 중")
    public static let loading = language.pick("Loading", "불러오는 중")
    public static let connectKeyPrompt = language.pick("Connect an API key to see your balance", "API 키를 연결하면 잔액이 보여요")
    public static let connectKey = language.pick("Connect key", "키 연결")
    public static let reconnectKey = language.pick("Reconnect key", "키 다시 연결")
    public static let logInAgain = language.pick("Log in again", "다시 로그인")
    public static let balance = language.pick("Balance", "잔액")
    public static let noBalanceInfo = language.pick("No balance info", "잔액 정보 없음")
    public static let insufficientBalance = language.pick("Insufficient balance", "잔액 부족")

    public static let accounts = language.pick("Accounts", "계정")
    public static let noAccountsFound = language.pick("No accounts found on this Mac yet", "이 맥에서 찾은 계정이 아직 없어요")
    public static let addAccount = language.pick("Add account", "계정 추가")
    public static let launchAtLogin = language.pick("Launch at login", "로그인할 때 자동 실행")
    public static let quit = language.pick("Quit", "앱 종료")
    public static let confirmDelete = language.pick("Confirm delete", "삭제 확인")

    public static let namePlaceholder = language.pick("Name (optional)", "이름 (선택)")
    public static let apiKeyPlaceholder = language.pick("DeepSeek API key", "DeepSeek API 키")
    public static let paste = language.pick("Paste", "붙여넣기")
    public static let connect = language.pick("Connect", "연결")
    public static let invalidKey = language.pick("That key isn't valid. Check it and try again.", "키가 올바르지 않아요. 다시 확인해 주세요.")

    public static func couldNotSave(_ reason: String) -> String {
        language.pick("Couldn't save · \(reason)", "저장하지 못했어요 · \(reason)")
    }
}
