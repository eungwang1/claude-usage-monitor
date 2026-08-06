import Foundation

enum UsageError: LocalizedError {
    case unauthorized
    case rateLimited(retryAfter: TimeInterval?)
    case http(Int, String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .unauthorized:
            return "인증 만료 — 계정을 다시 가져와 주세요."
        case .rateLimited(let retry):
            if let retry { return "요청 제한 (약 \(Int(retry / 60))분 후 재시도)" }
            return "요청 제한 — 잠시 후 재시도합니다."
        case .http(let code, let body):
            return "HTTP \(code): \(body.prefix(120))"
        case .transport(let message):
            return message
        }
    }
}

/// Talks to the endpoint Claude Code's own `/usage` command uses.
/// This endpoint is undocumented — treat failures as expected, not exceptional.
struct UsageClient {
    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let tokenURL = URL(string: "https://console.anthropic.com/v1/oauth/token")!
    /// Claude Code's public OAuth client id.
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"
    static let userAgent = "claude-code/2.1.222"

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.httpAdditionalHeaders = nil
        return URLSession(configuration: config)
    }()

    func fetchUsage(accessToken: String) async throws -> UsageResponse {
        var request = URLRequest(url: Self.usageURL)
        request.httpMethod = "GET"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.transport("잘못된 응답")
        }

        switch http.statusCode {
        case 200:
            do {
                return try UsageParser.decode(data)
            } catch {
                throw UsageError.transport("응답 해석 실패: \(error.localizedDescription)")
            }
        case 401, 403:
            throw UsageError.unauthorized
        case 429:
            let retry = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw UsageError.rateLimited(retryAfter: retry)
        default:
            throw UsageError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
    }

    /// Exchanges a refresh token for a fresh access token.
    /// The token endpoint is undocumented; a failure here means the user has to
    /// re-import the account rather than that something is broken.
    func refresh(credentials: StoredCredentials) async throws -> StoredCredentials {
        guard let refreshToken = credentials.refreshToken, !refreshToken.isEmpty else {
            throw UsageError.unauthorized
        }

        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": Self.clientID,
        ])

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UsageError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String
        else {
            throw UsageError.unauthorized
        }

        var updated = credentials
        updated.accessToken = access
        if let newRefresh = json["refresh_token"] as? String { updated.refreshToken = newRefresh }
        if let expiresIn = json["expires_in"] as? Double {
            updated.expiresAt = Date().addingTimeInterval(expiresIn).timeIntervalSince1970 * 1000
        }
        return updated
    }
}
