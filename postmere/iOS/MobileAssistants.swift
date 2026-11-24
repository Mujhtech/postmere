import ActivityKit
import SwiftUI
import UIKit

/// Assistants connected over MCP: how to connect one, what each is doing right
/// now, which accounts they can see, and the Lock Screen Live Activity.
struct MobileAssistantsSettings: View {
    let runtime: MailRuntime
    @Environment(\.postmereAccent) private var palette
    @AppStorage(MobileAssistantActivities.preferenceKey) private var liveActivities = true
    @State private var confirmRevoke: AssistantConnection?
    @State private var copied: String?
    @State private var updatingAccount: UUID?
    @State private var accessError: String?

    private var session: BackendSession { runtime.backend }
    private var monitor: AssistantActivityMonitor { runtime.assistants }

    private var mcpURL: String? {
        guard session.isConnected, let base = URL(string: session.baseURL) else { return nil }
        return base.appending(path: "mcp").absoluteString
    }

    var body: some View {
        List {
            connected
            if let mcpURL { connect(mcpURL) }
            liveActivitySection
            visibility
        }
        .mobileSettingsCanvas()
        .navigationTitle("Assistants")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Faster than the background poll while this screen is open.
            while !Task.isCancelled {
                await monitor.refresh(session: session)
                try? await Task.sleep(for: .seconds(5))
            }
        }
        .refreshable { await monitor.refresh(session: session) }
        .confirmationDialog("Revoke \(confirmRevoke?.clientName ?? "assistant")?",
                            isPresented: Binding(get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } }),
                            titleVisibility: .visible) {
            if let connection = confirmRevoke {
                Button("Revoke Access", role: .destructive) {
                    Task { await monitor.revoke(connection, session: session) }
                }
            }
        } message: {
            Text("It loses access right away and has to sign in again.")
        }
        .sensoryFeedback(.selection, trigger: copied)
    }

    // MARK: Connected

    @ViewBuilder private var connected: some View {
        Section {
            if monitor.connections.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(monitor.lastError ?? "No assistants yet", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(monitor.lastError == nil ? AnyShapeStyle(palette.accent) : AnyShapeStyle(.red))
                    Text("Connect Claude, ChatGPT, Cursor or another MCP assistant below. It signs in through your workspace, and you can revoke it here at any time.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } else {
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    ForEach(monitor.connections) { connection in
                        MobileAssistantRow(connection: connection, now: context.date)
                            .swipeActions {
                                Button("Revoke", role: .destructive) { confirmRevoke = connection }
                            }
                            .contextMenu {
                                Button("Revoke Access", systemImage: "xmark.circle", role: .destructive) { confirmRevoke = connection }
                            }
                    }
                }
            }
        } header: {
            HStack {
                Text("Connected")
                Spacer()
                if !monitor.working.isEmpty {
                    Label("\(monitor.working.count) working", systemImage: "circle.fill")
                        .labelStyle(WorkingLabelStyle())
                        .foregroundStyle(palette.accent)
                        .textCase(nil)
                }
            }
        }
        .animation(MobileMotion.quick, value: monitor.connections)
    }

    // MARK: Connect

    private func connect(_ url: String) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                Text("Server URL").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                HStack(spacing: 10) {
                    Text(url)
                        .font(.system(.footnote, design: .monospaced))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer(minLength: 4)
                    copyButton(url, key: "url", title: "Copy")
                }
            }
            .padding(.vertical, 4)
            ForEach(setups(url), id: \.name) { setup in
                HStack(spacing: 12) {
                    MobileAssistantMonogram(name: setup.name, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(setup.name).font(.subheadline.weight(.semibold))
                        Text(setup.hint).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 4)
                    if let page = setup.page {
                        Button {
                            copy(url, key: setup.name)
                            UIApplication.shared.open(page)
                        } label: {
                            Text(copied == setup.name ? "Copied" : "Open").font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(palette.accent)
                    } else {
                        ShareLink(item: setup.text) {
                            Image(systemName: "square.and.arrow.up").font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(palette.accent)
                        .accessibilityLabel("Send \(setup.name) setup to your computer")
                        copyButton(setup.text, key: setup.name, title: "Copy")
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            Text("Connect an assistant")
        } footer: {
            Text("Claude and ChatGPT add Postmere as a custom connector on the web. For tools on your computer, send the setup to your Mac, or use Settings → AI there to add it in one click.")
        }
    }

    private struct Setup {
        let name: String
        let hint: String
        let text: String
        var page: URL?
    }

    private func setups(_ url: String) -> [Setup] {
        [
            Setup(name: "Claude", hint: "Copies the URL and opens Connectors. Choose Add custom connector.", text: url,
                  page: URL(string: "https://claude.ai/settings/connectors")),
            Setup(name: "ChatGPT", hint: "Copies the URL and opens Connectors.", text: url,
                  page: URL(string: "https://chatgpt.com/#settings/Connectors")),
            Setup(name: "Claude Code", hint: "A Terminal command for your computer.",
                  text: "claude mcp add --transport http --scope user postmere \(url)"),
            Setup(name: "Codex", hint: "A Terminal command that adds Postmere and signs in.",
                  text: "codex mcp add postmere --url \(url) && codex mcp login postmere"),
            Setup(name: "Cursor", hint: "Configuration for ~/.cursor/mcp.json.",
                  text: AssistantConfigFile.cursor.snippet(url: url)),
            Setup(name: "VS Code", hint: "Configuration for VS Code’s mcp.json.",
                  text: AssistantConfigFile.vsCode.snippet(url: url)),
        ]
    }

    private func copyButton(_ text: String, key: String, title: String) -> some View {
        Button { copy(text, key: key) } label: {
            Text(copied == key ? "Copied" : title)
                .font(.subheadline.weight(.semibold))
                .contentTransition(.interpolate)
        }
        .buttonStyle(.bordered)
        .tint(palette.accent)
    }

    private func copy(_ text: String, key: String) {
        UIPasteboard.general.string = text
        withAnimation(MobileMotion.quick) { copied = key }
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copied == key { withAnimation(MobileMotion.quick) { copied = nil } }
        }
    }

    // MARK: Live Activity

    private var liveActivitySection: some View {
        Section {
            Toggle(isOn: $liveActivities) {
                Label("Show on Lock Screen", systemImage: "platter.filled.bottom.iphone")
            }
            .tint(palette.accent)
            .onChange(of: liveActivities) { MobileAssistantActivities.refresh(runtime: runtime) }
        } header: {
            Text("Live Activity")
        } footer: {
            if !ActivityAuthorizationInfo().areActivitiesEnabled {
                Text("Live Activities are off for Postmere in the Settings app.")
            } else {
                Text("While an assistant works in your mail, follow along on the Lock Screen and in the Dynamic Island, even with Postmere closed. It needs notifications on for this iPhone.")
            }
        }
    }

    // MARK: Visibility

    private var visibility: some View {
        Section {
            ForEach(session.accounts) { account in
                Toggle(isOn: Binding(get: { account.hiddenFromAssistants != true },
                                     set: { setAccess(account, visible: $0) })) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.name ?? account.email).lineLimit(1)
                        if account.hiddenFromAssistants == true {
                            Text("Hidden from assistants").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .tint(palette.accent)
                .disabled(updatingAccount == account.id)
            }
            if let accessError {
                Text(accessError).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            Text("What assistants can see")
        } footer: {
            Text("Hidden accounts, their mail and their outbox are invisible to every assistant.")
        }
    }

    private func setAccess(_ account: BackendAccount, visible: Bool) {
        updatingAccount = account.id
        accessError = nil
        Task {
            defer { updatingAccount = nil }
            do { try await session.setAssistantAccess(accountID: account.id, visible: visible) }
            catch { accessError = error.localizedDescription }
        }
    }
}

private struct WorkingLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 7)).symbolEffect(.pulse, options: .repeating)
            configuration.title.font(.caption.weight(.semibold))
        }
    }
}

