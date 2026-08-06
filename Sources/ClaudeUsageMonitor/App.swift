import SwiftUI

@main
struct ClaudeUsageMonitorApp: App {
    @StateObject private var store = AccountStore()

    var body: some Scene {
        MenuBarExtra {
            DashboardView(store: store)
        } label: {
            MenuBarLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu bar title: the account currently in use and how much of its tightest
/// limit is gone, so a glance answers "how much room do I have left?".
struct MenuBarLabel: View {
    @ObservedObject var store: AccountStore

    var body: some View {
        if let current = store.menuBarAccount {
            Label("\(current.account.label) \(Int(current.snapshot.worstPercent))%",
                  systemImage: "gauge.with.dots.needle.bottom.50percent")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
        }
    }
}
