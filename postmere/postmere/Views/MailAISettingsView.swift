import SwiftUI

struct MailAISettingsView: View {
    let session: BackendSession
    @Environment(MailRuntime.self) private var runtime
    @State private var settings: MailAISettings?
    @State private var loadedGeneration: UUID?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !session.canAccessWorkspace {
                Text("Connect a workspace in Accounts to use optional AI assistance.").font(.caption).foregroundStyle(.secondary)
            } else if let value = settings, let generation = loadedGeneration, generation == session.realtimeGeneration {
                Toggle("Enable AI assistance", isOn: Binding(get: { settings?.enabled ?? false }, set: { enabled in
                    Task { await save(enabled: enabled, in: generation) }
                })).disabled(busy || (!value.enabled && !value.available && value.decisionAvailable != true))
                if !value.available {
                    Text(value.decisionAvailable == true
                         ? "Spam checks are available. Writing assistance needs an OpenAI connection."
                         : "Your administrator has not configured an AI provider.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text(value.dataNotice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if value.enabled && value.decisionAvailable == true {
                    VStack(alignment: .leading, spacing: 3) {
                        Toggle("Check suspicious incoming mail automatically", isOn: Binding(
                            get: { runtime.spamChecks.automaticChecksEnabled(for: session) },
                            set: { enabled in
                                if generation == session.realtimeGeneration { runtime.spamChecks.setAutomaticChecksEnabled(enabled, for: session) }
                            }
                        ))
                        .disabled(busy)
                        Text("On this Mac, check new messages in this workspace when they show signs of spam.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if value.enabled && value.available {
                    TextField("Writing style", text: Binding(get: { settings?.styleGuide ?? "" }, set: { settings?.styleGuide = String($0.prefix(1000)) }),
                              prompt: Text("For example: concise, friendly, no sign-off"), axis: .vertical).lineLimit(2...4)
                    HStack {
                        Text("\(value.provider) · \(value.model)").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Save Style") { Task { await save(in: generation) } }.disabled(busy)
                    }
                }
            } else if busy { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.task(id: session.realtimeGeneration) {
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
