import Foundation
import Foundation
import Observation

/// The app side of plugins: which ones the user turned on, the cards and
/// actions each plugin offers for a message, and running those actions.
/// Nothing is requested for messages until at least one plugin is on.
@MainActor @Observable
final class MailPlugins {
    enum CatalogState: Equatable { case idle, loading, loaded, failed(String) }

    private(set) var catalog: [PluginInfo] = []
    private(set) var catalogState = CatalogState.idle
    /// Keyed by plugin and tool while a tool call is running, for spinners.
    private(set) var running: Set<String> = []
    private var results: [String: MessagePlugins] = [:]
    @ObservationIgnored private var loading: Set<String> = []
    @ObservationIgnored private var catalogScope: String?
    private let store: MailStore

    init(store: MailStore) {
        self.store = store
    }

    var hasEnabledPlugins: Bool { catalog.contains(where: \.enabled) }

    /// Bumps whenever enabled plugins or their settings change, so views can
    /// reload cards for the open message.
    private(set) var revision = 0

    // MARK: Catalog

    func refreshCatalog(session: BackendSession) async {
        guard session.isConnected, let scope = session.scope else {
            reset()
            return
        }
        if catalogState == .loading { return }
        if catalogScope != scope { reset() }
        catalogState = catalog.isEmpty ? .loading : catalogState
        do {
            let list: PluginList = try await session.request("GET", "/v1/plugins")
            guard session.scope == scope else { return }
            if list.plugins.map(\.enabled) != catalog.map(\.enabled) || list.plugins.map(\.settings) != catalog.map(\.settings) {
                results.removeAll()
                revision += 1
            }
            catalog = list.plugins
            catalogScope = scope
            catalogState = .loaded
        } catch {
            guard session.scope == scope else { return }
            catalogState = catalog.isEmpty ? .failed(error.localizedDescription) : .loaded
        }
    }

    func setEnabled(_ enabled: Bool, for id: String, session: BackendSession) async {
        guard let plugin = catalog.first(where: { $0.id == id }) else { return }
        await update(plugin, enabled: enabled, values: plugin.settings, session: session)
    }

    func setValue(_ value: PluginJSON, for key: String, plugin id: String, session: BackendSession) async {
        guard let plugin = catalog.first(where: { $0.id == id }) else { return }
        let settings = plugin.settings.map { setting in
            var setting = setting
            if setting.key == key { setting.value = value }
            return setting
        }
        await update(plugin, enabled: plugin.enabled, values: settings, session: session)
    }

    private func update(_ plugin: PluginInfo, enabled: Bool, values: [PluginSetting], session: BackendSession) async {
        guard let index = catalog.firstIndex(where: { $0.id == plugin.id }) else { return }
        let previous = catalog[index]
        // Optimistic: the switch moves immediately and reverts on failure.
        catalog[index].enabled = enabled
        catalog[index].settings = values
        do {
            let body = PluginUpdate(enabled: enabled, values: Dictionary(uniqueKeysWithValues: values.map { ($0.key, $0.value) }))
            let saved: PluginInfo = try await session.request("PUT", "/v1/plugins/\(plugin.id)", body: body)
            if let index = catalog.firstIndex(where: { $0.id == plugin.id }) { catalog[index] = saved }
            results.removeAll()
            revision += 1
        } catch {
            if let index = catalog.firstIndex(where: { $0.id == plugin.id }) { catalog[index] = previous }
            store.lastAction = "Couldn’t update \(plugin.name)"
        }
    }

    func reset() {
        catalog = []
        catalogState = .idle
        catalogScope = nil
        results.removeAll()
        loading.removeAll()
        running.removeAll()
        revision += 1
    }

    // MARK: Messages

    static func key(for message: MailMessage) -> String? {
        guard let id = message.backendMessageID, let remote = message.mailAccount.remote,
              !message.isDraft, message.mailbox != .outbox else { return nil }
        return "\(remote.localID)/\(id.uuidString)"
    }

    func plugins(for message: MailMessage) -> MessagePlugins? {
        Self.key(for: message).flatMap { results[$0] }
    }

    /// Fetches cards and actions for a message once; later calls are free.
    func load(_ message: MailMessage, session: BackendSession) async {
        if catalogState == .idle { await refreshCatalog(session: session) }
        guard hasEnabledPlugins, let key = Self.key(for: message), let id = message.backendMessageID,
              let remote = message.mailAccount.remote, session.isAccountConnected(remote.accountID, scope: remote.scope),
              results[key] == nil, !loading.contains(key) else { return }
        loading.insert(key)
        defer { loading.remove(key) }
        let requestRevision = revision
        do {
            let found: MessagePlugins = try await session.request("GET", "/v1/mail/messages/\(id.uuidString)/plugins",
                                                                  query: [URLQueryItem(name: "today", value: Self.today())])
            guard revision == requestRevision else { return }
            results[key] = found.schema <= pluginCardSchema ? found : .empty
            if results.count > 300, let stale = results.keys.first(where: { $0 != key }) { results.removeValue(forKey: stale) }
        } catch {
            // Plugins are an enhancement: a failure leaves the message as it is.
        }
    }

    // MARK: Actions

    func isRunning(plugin: String, tool: String) -> Bool { running.contains("\(plugin)/\(tool)") }

    func perform(_ action: PluginCardAction, plugin: String, message: MailMessage, session: BackendSession) {
        switch action.kind {
        case .open(let url): MailPlatform.open(url)
        case .copy(let text): MailPlatform.copy(text)
        case .tool(let name, let args):
            call(name, args: args, plugin: plugin, message: message, session: session)
        }
    }

    func perform(_ action: PluginMessageAction, message: MailMessage, session: BackendSession) {
        call(action.tool, args: action.args ?? .null, plugin: action.pluginId, message: message, session: session)
    }

    private func call(_ tool: String, args: PluginJSON, plugin: String, message: MailMessage, session: BackendSession) {
        guard let id = message.backendMessageID else { return }
        let key = "\(plugin)/\(tool)"
        guard !running.contains(key) else { return }
        running.insert(key)
        let messageID = message.id
        Task {
            defer { running.remove(key) }
            do {
                let result: PluginToolResult = try await session.request(
                    "POST", "/v1/plugins/\(plugin)/tools/\(tool)",
                    body: PluginToolCall(messageId: id, args: args, today: Self.today()))
                apply(result, to: messageID)
            } catch BackendError.response(let status, let detail) where status == 400 || status == 409 {
                store.lastAction = detail.isEmpty ? "That didn’t work" : detail
            } catch {
                let name = catalog.first(where: { $0.id == plugin })?.name ?? "The plugin"
                store.lastAction = "\(name) couldn’t finish that"
            }
        }
    }

    private func apply(_ result: PluginToolResult, to messageID: UUID) {
        var reminded = false
        for effect in result.effects {
            switch effect {
            case .open(let url): MailPlatform.open(url)
            case .remind(var components):
                // The morning of the chosen day, in the user's time zone.
                components.hour = 9
                guard let date = Calendar.current.date(from: components) else { continue }
                store.setFollowUp(messageID, at: max(date, .now.addingTimeInterval(60)), onlyIfNoReply: false)
                reminded = true
            case .unsupported: continue
            }
        }
        if let toast = result.toast { store.lastAction = toast }
        else if reminded { store.lastAction = "Reminder set" }
    }

    static func today(_ date: Date = .now) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 2000, parts.month ?? 1, parts.day ?? 1)
    }
}
