import Foundation

/// 이 맥에 로그인된 계정을 파일 구조에서 찾는다. 토큰은 읽지 않는다.
public struct AccountDiscovery: Sendable {
    public let home: String
    public let usersRoot: String

    public init(home: String = NSHomeDirectory(), usersRoot: String = "/Users") {
        self.home = home
        self.usersRoot = usersRoot
    }

    public func claudeAccounts() -> [Account] {
        var logins: [ClaudeLogin] = []
        if let login = claudeLogin(jsonPath: home + "/.claude.json", configDir: nil) {
            logins.append(login)
        }
        for dir in configDirs(prefix: ".claude") {
            if let login = claudeLogin(jsonPath: dir + "/.claude.json", configDir: dir) {
                logins.append(login)
            }
        }
        return Dictionary(grouping: logins, by: \.accountKey)
            .map { key, group in
                Account(id: "claude:\(key)", provider: .claude, title: group[0].email, source: .claude(logins: group))
            }
            .sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    }

    private func claudeLogin(jsonPath: String, configDir: String?) -> ClaudeLogin? {
        guard
            let data = FileManager.default.contents(atPath: jsonPath),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let account = root["oauthAccount"] as? [String: Any],
            let uuid = account["accountUuid"] as? String,
            let email = account["emailAddress"] as? String
        else { return nil }
        let organization = account["organizationUuid"] as? String ?? ""
        return ClaudeLogin(
            configDir: configDir,
            accountKey: "\(uuid)|\(organization)",
            email: email,
            organization: account["organizationName"] as? String
        )
    }

    public func codexAccounts() -> [Account] {
        struct Login {
            let home: String
            let key: String
            let email: String?
            let modified: Date
        }
        var logins: [Login] = []
        for dir in configDirs(prefix: ".codex") {
            let path = dir + "/auth.json"
            guard
                let data = FileManager.default.contents(atPath: path),
                let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                let tokens = root["tokens"] as? [String: Any],
                let accountID = tokens["account_id"] as? String
            else { continue }
            let email = (tokens["id_token"] as? String).flatMap(Self.emailClaim)
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            logins.append(Login(
                home: dir,
                key: "\(accountID)|\(email ?? "")",
                email: email,
                modified: attributes?[.modificationDate] as? Date ?? .distantPast
            ))
        }
        return Dictionary(grouping: logins, by: \.key)
            .compactMap { key, group -> Account? in
                guard let newest = group.max(by: { $0.modified < $1.modified }) else { return nil }
                return Account(
                    id: "codex:\(key)",
                    provider: .codex,
                    title: newest.email ?? newest.home,
                    source: .codex(home: newest.home)
                )
            }
            .sorted { ($0.title, $0.id) < ($1.title, $1.id) }
    }

    /// 새 계정을 로그인시킬 빈 폴더. `.claude-2`, `.claude-3` 순서로 찾는다.
    public func nextConfigDir(prefix: String) -> String {
        var number = 2
        while FileManager.default.fileExists(atPath: "\(home)/\(prefix)-\(number)") {
            number += 1
        }
        return "\(home)/\(prefix)-\(number)"
    }

    /// id_token에서 표시용 이메일만 꺼낸다. 서명은 검증하지 않으며 다른 용도로 쓰지 않는다.
    private static func emailClaim(_ token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var encoded = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard
            let data = Data(base64Encoded: encoded),
            let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return claims["email"] as? String
    }

    /// 모든 홈 폴더의 `.claude`, `.claude-*` 같은 설정 폴더 경로.
    func configDirs(prefix: String) -> [String] {
        let manager = FileManager.default
        let others = ((try? manager.contentsOfDirectory(atPath: usersRoot)) ?? [])
            .sorted()
            .map { usersRoot + "/" + $0 }
        var roots = [home]
        roots.append(contentsOf: others.filter { $0 != home })

        var result: [String] = []
        for root in roots {
            for name in ((try? manager.contentsOfDirectory(atPath: root)) ?? []).sorted()
            where name == prefix || name.hasPrefix(prefix + "-") {
                let path = root + "/" + name
                var isDirectory: ObjCBool = false
                if manager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
                    result.append(path)
                }
            }
        }
        return result
    }
}
