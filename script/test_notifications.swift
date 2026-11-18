import Foundation
import UserNotifications

private struct NotificationCheckFailure: Error, CustomStringConvertible {
    let description: String
}

@MainActor
private func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw NotificationCheckFailure(description: message) }
}

@MainActor
private final class FakeNotificationClient: MailNotificationClient {
    var status: UNAuthorizationStatus = .authorized
    var pending: [String: UNNotificationRequest] = [:]
    var delivered: [String: UNNotificationRequest] = [:]
    var added: [String] = []
    var removedDelivered: [String] = []
    var failAdds = false
    var authorizationRequests = 0
    var beforePendingRead: (() async -> Void)?
    var duringAdd: (() async -> Void)?
    func setDelegate(_ delegate: any UNUserNotificationCenterDelegate) {}
    func authorizationStatus() async -> UNAuthorizationStatus { status }
    func requestAuthorization() async throws { authorizationRequests += 1 }
    func pendingRequests() async -> [UNNotificationRequest] {
        if let action = beforePendingRead { beforePendingRead = nil; await action() }
        return Array(pending.values)
    }
    func add(_ request: UNNotificationRequest) async throws {
        if failAdds { throw NotificationCheckFailure(description: "Synthetic scheduling failure") }
        if let action = duringAdd { duringAdd = nil; await action() }
        added.append(request.identifier)
        if request.trigger == nil { delivered[request.identifier] = request }
        else { pending[request.identifier] = request }
    }
    func removePending(_ identifiers: [String]) { for id in identifiers { pending.removeValue(forKey: id) } }
    func removeDelivered(_ identifiers: [String]) {
        removedDelivered += identifiers
        for id in identifiers { delivered.removeValue(forKey: id) }
    }
    func advance(to date: Date) {
        for (id, request) in pending {
            if let timestamp = request.content.userInfo["deliveryDate"] as? Double, timestamp <= date.timeIntervalSince1970 {
                delivered[id] = request
                pending.removeValue(forKey: id)
            }
        }
    }
}

@main
private struct NotificationChecks {
    @MainActor
    static func main() async throws {
        RemoteAccountRegistry.accounts = ["work", "personal", "third"].map {
            RemoteAccountIdentity(localID: "remote:fixture:\($0)", accountID: UUID(), scope: "fixture", email: "\($0)@example.com", displayName: $0, provider: "gmail")
        }
        defer { RemoteAccountRegistry.accounts = [] }
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        try schedules(calendar: utc)
        try focusAndPlanning()
        try await reconciliation(calendar: utc)
        try await overdueAndQuietHours(calendar: utc)
        try await budgetAndRetry(calendar: utc)
        try await manyAccountProfiles(calendar: utc)
        try await accountChangesDuringScheduling(calendar: utc)
        try await foregroundPresentation()
        try await remoteOwnership(calendar: utc)
        try await incomingPolicyChanges(calendar: utc)
        print("PASS: notification checks use a fake center; no prompts, alerts, or network")
    }

    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    @MainActor
    static func remoteOwnership(calendar: Calendar) async throws {
        let now = date("2026-11-16T12:00:00Z")
        try await withService { service, client, _ in
            service.shouldNotifyLocally = { _ in false }
            let incoming = message(sentAt: now)
            await service.notifyNewMessage(incoming, now: now, calendar: calendar)
            try expect(client.added.isEmpty, "Confirmed APNs ownership must suppress duplicate local incoming alerts")
            var reminder = incoming
            reminder.workflow.snoozedUntil = now.addingTimeInterval(60)
            await service.reconcileReminders(messages: [reminder], now: now, calendar: calendar)
            try expect(client.pending.count == 1, "APNs ownership must not suppress local reminders")
        }
        try await withService { service, client, _ in
            var remoteOwns = false
            service.shouldNotifyLocally = { _ in !remoteOwns }
            client.duringAdd = { remoteOwns = true }
            await service.notifyNewMessage(message(sentAt: now), now: now, calendar: calendar)
            try expect(client.pending.isEmpty && client.delivered.isEmpty, "Ownership change during insertion must remove a duplicate local alert")
            remoteOwns = false
            await service.notifyNewMessage(message(sentAt: now.addingTimeInterval(1)), now: now, calendar: calendar)
            try expect(client.delivered.count == 1, "Unavailable remote delivery must retain local notification fallback")
        }
        try await withService { service, _, _ in
            var valid = true
            var remoteOwns = true
            let account = RemoteAccountRegistry.accounts[0]
            let destination = MailPushDestination(userInfo: ["postmere_push":1,"server_origin":"https://postmere.example.test",
                "workspace_id":UUID().uuidString,"user_id":UUID().uuidString,"account_id":account.accountID.uuidString,
                "message_id":UUID().uuidString,"filter_criteria":account.localID])!
            service.validateRemoteDestination = { _ in valid }
            service.shouldPresentRemoteDestination = { _ in remoteOwns }
            let visible = await service.remotePresentationOptions(for: destination, focusAllows: { _ in true })
            try expect(visible == [.banner, .sound], "Valid APNs foreground alerts must use the existing presentation policy")
            let focused = await service.remotePresentationOptions(for: destination, focusAllows: { _ in false })
            try expect(focused.isEmpty, "APNs foreground delivery must respect Focus")
            let stale = await service.remotePresentationOptions(for: destination, focusAllows: { _ in valid = false; return true })
            try expect(stale.isEmpty, "Identity changes during APNs Focus lookup must suppress presentation")
            valid = true
            remoteOwns = false
            let noOwner = await service.remotePresentationOptions(for: destination, focusAllows: { _ in true })
            try expect(noOwner.isEmpty, "Unconfirmed remote ownership must not duplicate local foreground alerts")
        }
        print("PASS: APNs/local incoming ownership, insertion races, retained reminders and scoped foreground Focus checks")
    }

