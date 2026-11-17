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

struct MessageActivityView: View {
    let message: MailMessage
    let session: BackendSession
    @Environment(\.dismiss) private var dismiss
    @State private var response: BackendActivityResponse?
    @State private var isLoading = false
    @State private var error: String?

    private var activity: BackendActivity? { response?.items.first { $0.outboxId == message.backendOutboxID } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Message activity").font(PostmereTheme.sheetTitle)
                    Text(message.subject).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if message.backendOutboxID == nil || (message.trackOpens != true && message.trackLinks != true) {
                        ContentUnavailableView {
                            PostmereLabel("Tracking was off", symbol: "eye", size: 32)
                        } description: {
                            Text("Enable tracking from the Send menu before sending a message from a workspace account.")
                        }
                    } else if let activity {
                        HStack(spacing: 28) {
                            metric("Opens", value: activity.opens, enabled: message.trackOpens == true)
                            metric("Link clicks", value: activity.clicks, enabled: message.trackLinks == true)
                            Spacer()
                            Button { Task { await refresh() } } label: { PostmereIcon("arrow.clockwise", size: 15) }
                                .disabled(isLoading).help("Refresh activity").accessibilityLabel("Refresh activity")
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
                            HStack(alignment: .top, spacing: 12) {
                                PostmereIcon(deviceIcon(event), size: 18).foregroundStyle(PostmereTheme.icon).frame(width: 22)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(event.recipient ?? "Recipient not identified").font(.system(size: 13, weight: .medium))
                                    Text("\(event.kind == "click" ? "Link requested" : "Image requested") · \(event.device)")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if event.isProxyOrBot {
                                        Text("May be a privacy proxy or automated request").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Text(event.occurredAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Text(response?.attributionNotice ?? "Image and link requests are signals, not proof that a person read your message.")
                            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    } else if isLoading { ProgressView("Loading activity…").frame(maxWidth: .infinity) }
                    else if error == nil { Text("No activity recorded yet.").foregroundStyle(.secondary) }
                    if let error {
                        Text(error).font(.caption).foregroundStyle(.red)
                        Button("Try Again") { Task { await refresh() } }
                    }
                }.padding(24)
            }.scrollIndicators(.never)
        }.frame(width: 570, height: 540).tint(PostmereTheme.accent)
            .task { await refresh() }
    }

    private func metric(_ title: String, value: Int, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(enabled ? value.formatted() : "Off").font(.system(size: 30, weight: .medium, design: .serif)).foregroundStyle(PostmereTheme.accentInk)
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
    }

    private func deviceIcon(_ event: BackendActivityEvent) -> String {
        if event.isProxyOrBot { return "eye" }
        return ["phone", "mobile", "iphone", "android"].contains(where: { event.device.lowercased().contains($0) }) ? "iphone" : "desktopcomputer"
    }

    private func refresh() async {
        guard let id = message.backendOutboxID, message.trackOpens == true || message.trackLinks == true else { return }
        guard message.mailAccount.remote?.scope == session.scope else { error = BackendError.notConnected.localizedDescription; return }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do { response = try await session.request("GET", "/v1/mail/activity", query: [URLQueryItem(name: "message_id", value: id.uuidString)]) }
        catch { self.error = error.localizedDescription }
    }
}
