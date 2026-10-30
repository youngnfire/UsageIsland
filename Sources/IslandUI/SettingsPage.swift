import AppKit
import SwiftUI
import UsageCore

struct SettingsPage: View {
    @ObservedObject var model: IslandModel
    @ObservedObject var store: UsageStore
    @State private var pendingDeleteID: String?
    @State private var loginItemEnabled = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                CircleIconButton(systemName: "chevron.left") {
                    model.isAddingDeepSeek = false
                    model.page = .usage
                }
                Text("계정")
                    .font(IslandTheme.rounded(13, .bold))
                    .foregroundColor(.white)
                Spacer()
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(store.allRows) { row in
                    accountRow(row)
                }
                if store.allRows.isEmpty {
                    Text("이 맥에서 찾은 계정이 아직 없어요")
                        .font(IslandTheme.rounded(12, .medium))
                        .foregroundColor(.white.opacity(0.6))
                }
            }

            HStack(spacing: 6) {
                Text("계정 추가")
                    .font(IslandTheme.rounded(12, .medium))
                    .foregroundColor(.white.opacity(0.6))
                Spacer()
                CapsuleButton(title: "+ Claude", tint: IslandTheme.tint(.claude)) {
                    model.actions.addAccount(.claude)
                }
                CapsuleButton(title: "+ Codex", tint: IslandTheme.tint(.codex)) {
                    model.actions.addAccount(.codex)
                }
                CapsuleButton(title: "+ DeepSeek", tint: IslandTheme.tint(.deepseek)) {
                    model.isAddingDeepSeek.toggle()
                }
            }

            if model.isAddingDeepSeek {
                DeepSeekForm(model: model)
                    .transition(.opacity)
            }

            HStack {
                Toggle("로그인할 때 자동 실행", isOn: Binding(
                    get: { loginItemEnabled },
                    set: { loginItemEnabled = model.actions.setLoginItemEnabled($0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .font(IslandTheme.rounded(12, .medium))
                .foregroundColor(.white.opacity(0.8))
                Spacer()
                CapsuleButton(title: "앱 종료", action: model.actions.quit)
            }
        }
        .onAppear { loginItemEnabled = model.actions.isLoginItemEnabled() }
        .animation(.easeInOut(duration: 0.18), value: model.isAddingDeepSeek)
    }

    private func accountRow(_ row: AccountRow) -> some View {
        let isHidden = store.hiddenAccountIDs.contains(row.id)
        return HStack(spacing: 8) {
            Circle()
                .fill(IslandTheme.tint(row.account.provider))
                .frame(width: 7, height: 7)
            Text(row.account.title)
                .font(IslandTheme.rounded(12, .medium))
                .foregroundColor(.white.opacity(isHidden ? 0.4 : 0.9))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if row.account.provider == .deepseek {
                if pendingDeleteID == row.id {
                    CapsuleButton(title: "삭제 확인", tint: IslandTheme.critical) {
                        pendingDeleteID = nil
                        model.actions.removeDeepSeek(row.id)
                    }
                } else {
                    CircleIconButton(systemName: "trash.fill") { pendingDeleteID = row.id }
                }
            }
            CircleIconButton(systemName: isHidden ? "eye.slash.fill" : "eye.fill") {
                model.actions.setHidden(!isHidden, row.id)
            }
        }
    }
}

struct DeepSeekForm: View {
    @ObservedObject var model: IslandModel
    @State private var label = ""
    @State private var apiKey = ""
    @State private var errorText: String?
    @State private var isSubmitting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("", text: $label, prompt: Text("이름 (선택)"))
                .modifier(IslandFieldStyle())
            HStack(spacing: 6) {
                SecureField("", text: $apiKey, prompt: Text("DeepSeek API 키"))
                    .modifier(IslandFieldStyle())
                    .onSubmit(submit)
                CapsuleButton(title: "붙여넣기") {
                    apiKey = NSPasteboard.general.string(forType: .string)?
                        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                }
                CapsuleButton(
                    title: isSubmitting ? "확인 중" : "연결",
                    tint: IslandTheme.tint(.deepseek),
                    isDisabled: isSubmitting || apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                    action: submit
                )
            }
            if let errorText {
                Text(errorText)
                    .font(IslandTheme.rounded(11, .medium))
                    .foregroundColor(IslandTheme.critical)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.white.opacity(0.06)))
        .onDisappear { apiKey = "" }
    }

    /// 빠른 연속 클릭으로 같은 키가 두 번 저장되지 않게 먼저 잠근다.
    private func submit() {
        guard !isSubmitting else { return }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        isSubmitting = true
        errorText = nil
        Task {
            do {
                try await model.actions.addDeepSeek(label, key)
                apiKey = ""
                label = ""
                model.isAddingDeepSeek = false
                model.page = .usage
            } catch let failure as FetchFailure {
                if failure.loginTarget != nil {
                    errorText = "키가 올바르지 않아요. 다시 확인해 주세요."
                } else {
                    errorText = "저장하지 못했어요 · \(UsageFormat.failureText(failure, now: Date()))"
                }
            } catch {
                errorText = "저장하지 못했어요 · \(error.localizedDescription)"
            }
            isSubmitting = false
        }
    }
}

private struct IslandFieldStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(IslandTheme.rounded(12, .medium))
            .foregroundColor(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.white.opacity(0.1)))
    }
}
