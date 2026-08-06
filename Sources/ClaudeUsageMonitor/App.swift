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

/// Menu bar title: the account with the most headroom, so a glance answers
/// "which account should I use right now?".
struct MenuBarLabel: View {
    @ObservedObject var store: AccountStore

    var body: some View {
        if let best = store.bestAccount {
            Label("\(best.account.label) \(Int(best.snapshot.worstPercent))%",
                  systemImage: "gauge.with.dots.needle.bottom.50percent")
                .labelStyle(.titleAndIcon)
        } else {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
        }
    }
}
