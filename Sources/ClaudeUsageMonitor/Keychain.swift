import Foundation
import Security

enum KeychainError: LocalizedError {
    case notFound
    case claudeCodeNotLoggedIn
    case unexpectedFormat
    case os(OSStatus)

    var errorDescription: String? {
        switch self {
        case .notFound: return "키체인에서 항목을 찾을 수 없습니다."
        case .claudeCodeNotLoggedIn:
            return "Claude Code에 로그인된 계정이 없습니다.\n터미널에서 claude 를 실행해 /login 으로 로그인한 뒤 다시 시도하세요."
        case .unexpectedFormat: return "키체인 항목의 형식을 해석할 수 없습니다."
        case .os(let status):
            let message = SecCopyErrorMessageString(status, nil) as String? ?? "알 수 없는 오류"
            return "키체인 오류 (\(status)): \(message)"
        }
    }
}

enum Keychain {
    static let appService = "ClaudeUsageMonitor"
    static let claudeCodeService = "Claude Code-credentials"

    // MARK: This app's own per-account storage

    static func save(_ credentials: StoredCredentials, for accountID: UUID) throws {
        let data = try JSONEncoder().encode(credentials)
        let key = accountID.uuidString

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appService,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)

        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock

        let status = SecItemAdd(insert as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.os(status) }
    }

    static func load(for accountID: UUID) throws -> StoredCredentials {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appService,
            kSecAttrAccount as String: accountID.uuidString,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status != errSecItemNotFound else { throw KeychainError.notFound }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.os(status)
        }
        return try JSONDecoder().decode(StoredCredentials.self, from: data)
    }

    static func delete(for accountID: UUID) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: appService,
            kSecAttrAccount as String: accountID.uuidString,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: Importing the account Claude Code is currently logged in as

    /// Reads Claude Code's own keychain entry. macOS will prompt for permission
    /// the first time, since another app created the item.
    static func importFromClaudeCode() throws -> StoredCredentials {
        guard claudeCodeItemExists() else { throw KeychainError.claudeCodeNotLoggedIn }
        let data = try readClaudeCodeItem()
        return try parseClaudeCode(data)
    }

    /// Attributes-only lookup: tells us whether Claude Code has credentials
    /// stored without reading them, so it never triggers a permission prompt.
    static func claudeCodeItemExists() -> Bool {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeCodeService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        return SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess
    }

    /// What Claude Code is currently logged in with, used to work out which
    /// stored account is active. Returns nil rather than throwing — callers
    /// treat "unknown" as a normal state.
    static func currentClaudeCodeCredentials() -> StoredCredentials? {
        guard let data = try? readClaudeCodeItem() else { return nil }
        return try? parseClaudeCode(data)
    }

    private static func parseClaudeCode(_ data: Data) throws -> StoredCredentials {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KeychainError.unexpectedFormat
        }
        let oauth = (root["claudeAiOauth"] as? [String: Any]) ?? root
        guard let access = oauth["accessToken"] as? String, !access.isEmpty else {
            throw KeychainError.unexpectedFormat
        }
        return StoredCredentials(
            accessToken: access,
            refreshToken: oauth["refreshToken"] as? String,
            expiresAt: oauth["expiresAt"] as? Double,
            rawPayload: String(data: data, encoding: .utf8),
            profileSnapshot: ClaudeCodeConfig.readProfile()
        )
    }

    /// Makes the given payload Claude Code's active login. Existing sessions
    /// keep the old token in memory, so Claude Code must be restarted.
    static func writeToClaudeCode(payload: String) throws {
        let data = Data(payload.utf8)
        let account = existingClaudeCodeAccount() ?? NSUserName()

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeCodeService,
            kSecAttrAccount as String: account,
        ]

        // Updating preserves the item's existing ACL, which is what keeps Claude
        // Code able to read its own credentials without a prompt.
        let status = SecItemUpdate(query as CFDictionary,
                                   [kSecValueData as String: data] as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw KeychainError.os(status) }

        // No item to update — Claude Code is logged out. Creating it with
        // SecItemAdd would put *this* app alone on the ACL, so Claude Code would
        // be prompted on every single keychain read afterwards. Create it through
        // the security tool instead, naming both binaries as trusted.
        try createClaudeCodeItem(account: account, payload: payload)
    }

    /// `security add-generic-password -T` is the only practical way to seed an
    /// item whose ACL trusts a binary other than the caller.
    private static func createClaudeCodeItem(account: String, payload: String) throws {
        var arguments = [
            "add-generic-password",
            "-U",
            "-s", claudeCodeService,
            "-a", account,
            "-w", payload,
        ]

        // Trust Claude Code itself, plus this app so later switches stay silent.
        for path in claudeCodeBinaryPaths() {
            arguments.append(contentsOf: ["-T", path])
        }
        arguments.append(contentsOf: ["-T", Bundle.main.bundlePath])

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        task.arguments = arguments
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
        } catch {
            throw KeychainError.unexpectedFormat
        }
        task.waitUntilExit()
        guard task.terminationStatus == 0 else {
            throw KeychainError.os(OSStatus(task.terminationStatus))
        }
    }

    /// Claude Code installs each release under a versioned path, so resolve the
    /// launcher symlink rather than hardcoding one.
    private static func claudeCodeBinaryPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            home.appendingPathComponent(".local/bin/claude"),
            URL(fileURLWithPath: "/usr/local/bin/claude"),
            URL(fileURLWithPath: "/opt/homebrew/bin/claude"),
        ]

        var paths: [String] = []
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            paths.append(candidate.path)
            let resolved = candidate.resolvingSymlinksInPath().path
            if resolved != candidate.path { paths.append(resolved) }
        }
        return paths
    }

    /// The account name Claude Code keyed its item under — usually the login
    /// name, but read it rather than assume so a switch updates the same item.
    private static func existingClaudeCodeAccount() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeCodeService,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attributes = item as? [String: Any]
        else { return nil }
        return attributes[kSecAttrAccount as String] as? String
    }

    private static func readClaudeCodeItem() throws -> Data {
        // Claude Code keys the item by the current username, but don't rely on
        // that — fall back to a service-wide search.
        let byAccount: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeCodeService,
            kSecAttrAccount as String: NSUserName(),
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        var status = SecItemCopyMatching(byAccount as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return data }

        let byService: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: claudeCodeService,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        item = nil
        status = SecItemCopyMatching(byService as CFDictionary, &item)
        if status == errSecSuccess, let data = item as? Data { return data }

        if status == errSecItemNotFound {
            // Older installs kept credentials in a plain file.
            let path = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".claude/.credentials.json")
            if let data = try? Data(contentsOf: path) { return data }
            throw KeychainError.notFound
        }
        throw KeychainError.os(status)
    }
}
