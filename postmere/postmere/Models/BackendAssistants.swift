import Foundation

/// An MCP assistant connected to the workspace, and what it did recently.
nonisolated struct AssistantConnection: Decodable, Identifiable, Equatable, Sendable {
    let id: UUID
    let clientName: String
    let scopes: [String]
    let createdAt: Date
    var lastUsedAt: Date?
    var recent: [AssistantActivity] = []

    private enum CodingKeys: String, CodingKey { case id, clientName, scopes, createdAt, lastUsedAt, recent }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        clientName = try values.decode(String.self, forKey: .clientName)
        scopes = try values.decodeIfPresent([String].self, forKey: .scopes) ?? []
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        lastUsedAt = try values.decodeIfPresent(Date.self, forKey: .lastUsedAt)
        recent = try values.decodeIfPresent([AssistantActivity].self, forKey: .recent) ?? []
    }

    /// Used a tool within the last two minutes.
    func isWorking(at now: Date = .now) -> Bool {
        lastUsedAt.map { now.timeIntervalSince($0) < 120 } ?? false
    }
}

nonisolated struct AssistantActivity: Decodable, Equatable, Sendable {
    let tool: String
    let at: Date

    /// The tool, as something a person did.
    var summary: String {
        switch tool {
        case "list_accounts": "Looked at accounts"
        case "list_messages": "Searched mail"
        case "read_message": "Read a message"
        case "list_drafts": "Listed drafts"
        case "get_draft": "Opened a draft"
        case "create_draft": "Wrote a draft"
        case "update_draft": "Edited a draft"
        case "delete_draft": "Deleted a draft"
        case "manage_message": "Organized mail"
        case "list_outbox": "Checked the outbox"
        case "cancel_outbox": "Cancelled a send"
        case "request_send": "Asked to send"
        case "request_trash": "Asked to trash"
        case "request_disconnect": "Asked to disconnect"
        default: tool.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

nonisolated struct AssistantAccessInput: Encodable, Sendable { let visible: Bool }
