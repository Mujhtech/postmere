import SwiftUI
import UserNotifications

struct SettingsView: View {
    @Environment(\.postmereAccent) private var palette
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
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
    @AppStorage(MailReadingFont.preference) private var readingFont = MailReadingFont.original
    @AppStorage("showMessagePreviews") private var showMessagePreviews = true
    @AppStorage("showContactPhotos") private var showContactPhotos = true
    @AppStorage(MenuBarInboxHost.visibilityPreference) private var showsMenuBarInbox = true
    @AppStorage("loadRemoteMailImagesAutomatically") private var loadRemoteMailImagesAutomatically = true
    @AppStorage("blockSenderTrackingPixels") private var blockSenderTrackingPixels = true
    @Environment(\.mailboxTheme) private var theme
    @AppStorage("defaultSendingAccount") private var defaultSendingAccount = ""

    var body: some View {
        TabView(selection: $settingsTab) {
            generalSettings.tabItem { PostmereLabel("General", symbol: "gearshape", size: 18) }.tag("general")
            MailAppearanceSettings().tabItem { PostmereLabel("Appearance", symbol: "paintpalette", size: 18) }.tag("appearance")
            composingSettings.tabItem { PostmereLabel("Composing", symbol: "square.and.pencil", size: 18) }.tag("composing")
            accountSettings.tabItem { PostmereLabel("Accounts", symbol: "person.crop.circle", size: 18) }.tag("accounts")
            aiSettings.tabItem { PostmereLabel("AI", symbol: "sparkles", size: 18) }.tag("ai")
            PluginSettingsView(session: runtime.backend).tabItem { PostmereLabel("Plugins", symbol: "puzzlepiece", size: 18) }.tag("plugins")
            privacySettings.tabItem { PostmereLabel("Privacy", symbol: "shield", size: 18) }.tag("privacy")
            notificationSettings.tabItem { PostmereLabel("Notifications", symbol: "bell", size: 18) }.tag("notifications")
            rulesSettings.tabItem { PostmereLabel("Rules", symbol: "line.3.horizontal.decrease.circle", size: 18) }.tag("rules")
            shortcutSettings.tabItem { PostmereLabel("Shortcuts", symbol: "keyboard", size: 18) }.tag("shortcuts")
        }
        .scrollContentBackground(theme == .native ? .automatic : .hidden)
        .padding(.top, 8)
        .frame(width: 790, height: 600)
        .background { SettingsTabForeground(palette: palette, selection: settingsTab).frame(width: 0, height: 0) }
        .mailboxWindowSurface()
        .sheet(isPresented: $showsInboxManager) { InboxManagementView(store: store) }
        .onChange(of: MailAccount.allCases.map(\.rawValue), initial: true) {
            if !MailAccount.allCases.contains(where: { $0.rawValue == selectedNotificationAccount }) {
                selectedNotificationAccount = (MailAccount.allCases.first(where: \.isConnected) ?? MailAccount.allCases.first)?.rawValue ?? ""
            }
        }
    }

    // MARK: General

