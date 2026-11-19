import SwiftUI
import AppKit

struct UnsubscribeView: View {
    let message: MailMessage
    let onComposeEmail: (MailUnsubscribeEmail) throws -> Void
    let onLocalActions: (_ archive: Bool, _ block: Bool) -> Void
    private let service: any MailUnsubscribeRequesting
    private let session: BackendSession?

    @Environment(\.dismiss) private var dismiss
    @State private var operation: Task<Void, Never>?
    @State private var operationID: UUID?
    @State private var isRequesting = false
    @State private var status: String?
    @State private var error: String?
    @State private var requestAccepted = false
    @State private var archiveMessage = false
    @State private var blockSender = false
    @State private var localActionsApplied = false
    @State private var remoteOptions: BackendUnsubscribeOptions?

    @MainActor init(message: MailMessage,
         onComposeEmail: @escaping (MailUnsubscribeEmail) throws -> Void,
         onLocalActions: @escaping (_ archive: Bool, _ block: Bool) -> Void,
         service: (any MailUnsubscribeRequesting)? = nil, session: BackendSession? = nil) {
        self.message = message
        self.onComposeEmail = onComposeEmail
        self.onLocalActions = onLocalActions
        self.service = service ?? MailUnsubscribeService()
        self.session = session
    }

    private var options: MailUnsubscribeOptions { MailUnsubscribeService.options(for: message) }
    private var oneClickURL: URL? {
        message.mailAccount.isRemote ? remoteOptions?.oneClickUrl.flatMap(URL.init(string:)) : options.oneClickURL
    }
    private var explanation: String? { message.mailAccount.isRemote ? remoteOptions?.reason : options.explanation }
    private var isBusy: Bool { operationID != nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Unsubscribe").font(PostmereTheme.sheetTitle)
                    Text(message.senderEmail).font(.subheadline).foregroundStyle(.secondary)
                        .lineLimit(2).textSelection(.enabled)
                }
                Spacer()
                Button("Done") { cancelOperation(); dismiss() }.keyboardShortcut(.cancelAction)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if let url = oneClickURL {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Request removal from this mailing list.").font(.subheadline.weight(.medium))
                            Text("The request goes to \(url.host ?? "the sender’s website").")
                                .font(.caption).foregroundStyle(.secondary)
                            Button(requestAccepted ? "Request accepted" : "Request unsubscribe") {
                                perform(isRequest: true) {
                                    if message.mailAccount.isRemote {
                                        guard let session, let id = message.backendMessageID, message.mailAccount.remote?.scope == session.scope else { throw BackendError.notConnected }
                                        let response: BackendUnsubscribeResult = try await session.request("POST", "/v1/mail/messages/\(id.uuidString)/unsubscribe", body: BackendUnsubscribeInput(expectedUrl: url.absoluteString))
                                        guard response.accepted else { throw MailUnsubscribeError.http(response.httpStatus) }
                                    } else { try await service.requestOneClick(for: message) }
                                    return "The sender accepted your unsubscribe request. Their mailing list may take time to update."
                                }
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(isBusy || requestAccepted)
                        }
                    }

                    if let explanation {
                        Text(explanation).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if !options.methods.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            if oneClickURL != nil {
                                Text("Other options").font(.subheadline.weight(.medium))
                            }
                            ForEach(Array(options.methods.enumerated()), id: \.offset) { _, method in
                                methodRow(method)
                            }
                        }
                    } else if oneClickURL == nil && explanation == nil {
                        Text("This sender did not include a supported unsubscribe address.")
                            .font(.callout).foregroundStyle(.secondary)
                    }

                    if isBusy {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text(isRequesting ? "Sending unsubscribe request…" : "Checking website address…")
                                .font(.callout)
                            Spacer()
                            Button("Cancel", action: cancelOperation)
                        }
                    }
                    if let status {
                        Text(status).font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel(status)
                    }
                    if let error {
                        PostmereLabel(error, symbol: "exclamationmark.circle", size: 16)
                            .font(.callout).foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Divider()
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Organize in Postmere").font(.subheadline.weight(.medium))
                        Toggle("Archive this message", isOn: $archiveMessage)
                        Toggle("Send this sender’s future mail to Trash", isOn: $blockSender)
                        Text("These actions organize your mail. They do not unsubscribe you from the sender’s list.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button(localActionsApplied ? "Mail actions applied" : "Apply mail actions") {
                            onLocalActions(archiveMessage, blockSender)
                            localActionsApplied = true
                        }
                        .disabled(isBusy || (!archiveMessage && !blockSender) || localActionsApplied)
                    }
                    .disabled(localActionsApplied)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(24)
        .frame(width: 500, height: 530)
        .onDisappear { operation?.cancel() }
        .task {
            guard let session, let id = message.backendMessageID, message.mailAccount.remote?.scope == session.scope else { return }
            do { remoteOptions = try await session.request("GET", "/v1/mail/messages/\(id.uuidString)/unsubscribe") }
            catch { self.error = error.localizedDescription }
        }
    }

    @ViewBuilder
    private func methodRow(_ method: MailUnsubscribeMethod) -> some View {
        switch method {
        case .email(let email):
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    do {
                        try onComposeEmail(email)
                        dismiss()
                    } catch { self.error = error.localizedDescription }
                } label: {
                    PostmereLabel("Prepare unsubscribe email", symbol: "envelope", size: 16)
                }
                .disabled(isBusy)
                Text("To \(email.recipients.joined(separator: ", ")). Review the draft before sending.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .web(let url):
            VStack(alignment: .leading, spacing: 5) {
                Button {
                    perform(isRequest: false) {
                        let checked = try await service.validateBrowserURL(url)
                        guard NSWorkspace.shared.open(checked) else { throw MailUnsubscribeError.browserUnavailable }
                        return "Opened \(url.host ?? "the sender’s website") in your browser. Complete any steps there; Postmere cannot confirm removal."
                    }
                } label: {
                    PostmereLabel("Open unsubscribe page", symbol: "arrow.up.forward.square", size: 16)
                }
                .disabled(isBusy)
                Text(url.host ?? "The sender’s website")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func perform(isRequest: Bool, action: @escaping @MainActor () async throws -> String) {
        guard !isBusy else { return }
        let id = UUID()
        operationID = id
        isRequesting = isRequest
        status = nil
        error = nil
        operation = Task { @MainActor in
            defer {
                if operationID == id { operationID = nil; operation = nil }
            }
            do {
                let result = try await action()
                guard operationID == id, !Task.isCancelled else { return }
                status = result
                if isRequest { requestAccepted = true }
            } catch {
                guard operationID == id else { return }
                if Task.isCancelled || error is CancellationError {
                    status = cancellationMessage(isRequest: isRequest)
                } else {
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func cancelOperation() {
        guard isBusy else { return }
        operation?.cancel()
        operation = nil
        operationID = nil
        status = cancellationMessage(isRequest: isRequesting)
        error = nil
    }

    private func cancellationMessage(isRequest: Bool) -> String {
        isRequest ? "Request cancelled. If it was already sent, the sender may still process it." : "Opening the website was cancelled."
    }
}

nonisolated private struct BackendUnsubscribeOptions: Decodable, Sendable { let oneClickUrl: String?; let reason: String? }
nonisolated private struct BackendUnsubscribeInput: Encodable, Sendable { let expectedUrl: String }
nonisolated private struct BackendUnsubscribeResult: Decodable, Sendable { let accepted: Bool; let httpStatus: Int; let host: String; let message: String }
