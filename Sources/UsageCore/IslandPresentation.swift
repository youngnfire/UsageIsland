import CoreGraphics
import Foundation

/// 섬의 가로 위치. 아이콘 바로 아래에 맞추되 화면 밖으로 나가면 안쪽으로 민다.
public enum IslandPlacement {
    public static func midX(
        anchorMidX: CGFloat,
        width: CGFloat,
        screenMinX: CGFloat,
        screenMaxX: CGFloat,
        margin: CGFloat
    ) -> CGFloat {
        let lowest = screenMinX + margin + width / 2
        let highest = screenMaxX - margin - width / 2
        guard lowest <= highest else { return (screenMinX + screenMaxX) / 2 }
        return min(highest, max(lowest, anchorMidX))
    }

    /// 메뉴바에 아직 자리 잡지 못했거나 화면 밖으로 밀려난 아이콘 위치는 쓰지 않는다.
    public static func usableAnchor(_ icon: CGRect, in screen: CGRect) -> CGRect? {
        let maxMenuBarHeight: CGFloat = 64
        guard
            icon.width > 0,
            icon.height > 0,
            icon.midX >= screen.minX,
            icon.midX <= screen.maxX,
            icon.midY >= screen.maxY - maxMenuBarHeight,
            icon.midY <= screen.maxY
        else { return nil }
        return icon
    }
}

/// 패널 표시 상태. 빠른 연속 클릭에서 지난 닫기 애니메이션이 다시 연 패널을 숨기지 않게 세대를 센다.
public struct IslandPresentation: Equatable, Sendable {
    public enum Phase: Equatable, Sendable { case hidden, open, closing }
    public enum Effect: Equatable, Sendable { case none, open, close(generation: Int) }

    public private(set) var phase: Phase = .hidden
    private var generation = 0

    public init() {}

    public var isExpanded: Bool { phase == .open }

    public mutating func toggle() -> Effect {
        phase == .open ? close() : open()
    }

    public mutating func open() -> Effect {
        guard phase != .open else { return .none }
        generation += 1
        phase = .open
        return .open
    }

    public mutating func close() -> Effect {
        guard phase == .open else { return .none }
        generation += 1
        phase = .closing
        return .close(generation: generation)
    }

    /// 창을 실제로 숨겨도 되면 true.
    public mutating func closeAnimationFinished(generation finished: Int) -> Bool {
        guard phase == .closing, finished == generation else { return false }
        phase = .hidden
        return true
    }
}
