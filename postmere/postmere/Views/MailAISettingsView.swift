import AppKit
import SwiftUI

struct MailAISettingsView: View {
    let session: BackendSession
    @Environment(MailRuntime.self) private var runtime
    @State private var settings: MailAISettings?
    @State private var loadedGeneration: UUID?
    @State private var busy = false
    @State private var error: String?

    private var mcpURL: URL? {
        guard session.isConnected, let base = URL(string: session.baseURL) else { return nil }
        return base.appending(path: "mcp")
    }

    var body: some View {
        Form {
            if !session.canAccessWorkspace {
                Section {
                    SettingsRow("AI assistance", symbol: "sparkles", tint: SettingsTint.purple,
                                subtitle: "Connect a workspace to turn this on") {
                        AccountSettingsButton(title: "Open Accounts").controlSize(.small)
                    }
                }
            } else if let value = settings, let generation = loadedGeneration, generation == session.realtimeGeneration {
                Section {
                    SettingsRow("AI assistance", symbol: "sparkles", tint: SettingsTint.purple, subtitle: availability(value)) {
                        HStack(spacing: 8) {
                            SettingsInfoButton(text: value.dataNotice)
                            Toggle("AI assistance", isOn: Binding(get: { settings?.enabled ?? false }, set: { enabled in
                                Task { await save(enabled: enabled, in: generation) }
                            }))
                            .toggleStyle(.switch).labelsHidden().controlSize(.small)
                            .disabled(busy || (!value.enabled && !value.available && value.decisionAvailable != true))
                        }
                    }
                    if value.enabled && value.decisionAvailable == true {
                        SettingsToggle("Automatic spam checks", symbol: "shield", tint: SettingsTint.red,
                                       subtitle: "Check suspicious new mail on this Mac", isOn: Binding(
                            get: { runtime.spamChecks.automaticChecksEnabled(for: session) },
                            set: { enabled in
                                if generation == session.realtimeGeneration { runtime.spamChecks.setAutomaticChecksEnabled(enabled, for: session) }
                            }
                        ))
                        .disabled(busy)
                    }
                }
                if value.enabled && value.available {
                    Section("Writing style") {
                        TextField("Writing style", text: Binding(get: { settings?.styleGuide ?? "" },
                                                                 set: { settings?.styleGuide = String($0.prefix(1000)) }),
                                  prompt: Text("Concise, friendly, no sign-off"), axis: .vertical)
                            .lineLimit(3...5)
                            .labelsHidden()
                        HStack {
                            Text("Used when AI drafts or edits for you").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            Spacer()
                            Button("Save") { Task { await save(in: generation) } }
                                .controlSize(.small)
                                .disabled(busy)
                        }
                    }
                }
            } else {
                // Always draw something, so the load below has a view to run on.
                Section {
                    SettingsRow("AI assistance", symbol: "sparkles", tint: SettingsTint.purple,
                                subtitle: error == nil ? "Loading…" : "Couldn’t load settings") {
                        if error == nil { ProgressView().controlSize(.small) }
                    }
                }
            }
            if let error {
                Section { Text(error).font(.system(size: 11.5)).foregroundStyle(.red).textSelection(.enabled) }
            }
            if let mcpURL {
                AssistantSettings(session: session, mcpURL: mcpURL, monitor: runtime.assistants)
            }
        }
        .formStyle(.grouped)
        .task(id: session.realtimeGeneration) {
            settings = nil
            loadedGeneration = nil
            error = nil
            guard let generation = session.realtimeGeneration else { busy = false; return }
            busy = true
            defer { if session.realtimeGeneration == generation { busy = false } }
            do {
                let loaded: MailAISettings = try await session.request("GET", "/v1/ai/settings")
                if !Task.isCancelled, session.realtimeGeneration == generation {
                    settings = loaded
                    loadedGeneration = generation
                }
            } catch {
                if !Task.isCancelled, session.realtimeGeneration == generation { self.error = error.localizedDescription }
            }
        }
    }

    private func availability(_ value: MailAISettings) -> String {
        if value.available { return "\(value.provider) · \(value.model)" }
        return value.decisionAvailable == true ? "Spam checks only; writing needs an AI provider" : "Not set up by your administrator"
    }

    private func save(enabled: Bool? = nil, in generation: UUID) async {
        guard !busy, let value = settings, generation == session.realtimeGeneration else { return }
        busy = true
        error = nil
        defer { if session.realtimeGeneration == generation { busy = false } }
        do {
            let updated: MailAISettings = try await session.request("PUT", "/v1/ai/settings", body: MailAISettingsInput(enabled: enabled ?? value.enabled, styleGuide: value.styleGuide))
            if session.realtimeGeneration == generation {
                settings = updated
                if !updated.enabled {
                    runtime.spamChecks.setAutomaticChecksEnabled(false, for: session)
                }
            }
        } catch {
            if session.realtimeGeneration == generation { self.error = error.localizedDescription }
        }
    }
}
