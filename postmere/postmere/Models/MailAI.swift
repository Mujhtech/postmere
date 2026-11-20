import Foundation

nonisolated struct MailAISettings: Codable, Sendable {
    var enabled: Bool
    let available: Bool
    let decisionAvailable: Bool?
    let provider: String
    let model: String
    var styleGuide: String
    let dataNotice: String
}
nonisolated struct MailAISettingsInput: Encodable, Sendable { let enabled: Bool; let styleGuide: String }
nonisolated struct MailAIResult: Decodable, Sendable {
    let text: String
    let items: [MailAIItem]
    let sources: [MailAISource]
    let scope: String
    let generatedAt: Date
    let model: String
}
nonisolated struct MailAIItem: Decodable, Sendable {
    let kind: String
    let text: String
    let sourceIds: [UUID]
    let action: String?
    let messageId: UUID?
    let dueAt: Date?
}
nonisolated struct MailAISource: Decodable, Sendable, Identifiable {
    let id: UUID
    let accountId: UUID
    let subject: String
    let sender: String
    let sentAt: Date
}
nonisolated struct MailAISourceInput: Encodable, Sendable { let messageIds: [UUID] }
nonisolated struct MailAIDraftInput: Encodable, Sendable {
    let messageIds: [UUID]
    let draftText: String
    let instruction: String
    let notes: String
}
nonisolated struct MailAIAskInput: Encodable, Sendable { let question: String; let accountIds: [UUID] }

enum MailAIMode: String, Identifiable {
    case draft, suggestions, ask
    var id: Self { self }
    var title: String {
        switch self {
        case .draft: "Writing assistant"
        case .suggestions: "Suggested next steps"
        case .ask: "Ask your mail"
        }
    }
}