    private var generalSettings: some View {
        Form {
            Section {
                defaultMailRow
                SettingsToggle("Menu bar inbox", symbol: "desktopcomputer", tint: SettingsTint.gray,
                               subtitle: "Glance at new mail from the menu bar", isOn: $showsMenuBarInbox)
            }
            Section("Updates") {
                UpdateSettingsRows()
            }
            Section("Reading") {
                SettingsToggle("Message previews", symbol: "eye", tint: SettingsTint.teal,
                               subtitle: "Show the first lines in the list", isOn: $showMessagePreviews)
                SettingsToggle("Contact photos", symbol: "person.crop.circle", tint: SettingsTint.blue,
                               subtitle: "Show sender photos in the list", isOn: $showContactPhotos)
                SettingsRow("Font", symbol: "textformat", tint: SettingsTint.indigo) {
                    Picker("Font", selection: $readingFont) {
                        Text(MailReadingFont.original.title).tag(MailReadingFont.original)
                        Section("System") {
                            ForEach(MailReadingFont.systemFonts, id: \.self) { Text($0.title).tag($0) }
                        }
                        Section("Mac fonts") {
                            ForEach(MailReadingFont.macFonts, id: \.self) { Text($0.title).tag($0) }
                        }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsRow("Text size", symbol: "textformat", tint: SettingsTint.indigo) {
                    HStack(spacing: 8) {
                        Text("A").font(.system(size: 11)).foregroundStyle(.secondary)
                        Slider(value: $readingFontSize, in: 12...20, step: 1) { Text("Text size") }
                            .labelsHidden().frame(width: 140).controlSize(.small)
                            .accessibilityValue("\(Int(readingFontSize)) points")
                        Text("A").font(.system(size: 16)).foregroundStyle(.secondary)
                    }
                }
                readingPreview
            }
        }
        .formStyle(.grouped)
        .task(id: settingsTab == "general" && scenePhase == .active) {
            guard settingsTab == "general", scenePhase == .active || runtime.defaultMail.status == nil else { return }
            await runtime.defaultMail.refresh()
        }
    }

    private var defaultMailRow: some View {
        let service = runtime.defaultMail
        let subtitle: String? = switch service.status {
        case .other(let name): "Currently \(name ?? "another app")"
        case .postmere: "Links and emails open here"
        case nil: nil
        }
        return VStack(alignment: .leading, spacing: 6) {
            SettingsRow("Default mail app", symbol: "envelope", tint: SettingsTint.blue, subtitle: subtitle) {
                if service.isRequesting || service.status == nil {
                    ProgressView().controlSize(.small)
                } else if case .postmere = service.status {
                    SettingsPill(title: "Postmere")
                } else {
                    Button("Make Default") { Task { await service.makeDefault() } }
                        .controlSize(.small)
                }
            }
            if let error = service.errorMessage {
                Text(error).font(.system(size: 11.5)).foregroundStyle(.red).textSelection(.enabled)
            }
        }
    }

    /// The chosen font and size, as a message would show it.
    private var readingPreview: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Re: Friday’s review")
                .font(readingFont.font(size: readingFontSize).weight(.semibold))
            Text("Thanks — the draft reads well. One small note on the timeline, then we’re good to go.")
                .font(readingFont.font(size: readingFontSize))
                .foregroundStyle(.primary.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PostmereTheme.paper, in: .rect(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(PostmereTheme.rule))
        .animation(.snappy(duration: 0.2), value: readingFontSize)
        .accessibilityLabel("Reading font preview")
    }

    // MARK: Composing

    private var composingSettings: some View {
        Form {
            Section {
                SettingsRow("Send from", symbol: "paperplane", tint: SettingsTint.blue,
                            subtitle: "Replies use the account that received the message") {
                    if MailAccount.sendingAccounts.isEmpty {
                        AccountSettingsButton(title: MailAccount.allCases.isEmpty ? "Add Account" : "Reconnect")
                            .controlSize(.small)
                    } else {
                        Picker("Send from", selection: $defaultSendingAccount) {
                            if !MailAccount.allCases.contains(where: { $0.rawValue == defaultSendingAccount }) {
                                Text("Choose").tag(defaultSendingAccount)
                            }
                            ForEach(MailAccount.allCases, id: \.self) { account in
                                AccountMenuLabel(account: account).tag(account.rawValue).disabled(!account.isConnected)
                            }
                        }
                        .labelsHidden().fixedSize()
                    }
                }
                SettingsRow("Undo Send", symbol: "arrow.uturn.backward", tint: SettingsTint.orange,
                            subtitle: "Time to take a message back") {
                    Picker("Undo Send", selection: $undoSendDelay) {
                        ForEach([5.0, 10.0, 20.0, 30.0, 60.0], id: \.self) { Text("\(Int($0)) s").tag($0) }
                    }
                    .labelsHidden().fixedSize()
                }
                SettingsToggle("Markdown shortcuts", symbol: "bold", tint: SettingsTint.purple,
                               subtitle: "**bold**, *italic*, `code` and lists as you type", isOn: $markdownSubstitutions)
            }
            Section("Signature") {
                SignatureEditorView(accounts: MailAccount.allCases.filter { !$0.email.isEmpty }.map {
                    MailSignatureAccount(id: $0.rawValue, title: $0.title, detail: $0.email)
                })
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Accounts and AI

    private var accountSettings: some View {
        BackendConnectionView(session: runtime.backend, store: store, onSync: runtime.sync)
    }

    private var aiSettings: some View {
        MailAISettingsView(session: runtime.backend)
    }

    // MARK: Privacy

    private var privacySettings: some View {
        Form {
            Section("Incoming mail") {
                SettingsToggle("Load remote images", symbol: "eye", tint: SettingsTint.blue,
                               subtitle: "Image hosts can see your IP address", isOn: $loadRemoteMailImagesAutomatically)
                SettingsToggle("Block tracking pixels", symbol: "shield", tint: SettingsTint.green,
                               subtitle: "Stops senders seeing when you open mail", isOn: $blockSenderTrackingPixels)
            }
            Section("Sender photos") {
                SettingsRow("Contacts", symbol: "person.crop.circle", tint: SettingsTint.gray,
                            subtitle: "Use photos from your address book") {
                    ContactPhotoAccess().controlSize(.small)
                }
                SettingsToggle("Organization icons", symbol: "building.2", tint: SettingsTint.indigo,
                               subtitle: "Sends the sender’s domain to Bitwarden",
                               isOn: Bindable(MailRemoteParticipantImages.websiteIcons).enabled)
                SettingsToggle("Gravatar", symbol: "at", tint: SettingsTint.teal,
                               subtitle: "Sends a hash of the address to Gravatar",
                               isOn: Bindable(MailRemoteParticipantImages.gravatar).enabled)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Notifications

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
                SettingsRow("Notifications", symbol: "bell", tint: SettingsTint.red) { notificationPermissionControl }
                SettingsToggle("Dock badge", symbol: "tray", tint: SettingsTint.red,
                               subtitle: "Unread count on the Dock icon", isOn: Bindable(runtime.mailboxCounts).showsUnreadInDock)
                if let error = runtime.notifications.authorizationError {
                    Text(error).font(.system(size: 11.5)).foregroundStyle(.red)
                }
            }
            Section("Per account") {
                if MailAccount.allCases.isEmpty {
                    SettingsRow("No accounts yet", symbol: "envelope", tint: SettingsTint.gray) {
                        AccountSettingsButton(title: "Add Account").controlSize(.small)
                    }
                } else {
                    SettingsRow("Account", symbol: "envelope", tint: SettingsTint.blue) {
                        Picker("Account", selection: $selectedNotificationAccount) {
                            ForEach(MailAccount.allCases) { account in
                                AccountMenuLabel(account: account).tag(account.rawValue)
                            }
                        }
                        .labelsHidden().fixedSize()
                    }
                    if let account = MailAccount(rawValue: selectedNotificationAccount), !account.isConnected {
                        SettingsRow("Reconnect to get alerts", symbol: "exclamationmark.circle", tint: SettingsTint.orange) {
                            AccountSettingsButton(title: "Open Accounts").controlSize(.small)
                        }
                    }
                    SettingsToggle("Alerts", symbol: "bell.badge", tint: SettingsTint.red, isOn: notificationProfile.enabled)
                    if notificationProfile.wrappedValue.enabled {
                        SettingsToggle("Show subject", symbol: "doc.text", tint: SettingsTint.gray, isOn: notificationProfile.showPreview)
                        SettingsToggle("Quiet hours", symbol: "moon.zzz", tint: SettingsTint.indigo,
                                       subtitle: "Only alert during a schedule", isOn: notificationProfile.scheduleEnabled)
                        if notificationProfile.wrappedValue.scheduleEnabled { notificationSchedule }
                    }
                }
                if let error = runtime.notifications.lastError {
                    Text(error).font(.system(size: 11.5)).foregroundStyle(.red)
                }
            }
            Section {
                SettingsRow("Focus filters", symbol: "moon.zzz", tint: SettingsTint.purple,
                            subtitle: "Choose which accounts can alert during a Focus") {
                    Button("Open Focus") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.Focus-Settings.extension") { openURL(url) }
                    }
                    .controlSize(.small)
                }
                SettingsRow("While closed", symbol: "desktopcomputer", tint: SettingsTint.gray,
                            subtitle: runtime.push.lastError ?? runtime.push.statusText) { EmptyView() }
            }
        }
        .formStyle(.grouped)
        .task { await runtime.notifications.refreshAuthorization() }
    }

    @ViewBuilder
    private var notificationPermissionControl: some View {
        let notifications = runtime.notifications
        if !notifications.hasCheckedAuthorization || notifications.isRequestingAuthorization {
            ProgressView().controlSize(.small)
        } else {
            switch notifications.authorizationStatus {
            case .notDetermined:
                Button("Turn On") { Task { await notifications.requestAuthorization() } }.controlSize(.small)
            case .authorized:
                SettingsPill(title: "On")
            case .provisional:
                HStack(spacing: 8) {
                    SettingsPill(title: "Quiet", tint: SettingsTint.orange, symbol: nil)
                    SystemNotificationSettingsButton(title: "Change").controlSize(.small)
                }
            case .denied:
                HStack(spacing: 8) {
                    SettingsPill(title: "Off", tint: SettingsTint.gray, symbol: nil)
                    SystemNotificationSettingsButton(title: "Turn On").controlSize(.small)
                }
            @unknown default:
                SystemNotificationSettingsButton(title: "Settings").controlSize(.small)
            }
        }
    }

    private var notificationSchedule: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                DatePicker("From", selection: minuteBinding(notificationProfile.startMinute), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Text("to").foregroundStyle(.secondary)
                DatePicker("Until", selection: minuteBinding(notificationProfile.endMinute), displayedComponents: .hourAndMinute)
                    .labelsHidden()
                Spacer()
            }
            HStack(spacing: 6) {
                ForEach(1...7, id: \.self) { day in
                    let on = notificationProfile.wrappedValue.weekdays.contains(day)
                    Button {
                        if on { notificationProfile.wrappedValue.weekdays.remove(day) }
                        else { notificationProfile.wrappedValue.weekdays.insert(day) }
                    } label: {
                        Text(Calendar.current.veryShortWeekdaySymbols[day - 1])
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(on ? Color.white : Color.secondary)
                            .frame(width: 26, height: 26)
                            .background(on ? palette.accent : PostmereTheme.rule.opacity(0.6), in: Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Calendar.current.weekdaySymbols[day - 1])
                    .accessibilityAddTraits(on ? .isSelected : [])
                    .animation(.snappy(duration: 0.15), value: on)
                }
            }
        }
        .padding(.leading, 35)
        .help("Uses your Mac’s time zone; overnight schedules run into the next morning.")
    }

    private func minuteBinding(_ minutes: Binding<Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(bySettingHour: minutes.wrappedValue / 60, minute: minutes.wrappedValue % 60, second: 0, of: .now) ?? .now
        }, set: { date in
            minutes.wrappedValue = Calendar.current.component(.hour, from: date) * 60 + Calendar.current.component(.minute, from: date)
        })
    }

    // MARK: Rules

    private var canAddSenderRule: Bool {
        let list = MailAddressList(senderEmail)
        return list.addresses.count == 1 && list.invalid.isEmpty
    }

    private var rulesSettings: some View {
        Form {
            Section {
                SettingsRow("Inbox tabs and VIPs", symbol: "tray", tint: SettingsTint.blue,
                            subtitle: "Group mail with rules and keep key people together") {
                    Button("Manage…") { showsInboxManager = true }.controlSize(.small)
                }
                SettingsToggle("Screen new senders", symbol: "person.crop.circle.badge.questionmark", tint: SettingsTint.orange,
                               subtitle: "First-time senders wait in New Senders", isOn: $store.senderScreeningEnabled)
            }
            Section("Sender rules") {
                HStack(spacing: 8) {
                    TextField("Sender", text: $senderEmail, prompt: Text("name@example.com"))
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(addSenderRule)
                    Picker("Route", selection: $senderRoute) {
                        ForEach(SenderRoute.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Button("Add", action: addSenderRule).disabled(!canAddSenderRule)
                }
                ForEach(store.senderRules) { rule in
                    HStack(spacing: 10) {
                        ParticipantPhoto(address: rule.domain.map { "hello@\($0)" } ?? rule.email, name: rule.displayName, size: 26, verifiedMark: nil)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.displayName).font(.system(size: 13)).lineLimit(1).truncationMode(.middle)
                            Text(MailAccount.scopeLabel(for: rule.account, providerEmail: rule.providerAccountEmail))
                                .font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        SettingsPill(title: rule.route.title, tint: routeTint(rule.route), symbol: nil)
                        Button { store.deleteSenderRule(rule.id) } label: {
                            PostmereIcon("xmark", size: 10).foregroundStyle(.secondary)
                                .frame(width: 20, height: 20)
                                .background(PostmereTheme.rule.opacity(0.5), in: Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Remove rule")
                        .accessibilityLabel("Remove rule for \(rule.displayName)")
                    }
                }
                if store.senderRules.isEmpty {
                    Text("Route a sender straight to a mailbox, or block them.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func addSenderRule() {
        guard canAddSenderRule, let address = MailAddressList(senderEmail).addresses.first else { return }
        store.saveSenderRule(SenderRule(email: address, route: senderRoute))
        senderEmail = ""
    }

    private func routeTint(_ route: SenderRoute) -> Color {
        switch route {
        case .inbox: SettingsTint.blue
        case .archive: SettingsTint.gray
        case .needsReply: SettingsTint.orange
        case .blocked: SettingsTint.red
        }
    }

    // MARK: Shortcuts

    private var shortcutSettings: some View {
        Form {
            Section("Messages") {
                shortcut("New message", ["⌘", "N"])
                shortcut("Reply", ["⌘", "R"])
                shortcut("Reply all", ["⇧", "⌘", "R"])
                shortcut("Forward", ["⇧", "⌘", "F"])
                shortcut("Archive", ["⇧", "⌘", "A"])
                shortcut("Move to Trash", ["⌘", "⌫"])
                shortcut("Mark read or unread", ["⇧", "⌘", "U"])
                shortcut("Star", ["⇧", "⌘", "L"])
            }
            Section("In the message list") {
                shortcut("Next or previous", ["J"], or: ["K"])
                shortcut("Archive or trash", ["E"], or: ["#"])
                shortcut("Reply or star", ["R"], or: ["S"])
            }
            Section("Getting around") {
                shortcut("Inbox tabs", ["⌘", "1"], or: ["⌘", "9"], joiner: "–")
                shortcut("Search", ["⌘", "F"])
                shortcut("Command palette", ["⌘", "K"])
                shortcut("Show mailboxes", ["⌃", "⌘", "S"])
                shortcut("Attachment library", ["⌥", "⌘", "A"])
            }
            Section("Composing") {
                shortcut("Send", ["⌘", "↩"])
                shortcut("Save draft", ["⌘", "S"])
                shortcut("Write with AI", ["⌘", "J"])
                shortcut("Close", ["esc"])
            }
        }
        .formStyle(.grouped)
    }

    private func shortcut(_ title: String, _ keys: [String], or alternate: [String]? = nil, joiner: String = "or") -> some View {
        HStack {
            Text(title).font(.system(size: 13))
            Spacer()
            HStack(spacing: 3) {
                ForEach(Array(keys.enumerated()), id: \.offset) { SettingsKeyCap($0.element) }
                if let alternate {
                    Text(joiner).font(.system(size: 11)).foregroundStyle(.tertiary).padding(.horizontal, 3)
                    ForEach(Array(alternate.enumerated()), id: \.offset) { SettingsKeyCap($0.element) }
                }
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue((keys + (alternate.map { [joiner] + $0 } ?? [])).joined(separator: " "))
    }
}

/// An account's address with its provider's logo, for pickers and menus.
struct AccountMenuLabel: View {
    let account: MailAccount

    var body: some View {
        if let brand = account.remote.flatMap({ Brand(mailProvider: $0.provider) }) {
            Label { Text(account.titleWithEmail) } icon: { brand.menuImage() }
        } else {
            Text(account.titleWithEmail)
        }
    }
}

/// Sparkle's preferences: daily checks, optional background downloads, and
/// a manual check with when it last ran.
private struct UpdateSettingsRows: View {
    @State private var updater = AppUpdater.shared
    @State private var checksAutomatically = AppUpdater.shared.checksAutomatically
    @State private var downloadsAutomatically = AppUpdater.shared.downloadsAutomatically

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "–"
        let build = info?["CFBundleVersion"] as? String ?? "–"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        SettingsRow("Postmere", symbol: "arrow.clockwise", tint: SettingsTint.blue,
                    subtitle: updater.lastCheck.map { "\(version) · Checked \($0.formatted(.relative(presentation: .named)))" } ?? version) {
            Button("Check Now") { updater.checkForUpdates() }
                .controlSize(.small)
                .disabled(!updater.canCheckForUpdates)
        }
        SettingsToggle("Check automatically", symbol: "clock", tint: SettingsTint.teal,
                       subtitle: "Look for a new version once a day", isOn: $checksAutomatically)
            .onChange(of: checksAutomatically) { _, value in updater.checksAutomatically = value }
        if checksAutomatically {
            SettingsToggle("Download in the background", symbol: "arrow.down.to.line", tint: SettingsTint.green,
                           subtitle: "Install the next time Postmere quits", isOn: $downloadsAutomatically)
                .onChange(of: downloadsAutomatically) { _, value in updater.downloadsAutomatically = value }
        }
    }
}
