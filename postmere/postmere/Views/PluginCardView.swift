import SwiftUI

extension PluginInfo {
    static func tint(named name: String) -> Color {
        switch name {
        case "blue": SettingsTint.blue
        case "indigo": SettingsTint.indigo
        case "purple": SettingsTint.purple
        case "pink": SettingsTint.pink
        case "red": SettingsTint.red
        case "orange": SettingsTint.orange
        case "yellow": SettingsTint.yellow
        case "green": SettingsTint.green
        case "teal": SettingsTint.teal
        default: SettingsTint.gray
        }
    }
}

/// The top-of-message slot for plugin cards. Shows the first card; any others
/// wait behind a link to the plugins panel so a message never stacks banners.
struct PluginBanner: View {
    let message: MailMessage
    @Environment(MailRuntime.self) private var runtime
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let plugins = runtime.plugins
        let found = plugins.plugins(for: message)
        VStack(alignment: .leading, spacing: 0) {
            if let first = found?.cards.first {
                PluginCardView(result: first, message: message, more: found.map { $0.cards.count - 1 } ?? 0) {
                    runtime.openReaderPanel(.plugins)
                }
                .padding(.bottom, 14)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .offset(y: -10).combined(with: .opacity).combined(with: .scale(scale: 0.97, anchor: .top)),
                    removal: .opacity))
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.2) : .spring(duration: 0.45, bounce: 0.15), value: found?.cards.first?.id)
        .task(id: "\(MailPlugins.key(for: message) ?? "")#\(plugins.revision)") {
            await plugins.load(message, session: runtime.backend)
        }
    }
}

/// One plugin card, drawn with Postmere's own components so every plugin
/// matches the reader: a tinted disc, a title and line of context, the body,
/// then compact actions.
struct PluginCardView: View {
    let result: PluginCardResult
    let message: MailMessage
    var more = 0
    var showsMore: () -> Void = {}
    var separated = true

    @Environment(MailRuntime.self) private var runtime
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "general"
    @State private var appeared = false

    private var tint: Color { PluginInfo.tint(named: result.tint) }
    private var card: PluginCard { result.card }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 11) {
                PluginOrb(symbol: result.icon, tint: tint, brand: card.brand.flatMap(Brand.init(rawValue:)))
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(verbatim: card.title)
                            .font(.system(size: 13, weight: .semibold))
                            .accessibilityAddTraits(.isHeader)
                        Text(verbatim: result.pluginName)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                        Spacer(minLength: 8)
                        if more > 0 {
                            Button(more == 1 ? "1 more" : "\(more) more", action: showsMore)
                                .buttonStyle(.plain)
                                .font(.system(size: 11.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .help("Show every plugin card for this message")
                        }
                    }
                    if let subtitle = card.subtitle {
                        Text(verbatim: subtitle)
                            .font(.system(size: 12.5))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                    if !card.body.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(Array(card.body.enumerated()), id: \.offset) { _, component in
                                componentView(component)
                            }
                        }
                        .padding(.top, 6)
                    }
                    if !card.actions.isEmpty {
                        HStack(spacing: 8) {
                            ForEach(card.actions) { action in
                                PluginActionButton(action: action, tint: tint,
                                                   running: toolName(action).map { runtime.plugins.isRunning(plugin: result.pluginId, tool: $0) } ?? false) {
                                    runtime.plugins.perform(action, plugin: result.pluginId, message: message, session: runtime.backend)
                                }
                            }
                        }
                        .controlSize(.small)
                        .padding(.top, 8)
                    }
                }
                .frame(maxWidth: 560, alignment: .leading)
            }
            .padding(.vertical, 12)
            if separated {
                Rectangle().fill(.separator).frame(height: 1).accessibilityHidden(true)
            }
        }
        .contextMenu {
            Button("\(result.pluginName) Settings…") {
                settingsTab = "plugins"
                openSettings()
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(result.pluginName): \(card.title)")
    }

    private func toolName(_ action: PluginCardAction) -> String? {
        if case .tool(let name, _) = action.kind { name } else { nil }
    }

    @ViewBuilder private func componentView(_ component: PluginComponent) -> some View {
        switch component {
        case .text(let text):
            Text(verbatim: text)
                .font(.system(size: 12.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        case .facts(let items):
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 3) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    GridRow {
                        Text(verbatim: item.label)
                            .font(.system(size: 11.5))
                            .foregroundStyle(.tertiary)
                        Text(verbatim: item.value)
                            .font(.system(size: 12, weight: .medium).monospacedDigit())
                            .foregroundStyle(.primary.opacity(0.85))
                            .textSelection(.enabled)
                    }
                }
            }
        case .steps(let labels, let current):
            PluginStepTrack(labels: labels, current: current, tint: tint)
        case .badge(let label, let tintName):
            SettingsPill(title: label, tint: tintName.map { PluginInfo.tint(named: $0) } ?? tint, symbol: nil)
        case .divider:
            Divider()
        case .unsupported:
            EmptyView()
        }
    }
}