    @MainActor
    static func foregroundPresentation() async throws {
        let accounts = RemoteAccountRegistry.accounts
        defer { RemoteAccountRegistry.accounts = accounts }
        try await withService { service, _, _ in
            let account = "remote:fixture:work"
            let connected = await service.presentationOptions(for: account, focusAllows: { _ in true })
            try expect(connected == [.banner, .sound], "Connected enabled account can present a banner")
            let filtered = await service.presentationOptions(for: account, focusAllows: { _ in false })
            try expect(filtered.isEmpty, "Focus still suppresses an active account")
            let stale = await service.presentationOptions(for: account, focusAllows: { _ in
                RemoteAccountRegistry.accounts = []
                return true
            })
            try expect(stale.isEmpty, "Logout during Focus lookup suppresses a retained notification")
            var lookedUpFocus = false
            let disconnected = await service.presentationOptions(for: account, focusAllows: { _ in
                lookedUpFocus = true
                return true
            })
            try expect(disconnected.isEmpty && !lookedUpFocus, "Saved profiles cannot present disconnected-account notifications")
            RemoteAccountRegistry.accounts = accounts
            RemoteAccountRegistry.accounts[0].status = "reconnect_required"
            let revoked = await service.presentationOptions(for: account, focusAllows: { _ in true })
            try expect(revoked.isEmpty, "Revoked accounts cannot present old notifications")
        }
        print("PASS: foreground presentation rechecks connected accounts after Focus and logout")
    }

