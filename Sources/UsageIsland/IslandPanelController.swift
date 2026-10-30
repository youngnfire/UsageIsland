import AppKit
import Combine
import IslandUI
import SwiftUI
import UsageCore

final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// 그림자 여백이 화면 끝을 넘어도 시스템이 창을 옮기지 못하게 한다.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }

    /// 메인 메뉴가 없는 앱이라 입력칸의 복사·붙여넣기 단축키를 직접 처리한다.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        let selector: Selector?
        switch event.charactersIgnoringModifiers {
        case "v": selector = #selector(NSText.paste(_:))
        case "c": selector = #selector(NSText.copy(_:))
        case "x": selector = #selector(NSText.cut(_:))
        case "a": selector = #selector(NSText.selectAll(_:))
        default: selector = nil
        }
        if let selector, NSApp.sendAction(selector, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}

@MainActor
final class IslandPanelController {
    private static let windowWidth: CGFloat = IslandGeometry.expandedWidth + 80
    private static let bottomMargin: CGFloat = 56
    private static let closeDuration: TimeInterval = 0.42
    /// 섬이 화면 끝에서 떨어지는 최소 거리.
    private static let screenMargin: CGFloat = 10

    private let panel: IslandPanel
    private let model: IslandModel
    private var presentation = IslandPresentation()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var heightObserver: AnyCancellable?
    private var shrinkWork: DispatchWorkItem?
    private var screen: NSScreen?
    private var islandMidX: CGFloat = 0
    /// 창 위쪽 끝. 아이콘 바로 아래라서 창이 메뉴바를 덮지 않고, 아이콘 클릭이 그대로 토글로 간다.
    private var windowTopY: CGFloat = 0

    init(model: IslandModel) {
        self.model = model
        panel = IslandPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: 400),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        // isFloatingPanel은 레벨을 덮어쓰므로 레벨보다 먼저 지정한다.
        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 1)
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.isMovable = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .none

        let host = NSHostingView(rootView: IslandRootView(model: model))
        host.sizingOptions = []
        panel.contentView = host

        heightObserver = model.$contentHeight
            .removeDuplicates()
            .sink { [weak self] height in
                MainActor.assumeIsolated { self?.fit(contentHeight: height) }
            }
    }

    var isOpen: Bool { presentation.isExpanded }

    func toggle(from button: NSStatusBarButton?) {
        switch presentation.toggle() {
        case .open: show(from: button)
        case .close(let generation): hide(generation: generation)
        case .none: break
        }
    }

    func open(from button: NSStatusBarButton?) {
        if presentation.open() == .open { show(from: button) }
    }

    func close() {
        if case .close(let generation) = presentation.close() { hide(generation: generation) }
    }

    private func show(from button: NSStatusBarButton?) {
        shrinkWork?.cancel()
        let wasVisible = panel.isVisible
        let screen = button?.window?.screen ?? NSScreen.main ?? NSScreen.screens[0]
        self.screen = screen

        let anchor = button
            .flatMap(Self.screenRect(of:))
            .flatMap { IslandPlacement.usableAnchor($0, in: screen.frame) }
        let anchorMidX = anchor?.midX ?? screen.frame.midX
        islandMidX = IslandPlacement.midX(
            anchorMidX: anchorMidX,
            width: IslandGeometry.expandedWidth,
            screenMinX: screen.frame.minX,
            screenMaxX: screen.frame.maxX,
            margin: Self.screenMargin
        )
        windowTopY = anchor?.minY ?? screen.visibleFrame.maxY
        model.geometry.anchorOffset = anchorMidX - islandMidX

        if !wasVisible {
            model.isExpanded = false
        }
        place(height: windowHeight(for: model.contentHeight))
        panel.orderFrontRegardless()
        panel.makeKey()
        installMonitors()
        // 접힌 첫 프레임을 그린 뒤에 펼쳐야 알약에서 커지는 움직임이 보인다.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                // 그 사이 닫혔다면 다시 펼치지 않는다.
                guard let self, self.presentation.isExpanded else { return }
                self.model.isExpanded = true
            }
        }
        Task { await model.store.refreshIfStale(maxAge: 60) }
    }

    private static func screenRect(of button: NSStatusBarButton) -> NSRect? {
        guard let window = button.window else { return nil }
        return window.convertToScreen(button.convert(button.bounds, to: nil))
    }

    private func hide(generation: Int) {
        model.isExpanded = false
        removeMonitors()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.closeDuration) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.presentation.closeAnimationFinished(generation: generation) else { return }
                self.panel.orderOut(nil)
                self.model.page = .usage
                self.model.isAddingDeepSeek = false
            }
        }
    }

    private func windowHeight(for contentHeight: CGFloat) -> CGFloat {
        let limit = windowTopY - (screen?.frame.minY ?? 0)
        return min(limit, IslandGeometry.topInset + contentHeight + Self.bottomMargin)
    }

    private func place(height: CGFloat) {
        let frame = NSRect(
            x: islandMidX - Self.windowWidth / 2,
            y: windowTopY - height,
            width: Self.windowWidth,
            height: height
        )
        panel.setFrame(frame, display: true)
    }

    /// 커질 때는 바로 키우고, 줄어들 때는 애니메이션이 끝난 뒤 줄여 잘리지 않게 한다.
    private func fit(contentHeight: CGFloat) {
        guard panel.isVisible else { return }
        shrinkWork?.cancel()
        let height = windowHeight(for: contentHeight)
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.place(height: height) }
        }
        shrinkWork = work
        // 값 변경 콜백 안에서 창 크기를 바꾸면 SwiftUI 갱신이 묻혀 섬이 커지지 않아 다음 순환으로 미룬다.
        let delay: TimeInterval = height >= panel.frame.height ? 0 : 0.5
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    /// 창 좌표에서 지금 보이는 섬의 영역.
    private var islandRect: NSRect {
        let width = IslandGeometry.expandedWidth
        let height = panel.frame.height
        return NSRect(
            x: (panel.frame.width - width) / 2,
            y: height - IslandGeometry.topInset - model.contentHeight,
            width: width,
            height: model.contentHeight
        )
    }

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated {
                #if DEBUG
                if self?.debugIgnoresOutsideClicks == true { return }
                #endif
                self?.close()
            }
        }
        let panel = self.panel
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            let isEscape = event.type == .keyDown && event.keyCode == 53
            // 메뉴바 아이콘 클릭은 토글이 처리한다. 섬 바깥 투명 영역 클릭만 닫는다.
            let clickInPanel = event.type != .keyDown && event.window === panel
            let location = event.locationInWindow
            let shouldClose = MainActor.assumeIsolated {
                guard let self else { return false }
                let closes = isEscape || (clickInPanel && !self.islandRect.contains(location))
                if closes { self.close() }
                return closes
            }
            return shouldClose ? nil : event
        }
    }

    private func removeMonitors() {
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor) }
        if let localMonitor { NSEvent.removeMonitor(localMonitor) }
        globalMonitor = nil
        localMonitor = nil
    }

    #if DEBUG
    /// 점검 중에 맥을 쓰는 사람의 실제 클릭이 결과를 흔들지 않게 한다.
    var debugIgnoresOutsideClicks = false

    var debugState: String {
        "phase=\(presentation.phase) visible=\(panel.isVisible) expanded=\(model.isExpanded) level=\(panel.level.rawValue) frame=\(panel.frame) content=\(model.contentHeight) islandMidX=\(islandMidX) anchorOffset=\(model.geometry.anchorOffset)"
    }

    func debugRender(to path: String) {
        guard let view = panel.contentView, let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        if let png = bitmap.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: path))
        }
    }
    #endif
}
