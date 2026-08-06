import Foundation
import SwiftUI

enum AccountStatus {
    case idle
    case loading
    case loaded(UsageSnapshot)
    case failed(String)
    case needsAuth

    var snapshot: UsageSnapshot? {
        if case .loaded(let snapshot) = self { return snapshot }
        return nil
    }
}

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [Account] = []
    @Published private(set) var status: [UUID: AccountStatus] = [:]
    /// Last good snapshot per account, kept across failures so the UI can keep
    /// showing numbers while an account is rate-limited.
    @Published private(set) var lastGood: [UUID: UsageSnapshot] = [:]
    @Published var refreshInterval: TimeInterval {
        didSet { UserDefaults.standard.set(refreshInterval, forKey: Self.intervalKey) }
    }

    private let client = UsageClient()
    private var pollTask: Task<Void, Never>?
    /// Per-account backoff floor, set when the endpoint rate-limits us.
    private var nextAllowedFetch: [UUID: Date] = [:]

    /// Which account Claude Code is currently logged in as, when we can tell.
    @Published private(set) var activeAccountID: UUID?
    /// Transient banner text after a switch.
    @Published var switchNotice: String?

    private static let accountsKey = "accounts.v1"
    private static let intervalKey = "refreshInterval"
    private static let activeKey = "activeAccountID"

    init() {
        let stored = UserDefaults.standard.double(forKey: Self.intervalKey)
        refreshInterval = stored > 0 ? stored : 300
        loadAccounts()
        detectActiveAccount()
        startPolling()
    }

    // MARK: Switching Claude Code's login

    /// Matches Claude Code's current token against the stored accounts. Falls
    /// back to the last switch we performed when the token has since been
    /// refreshed by Claude Code itself.
    func detectActiveAccount() {
        if let current = Keychain.currentClaudeCodeCredentials(),
           let match = matchingAccount(for: current) {
            activeAccountID = match.id
            return
        }
        if let raw = UserDefaults.standard.string(forKey: Self.activeKey) {
            activeAccountID = UUID(uuidString: raw)
        }
    }

    /// Tokens get refreshed on both sides, so match on either one: a stored
    /// account is the same login if its access *or* refresh token still lines up.
    private func matchingAccount(for current: StoredCredentials) -> Account? {
        accounts.first { account in
            guard let stored = try? Keychain.load(for: account.id) else { return false }
            if stored.accessToken == current.accessToken { return true }
            if let mine = stored.refreshToken, let theirs = current.refreshToken {
                return mine == theirs
            }
            return false
        }
    }

    /// True when Claude Code is logged in as somebody we have not stored —
    /// switching would discard that login's tokens.
    var currentLoginIsUnregistered: Bool {
        guard let current = Keychain.currentClaudeCodeCredentials() else { return false }
        return matchingAccount(for: current) == nil
    }

    /// Captures whatever Claude Code is logged in as right now, so an
    /// unregistered login can be saved instead of overwritten.
    func adoptCurrentLogin(label: String) throws {
        guard let current = Keychain.currentClaudeCodeCredentials() else {
            throw KeychainError.notFound
        }
        try addAccount(label: label, credentials: current)
    }

    func switchTo(_ account: Account) async {
        do {
            var credentials = try Keychain.load(for: account.id)

            // Install a token that is actually usable, refreshing first if the
            // stored one has already expired.
            if credentials.isExpired, let renewed = try? await client.refresh(credentials: credentials) {
                credentials = renewed
                try? Keychain.save(renewed, for: account.id)
            }

            guard let payload = credentials.claudeCodePayload() else {
                switchNotice = "전환 실패: 자격증명을 구성할 수 없습니다."
                return
            }

            try Keychain.writeToClaudeCode(payload: payload)

            // Tokens and profile have to move together, or Claude Code shows
            // the previous account's identity next to the new account's usage.
            if let profile = credentials.profileSnapshot {
                try? ClaudeCodeConfig.writeProfile(profile)
            }

            activeAccountID = account.id
            UserDefaults.standard.set(account.id.uuidString, forKey: Self.activeKey)

            var notice = "\(account.label)(으)로 전환했습니다."
            notice += ClaudeCodeConfig.isClaudeCodeRunning()
                ? " 실행 중인 Claude Code를 종료 후 다시 여세요 (claude -c 로 대화 이어가기 가능)."
                : " 다음 실행부터 적용됩니다."
            if credentials.profileSnapshot == nil {
                notice += " 계정 프로필 정보가 없어 이메일 표시가 이전 계정으로 남을 수 있습니다."
            }
            switchNotice = notice
        } catch {
            switchNotice = "전환 실패: \(error.localizedDescription)"
        }
    }

    // MARK: Account management

    private func loadAccounts() {
        guard let data = UserDefaults.standard.data(forKey: Self.accountsKey),
              let decoded = try? JSONDecoder().decode([Account].self, from: data)
        else { return }
        accounts = decoded
        for account in decoded { status[account.id] = .idle }
    }

    private func persistAccounts() {
        guard let data = try? JSONEncoder().encode(accounts) else { return }
        UserDefaults.standard.set(data, forKey: Self.accountsKey)
    }

    func addAccount(label: String, credentials: StoredCredentials) throws {
        let account = Account(label: label.isEmpty ? "계정 \(accounts.count + 1)" : label)
        try Keychain.save(credentials, for: account.id)
        accounts.append(account)
        status[account.id] = .idle
        persistAccounts()
        Task { await refresh(account) }
    }

    func removeAccount(_ account: Account) {
        Keychain.delete(for: account.id)
        accounts.removeAll { $0.id == account.id }
        status[account.id] = nil
        lastGood[account.id] = nil
        nextAllowedFetch[account.id] = nil
        persistAccounts()
    }

    func rename(_ account: Account, to label: String) {
        guard let index = accounts.firstIndex(of: account), !label.isEmpty else { return }
        accounts[index].label = label
        persistAccounts()
    }

    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        accounts.move(fromOffsets: source, toOffset: destination)
        persistAccounts()
    }

    // MARK: Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshAll()
                try? await Task.sleep(nanoseconds: UInt64(self.refreshInterval * 1_000_000_000))
            }
        }
    }

    func refreshAll(force: Bool = false) async {
        // Stagger the accounts so four requests don't land on the endpoint at once.
        for (index, account) in accounts.enumerated() {
            if index > 0 {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
            await refresh(account, force: force)
        }
    }

    func refresh(_ account: Account, force: Bool = false) async {
        if !force, let notBefore = nextAllowedFetch[account.id], notBefore > Date() {
            return
        }

        var credentials: StoredCredentials
        do {
            credentials = try Keychain.load(for: account.id)
        } catch {
            status[account.id] = .failed(error.localizedDescription)
            return
        }

        if lastGood[account.id] == nil { status[account.id] = .loading }

        if credentials.isExpired {
            if let renewed = try? await client.refresh(credentials: credentials) {
                credentials = renewed
                try? Keychain.save(renewed, for: account.id)
            }
        }

        do {
            let response = try await client.fetchUsage(accessToken: credentials.accessToken)
            apply(response, to: account)
        } catch UsageError.unauthorized {
            // One retry through a token refresh before asking the user to re-import.
            if let renewed = try? await client.refresh(credentials: credentials) {
                try? Keychain.save(renewed, for: account.id)
                if let response = try? await client.fetchUsage(accessToken: renewed.accessToken) {
                    apply(response, to: account)
                    return
                }
            }
            status[account.id] = .needsAuth
        } catch UsageError.rateLimited(let retryAfter) {
            let backoff = retryAfter ?? max(refreshInterval, 600)
            nextAllowedFetch[account.id] = Date().addingTimeInterval(backoff)
            status[account.id] = .failed(UsageError.rateLimited(retryAfter: backoff).localizedDescription)
        } catch {
            status[account.id] = .failed(error.localizedDescription)
        }
    }

    private func apply(_ response: UsageResponse, to account: Account) {
        let snapshot = UsageSnapshot(rows: UsageParser.rows(from: response), fetchedAt: Date())
        status[account.id] = .loaded(snapshot)
        lastGood[account.id] = snapshot
        nextAllowedFetch[account.id] = nil
    }

    func restartPolling() { startPolling() }

    /// The account Claude Code is logged in as floats to the top — it's the one
    /// whose numbers are being spent right now.
    var orderedAccounts: [Account] {
        guard let activeID = activeAccountID,
              let index = accounts.firstIndex(where: { $0.id == activeID })
        else { return accounts }
        var reordered = accounts
        reordered.insert(reordered.remove(at: index), at: 0)
        return reordered
    }

    // MARK: Menu bar summary

    /// The account with the most headroom — the one worth switching to.
    var bestAccount: (account: Account, snapshot: UsageSnapshot)? {
        accounts
            .compactMap { account in lastGood[account.id].map { (account, $0) } }
            .min { $0.1.worstPercent < $1.1.worstPercent }
    }
}
