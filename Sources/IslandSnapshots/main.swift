// 패널 모습을 PNG로 뽑아 눈으로 확인하는 개발용 도구. 실제 계정·네트워크를 쓰지 않는다.
import AppKit
import IslandUI
import SwiftUI
import UsageCore

struct SampleService: AccountServicing {
    let now: Date

    func discover() async -> [Account] {
        [
            Account(id: "c1", provider: .claude, title: "work@example.com", source: .claude(logins: [])),
            Account(id: "c2", provider: .claude, title: "personal@example.com", source: .claude(logins: [])),
            Account(id: "x1", provider: .codex, title: "work@example.com", source: .codex(home: "/h")),
            Account(id: "d1", provider: .deepseek, title: "회사 키", source: .deepseek(keychainService: "s")),
        ]
    }

    func fetch(_ account: Account) async throws -> UsageSnapshot {
        switch account.id {
        case "c1":
            return UsageSnapshot(
                windows: [
                    UsageWindow(id: "session", label: "5시간", usedPercent: 2, resetsAt: now.addingTimeInterval(3 * 3600 + 52 * 60)),
                    UsageWindow(id: "weekly", label: "주간", usedPercent: 49, resetsAt: now.addingTimeInterval(4 * 86400 + 5 * 3600)),
                    UsageWindow(id: "fable", label: "Fable", usedPercent: 72, resetsAt: now.addingTimeInterval(4 * 86400 + 5 * 3600)),
                ],
                detail: "Max 20x",
                fetchedAt: now
            )
        case "c2":
            return UsageSnapshot(
                windows: [
                    UsageWindow(id: "session", label: "5시간", usedPercent: 18, resetsAt: now.addingTimeInterval(1 * 3600 + 20 * 60)),
                    UsageWindow(id: "weekly", label: "주간", usedPercent: 63, resetsAt: now.addingTimeInterval(2 * 86400 + 10 * 3600)),
                ],
                detail: "Max 5x",
                fetchedAt: now
            )
        case "x1":
            return UsageSnapshot(
                windows: [UsageWindow(id: "primary", label: "주간", usedPercent: 94, resetsAt: now.addingTimeInterval(4 * 86400 + 21 * 3600))],
                detail: "Pro · 크레딧 2,656",
                fetchedAt: now
            )
        default:
            return UsageSnapshot(balances: [MoneyBalance(currency: "CNY", total: 110)], isAvailable: true, fetchedAt: now)
        }
    }
}

@MainActor
func render(_ model: IslandModel, name: String, directory: String) {
    let view = ZStack(alignment: .top) {
        LinearGradient(colors: [Color(red: 0.32, green: 0.42, blue: 0.62), Color(red: 0.72, green: 0.62, blue: 0.70)], startPoint: .top, endPoint: .bottom)
        Rectangle().fill(Color.white.opacity(0.28)).frame(height: 24)
        IslandRootView(model: model).padding(.top, 24)
    }
    .frame(width: 620, height: 520)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    guard let image = renderer.nsImage, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) else {
        print("render failed: \(name)")
        return
    }
    let path = directory + "/" + name + ".png"
    try? png.write(to: URL(fileURLWithPath: path))
    print(path)
}

@MainActor
func renderStatusIcon(directory: String) {
    let scale: CGFloat = 8
    let side = 18 * scale
    let canvas = NSImage(size: NSSize(width: side * 2 + 16, height: side + 8), flipped: false) { rect in
        NSColor(white: 0.95, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: rect.width / 2, height: rect.height).fill()
        NSColor(white: 0.12, alpha: 1).setFill()
        NSRect(x: rect.width / 2, y: 0, width: rect.width / 2, height: rect.height).fill()
        let glyph = PromptGlyph.statusImage(size: side)
        glyph.isTemplate = false
        glyph.draw(in: NSRect(x: 4, y: 4, width: side, height: side))
        let tinted = NSImage(size: glyph.size, flipped: false) { inner in
            glyph.draw(in: inner)
            NSColor.white.setFill()
            inner.fill(using: .sourceAtop)
            return true
        }
        tinted.draw(in: NSRect(x: rect.width / 2 + 4, y: 4, width: side, height: side))
        return true
    }
    if let tiff = canvas.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let png = bitmap.representation(using: .png, properties: [:]) {
        let path = directory + "/status-icon.png"
        try? png.write(to: URL(fileURLWithPath: path))
        print(path)
    }
}

/// 앱 아이콘 원본(.iconset)을 만든다.
@MainActor
func renderIconSet(directory: String) {
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for (name, side) in [
        ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ] {
        let renderer = ImageRenderer(content: AppIconView(size: CGFloat(side)))
        renderer.scale = 1
        renderer.isOpaque = false
        if let image = renderer.cgImage,
           let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: directory + "/" + name + ".png"))
        }
    }
}