    @MainActor
    static func incomingPolicyChanges(calendar: Calendar) async throws {
        let now = date("2026-11-16T12:00:00Z")
        try await withService { service, client, _ in
            var allowed = true
            service.shouldDeliverIncoming = { _ in allowed }
            service.profiles[0].scheduleEnabled = true
            service.profiles[0].startMinute = 22 * 60
            service.profiles[0].endMinute = 23 * 60
            service.profiles[0].weekdays = Set(1...7)
            let incoming = message(sentAt: now)
            await service.notifyNewMessage(incoming, now: now, calendar: calendar)
            await service.reconcileReminders(messages: [incoming], now: now, calendar: calendar)
            try expect(client.pending.count == 1, "Allowed sender did not retain its quiet-hour incoming alert")
            allowed = false
            service.notificationPolicyChanged()
            await service.reconcileReminders(messages: [incoming], now: now, calendar: calendar)
            try expect(client.pending.isEmpty, "Blocking a sender did not cancel an already queued quiet-hour alert")
        }
        try await withService { service, client, _ in
            var allowed = true
            service.shouldDeliverIncoming = { _ in allowed }
            client.duringAdd = { allowed = false }
            await service.notifyNewMessage(message(sentAt: now), now: now, calendar: calendar)
            try expect(client.pending.isEmpty && client.delivered.isEmpty, "Sender-policy change during insertion left a stale incoming alert")
        }
        try await withService { service, _, _ in
            let account = RemoteAccountRegistry.accounts[0]
            let destination = MailPushDestination(userInfo: ["postmere_push":1,"server_origin":"https://postmere.example.test",
                "workspace_id":UUID().uuidString,"user_id":UUID().uuidString,"account_id":account.accountID.uuidString,
                "message_id":UUID().uuidString,"filter_criteria":account.localID])!
            var allowed = true
            service.validateRemoteDestination = { _ in true }
            service.shouldPresentRemoteDestination = { _ in await Task.yield(); return allowed }
            let suppressed = await service.remotePresentationOptions(for: destination, focusAllows: { _ in allowed = false; return true })
            try expect(suppressed.isEmpty, "Policy changes during foreground Focus lookup were not rechecked")
        }
        print("PASS: sender-policy changes cancel queued incoming alerts and recheck insertion/foreground races")
    }

    @MainActor
    static func accountChangesDuringScheduling(calendar: Calendar) async throws {
        let accounts = RemoteAccountRegistry.accounts
        defer { RemoteAccountRegistry.accounts = accounts }
        let now = date("2026-11-16T12:00:00Z")
        let reminder = message(sentAt: now.addingTimeInterval(-10), snooze: now.addingTimeInterval(60))
        try await withService { service, client, _ in
            client.beforePendingRead = { RemoteAccountRegistry.accounts = [] }
            await service.reconcileReminders(messages: [reminder], now: now, calendar: calendar)
            try expect(client.added.isEmpty, "Logout during pending-request lookup cannot schedule old-account reminders")
        }
        RemoteAccountRegistry.accounts = accounts
        try await withService { service, client, _ in
            client.duringAdd = { RemoteAccountRegistry.accounts = [] }
            await service.reconcileReminders(messages: [reminder], now: now, calendar: calendar)
            try expect(client.pending.isEmpty && client.delivered.isEmpty, "Disconnect during reminder insertion removes the stale request")
        }
        RemoteAccountRegistry.accounts = accounts
        try await withService { service, client, _ in
            client.duringAdd = { RemoteAccountRegistry.accounts = [] }
            await service.notifyNewMessage(message(sentAt: now.addingTimeInterval(-10)), now: now, calendar: calendar)
            try expect(client.pending.isEmpty && client.delivered.isEmpty, "Logout during incoming notification insertion removes the stale request")
        }
        print("PASS: account changes during notification lookups and insertion fail closed")
    }

