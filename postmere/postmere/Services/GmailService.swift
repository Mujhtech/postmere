import Foundation
import Observation
import AppKit
import UniformTypeIdentifiers

enum GmailConnectionStatus: String {
    case needsConfiguration, disconnected, connecting, connected, syncing

    var title: String {
        switch self {
        case .needsConfiguration: "Setup needed"
        case .disconnected: "Not connected"
        case .connecting: "Waiting for Google"
        case .connected: "Connected"
        case .syncing: "Syncing Gmail"
        }
    }
}

struct GmailCachedMessageVerification {
    var messages: [MailMessage]
    var unavailableMessageIDs: Set<String>
}

@MainActor
@Observable
final class GmailService {
    private(set) var status: GmailConnectionStatus = .needsConfiguration
    private(set) var email: String?
    private(set) var displayName = "Me"
    private(set) var clientID = ""
    private(set) var hasSavedClientSecret = false
    private(set) var isSyncing = false
    private(set) var isSending = false
    private(set) var lastSyncedAt: Date?
    private(set) var hasMoreMessages = false
    private(set) var syncedMessageCount = 0
    private(set) var isVerifyingCachedMessages = false
    var error: String?

    var isConnected: Bool { email != nil && (status == .connected || status == .syncing) }
    var isConnecting: Bool { status == .connecting }

    @ObservationIgnored private let client: GmailAPIClient
    @ObservationIgnored private var loopback: GoogleOAuthLoopback?
    @ObservationIgnored private var didRestore = false
    @ObservationIgnored private var sessionGeneration = UUID()
    @ObservationIgnored private var latestSnapshotIDs: Set<String> = []
    @ObservationIgnored private var lastVerifiedAt: [String: Date] = [:]

    init(client: GmailAPIClient = GmailAPIClient()) { self.client = client }

    func restoreSession() async {
        guard !didRestore else { return }
        didRestore = true
        do { try await refreshConnectionInfo() }
        catch { self.error = error.localizedDescription }
    }

    func saveConfiguration(clientID: String, clientSecret: String? = nil, displayName: String? = nil) async throws {
        do {
            try await client.configure(clientID: clientID, clientSecret: clientSecret, displayName: displayName)
            try await refreshConnectionInfo()
            error = nil
        } catch { self.error = error.localizedDescription; throw error }
    }

    func connect(clientID: String, clientSecret: String? = nil, displayName: String? = nil) async throws {
        guard !isConnecting else { return }
        try await saveConfiguration(clientID: clientID, clientSecret: clientSecret, displayName: displayName)
        let generation = UUID(); sessionGeneration = generation
        status = .connecting; error = nil
        let callback = GoogleOAuthLoopback(); loopback = callback
        do {
            let verifier = try GoogleDesktopOAuth.randomValue()
            let state = try GoogleDesktopOAuth.randomValue()
            let redirect = try await callback.start(state: state)
            let url = try GoogleDesktopOAuth.authorizationURL(clientID: self.clientID, redirect: redirect, state: state, verifier: verifier)
            guard NSWorkspace.shared.open(url) else { throw GmailError.authorization("Postmere could not open your browser for Google sign-in.") }
            let code = try await callback.authorizationCode()
            guard sessionGeneration == generation else { throw GmailError.cancelled }
            _ = try await client.finishAuthorization(code: code, verifier: verifier, redirectURI: redirect.absoluteString)
            guard sessionGeneration == generation else { throw GmailError.cancelled }
            try await refreshConnectionInfo()
            loopback = nil
        } catch {
            await callback.cancel()
            loopback = nil
            try? await refreshConnectionInfo()
            self.error = error.localizedDescription
            throw error
        }
    }

    func cancelSignIn() {
        sessionGeneration = UUID()
        if let loopback { Task { await loopback.cancel() } }
    }

