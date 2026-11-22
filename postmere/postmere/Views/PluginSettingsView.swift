import SwiftUI

/// Settings → Plugins: one section per plugin with its switch, what it may
/// read, its options once on, and what it did recently.
struct PluginSettingsView: View {
    let session: BackendSession
    @Environment(MailRuntime.self) private var runtime

    var body: some View {
        let plugins = runtime.plugins
        Form {
            if !session.canAccessWorkspace {
                Section {
                    SettingsRow("Plugins", symbol: "puzzlepiece", tint: SettingsTint.indigo,
                                subtitle: "Connect a workspace to use plugins") {
                        AccountSettingsButton(title: "Open Accounts").controlSize(.small)
                    }
                }
            } else if plugins.catalog.isEmpty {
                Section {
                    SettingsRow("Plugins", symbol: "puzzlepiece", tint: SettingsTint.indigo, subtitle: loadingSubtitle) {
                        if case .failed = plugins.catalogState {
                            Button("Try Again") { Task { await plugins.refreshCatalog(session: session) } }
                                .controlSize(.small)
                        } else {
                            ProgressView().controlSize(.small)
                        }
                    }
                }
            } else {
                Section {
                    Text("Plugins add cards and actions to messages. They run on your Postmere server, and each one ships turned off.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(plugins.catalog) { plugin in
                    PluginSection(plugin: plugin, session: session)
                }
            }
        }
        .formStyle(.grouped)
        .task(id: session.realtimeGeneration) {
            guard session.canAccessWorkspace else { return }
            await plugins.refreshCatalog(session: session)
        }
    }

    private var loadingSubtitle: String {
        if case .failed(let message) = runtime.plugins.catalogState { return message }
        return "Loading…"
    }
}

private struct PluginSection: View {
    let plugin: PluginInfo
    let session: BackendSession
    @Environment(MailRuntime.self) private var runtime
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var tint: Color { PluginInfo.tint(named: plugin.tint) }

    var body: some View {
        Section {
            SettingsRow(plugin.name, symbol: plugin.icon, tint: tint, subtitle: plugin.summary,
                        brands: (plugin.brands ?? []).compactMap(Brand.init(rawValue:))) {
                Toggle(plugin.name, isOn: Binding(get: { plugin.enabled }, set: { enabled in
                    Task { await runtime.plugins.setEnabled(enabled, for: plugin.id, session: session) }
                }))
                .toggleStyle(.switch).labelsHidden().controlSize(.small)
            }
            ForEach(plugin.permissions, id: \.self) { permission in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    PostmereIcon("lock", size: 11).foregroundStyle(.tertiary)
                    Text(permission)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.leading, 35)
            }
            if plugin.enabled {
                ForEach(plugin.settings) { setting in
                    settingRow(setting)
                        .transition(.opacity)
                }
                if let last = plugin.activity.first {
                    HStack(spacing: 8) {
                        Text("Last used")
                            .font(.system(size: 12))
                        Spacer()
                        Text(verbatim: "\(last.title) · \(last.at.formatted(.relative(presentation: .named)))")
                            .font(.system(size: 12))
                            .foregroundStyle(last.succeeded ? Color.secondary : Color.red)
                        if plugin.activity.count > 1 {
                            ActivityButton(activity: plugin.activity, name: plugin.name)
                        }
                    }
                    .padding(.leading, 35)
                    .transition(.opacity)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: plugin.enabled)
    }

    @ViewBuilder private func settingRow(_ setting: PluginSetting) -> some View {
        switch setting.type {
        case .toggle:
            HStack {
                Text(setting.title).font(.system(size: 12.5))
                Spacer()
                Toggle(setting.title, isOn: Binding(get: { setting.value.bool ?? false }, set: { value in
                    Task { await runtime.plugins.setValue(.bool(value), for: setting.key, plugin: plugin.id, session: session) }
                }))
                .toggleStyle(.switch).labelsHidden().controlSize(.mini)
            }
            .padding(.leading, 35)
        case .choice:
            HStack {
                Text(setting.title).font(.system(size: 12.5))
                Spacer()
                Picker(setting.title, selection: Binding(get: { setting.value.string ?? "" }, set: { value in
                    Task { await runtime.plugins.setValue(.string(value), for: setting.key, plugin: plugin.id, session: session) }
                })) {
                    ForEach(setting.options ?? []) { option in
                        Text(option.title).tag(option.value)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.leading, 35)
        }
    }
}

/// The plugin's recent calls, kept seven days on the server.
private struct ActivityButton: View {
    let activity: [PluginActivity]
    let name: String
    @State private var shows = false

    var body: some View {
        Button { shows.toggle() } label: {
            PostmereIcon("clock", size: 12).foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .help("Recent activity")
        .accessibilityLabel("Recent \(name) activity")
        .popover(isPresented: $shows, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 0) {
                Text("Last 7 days")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                ForEach(activity) { entry in
                    HStack(spacing: 8) {
                        Circle().fill(entry.succeeded ? SettingsTint.green : SettingsTint.red).frame(width: 6, height: 6)
                        Text(entry.title).font(.system(size: 12))
                        Spacer(minLength: 16)
                        Text(entry.at.formatted(date: .abbreviated, time: .shortened))
                            .font(.system(size: 11.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 3)
                }
            }
            .padding(14)
            .frame(width: 280)
        }
    }
}
