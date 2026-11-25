import SwiftUI

// MARK: - Needs reply

/// Why this conversation waits on you: the request Postmere found, or that you marked it.
struct MobileNeedsReplyNote: View {
    let annotation: NeedsReplyAnnotation
    let inThread: Bool
    let showSource: () -> Void
    let markDone: () -> Void
    @Environment(\.postmereAccent) private var palette

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Needs reply", systemImage: "arrowshape.turn.up.left.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.orange)
                Spacer(minLength: 0)
                Button(action: markDone) {
                    Label("Done", systemImage: "checkmark")
                        .font(.system(size: 12.5, weight: .semibold))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(.background, in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityHint("Removes this conversation from Needs Reply")
            }
            switch annotation.origin {
            case .marked:
                Text("You marked this for a reply.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            case .detected(let request, let sender):
                Text(verbatim: "“\(request)”")
                    .font(.system(.body, design: .serif))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if inThread {
                    Button(action: showSource) {
                        HStack(spacing: 4) {
                            Text("Asked by \(sender)")
                            Image(systemName: "arrow.down").imageScale(.small)
                        }
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(palette.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityHint("Scrolls to the message with this request")
                } else {
                    Text("Asked by \(sender)").font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

// MARK: - New sender

/// A first-time sender waits in New Senders until you decide, as on the Mac:
/// let them into the Inbox (or straight to Needs Reply or Archive), let everyone
/// at their company in, or block them.
struct MobileNewSenderCard: View {
    let message: MailMessage
    let store: MailStore
    let onRemove: () -> Void
    @Environment(\.postmereAccent) private var palette

    var body: some View {
        let organization = WebsiteIconDomains.shared.organization(for: message.senderEmail)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Label("New sender", systemImage: "person.crop.circle.badge.questionmark")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(palette.accent)
                Spacer(minLength: 0)
            }
            Text("This is the first mail from \(message.senderEmail). Allow it to choose where their mail goes from now on.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Menu {
                    Button("Allow in Inbox", systemImage: "tray") { decide { store.acceptSender(of: message, route: .inbox) } }
                    Button("Route to Needs Reply", systemImage: "arrowshape.turn.up.left") {
                        decide { store.acceptSender(of: message, route: .needsReply) }
                    }
                    Button("Route to Archive", systemImage: "archivebox") { decide { store.acceptSender(of: message, route: .archive) } }
                    if let organization {
                        Divider()
                        Button("Allow Everyone at \(organization)", systemImage: "building.2") {
                            decide { store.acceptDomain(organization, of: message) }
                        }
                    }
                } label: {
                    Label("Allow", systemImage: "tray.and.arrow.down")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                } primaryAction: {
                    decide { store.acceptSender(of: message, route: .inbox) }
                }
                .buttonStyle(.glassProminent)
                .tint(palette.accent)
                .accessibilityHint("Delivers mail from this address to your Inbox. Touch and hold for other places.")
                Button(role: .destructive) {
                    decide { store.blockSender(of: message) }
                    onRemove()
                } label: {
                    Label("Block", systemImage: "hand.raised")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, minHeight: 40)
                }
                .buttonStyle(.glass)
                .tint(PostmereTheme.destructiveInk)
                .accessibilityHint("Moves mail from this address to Trash, now and in future.")
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .sensoryFeedback(.success, trigger: message.workflow.screeningState)
    }

    private func decide(_ action: () -> Void) {
        withAnimation(MobileMotion.reveal) { action() }
    }
}

// MARK: - Message details

/// Every address, the date, and how the message was delivered.
struct MobileMessageDetailsSheet: View {
    let message: MailMessage
    let runtime: MailRuntime
    @Environment(\.dismiss) private var dismiss
    @State private var fetched: MailEnvelopeDetails?
    @State private var failed = false
    @State private var attempt = 0

    private var details: MailEnvelopeDetails? { fetched ?? message.envelopeDetails }

    private var canFetch: Bool {
        guard !message.isDraft, message.mailbox != .outbox,
              message.backendMessageID != nil, let account = message.mailAccount.remote else { return false }
        return runtime.backend.isAccountConnected(account.accountID, scope: account.scope)
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    row("From", addressLine(name: message.sender, email: message.senderEmail))
                    row("To", addresses(message.toRecipients))
                    if !message.ccRecipients.isEmpty { row("Cc", addresses(message.ccRecipients)) }
                    if message.isOutgoing && !message.bccRecipients.isEmpty { row("Bcc", addresses(message.bccRecipients)) }
                    row("Date", message.sentAt.formatted(date: .long, time: .shortened))
                    if message.mailAccount != .unassigned { row("Account", message.accountLabel) }
                    row("Subject", message.displaySubject)
                }
                .mobileSheetRows()
                if !message.isDraft && message.mailbox != .outbox {
                    Section {
                        if let details {
                            if let path = details.deliveryHeaders?.returnPath { row("Return path", path) }
                            if !details.signingDomains.isEmpty { let domains = details.signingDomains
                                row("DKIM signer", domains.joined(separator: ", "))
                            }
                            row("Transport", transport(details))
                        } else if canFetch {
                            if failed {
                                Button("Couldn’t load delivery details. Try Again") { failed = false; attempt += 1 }
                            } else {
                                HStack(spacing: 8) { ProgressView(); Text("Loading delivery details…").foregroundStyle(.secondary) }
                            }
                        } else {
                            Text("No delivery details available").foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("Delivery")
                    } footer: {
                        if details != nil {
                            Text("Transport is what the last server reported. Earlier hops may differ.")
                        }
                    }
                    .mobileSheetRows()
                }
            }
            .textSelection(.enabled)
            .navigationTitle("Message Details")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .task(id: canFetch ? attempt : nil) { await load() }
        }
        .mobileSheetDetents()
    }

    private func row(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(value.isEmpty ? "—" : value).font(.subheadline)
        }
        .accessibilityElement(children: .combine)
    }

    private func transport(_ details: MailEnvelopeDetails) -> String {
        guard let code = details.deliveryHeaders?.receivedWith?.uppercased() else { return "Not reported" }
        if ["ESMTPS", "ESMTPSA", "SMTPS", "LMTPS", "LMTPSA", "UTF8SMTPS", "UTF8SMTPSA"].contains(code) {
            return "\(code) · encrypted (TLS)"
        }
        return "\(code) · encryption not stated"
    }

    private func addresses(_ values: [String]) -> String {
        values.map { addressLine(name: details?.recipientNames[$0.lowercased()], email: $0) }.joined(separator: "\n")
    }

    private func addressLine(name: String?, email: String) -> String {
        guard let name, !name.isEmpty, name.caseInsensitiveCompare(email) != .orderedSame else { return email }
        return email.isEmpty ? name : "\(name) <\(email)>"
    }

    private func load() async {
        guard details == nil, canFetch, let id = message.backendMessageID, let account = message.mailAccount.remote else { return }
        do {
            let envelope: BackendMessageEnvelope = try await runtime.backend.request(
                "GET", "/v1/mail/messages/\(id.uuidString)", query: [URLQueryItem(name: "view", value: "envelope")])
            guard !Task.isCancelled, envelope.id == id, envelope.accountId == account.accountID else {
                if !Task.isCancelled { failed = true }
                return
            }
            fetched = envelope.details
            runtime.store.cacheEnvelope(envelope.details, messageID: message.id, account: account.localID)
        } catch {
            if !Task.isCancelled { failed = true }
        }
    }
}

// MARK: - Activity

extension MailMessage {
    /// Sent through the workspace with open or click tracking on.
    var hasTrackedActivity: Bool {
        isOutgoing && backendOutboxID != nil && (trackOpens == true || trackLinks == true)
    }
}

/// Opens and link clicks for a message you sent with tracking on.
struct MobileActivitySheet: View {
    let message: MailMessage
    let runtime: MailRuntime
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var response: BackendActivityResponse?
    @State private var loading = true
    @State private var error: String?
    @State private var attempt = 0

    private var activity: BackendActivity? { response?.items.first { $0.outboxId == message.backendOutboxID } }

    var body: some View {
        NavigationStack {
            List {
                if let activity {
                    Section {
                        HStack(spacing: 12) {
                            metric("Opens", value: activity.opens, enabled: message.trackOpens == true, symbol: "envelope.open.fill")
                            metric("Link clicks", value: activity.clicks, enabled: message.trackLinks == true, symbol: "link")
                        }
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                    }
                    .mobileSheetRows()
                    if activity.firstOpenAt != nil || activity.lastOpenAt != nil {
                        Section {
                            if let first = activity.firstOpenAt {
                                LabeledContent("First open", value: first.formatted(date: .abbreviated, time: .shortened))
                            }
                            if let last = activity.lastOpenAt {
                                LabeledContent("Latest open", value: last.formatted(date: .abbreviated, time: .shortened))
                            }
                        }
                        .mobileSheetRows()
                    }
                    Section {
                        if activity.events.isEmpty {
                            Text("Nothing yet.").foregroundStyle(.secondary)
                        }
                        ForEach(activity.events.sorted { $0.occurredAt > $1.occurredAt }) { event($0) }
                    } header: {
                        Text("Timeline")
                    } footer: {
                        if let notice = response?.attributionNotice, !notice.isEmpty { Text(notice) }
                    }
                    .mobileSheetRows()
                } else if let error {
                    Section {
                        Text(error).foregroundStyle(.secondary)
                        Button("Try Again") { attempt += 1 }
                    }
                    .mobileSheetRows()
                } else if loading {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                } else {
                    Text("No activity recorded yet.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .refreshable { await load() }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .task(id: attempt) { await load() }
        }
        .mobileSheetDetents()
    }

    private func metric(_ title: String, value: Int, enabled: Bool, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.accent)
            Text(enabled ? value.formatted() : "Off")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
            Text(title).font(.footnote.weight(.medium)).foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    private func event(_ event: BackendActivityEvent) -> some View {
        let phone = ["phone", "mobile", "iphone", "android"].contains { event.device.lowercased().contains($0) }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: event.isProxyOrBot ? "eye.slash" : phone ? "iphone" : "desktopcomputer")
                .foregroundStyle(.secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.recipient ?? "Recipient not identified").font(.subheadline.weight(.medium))
                Text("\(event.kind == "click" ? "Clicked a link" : "Opened") · \(event.device)")
                    .font(.caption).foregroundStyle(.secondary)
                if event.isProxyOrBot {
                    Text("May be a privacy proxy or automated check").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 6)
            Text(event.occurredAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func load() async {
        guard let id = message.backendOutboxID else { return }
        loading = true
        error = nil
        defer { loading = false }
        guard let scope = message.mailAccount.remote?.scope, scope == runtime.backend.scope else {
            error = BackendError.notConnected.localizedDescription
            return
        }
        do {
            let result: BackendActivityResponse = try await runtime.backend.request(
                "GET", "/v1/mail/activity", query: [URLQueryItem(name: "message_id", value: id.uuidString)])
            withAnimation(.snappy) { response = result }
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }
}