/// 실제 계정으로 한 라운드를 돌려 결과를 출력하고 PNG로 남긴다. 토큰은 출력하지 않는다.
@MainActor
func runLive(directory: String, actions: IslandActions) async {
    let runner = ProcessRunner()
    let keychain = SecurityKeychain(runner: runner)
    let service = LiveAccountService.make(
        discovery: AccountDiscovery(),
        settings: SettingsStore(path: NSTemporaryDirectory() + "usageisland-live-\(UUID().uuidString).json"),
        keychain: keychain,
        http: URLSessionHTTP(),
        runner: runner,
        locator: ToolLocator()
    )
    let store = UsageStore(service: service)
    await store.refresh()
    for row in store.allRows {
        let windows = row.snapshot?.windows.map { "\($0.label)=\(UsageFormat.percent($0.remainingPercent))" } ?? []
        print(row.account.provider.displayName, row.account.title, row.snapshot?.detail ?? "-", windows, row.failure.map { "\($0)" } ?? "ok")
    }
    let model = IslandModel(store: store, actions: actions, geometry: IslandGeometry())
    model.fixedNow = Date()
    model.isExpanded = true
    model.contentHeight = 430
    render(model, name: "live", directory: directory)
}

@MainActor
func run() async {
    let arguments = Array(CommandLine.arguments.dropFirst())
    let now = Date(timeIntervalSince1970: 1_793_000_000)
    let actions = IslandActions(
        refresh: {}, openLogin: { _ in }, addAccount: { _ in }, addDeepSeek: { _, _ in }, removeDeepSeek: { _ in },
        setHidden: { _, _ in }, isLoginItemEnabled: { true }, setLoginItemEnabled: { $0 }, quit: {}
    )
    if arguments.first == "--icon" {
        renderIconSet(directory: arguments[1])
        return
    }
    if arguments.first == "--live" {
        await runLive(directory: arguments[1], actions: actions)
        return
    }
    if arguments.first == "--readme" {
        await renderReadmeShots(directory: arguments[1], actions: actions)
        return
    }
    let directory = arguments.first ?? NSTemporaryDirectory()

    let store = UsageStore(service: SampleService(now: now), clock: { now })
    await store.refresh()
    let model = IslandModel(store: store, actions: actions, geometry: IslandGeometry())
    model.fixedNow = now
    model.isExpanded = true
    model.contentHeight = 430
    render(model, name: "island", directory: directory)
    renderStatusIcon(directory: directory)
}

/// 실제 패널과 같은 NSHostingView를 표본 계정으로 그려 README 이미지를 만든다.
/// 개인 이메일과 잔액이 공개 저장소에 올라가지 않도록 실제 계정은 쓰지 않는다.
@MainActor
func renderReadmeShots(directory: String, actions: IslandActions) async {
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    let now = Date(timeIntervalSince1970: 1_793_000_000)
    let store = UsageStore(service: SampleService(now: now), clock: { now })
    await store.refresh()
    let model = IslandModel(store: store, actions: actions, geometry: IslandGeometry())
    model.fixedNow = now
    model.isExpanded = true

    let window = NSWindow(contentRect: NSRect(x: -20000, y: -20000, width: 566, height: 500), styleMask: .borderless, backing: .buffered, defer: false)
    window.isOpaque = false
    window.backgroundColor = .clear
    let host = NSHostingView(rootView: IslandRootView(model: model))
    host.sizingOptions = []
    window.contentView = host
    window.orderFrontRegardless()

    func capture(_ name: String) async {
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let panel = NSImage(size: host.bounds.size)
        panel.addRepresentation(bitmap)
        composeOnDesktop(panel: panel, height: model.contentHeight, path: directory + "/" + name + ".png")
    }

    await capture("usage")
    model.page = .settings
    await capture("settings")
    window.orderOut(nil)
}

/// 바탕화면과 메뉴바를 깔고 아이콘 바로 아래에 패널을 놓는다.
@MainActor
func composeOnDesktop(panel: NSImage, height: CGFloat, path: String) {
    let canvas = NSSize(width: 760, height: height + 92)
    let menuBar: CGFloat = 26
    let iconMidX = canvas.width - 290
    let image = NSImage(size: canvas, flipped: false) { rect in
        NSGradient(starting: NSColor(red: 0.72, green: 0.62, blue: 0.70, alpha: 1), ending: NSColor(red: 0.32, green: 0.42, blue: 0.62, alpha: 1))?
            .draw(in: rect, angle: 90)
        NSColor(white: 0.08, alpha: 0.55).setFill()
        NSRect(x: 0, y: rect.height - menuBar, width: rect.width, height: menuBar).fill()

        let icon = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { inner in
            PromptGlyph.statusImage().draw(in: inner)
            NSColor.white.setFill()
            inner.fill(using: .sourceAtop)
            return true
        }
        icon.draw(in: NSRect(x: iconMidX - 9, y: rect.height - menuBar + 4, width: 18, height: 18))

        panel.draw(in: NSRect(
            x: iconMidX - panel.size.width / 2,
            y: rect.height - menuBar - panel.size.height,
            width: panel.size.width,
            height: panel.size.height
        ))
        return true
    }
    let target = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(canvas.width * 2), pixelsHigh: Int(canvas.height * 2),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )
    guard let target else { return }
    target.size = canvas
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: target)
    image.draw(in: NSRect(origin: .zero, size: canvas))
    NSGraphicsContext.restoreGraphicsState()
    if let png = target.representation(using: .png, properties: [:]) {
        try? png.write(to: URL(fileURLWithPath: path))
        print(path)
    }
}

// 창을 실제로 그리려면 메인 런루프가 돌아야 한다.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
Task { @MainActor in
    await run()
    exit(0)
}
application.run()
