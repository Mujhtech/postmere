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
    @Environment(MailRuntime.self) private var runtime

    var body: some View {
        ContentUnavailableView {
            PostmereLabel(runtime.backend.isConnected ? "Add your email accounts" : "Welcome to Postmere",
                          symbol: "envelope", size: 42)
        } description: {
            Text(runtime.backend.isConnected
                 ? "Connect your Google and Outlook accounts to read and send mail from one workspace."
                 : "Sign in to your Postmere workspace, then add your Google and Outlook accounts.")
                .frame(maxWidth: 340)
        } actions: {
            AccountSettingsButton(title: runtime.backend.isConnected ? "Add an Account" : "Sign In to Workspace")
                .buttonStyle(.borderedProminent)
        }
    }
}
