import AppKit
import IslandUI
import ServiceManagement
import SwiftUI
import UsageCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let backgroundInterval: TimeInterval = 10 * 60

    private let settings = SettingsStore(path: SettingsStore.defaultPath)
    private let discovery = AccountDiscovery()
    private let locator = ToolLocator()
    private let runner = ProcessRunner()
    private let http = URLSessionHTTP()
    private lazy var keychain = SecurityKeychain(runner: runner)
    private var statusItem: NSStatusItem?
    private var store: UsageStore?
    private var controller: IslandPanelController?
    private var timer: Timer?
    private var loginWatch: Task<Void, Never>?

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let bundleID = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count > 1 {
            NSApp.terminate(nil)
            return
        }
        clearOldLoginScripts()

        let service = LiveAccountService.make(
            discovery: discovery,
            settings: settings,
            keychain: keychain,
            http: http,
            runner: runner,
            locator: locator
        )
        let store = UsageStore(service: service, hiddenAccountIDs: Set(settings.load().hiddenAccountIDs))
        self.store = store

        let model = IslandModel(store: store, actions: makeActions(store: store), geometry: IslandGeometry())
        let controller = IslandPanelController(model: model)
        self.controller = controller

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = PromptGlyph.statusImage()
            button.imagePosition = .imageOnly
            button.toolTip = "UsageIsland"
            button.target = self
            button.action = #selector(statusItemClicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        enableLoginItemOnFirstRun()
        Task { await store.refresh() }
        timer = Timer.scheduledTimer(withTimeInterval: Self.backgroundInterval, repeats: true) { _ in
            Task { await store.refresh() }
        }
        timer?.tolerance = 60
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            Task { await store.refreshIfStale(maxAge: 120) }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak controller] _ in
            MainActor.assumeIsolated { controller?.close() }
        }

        if CommandLine.arguments.contains("--open") {
            // 아이콘이 메뉴바에 자리 잡은 뒤에 연다.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak controller, weak item] in
                MainActor.assumeIsolated { controller?.open(from: item?.button) }
            }
        }
        #if DEBUG
        if let index = CommandLine.arguments.firstIndex(of: "--verify"), index + 1 < CommandLine.arguments.count {
            runVerification(directory: CommandLine.arguments[index + 1], model: model)
        }
        #endif
    }

    #if DEBUG
    /// 실제 창과 메뉴바 버튼으로 표시·경쟁 상황을 점검하는 개발용 경로. 설치본에는 포함되지 않는다.
    private func runVerification(directory: String, model: IslandModel) {
        func sleep(_ seconds: Double) async {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        func click() { statusItem?.button?.performClick(nil) }
        func report(_ label: String) { print("[\(label)] \(controller?.debugState ?? "-")"); fflush(stdout) }
        controller?.debugIgnoresOutsideClicks = true
        Task { @MainActor in
            await sleep(1)
            let button = statusItem?.button
            let iconRect = button.flatMap { button in button.window?.convertToScreen(button.convert(button.bounds, to: nil)) }
            print("statusButton image=\(button?.image != nil) screen=\(button?.window?.screen?.localizedName ?? "-") screenFrame=\(button?.window?.screen?.frame ?? .zero) icon=\(iconRect ?? .zero)")

            click()
            await sleep(6)
            report("single click opens")
            controller?.debugRender(to: directory + "/real-usage.png")

            model.page = .settings
            await sleep(0.6)
            controller?.debugRender(to: directory + "/real-settings.png")
            model.isAddingDeepSeek = true
            await sleep(1.2)
            report("settings with form")
            controller?.debugRender(to: directory + "/real-form.png")
            model.isAddingDeepSeek = false
            model.page = .usage
            await sleep(0.6)

            click()
            await sleep(1)
            report("second click hides")

            for _ in 0..<9 {
                click()
                await sleep(0.015)
            }
            await sleep(1)
            report("9 rapid clicks end open")

            click()
            await sleep(0.1)
            click()
            await sleep(1)
            report("reopen during close stays open")

            controller?.close()
            controller?.close()
            await sleep(1)
            report("double close hides")

            click()
            model.actions.refresh()
            model.actions.refresh()
            await sleep(0.05)
            click()
            await sleep(1)
            report("refresh while toggling hides")
            print("rows=\(store?.visibleRows.count ?? -1) refreshing=\(store?.isRefreshing ?? false)")
            fflush(stdout)
            NSApp.terminate(nil)
        }
    }
    #endif

    @objc private func statusItemClicked() {
        controller?.toggle(from: statusItem?.button)
    }

    private func makeActions(store: UsageStore) -> IslandActions {
        let settings = self.settings
        let manager = DeepSeekAccountManager(
            settings: settings,
            keychain: keychain,
            fetcher: DeepSeekFetcher(keychain: keychain, http: http)
        )
        return IslandActions(
            refresh: {
                Task { await store.refresh() }
            },
            openLogin: { [weak self] target in
                self?.openLogin(target)
            },
            addAccount: { [weak self] provider in
                guard let self else { return }
                switch provider {
                case .claude:
                    self.openLogin(.claude(configDir: self.discovery.nextConfigDir(prefix: ".claude")))
                case .codex:
                    self.openLogin(.codex(home: self.discovery.nextConfigDir(prefix: ".codex")))
                case .deepseek:
                    break
                }
            },
            addDeepSeek: { label, apiKey in
                _ = try await manager.add(label: label, apiKey: apiKey)
                await store.refreshAfterChange()
            },
            removeDeepSeek: { accountID in
                store.forget(accountID: accountID)
                Task {
                    await manager.remove(id: String(accountID.dropFirst("deepseek:".count)))
                }
            },
            setHidden: { hidden, accountID in
                store.setHidden(hidden, accountID: accountID)
                var current = settings.load()
                current.hiddenAccountIDs = Array(store.hiddenAccountIDs).sorted()
                settings.save(current)
                if !hidden {
                    Task { await store.refreshAfterChange() }
                }
            },
            isLoginItemEnabled: {
                SMAppService.mainApp.status == .enabled
            },
            setLoginItemEnabled: { enabled in
                do {
                    if enabled {
                        try SMAppService.mainApp.register()
                    } else {
                        try SMAppService.mainApp.unregister()
                    }
                } catch {
                    NSLog("UsageIsland login item change failed: %@", error.localizedDescription)
                }
                return SMAppService.mainApp.status == .enabled
            },
            quit: {
                NSApp.terminate(nil)
            }
        )
    }

    /// 메뉴바 앱은 항상 떠 있어야 쓸모가 있어 첫 실행에 한 번만 켠다. 설정에서 끌 수 있다.
    private func enableLoginItemOnFirstRun() {
        var current = settings.load()
        guard !current.loginItemInitialized else { return }
        do {
            try SMAppService.mainApp.register()
        } catch {
            NSLog("UsageIsland login item registration failed: %@", error.localizedDescription)
        }
        current.loginItemInitialized = true
        settings.save(current)
    }

    private var loginScriptDirectory: String {
        (SettingsStore.defaultPath as NSString).deletingLastPathComponent + "/login"
    }

    private func clearOldLoginScripts() {
        try? FileManager.default.removeItem(atPath: loginScriptDirectory)
    }

    /// 로그인은 브라우저 승인이 필요해 터미널 창으로 넘기고, 끝나면 자동으로 다시 읽는다.
    private func openLogin(_ target: LoginTarget) {
        guard let text = LoginScript.text(for: target, claude: locator.find("claude"), codex: locator.find("codex")) else {
            NSSound.beep()
            return
        }
        let path = loginScriptDirectory + "/login-\(UUID().uuidString).command"
        do {
            try FileManager.default.createDirectory(atPath: loginScriptDirectory, withIntermediateDirectories: true)
            try text.write(toFile: path, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
        } catch {
            NSLog("UsageIsland login script failed: %@", error.localizedDescription)
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
        controller?.close()
        loginWatch?.cancel()
        if let store {
            loginWatch = Task { await store.watchAfterLogin() }
        }
    }
}
