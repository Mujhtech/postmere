import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Bindable var store: MailStore
    @Bindable var runtime: MailRuntime
    @AppStorage("markdownSubstitutions") private var markdownSubstitutions = true
    @AppStorage("undoSendDelay") private var undoSendDelay = 10.0
    @State private var selectedNotificationAccount = ""
    @State private var senderEmail = ""
    @State private var senderRoute: SenderRoute = .inbox
    @State private var showsInboxManager = false
    @AppStorage("settingsTab") private var settingsTab = "general"
    @AppStorage("readingFontSize") private var readingFontSize = 14.0
    @AppStorage("showMessagePreviews") private var showMessagePreviews = true
    @AppStorage("appearance") private var appearance: MailAppearance = .system
    @AppStorage("defaultSendingAccount") private var defaultSendingAccount = ""

    var body: some View {
        TabView(selection: $settingsTab) {
            readingSettings.tabItem { PostmereLabel("General", symbol: "gearshape", size: 18) }.tag("general")
            composingSettings.tabItem { PostmereLabel("Composing", symbol: "square.and.pencil", size: 18) }.tag("composing")
            accountSettings.tabItem { PostmereLabel("Accounts", symbol: "person.crop.circle", size: 18) }.tag("accounts")
            notificationSettings.tabItem { PostmereLabel("Notifications", symbol: "bell", size: 18) }.tag("notifications")
            screeningSettings.tabItem { PostmereLabel("Rules", symbol: "line.3.horizontal.decrease.circle", size: 18) }.tag("rules")
            shortcutSettings.tabItem { PostmereLabel("Shortcuts", symbol: "keyboard", size: 18) }.tag("shortcuts")
        }
        .padding(.top, 8)
        .tint(PostmereTheme.accent)
        .frame(width: 640, height: 590)
        .sheet(isPresented: $showsInboxManager) { InboxManagementView(store: store) }
        .onChange(of: MailAccount.allCases.map(\.rawValue), initial: true) {
            if !MailAccount.allCases.contains(where: { $0.rawValue == selectedNotificationAccount }) {
                selectedNotificationAccount = MailAccount.allCases.first?.rawValue ?? ""
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
        .scrollIndicators(.never)
        .formStyle(.grouped)
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
        .scrollIndicators(.never)
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
            Section("Permission") {
                HStack {
                    Text(notificationPermissionText)
                    Spacer()
                    Button("Enable Notifications") { Task { await runtime.notifications.requestAuthorization() } }
                }
                if let error = runtime.notifications.lastError { Text(error).font(.caption).foregroundStyle(.red) }
            }
            Section("Account schedule") {
                Picker("Account", selection: $selectedNotificationAccount) {
                    if MailAccount.allCases.isEmpty { Text("No accounts connected").tag("") }
                    ForEach(MailAccount.allCases) { Text($0.email).tag($0.rawValue) }
                }
                Toggle("Allow notifications", isOn: notificationProfile.enabled)
                Toggle("Show message subject", isOn: notificationProfile.showPreview)
                    .disabled(!notificationProfile.wrappedValue.enabled)
                Toggle("Only during these hours", isOn: notificationProfile.scheduleEnabled)
                    .disabled(!notificationProfile.wrappedValue.enabled)
                if notificationProfile.wrappedValue.scheduleEnabled {
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
                    Text("Times use your Mac’s time zone. Overnight schedules continue into the next morning.").font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(MailAccount.allCases.isEmpty)
            Section("Focus") {
                Text("In System Settings → Focus, add Postmere as a Focus Filter to choose which accounts may notify you. Your Focus and notification permissions still apply.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Section("While Postmere is closed") {
                Text(runtime.push.statusText).font(.caption).foregroundStyle(.secondary)
                if let error = runtime.push.lastError { Text(error).font(.caption).foregroundStyle(.secondary) }
                Text("Apple push delivery follows your account schedules and system Focus settings while you stay signed in. Sign-in continues until you sign out or workspace access is revoked. Accounts with local sender screening or blocking rules use local notifications while Postmere is open.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }.formStyle(.grouped).scrollIndicators(.never)
            .task { await runtime.notifications.refreshAuthorization() }
    }

    private var notificationPermissionText: String {
        switch runtime.notifications.authorizationStatus {
        case .authorized, .provisional: "Notifications are allowed"
        case .denied: "Notifications are disabled in System Settings"
        default: "Notifications are off until you enable them"
        }
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
        }.formStyle(.grouped).scrollIndicators(.never)
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
        .scrollIndicators(.never)
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
