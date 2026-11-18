import AppIntents
import Foundation

nonisolated enum MailFocusProfile: String, AppEnum {
    case all, selected, none

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mail accounts"
    static let caseDisplayRepresentations: [MailFocusProfile: DisplayRepresentation] = [
        .all: "All accounts", .selected: "Selected accounts", .none: "No accounts"
    ]

    func allows(account: String, selectedAccountIDs: Set<String>, availableAccountIDs: Set<String>) -> Bool {
        switch self {
        case .all: true
        case .selected: selectedAccountIDs.contains(account) && availableAccountIDs.contains(account)
        case .none: false
        }
    }

    func notificationPredicate(selectedAccountIDs: Set<String>, availableAccountIDs: Set<String>) -> NSPredicate {
        switch self {
        case .all: NSPredicate(value: true)
        case .selected: NSPredicate(format: "SELF IN %@", Array(selectedAccountIDs.intersection(availableAccountIDs)))
        case .none: NSPredicate(value: false)
        }
    }
}

/// Only non-secret, active account metadata is exposed to system Focus settings.
/// The account ID includes server, workspace, user, and provider account identity.
nonisolated struct MailFocusAccount: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Mail account"
    static let defaultQuery = MailFocusAccountQuery()
    let id: String
    let email: String
    let displayName: String
    let provider: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(email)", subtitle: "\(provider == "gmail" ? "Google" : "Microsoft Outlook")")
    }
}

nonisolated enum MailFocusAccountCatalog {
    static let preferenceKey = "postmereFocusAccountCatalog.v1"

    private struct Record: Decodable {
        let localID: String
        let email: String
        let displayName: String
        let provider: String
        let status: String
    }

    static func accounts(preferences: UserDefaults = .standard) -> [MailFocusAccount] {
        guard let data = preferences.data(forKey: preferenceKey),
              let records = try? JSONDecoder().decode([Record].self, from: data) else { return [] }
        var seen: Set<String> = []
        return records.compactMap { record in
            guard record.localID.hasPrefix("remote:"), record.status == "connected",
                  ["gmail", "microsoft"].contains(record.provider),
                  !record.email.isEmpty, seen.insert(record.localID).inserted else { return nil }
            return MailFocusAccount(id: record.localID, email: record.email,
                                    displayName: record.displayName, provider: record.provider)
        }
    }
}

nonisolated struct MailFocusAccountQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [MailFocusAccount] {
        let accounts = Dictionary(uniqueKeysWithValues: MailFocusAccountCatalog.accounts().map { ($0.id, $0) })
        var seen: Set<String> = []
        return identifiers.compactMap { seen.insert($0).inserted ? accounts[$0] : nil }
    }

    func suggestedEntities() async throws -> [MailFocusAccount] {
        MailFocusAccountCatalog.accounts()
    }

    func entities(matching string: String) async throws -> [MailFocusAccount] {
        let query = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return MailFocusAccountCatalog.accounts().filter {
            query.isEmpty || $0.email.localizedCaseInsensitiveContains(query)
                || $0.displayName.localizedCaseInsensitiveContains(query)
        }
    }
}

struct PostmereFocusFilter: SetFocusFilterIntent {
    static let title: LocalizedStringResource = "Mail notifications"
    static let description = IntentDescription("Choose which workspace email accounts may notify you during this Focus.")

    @Parameter(title: "Allow notifications from", default: .all)
    var profile: MailFocusProfile

    @Parameter(title: "Selected accounts")
    var accounts: [MailFocusAccount]?

    static var parameterSummary: some ParameterSummary {
        Switch(\.$profile) {
            Case(.selected) {
                Summary("Notify from \(\.$profile)") { \.$accounts }
            }
            DefaultCase { Summary("Notify from \(\.$profile)") }
        }
    }

    private var selectedAccountIDs: Set<String> { Set((accounts ?? []).map(\.id)) }
    private var availableAccountIDs: Set<String> { Set(MailFocusAccountCatalog.accounts().map(\.id)) }

    var displayRepresentation: DisplayRepresentation {
        let label: String
        switch profile {
        case .all: label = "All accounts"
        case .none: label = "No accounts"
        case .selected:
            let count = selectedAccountIDs.intersection(availableAccountIDs).count
            label = count == 1 ? "1 selected account" : "\(count) selected accounts"
        }
        return DisplayRepresentation(title: "Mail notifications", subtitle: "\(label)")
    }

    var appContext: FocusFilterAppContext {
        FocusFilterAppContext(notificationFilterPredicate: profile.notificationPredicate(
            selectedAccountIDs: selectedAccountIDs, availableAccountIDs: availableAccountIDs))
    }

    func perform() async throws -> some IntentResult {
        // The system applies this predicate while the app is closed. Account
        // changes invalidate the context; no stale filter is saved by this intent.
        .result()
    }

    static func allowsNotifications(for account: String) async -> Bool {
        do {
            let filter = try await current
            return filter.profile.allows(account: account, selectedAccountIDs: filter.selectedAccountIDs,
                                         availableAccountIDs: filter.availableAccountIDs)
        } catch SetFocusFilterIntentError.notFound {
            return true
        } catch {
            // An unresolved or removed selected account must not become "all".
            return false
        }
    }
}
