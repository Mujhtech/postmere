import SwiftUI

nonisolated struct BackendActivityResponse: Decodable, Sendable {
    let items: [BackendActivity]
    let attributionNotice: String
}
nonisolated struct BackendActivity: Decodable, Sendable {
    let outboxId: UUID
    let opens: Int
    let clicks: Int
    let firstOpenAt: Date?
    let lastOpenAt: Date?
    let firstClickAt: Date?
    let lastClickAt: Date?
    let events: [BackendActivityEvent]
}
nonisolated struct BackendActivityEvent: Decodable, Identifiable, Sendable {
    let id: UUID
    let kind: String
    let occurredAt: Date
    let recipient: String?
    let device: String
    let isProxyOrBot: Bool
}

struct MessageActivityButton: View {
    @Environment(\.postmereAccent) private var palette
    let message: MailMessage
    let session: BackendSession
    @State private var isPresented = false

    var body: some View {
        Button { isPresented.toggle() } label: {
            PostmereLabel("Message activity", symbol: "eye", size: 12)
                .foregroundStyle(palette.accentInk)
        }
        .onChange(of: message.id) { isPresented = false }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            MessageActivityView(message: message, session: session)
                .id(message.id)
                .onExitCommand { isPresented = false }
        }
    }
}

private struct MessageActivityView: View {
    @Environment(\.postmereAccent) private var palette
    @Environment(\.dismiss) private var dismiss
    let message: MailMessage
    let session: BackendSession
    @State private var response: BackendActivityResponse?
    @State private var isLoading = true
    @State private var error: String?
    @State private var refreshRevision = 0
    @State private var contentHeight: CGFloat = 96

    private var isTracked: Bool {
        message.backendOutboxID != nil && (message.trackOpens == true || message.trackLinks == true)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Message activity").font(.headline).accessibilityAddTraits(.isHeader)
                    Spacer()
                    if isTracked {
                        if isLoading {
                            ProgressView().controlSize(.small).accessibilityLabel("Loading activity")
                        } else if error == nil {
                            Button { refreshRevision += 1 } label: { PostmereIcon("arrow.clockwise", size: 14) }
                                .buttonStyle(.borderless)
                                .help("Refresh activity")
                                .accessibilityLabel("Refresh activity")
                        }
                    }
                    Button { dismiss() } label: { Image(systemName: "xmark") }
                        .buttonStyle(.borderless)
                        .keyboardShortcut(.cancelAction)
                        .help("Close message activity")
                        .accessibilityLabel("Close message activity")
                }
                if !isTracked {
                    Text("Tracking was off for this message. You can enable it in the Send menu before sending.")
                        .foregroundStyle(.secondary)
                } else if let activity = response?.items.first(where: { $0.outboxId == message.backendOutboxID }) {
                    HStack(spacing: 32) {
                        metric("Opens", value: activity.opens, enabled: message.trackOpens == true)
                        metric("Link clicks", value: activity.clicks, enabled: message.trackLinks == true)
                    }
                    if let first = activity.firstOpenAt {
                        LabeledContent("First open", value: first.formatted(date: .abbreviated, time: .shortened))
                    }
                    if let latest = activity.lastOpenAt {
                        LabeledContent("Latest open", value: latest.formatted(date: .abbreviated, time: .shortened))
                    }
                    Divider()
                    if activity.events.isEmpty {
                        Text("No activity recorded yet.").foregroundStyle(.secondary)
                    }
                    ForEach(activity.events.sorted { $0.occurredAt > $1.occurredAt }) { event in
                        eventRow(event)
                    }
                    if let notice = response?.attributionNotice, !notice.isEmpty {
                        Text(notice).font(.caption).foregroundStyle(.secondary)
                    }
                } else if error == nil {
                    Text(isLoading ? "Loading activity…" : "No activity recorded yet.")
                        .foregroundStyle(.secondary)
                }
                if let error {
                    Text(error).foregroundStyle(.secondary)
                    Button("Try Again") { refreshRevision += 1 }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }
            }
            .font(.callout)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 360, height: min(contentHeight, 396))
        .foregroundStyle(Color.primary)
        .task(id: refreshRevision) { await refresh() }
    }

    private func metric(_ title: String, value: Int, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(enabled ? value.formatted() : "Off")
                .font(.title2.weight(.semibold))
                .foregroundStyle(palette.accentInk)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func eventRow(_ event: BackendActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 8) {
            PostmereIcon(deviceIcon(event), size: 14).foregroundStyle(PostmereTheme.icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(event.recipient ?? "Recipient not identified").fontWeight(.medium)
                Text("\(event.kind == "click" ? "Link requested" : "Image requested") · \(event.device)")
                    .font(.caption).foregroundStyle(.secondary)
                if event.isProxyOrBot {
                    Text("May be a privacy proxy or automated request").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            Text(event.occurredAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func deviceIcon(_ event: BackendActivityEvent) -> String {
        if event.isProxyOrBot { return "eye" }
        return ["phone", "mobile", "iphone", "android"].contains(where: { event.device.lowercased().contains($0) }) ? "iphone" : "desktopcomputer"
    }

    private func refresh() async {
        guard isTracked, let id = message.backendOutboxID else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        let scope = message.mailAccount.remote?.scope
        guard let scope, scope == session.scope else { error = BackendError.notConnected.localizedDescription; return }
        do {
            let result: BackendActivityResponse = try await session.request("GET", "/v1/mail/activity", query: [URLQueryItem(name: "message_id", value: id.uuidString)])
            try Task.checkCancellation()
            guard scope == session.scope else { throw BackendError.notConnected }
            response = result
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
