import AppKit
import ServiceManagement

// 자동 실행 등록 상태만 출력하고 끝낸다. 설정 화면 없이 진단할 때 쓴다.
if CommandLine.arguments.contains("--login-item-status") {
    let names: [SMAppService.Status: String] = [
        .notRegistered: "notRegistered",
        .enabled: "enabled",
        .requiresApproval: "requiresApproval",
        .notFound: "notFound",
    ]
    print(names[SMAppService.mainApp.status] ?? "unknown")
    exit(0)
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    withExtendedLifetime(delegate) {
        app.run()
    }
}
