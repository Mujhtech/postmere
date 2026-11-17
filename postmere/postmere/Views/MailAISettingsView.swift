import SwiftUI

struct MailAISettingsView: View {
    let session: BackendSession
    @State private var settings: MailAISettings?
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !session.isConnected {
                Text("Connect a workspace in Accounts to use optional AI assistance.").font(.caption).foregroundStyle(.secondary)
            } else if let value = settings {
                Toggle("Enable AI assistance", isOn: Binding(get: { settings?.enabled ?? false }, set: { enabled in
                    settings?.enabled = enabled
                    Task { await save() }
                })).disabled(busy || !value.available)
                if !value.available { Text("Your administrator has not configured an AI provider.").font(.caption).foregroundStyle(.secondary) }
                Text(value.dataNotice).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if value.enabled {
                    TextField("Writing style", text: Binding(get: { settings?.styleGuide ?? "" }, set: { settings?.styleGuide = String($0.prefix(1000)) }),
                              prompt: Text("For example: concise, friendly, no sign-off"), axis: .vertical).lineLimit(2...4)
                    HStack { Text("\(value.provider) · \(value.model)").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Save Style") { Task { await save() } }.disabled(busy) }
                }
            } else if busy { ProgressView().controlSize(.small) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }.task(id: session.isConnected) {
            guard session.isConnected else { settings = nil; return }
            busy = true
            defer { busy = false }
            do { settings = try await session.request("GET", "/v1/ai/settings") }
            catch { self.error = error.localizedDescription }
        }
    }

    private func save() async {
        guard let value = settings else { return }
        busy = true
        error = nil
        defer { busy = false }
        do { settings = try await session.request("PUT", "/v1/ai/settings", body: MailAISettingsInput(enabled: value.enabled, styleGuide: value.styleGuide)) }
        catch { self.error = error.localizedDescription }
    }
}