    func disconnect() async {
        cancelSignIn()
        do {
            let warning = try await client.disconnect()
            email = nil; displayName = "Me"; lastSyncedAt = nil; syncedMessageCount = 0; hasMoreMessages = false
            UserDefaults.standard.removeObject(forKey: "gmailEmail")
            UserDefaults.standard.removeObject(forKey: "gmailDisplayName")
            try await refreshConnectionInfo()
            error = warning
        } catch { self.error = error.localizedDescription }
    }

    func sync(maximumMessages: Int = 500) async throws -> [MailMessage] {
        guard !isSyncing else { throw GmailError.configuration("Gmail sync is already in progress.") }
        guard isConnected else { throw GmailError.notConnected }
        let generation = sessionGeneration
        isSyncing = true; status = .syncing; error = nil
        defer {
            isSyncing = false
            if status == .syncing { status = email == nil ? .disconnected : .connected }
        }
        do {
            let profile = try await client.profile()
            let result = try await client.sync(maximumMessages: maximumMessages)
            guard sessionGeneration == generation else { throw GmailError.cancelled }
            email = profile.emailAddress
            UserDefaults.standard.set(profile.emailAddress, forKey: "gmailEmail")
            let messages = result.messages.map { GmailMessageMapper.message($0, accountEmail: profile.emailAddress) }
            syncedMessageCount = messages.count
            latestSnapshotIDs = Set(result.messages.map(\.id))
            hasMoreMessages = result.hasMore
            lastSyncedAt = .now
            return messages
        } catch { await record(error); throw error }
    }

    /// Refresh a small rotating sample of older cached mail. Never infer deletion from
    /// falling outside the latest-message window; preserve notes/drafts in the store.
    func verifyMissingMessages(_ cachedMessages: [MailMessage], maximumChecks: Int = 12) async throws -> GmailCachedMessageVerification {
        guard isConnected, let email else { throw GmailError.notConnected }
        guard !isVerifyingCachedMessages else { return .init(messages: [], unavailableMessageIDs: []) }
        let generation = sessionGeneration
        let cutoff = Date.now.addingTimeInterval(-30 * 60)
        let candidates = cachedMessages.filter {
            guard !$0.isDeletedOnProvider, $0.providerAccountEmail?.caseInsensitiveCompare(email) == .orderedSame,
                  let id = $0.providerMessageID, !latestSnapshotIDs.contains(id) else { return false }
            return (lastVerifiedAt["\(email):\(id)"] ?? .distantPast) < cutoff
        }.sorted {
            let left = lastVerifiedAt["\(email):\($0.providerMessageID ?? "")"] ?? .distantPast
            let right = lastVerifiedAt["\(email):\($1.providerMessageID ?? "")"] ?? .distantPast
            return left == right ? $0.sentAt > $1.sentAt : left < right
        }.prefix(max(0, min(12, maximumChecks)))
        let ids = candidates.compactMap(\.providerMessageID)
        guard !ids.isEmpty else { return .init(messages: [], unavailableMessageIDs: []) }
        isVerifyingCachedMessages = true
        defer { isVerifyingCachedMessages = false }
        do {
            let result = try await client.verify(messageIDs: ids, expectedAccountEmail: email)
            guard generation == sessionGeneration else { throw GmailError.cancelled }
            for id in ids { lastVerifiedAt["\(email):\(id)"] = .now }
            return .init(messages: result.messages.map { GmailMessageMapper.message($0, accountEmail: email) },
                         unavailableMessageIDs: result.unavailableMessageIDs)
        } catch { await record(error); throw error }
    }

