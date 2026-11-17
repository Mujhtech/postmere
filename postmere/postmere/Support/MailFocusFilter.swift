import AppIntents
import Foundation

enum MailFocusProfile: String, AppEnum {
    case all, work, personal, gmail, none

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Mail accounts"
    static var caseDisplayRepresentations: [MailFocusProfile: DisplayRepresentation] = [
        .all: "All accounts", .work: "Work", .personal: "Personal", .gmail: "Gmail", .none: "No accounts"
    ]

    var accountName: String? {
        switch self {
        case .work: "Work"
        case .personal: "Personal"
        case .gmail: "Gmail"
        default: nil
        }
    }

    func allows(account: String) -> Bool {
        self == .all || accountName == account
    }

    var notificationPredicate: NSPredicate {
        if let account = accountName { return NSPredicate(format: "SELF == %@", account) }
        return NSPredicate(value: self == .all)
    }
}

struct PostmereFocusFilter: SetFocusFilterIntent {
    static var title: LocalizedStringResource = "Mail notifications"
    static var description = IntentDescription("Choose which Postmere accounts may notify you during this Focus.")

    @Parameter(title: "Allow notifications from", default: .all)
    var profile: MailFocusProfile

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "Mail notifications", subtitle: "\(profile.accountName ?? (profile == .none ? "No accounts" : "All accounts"))")
    }

    var appContext: FocusFilterAppContext {
        FocusFilterAppContext(notificationFilterPredicate: profile.notificationPredicate)
    }

    func perform() async throws -> some IntentResult {
        // The system applies appContext at delivery time, including while Postmere is closed.
        // Persisting the last filter here would leave stale restrictions after Focus ends.
        return .result()
    }

    static func allowsNotifications(for account: String) async -> Bool {
        do {
            return try await current.profile.allows(account: account)
        } catch {
            // No active filter is normal; the system still enforces its Focus settings.
            return true
        }
    }
}
