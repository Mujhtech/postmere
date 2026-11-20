import AppKit
import Observation
import UserNotifications

@MainActor
protocol MailNotificationClient {
    func setDelegate(_ delegate: any UNUserNotificationCenterDelegate)
    func authorizationStatus() async -> UNAuthorizationStatus
    func requestAuthorization() async throws
    func pendingRequests() async -> [UNNotificationRequest]
    func add(_ request: UNNotificationRequest) async throws
    func removePending(_ identifiers: [String])
    func removeDelivered(_ identifiers: [String])
}

@MainActor
private final class SystemMailNotificationClient: MailNotificationClient {
    private let center = UNUserNotificationCenter.current()
    func setDelegate(_ delegate: any UNUserNotificationCenterDelegate) { center.delegate = delegate }
    func authorizationStatus() async -> UNAuthorizationStatus { await center.notificationSettings().authorizationStatus }
    func requestAuthorization() async throws { _ = try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
    func pendingRequests() async -> [UNNotificationRequest] { await center.pendingNotificationRequests() }
    func add(_ request: UNNotificationRequest) async throws { try await center.add(request) }
    func removePending(_ identifiers: [String]) { center.removePendingNotificationRequests(withIdentifiers: identifiers) }
    func removeDelivered(_ identifiers: [String]) { center.removeDeliveredNotifications(withIdentifiers: identifiers) }
}

nonisolated enum MailReminderKind: String, Codable, Sendable { case snooze, followup }

nonisolated struct MailReminderSource: Sendable {
    let kind: MailReminderKind
    let message: MailMessage
    let originalDate: Date
    var identifier: String { "reminder.\(kind.rawValue).\(MailReminderPlanning.conversationKey(message))" }
    var occurrence: String {
        let reference = kind == .followup ? message.workflow.followUpReferenceDate?.timeIntervalSince1970 ?? 0 : 0
        return "\(originalDate.timeIntervalSince1970)|\(reference)"
    }
    var title: String { kind == .snooze ? "Snoozed message" : "Time to follow up" }
}

enum MailReminderPlanning {
    nonisolated static func conversationKey(_ message: MailMessage) -> String {
        let identity = "\(message.account)|\(message.providerAccountEmail?.lowercased() ?? "")"
        return "\(Data(identity.utf8).base64EncodedString()).\(message.conversationID.uuidString)"
    }

    static func isAvailable(_ message: MailMessage) -> Bool {
        isAvailable(message, connected: message.mailAccount.isConnected)
    }

    private nonisolated static func isAvailable(_ message: MailMessage, connected: Bool) -> Bool {
        connected && !message.isDraft && message.providerDeletedAt == nil && !message.mailbox.isJunkOrTrash &&
            message.mailbox != .outbox && message.workflow.screeningState == .accepted
    }

    static func sources(messages: [MailMessage], dueSnoozes: [String: Date] = [:]) -> [MailReminderSource] {
        let accounts = Set(RemoteAccountRegistry.accounts.filter { $0.status == "connected" }.map(\.localID))
        return sources(messages: messages, dueSnoozes: dueSnoozes, accounts: accounts)
    }

    private nonisolated static func sources(messages: [MailMessage], dueSnoozes: [String: Date], accounts: Set<String>) -> [MailReminderSource] {
        var result: [MailReminderSource] = []
        for (key, conversation) in Dictionary(grouping: messages, by: { conversationKey($0) }) {
            let available = conversation.filter { isAvailable($0, connected: accounts.contains($0.account)) }.sorted {
                $0.sentAt == $1.sentAt ? $0.id.uuidString < $1.id.uuidString : $0.sentAt > $1.sentAt
            }
            guard let newest = available.first else { continue }
            if let snoozed = available.first(where: { $0.workflow.snoozedUntil != nil }),
               let date = snoozed.workflow.snoozedUntil {
                result.append(MailReminderSource(kind: .snooze, message: snoozed, originalDate: date))
            } else if let date = dueSnoozes[key], available.contains(where: \.isUnread) {
                result.append(MailReminderSource(kind: .snooze, message: newest, originalDate: date))
            }
            if let followup = available.first(where: { $0.workflow.followUpAt != nil }),
               let date = followup.workflow.followUpAt {
                let reference = followup.workflow.followUpReferenceDate ?? followup.sentAt
                let hasReply = conversation.contains { !$0.isOutgoing && !$0.isDraft && $0.mailbox != .outbox && $0.mailbox != .junk && $0.sentAt > reference }
                if !followup.workflow.followUpOnlyIfNoReply || !hasReply {
                    result.append(MailReminderSource(kind: .followup, message: followup, originalDate: date))
                }
            }
        }
        return result.sorted { $0.identifier < $1.identifier }
    }

