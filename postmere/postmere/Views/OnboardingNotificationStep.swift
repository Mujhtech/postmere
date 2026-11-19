import AppKit
import SwiftUI
import UserNotifications

struct OnboardingNotificationStep: View {
    let notifications: MailNotificationService
    let finishTitle: String
    let onFinish: () -> Void
    @Environment(\.postmereAccent) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            reminderPreview
            if !notifications.hasCheckedAuthorization || notifications.isRequestingAuthorization {
                ProgressView(notifications.isRequestingAuthorization ? "Waiting for your choice…" : "Checking notification settings…")
                    .controlSize(.small)
                if !notifications.isRequestingAuthorization { skipButton }
            } else {
                switch notifications.authorizationStatus {
                case .notDetermined:
                    if let error = notifications.authorizationError {
                        Text(error).font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    actions {
                        Button {
                            Task { await notifications.requestAuthorization() }
                        } label: {
                            Label("Enable notifications", systemImage: "bell")
                        }
                        .buttonStyle(OnboardingActionStyle())
                        .keyboardShortcut(.defaultAction)
                    } secondary: {
                        skipButton
                    }
                case .authorized:
                    status("Notifications are on", symbol: "checkmark.circle.fill", color: palette.accentInk)
                    finishButton
                case .provisional:
                    status("Notifications are delivered quietly", symbol: "bell")
                    finishAndSettings
                case .denied:
                    status("Notifications are off on this Mac", symbol: "bell.slash")
                    finishAndSettings
                @unknown default:
                    finishAndSettings
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task { await notifications.refreshAuthorization() }
    }

    private var reminderPreview: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable().interpolation(.high).frame(width: 38, height: 38)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Example reminder").font(.caption).foregroundStyle(.secondary)
                Text("Time to follow up").font(.headline)
                Text("Open Postmere to view the message.").font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(PostmereTheme.rule) }
        .accessibilityElement(children: .combine)
    }

    private var finishButton: some View {
        Button(finishTitle, action: onFinish)
            .buttonStyle(OnboardingActionStyle())
            .keyboardShortcut(.defaultAction)
    }

    private var skipButton: some View {
        Button("Not now", action: onFinish)
            .buttonStyle(.link).foregroundStyle(palette.accentInk)
    }

    private var finishAndSettings: some View {
        actions {
            finishButton
        } secondary: {
            SystemNotificationSettingsButton(title: "Open Notification Settings")
                .buttonStyle(.link).foregroundStyle(palette.accentInk)
        }
    }

    private func status(_ text: String, symbol: String, color: Color = .secondary) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: symbol).foregroundStyle(color)
        }
        .font(.callout.weight(.medium))
    }

    private func actions<Primary: View, Secondary: View>(@ViewBuilder primary: () -> Primary,
                                                         @ViewBuilder secondary: () -> Secondary) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                primary()
                secondary()
            }
            .fixedSize(horizontal: true, vertical: false)
            VStack(alignment: .leading, spacing: 14) {
                primary()
                secondary()
            }
        }
    }
}

struct SystemNotificationSettingsButton: View {
    var title = "Open System Settings…"
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button(title) {
            guard var url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
            if let bundleID = Bundle.main.bundleIdentifier {
                url.append(queryItems: [URLQueryItem(name: "id", value: bundleID)])
            }
            openURL(url)
        }
    }
}
