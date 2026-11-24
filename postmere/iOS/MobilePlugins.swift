import SwiftUI
import UIKit

/// Cards that enabled plugins attach to a message: an issue, a bill, a delivery.
struct MobilePluginCards: View {
    let message: MailMessage
    let runtime: MailRuntime
    @Environment(\.postmereAccent) private var palette
    @Environment(\.openURL) private var openURL

    private var plugins: MailPlugins { runtime.plugins }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let cards = plugins.plugins(for: message)?.cards {
                ForEach(cards) { result in card(result) }
            }
        }
        .task(id: "\(message.id)-\(plugins.revision)") {
            await plugins.load(message, session: runtime.backend)
        }
    }

    private func card(_ result: PluginCardResult) -> some View {
        let card = result.card
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                if let brand = card.brand.flatMap(Brand.init(rawValue:)) {
                    BrandTile(brand: brand, size: 28)
                } else {
                    Image(systemName: result.icon)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(palette.accent, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                    Text(card.subtitle ?? result.pluginName).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            ForEach(Array(card.body.enumerated()), id: \.offset) { _, component in
                switch component {
                case .text(let text):
                    Text(text).font(.subheadline)
                case .facts(let facts):
                    VStack(spacing: 6) {
                        ForEach(Array(facts.enumerated()), id: \.offset) { _, fact in
                            HStack(alignment: .firstTextBaseline) {
                                Text(fact.label).foregroundStyle(.secondary)
                                Spacer()
                                Text(fact.value).fontWeight(.medium).multilineTextAlignment(.trailing)
                            }
                            .font(.subheadline)
                        }
                    }
                case .steps(let labels, let current):
                    HStack(spacing: 4) {
                        ForEach(labels.indices, id: \.self) { index in
                            Capsule()
                                .fill(index <= current ? palette.accent : Color(uiColor: .systemGray4))
                                .frame(height: 4)
                        }
                    }
                    Text(labels[current]).font(.caption.weight(.semibold)).foregroundStyle(palette.accent)
                case .badge(let label, _):
                    Text(label)
                        .font(.caption.weight(.bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(palette.accent.opacity(0.14), in: Capsule())
                        .foregroundStyle(palette.accent)
                case .divider:
                    MobileHairline()
                case .unsupported:
                    EmptyView()
                }
            }
            if !card.actions.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(card.actions) { action in
                            Button { perform(action, plugin: result.pluginId) } label: {
                                HStack(spacing: 6) {
                                    if plugins.isRunning(plugin: result.pluginId, tool: action.toolName ?? "") {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Image(systemName: action.icon)
                                    }
                                    Text(action.title)
                                }
                                .font(.footnote.weight(.semibold))
                            }
                            .buttonStyle(action.isPrimary ? AnyPrimitiveButtonStyle(.glassProminent) : AnyPrimitiveButtonStyle(.glass))
                            .tint(palette.accent)
                        }
                    }
                }
            }
        }
        .padding(14)
        .background(Mobile.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func perform(_ action: PluginCardAction, plugin: String) {
        switch action.kind {
        case .open(let url): openURL(url)
        case .copy(let text):
            UIPasteboard.general.string = text
            runtime.store.lastAction = "Copied"
        case .tool:
            plugins.perform(action, plugin: plugin, message: message, session: runtime.backend)
        }
    }
}

private extension PluginCardAction {
    var toolName: String? {
        if case .tool(let name, _) = kind { return name }
        return nil
    }
}

/// Type-erases the two glass button styles so a card can mix primary and secondary actions.
private struct AnyPrimitiveButtonStyle: PrimitiveButtonStyle {
    private let make: (Configuration) -> AnyView

    init<S: PrimitiveButtonStyle>(_ style: S) {
        make = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}

// MARK: - Settings

/// Turn plugins on or off and set their options.
struct MobilePluginSettings: View {
    let runtime: MailRuntime
    @Environment(\.postmereAccent) private var palette

    private var plugins: MailPlugins { runtime.plugins }

    var body: some View {
        List {
            switch plugins.catalogState {
            case .loading where plugins.catalog.isEmpty:
                HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
            case .failed(let message):
                Text(message).foregroundStyle(.secondary)
            default:
                ForEach(plugins.catalog) { plugin in
                    Section {
                        Toggle(isOn: Binding(get: { plugin.enabled },
                                             set: { enabled in Task { await plugins.setEnabled(enabled, for: plugin.id, session: runtime.backend) } })) {
                            HStack(spacing: 12) {
                                let brands = (plugin.brands ?? []).compactMap(Brand.init(rawValue:))
                                if brands.count >= 2 {
                                    BrandPair(first: brands[0], second: brands[1], size: 32)
                                } else if let brand = brands.first {
                                    BrandTile(brand: brand, size: 32)
                                } else {
                                    Image(systemName: plugin.icon)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 32, height: 32)
                                        .background(palette.accent, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                                }
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(plugin.name).font(.body.weight(.semibold))
                                    Text(plugin.summary).font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                        if plugin.enabled {
                            ForEach(plugin.settings) { setting in settingRow(setting, plugin: plugin) }
                        }
                    } footer: {
                        if !plugin.permissions.isEmpty {
                            Text(plugin.permissions.joined(separator: " "))
                        }
                    }
                }
                if plugins.catalog.isEmpty {
                    ContentUnavailableView("No plugins", systemImage: "puzzlepiece.extension",
                        description: Text("Your workspace hasn’t installed any plugins yet."))
                        .listRowBackground(Color.clear)
                }
            }
        }
        .tint(palette.accent)
        .navigationTitle("Plugins")
        .task { await plugins.refreshCatalog(session: runtime.backend) }
    }

    @ViewBuilder private func settingRow(_ setting: PluginSetting, plugin: PluginInfo) -> some View {
        switch setting.type {
        case .toggle:
            Toggle(setting.title, isOn: Binding(get: { setting.value == .bool(true) }, set: { value in
                Task { await plugins.setValue(.bool(value), for: setting.key, plugin: plugin.id, session: runtime.backend) }
            }))
        case .choice:
            Picker(setting.title, selection: Binding(get: {
                if case .string(let value) = setting.value { return value }
                return ""
            }, set: { value in
                Task { await plugins.setValue(.string(value), for: setting.key, plugin: plugin.id, session: runtime.backend) }
            })) {
                ForEach(setting.options ?? []) { option in Text(option.title).tag(option.value) }
            }
        }
    }
}