    @concurrent static func prepare(messages: [MailMessage], dueSnoozes: [String: Date],
                                    accounts: Set<String>, policy: String, revisionKey: String?) async -> ([MailReminderSource], String) {
        let sources = sources(messages: messages, dueSnoozes: dueSnoozes, accounts: accounts)
        if let revisionKey { return (sources, revisionKey) }
        let occurrences = sources.map { "\($0.identifier)|\($0.occurrence)|\($0.message.id)|\($0.message.subject)" }.joined(separator: "\n")
        let states = messages.map { "\($0.id)|\($0.isUnread)|\($0.mailbox.rawValue)|\($0.workflow.screeningState.rawValue)" }.sorted().joined(separator: ";")
        return (sources, "\(policy)|\(occurrences)|\(states)")
    }
}

private struct ReminderDeliveryRecord: Codable {
    var occurrence: String
    var deliveryDate: Date
    var timingSignature: String
}

private struct IncomingNotificationRecord: Codable {
    var messageID: UUID
    var sentAt: Date
}

@MainActor
@Observable
final class MailNotificationService: NSObject, UNUserNotificationCenterDelegate {
    var profiles: [NotificationProfile] { didSet { savePreferences() } }
    private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined
    private(set) var hasCheckedAuthorization = false
    private(set) var isRequestingAuthorization = false
    private(set) var authorizationError: String?
    private(set) var lastError: String?
    @ObservationIgnored var openMessage: ((UUID) -> Void)?
    @ObservationIgnored var openRemoteMessage: ((MailPushDestination) -> Void)?
    @ObservationIgnored var validateRemoteDestination: ((MailPushDestination) -> Bool)?
    @ObservationIgnored var shouldPresentRemoteDestination: ((MailPushDestination) async -> Bool)?
    @ObservationIgnored var shouldNotifyLocally: ((MailMessage) -> Bool)?
    @ObservationIgnored var shouldDeliverIncoming: ((MailMessage) -> Bool)?
    @ObservationIgnored var onPreferencesChanged: (() -> Void)?
    @ObservationIgnored private let client: any MailNotificationClient
    @ObservationIgnored private let preferences: UserDefaults
    @ObservationIgnored private var scheduledFingerprint = ""
    @ObservationIgnored private var nextReconciliation = Date.distantPast
    @ObservationIgnored private var lastAuthorizationCheck = Date.distantPast
    @ObservationIgnored private var latestAuthorizationRead: UUID?
    @ObservationIgnored private var deliveryRecords: [String: ReminderDeliveryRecord]
    @ObservationIgnored private var dueSnoozes: [String: Date]
    @ObservationIgnored private var incomingRecords: [String: IncomingNotificationRecord]
    @ObservationIgnored private var latestMessages: [MailMessage] = []
    @ObservationIgnored private var latestMessageRevision: Int?
    @ObservationIgnored private var latestDate = Date.now
    @ObservationIgnored private var latestCalendar = Calendar.current
    @ObservationIgnored private var isReconciling = false
    @ObservationIgnored private var needsReconciliation = false

    override convenience init() { self.init(client: SystemMailNotificationClient(), preferences: .standard) }

