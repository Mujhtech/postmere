import SwiftUI
import UserNotifications

struct MobileSettings: View {
    let runtime: MailRuntime
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @AppStorage(MailAppearance.preferenceKey) private var appearance = MailAppearance.system
    @AppStorage(PostmereAccent.preferenceKey) private var accent = PostmereAccent.defaultRGB
    @AppStorage(MailReadingFont.preference) private var readingFont = MailReadingFont.original
    @AppStorage("readingFontSize") private var fontSize = 14.0
    @AppStorage("loadRemoteMailImagesAutomatically") private var automaticImages = true
    @AppStorage("blockSenderTrackingPixels") private var blocksTrackers = true
    @AppStorage(MailSpotlightIndexer.preferenceKey) private var spotlightIndexes = true
    @AppStorage("undoSendDelay") private var undoSendDelay = 10.0
    @State private var connection = MailAccountConnection()
    @State private var addsAccount = false
    @State private var confirmsSignOut = false

    private var session: BackendSession { runtime.backend }
    private var notifications: MailNotificationService { runtime.notifications }

    /// The Mac's accent presets.
    static let swatches: [(String, Int)] = [
        ("Postmere green", PostmereAccent.defaultRGB), ("Ocean", 0x367FA8), ("Indigo", 0x6257B4),
        ("Violet", 0x9A62AF), ("Rose", 0xBC5971), ("Copper", 0xBC7542), ("Slate", 0x697882),
    ]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    profile
                        .navigationDestination(isPresented: Binding(get: { MobileRouter.shared.opensAssistants },
                                                                    set: { MobileRouter.shared.opensAssistants = $0 })) {
                            MobileAssistantsSettings(runtime: runtime)
                        }
                    group("Mail") {
                        NavigationLink { MobileInboxTabsSettings(store: runtime.store) } label: {
                            SettingsRow(symbol: "rectangle.split.3x1.fill", tint: .blue, title: "Inbox Tabs",
                                        value: "\(runtime.store.visibleInboxSplits.count) shown")
                        }
                        divider
                        NavigationLink { MobileSenderRulesSettings(store: runtime.store) } label: {
                            SettingsRow(symbol: "person.crop.circle.badge.checkmark", tint: .green, title: "Sender Rules",
                                        value: runtime.store.senderRules.count.formatted())
                        }
                        divider
                        NavigationLink { MobileSnippetLibrary(store: runtime.store) } label: {
                            SettingsRow(symbol: "text.badge.plus", tint: .orange, title: "Snippets & Templates",
                                        value: runtime.store.snippets.count.formatted())
                        }
                        divider
                        NavigationLink { MobileNotificationSettings(runtime: runtime) } label: {
                            SettingsRow(symbol: "bell.badge.fill", tint: .red, title: "Notifications", value: notificationValue)
                        }
                    }
                    group("Look & Feel") {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("Appearance").font(.subheadline.weight(.semibold))
                            HStack(spacing: 12) {
                                ForEach(MailAppearance.allCases, id: \.self) { option in appearanceTile(option) }
                            }
                            Text("Accent").font(.subheadline.weight(.semibold)).padding(.top, 4)
                            HStack(spacing: 0) {
                                ForEach(Self.swatches, id: \.1) { name, rgb in swatch(name, rgb: rgb) }
                            }
                        }
                        .padding(16)
                        divider
                        readingCard
                    }
                    group("Sending", footer: "Time to take a message back after tapping Send.") {
                        VStack(alignment: .leading, spacing: 12) {
                            SettingsRow(symbol: "arrow.uturn.backward", tint: .indigo, title: "Undo Send", chevron: false)
                                .padding(.horizontal, -16)
                            HStack(spacing: 8) {
                                ForEach([5.0, 10.0, 20.0, 30.0, 60.0], id: \.self) { seconds in
                                    chip("\(Int(seconds))s", selected: undoSendDelay == seconds) { undoSendDelay = seconds }
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.bottom, 14)
                    }
                    if session.canAccessWorkspace {
                        group("Team", footer: "Conversations shared from this workspace, and who can see them.") {
                            NavigationLink { MobileSharedThreadsScreen(runtime: runtime) } label: {
                                SettingsRow(symbol: "bubble.left.and.bubble.right.fill", tint: .cyan, title: "Shared with Team")
                            }
                            divider
                            NavigationLink { MobileMembersSettings(session: session) } label: {
                                SettingsRow(symbol: "person.2.fill", tint: .blue, title: "Members")
                            }
                            divider
                            NavigationLink { MobileBookingLinksScreen(session: session) } label: {
                                SettingsRow(symbol: "calendar.badge.clock", tint: .red, title: "Booking Links")
                            }
                        }
                    }
                    if session.canAccessWorkspace {
                        group("Intelligence") {
                            NavigationLink { MobileAISettings(runtime: runtime) } label: {
                                SettingsRow(symbol: "sparkles", tint: palette.accent, title: "AI Writing & Answers")
                            }
                            divider
                            NavigationLink { MobileAssistantsSettings(runtime: runtime) } label: {
                                SettingsRow(symbol: "point.3.connected.trianglepath.dotted", tint: .orange, title: "Assistants",
                                            value: runtime.assistants.working.isEmpty
                                                ? (runtime.assistants.connections.isEmpty ? nil : runtime.assistants.connections.count.formatted())
                                                : "\(runtime.assistants.working.count) working")
                            }
                            divider
                            NavigationLink { MobilePluginSettings(runtime: runtime) } label: {
                                SettingsRow(symbol: "puzzlepiece.extension.fill", tint: .purple, title: "Plugins")
                            }
                        }
                    }
                    group("Privacy", footer: "Messages never run scripts. Remote images can tell senders when you read their mail. Spotlight keeps the subject, sender and a preview of recent mail on this iPhone only.") {
                        toggleRow(symbol: "photo.fill", tint: .teal, title: "Load Remote Images", isOn: $automaticImages)
                        divider
                        toggleRow(symbol: "eye.slash.fill", tint: .gray, title: "Block Tracking Pixels", isOn: $blocksTrackers)
                        divider
                        toggleRow(symbol: "magnifyingglass", tint: .indigo, title: "Show Mail in Spotlight", isOn: $spotlightIndexes)
                            .onChange(of: spotlightIndexes) {
                                if spotlightIndexes {
                                    runtime.spotlight.update(messages: runtime.store.messages, signedIn: runtime.backend.canAccessWorkspace)
                                } else {
                                    runtime.spotlight.clear()
                                }
                            }
                        divider
                        NavigationLink { MobileSenderPhotoSettings() } label: {
                            SettingsRow(symbol: "person.crop.circle.fill", tint: .blue, title: "Sender Photos")
                        }
                    }
                    signOut
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
            .mobileSettingsCanvas()
            .buttonStyle(.plain)
            .tint(palette.accent)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .task { await notifications.refreshAuthorization() }
        }
    }

    // MARK: Profile

    /// Who's signed in, each account, and adding another.
    private var profile: some View {
        let primary = session.accounts.first
        return VStack(spacing: 0) {
            VStack(spacing: 8) {
                MobileAccountAvatar(address: primary?.email ?? "", name: primary?.displayName ?? "",
                                    provider: primary?.provider, size: 72)
                    .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
                Text(primary?.name ?? primary?.displayName ?? primary?.email ?? "Postmere")
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                workspaceChip
            }
            .padding(.top, 18)
            .padding(.bottom, 16)
            VStack(spacing: 0) {
                ForEach(session.accounts) { account in
                    NavigationLink {
                        MobileAccountsSettings(runtime: runtime)
                    } label: {
                        HStack(spacing: 12) {
                            MobileAccountAvatar(address: account.email, name: account.displayName ?? "",
                                                provider: account.provider, size: 34)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.name ?? account.email).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                Text(account.status == "connected"
                                     ? [account.name == nil ? nil : account.email, Brand.providerName(account.provider)]
                                        .compactMap(\.self).joined(separator: " · ")
                                     : "Needs reconnecting")
                                    .font(.caption)
                                    .foregroundStyle(account.status == "connected" ? AnyShapeStyle(.secondary)
                                                     : AnyShapeStyle(PostmereTheme.destructiveInk))
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                    }
                    MobileHairline(leading: 62)
                }
                Button {
                    withAnimation(.snappy) { addsAccount.toggle() }
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "plus")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(palette.accent)
                            .frame(width: 34, height: 34)
                            .background(palette.accent.opacity(0.12), in: Circle())
                        Text("Add Account").font(.subheadline.weight(.semibold)).foregroundStyle(palette.accent)
                        Spacer()
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                if addsAccount || connection.provider != nil {
                    MobileProviderButtons(runtime: runtime, connection: connection)
                        .padding([.horizontal, .bottom], 16)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .mobileSettingsCard()
        }
    }

    // MARK: Look & feel

    private func appearanceTile(_ option: MailAppearance) -> some View {
        let selected = appearance == option
        return Button { withAnimation(.snappy) { appearance = option } } label: {
            VStack(spacing: 8) {
                AppearancePreview(option: option, accent: palette.accent)
                    .frame(height: 74)
                    .overlay {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(selected ? palette.accent : Color(uiColor: .separator), lineWidth: selected ? 2.5 : 0.5)
                    }
                Text(option.title)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func swatch(_ name: String, rgb: Int) -> some View {
        let selected = accent == rgb
        return Button { withAnimation(.snappy) { accent = rgb } } label: {
            Circle()
                .fill(PostmereAccent(rgb: rgb).swatch)
                .frame(width: 30, height: 30)
                .padding(4)
                .overlay { Circle().strokeBorder(selected ? PostmereAccent(rgb: rgb).swatch : .clear, lineWidth: 2.5) }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The reading font and size, with the result shown as you change them.
    private var readingCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Reading").font(.subheadline.weight(.semibold))
                Spacer()
                Menu {
                    Picker("Font", selection: $readingFont) {
                        ForEach([MailReadingFont.original] + MailReadingFont.systemFonts, id: \.self) { Text($0.title).tag($0) }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(readingFont.title)
                        Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold))
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(palette.accent)
                }
            }
            Text("The quick brown fox reads your mail before breakfast.")
                .font(.system(size: fontSize + 3, design: readingFont.previewDesign))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .animation(.snappy, value: fontSize)
            HStack(spacing: 14) {
                Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary)
                Slider(value: $fontSize, in: 10...26, step: 1)
                Image(systemName: "textformat.size.larger").foregroundStyle(.secondary)
                Text("\(Int(fontSize) + 3)")
                    .font(.subheadline.weight(.semibold))
                    .monospacedDigit()
                    .frame(width: 26, alignment: .trailing)
            }
        }
        .padding(16)
    }

    // MARK: Pieces

    private func group<Content: View>(_ title: String, footer: String? = nil,
                                      @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(0.6)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
            VStack(spacing: 0, content: content)
                .mobileSettingsCard()
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 16)
            }
        }
    }

    private var divider: some View { MobileHairline(leading: 60) }

    private func toggleRow(symbol: String, tint: Color, title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            SettingsRow(symbol: symbol, tint: tint, title: title, chevron: false)
            Toggle(title, isOn: isOn).labelsHidden().padding(.trailing, 16)
        }
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: { withAnimation(.snappy) { action() } }) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(selected ? .white : .primary)
                .frame(maxWidth: .infinity, minHeight: 36)
                .background(selected ? palette.accent : Color(uiColor: .tertiarySystemFill), in: Capsule())
        }
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The server, or with several workspaces a menu to switch between them.
    @ViewBuilder private var workspaceChip: some View {
        let host = URL(string: session.baseURL)?.host ?? session.baseURL
        Group {
            if session.workspaces.count > 1, let current = session.currentWorkspace {
                Menu {
                    Section("Switch workspace") {
                        ForEach(session.workspaces) { workspace in
                            Button {
                                guard workspace.id != current.id else { return }
                                Task { await session.switchWorkspace(to: workspace.id) }
                            } label: {
                                Label {
                                    Text(workspace.name)
                                    Text(workspace.roleTitle)
                                } icon: {
                                    if workspace.id == current.id { Image(systemName: "checkmark") }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 6) {
                        WorkspaceMonogram(name: current.name, size: 18)
                        Text(current.name).lineLimit(1)
                        if session.isSwitchingWorkspace {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "chevron.up.chevron.down").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
                    .padding(.leading, 5)
                    .padding(.trailing, 10)
                    .padding(.vertical, 4)
                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                    .contentTransition(.interpolate)
                }
                .disabled(session.isBusy)
                .accessibilityLabel("Workspace, \(current.name)")
                .accessibilityHint("Switch to another workspace")
                .sensoryFeedback(.success, trigger: current.id)
                .transition(.blurReplace)
            } else {
                Label(session.currentWorkspace.map { "\($0.name) · \(host)" } ?? host, systemImage: "server.rack")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                    .transition(.blurReplace)
            }
        }
        .animation(MobileMotion.reveal, value: session.currentWorkspace)
        .task(id: session.realtimeGeneration) { await session.refreshWorkspaces() }
        if let error = session.errorMessage, session.workspaces.count > 1 {
            Text(error).font(.caption).foregroundStyle(PostmereTheme.destructiveInk)
                .multilineTextAlignment(.center).padding(.horizontal, 24)
        }
    }

    private var signOut: some View {
        VStack(spacing: 10) {
            Button { confirmsSignOut = true } label: {
                Text("Sign Out")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(PostmereTheme.destructiveInk)
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .mobileSettingsCard(cornerRadius: 18)
            }
            .disabled(session.isBusy)
            .confirmationDialog("Sign out of this workspace?", isPresented: $confirmsSignOut, titleVisibility: .visible) {
                Button("Sign Out", role: .destructive) {
                    Task {
                        await session.logout()
                        dismiss()
                    }
                }
            } message: {
                Text("Other devices stay signed in.")
            }
            Text("Postmere \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .padding(.top, 4)
    }

    private var notificationValue: String {
        switch notifications.authorizationStatus {
        case .authorized, .provisional, .ephemeral: "On"
        case .denied: "Off"
        default: "Not set"
        }
    }

    @ViewBuilder private var notificationControl: some View {
        switch notifications.authorizationStatus {
        case .authorized, .provisional, .ephemeral:
            Text("On").font(.subheadline).foregroundStyle(.secondary)
        case .denied:
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) { MailPlatform.open(url) }
            }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(palette.accent)
        default:
            Button("Turn On") { Task { await notifications.requestAuthorization() } }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(palette.accent)
                .disabled(notifications.isRequestingAuthorization)
        }
    }
}

/// An iOS-Settings-style row: a coloured icon tile, a title, an optional value and chevron.
private struct SettingsRow: View {
    let symbol: String
    let tint: Color
    let title: String
    var value: String?
    var chevron = true

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            Text(title).font(.body).foregroundStyle(.primary)
            Spacer(minLength: 8)
            if let value { Text(value).font(.subheadline).foregroundStyle(.secondary) }
            if chevron {
                Image(systemName: "chevron.right").font(.caption.weight(.bold)).foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 52)
        .contentShape(Rectangle())
    }
}

/// A tiny phone screen in light, dark, or split for System.
private struct AppearancePreview: View {
    let option: MailAppearance
    let accent: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                switch option {
                case .light: screen(dark: false)
                case .dark: screen(dark: true)
                default:
                    HStack(spacing: 0) {
                        screen(dark: false).frame(width: proxy.size.width / 2).clipped()
                        screen(dark: true).frame(width: proxy.size.width / 2).clipped()
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityHidden(true)
    }

    private func screen(dark: Bool) -> some View {
        let ink = dark ? Color.white : Color.black
        return ZStack(alignment: .topLeading) {
            (dark ? Color(white: 0.08) : Color(white: 0.97))
            VStack(alignment: .leading, spacing: 5) {
                Capsule().fill(ink.opacity(0.7)).frame(width: 26, height: 5)
                ForEach(0..<3, id: \.self) { index in
                    HStack(spacing: 4) {
                        Circle().fill(index == 0 ? accent : ink.opacity(0.25)).frame(width: 8, height: 8)
                        Capsule().fill(ink.opacity(0.22)).frame(height: 4)
                    }
                }
            }
            .padding(9)
        }
    }
}

private extension MailReadingFont {
    var previewDesign: Font.Design {
        switch self {
        case .serif: .serif
        case .rounded: .rounded
        case .monospaced: .monospaced
        default: .default
        }
    }
}

// MARK: - Signature

/// A plain-text signature per account and where it's added. Stored on this device.
struct MobileSignatureEditor: View {
    let accountID: String
    let title: String
    @Environment(\.dismiss) private var dismiss
    @State private var signature: MailSignature
    @State private var error: String?

    init(accountID: String, title: String) {
        self.accountID = accountID
        self.title = title
        _signature = State(initialValue: MailSignatureStore.shared.signature(for: accountID))
    }

    var body: some View {
        Form {
            Section {
                TextEditor(text: $signature.text)
                    .frame(minHeight: 140)
                    .onChange(of: signature.text) { signature.rtfData = nil }
            } header: {
                Text("Signature")
            } footer: {
                Text("Formatting from a signature made on the Mac is replaced when you edit it here.")
            }
            Section("Add to") {
                Toggle("New Messages", isOn: $signature.includeInNewMessages)
                Toggle("Replies", isOn: $signature.includeInReplies)
                Toggle("Forwards", isOn: $signature.includeInForwards)
            }
            if let error {
                Text(error).foregroundStyle(PostmereTheme.destructiveInk)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Save") {
                    do {
                        try MailSignatureStore.shared.save(signature, for: accountID)
                        dismiss()
                    } catch {
                        self.error = error.localizedDescription
                    }
                }
                .fontWeight(.semibold)
            }
        }
        .mobileSettingsCanvas()
    }
}

// MARK: - Snippets

private struct MobileSnippetLibrary: View {
    @Bindable var store: MailStore

    var body: some View {
        List {
            ForEach(store.snippets) { snippet in
                VStack(alignment: .leading, spacing: 3) {
                    Label(snippet.title, systemImage: snippet.isTemplate ? "doc.text" : "text.quote")
                        .font(.body.weight(.semibold))
                    Text(snippet.body.replacingOccurrences(of: "\n", with: " "))
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .onDelete { offsets in
                for index in offsets { store.deleteSnippet(store.snippets[index].id) }
            }
            if store.snippets.isEmpty {
                ContentUnavailableView("No snippets yet", systemImage: "text.badge.plus",
                    description: Text("Save one from the composer’s snippet button."))
                    .listRowBackground(Color.clear)
            }
        }
        .mobileSettingsCanvas()
        .navigationTitle("Snippets & Templates")
    }
}

// MARK: - AI

/// Turn AI on or off for this account and set the writing style it follows.
private struct MobileAISettings: View {
    let runtime: MailRuntime
    @State private var settings: MailAISettings?
    @State private var style = ""
    @State private var error: String?
    @State private var saving = false
    @State private var learning = false

    var body: some View {
        Form {
            if let settings {
                if !settings.available {
                    Text("Your workspace administrator needs to set up an AI provider.").foregroundStyle(.secondary)
                } else {
                    Section {
                        Toggle("Use AI", isOn: Binding(get: { settings.enabled }, set: { enabled in Task { await save(enabled: enabled) } }))
                            .disabled(saving)
                    } footer: {
                        Text(settings.dataNotice)
                    }
                    Section {
                        TextEditor(text: $style).frame(minHeight: 120)
                        Button("Save Style") { Task { await save(enabled: settings.enabled) } }
                            .disabled(saving || style == settings.styleGuide)
                    } header: {
                        Text("Writing style")
                    } footer: {
                        Text("How drafts should sound, for example “Warm, brief, no exclamation marks.”")
                    }
                    if settings.enabled {
                        Section {
                            if let learned = settings.learnedStyle, !learned.isEmpty {
                                Text(learned).font(.subheadline).foregroundStyle(.secondary)
                                Button(learning ? "Learning…" : "Learn Again", systemImage: "arrow.clockwise") { Task { await learn() } }
                                    .disabled(learning)
                                Button("Forget Learned Style", role: .destructive) { Task { await save(enabled: true, learned: "") } }
                            } else {
                                Button(learning ? "Reading your sent mail…" : "Learn From My Sent Mail", systemImage: "wand.and.stars") {
                                    Task { await learn() }
                                }
                                .disabled(learning)
                            }
                        } header: {
                            Text("Your voice")
                        } footer: {
                            Text("Reads up to 25 messages you’ve sent, only your own words, and notes how you write so replies and drafts sound like you. What you type above takes priority.")
                        }
                        Section {
                            NavigationLink { MobileDescribedLabelsSettings(runtime: runtime) } label: {
                                LabeledContent("Labels You Describe", value: runtime.describedLabels.labels.filter(\.enabled).count.formatted())
                            }
                        } footer: {
                            Text("Describe a label, like “Receipts and invoices”, and new mail that fits is labelled for you.")
                        }
                    }
                    if settings.enabled && settings.decisionAvailable == true {
                        Section {
                            Toggle("Check new mail for spam", isOn: Binding(
                                get: { runtime.spamChecks.automaticChecksEnabled(for: runtime.backend) },
                                set: { runtime.spamChecks.setAutomaticChecksEnabled($0, for: runtime.backend) }))
                        } footer: {
                            Text("Suspicious new mail is checked automatically, so a warning is ready when you open it.")
                        }
                    }
                    Section {
                        LabeledContent("Provider", value: settings.provider)
                        LabeledContent("Model", value: settings.model)
                    }
                }
            } else if error == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let error { Text(error).foregroundStyle(PostmereTheme.destructiveInk) }
        }
        .mobileSettingsCanvas()
        .navigationTitle("AI")
        .task {
            do {
                let loaded: MailAISettings = try await runtime.backend.request("GET", "/v1/ai/settings")
                settings = loaded
                style = loaded.styleGuide
            } catch { self.error = error.localizedDescription }
        }
    }

    private func learn() async {
        learning = true
        defer { learning = false }
        do {
            let learned = try await MailAIAssist.learnStyle(session: runtime.backend)
            settings?.learnedStyle = learned.learnedStyle
            settings?.learnedAt = learned.learnedAt
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    private func save(enabled: Bool, learned: String? = nil) async {
        saving = true
        defer { saving = false }
        do {
            let updated: MailAISettings = try await runtime.backend.request(
                "PUT", "/v1/ai/settings", body: MailAISettingsInput(enabled: enabled, styleGuide: style, learnedStyle: learned))
            settings = updated
            style = updated.styleGuide
            error = nil
        } catch { self.error = error.localizedDescription }
    }
}

// MARK: - Labels you describe

/// Labels defined in words; new mail that fits is given the label in the account.
private struct MobileDescribedLabelsSettings: View {
    let runtime: MailRuntime
    @State private var editing: MailDescribedLabel?
    @Environment(\.postmereAccent) private var palette

    private var model: MailDescribedLabels { runtime.describedLabels }

    var body: some View {
        List {
            Section {
                ForEach(model.labels) { label in
                    Button { editing = label } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "tag.fill").foregroundStyle(label.enabled ? palette.accent : .secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(label.labelName).font(.body.weight(.semibold)).foregroundStyle(.primary)
                                Text(label.description).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            if !label.enabled { Text("Off").font(.footnote).foregroundStyle(.secondary) }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    var labels = model.labels
                    labels.remove(atOffsets: offsets)
                    model.save(labels)
                }
                Button("Add Label", systemImage: "plus") {
                    editing = MailDescribedLabel(id: UUID().uuidString, labelName: "", description: "")
                }
            } footer: {
                Text("Postmere sends the subject and the start of each new message to your workspace’s AI to decide. Only mail that arrives after you add a label is sorted. Labels are kept on this device.")
            }
            .mobileSettingsRows()
            if let problem = model.problem {
                Text(problem).foregroundStyle(PostmereTheme.destructiveInk).listRowBackground(Color.clear)
            } else if model.lastSortedCount > 0 {
                Text("\(model.lastSortedCount) messages labelled so far.").font(.footnote).foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
        }
        .mobileSettingsCanvas()
        .navigationTitle("Labels You Describe")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editing) { label in
            MobileDescribedLabelEditor(label: label) { saved in
                var labels = model.labels
                if let index = labels.firstIndex(where: { $0.id == saved.id }) { labels[index] = saved } else { labels.append(saved) }
                model.save(labels)
            }
        }
    }
}

private struct MobileDescribedLabelEditor: View {
    @State var label: MailDescribedLabel
    let onSave: (MailDescribedLabel) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Label") {
                    TextField("Receipts", text: $label.labelName)
                        .textInputAutocapitalization(.words)
                }
                .mobileSheetRows()
                Section {
                    TextField("Receipts, invoices and payment confirmations from shops and services", text: $label.description, axis: .vertical)
                        .lineLimit(3...6)
                } header: {
                    Text("What goes in it")
                } footer: {
                    Text("Describe it as you would to a person. Be specific about what to leave out, too.")
                }
                .mobileSheetRows()
                Section { Toggle("Sort New Mail", isOn: $label.enabled) }.mobileSheetRows()
            }
            .navigationTitle(label.labelName.isEmpty ? "New Label" : label.labelName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", systemImage: "checkmark") {
                        label.labelName = label.labelName.trimmingCharacters(in: .whitespacesAndNewlines)
                        label.description = label.description.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(label)
                        dismiss()
                    }
                    .disabled(label.labelName.trimmingCharacters(in: .whitespaces).isEmpty
                              || label.description.trimmingCharacters(in: .whitespaces).count < 8)
                }
            }
        }
        .mobileSheetDetents()
    }
}
