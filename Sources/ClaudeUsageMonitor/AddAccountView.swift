import ServiceManagement
import SwiftUI

struct AddAccountView: View {
    @ObservedObject var store: AccountStore
    @Environment(\.dismiss) private var dismiss

    @State private var label = ""
    @State private var accessToken = ""
    @State private var refreshToken = ""
    @State private var mode: Mode = .importFromClaudeCode
    @State private var errorMessage: String?

    enum Mode: String, CaseIterable, Identifiable {
        case importFromClaudeCode = "Claude Code에서 가져오기"
        case manual = "토큰 직접 입력"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("계정 추가")
                .font(.headline)

            Picker("", selection: $mode) {
                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            TextField("표시 이름 (예: 회사, 개인)", text: $label)
                .textFieldStyle(.roundedBorder)

            switch mode {
            case .importFromClaudeCode:
                VStack(alignment: .leading, spacing: 6) {
                    Text("지금 Claude Code에 로그인되어 있는 계정의 토큰을 키체인에서 읽어옵니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("계정을 여러 개 등록하려면: 계정 A로 로그인 → 가져오기 → `/logout` 후 계정 B로 로그인 → 다시 가져오기 순으로 반복하세요. 첫 실행 시 키체인 접근 허용 창이 뜹니다.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

            case .manual:
                VStack(alignment: .leading, spacing: 8) {
                    SecureField("Access token (sk-ant-oat01-...)", text: $accessToken)
                        .textFieldStyle(.roundedBorder)
                    SecureField("Refresh token (선택, 자동 갱신용)", text: $refreshToken)
                        .textFieldStyle(.roundedBorder)
                    Text("토큰은 이 앱 전용 키체인 항목에 저장되며 외부로 전송되지 않습니다.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("취소") { dismiss() }
                Button(primaryTitle, action: add)
                    .keyboardShortcut(.defaultAction)
                    .disabled(mode == .manual && accessToken.isEmpty)
            }
        }
        .padding(18)
        .frame(width: 400)
    }

    private var primaryTitle: String {
        mode == .importFromClaudeCode ? "가져오기" : "추가"
    }

    private func add() {
        do {
            let credentials: StoredCredentials
            switch mode {
            case .importFromClaudeCode:
                credentials = try Keychain.importFromClaudeCode()
            case .manual:
                credentials = StoredCredentials(
                    accessToken: accessToken.trimmingCharacters(in: .whitespacesAndNewlines),
                    refreshToken: refreshToken.isEmpty ? nil : refreshToken,
                    expiresAt: nil
                )
            }
            try store.addAccount(label: label.trimmingCharacters(in: .whitespaces),
                                 credentials: credentials)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Renaming lives in a sheet rather than inline in the menu bar popover:
/// the popover is not always the key window, so a TextField inside it can
/// silently refuse first responder.
struct RenameAccountView: View {
    let currentLabel: String
    let onCommit: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var label: String
    @FocusState private var fieldFocused: Bool

    init(currentLabel: String, onCommit: @escaping (String) -> Void) {
        self.currentLabel = currentLabel
        self.onCommit = onCommit
        _label = State(initialValue: currentLabel)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("계정 이름 변경")
                .font(.headline)

            TextField("이름", text: $label)
                .textFieldStyle(.roundedBorder)
                .focused($fieldFocused)
                .onSubmit(commit)

            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("저장", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(label.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(18)
        .frame(width: 300)
        .onAppear {
            NSApp.activate()
            fieldFocused = true
        }
    }

    private func commit() {
        let trimmed = label.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        onCommit(trimmed)
        dismiss()
    }
}

struct SettingsView: View {
    @ObservedObject var store: AccountStore
    @Environment(\.dismiss) private var dismiss
    @State private var minutes: Double
    @State private var launchAtLogin: Bool

    init(store: AccountStore) {
        self.store = store
        _minutes = State(initialValue: store.refreshInterval / 60)
        _launchAtLogin = State(initialValue: SMAppService.mainApp.status == .enabled)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration fails for unsigned builds run from odd locations;
            // reflect reality rather than leaving the toggle lying.
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("설정")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("새로고침 주기: \(Int(minutes))분")
                    .font(.callout)
                Slider(value: $minutes, in: 1...30, step: 1)
                Text("사용량 엔드포인트는 요청 제한이 엄격합니다. 계정이 많을수록 주기를 넉넉히 두세요 (권장 5분 이상).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Toggle("로그인 시 자동 실행", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    setLaunchAtLogin(enabled)
                }

            Divider()

            Text("이 앱은 Claude Code가 사용하는 비공개 사용량 엔드포인트를 호출합니다. Anthropic이 예고 없이 변경할 수 있습니다.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("완료") {
                    store.refreshInterval = minutes * 60
                    store.restartPolling()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 340)
    }
}
