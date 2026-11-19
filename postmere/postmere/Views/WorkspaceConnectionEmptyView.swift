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
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Connect your inbox")
                        .font(.system(.largeTitle, design: .serif, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    Text("Choose where you read your mail.")
                        .foregroundStyle(.secondary)
                }
                OnboardingInboxPicker(session: runtime.backend, onSync: runtime.sync)
            }
            .frame(maxWidth: 410)
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
    }
}
