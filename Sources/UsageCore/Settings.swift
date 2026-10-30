import Foundation

public struct DeepSeekAccountConfig: Codable, Equatable, Sendable {
    public let id: String
    public let label: String

    public init(id: String, label: String) {
        self.id = id
        self.label = label
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var hiddenAccountIDs: [String] = []
    public var deepseekAccounts: [DeepSeekAccountConfig] = []
    public var loginItemInitialized = false

    public init() {}

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hiddenAccountIDs = try container.decodeIfPresent([String].self, forKey: .hiddenAccountIDs) ?? []
        deepseekAccounts = try container.decodeIfPresent([DeepSeekAccountConfig].self, forKey: .deepseekAccounts) ?? []
        loginItemInitialized = try container.decodeIfPresent(Bool.self, forKey: .loginItemInitialized) ?? false
    }
}

public final class SettingsStore: @unchecked Sendable {
    public let path: String
    private let lock = NSLock()

    public init(path: String) {
        self.path = path
    }

    public static var defaultPath: String {
        NSHomeDirectory() + "/Library/Application Support/UsageIsland/settings.json"
    }

    public func load() -> AppSettings {
        lock.lock(); defer { lock.unlock() }
        guard let data = FileManager.default.contents(atPath: path) else { return AppSettings() }
        if let settings = try? JSONDecoder().decode(AppSettings.self, from: data) {
            return settings
        }
        // 손상된 파일을 조용히 덮어쓰지 않고 옆에 남긴다.
        let aside = (path as NSString).deletingPathExtension + ".corrupt.json"
        try? FileManager.default.removeItem(atPath: aside)
        try? FileManager.default.moveItem(atPath: path, toPath: aside)
        return AppSettings()
    }

    public func save(_ settings: AppSettings) {
        lock.lock(); defer { lock.unlock() }
        let directory = (path as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(settings) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
