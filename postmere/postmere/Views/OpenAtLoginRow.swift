import AppKit
import ServiceManagement
import SwiftUI

/// Opens Postmere when the person logs in, using the system's own login item
/// list. The switch reads the system state, so a change made in System
/// Settings › General › Login Items shows here too.
struct OpenAtLoginRow: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Group { rows }
            // Pick up changes made in System Settings while Postmere was in the background.
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                status = SMAppService.mainApp.status
            }
    }

    @ViewBuilder private var rows: some View {
        SettingsToggle("Open at login", symbol: "power", tint: SettingsTint.green,
                       subtitle: "Start Postmere when you log in to your Mac",
                       isOn: Binding(get: { status == .enabled || status == .requiresApproval }, set: update))
        if status == .requiresApproval {
            HStack {
                Text("Allow Postmere in Login Items to finish turning this on.")
                    .font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
            }
        }
        if let error {
            Text(error).font(.callout).foregroundStyle(PostmereTheme.destructiveInk)
        }
    }

    private func update(_ enabled: Bool) {
        error = nil
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            self.error = enabled ? "Couldn’t add Postmere to your login items." : "Couldn’t remove Postmere from your login items."
        }
        status = SMAppService.mainApp.status
    }
}
