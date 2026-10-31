import SwiftUI
import UsageCore

struct UsagePage: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: UsageStore
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ForEach(Provider.allCases, id: \.self) { provider in
                let rows = store.visibleRows.filter { $0.account.provider == provider }
                if !rows.isEmpty || provider == .deepseek {
                    section(provider, rows: rows)
                }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(nsImage: PromptGlyph.statusImage())
                .renderingMode(.template)
                .foregroundColor(.white)
                .frame(width: 18, height: 18)
            Text(AppText.usageTitle)
                .font(IslandTheme.rounded(13, .bold))
                .foregroundColor(.white)
            Spacer()
            Text(ageText)
                .font(IslandTheme.rounded(11, .medium))
                .foregroundColor(.white.opacity(0.5))
            CircleIconButton(
                systemName: "arrow.clockwise",
                isDisabled: store.isRefreshing,
                spinning: store.isRefreshing,
                action: model.actions.refresh
            )
            CircleIconButton(systemName: "gearshape.fill") {
                model.page = .settings
            }
        }
    }

    private var ageText: String {
        if store.isRefreshing { return AppText.checking }
        guard let last = store.lastRefreshAt else { return "" }
        return UsageFormat.age(since: last, now: now)
    }

    private func section(_ provider: Provider, rows: [AccountRow]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(provider.displayName)
                .font(IslandTheme.rounded(11, .bold))
                .foregroundColor(IslandTheme.tint(provider))
            if rows.isEmpty {
                deepseekPrompt
            }
            ForEach(rows) { row in
                AccountRowView(model: model, row: row, now: now)
            }
        }
    }

    private var deepseekPrompt: some View {
        HStack {
            Text(AppText.connectKeyPrompt)
                .font(IslandTheme.rounded(12, .medium))
                .foregroundColor(.white.opacity(0.6))
            Spacer()
            CapsuleButton(title: AppText.connectKey, tint: IslandTheme.tint(.deepseek)) {
                model.showDeepSeekForm()
            }
        }
    }
}

struct AccountRowView: View {
    @ObservedObject var model: IslandModel
    let row: AccountRow
    let now: Date

    private var isStale: Bool { row.failure != nil && row.snapshot != nil }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text(row.account.title)
                    .font(IslandTheme.rounded(13))
                    .foregroundColor(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                statusLine
            }
            Spacer(minLength: 0)
            trailing
        }
    }

    private var statusLine: some View {
        HStack(spacing: 6) {
            if let text = statusText {
                Text(text)
                    .font(IslandTheme.rounded(11, .medium))
                    .foregroundColor(row.failure == nil ? .white.opacity(0.5) : IslandTheme.warning)
                    .lineLimit(1)
            }
            if let target = row.failure?.loginTarget {
                if case .deepseek = target {
                    CapsuleButton(title: AppText.reconnectKey, tint: IslandTheme.tint(row.account.provider)) {
                        model.showDeepSeekForm()
                    }
                } else {
                    CapsuleButton(title: AppText.logInAgain, tint: IslandTheme.tint(row.account.provider)) {
                        model.actions.openLogin(target)
                    }
                }
            }
        }
    }

    private var statusText: String? {
        if let failure = row.failure {
            let reason = UsageFormat.failureText(failure, now: now)
            if let snapshot = row.snapshot {
                return UsageFormat.staleStatus(since: snapshot.fetchedAt, now: now, reason: reason)
            }
            return reason
        }
        if row.snapshot == nil, row.isLoading { return AppText.loading }
        return row.snapshot?.detail
    }

    @ViewBuilder
    private var trailing: some View {
        if let snapshot = row.snapshot, !snapshot.windows.isEmpty {
            HStack(spacing: 0) {
                ForEach(snapshot.windows.prefix(4)) { window in
                    UsageRing(window: window, provider: row.account.provider, isStale: isStale, now: now, isExpanded: model.isExpanded)
                }
            }
        } else if let snapshot = row.snapshot, snapshot.isAvailable != nil {
            BalanceView(snapshot: snapshot, isStale: isStale)
        } else if row.snapshot == nil, row.isLoading {
            HStack(spacing: 0) {
                ForEach(0..<2, id: \.self) { _ in GhostRing() }
            }
        }
    }
}

struct UsageRing: View {
    let window: UsageWindow
    let provider: Provider
    let isStale: Bool
    let now: Date
    let isExpanded: Bool

    var body: some View {
        let remaining = window.remainingPercent
        let color = isStale ? Color.white.opacity(0.45) : IslandTheme.ring(provider: provider, remaining: remaining)
        VStack(spacing: 3) {
            ZStack {
                Circle().stroke(color.opacity(0.22), lineWidth: 4)
                Circle()
                    .trim(from: 0, to: isExpanded ? remaining / 100 : 0)
                    .stroke(color, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.spring(response: 0.7, dampingFraction: 0.85).delay(isExpanded ? 0.1 : 0), value: isExpanded)
                    .animation(.spring(response: 0.6, dampingFraction: 0.85), value: remaining)
                Text(UsageFormat.percent(remaining))
                    .font(IslandTheme.rounded(10.5, .bold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.7)
                    .lineLimit(1)
                    .foregroundColor(isStale ? .white.opacity(0.6) : .white)
                    .frame(width: 30)
            }
            .frame(width: 38, height: 38)
            Text(window.label)
                .font(IslandTheme.rounded(10))
                .foregroundColor(.white.opacity(0.8))
                .lineLimit(1)
            Text(window.resetsAt.map { UsageFormat.resetCountdown(to: $0, now: now) } ?? " ")
                .font(IslandTheme.rounded(9.5, .medium))
                .foregroundColor(.white.opacity(0.45))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
        }
        .frame(width: 66)
    }
}

struct GhostRing: View {
    var body: some View {
        VStack(spacing: 3) {
            Circle()
                .stroke(Color.white.opacity(0.12), lineWidth: 4)
                .frame(width: 38, height: 38)
            Text(" ").font(IslandTheme.rounded(10))
            Text(" ").font(IslandTheme.rounded(9.5))
        }
        .frame(width: 66)
    }
}

struct BalanceView: View {
    let snapshot: UsageSnapshot
    let isStale: Bool

    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if snapshot.balances.isEmpty {
                Text(AppText.noBalanceInfo)
                    .font(IslandTheme.rounded(12, .medium))
                    .foregroundColor(.white.opacity(0.6))
            }
            ForEach(snapshot.balances, id: \.currency) { balance in
                Text(UsageFormat.money(balance))
                    .font(IslandTheme.rounded(20))
                    .monospacedDigit()
                    .foregroundColor(isStale ? .white.opacity(0.6) : .white)
            }
            Text(snapshot.isAvailable == false ? AppText.insufficientBalance : AppText.balance)
                .font(IslandTheme.rounded(10))
                .foregroundColor(snapshot.isAvailable == false ? IslandTheme.critical : .white.opacity(0.5))
        }
    }
}
