import SwiftUI

struct AccountSettingsButton: View {
    var title = "Open Accounts"
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "general"

    var body: some View {
        Button(title) {
            settingsTab = "accounts"
            openSettings()
        }
    }
}

struct WorkspaceConnectionEmptyView: View {
    var body: some View {
        ContentUnavailableView {
            PostmereLabel.emptyState("Add your first email account", symbol: "envelope", size: 42)
        } description: {
            Text("Choose Google or Outlook in Accounts settings to start reading and sending mail.")
                .frame(maxWidth: 340)
        } actions: {
            AccountSettingsButton(title: "Open Accounts Settings")
                .buttonStyle(.borderedProminent)
        }
    }
}