    @MainActor
    static func manyAccountProfiles(calendar: Calendar) async throws {
        let oldAccounts = RemoteAccountRegistry.accounts
        defer { RemoteAccountRegistry.accounts = oldAccounts }
        let many = (0..<32).map { index in
            RemoteAccountIdentity(localID: "remote:many:user:account-\(index)", accountID: UUID(), scope: "many:user",
                                  email: "account\(index)@example.com", displayName: "Account \(index)", provider: index.isMultiple(of: 2) ? "gmail" : "microsoft")
        }
        RemoteAccountRegistry.accounts = many
        try await withService { service, client, defaults in
            service.reconcileAccounts()
            try expect(Set(service.profiles.map(\.id)).isSuperset(of: Set(many.map(\.localID))), "Every connected account gets an independent notification profile")
            let target = many[31]
            let index = service.profiles.firstIndex { $0.id == target.localID }!
            service.profiles[index].enabled = true
            let now = date("2026-11-16T12:00:00Z")
            let incoming = message(account: target.localID, sentAt: now.addingTimeInterval(-10))
            await service.notifyNewMessage(incoming, now: now, calendar: calendar)
            try expect(client.delivered.values.contains { $0.content.filterCriteria == target.localID }, "Accounts beyond the first ten can notify with their own Focus identity")
            let restored = MailNotificationService(client: client, preferences: defaults)
            try expect(restored.profiles.first { $0.id == target.localID }?.enabled == true, "Dynamic account notification preferences survive relaunch")
            var snoozed = incoming
            snoozed.workflow.snoozedUntil = now.addingTimeInterval(100)
            await service.reconcileReminders(messages: [snoozed], now: now, calendar: calendar)
            try expect(!client.pending.isEmpty, "Connected account reminder is scheduled")
            RemoteAccountRegistry.accounts = []
            await service.reconcileReminders(messages: [snoozed], now: now.addingTimeInterval(1), calendar: calendar)
            try expect(client.pending.isEmpty, "Signing out removes pending notifications for disconnected accounts")
        }
        print("PASS: 32 scoped notification profiles, persistence, Focus identities, and logout cancellation")
    }

    @MainActor
    static func schedules(calendar: Calendar) throws {
        var p = NotificationProfile(id: "remote:fixture:work", enabled: true, scheduleEnabled: true, weekdays: [2])
        let monday = date("2026-11-16T09:00:00Z")
        try expect(p.permits(monday, calendar: calendar), "Schedule must include its start")
        try expect(!p.permits(date("2026-11-16T18:00:00Z"), calendar: calendar), "End must be exclusive")
        try expect(p.nextPermittedDate(after: date("2026-11-16T08:59:00Z"), calendar: calendar) == monday, "Opening time must be returned")
        try expect(p.nextPermittedDate(after: date("2026-11-16T18:00:00Z"), calendar: calendar) == date("2026-11-23T09:00:00Z"), "Inactive weekdays must be skipped")
        p.weekdays = []
        try expect(p.nextPermittedDate(after: monday, calendar: calendar) == nil, "No selected days must suppress scheduling")
        p.weekdays = [0, 8]
        try expect(p.nextPermittedDate(after: monday, calendar: calendar) == nil, "Invalid weekdays must not produce dates")
        p.weekdays = [2]; p.endMinute = p.startMinute
        try expect(p.nextPermittedDate(after: date("2026-11-15T12:00:00Z"), calendar: calendar) == date("2026-11-16T00:00:00Z"), "All-day schedule must open at midnight")
        try expect(p.permits(date("2026-11-16T23:59:59Z"), calendar: calendar), "All-day must include the whole selected day")
        p.startMinute = 22 * 60; p.endMinute = 6 * 60; p.weekdays = [6]
        try expect(p.permits(date("2026-11-20T22:00:00Z"), calendar: calendar), "Overnight Friday must start Friday")
        try expect(p.permits(date("2026-11-21T05:59:59Z"), calendar: calendar), "Overnight tail belongs to starting weekday")
        try expect(!p.permits(date("2026-11-21T06:00:00Z"), calendar: calendar), "Overnight end must be excluded")
        try expect(!p.permits(date("2026-11-21T22:00:00Z"), calendar: calendar), "Friday must not restart Saturday")
        var ny = calendar; ny.timeZone = TimeZone(identifier: "America/New_York")!
        p.weekdays = [1]; p.startMinute = 150; p.endMinute = 240
        try expect(p.nextPermittedDate(after: date("2026-03-08T01:50:00-05:00"), calendar: ny) == date("2026-03-08T03:00:00-04:00"), "Spring gap must use next existing permitted time")
        p.startMinute = 90; p.endMinute = 150
        try expect(p.nextPermittedDate(after: date("2026-11-01T01:15:00-04:00"), calendar: ny) == date("2026-11-01T01:30:00-04:00"), "First repeated opening must be selectable")
        try expect(p.nextPermittedDate(after: date("2026-11-01T01:15:00-05:00"), calendar: ny) == date("2026-11-01T01:30:00-05:00"), "Second repeated opening must not be skipped")
        p.startMinute = -20; p.endMinute = 60; p.weekdays = Set(1...7)
        try expect(p.permits(date("2026-11-16T00:30:00Z"), calendar: calendar), "Invalid minute values must normalize safely")
        print("PASS: daytime/overnight boundaries, weekdays, all-day/no-days, and DST")
    }