    init(client: any MailNotificationClient, preferences: UserDefaults) {
        self.client = client
        self.preferences = preferences
        let saved: [NotificationProfile] = Self.load("notificationProfiles.v1", preferences: preferences) ?? []
        profiles = saved
        deliveryRecords = Self.load("reminderDeliveries.v1", preferences: preferences) ?? [:]
        dueSnoozes = Self.load("dueSnoozeNotifications.v1", preferences: preferences) ?? [:]
        incomingRecords = Self.load("incomingNotificationReceipts.v1", preferences: preferences) ?? [:]
        super.init()
        client.setDelegate(self)
    }

    /// Preserve saved schedules for disconnected accounts while exposing a
    /// separate profile for every active server/user/account identity.
    func reconcileAccounts() {
        let existing = Set(profiles.map(\.id))
        let additions = RemoteAccountRegistry.accounts.filter { !existing.contains($0.localID) }
            .map { NotificationProfile(id: $0.localID) }
        if !additions.isEmpty { profiles.append(contentsOf: additions) }
    }

    func refreshAuthorization(now: Date = .now) async {
        let read = UUID()
        latestAuthorizationRead = read
        let status = await client.authorizationStatus()
        guard latestAuthorizationRead == read else { return }
        let changed = !hasCheckedAuthorization || authorizationStatus != status
        hasCheckedAuthorization = true
        authorizationStatus = status
        if isAuthorized { authorizationError = nil }
        lastAuthorizationCheck = now
        if changed {
            scheduledFingerprint = ""
            if isReconciling { needsReconciliation = true }
            onPreferencesChanged?()
        }
    }

    func requestAuthorization() async {
        guard !isRequestingAuthorization else { return }
        isRequestingAuthorization = true
        defer { isRequestingAuthorization = false }
        if !hasCheckedAuthorization { await refreshAuthorization() }
        guard authorizationStatus == .notDetermined || authorizationStatus == .provisional else { return }
        do { try await client.requestAuthorization(); authorizationError = nil }
        catch { authorizationError = error.localizedDescription }
        await refreshAuthorization()
    }

    func reconcileReminders(messages: [MailMessage], revision: Int? = nil, now: Date = .now, calendar: Calendar = .current) async {
        latestMessages = messages
        latestMessageRevision = revision
        latestDate = now
        latestCalendar = calendar
        if isReconciling { needsReconciliation = true; return }
        isReconciling = true
        repeat {
            needsReconciliation = false
            await applyReconciliation()
        } while needsReconciliation
        isReconciling = false
    }

    /// Called before the store clears a naturally expired snooze, once per conversation.
    func notifySnoozeDue(_ message: MailMessage, originalDate: Date, now: Date = .now, calendar: Calendar = .current) async {
        let key = MailReminderPlanning.conversationKey(message)
        dueSnoozes[key] = originalDate
        if !latestMessages.contains(where: { $0.id == message.id }) { latestMessages.append(message) }
        saveDeliveryState()
        scheduledFingerprint = ""
        await reconcileReminders(messages: latestMessages, now: now, calendar: calendar)
    }

