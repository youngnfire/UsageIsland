import Foundation

public enum CodexUsageParser {
    public static func parse(rateLimitsResult data: Data, now: Date, in language: AppLanguage = .current) throws -> UsageSnapshot {
        guard
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let limits = root["rateLimits"] as? [String: Any]
        else {
            throw FetchFailure.unexpectedResponse("Codex response has no rate limits")
        }

        var windows: [UsageWindow] = []
        if let window = window(limits["primary"], id: "primary", label: nil, in: language) { windows.append(window) }
        if let window = window(limits["secondary"], id: "secondary", label: nil, in: language) { windows.append(window) }

        let baseID = limits["limitId"] as? String
        let others = root["rateLimitsByLimitId"] as? [String: [String: Any]] ?? [:]
        for (id, limit) in others.sorted(by: { $0.key < $1.key }) where id != baseID {
            let name = limit["limitName"] as? String ?? id
            if let window = window(limit["primary"], id: "limit-\(id)", label: name, in: language) { windows.append(window) }
        }

        let plan = UsageFormat.plan(subscription: limits["planType"] as? String, tier: nil)
        let credits = creditsText(limits["credits"], in: language)
        guard !windows.isEmpty || credits != nil else {
            throw FetchFailure.unexpectedResponse("Codex response has no usage windows")
        }
        let detail = [plan, credits].compactMap { $0 }.joined(separator: " · ")
        return UsageSnapshot(windows: windows, detail: detail.isEmpty ? nil : detail, fetchedAt: now)
    }

    private static func window(_ value: Any?, id: String, label: String?, in language: AppLanguage) -> UsageWindow? {
        guard let dict = value as? [String: Any], let used = dict["usedPercent"] as? Double else { return nil }
        let minutes = dict["windowDurationMins"] as? Int
        return UsageWindow(
            id: id,
            label: label ?? minutes.map { UsageFormat.windowLabel(minutes: $0, in: language) } ?? language.pick("Limit", "한도"),
            usedPercent: used,
            resetsAt: (dict["resetsAt"] as? Double).map { Date(timeIntervalSince1970: $0) }
        )
    }

    private static func creditsText(_ value: Any?, in language: AppLanguage) -> String? {
        guard let credits = value as? [String: Any] else { return nil }
        if credits["unlimited"] as? Bool == true { return language.pick("Unlimited credits", "크레딧 무제한") }
        guard
            credits["hasCredits"] as? Bool == true,
            let text = credits["balance"] as? String,
            let balance = Decimal(string: text)
        else { return nil }
        return UsageFormat.credits(balance, in: language)
    }
}

/// Codex는 공식 `app-server`에 묻는다. 토큰 갱신도 Codex가 하므로 앱이 토큰을 다루지 않는다.
public struct CodexAppServerClient: Sendable {
    private let executable: String?
    private let timeout: TimeInterval
    private let clock: @Sendable () -> Date
    private let searchPath: String?

    public init(
        executable: String?,
        timeout: TimeInterval = 15,
        clock: @escaping @Sendable () -> Date = { Date() },
        searchPath: String? = nil
    ) {
        self.executable = executable
        self.timeout = timeout
        self.clock = clock
        self.searchPath = searchPath
    }

    public func fetch(home: String) async throws -> UsageSnapshot {
        guard let executable else { throw FetchFailure.toolMissing("codex") }
        _ = ChildEnvironment.ignoreSIGPIPE
        var environment = ["CODEX_HOME": home]
        if let searchPath { environment["PATH"] = searchPath }
        let session = AppServerSession(executable: executable, environment: environment, timeout: timeout)
        let replies = try await session.run()

        if let failure = Self.failure(in: replies[AppServerSession.accountID], home: home) { throw failure }
        let account = replies[AppServerSession.accountID]?["result"] as? [String: Any]
        guard account?["account"] is [String: Any] else {
            throw FetchFailure.loginRequired(.codex(home: home))
        }

        if let failure = Self.failure(in: replies[AppServerSession.rateLimitsID], home: home) { throw failure }
        guard
            let result = replies[AppServerSession.rateLimitsID]?["result"] as? [String: Any],
            let data = try? JSONSerialization.data(withJSONObject: result)
        else {
            throw FetchFailure.unexpectedResponse("Codex response has no rate limits")
        }
        return try CodexUsageParser.parse(rateLimitsResult: data, now: clock())
    }

