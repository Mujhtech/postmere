import Foundation
import os

nonisolated struct MailStateSnapshot: Codable, Sendable {
    private var junkMailboxVersion = 1
    static let currentReplyIndexVersion = 2
    var replyIndexVersion = Self.currentReplyIndexVersion
    var schemaVersion = 1
    var messages: [MailMessage]
    var savedViews: [SavedInboxView]
    var snippets: [MailSnippet]
    var senderRules: [SenderRule]
    var outgoingQueue: [OutgoingMailItem]
    var activeDraft: ActiveMailDraft?
    var senderScreeningEnabled: Bool
    var inboxSplitDefaultsVersion = InboxSplit.defaultsVersion
    var inboxSplits: [InboxSplit]
    var selectedInboxSplitID: UUID?
    var inboxSplitOverlapPolicy: InboxSplitOverlapPolicy = .firstMatch
    var vipContacts: [VIPContact] = []
    var backendSyncCursors: [String: String] = [:]
    var backendNotificationCutoffs: [String: Date] = [:]
    var spamCheckResults: [String: StoredSpamCheck] = [:]

    private enum CodingKeys: String, CodingKey {
        case junkMailboxVersion, replyIndexVersion, schemaVersion, messages, savedViews, snippets, senderRules, outgoingQueue, activeDraft,
             senderScreeningEnabled, inboxSplitDefaultsVersion, inboxSplits, selectedInboxSplitID, inboxSplitOverlapPolicy, vipContacts, backendSyncCursors,
             backendNotificationCutoffs, spamCheckResults
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

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        replyIndexVersion = try values.decodeIfPresent(Int.self, forKey: .replyIndexVersion) ?? 0
        schemaVersion = try values.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        messages = try values.decode([MailMessage].self, forKey: .messages)
        let repairJunk = try values.decodeIfPresent(Int.self, forKey: .junkMailboxVersion) == nil
        for index in messages.indices {
            // Format 2 keeps bodies in separate files; they are repaired once loaded.
            if schemaVersion == 1 { messages[index].restoreReceivedText() }
            if repairJunk, messages[index].mailbox == .archive {
                messages[index].mailbox = Mailbox.archive.correctingLegacyJunk(labels: messages[index].providerLabelIDs)
            }
        }
        savedViews = try values.decodeIfPresent([SavedInboxView].self, forKey: .savedViews) ?? []
        snippets = try values.decodeIfPresent([MailSnippet].self, forKey: .snippets) ?? []
        senderRules = try values.decodeIfPresent([SenderRule].self, forKey: .senderRules) ?? []
        outgoingQueue = try values.decodeIfPresent([OutgoingMailItem].self, forKey: .outgoingQueue) ?? []
        activeDraft = try values.decodeIfPresent(ActiveMailDraft.self, forKey: .activeDraft)
        senderScreeningEnabled = try values.decodeIfPresent(Bool.self, forKey: .senderScreeningEnabled) ?? false
        let previousDefaults = try values.decodeIfPresent(Int.self, forKey: .inboxSplitDefaultsVersion) ?? 0
        if let saved = try values.decodeIfPresent([InboxSplit].self, forKey: .inboxSplits) {
            inboxSplits = previousDefaults < InboxSplit.defaultsVersion ? InboxSplit.upgradingLegacyTabs(saved) : saved
        } else {
            inboxSplits = InboxSplit.defaults
        }
        selectedInboxSplitID = try values.decodeIfPresent(UUID.self, forKey: .selectedInboxSplitID)
        inboxSplitOverlapPolicy = try values.decodeIfPresent(InboxSplitOverlapPolicy.self, forKey: .inboxSplitOverlapPolicy) ?? .firstMatch
        vipContacts = try values.decodeIfPresent([VIPContact].self, forKey: .vipContacts) ?? []
        backendSyncCursors = try values.decodeIfPresent([String: String].self, forKey: .backendSyncCursors) ?? [:]
        backendNotificationCutoffs = try values.decodeIfPresent([String: Date].self, forKey: .backendNotificationCutoffs) ?? [:]
        spamCheckResults = try values.decodeIfPresent([String: StoredSpamCheck].self, forKey: .spamCheckResults) ?? [:]
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

    /// Format 2 stores each message body in its own file here, written only
    /// when it changes, so routine saves no longer re-encode every body.
    var bodyDirectory: URL { URL(fileURLWithPath: fileURL.path + ".bodies", isDirectory: true) }

    /// With `bodies: false`, format 2 returns message metadata only, which is
    /// enough to show the mailbox; `loadBodies` then fills bodies in. Until a
    /// body is loaded, saves keep its file instead of writing it empty.
    func load(bodies: Bool = true) throws -> MailStateSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let started = ContinuousClock.now
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        let raw = try Data(contentsOf: fileURL)
        var state = try decoder.decode(MailStateSnapshot.self, from: raw)
        let decoded = ContinuousClock.now
        defer {
            // Sizes and timings only; never message content.
            Logger(subsystem: "mujhtech.postmere", category: "storage").notice(
                "mailbox load: \(state.messages.count, privacy: .public) messages, \(raw.count, privacy: .public) bytes, snapshot \((decoded - started).components.attoseconds / 1_000_000_000_000_000 + (decoded - started).components.seconds * 1000, privacy: .public) ms, total \((ContinuousClock.now - started).components.attoseconds / 1_000_000_000_000_000 + (ContinuousClock.now - started).components.seconds * 1000, privacy: .public) ms")
        }
        guard state.schemaVersion == 1 || state.schemaVersion == 2 else { throw MailStorageError.unsupportedVersion(state.schemaVersion) }
        if state.schemaVersion == 2 {
            removeUnreferencedBodies(keeping: Set(state.messages.map(\.id)))
            MailBodyLedger.shared.reset(pending: Set(state.messages.map(\.id)), for: bodyDirectory)
            // Collapsing duplicates merges their bodies, so that rare repair loads them first.
            let draft = state.activeDraft?.editingMessageID
            let collapses = !MailSyncRepair.collapse(state.messages, preferring: Set([draft].compactMap { $0 })).replacedIDs.isEmpty
            if bodies || collapses {
                let loaded = loadBodies(for: state.messages)
                for index in state.messages.indices {
                    if let restored = loaded[state.messages[index].id] { state.messages[index] = restored }
                }
            }
        } else {
            MailBodyLedger.shared.reset(pending: [], for: bodyDirectory)
        }
        let draftID = state.activeDraft?.editingMessageID
        let repair = MailSyncRepair.collapse(state.messages, preferring: Set([draftID].compactMap { $0 }))
        state.messages = repair.messages
        if !repair.replacedIDs.isEmpty { state.replyIndexVersion = 0 }
        if let draftID, let survivor = repair.replacedIDs[draftID] { state.activeDraft?.editingMessageID = survivor }
        guard Set(state.messages.map(\.id)).count == state.messages.count else {
            throw MailStorageError.invalidSnapshot("The mailbox contains duplicate message identifiers.")
        }
        guard Set(state.inboxSplits.map(\.id)).count == state.inboxSplits.count,
              Set(state.vipContacts.map(\.id)).count == state.vipContacts.count else {
            throw MailStorageError.invalidSnapshot("The inbox settings contain duplicate identifiers.")
        }
        let queuedIDs = Set(state.outgoingQueue.map(\.messageID))
        guard queuedIDs.count == state.outgoingQueue.count,
              queuedIDs.isEmpty || queuedIDs.isSubset(of: state.messages.lazy.filter { $0.mailbox == .outbox }.map(\.id)) else {
            throw MailStorageError.invalidSnapshot("The outgoing queue is inconsistent with the saved mailbox.")
        }
        return state
    }

    func save(_ state: MailStateSnapshot) throws {
        let directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.createDirectory(at: bodyDirectory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        // Bodies first, then the snapshot that refers to them, then cleanup:
        // an interruption at any point leaves a readable mailbox.
        let (previous, pending) = MailBodyLedger.shared.state(for: bodyDirectory)
        var written: [UUID: StoredMessageBody] = [:]
        var stillPending: Set<UUID> = []
        var snapshot = state
        snapshot.schemaVersion = 2
        for index in snapshot.messages.indices {
            let body = StoredMessageBody(snapshot.messages[index])
            let id = snapshot.messages[index].id
            // A body not loaded yet is still on disk; never replace it with nothing.
            if pending.contains(id) && body.isEmpty {
                stillPending.insert(id)
                StoredMessageBody.strip(&snapshot.messages[index])
                continue
            }
            // Unchanged bodies share storage with the last write, so this
            // comparison returns without reading their contents.
            if previous[id] != body {
                let file = bodyFile(id)
                try encoder.encode(body).write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
            written[id] = body
            StoredMessageBody.strip(&snapshot.messages[index])
        }
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        for id in Set(previous.keys).union(pending) where written[id] == nil && !stillPending.contains(id) {
            try? FileManager.default.removeItem(at: bodyFile(id))
        }
        MailBodyLedger.shared.finishSave(written: written, pending: stillPending, for: bodyDirectory)
    }

    /// Reads the stored bodies of these messages and returns each message with
    /// its body restored. Safe off the main thread.
    func loadBodies(for messages: [MailMessage]) -> [UUID: MailMessage] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        var restored: [UUID: MailMessage] = [:]
        var bodies: [UUID: StoredMessageBody] = [:]
        for var message in messages {
            guard let data = try? Data(contentsOf: bodyFile(message.id)),
                  let body = try? decoder.decode(StoredMessageBody.self, from: data) else { continue }
            body.apply(to: &message)
            message.restoreReceivedText()
            bodies[message.id] = body
            restored[message.id] = message
        }
        MailBodyLedger.shared.loaded(bodies, for: bodyDirectory)
        return restored
    }

    private func bodyFile(_ id: UUID) -> URL {
        bodyDirectory.appendingPathComponent(id.uuidString.lowercased() + ".json")
    }

    /// Bodies left behind by an interrupted save of a removed message.
    private func removeUnreferencedBodies(keeping ids: Set<UUID>) {
        guard let files = try? FileManager.default.contentsOfDirectory(atPath: bodyDirectory.path) else { return }
        for name in files where name.hasSuffix(".json") {
            guard let id = UUID(uuidString: String(name.dropLast(5))), !ids.contains(id) else { continue }
            try? FileManager.default.removeItem(at: bodyDirectory.appendingPathComponent(name))
        }
    }
}

/// The large, rarely changing part of a message.
nonisolated struct StoredMessageBody: Codable, Equatable, Sendable {
    var paragraphs: [String]
    var bodyHTML: String?
    var bodyRTF: Data?
    var verifiedSenderMark: MailVerifiedSenderMark?

    init(_ message: MailMessage) {
        paragraphs = message.paragraphs
        bodyHTML = message.bodyHTML
        bodyRTF = message.bodyRTF
        verifiedSenderMark = message.verifiedSenderMark
    }

    func apply(to message: inout MailMessage) {
        message.paragraphs = paragraphs
        message.bodyHTML = bodyHTML
        message.bodyRTF = bodyRTF
        message.verifiedSenderMark = verifiedSenderMark
    }

    var isEmpty: Bool {
        paragraphs.allSatisfy(\.isEmpty) && bodyHTML == nil && bodyRTF == nil && verifiedSenderMark == nil
    }

    static func strip(_ message: inout MailMessage) {
        message.paragraphs = []
        message.bodyHTML = nil
        message.bodyRTF = nil
        message.verifiedSenderMark = nil
    }
}

/// The bodies each store last wrote, so a save writes only new or changed
/// ones, and which bodies are on disk but not loaded yet. Written bodies share
/// storage with the live messages, so this costs no copies.
private nonisolated final class MailBodyLedger: @unchecked Sendable {
    static let shared = MailBodyLedger()
    private let lock = NSLock()
    private var written: [String: [UUID: StoredMessageBody]] = [:]
    private var pending: [String: Set<UUID>] = [:]

    func state(for directory: URL) -> ([UUID: StoredMessageBody], Set<UUID>) {
        lock.withLock { (written[directory.path] ?? [:], pending[directory.path] ?? []) }
    }

    func reset(pending ids: Set<UUID>, for directory: URL) {
        lock.withLock {
            written[directory.path] = [:]
            pending[directory.path] = ids
        }
    }

    /// Loaded bodies stay pending until a save carries them: a snapshot taken
    /// before they reached the live messages must not write them empty.
    func loaded(_ bodies: [UUID: StoredMessageBody], for directory: URL) {
        lock.withLock { written[directory.path, default: [:]].merge(bodies) { _, new in new } }
    }

    func finishSave(written value: [UUID: StoredMessageBody], pending ids: Set<UUID>, for directory: URL) {
        lock.withLock {
            written[directory.path] = value
            // A save that carried a body clears it; loads never do.
            pending[directory.path] = ids.intersection(pending[directory.path] ?? [])
        }
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
