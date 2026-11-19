import Foundation

nonisolated struct MailStateSnapshot: Encodable, @MainActor Decodable, Sendable {
    var schemaVersion = 1
    var messages: [MailMessage]
    var savedViews: [SavedInboxView]
    var snippets: [MailSnippet]
    var senderRules: [SenderRule]
    var outgoingQueue: [OutgoingMailItem]
    var activeDraft: ActiveMailDraft?
    var senderScreeningEnabled: Bool
    var inboxSplits: [InboxSplit]
    var selectedInboxSplitID: UUID?
    var inboxSplitOverlapPolicy: InboxSplitOverlapPolicy = .firstMatch
    var vipContacts: [VIPContact] = []
    var backendSyncCursors: [String: String] = [:]
    var backendNotificationCutoffs: [String: Date] = [:]

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, messages, savedViews, snippets, senderRules, outgoingQueue, activeDraft,
             senderScreeningEnabled, inboxSplits, selectedInboxSplitID, inboxSplitOverlapPolicy, vipContacts, backendSyncCursors,
             backendNotificationCutoffs
    }

    @MainActor
    init(schemaVersion: Int = 1, messages: [MailMessage], savedViews: [SavedInboxView], snippets: [MailSnippet],
         senderRules: [SenderRule], outgoingQueue: [OutgoingMailItem], activeDraft: ActiveMailDraft?,
         senderScreeningEnabled: Bool, inboxSplits: [InboxSplit],
         selectedInboxSplitID: UUID? = nil, inboxSplitOverlapPolicy: InboxSplitOverlapPolicy = .firstMatch,
         vipContacts: [VIPContact] = [], backendSyncCursors: [String: String] = [:],
         backendNotificationCutoffs: [String: Date] = [:]) {
        self.schemaVersion = schemaVersion
        self.messages = messages
        self.savedViews = savedViews
        self.snippets = snippets
        self.senderRules = senderRules
        self.outgoingQueue = outgoingQueue
        self.activeDraft = activeDraft
        self.senderScreeningEnabled = senderScreeningEnabled
        self.inboxSplits = inboxSplits
        self.selectedInboxSplitID = selectedInboxSplitID
        self.inboxSplitOverlapPolicy = inboxSplitOverlapPolicy
        self.vipContacts = vipContacts
        self.backendSyncCursors = backendSyncCursors
        self.backendNotificationCutoffs = backendNotificationCutoffs
    }

    @MainActor
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        messages = try values.decode([MailMessage].self, forKey: .messages)
        for index in messages.indices { messages[index].restoreReceivedText() }
        savedViews = try values.decodeIfPresent([SavedInboxView].self, forKey: .savedViews) ?? []
        snippets = try values.decodeIfPresent([MailSnippet].self, forKey: .snippets) ?? []
        senderRules = try values.decodeIfPresent([SenderRule].self, forKey: .senderRules) ?? []
        outgoingQueue = try values.decodeIfPresent([OutgoingMailItem].self, forKey: .outgoingQueue) ?? []
        activeDraft = try values.decodeIfPresent(ActiveMailDraft.self, forKey: .activeDraft)
        senderScreeningEnabled = try values.decodeIfPresent(Bool.self, forKey: .senderScreeningEnabled) ?? false
        inboxSplits = try values.decodeIfPresent([InboxSplit].self, forKey: .inboxSplits) ?? InboxSplit.defaults
        selectedInboxSplitID = try values.decodeIfPresent(UUID.self, forKey: .selectedInboxSplitID)
        inboxSplitOverlapPolicy = try values.decodeIfPresent(InboxSplitOverlapPolicy.self, forKey: .inboxSplitOverlapPolicy) ?? .firstMatch
        vipContacts = try values.decodeIfPresent([VIPContact].self, forKey: .vipContacts) ?? []
        backendSyncCursors = try values.decodeIfPresent([String: String].self, forKey: .backendSyncCursors) ?? [:]
        backendNotificationCutoffs = try values.decodeIfPresent([String: Date].self, forKey: .backendNotificationCutoffs) ?? [:]
    }
}

/// One atomic snapshot keeps messages, the active draft and the outgoing queue consistent.
nonisolated struct MailPersistence: Sendable {
    let fileURL: URL
    static var defaultDirectory: URL {
        URL.applicationSupportDirectory.appendingPathComponent("Postmere", isDirectory: true)
    }
    static var defaultURL: URL { defaultDirectory.appendingPathComponent("mail-state.json") }
    var attachmentDirectory: URL {
        fileURL.deletingLastPathComponent().appendingPathComponent("Attachments", isDirectory: true)
    }

    @MainActor
    func load() throws -> MailStateSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let state = try decoder.decode(MailStateSnapshot.self, from: Data(contentsOf: fileURL))
        guard state.schemaVersion == 1 else { throw MailStorageError.unsupportedVersion(state.schemaVersion) }
        guard Set(state.messages.map(\.id)).count == state.messages.count else {
            throw MailStorageError.invalidSnapshot("The mailbox contains duplicate message identifiers.")
        }
        guard Set(state.inboxSplits.map(\.id)).count == state.inboxSplits.count,
              Set(state.vipContacts.map(\.id)).count == state.vipContacts.count else {
            throw MailStorageError.invalidSnapshot("The inbox settings contain duplicate identifiers.")
        }
        guard Set(state.outgoingQueue.map(\.id)).count == state.outgoingQueue.count,
              state.outgoingQueue.allSatisfy({ queued in state.messages.contains { $0.id == queued.id && $0.mailbox == .outbox } }) else {
            throw MailStorageError.invalidSnapshot("The outgoing queue is inconsistent with the saved mailbox.")
        }
        return state
    }

    func save(_ state: MailStateSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(state)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}

enum MailStorageError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidSnapshot(String)
    case workspaceRequired
    case missingSender
    case accountMismatch(String)
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "This mailbox was saved by a newer version of Postmere (format \(version)). Its data has not been changed."
        case .invalidSnapshot(let reason): reason
        case .workspaceRequired: "This send uses a previous local account. Restore its draft, select a workspace account, and review it before sending."
        case .missingSender: "Connect to your workspace before sending this message."
        case .accountMismatch(let email): "This message belongs to \(email). Reconnect that workspace account to send it."
        }
    }
}
