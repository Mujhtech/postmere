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
        if let brand = Brand(clientName: name) {
            BrandTile(brand: brand, size: size)
        } else {
            monogram
        }
    }

    private var monogram: some View {
        Text(String(name.trimmingCharacters(in: .whitespaces).prefix(1)).uppercased())
            .font(.system(size: size * 0.5, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(tint.gradient, in: .rect(cornerRadius: size * 0.27, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Quick setup

/// One assistant Postmere can be added to, and the ways to do it.
private struct AssistantClient: Identifiable {
    let name: String
    /// The file Postmere can update directly.
    var config: AssistantConfigFile?
    /// A Terminal command that does the same through the assistant's own CLI.
    var command: String?
    /// The assistant's own install link, and the URL scheme that shows it's installed.
    var link: (url: URL, scheme: String)?
    /// For assistants set up on the web: the page where connectors are added.
    var connectorPage: URL?
    /// What to do after the config is in place.
    var next: String
    var id: String { name }
}

private struct QuickSetupGrid: View {
    let mcpURL: URL
    @State private var done: String?
    @State private var showing: String?
    @State private var setUp: Set<String> = []

    private var clients: [AssistantClient] {
        let url = mcpURL.absoluteString
        return [
            AssistantClient(name: "Claude Code", config: .claudeCode,
                            command: "claude mcp add --transport http --scope user postmere \(url)",
                            next: "In Claude Code, run /mcp and choose postmere to sign in."),
            AssistantClient(name: "Codex", config: .codex,
                            command: "codex mcp add postmere --url \(url) && codex mcp login postmere",
                            next: "Run codex mcp login postmere in Terminal to sign in."),
            AssistantClient(name: "Cursor", config: .cursor, link: (cursorInstallURL(url), "cursor://"),
                            next: "In Cursor, open Settings → MCP and sign in to postmere."),
            AssistantClient(name: "VS Code", config: .vsCode, link: (vscodeInstallURL(url), "vscode://"),
                            next: "In VS Code, start postmere from the MCP Servers list and sign in."),
            AssistantClient(name: "Windsurf", config: .windsurf,
                            next: "In Windsurf, refresh MCP servers and sign in to postmere."),
            AssistantClient(name: "Gemini CLI", config: .gemini,
                            next: "In Gemini CLI, run /mcp auth postmere to sign in."),
            AssistantClient(name: "Claude", connectorPage: URL(string: "https://claude.ai/settings/connectors"),
                            next: "Choose Add custom connector and paste the URL."),
            AssistantClient(name: "ChatGPT", connectorPage: URL(string: "https://chatgpt.com/#settings/Connectors"),
                            next: "Create a connector and paste the URL."),
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
                Button(done == "url" ? "Copied" : "Copy URL") { copyToPasteboard(mcpURL.absoluteString); flash("url") }
                    .controlSize(.small)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4), spacing: 10) {
                ForEach(clients) { client in
                    let isSetUp = setUp.contains(client.name)
                    Button { showing = client.name } label: {
                        HStack(spacing: 9) {
                            AssistantMonogram(name: client.name, size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(client.name).font(.system(size: 12.5, weight: .medium)).lineLimit(1)
                                Text(isSetUp ? "Added" : client.connectorPage == nil ? "Set up…" : "Add connector…")
                                    .font(.system(size: 11))
                                    .foregroundStyle(isSetUp ? SettingsTint.green : .secondary)
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
                    .accessibilityLabel("Set up \(client.name)")
                    .popover(isPresented: Binding(get: { showing == client.name }, set: { if !$0 { showing = nil } }),
                             arrowEdge: .bottom) {
                        AssistantSetupPopover(client: client, mcpURL: mcpURL) { added in
                            if added { setUp.insert(client.name) }
                        }
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .animation(.snappy(duration: 0.2), value: done)
        .animation(.snappy(duration: 0.2), value: setUp)
        .task(id: mcpURL) { setUp = Set(clients.filter { AssistantConfigInstaller.isSetUp($0.config, url: mcpURL) }.map(\.name)) }
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

private func copyToPasteboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
}

/// Shows exactly what will be added and where, then either copies it or writes it.
private struct AssistantSetupPopover: View {
    let client: AssistantClient
    let mcpURL: URL
    let onFinish: (Bool) -> Void
    @Environment(\.openURL) private var openURL
    @State private var outcome: Outcome?
    @State private var copied: String?

    private enum Outcome: Equatable {
        case added(AssistantConfigFile.MergeResult)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                AssistantMonogram(name: client.name, size: 30)
                Text(client.name).font(.system(size: 15, weight: .semibold))
                Spacer()
            }
            if let config = client.config {
                fileSetup(config)
            } else if let page = client.connectorPage {
                connectorSetup(page)
            }
        }
        .padding(16)
        .frame(width: 420)
        .animation(.snappy(duration: 0.22), value: outcome)
        .animation(.snappy(duration: 0.22), value: copied)
    }

    @ViewBuilder private func fileSetup(_ config: AssistantConfigFile) -> some View {
        Text("Adds Postmere to **~/\(config.path)**. Everything else in the file stays as it is.")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        codeBox(config.snippet(url: mcpURL.absoluteString))
        if let command = client.command {
            VStack(alignment: .leading, spacing: 5) {
                Text("Or run this in Terminal").font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 8) {
                    Text(command)
                        .font(.system(size: 11, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button(copied == "command" ? "Copied" : "Copy") { copy(command, as: "command") }
                        .controlSize(.small)
                }
            }
        }
        HStack(spacing: 8) {
            Button(copied == "config" ? "Copied" : "Copy Configuration") {
                copy(config.snippet(url: mcpURL.absoluteString), as: "config")
            }
            if let link = client.link, NSWorkspace.shared.urlForApplication(toOpen: URL(string: link.scheme)!) != nil {
                Button("Open \(client.name)") { openURL(link.url) }
                    .help("Install with \(client.name)’s own link instead")
            }
            Spacer()
            Button("Add to \(client.name)") { install(config) }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(outcome == .added(.added) || outcome == .added(.updated) || outcome == .added(.unchanged))
        }
        .controlSize(.regular)
        if let outcome { result(outcome, config: config) }
    }

    @ViewBuilder private func result(_ outcome: Outcome, config: AssistantConfigFile) -> some View {
        switch outcome {
        case .added(let change):
            VStack(alignment: .leading, spacing: 6) {
                Label(change == .unchanged ? "Already set up in ~/\(config.path)"
                      : change == .updated ? "Updated ~/\(config.path)" : "Added to ~/\(config.path)",
                      systemImage: "checkmark.circle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(SettingsTint.green)
                Text(client.next)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([AssistantConfigInstaller.fileURL(config)])
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
            }
            .transition(.opacity.combined(with: .move(edge: .top)))
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.red)
                .fixedSize(horizontal: false, vertical: true)
                .transition(.opacity)
        }
    }

    @ViewBuilder private func connectorSetup(_ page: URL) -> some View {
        Text("\(client.name) adds Postmere as a custom connector on the web. \(client.next)")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        codeBox(mcpURL.absoluteString)
        HStack {
            Button(copied == "url" ? "Copied" : "Copy URL") { copy(mcpURL.absoluteString, as: "url") }
            Spacer()
            Button("Copy URL & Open \(client.name)") {
                copy(mcpURL.absoluteString, as: "url")
                openURL(page)
                onFinish(false)
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
        }
    }

    private func codeBox(_ text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 11.5, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
        }
        .frame(maxHeight: 150)
        .fixedSize(horizontal: false, vertical: true)
        .background(PostmereTheme.rule.opacity(0.3), in: .rect(cornerRadius: 8, style: .continuous))
    }

    private func copy(_ text: String, as key: String) {
        copyToPasteboard(text)
        copied = key
        Task {
            try? await Task.sleep(for: .seconds(2))
            if copied == key { copied = nil }
        }
    }

    private func install(_ config: AssistantConfigFile) {
        do {
            let change = try AssistantConfigInstaller.install(config, url: mcpURL)
            outcome = .added(change)
            onFinish(true)
        } catch {
            outcome = .failed(error.localizedDescription)
        }
    }
}

/// Reads and writes assistants' config files in the real home folder. The sandbox
/// allows only these files and folders (see postmere.entitlements).
enum AssistantConfigInstaller {
    /// The person's home folder, not the app's sandbox container.
    static var home: URL {
        if let entry = getpwuid(getuid()), let path = entry.pointee.pw_dir {
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func fileURL(_ config: AssistantConfigFile) -> URL {
        home.appending(path: config.path)
    }

    static func isSetUp(_ config: AssistantConfigFile?, url: URL) -> Bool {
        guard let config, let text = try? String(contentsOf: fileURL(config), encoding: .utf8) else { return false }
        return (try? config.merged(text, url: url.absoluteString).result) == .unchanged
    }

    @discardableResult
    static func install(_ config: AssistantConfigFile, url: URL) throws -> AssistantConfigFile.MergeResult {
        let file = fileURL(config)
        let manager = FileManager.default
        var existing: String?
        if manager.fileExists(atPath: file.path) {
            do { existing = try String(contentsOf: file, encoding: .utf8) }
            catch { throw InstallError.access(config.path) }
        }
        let (text, result) = try config.merged(existing, url: url.absoluteString)
        guard result != .unchanged else { return result }
        do {
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            // A file directly in the home folder can't be swapped in from a temporary
            // copy under the sandbox, so it's written in place.
            let inHome = !config.path.contains("/")
            try Data(text.utf8).write(to: file, options: inHome ? [] : [.atomic])
        } catch {
            throw InstallError.access(config.path)
        }
        return result
    }

    enum InstallError: LocalizedError {
        case access(String)
        var errorDescription: String? {
            switch self {
            case .access(let path): "Postmere couldn’t write ~/\(path). Copy the configuration and add it by hand."
            }
        }
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
