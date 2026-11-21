import AppKit
import SwiftUI

/// Connecting MCP assistants, seeing what they do, and choosing which
/// accounts they can reach. Part of Settings → AI.
struct AssistantSettings: View {
    let session: BackendSession
    let mcpURL: URL
    let monitor: AssistantActivityMonitor

    @State private var confirmRevoke: AssistantConnection?
    @State private var accessError: String?
    @State private var updatingAccount: UUID?

    var body: some View {
        Section {
            QuickSetupGrid(mcpURL: mcpURL)
        } header: {
            HStack {
                Text("Connect an assistant")
                Spacer()
                SettingsInfoButton(text: "Each assistant signs in through your workspace with OAuth. Your server must allow its sign-in callback in POSTMERE_MCP_REDIRECT_URIS; command-line assistants on localhost may use any port.")
            }
        }

        Section("Connected") {
            if monitor.connections.isEmpty {
                Text(monitor.lastError ?? "No assistants yet. Connect one above.")
                    .font(.system(size: 12))
                    .foregroundStyle(monitor.lastError == nil ? Color.secondary : Color.red)
            }
            TimelineView(.periodic(from: .now, by: 30)) { context in
                ForEach(monitor.connections) { connection in
                    ConnectionRow(connection: connection, now: context.date) { confirmRevoke = connection }
                }
            }
        }
        .task { await monitor.refresh(session: session) }
        .confirmationDialog("Revoke \(confirmRevoke?.clientName ?? "assistant")?", isPresented: Binding(
            get: { confirmRevoke != nil }, set: { if !$0 { confirmRevoke = nil } }
        ), titleVisibility: .visible) {
            if let connection = confirmRevoke {
                Button("Revoke Access", role: .destructive) {
                    Task { await monitor.revoke(connection, session: session) }
                }
            }
        } message: {
            Text("It loses access right away and has to sign in again.")
        }

        Section {
            ForEach(session.accounts) { account in
                SettingsRow(account.email, symbol: "envelope", tint: account.hiddenFromAssistants == true ? SettingsTint.gray : SettingsTint.blue,
                            subtitle: account.hiddenFromAssistants == true ? "Hidden from assistants" : nil) {
                    if updatingAccount == account.id {
                        ProgressView().controlSize(.small)
                    } else {
                        Toggle("Assistants can see \(account.email)", isOn: Binding(
                            get: { account.hiddenFromAssistants != true },
                            set: { visible in setAccess(account, visible: visible) }
                        ))
                        .toggleStyle(.switch).labelsHidden().controlSize(.small)
                    }
                }
            }
            if let accessError {
                Text(accessError).font(.system(size: 11.5)).foregroundStyle(.red)
            }
        } header: {
            Text("What assistants can see")
        } footer: {
            Text("Hidden accounts, their mail and their outbox are invisible to every assistant.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
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

// MARK: - Connected assistant

private struct ConnectionRow: View {
    let connection: AssistantConnection
    let now: Date
    let revoke: () -> Void

    var body: some View {
        let working = connection.isWorking(at: now)
        HStack(spacing: 11) {
            AssistantMonogram(name: connection.clientName)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(connection.clientName).font(.system(size: 13)).lineLimit(1)
                    if working { WorkingBadge() }
                }
                Text(detail(working: working))
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Revoke", action: revoke).controlSize(.small)
        }
        .padding(.vertical, 1)
        .animation(.smooth, value: working)
    }

    /// The latest few things it did, or when it was connected.
    private func detail(working: Bool) -> String {
        let actions = connection.recent.prefix(3).map(\.summary)
        var seen = Set<String>()
        let distinct = actions.filter { seen.insert($0).inserted }
        if let last = connection.lastUsedAt {
            let when = working ? "now" : last.formatted(.relative(presentation: .named))
            return ([distinct.joined(separator: " · ")].filter { !$0.isEmpty } + [when]).joined(separator: " — ")
        }
        return "Connected \(connection.createdAt.formatted(.relative(presentation: .named))) · not used yet"
    }
}

private struct WorkingBadge: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(SettingsTint.green)
                .frame(width: 6, height: 6)
                .overlay(Circle().stroke(SettingsTint.green.opacity(0.5), lineWidth: 1)
                    .scaleEffect(pulse ? 2.2 : 1).opacity(pulse ? 0 : 1))
            Text("Working").font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundStyle(SettingsTint.green)
        .padding(.horizontal, 6).padding(.vertical, 2)
        .background(SettingsTint.green.opacity(0.12), in: Capsule())
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.4).repeatForever(autoreverses: false)) { pulse = true }
        }
    }
}

/// A tile with the assistant's initial, coloured by its name.
struct AssistantMonogram: View {
    let name: String
    var size: CGFloat = 24

    private var tint: Color {
        let lower = name.lowercased()
        if lower.contains("claude") { return Color(red: 0.85, green: 0.47, blue: 0.34) }
        if lower.contains("chatgpt") || lower.contains("openai") || lower.contains("codex") { return Color(red: 0.13, green: 0.13, blue: 0.14) }
        if lower.contains("cursor") { return Color(red: 0.2, green: 0.2, blue: 0.24) }
        if lower.contains("code") { return SettingsTint.blue }
        let palette = [SettingsTint.indigo, SettingsTint.purple, SettingsTint.teal, SettingsTint.pink, SettingsTint.orange]
        let hash = lower.unicodeScalars.reduce(UInt32(5381)) { ($0 &* 33) &+ $1.value }
        return palette[Int(hash % UInt32(palette.count))]
    }

