import Foundation
import Security

nonisolated enum MailPushEnvironment: String, Sendable {
    case sandbox, production

    /// Build settings and user defaults do not prove which APNs environment
    /// signed this running binary. Read its actual code-signing entitlement.
    static func signedEnvironment() -> Self? {
        var code: SecCode?
        guard SecCodeCopySelf(SecCSFlags(), &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, SecCSFlags(), &staticCode) == errSecSuccess, let staticCode else { return nil }
        var information: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let information = information as? [String: Any],
              let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              let value = entitlements["com.apple.developer.aps-environment"] as? String else { return nil }
        switch value {
        case "development": return .sandbox
        case "production": return .production
        default: return nil
        }
    }
}

nonisolated struct MailPushAccountPreference: Encodable, Sendable, Equatable {
    let accountId: UUID
    var enabled: Bool
    let scheduleEnabled: Bool
    let startMinute: Int
    let endMinute: Int
    let weekdays: [Int]
    let timeZone: String
    let showSubject: Bool
    let filterCriteria: String
    var senderPolicy: MailPushSenderPolicy?
}

nonisolated struct MailPushSenderRule: Encodable, Sendable, Equatable {
    let email: String
    let route: String
}

nonisolated struct MailPushSenderPolicy: Encodable, Sendable, Equatable {
    let version = 1
    let screenUnknownSenders: Bool
    let rules: [MailPushSenderRule]

    var needsFiltering: Bool {
        screenUnknownSenders || rules.contains { $0.route == "blocked" || $0.route == "archive" }
    }

    func permits(senderEmail: String) -> Bool {
        if let rule = rules.first(where: { $0.email.caseInsensitiveCompare(senderEmail) == .orderedSame }) {
            return rule.route == "inbox" || rule.route == "needsReply"
        }
        return !screenUnknownSenders
    }

    @MainActor static func account(_ account: RemoteAccountIdentity, screening: Bool, rules: [SenderRule]) -> Self {
        Self(screenUnknownSenders: screening, rules: rules.filter {
            ($0.account == nil || $0.account == account.localID)
                && ($0.providerAccountEmail == nil || $0.providerAccountEmail?.caseInsensitiveCompare(account.email) == .orderedSame)
        }.map { MailPushSenderRule(email: $0.email.lowercased(), route: $0.route.rawValue) })
    }
}

nonisolated struct MailPushPreferences: Encodable, Sendable, Equatable {
    let enabled: Bool
    let accounts: [MailPushAccountPreference]

    @MainActor static func workspace(accounts: [RemoteAccountIdentity], profiles: [NotificationProfile], authorized: Bool,
                                     senderScreeningEnabled: Bool, senderRules: [SenderRule], timeZone: TimeZone = .current) -> Self {
        let values = accounts.map { account in
            let profile = profiles.first { $0.id == account.localID } ?? NotificationProfile(id: account.localID)
            return MailPushAccountPreference(accountId: account.accountID,
                enabled: authorized && profile.enabled && account.status == "connected",
                scheduleEnabled: profile.scheduleEnabled, startMinute: min(1439, max(0, profile.startMinute)),
                endMinute: min(1439, max(0, profile.endMinute)), weekdays: profile.weekdays.intersection(1...7).sorted(),
                timeZone: timeZone.identifier, showSubject: profile.showPreview, filterCriteria: account.localID,
                senderPolicy: .account(account, screening: senderScreeningEnabled, rules: senderRules))
        }.sorted { $0.accountId.uuidString < $1.accountId.uuidString }
        return Self(enabled: authorized, accounts: values)
    }

    /// Older servers cannot apply sender rules. Keep their previous local-only
    /// behavior until they advertise the policy protocol, without truncating or
    /// weakening the requested policy on a capable server.
    func compatible(with senderPolicyVersion: Int?) -> Self {
        guard senderPolicyVersion == 1 else {
            return Self(enabled: enabled, accounts: accounts.map {
                var value = $0
                value.enabled = value.enabled && value.senderPolicy?.needsFiltering != true
                value.senderPolicy = nil
                return value
            })
        }
        return self
    }
}

nonisolated struct MailPushRegistration: Encodable, Sendable {
    let token: String
    let environment: String
    let enabled: Bool
    let accounts: [MailPushAccountPreference]
}

nonisolated struct MailPushDeviceState: Decodable, Sendable {
    let configured: Bool
    let enabled: Bool
    let environment: String?
    let deviceId: UUID
    let accountIds: [UUID]
    var active: Bool? = nil
    var senderPolicyVersion: Int? = nil
}

nonisolated struct MailPushDestination: Sendable, Equatable {
    let serverOrigin: URL
    let workspaceID: UUID
    let userID: UUID
    let accountID: UUID
    let messageID: UUID
    let filterCriteria: String

    init?(userInfo: [AnyHashable: Any]) {
        guard userInfo["postmere_push"] as? Int == 1,
              let origin = userInfo["server_origin"] as? String,
              let serverOrigin = try? BackendHTTPClient.validatedBaseURL(origin),
              let workspace = userInfo["workspace_id"] as? String, let workspaceID = UUID(uuidString: workspace),
              let user = userInfo["user_id"] as? String, let userID = UUID(uuidString: user),
              let account = userInfo["account_id"] as? String, let accountID = UUID(uuidString: account),
              let message = userInfo["message_id"] as? String, let messageID = UUID(uuidString: message),
              let filterCriteria = userInfo["filter_criteria"] as? String, filterCriteria.utf8.count <= 512 else { return nil }
        self.serverOrigin = serverOrigin
        self.workspaceID = workspaceID
        self.userID = userID
        self.accountID = accountID
        self.messageID = messageID
        self.filterCriteria = filterCriteria
    }

    func matches(_ credential: BackendCredential, account: RemoteAccountIdentity) -> Bool {
        guard let expected = try? BackendHTTPClient.validatedBaseURL(credential.baseURL) else { return false }
        return serverOrigin.scheme?.lowercased() == expected.scheme?.lowercased()
            && serverOrigin.host?.lowercased() == expected.host?.lowercased()
            && (serverOrigin.port ?? (serverOrigin.scheme == "https" ? 443 : 80)) == (expected.port ?? (expected.scheme == "https" ? 443 : 80))
            && workspaceID == credential.workspaceID && userID == credential.userID
            && accountID == account.accountID && filterCriteria == account.localID
    }
}

