import Foundation

public struct CommandResult: Equatable, Sendable {
    public let status: Int32
    public let stdout: Data
    public let stderr: Data

    public init(status: Int32, stdout: Data, stderr: Data) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }
}

public enum CommandError: Error, Equatable {
    case timedOut
    case launchFailed(String)
}

public protocol CommandRunning: Sendable {
    func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]?,
        stdin: Data?,
        directory: String?,
        timeout: TimeInterval
    ) async throws -> CommandResult
}

enum ChildEnvironment {
    /// 계정을 가리키는 변수는 물려받지 않는다. 호출자가 명시한 값만 쓴다.
    static func make(overrides: [String: String]?) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        for name in ["CLAUDE_CONFIG_DIR", "CODEX_HOME", "CLAUDECODE"] {
            environment[name] = nil
        }
        environment.merge(overrides ?? [:]) { _, new in new }
        return environment
    }

    /// 죽은 자식의 파이프에 쓸 때 앱 전체가 SIGPIPE로 죽지 않게 한다.
    static let ignoreSIGPIPE: Void = {
        signal(SIGPIPE, SIG_IGN)
    }()
}

public struct ProcessRunner: CommandRunning {
    public init() {}

    public func run(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]?,
        stdin: Data?,
        directory: String?,
        timeout: TimeInterval
    ) async throws -> CommandResult {
        _ = ChildEnvironment.ignoreSIGPIPE
        return try await withCheckedThrowingContinuation { continuation in
            let session = RunningCommand(continuation: continuation)
            session.start(executable, arguments, environment: environment, stdin: stdin, directory: directory, timeout: timeout)
        }
    }
}

private final class RunningCommand: @unchecked Sendable {
    private let process = Process()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private let inPipe = Pipe()
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private var timedOut = false
    private var continuation: CheckedContinuation<CommandResult, Error>?

    init(continuation: CheckedContinuation<CommandResult, Error>) {
        self.continuation = continuation
    }

    func start(
        _ executable: String,
        _ arguments: [String],
        environment: [String: String]?,
        stdin: Data?,
        directory: String?,
        timeout: TimeInterval
    ) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ChildEnvironment.make(overrides: environment)
        if let directory {
            process.currentDirectoryURL = URL(fileURLWithPath: directory)
        }
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = inPipe

        outPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData, toError: false)
        }
        errPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.append(handle.availableData, toError: true)
        }
        process.terminationHandler = { [self] _ in finish() }

        do {
            try process.run()
        } catch {
            outPipe.fileHandleForReading.readabilityHandler = nil
            errPipe.fileHandleForReading.readabilityHandler = nil
            resume(with: .failure(CommandError.launchFailed(error.localizedDescription)))
            return
        }

        DispatchQueue.global().async { [inPipe] in
            if let stdin {
                try? inPipe.fileHandleForWriting.write(contentsOf: stdin)
            }
            try? inPipe.fileHandleForWriting.close()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [self] in
            guard process.isRunning else { return }
            lock.lock(); timedOut = true; lock.unlock()
            process.terminate()
            let pid = process.processIdentifier
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [process] in
                if process.isRunning { kill(pid, SIGKILL) }
            }
        }
    }

    private func append(_ data: Data, toError: Bool) {
        lock.lock(); defer { lock.unlock() }
        if toError {
            err.append(data)
        } else {
            out.append(data)
        }
    }

    private func finish() {
        outPipe.fileHandleForReading.readabilityHandler = nil
        errPipe.fileHandleForReading.readabilityHandler = nil
        // 손자 프로세스가 파이프를 쥐고 있어도 멈추지 않게 논블로킹으로 남은 출력만 비운다.
        append(Self.drain(outPipe.fileHandleForReading), toError: false)
        append(Self.drain(errPipe.fileHandleForReading), toError: true)
        lock.lock()
        let result = CommandResult(status: process.terminationStatus, stdout: out, stderr: err)
        let didTimeOut = timedOut
        lock.unlock()
        resume(with: didTimeOut ? .failure(CommandError.timedOut) : .success(result))
    }

    private func resume(with result: Result<CommandResult, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }

    private static func drain(_ handle: FileHandle) -> Data {
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count <= 0 { break }
            data.append(contentsOf: buffer[0..<count])
        }
        return data
    }
}

/// GUI 앱은 셸 PATH를 물려받지 않아 CLI 위치를 직접 찾는다.
public struct ToolLocator: Sendable {
    public let home: String
    public let extraDirs: [String]