    var body: some View {
        Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
            .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Quick setup

private struct QuickSetupGrid: View {
    let mcpURL: URL
    @Environment(\.openURL) private var openURL
    @State private var done: String?

    private struct Client: Identifiable {
        enum Action { case copy(String, then: URL?), open(URL, requires: String) }
        let name: String
        let hint: String
        let action: Action
        var id: String { name }
    }

    private var clients: [Client] {
        let url = mcpURL.absoluteString
        return [
            Client(name: "Claude Code", hint: "Copies a command. Run it, then /mcp to sign in.",
                   action: .copy("claude mcp add --transport http postmere \(url)", then: nil)),
            Client(name: "Codex", hint: "Copies a command that adds Postmere and signs in.",
                   action: .copy("codex mcp add postmere --url \(url) && codex mcp login postmere", then: nil)),
            Client(name: "Cursor", hint: "Opens Cursor to install Postmere.",
                   action: .open(cursorInstallURL(url), requires: "cursor://")),
            Client(name: "VS Code", hint: "Opens VS Code to install Postmere.",
                   action: .open(vscodeInstallURL(url), requires: "vscode://")),
            Client(name: "Claude", hint: "Copies the URL and opens Connectors. Choose Add custom connector.",
                   action: .copy(url, then: URL(string: "https://claude.ai/settings/connectors"))),
            Client(name: "ChatGPT", hint: "Copies the URL and opens Connectors in ChatGPT.",
                   action: .copy(url, then: URL(string: "https://chatgpt.com/#settings/Connectors"))),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(mcpURL.absoluteString)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .textSelection(.enabled)
                Spacer()
                Button(done == "url" ? "Copied" : "Copy URL") { copy(mcpURL.absoluteString, key: "url") }
                    .controlSize(.small)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3), spacing: 10) {
                ForEach(clients) { client in
                    let available = isAvailable(client)
                    Button { run(client) } label: {
                        HStack(spacing: 9) {
                            AssistantMonogram(name: client.name, size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(client.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                Text(done == client.name ? doneText(client) : actionText(client, available: available))
                                    .font(.system(size: 11))
                                    .foregroundStyle(done == client.name ? SettingsTint.green : .secondary)
                                    .lineLimit(1)
                                    .contentTransition(.opacity)
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 9)
                        .background(PostmereTheme.rule.opacity(0.28), in: .rect(cornerRadius: 10, style: .continuous))
                        .contentShape(.rect(cornerRadius: 10))
                    }
                    .buttonStyle(QuickSetupStyle())
                    .disabled(!available)
                    .help(client.hint)
                    .accessibilityLabel("Set up \(client.name)")
                    .accessibilityHint(client.hint)
                }
            }
        }
        .padding(.vertical, 2)
        .animation(.snappy(duration: 0.2), value: done)
    }

    private func actionText(_ client: Client, available: Bool) -> String {
        switch client.action {
        case .copy(_, let then): then == nil ? "Copy command" : "Copy & open"
        case .open: available ? "Install" : "Not installed"
        }
    }

    private func doneText(_ client: Client) -> String {
        switch client.action {
        case .copy(_, let then): then == nil ? "Copied — paste in Terminal" : "URL copied"
        case .open: "Opening…"
        }
    }

    private func isAvailable(_ client: Client) -> Bool {
        guard case .open(_, let scheme) = client.action, let probe = URL(string: scheme) else { return true }
        return NSWorkspace.shared.urlForApplication(toOpen: probe) != nil
    }

    private func run(_ client: Client) {
        switch client.action {
        case .copy(let text, let then):
            copy(text, key: client.name)
            if let then { openURL(then) }
        case .open(let url, _):
            openURL(url)
            flash(client.name)
        }
    }

    private func copy(_ text: String, key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        flash(key)
    }

    private func flash(_ key: String) {
        done = key
        Task {
            try? await Task.sleep(for: .seconds(2.2))
            if done == key { done = nil }
        }
    }

    private func cursorInstallURL(_ url: String) -> URL {
        let config = (try? JSONSerialization.data(withJSONObject: ["url": url])) ?? Data()
        var components = URLComponents(string: "cursor://anysphere.cursor-deeplink/mcp/install")!
        components.queryItems = [URLQueryItem(name: "name", value: "postmere"),
                                 URLQueryItem(name: "config", value: config.base64EncodedString())]
        return components.url!
    }

    private func vscodeInstallURL(_ url: String) -> URL {
        let config = (try? JSONSerialization.data(withJSONObject: ["name": "postmere", "type": "http", "url": url], options: [.sortedKeys])) ?? Data()
        let json = String(decoding: config, as: UTF8.self)
        let encoded = json.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? json
        return URL(string: "vscode:mcp/install?\(encoded)")!
    }
}

private struct QuickSetupStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(isEnabled ? 1 : 0.5)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}