    func send(_ message: MailMessage) async throws -> MailMessage {
        guard isConnected, let email else { throw GmailError.notConnected }
        guard message.senderEmail.caseInsensitiveCompare(email) == .orderedSame else {
            throw GmailError.invalidMessage("This draft belongs to a different Gmail account. Reconnect its sending account or create a new draft.")
        }
        guard !isSending else { throw GmailError.configuration("Another Gmail message is being sent. Please wait.") }
        let generation = sessionGeneration
        isSending = true; error = nil
        defer { isSending = false }
        do {
            var files: [GmailOutgoingAttachment] = []
            for attachment in message.attachments {
                let url = try await downloadAttachment(attachment, message: message)
                let mime = attachment.mimeType ?? UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
                let data = try await Task.detached(priority: .userInitiated) {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 25 * 1_024 * 1_024 else { throw GmailError.invalidMessage("The attachment is larger than Gmail’s 25 MB limit.") }
                    return try Data(contentsOf: url, options: .mappedIfSafe)
                }.value
                files.append(.init(name: attachment.name, mimeType: mime, data: data))
            }
            let messageID = "<\(UUID().uuidString.lowercased())@\(email.split(separator: "@").last ?? "postmere.local")>"
            let outgoing = GmailOutgoingMail(from: email, displayName: displayName,
                to: message.toRecipients, cc: message.ccRecipients, bcc: message.bccRecipients,
                subject: message.subject, plainText: message.paragraphs.joined(separator: "\n\n"), html: Self.html(fromRTF: message.bodyRTF),
                messageID: messageID, inReplyTo: message.inReplyTo, references: message.references, attachments: files)
            let raw = try await Task.detached(priority: .userInitiated) { try GmailMIME.encode(outgoing) }.value
            guard sessionGeneration == generation, self.email?.caseInsensitiveCompare(email) == .orderedSame else { throw GmailError.cancelled }
            let sent = try await client.send(raw: raw, threadID: message.inReplyTo == nil ? nil : message.providerThreadID, expectedAccountEmail: email)
            // A successful send response is authoritative. Do not make success depend on a second GET.
            var delivered = message
            delivered.sender = displayName
            delivered.senderEmail = email
            delivered.mailbox = .sent
            delivered.isOutgoing = true
            delivered.isUnread = false
            delivered.sentAt = .now
            delivered.dateLabel = "Today"
            delivered.timeLabel = Date.now.formatted(date: .omitted, time: .shortened)
            delivered.providerMessageID = sent.id
            delivered.providerAccountEmail = email
            delivered.providerThreadID = sent.threadId
            delivered.rfcMessageID = messageID
            delivered.providerLabelIDs = sent.labelIds ?? ["SENT"]
            delivered.bodyHTML = outgoing.html
            return delivered
        } catch { await record(error); throw error }
    }

    func modifyLabels(messageID: String, add: [String], remove: [String]) async throws {
        guard isConnected, let email else { throw GmailError.notConnected }
        do { try await client.modifyLabels(messageID: messageID, add: add, remove: remove, expectedAccountEmail: email) }
        catch { await record(error); throw error }
    }

    func applyMutation(from original: MailMessage, to updated: MailMessage) async throws {
        guard let id = original.providerMessageID else { return }
        let accountEmail = try requireAccount(original.providerAccountEmail)
        do {
            if original.mailbox != updated.mailbox { try await move(original, to: updated.mailbox) }
            var add: [String] = []; var remove: [String] = []
            if original.isUnread != updated.isUnread { if updated.isUnread { add.append("UNREAD") } else { remove.append("UNREAD") } }
            if original.isStarred != updated.isStarred { if updated.isStarred { add.append("STARRED") } else { remove.append("STARRED") } }
            if !add.isEmpty || !remove.isEmpty { try await client.modifyLabels(messageID: id, add: add, remove: remove, expectedAccountEmail: accountEmail) }
        } catch { await record(error); throw error }
    }