/// The plugin's icon in a tinted disc, popping in once when the card lands.
private struct PluginOrb: View {
    let symbol: String
    let tint: Color
    /// The service's own mark replaces the plugin glyph when the card names one.
    var brand: Brand?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var kick = 0

    var body: some View {
        Group {
            if let brand {
                BrandMark(brand: brand, size: 16)
            } else {
                PostmereIcon(symbol, size: 15).foregroundStyle(tint)
            }
        }
            .frame(width: 30, height: 30)
            .background(discFill, in: Circle())
            .keyframeAnimator(initialValue: 1.0, trigger: kick) { [reduceMotion] content, scale in
                content.scaleEffect(reduceMotion ? 1 : scale)
            } keyframes: { _ in
                SpringKeyframe(1.16, duration: 0.14, spring: .snappy)
                SpringKeyframe(1.0, duration: 0.45, spring: .bouncy)
            }
            .onAppear { kick += 1 }
            .accessibilityHidden(true)
    }

    private var discFill: Color {
        guard let brand else { return tint.opacity(0.13) }
        return brand.isDark || brand.isFullColor ? Color.primary.opacity(0.07) : brand.color.opacity(0.13)
    }
}

/// Stages as a segmented bar that fills up to the current one on appear, with
/// the first and last stage named underneath.
private struct PluginStepTrack: View {
    let labels: [String]
    let current: Int
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filled = -1

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                ForEach(labels.indices, id: \.self) { index in
                    Capsule()
                        .fill(index <= filled ? tint : Color.primary.opacity(0.09))
                        .frame(height: 4)
                        .overlay {
                            if index == current && index == filled && !reduceMotion && current < labels.count - 1 {
                                Capsule().fill(tint).phaseAnimator([0.35, 1.0]) { content, opacity in
                                    content.opacity(opacity)
                                } animation: { _ in .easeInOut(duration: 0.9) }
                            }
                        }
                }
            }
            .frame(maxWidth: 320)
            HStack {
                Text(verbatim: labels.first ?? "")
                Spacer()
                Text(verbatim: labels.last ?? "")
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: 320)
        }
        .onAppear {
            guard filled < 0 else { return }
            if reduceMotion { filled = current; return }
            for step in 0...current {
                withAnimation(.spring(duration: 0.4, bounce: 0.1).delay(0.12 + Double(step) * 0.09)) { filled = step }
            }
        }
        .accessibilityElement()
        .accessibilityLabel("\(labels[current]), step \(current + 1) of \(labels.count)")
    }
}

private struct PluginActionButton: View {
    let action: PluginCardAction
    let tint: Color
    let running: Bool
    let run: () -> Void
    @State private var copied = false

    var body: some View {
        let button = Button {
            run()
            if case .copy = action.kind {
                copied = true
                Task { try? await Task.sleep(for: .seconds(1.4)); copied = false }
            }
        } label: {
            HStack(spacing: 5) {
                if running {
                    ProgressView().controlSize(.mini)
                } else {
                    PostmereIcon(copied ? "checkmark" : action.icon, size: 11)
                        .contentTransition(.opacity)
                }
                Text(copied ? "Copied" : action.title)
                    .contentTransition(.opacity)
            }
            .animation(.easeOut(duration: 0.15), value: copied)
        }
        .disabled(running)
        .help(help)
        if action.isPrimary {
            button.buttonStyle(.borderedProminent).tint(tint)
        } else {
            button.buttonStyle(.bordered)
        }
    }

    private var help: String {
        switch action.kind {
        case .open(let url): "Open \(url.host() ?? "link")"
        case .copy: "Copy to the clipboard"
        case .tool: action.title
        }
    }
}

/// Every card for the message, for the reader's side panel.
struct PluginPanelView: View {
    let message: MailMessage
    @Environment(MailRuntime.self) private var runtime

    var body: some View {
        let found = runtime.plugins.plugins(for: message)
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if let found, !found.cards.isEmpty {
                    ForEach(found.cards) { result in
                        PluginCardView(result: result, message: message, separated: result.id != found.cards.last?.id)
                    }
                } else {
                    Text("No plugin has anything for this message.")
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                }
            }
            .padding(.horizontal, 16)
        }
        .task(id: MailPlugins.key(for: message)) {
            await runtime.plugins.load(message, session: runtime.backend)
        }
    }
}