    func notifyNewMessage(_ message: MailMessage, now: Date = .now, calendar: Calendar = .current) async {
        reconcileAccounts()
        if now.timeIntervalSince(lastAuthorizationCheck) >= 60 { await refreshAuthorization(now: now) }
        guard isAuthorized, MailReminderPlanning.isAvailable(message),
              shouldNotifyLocally?(message) != false,
              shouldDeliverIncoming?(message) != false,
              message.isUnread, !message.isOutgoing,
              let profile = profiles.first(where: { $0.id == message.account }),
              let delivery = profile.nextPermittedDate(after: now, calendar: calendar) else { return }
        let identifier = "incoming.\(MailReminderPlanning.conversationKey(message))"
        if let prior = incomingRecords[identifier], prior.messageID == message.id || prior.sentAt >= message.sentAt { return }
        let content = notification(for: message, title: message.sender, showPreview: profile.showPreview)
        content.userInfo["deliveryDate"] = delivery.timeIntervalSince1970
        do {
            try await client.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger(delivery: delivery, now: now)))
            guard MailReminderPlanning.isAvailable(message), shouldNotifyLocally?(message) != false,
                  shouldDeliverIncoming?(message) != false else {
                client.removePending([identifier])
                client.removeDelivered([identifier])
                return
            }
            incomingRecords[identifier] = IncomingNotificationRecord(messageID: message.id, sentAt: message.sentAt)
            saveDeliveryState()
            scheduledFingerprint = ""
        } catch { lastError = error.localizedDescription }
    }

    var isAuthorized: Bool { authorizationStatus == .authorized || authorizationStatus == .provisional }

    func notificationPolicyChanged() { scheduledFingerprint = "" }

    private func applyReconciliation() async {
        let now = latestDate
        let calendar = latestCalendar
        if now.timeIntervalSince(lastAuthorizationCheck) >= 60 { await refreshAuthorization(now: now) }
        let messages = latestMessages
        reconcileAccounts()
        let activeAccounts = RemoteAccountRegistry.accounts.filter { $0.status == "connected" }.map(\.localID).sorted()
        let profileFingerprint = profiles.map { "\(timingSignature($0, calendar: calendar, now: now))|\($0.showPreview)" }.joined(separator: "\n")
        let policy = "\(profileFingerprint)|\(activeAccounts.joined(separator: ";"))|\(authorizationStatus.rawValue)"
        let revisionKey = latestMessageRevision.map { "revision=\($0)|\(policy)" }
        if revisionKey == scheduledFingerprint, now < nextReconciliation { return }
        let (sources, fingerprint) = await MailReminderPlanning.prepare(messages: messages, dueSnoozes: dueSnoozes,
            accounts: Set(activeAccounts), policy: policy, revisionKey: revisionKey)
        guard !needsReconciliation else { return }
        guard fingerprint != scheduledFingerprint || now >= nextReconciliation else { return }

        let pending = await client.pendingRequests()
        guard activeAccounts == RemoteAccountRegistry.accounts.filter({ $0.status == "connected" }).map(\.localID).sorted() else {
            needsReconciliation = true
            return
        }
        let pendingByID = Dictionary(pending.map { ($0.identifier, $0) }, uniquingKeysWith: { _, last in last })
        if !isAuthorized {
            client.removePending(pending.map(\.identifier).filter(Self.manages))
            deliveryRecords = deliveryRecords.filter { $0.value.deliveryDate <= now }
            scheduledFingerprint = fingerprint
            nextReconciliation = now.addingTimeInterval(60)
            saveDeliveryState()
            return
        }

        var plans: [(source: MailReminderSource, delivery: Date, profile: NotificationProfile, timing: String)] = []
        for source in sources {
            let prior = deliveryRecords[source.identifier]
            if prior?.occurrence == source.occurrence, let prior, prior.deliveryDate <= now, pendingByID[source.identifier] == nil {
                // A successfully scheduled occurrence has already had its delivery opportunity.
                if source.kind == .snooze { dueSnoozes.removeValue(forKey: MailReminderPlanning.conversationKey(source.message)) }
                continue
            }
            guard let profile = profiles.first(where: { $0.id == source.message.account }),
                  var delivery = profile.nextPermittedDate(after: max(source.originalDate, now.addingTimeInterval(1)), calendar: calendar) else { continue }
            let timing = timingSignature(profile, calendar: calendar, now: now)
            if prior?.occurrence == source.occurrence, let prior, prior.timingSignature == timing, pendingByID[source.identifier] != nil {
                delivery = prior.deliveryDate
            }
            plans.append((source, delivery, profile, timing))
        }
        // Filter and deduplicate before applying the finite system request budget.
        plans.sort { $0.delivery == $1.delivery ? $0.source.identifier < $1.source.identifier : $0.delivery < $1.delivery }
        plans = Array(plans.prefix(48))
        let desiredIDs = Set(plans.map { $0.source.identifier })
        let removed = pending.map(\.identifier).filter { $0.hasPrefix("reminder.") && !desiredIDs.contains($0) }
        client.removePending(removed)
        let sourceIDs = Set(sources.map(\.identifier))
        // A reply, explicit removal, or Trash cancels a follow-up even after it was delivered.
        client.removeDelivered(deliveryRecords.keys.filter { $0.hasPrefix("reminder.followup.") && !sourceIDs.contains($0) })
        for id in removed where deliveryRecords[id].map({ $0.deliveryDate > now }) == true { deliveryRecords.removeValue(forKey: id) }

        var hadError = false
        for plan in plans {
            let source = plan.source
            guard MailReminderPlanning.isAvailable(source.message) else {
                needsReconciliation = true
                return
            }
            let content = notification(for: source.message, title: source.title, showPreview: plan.profile.showPreview)
            let signature = "\(source.occurrence)|\(source.message.id)|\(content.title)|\(content.body)|\(plan.delivery.timeIntervalSince1970)"
            content.userInfo["occurrence"] = source.occurrence
            content.userInfo["deliveryDate"] = plan.delivery.timeIntervalSince1970
            content.userInfo["signature"] = signature
            if pendingByID[source.identifier]?.content.userInfo["signature"] as? String != signature {
                do {
                    try await client.add(UNNotificationRequest(identifier: source.identifier, content: content,
                                                               trigger: trigger(delivery: plan.delivery, now: now)))
                    guard MailReminderPlanning.isAvailable(source.message) else {
                        client.removePending([source.identifier])
                        client.removeDelivered([source.identifier])
                        needsReconciliation = true
                        return
                    }
                } catch { lastError = error.localizedDescription; hadError = true; continue }
            }
            deliveryRecords[source.identifier] = ReminderDeliveryRecord(occurrence: source.occurrence, deliveryDate: plan.delivery, timingSignature: plan.timing)
        }
        let incomingError = await reconcilePendingIncoming(pending, messages: messages, now: now, calendar: calendar)
        hadError = hadError || incomingError
        if !hadError { lastError = nil }
        let activeKeys = Set(sources.filter { $0.kind == .snooze }.map { MailReminderPlanning.conversationKey($0.message) })
        dueSnoozes = dueSnoozes.filter { activeKeys.contains($0.key) }
        scheduledFingerprint = hadError ? "" : fingerprint
        nextReconciliation = plans.map(\.delivery).filter { $0 > now }.min()?.addingTimeInterval(1) ?? now.addingTimeInterval(60)
        saveDeliveryState()
    }

    private func reconcilePendingIncoming(_ pending: [UNNotificationRequest], messages: [MailMessage], now: Date, calendar: Calendar) async -> Bool {
        var hadError = false
        for request in pending where request.identifier.hasPrefix("incoming.") {
            let messageID = (request.content.userInfo["messageID"] as? String).flatMap(UUID.init(uuidString:))
            guard let message = messages.first(where: { $0.id == messageID }), message.isUnread,
                  MailReminderPlanning.isAvailable(message),
                  shouldDeliverIncoming?(message) != false,
                  let profile = profiles.first(where: { $0.id == message.account }),
                  let next = profile.nextPermittedDate(after: now, calendar: calendar) else {
                client.removePending([request.identifier])
                continue
            }
            let previousDate = (request.content.userInfo["deliveryDate"] as? Double).map(Date.init(timeIntervalSince1970:)) ?? next
            let delivery = profile.permits(previousDate, calendar: calendar) ? max(previousDate, next) : next
            let content = notification(for: message, title: message.sender, showPreview: profile.showPreview)
            content.userInfo["deliveryDate"] = delivery.timeIntervalSince1970
            guard content.body != request.content.body || delivery != previousDate else { continue }
            do {
                try await client.add(UNNotificationRequest(identifier: request.identifier, content: content, trigger: trigger(delivery: delivery, now: now)))
                if !MailReminderPlanning.isAvailable(message) || shouldDeliverIncoming?(message) == false {
                    client.removePending([request.identifier])
                    client.removeDelivered([request.identifier])
                    needsReconciliation = true
                }
            }
            catch { lastError = error.localizedDescription; hadError = true }
        }
        return hadError
    }

    private func notification(for message: MailMessage, title: String, showPreview: Bool) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = showPreview ? message.subject : "Open Postmere to view the message."
        content.sound = .default
        content.threadIdentifier = MailReminderPlanning.conversationKey(message)
        content.filterCriteria = message.account
        content.userInfo = ["messageID": message.id.uuidString, "account": message.account]
        return content
    }

    private func trigger(delivery: Date, now: Date) -> UNNotificationTrigger? {
        let delay = delivery.timeIntervalSince(now)
        return delay > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: max(1, delay), repeats: false) : nil
    }

    private func timingSignature(_ profile: NotificationProfile, calendar: Calendar, now: Date) -> String {
        "\(profile.id)|\(profile.enabled)|\(profile.scheduleEnabled)|\(profile.startMinute)|\(profile.endMinute)|\(profile.weekdays.sorted())|\(calendar.timeZone.identifier)|\(calendar.timeZone.secondsFromGMT(for: now))"
    }

    private static func manages(_ identifier: String) -> Bool { identifier.hasPrefix("reminder.") || identifier.hasPrefix("incoming.") }

    private func savePreferences() {
        do { preferences.set(try JSONEncoder().encode(profiles), forKey: "notificationProfiles.v1") }
        catch { lastError = error.localizedDescription }
        scheduledFingerprint = ""
        if isReconciling { needsReconciliation = true }
        onPreferencesChanged?()
    }

    private func saveDeliveryState() {
        do {
            preferences.set(try JSONEncoder().encode(deliveryRecords), forKey: "reminderDeliveries.v1")
            preferences.set(try JSONEncoder().encode(dueSnoozes), forKey: "dueSnoozeNotifications.v1")
            preferences.set(try JSONEncoder().encode(incomingRecords), forKey: "incomingNotificationReceipts.v1")
        } catch { lastError = error.localizedDescription }
    }

    private static func load<Value: Decodable>(_ key: String, preferences: UserDefaults) -> Value? {
        preferences.data(forKey: key).flatMap { try? JSONDecoder().decode(Value.self, from: $0) }
    }

    func presentationOptions(for account: String,
                             focusAllows: (String) async -> Bool = { await PostmereFocusFilter.allowsNotifications(for: $0) }) async -> UNNotificationPresentationOptions {
        guard MailAccount(rawValue: account)?.isConnected == true,
              await focusAllows(account),
              MailAccount(rawValue: account)?.isConnected == true,
              profiles.first(where: { $0.id == account })?.permits(.now) == true else { return [] }
        return [.banner, .sound]
    }

    func remotePresentationOptions(for destination: MailPushDestination,
                                    focusAllows: (String) async -> Bool = { await PostmereFocusFilter.allowsNotifications(for: $0) }) async -> UNNotificationPresentationOptions {
        guard validateRemoteDestination?(destination) == true, await shouldPresentRemoteDestination?(destination) == true else { return [] }
        let options = await presentationOptions(for: destination.filterCriteria, focusAllows: focusAllows)
        guard validateRemoteDestination?(destination) == true, await shouldPresentRemoteDestination?(destination) == true else { return [] }
        return options
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        if let destination = MailPushDestination(userInfo: notification.request.content.userInfo) {
            return await remotePresentationOptions(for: destination)
        }
        // A malformed remote payload must not fall through as a local alert.
        guard notification.request.content.userInfo["postmere_push"] == nil else { return [] }
        guard let account = notification.request.content.filterCriteria else { return [] }
        return await presentationOptions(for: account)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                           didReceive response: UNNotificationResponse) async {
        if let destination = MailPushDestination(userInfo: response.notification.request.content.userInfo) {
            guard response.actionIdentifier != UNNotificationDismissActionIdentifier else { return }
            await MainActor.run {
                NSApp.activate(ignoringOtherApps: true)
                self.openRemoteMessage?(destination)
            }
            return
        }
        guard response.notification.request.content.userInfo["postmere_push"] == nil else { return }
        guard response.actionIdentifier != UNNotificationDismissActionIdentifier,
              let identifier = response.notification.request.content.userInfo["messageID"] as? String,
              let id = UUID(uuidString: identifier) else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            self.openMessage?(id)
        }
    }
}
