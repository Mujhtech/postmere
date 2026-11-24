import Foundation
import Observation

/// One AI summary of a conversation, streamed from the workspace. Shared by the Mac and the phone.
@MainActor @Observable
final class MailConversationSummary {
    let id = UUID()
    let messageID: UUID
    let sessionID: UUID?
    let sourceIDs: [UUID]
    private(set) var text = ""
    private(set) var requestID = UUID()
    private(set) var phase: Phase = .loading
    private var enablingStyleGuide: String?

    enum Phase {
        case loading
        case consent(MailAISettings)
        case failed(String, canRetry: Bool = true)
        case ready(MailAIResult)
    }

    init(messageID: UUID, sessionID: UUID?, sourceIDs: [UUID]) {
        self.messageID = messageID
        self.sessionID = sessionID
        self.sourceIDs = sourceIDs
    }

    func start(enablingWith styleGuide: String? = nil) {
        text = ""
        phase = .loading
        enablingStyleGuide = styleGuide
        requestID = UUID()
    }

    func load(session: BackendSession) async {
        let current = requestID
        guard !Task.isCancelled, case .loading = phase else { return }
        guard let generation = session.realtimeGeneration, session.scope != nil else {
            phase = .failed("Connect your workspace in Settings → Accounts to summarize this conversation.")
            return
        }
        guard generation == sessionID else { return }
        guard !sourceIDs.isEmpty else {
            phase = .failed("This conversation needs to sync before it can be summarized.")
            return
        }
        do {
            let settings: MailAISettings
            if let style = enablingStyleGuide {
                settings = try await session.request("PUT", "/v1/ai/settings",
                                                     body: MailAISettingsInput(enabled: true, styleGuide: style))
            } else {
                settings = try await session.request("GET", "/v1/ai/settings")
            }
            try Task.checkCancellation()
            guard session.realtimeGeneration == generation, requestID == current else { return }
            guard settings.available else {
                phase = .failed("Your workspace administrator needs to configure an AI provider.")
                return
            }
            guard settings.enabled else {
                phase = .consent(settings)
                return
            }
            let result = try await session.summarize(messageIDs: sourceIDs) { chunk in
                guard self.requestID == current else { throw CancellationError() }
                self.text.append(chunk)
            }
            try Task.checkCancellation()
            guard session.realtimeGeneration == generation, requestID == current else { return }
            let hasContent = !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || result.items.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            phase = hasContent ? .ready(result) : .failed("No summary was returned for this conversation.")
        } catch {
            guard !Task.isCancelled, session.realtimeGeneration == generation, requestID == current else { return }
            text = ""
            phase = .failed(error.localizedDescription, canRetry: (error as? BackendAIError)?.canRetry ?? true)
        }
    }
}

extension MailConversationSummary {
    /// The synced messages to summarize: up to 30, newest first, always including the open one.
    static func sourceIDs(for message: MailMessage, in conversation: [MailMessage], session: BackendSession) -> [UUID] {
        guard let scope = session.scope, message.mailAccount.remote?.scope == scope,
              let selectedID = message.backendMessageID else { return [] }
        var sourceIDs: [UUID] = []
        var seen: Set<UUID> = []
        for entry in conversation.reversed() {
            guard entry.mailAccount.remote?.scope == scope,
                  let id = entry.backendMessageID, seen.insert(id).inserted else { continue }
            sourceIDs.append(id)
            if sourceIDs.count == 30 { break }
        }
        if !seen.contains(selectedID) {
            if sourceIDs.count == 30 { sourceIDs.removeLast() }
            sourceIDs.append(selectedID)
        }
        return sourceIDs.reversed()
    }
}
