import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(\.postmereAccent) private var palette
    @Bindable var store: MailStore
    @Bindable var runtime: MailRuntime
    @Environment(\.openURL) private var openURL
    @AppStorage("markdownSubstitutions") private var markdownSubstitutions = true
    @AppStorage("undoSendDelay") private var undoSendDelay = 10.0
    @State private var selectedNotificationAccount = ""
    @State private var senderEmail = ""
    @State private var senderRoute: SenderRoute = .inbox
    @State private var showsInboxManager = false
    @AppStorage("settingsTab") private var settingsTab = "general"
    @AppStorage("readingFontSize") private var readingFontSize = 14.0
    @AppStorage("showMessagePreviews") private var showMessagePreviews = true
    @AppStorage("loadRemoteMailImagesAutomatically") private var loadRemoteMailImagesAutomatically = true
    @AppStorage("blockSenderTrackingPixels") private var blockSenderTrackingPixels = true
    @AppStorage("appearance") private var appearance: MailAppearance = .system
    @AppStorage(PostmereAccent.preferenceKey) private var primaryColorRGB = PostmereAccent.defaultRGB
    @AppStorage("defaultSendingAccount") private var defaultSendingAccount = ""

    var body: some View {
        TabView(selection: $settingsTab) {
            readingSettings.tabItem { PostmereLabel("General", symbol: "gearshape", size: 18) }.tag("general")
            composingSettings.tabItem { PostmereLabel("Composing", symbol: "square.and.pencil", size: 18) }.tag("composing")
            accountSettings.tabItem { PostmereLabel("Accounts", symbol: "person.crop.circle", size: 18) }.tag("accounts")
            privacySettings.tabItem { PostmereLabel("Privacy", symbol: "shield", size: 18) }.tag("privacy")
            notificationSettings.tabItem { PostmereLabel("Notifications", symbol: "bell", size: 18) }.tag("notifications")
            screeningSettings.tabItem { PostmereLabel("Rules", symbol: "line.3.horizontal.decrease.circle", size: 18) }.tag("rules")
            shortcutSettings.tabItem { PostmereLabel("Shortcuts", symbol: "keyboard", size: 18) }.tag("shortcuts")
        }
        .padding(.top, 8)
        .frame(width: 640, height: 590)
        .sheet(isPresented: $showsInboxManager) { InboxManagementView(store: store) }
        .onChange(of: MailAccount.allCases.map(\.rawValue), initial: true) {
            if !MailAccount.allCases.contains(where: { $0.rawValue == selectedNotificationAccount }) {
                selectedNotificationAccount = (MailAccount.allCases.first(where: \.isConnected) ?? MailAccount.allCases.first)?.rawValue ?? ""
            }
        }
    }

    private var readingSettings: some View {
        Form {
            Section("Appearance") {
                Picker("Appearance", selection: $appearance) {
                    ForEach(MailAppearance.allCases, id: \.self) { value in
                        Text(value.title).tag(value)
                    }
                }
                .pickerStyle(.segmented)
                LabeledContent("Primary color") {
                    HStack(spacing: 10) {
                        if primaryColorRGB != PostmereAccent.defaultRGB {
                            Button("Reset") { primaryColorRGB = PostmereAccent.defaultRGB }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                                .accessibilityLabel("Reset primary color")
                        }
                        ColorPicker("Primary color", selection: Binding(
                            get: { palette.swatch },
                            set: { color in
                                if let rgb = PostmereAccent.rgbValue(of: color) { primaryColorRGB = rgb }
                            }
                        ), supportsOpacity: false)
                        .labelsHidden()
                    }
                }
            }
            Section("Reading") {
                Toggle("Show message previews", isOn: $showMessagePreviews)
                HStack(spacing: 10) {
                    Text("Message text size")
                        .accessibilityHidden(true)
                    Spacer()
                    Slider(value: $readingFontSize, in: 12...20, step: 1) {
                        Text("Reading text size")
                    }
                    .labelsHidden()
                    .frame(width: 150)
                    .accessibilityValue("\(Int(readingFontSize)) points")
                    Text("\(Int(readingFontSize)) pt")
                        .monospacedDigit().foregroundStyle(.secondary).frame(width: 38)
                        .accessibilityHidden(true)
                }
                .accessibilityElement(children: .contain)
                Text("The quick brown fox jumps over the lazy dog.")
                    .font(.system(size: readingFontSize))
                    .padding(.vertical, 8)
                    .accessibilityLabel("Text size preview")
            }
            Section("Calendar") { CalendarIntegrationSettingsView() }
            Section("AI assistance") { MailAISettingsView(session: runtime.backend) }
            Section {
                Text("Messages, drafts, attachments, notes, and preferences are saved on this Mac. Add Google and Outlook accounts to your workspace in Accounts.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var privacySettings: some View {
        Form {
            Section("Incoming mail") {
                privacyToggle("Load remote images automatically", isOn: $loadRemoteMailImagesAutomatically,
                              detail: "Image hosts can see your IP address. Turn this off to choose which messages can load images.")
                privacyToggle("Block sender tracking pixels", isOn: $blockSenderTrackingPixels,
                              detail: "Keeps detected trackers from loading and shows the blocked count beside the recipients.")
            }
            Section("Profile photos") {
                LabeledContent("Photos from Contacts") { ContactPhotoAccess() }
                privacyToggle("Show website icons for organizations", isOn: Bindable(MailRemoteParticipantImages.websiteIcons).enabled,
                              detail: "Bitwarden receives the website’s domain and your IP address. It can fetch the icon from the website.")
                privacyToggle("Use Gravatar for missing photos", isOn: Bindable(MailRemoteParticipantImages.gravatar).enabled,
                              detail: "Gravatar receives a hash of the email address and can recognize that address and see your IP address.")
            }
        }
        .formStyle(.grouped)
    }

    private func privacyToggle(_ title: String, isOn: Binding<Bool>, detail: String) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                Text(detail).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityLabel(title)
        .accessibilityHint(detail)
    }

    private var composingSettings: some View {
        Form {
            Section("Sending") {
                Picker("Default account", selection: $defaultSendingAccount) {
                    if !MailAccount.allCases.contains(where: { $0.rawValue == defaultSendingAccount }) {
                        Text(MailAccount.allCases.isEmpty ? "No accounts connected" : "Choose an account").tag(defaultSendingAccount)
                    }
                    ForEach(MailAccount.allCases, id: \.self) { account in
                        Text(account.email).tag(account.rawValue).disabled(!account.isConnected)
                    }
                }
                .disabled(MailAccount.sendingAccounts.isEmpty)
                if MailAccount.sendingAccounts.isEmpty {
                    AccountSettingsButton(title: MailAccount.allCases.isEmpty ? "Add an Account" : "Reconnect an Account")
                }
                Picker("Undo Send delay", selection: $undoSendDelay) {
                    ForEach([5.0, 10.0, 20.0, 30.0, 60.0], id: \.self) { Text("\(Int($0)) seconds").tag($0) }
                }
                Toggle("Format Markdown as you type", isOn: $markdownSubstitutions)
                Text("Use **bold**, *italic*, `code`, and Markdown lists in the composer.").font(.caption).foregroundStyle(.secondary)
                Text("Replies use the account that received the original message.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Section("Signature") {
                SignatureEditorView(accounts: MailAccount.allCases.filter { !$0.email.isEmpty }.map {
                    MailSignatureAccount(id: $0.rawValue, title: $0.displayName, detail: $0.email)
                })
            }
        }
        .formStyle(.grouped)
    }

    private var accountSettings: some View {
        BackendConnectionView(session: runtime.backend, store: store, onSync: runtime.sync)
    }

    private var notificationProfile: Binding<NotificationProfile> {
        Binding(get: {
            runtime.notifications.profiles.first { $0.id == selectedNotificationAccount } ?? NotificationProfile(id: selectedNotificationAccount)
        }, set: { profile in
            guard !profile.id.isEmpty else { return }
            if let index = runtime.notifications.profiles.firstIndex(where: { $0.id == profile.id }) {
                runtime.notifications.profiles[index] = profile
            } else {
                runtime.notifications.profiles.append(profile)
            }
        })
    }

    private var notificationSettings: some View {
        Form {
            Section {
                LabeledContent("Notifications on this Mac") {
                    notificationPermissionControl
                }
                if let error = runtime.notifications.authorizationError { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("Account notifications") {
                if MailAccount.allCases.isEmpty {
                    LabeledContent("No accounts connected") { AccountSettingsButton(title: "Add an Account…") }
                } else {
                    Picker("Account", selection: $selectedNotificationAccount) {
                        ForEach(MailAccount.allCases) { Text($0.email).tag($0.rawValue) }
                    }
                    if let account = MailAccount(rawValue: selectedNotificationAccount), !account.isConnected {
                        LabeledContent("Reconnect to receive notifications") {
                            AccountSettingsButton(title: "Open Accounts…")
                        }
                    }
                    Toggle("Notify me about this account", isOn: notificationProfile.enabled)
                    if notificationProfile.wrappedValue.enabled {
                        Toggle("Show message subject", isOn: notificationProfile.showPreview)
                        Toggle("Only during these hours", isOn: notificationProfile.scheduleEnabled)
                        if notificationProfile.wrappedValue.scheduleEnabled { notificationSchedule }
                    }
                }
                if let error = runtime.notifications.lastError { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("Focus") {
                Text("To limit alerts to specific accounts during a Focus, add a Postmere filter in System Settings → Focus.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("While Postmere is closed") {
                Text(runtime.push.statusText).font(.caption).foregroundStyle(.secondary)
                if let error = runtime.push.lastError { Text(error).font(.caption).foregroundStyle(.secondary) }
            }
        }.formStyle(.grouped)
            .task { await runtime.notifications.refreshAuthorization() }
    }

    @ViewBuilder
    private var notificationPermissionControl: some View {
        let notifications = runtime.notifications
        if !notifications.hasCheckedAuthorization || notifications.isRequestingAuthorization {
            ProgressView(notifications.isRequestingAuthorization ? "Waiting for permission…" : "Checking permission…")
                .controlSize(.small)
        } else {
            switch notifications.authorizationStatus {
            case .notDetermined:
                Button("Enable Notifications…") { Task { await notifications.requestAuthorization() } }
            case .authorized:
                Label {
                    Text("Allowed")
                } icon: {
                    PostmereIcon("checkmark.circle", size: 15).foregroundStyle(palette.accentInk)
                }
                .labelStyle(.titleAndIcon)
            case .provisional:
                HStack {
                    Text("Delivered quietly")
                    systemNotificationSettingsButton
                }
            case .denied:
                HStack {
                    Text("Off")
                    systemNotificationSettingsButton
                }
            @unknown default:
                systemNotificationSettingsButton
            }
        }
    }

    private var systemNotificationSettingsButton: some View {
        Button("Open System Settings…") {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
                openURL(url)
            }
        }
    }

    @ViewBuilder
    private var notificationSchedule: some View {
        DatePicker("From", selection: minuteBinding(notificationProfile.startMinute), displayedComponents: .hourAndMinute)
        DatePicker("Until", selection: minuteBinding(notificationProfile.endMinute), displayedComponents: .hourAndMinute)
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { day in
                Toggle(Calendar.current.shortWeekdaySymbols[day - 1], isOn: Binding(get: {
                    notificationProfile.wrappedValue.weekdays.contains(day)
                }, set: { enabled in
                    if enabled { notificationProfile.wrappedValue.weekdays.insert(day) }
                    else { notificationProfile.wrappedValue.weekdays.remove(day) }
                })).toggleStyle(.button)
            }
        }
        Text("Times use your Mac’s time zone. Overnight schedules continue into the next morning.")
            .font(.caption).foregroundStyle(.secondary)
    }

    private func minuteBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: .now) ?? .now
        }, set: { date in
            minutes.wrappedValue = Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date)
        })
    }

    private var screeningSettings: some View {
        Form {
            Section("Inbox organization") {
                Button("Manage Inbox Tabs and VIPs…") { showsInboxManager = true }
                Text("Group related mail with editable rules, and keep important senders together.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sender screening") {
                Toggle("Screen unfamiliar senders", isOn: $store.senderScreeningEnabled)
                Text("New incoming senders wait in New Senders until you accept or block them. Existing mail stays where it is.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Sender rules") {
                HStack {
                    TextField("sender@example.com", text: $senderEmail)
                    Picker("Route", selection: $senderRoute) {
                        ForEach(SenderRoute.allCases) { Text($0.title).tag($0) }
                    }.labelsHidden().frame(width: 130)
                    Button("Add") {
                        guard let address = MailAddressList(senderEmail).addresses.first else { return }
                        store.saveSenderRule(SenderRule(email: address, route: senderRoute))
                        senderEmail = ""
                    }.disabled(MailAddressList(senderEmail).addresses.count != 1 || !MailAddressList(senderEmail).invalid.isEmpty)
                }
                ForEach(store.senderRules) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(rule.email).lineLimit(1)
                            Text("\(MailAccount.scopeLabel(for: rule.account, providerEmail: rule.providerAccountEmail)) · \(rule.route.title)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { store.deleteSenderRule(rule.id) }.controlSize(.small)
                    }
                }
                if store.senderRules.isEmpty { Text("No sender rules yet.").foregroundStyle(.secondary) }
            }
        }.formStyle(.grouped)
    }

    private var shortcutSettings: some View {
        Form {
            Section("Messages") {
                shortcut("New message", "⌘N")
                shortcut("Reply / Edit draft", "⌘R")
                shortcut("Reply all", "⇧⌘R")
                shortcut("Forward", "⇧⌘F")
                shortcut("Archive", "⇧⌘A")
                shortcut("Move to Trash", "⌘⌫")
                shortcut("Mark read / unread", "⇧⌘U")
                shortcut("Star / unstar", "⇧⌘L")
            }
            Section("List triage") {
                shortcut("Next / previous message", "J / K")
                shortcut("Archive / trash", "E / #")
                shortcut("Reply / star", "R / S")
                Text("Single-letter shortcuts apply only while the message list has focus. Use Shift-click or Command-click to select several messages.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Navigation and composing") {
                shortcut("Select inbox tab", "⌘1 … ⌘9")
                shortcut("Search messages", "⌘F")
                shortcut("Show mailboxes", "⌃⌘S")
                shortcut("Save draft", "⌘S")
                shortcut("Send / queue message", "⌘↩")
                shortcut("Command palette", "⌘K")
                shortcut("Attachment library", "⌥⌘A")
                shortcut("Close composer", "Esc")
            }
        }
        .formStyle(.grouped)
    }

    private func shortcut(_ title: String, _ keys: String) -> some View {
        LabeledContent(title) {
            Text(keys).font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(keys)
    }
}
