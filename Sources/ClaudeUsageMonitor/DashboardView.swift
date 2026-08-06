import AppKit
import SwiftUI

/// One sheet at a time, so SwiftUI never has to arbitrate between several
/// `.sheet` modifiers on the same view.
enum ActiveSheet: Identifiable {
    case add
    case settings
    case rename(Account)

    var id: String {
        switch self {
        case .add: return "add"
        case .settings: return "settings"
        case .rename(let account): return "rename-\(account.id)"
        }
    }
}

struct DashboardView: View {
    @ObservedObject var store: AccountStore
    @State private var activeSheet: ActiveSheet?
    @State private var pendingSwitch: Account?
    /// Drives the reset countdowns without re-polling the network.
    @State private var now = Date()

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    /// Switching overwrites Claude Code's keychain entry, so an unsaved login
    /// there would be lost — confirm before discarding it.
    private func switchRequest(to account: Account) {
        if store.currentLoginIsUnregistered {
            pendingSwitch = account
        } else {
            Task { await store.switchTo(account) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            Divider()

            if let notice = store.switchNotice {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.left.arrow.right.circle.fill")
                    Text(notice)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button {
                        store.switchNotice = nil
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .buttonStyle(.borderless)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.12))
            }

            if store.accounts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(store.orderedAccounts) { account in
                            AccountCard(
                                account: account,
                                status: store.status[account.id] ?? .idle,
                                fallback: store.lastGood[account.id],
                                isActive: store.activeAccountID == account.id,
                                now: now,
                                onRefresh: { Task { await store.refresh(account, force: true) } },
                                onRemove: { store.removeAccount(account) },
                                onStartRename: { activeSheet = .rename(account) },
                                onSwitch: { switchRequest(to: account) }
                            )
                        }
                    }
                    .padding(12)
                    .animation(.easeInOut(duration: 0.25), value: store.activeAccountID)
                }
                .frame(maxHeight: 460)
            }

            Divider()
            footer
        }
        .frame(width: 380)
        .onReceive(tick) { now = $0 }
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .add:
                AddAccountView(store: store)
            case .settings:
                SettingsView(store: store)
            case .rename(let account):
                RenameAccountView(currentLabel: account.label) { newLabel in
                    store.rename(account, to: newLabel)
                }
            }
        }
        .alert("등록되지 않은 계정이 로그인되어 있습니다",
               isPresented: .init(get: { pendingSwitch != nil },
                                  set: { if !$0 { pendingSwitch = nil } })) {
            Button("취소", role: .cancel) { pendingSwitch = nil }
            Button("먼저 저장하고 전환") {
                if let target = pendingSwitch {
                    try? store.adoptCurrentLogin(label: "저장된 로그인")
                    Task { await store.switchTo(target) }
                }
                pendingSwitch = nil
            }
            Button("그냥 전환", role: .destructive) {
                if let target = pendingSwitch {
                    Task { await store.switchTo(target) }
                }
                pendingSwitch = nil
            }
        } message: {
            Text("지금 Claude Code에 로그인된 계정은 이 앱에 등록돼 있지 않습니다. 그냥 전환하면 그 계정의 토큰이 사라져 다시 로그인해야 합니다.")
        }
    }

    private var header: some View {
        HStack {
            Text("Claude 사용량")
                .font(.headline)
            Spacer()
            Button {
                Task { await store.refreshAll(force: true) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("모든 계정 새로고침")

            Button {
                activeSheet = .settings
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
            .help("설정")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "person.badge.plus")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text("등록된 계정이 없습니다")
                .font(.callout)
            Text("Claude Code에 로그인한 계정을 가져오거나\n토큰을 직접 붙여넣어 추가하세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.vertical, 28)
    }

    private var footer: some View {
        HStack {
            Button {
                activeSheet = .add
            } label: {
                Label("계정 추가", systemImage: "plus")
            }
            .buttonStyle(.borderless)

            Spacer()

            Button("종료") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

// MARK: - One account

struct AccountCard: View {
    let account: Account
    let status: AccountStatus
    let fallback: UsageSnapshot?
    let isActive: Bool
    let now: Date
    let onRefresh: () -> Void
    let onRemove: () -> Void
    let onStartRename: () -> Void
    let onSwitch: () -> Void

    private var snapshot: UsageSnapshot? { status.snapshot ?? fallback }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text(account.label)
                    .font(.system(size: 13, weight: .semibold))
                    .onTapGesture(count: 2, perform: onStartRename)

                if isActive {
                    Text("사용 중")
                        .font(.caption2)
                        .padding(.horizontal, 5).padding(.vertical, 1)
                        .background(Color.accentColor.opacity(0.18), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                }

                statusBadge

                Spacer()

                if !isActive {
                    Button("전환", action: onSwitch)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("Claude Code 로그인을 이 계정으로 바꿉니다")
                }

                Button(action: onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .controlSize(.small)

                Menu {
                    if !isActive {
                        Button("이 계정으로 전환", action: onSwitch)
                    }
                    Button("이름 변경", action: onStartRename)
                    Button("계정 삭제", role: .destructive, action: onRemove)
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 20)
            }

            if let snapshot {
                ForEach(snapshot.rows) { row in
                    LimitBar(row: row, now: now)
                }
                Text(freshness(snapshot.fetchedAt))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            } else if case .loading = status {
                ProgressView().controlSize(.small)
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch status {
        case .needsAuth:
            Text("재인증 필요")
                .font(.caption2)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Color.orange.opacity(0.2), in: Capsule())
                .foregroundStyle(.orange)
        case .failed(let message):
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundStyle(.orange)
                .help(message)
        case .loading where snapshot != nil:
            ProgressView().controlSize(.small).scaleEffect(0.6)
        default:
            EmptyView()
        }
    }

    private func freshness(_ date: Date) -> String {
        let seconds = Int(now.timeIntervalSince(date))
        if seconds < 60 { return "방금 업데이트" }
        if seconds < 3600 { return "\(seconds / 60)분 전 업데이트" }
        return "\(seconds / 3600)시간 전 업데이트"
    }
}

// MARK: - One limit bar

struct LimitBar: View {
    let row: LimitRow
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(row.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("\(Int(row.percent))%")
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(color)
            }

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(color)
                        .frame(width: max(2, geo.size.width * min(row.percent, 100) / 100))
                }
            }
            .frame(height: 5)

            if let resetsAt = row.resetsAt {
                Text("리셋까지 \(countdown(to: resetsAt))")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private var color: Color {
        switch row.severity {
        case "critical": return .red
        case "warning": return .orange
        default:
            if row.percent >= 90 { return .red }
            if row.percent >= 70 { return .orange }
            return .green
        }
    }

    private func countdown(to date: Date) -> String {
        let remaining = Int(date.timeIntervalSince(now))
        if remaining <= 0 { return "곧 리셋" }
        let days = remaining / 86400
        let hours = (remaining % 86400) / 3600
        let minutes = (remaining % 3600) / 60
        let seconds = remaining % 60
        if days > 0 { return "\(days)일 \(hours)시간" }
        if hours > 0 { return "\(hours)시간 \(minutes)분" }
        return "\(minutes)분 \(seconds)초"
    }
}