    @MainActor
    static func message(conversation: UUID = UUID(), account: String = "remote:fixture:work", sentAt: Date,
                        snooze: Date? = nil, followup: Date? = nil, reference: Date? = nil) -> MailMessage {
        MailMessage(sender: "Sender", senderEmail: "sender@example.com", initials: "S", subject: "Review",
                    preview: "Preview", paragraphs: ["Body"], timeLabel: "", isUnread: true, account: account,
                    isOutgoing: false, conversationID: conversation, sentAt: sentAt,
                    workflow: MailWorkflowState(snoozedUntil: snooze, followUpAt: followup, followUpReferenceDate: reference))
    }

    @MainActor
    static func focusAndPlanning() throws {
        let available: Set<String> = ["remote:fixture:work", "remote:fixture:personal", "remote:fixture:third"]
        let selected: Set<String> = ["remote:fixture:work", "remote:disconnected:account"]
        for p in [MailFocusProfile.all, .selected, .none] {
            for account in available.union(["remote:disconnected:account", "Work"]) {
                try expect(p.notificationPredicate(selectedAccountIDs: selected, availableAccountIDs: available).evaluate(with: account)
                           == p.allows(account: account, selectedAccountIDs: selected, availableAccountIDs: available),
                           "Focus predicate and foreground policy must agree for every scoped account")
            }
        }
        try expect(!MailFocusProfile.selected.allows(account: "remote:disconnected:account", selectedAccountIDs: selected, availableAccountIDs: available),
                   "Focus selected accounts fail closed after disconnection")
        let now = date("2026-11-16T12:00:00Z"), conversation = UUID()
        let original = message(conversation: conversation, sentAt: now.addingTimeInterval(-600), snooze: now.addingTimeInterval(600), followup: now.addingTimeInterval(900), reference: now)
        var duplicate = original; duplicate.id = UUID(); duplicate.sentAt = now.addingTimeInterval(-500)
        let personal = message(conversation: conversation, account: "remote:fixture:personal", sentAt: now.addingTimeInterval(-600), followup: now.addingTimeInterval(900), reference: now)
        let sources = MailReminderPlanning.sources(messages: [original, duplicate, personal])
        try expect(sources.count == 3 && Set(sources.map(\.identifier)).count == 3, "Dedupe must isolate account, conversation, and kind")
        let reply = message(conversation: conversation, sentAt: now.addingTimeInterval(1))
        try expect(MailReminderPlanning.sources(messages: [original, duplicate, reply]).allSatisfy { $0.kind != .followup }, "Reply must cancel conditional follow-up")
        duplicate.workflow.followUpOnlyIfNoReply = false
        try expect(MailReminderPlanning.sources(messages: [duplicate, reply]).contains { $0.kind == .followup }, "Unconditional follow-up must remain")
        var deleted = original; deleted.providerDeletedAt = now
        try expect(MailReminderPlanning.sources(messages: [deleted]).isEmpty, "Deleted provider messages must not notify")
        var legacy = original; legacy.account = "Gmail"; legacy.providerAccountEmail = "old@example.com"
        try expect(MailReminderPlanning.sources(messages: [legacy]).isEmpty, "Legacy direct account must not notify")
        print("PASS: Focus policy, reminder identity, reply conditions, and account/deletion boundaries")
    }

