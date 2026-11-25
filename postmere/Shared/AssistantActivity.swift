#if os(iOS)
import ActivityKit
import Foundation

/// A connected assistant working in the user's mail, on the Lock Screen and in
/// the Dynamic Island. The server starts, updates and ends it over APNs; the
/// field names match its push payload exactly (see postmere-push/src/live.rs).
nonisolated struct AssistantActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        /// The MCP tool it used last, e.g. "read_message".
        var tool: String
        /// The last few tools, newest first.
        var recent: [String]
        /// Tool calls since this activity started.
        var calls: Int
        /// Unix seconds; plain numbers so the server's JSON decodes as-is.
        var startedAt: Double
        var lastAt: Double
        var working: Bool

        var startDate: Date { Date(timeIntervalSince1970: startedAt) }
        var lastDate: Date { Date(timeIntervalSince1970: lastAt) }
    }

    /// The MCP grant, so the app can report this activity's push token.
    let grantID: String
    let clientName: String
}

/// MCP tools as something a person did. Shared by the app and the Live Activity.
nonisolated enum AssistantToolWording {
    static func summary(_ tool: String) -> String {
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
        case "list_approvals": "Checked approvals"
        case "working": "Working"
        default: tool.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }

    /// Present tense for what it's doing right now.
    static func doing(_ tool: String) -> String {
        switch tool {
        case "list_accounts": "Looking at accounts"
        case "list_messages": "Searching mail"
        case "read_message": "Reading a message"
        case "list_drafts", "get_draft": "Looking at drafts"
        case "create_draft": "Writing a draft"
        case "update_draft": "Editing a draft"
        case "delete_draft": "Deleting a draft"
        case "manage_message": "Organizing mail"
        case "list_outbox": "Checking the outbox"
        case "cancel_outbox": "Cancelling a send"
        case "request_send": "Asking to send"
        case "request_trash": "Asking to trash"
        case "request_disconnect": "Asking to disconnect"
        case "list_approvals": "Checking approvals"
        default: "Working in your mail"
        }
    }

    static func symbol(_ tool: String) -> String {
        switch tool {
        case "list_messages": "magnifyingglass"
        case "read_message": "envelope.open.fill"
        case "list_drafts", "get_draft": "doc.text"
        case "create_draft", "update_draft": "square.and.pencil"
        case "delete_draft", "request_trash": "trash"
        case "manage_message": "tray.full.fill"
        case "list_outbox", "cancel_outbox": "tray.and.arrow.up.fill"
        case "request_send": "paperplane.fill"
        case "list_accounts", "request_disconnect": "person.crop.circle"
        case "list_approvals": "checkmark.shield"
        default: "sparkles"
        }
    }
}
#endif