    private static func failure(in reply: [String: Any]?, home: String) -> FetchFailure? {
        guard let error = reply?["error"] as? [String: Any] else { return nil }
        let message = error["message"] as? String ?? "Codex error"
        let lowered = message.lowercased()
        if ["auth", "login", "log in", "sign in"].contains(where: lowered.contains) {
            return .loginRequired(.codex(home: home))
        }
        if ["sending request", "timed out", "timeout", "connect", "network"].contains(where: lowered.contains) {
            return .network(message)
        }
        return .unexpectedResponse(message)
    }
}

/// `codex app-server`와 한 번 대화한다. 줄 단위 JSON-RPC이고 한 세션이 끝나면 프로세스를 내린다.
private final class AppServerSession: @unchecked Sendable {
    static let initializeID = 1
    static let accountID = 2
    static let rateLimitsID = 3

    private let queue = DispatchQueue(label: "UsageIsland.codex-app-server")
    private let process = Process()
    private let stdoutPipe = Pipe()
    private let stdinPipe = Pipe()
    private let timeout: TimeInterval
    private var buffer = Data()
    private var replies: [Int: [String: Any]] = [:]
    private var continuation: CheckedContinuation<[Int: [String: Any]], Error>?

    init(executable: String, environment: [String: String], timeout: TimeInterval) {
        self.timeout = timeout
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["-s", "read-only", "-a", "never", "app-server"]
        process.environment = ChildEnvironment.make(overrides: environment)
        process.currentDirectoryURL = URL(fileURLWithPath: NSTemporaryDirectory())
        process.standardOutput = stdoutPipe
        process.standardInput = stdinPipe
        process.standardError = FileHandle.nullDevice
    }

    func run() async throws -> [Int: [String: Any]] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { self.start(continuation) }
        }
    }

    private func start(_ continuation: CheckedContinuation<[Int: [String: Any]], Error>) {
        self.continuation = continuation
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.queue.async { self?.receive(data) }
        }
        process.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.finish(.failure(FetchFailure.network("Codex exited before responding"))) }
        }
        do {
            try process.run()
        } catch {
            finish(.failure(FetchFailure.toolMissing("codex")))
            return
        }
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.finish(.failure(FetchFailure.network("Codex response timed out")))
        }
        send([
            "id": Self.initializeID,
            "method": "initialize",
            "params": ["clientInfo": ["name": "usage_island", "title": "UsageIsland", "version": "1.0.0"]],
        ])
    }

    private func receive(_ data: Data) {
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer = Data(buffer[buffer.index(after: newline)...])
            if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
                handle(message)
            }
        }
    }

    private func handle(_ message: [String: Any]) {
        guard let id = message["id"] as? Int else { return }
        if id == Self.initializeID {
            send(["method": "initialized", "params": [String: Any]()])
            send(["id": Self.accountID, "method": "account/read", "params": ["refreshToken": false]])
            send(["id": Self.rateLimitsID, "method": "account/rateLimits/read"])
            return
        }
        replies[id] = message
        if replies[Self.accountID] != nil, replies[Self.rateLimitsID] != nil {
            finish(.success(replies))
        }
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message, options: .withoutEscapingSlashes) else { return }
        data.append(0x0A)
        try? stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func finish(_ result: Result<[Int: [String: Any]], Error>) {
        guard let pending = continuation else { return }
        continuation = nil
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        try? stdinPipe.fileHandleForWriting.close()
        if process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [process] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
        pending.resume(with: result)
    }
}
