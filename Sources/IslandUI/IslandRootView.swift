import SwiftUI
import UsageCore

private struct ContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

public struct IslandRootView: View {
    @ObservedObject private var model: IslandModel
    @ObservedObject private var store: UsageStore

    private static let spring = Animation.spring(response: 0.46, dampingFraction: 0.76)

    public init(model: IslandModel) {
        self.model = model
        self.store = model.store
    }

    public var body: some View {
        let expanded = model.isExpanded
        let collapsed = IslandGeometry.collapsedSize
        let shape = RoundedRectangle(cornerRadius: expanded ? 34 : collapsed.height / 2, style: .continuous)

        // 아이콘 바로 아래의 작은 알약에서 펼쳐지는 검은 섬.
        VStack(spacing: 0) {
            content
                .frame(width: IslandGeometry.expandedWidth)
                .fixedSize(horizontal: false, vertical: true)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: ContentHeightKey.self, value: proxy.size.height)
                })
                .opacity(expanded ? 1 : 0)
                .blur(radius: expanded ? 0 : 12)
                .scaleEffect(expanded ? 1 : 0.86, anchor: .top)
                .animation(.easeOut(duration: expanded ? 0.32 : 0.14).delay(expanded ? 0.06 : 0), value: expanded)
                .frame(
                    width: expanded ? IslandGeometry.expandedWidth : collapsed.width,
                    height: expanded ? model.contentHeight : collapsed.height,
                    alignment: .top
                )
                .clipShape(shape)
                .background(
                    // 창 위쪽 여백이 좁아 그림자가 위로 많이 번지면 잘린다.
                    shape
                        .fill(Color.black)
                        .shadow(color: .black.opacity(expanded ? 0.5 : 0), radius: 20, y: 14)
                )
                .overlay(shape.stroke(Color.white.opacity(0.09), lineWidth: 0.5))
                .offset(x: expanded ? 0 : model.geometry.anchorOffset)
                .animation(Self.spring, value: expanded)
                .animation(Self.spring, value: model.contentHeight)
                // 안쪽 애니메이션이 우선하므로 크기는 위의 스프링을, 투명도만 아래 곡선을 따른다.
                .opacity(expanded ? 1 : 0)
                .animation(expanded ? .easeOut(duration: 0.12) : .easeIn(duration: 0.18).delay(0.22), value: expanded)
            Spacer(minLength: 0)
        }
        .padding(.top, IslandGeometry.topInset)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onPreferenceChange(ContentHeightKey.self) { height in
            if height > 0 { model.contentHeight = height }
        }
        .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private var content: some View {
        if let fixed = model.fixedNow {
            page(now: fixed)
        } else {
            TimelineView(.periodic(from: Date(), by: 30)) { context in
                page(now: context.date)
            }
        }
    }

    private func page(now: Date) -> some View {
        Group {
            switch model.page {
            case .usage:
                UsagePage(model: model, store: store, now: now)
                    .transition(.opacity)
            case .settings:
                SettingsPage(model: model, store: store)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: model.page)
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 16)
    }
}

struct CircleIconButton: View {
    let systemName: String
    var isDisabled = false
    var spinning = false
    let action: () -> Void
    @State private var angle: Double = 0

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.white.opacity(isDisabled ? 0.4 : 0.85))
                .rotationEffect(.degrees(angle))
                .frame(width: 26, height: 26)
                .background(Circle().fill(Color.white.opacity(0.13)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onChange(of: spinning) { _, isSpinning in
            if isSpinning {
                withAnimation(.linear(duration: 0.9).repeatForever(autoreverses: false)) { angle = 360 }
            } else {
                withAnimation(.easeOut(duration: 0.15)) { angle = 0 }
            }
        }
    }
}

struct CapsuleButton: View {
    let title: String
    var tint: Color = .white
    var isDisabled = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(IslandTheme.rounded(11, .bold))
                .foregroundColor(isDisabled ? .white.opacity(0.4) : tint)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(tint.opacity(isDisabled ? 0.08 : 0.18)))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}
