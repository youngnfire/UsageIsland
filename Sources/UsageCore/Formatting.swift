import Foundation

public enum UsageSeverity: Equatable, Sendable {
    case normal, warning, critical

    public init(remaining: Double) {
        if remaining <= 10 {
            self = .critical
        } else if remaining <= 30 {
            self = .warning
        } else {
            self = .normal
        }
    }
}

public enum UsageFormat {
    public static func plan(subscription: String?, tier: String?) -> String? {
        guard let subscription, !subscription.isEmpty else { return nil }
        let name = subscription.prefix(1).uppercased() + subscription.dropFirst()
        if let tier, let range = tier.range(of: #"\d+x$"#, options: .regularExpression) {
            return "\(name) \(tier[range])"
        }
        return name
    }

    public static func resetCountdown(to date: Date, now: Date, in language: AppLanguage = .current) -> String {
        let seconds = Int(date.timeIntervalSince(now))
        if seconds <= 0 { return language.pick("Resets soon", "곧 초기화") }
        if seconds < 60 { return language.pick("<1m", "1분 미만") }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3_600
        let minutes = (seconds % 3_600) / 60
        if days > 0 {
            return hours > 0 ? language.pick("\(days)d \(hours)h", "\(days)일 \(hours)시간") : language.pick("\(days)d", "\(days)일")
        }
        if hours > 0 {
            return minutes > 0 ? language.pick("\(hours)h \(minutes)m", "\(hours)시간 \(minutes)분") : language.pick("\(hours)h", "\(hours)시간")
        }
        return language.pick("\(minutes)m", "\(minutes)분")
    }

    public static func age(since date: Date, now: Date, in language: AppLanguage = .current) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return language.pick("Just now", "방금") }
        if seconds < 3_600 { return language.pick("\(seconds / 60)m ago", "\(seconds / 60)분 전") }
        if seconds < 86_400 { return language.pick("\(seconds / 3_600)h ago", "\(seconds / 3_600)시간 전") }
        return language.pick("\(seconds / 86_400)d ago", "\(seconds / 86_400)일 전")
    }

    /// 실패해서 남겨 둔 값이 언제 값인지와 실패 이유를 한 줄로 쓴다.
    public static func staleStatus(since date: Date, now: Date, reason: String, in language: AppLanguage = .current) -> String {
        let age = age(since: date, now: now, in: language)
        return language.pick("From \(age.lowercased()) · \(reason)", "\(age) 값 · \(reason)")
    }

    /// 창 순서가 아니라 길이로 이름을 붙인다. Pro는 주간 창이 primary로 온다.
    public static func windowLabel(minutes: Int, in language: AppLanguage = .current) -> String {
        if minutes == 10_080 { return language.pick("Weekly", "주간") }
        if minutes % 1_440 == 0 { return language.pick("\(minutes / 1_440)-day", "\(minutes / 1_440)일") }
        if minutes % 60 == 0 { return language.pick("\(minutes / 60)-hour", "\(minutes / 60)시간") }
        return language.pick("\(minutes)-min", "\(minutes)분")
    }

    public static func money(_ balance: MoneyBalance) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        let amount = formatter.string(from: balance.total as NSDecimalNumber) ?? "\(balance.total)"
        switch balance.currency {
        case "CNY": return "¥\(amount)"
        case "USD": return "$\(amount)"
        default: return "\(balance.currency) \(amount)"
        }
    }

    public static func wholeNumber(_ value: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        formatter.roundingMode = .down
        return formatter.string(from: value as NSDecimalNumber) ?? "\(value)"
    }

    public static func credits(_ amount: Decimal, in language: AppLanguage = .current) -> String {
        let amount = wholeNumber(amount)
        return language.pick("\(amount) credits", "크레딧 \(amount)")
    }

    public static func failureText(_ failure: FetchFailure, now: Date, in language: AppLanguage = .current) -> String {
        switch failure {
        case .loginRequired(.deepseek):
            return language.pick("Check API key", "API 키 확인 필요")
        case .loginRequired:
            return language.pick("Login expired", "로그인 만료")
        case .rateLimited(let retryAt):
            let wait = resetCountdown(to: retryAt, now: now, in: language)
            return retryAt > now
                ? language.pick("Rate limited · retry in \(wait)", "요청 제한 · \(wait) 뒤 재시도")
                : language.pick("Rate limited · retrying soon", "요청 제한 · 곧 재시도")
        case .network:
            return language.pick("Connection failed", "연결 실패")
        case .unexpectedResponse:
            return language.pick("Couldn't read response", "응답을 읽지 못함")
        case .toolMissing(let tool):
            return language.pick("\(tool) CLI not found", "\(tool) CLI를 찾을 수 없음")
        }
    }

    /// 거의 다 쓴 계정을 넉넉해 보이게 하지 않도록 내림한다.
    public static func percent(_ remaining: Double) -> String {
        "\(Int(remaining.rounded(.down)))%"
    }
}
