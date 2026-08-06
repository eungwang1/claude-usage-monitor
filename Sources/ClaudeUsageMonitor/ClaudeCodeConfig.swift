import Foundation

/// Claude Code keeps tokens in the keychain but the *profile* of the logged-in
/// account — email, account UUID, organization — in ~/.claude.json. Swapping
/// only the keychain leaves those two disagreeing, so a switch has to move both.
enum ClaudeCodeConfig {
    static var path: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    /// The `oauthAccount` object as a JSON string, or nil when absent.
    static func readProfile() -> String? {
        guard let data = try? Data(contentsOf: path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let account = root["oauthAccount"],
              let encoded = try? JSONSerialization.data(withJSONObject: account)
        else { return nil }
        return String(data: encoded, encoding: .utf8)
    }

    /// Replaces only the `oauthAccount` key, leaving the other ~100 settings
    /// (project history, flags) untouched. Written atomically so a crash
    /// mid-write can't truncate the file.
    static func writeProfile(_ json: String) throws {
        guard let profileData = json.data(using: .utf8),
              let profile = try? JSONSerialization.jsonObject(with: profileData)
        else { return }

        let data = try Data(contentsOf: path)
        guard var root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        root["oauthAccount"] = profile

        let updated = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        let attributes = try? FileManager.default.attributesOfItem(atPath: path.path)
        try updated.write(to: path, options: .atomic)

        // .atomic replaces the file, so restore the original permissions.
        if let permissions = attributes?[.posixPermissions] {
            try? FileManager.default.setAttributes([.posixPermissions: permissions],
                                                   ofItemAtPath: path.path)
        }
    }

    /// Whether Claude Code is running right now — it holds both the config and
    /// the old token in memory, and can write the config back on exit.
    static func isClaudeCodeRunning() -> Bool {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        task.arguments = ["-f", "claude"]
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return false }
        task.waitUntilExit()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        return !output.isEmpty
    }
}