    @MainActor
    static func withService(_ body: (MailNotificationService, FakeNotificationClient, UserDefaults) async throws -> Void) async throws {
        let suite = "PostmereNotificationChecks.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let client = FakeNotificationClient()
        let service = MailNotificationService(client: client, preferences: defaults)
        service.profiles = [NotificationProfile(id: "remote:fixture:work", enabled: true), NotificationProfile(id: "remote:fixture:personal"), NotificationProfile(id: "remote:fixture:third")]
        try await body(service, client, defaults)
        try expect(client.authorizationRequests == 0, "Reconciliation must not request permission")
    }

    @MainActor
    static func reconciliation(calendar: Calendar) async throws {
        try await withService { service, client, _ in
            let now = date("2026-11-16T12:00:00Z")
            let original = message(sentAt: now.addingTimeInterval(-100), snooze: now.addingTimeInterval(100), followup: now.addingTimeInterval(200), reference: now)
            var duplicate = original; duplicate.id = UUID()
            await service.reconcileReminders(messages: [original, duplicate], now: now, calendar: calendar)
            try expect(client.pending.count == 2, "Thread must create one request per reminder kind")
            let count = client.added.count
            await service.reconcileReminders(messages: [original, duplicate], now: now.addingTimeInterval(1), calendar: calendar)
            try expect(client.added.count == count, "Unchanged reminders must not be replaced")
            service.profiles[0].showPreview = false
            await service.reconcileReminders(messages: [original, duplicate], now: now.addingTimeInterval(2), calendar: calendar)
            try expect(client.pending.values.allSatisfy { $0.content.body == "Open Postmere to view the message." }, "Pending previews must update")
            try expect(client.pending.values.allSatisfy { $0.content.filterCriteria == "remote:fixture:work" }, "All requests need Focus criteria")
            let reply = message(conversation: original.conversationID, sentAt: now.addingTimeInterval(3))
            await service.reconcileReminders(messages: [original, duplicate, reply], now: now.addingTimeInterval(4), calendar: calendar)
            try expect(client.pending.count == 1 && client.pending.keys.first!.hasPrefix("reminder.snooze."), "Reply must remove pending follow-up")
            try expect(client.removedDelivered.contains { $0.hasPrefix("reminder.followup.") }, "Obsolete delivered follow-up must be removed")
            client.status = .denied
            await service.refreshAuthorization(now: now.addingTimeInterval(5))
            await service.reconcileReminders(messages: [original], now: now.addingTimeInterval(5), calendar: calendar)
            try expect(client.pending.isEmpty, "Denied permission must clear pending alerts")
        }
        print("PASS: idempotence, previews, Focus metadata, conditional removal, and denied permission")
    }