/// One connected assistant: what it's doing now, or when it last did anything.
private struct MobileAssistantRow: View {
    let connection: AssistantConnection
    let now: Date
    @Environment(\.postmereAccent) private var palette

    var body: some View {
        let working = connection.isWorking(at: now)
        HStack(spacing: 12) {
            MobileAssistantMonogram(name: connection.clientName, size: 38)
                .overlay {
                    if working {
                        RoundedRectangle(cornerRadius: 38 * 0.27 + 4, style: .continuous)
                            .strokeBorder(palette.accent, lineWidth: 2).padding(-4)
                            .symbolEffect(.pulse)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(connection.clientName).font(.body.weight(.semibold)).lineLimit(1)
                    if working {
                        Text("Working")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(palette.accent)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(palette.accent.opacity(0.14), in: Capsule())
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                Text(detail(working: working))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .contentTransition(.opacity)
            }
        }
        .padding(.vertical, 3)
        .animation(MobileMotion.reveal, value: working)
        .animation(MobileMotion.quick, value: connection.recent)
        .accessibilityElement(children: .combine)
    }

    private func detail(working: Bool) -> String {
        var seen = Set<String>()
        let actions = connection.recent.prefix(3).map(\.summary).filter { seen.insert($0).inserted }
        if let last = connection.lastUsedAt {
            let when = working ? "now" : last.formatted(.relative(presentation: .named))
            return ([actions.joined(separator: " · ")].filter { !$0.isEmpty } + [when]).joined(separator: " — ")
        }
        return "Connected \(connection.createdAt.formatted(.relative(presentation: .named))) · not used yet"
    }
}

/// The assistant's own logo, as on the Mac (Claude, ChatGPT/Codex, Cursor, VS Code),
/// or its initial on a colour picked from its name.
struct MobileAssistantMonogram: View {
    let name: String
    var size: CGFloat = 30

    private static let palette: [Color] = [
        Color(red: 0.36, green: 0.40, blue: 0.86), Color(red: 0.62, green: 0.40, blue: 0.84),
        Color(red: 0.20, green: 0.62, blue: 0.66), Color(red: 0.88, green: 0.36, blue: 0.55),
        Color(red: 0.93, green: 0.55, blue: 0.24),
    ]

    var body: some View {
        if let brand = Brand(clientName: name) {
            BrandTile(brand: brand, size: size)
        } else {
            let lower = name.lowercased()
            let hash = lower.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
            Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
                .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .background(Self.palette[Int(hash % UInt32(Self.palette.count))].gradient,
                            in: .rect(cornerRadius: size * 0.27, style: .continuous))
                .accessibilityHidden(true)
        }
    }
}