    func move(_ message: MailMessage, to mailbox: Mailbox) async throws {
        guard let id = message.providerMessageID else { throw GmailError.invalidMessage("This message has not been synced with Gmail.") }
        let accountEmail = try requireAccount(message.providerAccountEmail)
        do {
            if mailbox == .trash { try await client.trash(messageID: id, expectedAccountEmail: accountEmail); return }
            if message.mailbox == .trash { try await client.trash(messageID: id, restore: true, expectedAccountEmail: accountEmail) }
            switch mailbox {
            case .inbox: try await client.modifyLabels(messageID: id, add: ["INBOX"], remove: ["SPAM"], expectedAccountEmail: accountEmail)
            case .archive, .sent: try await client.modifyLabels(messageID: id, add: [], remove: ["INBOX"], expectedAccountEmail: accountEmail)
            case .starred: try await client.modifyLabels(messageID: id, add: ["STARRED"], remove: [], expectedAccountEmail: accountEmail)
            default: break // Needs Reply, Snoozed, and other Postmere views are local metadata.
            }
        } catch { await record(error); throw error }
    }

    func downloadAttachment(_ attachment: MailAttachment, message: MailMessage) async throws -> URL {
        if let localURL = attachment.localURL, FileManager.default.fileExists(atPath: localURL.path) { return localURL }
        guard let messageID = attachment.providerMessageID ?? message.providerMessageID,
              let attachmentID = attachment.providerAttachmentID, let email else {
            throw GmailError.invalidMessage("This attachment is not available on this Mac. Reattach the file before sending.")
        }
        let accountEmail = try requireAccount(attachment.providerAccountEmail ?? message.providerAccountEmail)
        let data: Data
        if attachmentID.hasPrefix("inline:") {
            let wire = try await client.message(id: messageID, expectedAccountEmail: accountEmail)
            guard let bytes = GmailMessageMapper.inlineAttachment(String(attachmentID.dropFirst(7)), in: wire) else { throw GmailError.invalidResponse }
            data = bytes
        } else { data = try await client.attachmentData(messageID: messageID, attachmentID: attachmentID, expectedAccountEmail: accountEmail) }
        let safeName = URL(fileURLWithPath: attachment.name).lastPathComponent
            .replacingOccurrences(of: ":", with: "_").replacingOccurrences(of: "\0", with: "")
        let directory = try Self.attachmentCache().appendingPathComponent(GmailEncoding.stableID(email).uuidString, isDirectory: true)
            .appendingPathComponent(attachment.id.uuidString, isDirectory: true)
        let url = directory.appendingPathComponent(safeName.isEmpty || safeName == "." || safeName == ".." ? "Attachment" : safeName)
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }.value
        return url
    }

    private func refreshConnectionInfo() async throws {
        let info = try await client.connectionInfo()
        clientID = info?.clientID ?? ""
        hasSavedClientSecret = info?.hasClientSecret ?? false
        email = info?.hasTokens == true ? info?.email : nil
        displayName = info?.displayName ?? email?.split(separator: "@").first.map(String.init) ?? "Me"
        status = clientID.isEmpty ? .needsConfiguration : email == nil ? .disconnected : .connected
        if let email {
            UserDefaults.standard.set(email, forKey: "gmailEmail")
            UserDefaults.standard.set(displayName, forKey: "gmailDisplayName")
        } else {
            UserDefaults.standard.removeObject(forKey: "gmailEmail")
            UserDefaults.standard.removeObject(forKey: "gmailDisplayName")
        }
    }

    private func requireAccount(_ providerEmail: String?) throws -> String {
        guard isConnected, let email else { throw GmailError.notConnected }
        guard let providerEmail, providerEmail.caseInsensitiveCompare(email) == .orderedSame else {
            throw GmailError.invalidMessage("This email belongs to another Gmail account. Reconnect that account before continuing.")
        }
        return email
    }

    private func record(_ error: Error) async {
        self.error = error.localizedDescription
        if case GmailError.notConnected = error { try? await refreshConnectionInfo(); status = .disconnected }
    }

    private static func html(fromRTF rtf: Data?) -> String? {
        guard let rtf,
              let attributed = try? NSAttributedString(data: rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil),
              let data = try? attributed.data(from: NSRange(location: 0, length: attributed.length),
                                              documentAttributes: [.documentType: NSAttributedString.DocumentType.html]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func attachmentCache() throws -> URL {
        try FileManager.default.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Postmere/GmailAttachments", isDirectory: true)
    }

}
