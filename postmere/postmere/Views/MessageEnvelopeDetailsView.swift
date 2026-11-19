import SwiftUI

struct MessageDetailsDisclosure: View {
    let message: MailMessage
    let additionalRecipients: Int
    @State private var showsDetails = false

    var body: some View {
        Button { showsDetails.toggle() } label: {
            HStack(spacing: 3) {
                if additionalRecipients > 0 { Text("+\(additionalRecipients)") }
                PostmereIcon("chevron.down", size: 12)
            }
            .padding(.horizontal, 3)
            .frame(minWidth: 20, minHeight: 20)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show message details")
        .accessibilityLabel("Show message details for \(message.sender)")
        .onChange(of: message.id) { showsDetails = false }
        .popover(isPresented: $showsDetails, arrowEdge: .bottom) {
            MessageEnvelopeDetailsView(message: message).id(message.id)
        }
    }
}

struct MessageEnvelopeDetailsView: View {
    let message: MailMessage
    @Environment(MailRuntime.self) private var runtime
    @State private var fetchedDetails: MailEnvelopeDetails?
    @State private var retryCount = 0
    @State private var loadFailed = false
    @State private var contentHeight: CGFloat = 200

    private var canFetch: Bool {
        guard !message.isDraft, message.mailbox != .outbox,
              message.backendMessageID != nil, let account = message.mailAccount.remote else { return false }
        return runtime.backend.isAccountConnected(account.accountID, scope: account.scope)
    }

    private var details: MailEnvelopeDetails? { fetchedDetails ?? message.envelopeDetails }

    var body: some View {
        ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                row("From", addressLine(name: message.sender, email: message.senderEmail))
                row("To", addresses(message.toRecipients))
                if !message.ccRecipients.isEmpty { row("Cc", addresses(message.ccRecipients)) }
                if message.isOutgoing && !message.bccRecipients.isEmpty { row("Bcc", addresses(message.bccRecipients)) }
                row("Date", message.sentAt.formatted(date: .long, time: .shortened))
                if message.mailAccount != .unassigned { row("Account", message.accountLabel) }
                row("Subject", message.displaySubject)
                if !message.isDraft && message.mailbox != .outbox {
                    Divider().gridCellColumns(2).padding(.vertical, 3)
                    if let path = details?.deliveryHeaders?.returnPath { row("Return path", path) }
                    if let domains = details?.signingDomains, !domains.isEmpty {
                        row("DKIM signer", domains.joined(separator: ", "))
                            .help("Domains declared in the message’s DKIM signatures.")
                    }
                    if details != nil {
                        row("Transport", transport)
                            .help("Protocol reported in the most recent Received header. Earlier hops may differ.")
                    } else if canFetch {
                        GridRow {
                            Text("Delivery").foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            if loadFailed {
                                HStack {
                                    Text("Couldn’t load details.")
                                    Button("Retry") {
                                        loadFailed = false
                                        retryCount += 1
                                    }
                                }
                            } else {
                                HStack(spacing: 7) {
                                    ProgressView().controlSize(.small).accessibilityHidden(true)
                                    Text("Loading delivery details…")
                                }
                                .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        row("Delivery", "No delivery details available")
                    }
                }
            }
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(18)
            .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: 410, height: min(contentHeight, 416))
        .accessibilityLabel("Message details")
        .task(id: canFetch ? retryCount : nil) { await loadCachedEnvelope() }
    }

    private var transport: String {
        guard let code = details?.deliveryHeaders?.receivedWith?.uppercased() else { return "Not reported" }
        if ["ESMTPS", "ESMTPSA", "SMTPS", "LMTPS", "LMTPSA", "UTF8SMTPS", "UTF8SMTPSA"].contains(code) {
            return "\(code) · TLS on the receiving hop"
        }
        return "\(code) · encryption unspecified"
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow(alignment: .firstTextBaseline) {
            Text(label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value.isEmpty ? "—" : value)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func addresses(_ values: [String]) -> String {
        values.map { address in
            let name = details?.recipientNames[address.lowercased()]
            return addressLine(name: name, email: address)
        }.joined(separator: "\n")
    }

    private func addressLine(name: String?, email: String) -> String {
        guard let name, !name.isEmpty, name.caseInsensitiveCompare(email) != .orderedSame else { return email }
        return email.isEmpty ? name : "\(name) <\(email)>"
    }

    // Older local snapshots only contain addresses. Fetch the workspace's cached
    // message once to recover display names and any delivery headers it retained.
    private func loadCachedEnvelope() async {
        guard details == nil, canFetch, let id = message.backendMessageID, let account = message.mailAccount.remote else { return }
        loadFailed = false
        do {
            let envelope: BackendMessageEnvelope = try await runtime.backend.request(
                "GET", "/v1/mail/messages/\(id.uuidString)", query: [URLQueryItem(name: "view", value: "envelope")])
            guard !Task.isCancelled, runtime.backend.isAccountConnected(account.accountID, scope: account.scope) else { return }
            guard envelope.id == id, envelope.accountId == account.accountID else {
                loadFailed = true
                return
            }
            let received = envelope.details
            fetchedDetails = received
            runtime.store.cacheEnvelope(received, messageID: message.id, account: account.localID)
        } catch {
            if !Task.isCancelled { loadFailed = true }
        }
    }
}