    @MainActor
    static func overdueAndQuietHours(calendar: Calendar) async throws {
        try await withService { service, client, defaults in
            let now = date("2026-11-16T12:00:00Z")
            let overdue = message(sentAt: now.addingTimeInterval(-3_600), followup: now.addingTimeInterval(-100), reference: now.addingTimeInterval(-1_800))
            await service.reconcileReminders(messages: [overdue], now: now, calendar: calendar)
            try expect(client.pending.count == 1, "Overdue reminder must get a catch-up")
            client.advance(to: now.addingTimeInterval(2))
            let count = client.added.count
            await service.reconcileReminders(messages: [overdue], now: now.addingTimeInterval(3), calendar: calendar)
            let relaunched = MailNotificationService(client: client, preferences: defaults)
            await relaunched.reconcileReminders(messages: [overdue], now: now.addingTimeInterval(4), calendar: calendar)
            try expect(client.added.count == count, "Delivered catch-up must not repeat across relaunch")
        }
        try await withService { service, client, defaults in
            let now = date("2026-11-16T20:00:00Z")
            service.profiles[0].scheduleEnabled = true
            let original = message(sentAt: now.addingTimeInterval(-600), snooze: now)
            await service.reconcileReminders(messages: [original], now: now, calendar: calendar)
            await service.notifySnoozeDue(original, originalDate: now, now: now, calendar: calendar)
            var awakened = original; awakened.workflow.snoozedUntil = nil
            await service.reconcileReminders(messages: [awakened], now: now.addingTimeInterval(1), calendar: calendar)
            try expect(client.pending.count == 1, "Natural wake must retain quiet-hours delayed alert")
            let delivery = client.pending.values.first!.content.userInfo["deliveryDate"] as! Double
            try expect(Date(timeIntervalSince1970: delivery) == date("2026-11-17T09:00:00Z"), "Snooze alert must wait for working hours")
            let relaunched = MailNotificationService(client: client, preferences: defaults)
            await relaunched.reconcileReminders(messages: [awakened], now: now.addingTimeInterval(2), calendar: calendar)
            try expect(client.pending.count == 1, "Deferred snooze must survive relaunch")
            awakened.isUnread = false
            await relaunched.reconcileReminders(messages: [awakened], now: now.addingTimeInterval(3), calendar: calendar)
            try expect(client.pending.isEmpty, "Reading awakened mail must cancel deferred alert")
        }
        try await withService { service, client, _ in
            let now = date("2026-11-16T20:00:00Z")
            service.profiles[0].scheduleEnabled = true
            let newest = message(sentAt: now)
            await service.notifyNewMessage(newest, now: now, calendar: calendar)
            var older = newest; older.id = UUID(); older.sentAt = now.addingTimeInterval(-1)
            await service.notifyNewMessage(older, now: now, calendar: calendar)
            try expect(client.pending.count == 1 && client.added.count == 1, "Sync batch must keep only newest notification per thread")
            service.profiles[0].enabled = false
            await service.reconcileReminders(messages: [newest, older], now: now.addingTimeInterval(1), calendar: calendar)
            try expect(client.pending.isEmpty, "Disabling profile must remove queued incoming alerts")
        }
        print("PASS: overdue catch-up once, durable quiet-hour snoozes, read cancellation, and incoming batching")
    }

    @MainActor
    static func budgetAndRetry(calendar: Calendar) async throws {
        try await withService { service, client, _ in
            let now = date("2026-11-16T12:00:00Z")
            let disabled = (1...60).map { message(account: "remote:fixture:personal", sentAt: now, followup: now.addingTimeInterval(Double($0)), reference: now) }
            let enabled = (1...3).map { message(sentAt: now, followup: now.addingTimeInterval(Double($0 + 100)), reference: now) }
            await service.reconcileReminders(messages: disabled + enabled, now: now, calendar: calendar)
            try expect(client.pending.count == 3, "Disabled profiles must not use pending budget")
        }
        try await withService { service, client, _ in
            let now = date("2026-11-16T12:00:00Z")
            let messages = (1...60).map { message(sentAt: now, followup: now.addingTimeInterval(Double($0 * 10)), reference: now) }
            await service.reconcileReminders(messages: messages, now: now, calendar: calendar)
            try expect(client.pending.count == 48, "Nearest reminders must respect request budget")
            client.advance(to: now.addingTimeInterval(100))
            await service.reconcileReminders(messages: messages, now: now.addingTimeInterval(101), calendar: calendar)
            try expect(client.pending.count == 48 && client.added.count == 58, "Freed slots must refill without repeat delivery")
        }
        try await withService { service, client, _ in
            let now = date("2026-11-16T12:00:00Z")
            let reminder = message(sentAt: now, followup: now.addingTimeInterval(60), reference: now)
            client.failAdds = true
            await service.reconcileReminders(messages: [reminder], now: now, calendar: calendar)
            try expect(service.lastError != nil && client.pending.isEmpty, "Failures must be visible and retryable")
            client.failAdds = false
            await service.reconcileReminders(messages: [reminder], now: now.addingTimeInterval(1), calendar: calendar)
            try expect(client.pending.count == 1 && service.lastError == nil, "Successful retry must clear failure")
        }
        print("PASS: filtered request budget, replenishment, and scheduling retry")
    }
}
