import Foundation

// MARK: - Usage endpoint response

struct UsageResponse: Codable {
    let limits: [Limit]?
    let fiveHour: Window?
    let sevenDay: Window?

    struct Window: Codable {
        let utilization: Double?
        let resetsAt: String?
    }

    struct Limit: Codable, Identifiable {
        let kind: String
        let group: String?
        let percent: Double
        let severity: String?
        let resetsAt: String?
        let scope: Scope?
        let isActive: Bool?

        var id: String { kind + (scope?.model?.displayName ?? "") }

        struct Scope: Codable {
            let model: ModelRef?
            struct ModelRef: Codable {
                let id: String?
                let displayName: String?
            }
        }
    }
}

/// A flattened, display-ready view of one usage limit.
struct LimitRow: Identifiable {
    enum Group { case session, weekly }

    let id: String
    let title: String
    let group: Group
    let percent: Double
    let severity: String
    let resetsAt: Date?

    var isCritical: Bool { percent >= 90 }
}

/// Everything one account's last successful poll produced.
struct UsageSnapshot {
    let rows: [LimitRow]
    let fetchedAt: Date

    /// The single number that best answers "how much room is left here?" —
    /// the worst limit the account is currently up against.
    var worstPercent: Double { rows.map(\.percent).max() ?? 0 }

    var session: LimitRow? { rows.first { $0.group == .session } }
    var weeklyOverall: LimitRow? {
        rows.first { $0.group == .weekly && $0.title == "주간 전체" }
    }
}

// MARK: - Response → display rows

enum UsageParser {
    static func decode(_ data: Data) throws -> UsageResponse {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(UsageResponse.self, from: data)
    }

    static func rows(from response: UsageResponse) -> [LimitRow] {
        if let limits = response.limits, !limits.isEmpty {
            return limits.map { limit in
                LimitRow(
                    id: limit.id,
                    title: title(for: limit),
                    group: limit.group == "session" ? .session : .weekly,
                    percent: limit.percent,
                    severity: limit.severity ?? "normal",
                    resetsAt: parseDate(limit.resetsAt)
                )
            }
            .sorted { lhs, rhs in
                // Session first, then weekly limits by descending pressure.
                if lhs.group != rhs.group { return lhs.group == .session }
                return lhs.percent > rhs.percent
            }
        }

        // Older/leaner response shape: fall back to the top-level windows.
        var fallback: [LimitRow] = []
        if let five = response.fiveHour, let pct = five.utilization {
            fallback.append(LimitRow(id: "session", title: "세션 (5시간)", group: .session,
                                     percent: pct, severity: "normal",
                                     resetsAt: parseDate(five.resetsAt)))
        }
        if let week = response.sevenDay, let pct = week.utilization {
            fallback.append(LimitRow(id: "weekly_all", title: "주간 전체", group: .weekly,
                                     percent: pct, severity: "normal",
                                     resetsAt: parseDate(week.resetsAt)))
        }
        return fallback
    }

    private static func title(for limit: UsageResponse.Limit) -> String {
        if let model = limit.scope?.model?.displayName {
            return "주간 · \(model)"
        }
        switch limit.kind {
        case "session": return "세션 (5시간)"
        case "weekly_all": return "주간 전체"
        case "weekly_scoped": return "주간 (모델별)"
        default: return limit.kind
        }
    }

    private static let isoWithFraction: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func parseDate(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        return isoWithFraction.date(from: raw) ?? isoPlain.date(from: raw)
    }
}

// MARK: - Stored credentials

struct StoredCredentials: Codable {
    var accessToken: String
    var refreshToken: String?
    /// Milliseconds since epoch, matching Claude Code's own keychain format.
    var expiresAt: Double?
    /// Claude Code's keychain payload verbatim. Kept so switching back to this
    /// account restores every field it had — scopes, plan, rate limit tier —
    /// not just the three we parse.
    var rawPayload: String?
    /// The `oauthAccount` object from ~/.claude.json at import time, so a switch
    /// restores the profile (email, org) alongside the tokens.
    var profileSnapshot: String?

    /// The payload to write when making this account the active Claude Code
    /// login. Falls back to a minimal document for accounts added by pasting a
    /// token, which never had an original payload.
    func claudeCodePayload() -> String? {
        if let rawPayload, !rawPayload.isEmpty,
           let refreshed = Self.replacingTokens(in: rawPayload, with: self) {
            return refreshed
        }

        var oauth: [String: Any] = ["accessToken": accessToken]
        if let refreshToken { oauth["refreshToken"] = refreshToken }
        if let expiresAt { oauth["expiresAt"] = expiresAt }
        oauth["scopes"] = Self.defaultScopes
        guard let data = try? JSONSerialization.data(withJSONObject: ["claudeAiOauth": oauth]) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    static let defaultScopes = [
        "user:file_upload", "user:inference", "user:mcp_servers",
        "user:profile", "user:sessions:claude_code",
    ]

    /// Writes the current (possibly refreshed) tokens into a stored payload so
    /// a switch never installs a stale access token.
    private static func replacingTokens(in payload: String,
                                        with credentials: StoredCredentials) -> String? {
        guard let data = payload.data(using: .utf8),
              var root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        let key = root["claudeAiOauth"] != nil ? "claudeAiOauth" : nil
        var oauth = (key.flatMap { root[$0] as? [String: Any] }) ?? root

        oauth["accessToken"] = credentials.accessToken
        if let refreshToken = credentials.refreshToken { oauth["refreshToken"] = refreshToken }
        if let expiresAt = credentials.expiresAt { oauth["expiresAt"] = expiresAt }

        if let key { root[key] = oauth } else { root = oauth }
        guard let updated = try? JSONSerialization.data(withJSONObject: root) else { return nil }
        return String(data: updated, encoding: .utf8)
    }

    var expiryDate: Date? {
        guard let expiresAt else { return nil }
        return Date(timeIntervalSince1970: expiresAt / 1000)
    }

    var isExpired: Bool {
        guard let expiryDate else { return false }
        return expiryDate <= Date().addingTimeInterval(60)
    }
}

struct Account: Identifiable, Codable, Equatable {
    var id: UUID
    var label: String

    init(id: UUID = UUID(), label: String) {
        self.id = id
        self.label = label
    }
}
