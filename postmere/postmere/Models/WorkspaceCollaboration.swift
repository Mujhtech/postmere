import Foundation

nonisolated struct WorkspaceMember: Decodable, Identifiable, Sendable {
    let userId: UUID
    let email: String
    let role: String
    var id: UUID { userId }
}
nonisolated struct WorkspaceMembers: Decodable, Sendable { let members: [WorkspaceMember] }
nonisolated struct SharedThreads: Decodable, Sendable { let threads: [SharedThread] }
nonisolated struct SharedThread: Decodable, Identifiable, Sendable {
    let id: UUID
    let ownerId: UUID
    let ownerEmail: String
    let subject: String
    let createdAt: Date
    let updatedAt: Date
    let permission: String
    let messageCount: Int
    let version: Int
}
nonisolated struct SharedThreadMember: Codable, Identifiable, Sendable {
    let userId: UUID
    let email: String
    let permission: String
    var id: UUID { userId }
}
nonisolated struct SharedMemberInput: Encodable, Sendable { let userId: UUID; let permission: String }
nonisolated struct ShareThreadInput: Encodable, Sendable { let accountId: UUID; let providerThreadId: String; let members: [SharedMemberInput] }
nonisolated struct SharedMembersUpdate: Encodable, Sendable { let members: [SharedMemberInput]; let expectedVersion: Int }
nonisolated struct SharedThreadDetail: Decodable, Sendable {
    let thread: SharedThread
    let messages: [BackendMailMessage]
    let members: [SharedThreadMember]
    let comments: [SharedComment]
    let commentsNextBefore: UUID?
    let presence: [SharedPresence]
}
nonisolated struct SharedComment: Decodable, Identifiable, Sendable {
    let id: UUID
    let authorId: UUID
    let authorEmail: String
    let body: String
    let createdAt: Date
}
nonisolated struct SharedCommentPage: Decodable, Sendable { let comments: [SharedComment]; let nextBefore: UUID? }
nonisolated struct SharedPresence: Decodable, Sendable { let userId: UUID; let email: String; let expiresAt: Date }
nonisolated struct SharedPresenceInput: Encodable, Sendable { let active: Bool }
nonisolated struct SharedVersionInput: Encodable, Sendable { let expectedVersion: Int }
nonisolated struct SharedCommentInput: Encodable, Sendable { let body: String }
nonisolated struct WorkspaceMemberInput: Encodable, Sendable { let email: String; let initialPassword: String; let role: String }

nonisolated struct SharedSnippetSummary: Decodable, Identifiable, Sendable {
    let id: UUID
    let ownerId: UUID
    let ownerEmail: String
    let version: Int
    let createdAt: Date
    let updatedAt: Date
    let title: String
    let kind: String
}
nonisolated struct SharedSnippetList: Decodable, Sendable { let snippets: [SharedSnippetSummary] }
nonisolated struct SharedSnippetDetail: Decodable, Sendable {
    let id: UUID
    let ownerId: UUID
    let ownerEmail: String
    let version: Int
    let createdAt: Date
    let updatedAt: Date
    let template: SharedTemplate
}
nonisolated struct SharedTemplate: Codable, Sendable {
    let title: String
    let body: String
    let kind: String
    let bodyRtfBase64: String?
    let to: String?
    let cc: String?
    let bcc: String?
    let subject: String?
    let attachments: [SharedTemplateAttachment]
}
nonisolated struct SharedTemplateAttachment: Codable, Sendable {
    let filename: String
    let mimeType: String
    let dataBase64: String
}
nonisolated struct SharedTemplateInput: Encodable, Sendable { let template: SharedTemplate }
nonisolated struct SharedTemplateUpdate: Encodable, Sendable { let template: SharedTemplate; let expectedVersion: Int }