    public init(home: String = NSHomeDirectory(), extraDirs: [String] = ["/opt/homebrew/bin", "/usr/local/bin"]) {
        self.home = home
        self.extraDirs = extraDirs
    }

    private var searchDirs: [String] {
        [home + "/.local/bin", home + "/.claude/local", home + "/.bun/bin", home + "/.npm-global/bin"] + extraDirs
    }

    public func find(_ tool: String) -> String? {
        searchDirs
            .map { $0 + "/" + tool }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public var path: String {
        (searchDirs + ["/usr/bin", "/bin", "/usr/sbin", "/sbin"]).joined(separator: ":")
    }
}

/// `/usr/bin/security`로만 키체인을 다룬다. Claude Code 항목은 이 도구에 접근이 열려 있어
/// 승인 창이 뜨지 않고, 앱이 만드는 항목도 같은 이유로 재빌드 뒤에 승인 창이 뜨지 않는다.
public struct SecurityKeychain: KeychainStoring {
    static let tool = "/usr/bin/security"
    private let runner: CommandRunning

    public init(runner: CommandRunning) {
        self.runner = runner
    }

    public func read(service: String) async -> String? {
        guard
            let result = try? await runner.run(
                Self.tool, ["find-generic-password", "-s", service, "-w"],
                environment: nil, stdin: nil, directory: nil, timeout: 10
            ),
            result.status == 0
        else { return nil }
        let value = String(decoding: result.stdout, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// 비밀값은 프로세스 인자에 노출되지 않도록 stdin으로, 이스케이프가 필요 없도록 16진수로 넘긴다.
    public func write(service: String, value: String) async throws {
        let hex = Data(value.utf8).map { String(format: "%02x", $0) }.joined()
        let script = "add-generic-password -U -a UsageIsland -s \(service) -X \(hex)\n"
        let result = try await runner.run(
            Self.tool, ["-i"],
            environment: nil, stdin: Data(script.utf8), directory: nil, timeout: 10
        )
        guard result.status == 0, await read(service: service) == value else {
            throw FetchFailure.unexpectedResponse("Keychain save failed")
        }
    }

    public func delete(service: String) async {
        _ = try? await runner.run(
            Self.tool, ["delete-generic-password", "-s", service],
            environment: nil, stdin: nil, directory: nil, timeout: 10
        )
    }
}

/// 토큰 갱신을 Claude Code에 맡긴다. `/cost`는 로컬 명령이라 모델을 호출하지 않는다(실측 비용 0).
public struct ClaudeCLIRefresher: ClaudeRefreshing {
    private let runner: CommandRunning
    private let executable: String?
    private let searchPath: String?

    public init(runner: CommandRunning, executable: String?, searchPath: String? = nil) {
        self.runner = runner
        self.executable = executable
        self.searchPath = searchPath
    }

    public func refresh(configDir: String?) async throws {
        guard let executable else { throw FetchFailure.toolMissing("claude") }
        var environment: [String: String] = [:]
        if let searchPath { environment["PATH"] = searchPath }
        if let configDir { environment["CLAUDE_CONFIG_DIR"] = configDir }
        _ = try await runner.run(
            executable,
            [
                "-p", "/cost",
                "--settings", #"{"disableAllHooks":true}"#,
                "--strict-mcp-config",
                "--no-session-persistence",
                "--output-format", "json",
            ],
            environment: environment,
            stdin: nil,
            directory: NSTemporaryDirectory(),
            timeout: 90
        )
    }
}

/// 로그인은 브라우저에서 사람이 해야 해서 터미널 창으로 넘긴다.
public enum LoginScript {
    public static func text(for target: LoginTarget, claude: String?, codex: String?, in language: AppLanguage = .current) -> String? {
        var lines = ["#!/bin/zsh"]
        switch target {
        case .claude(let configDir):
            guard let claude else { return nil }
            if let configDir {
                lines.append("mkdir -p \(quote(configDir))")
                lines.append("export CLAUDE_CONFIG_DIR=\(quote(configDir))")
            } else {
                lines.append("unset CLAUDE_CONFIG_DIR")
            }
            lines.append("\(quote(claude)) auth login")
        case .codex(let home):
            guard let codex else { return nil }
            lines.append("mkdir -p \(quote(home))")
            lines.append("export CODEX_HOME=\(quote(home))")
            lines.append("\(quote(codex)) login")
        case .deepseek:
            return nil
        }
        lines.append("echo")
        lines.append("echo '\(language.pick("Done. You can close this window.", "끝났습니다. 이 창은 닫아도 됩니다."))'")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func quote(_ text: String) -> String {
        "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'"
    }
}
