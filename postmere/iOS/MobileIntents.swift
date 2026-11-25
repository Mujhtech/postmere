import AppIntents
import Foundation

// Siri, Spotlight and the Shortcuts app. Each opens Postmere where it should be,
// except the summary, which answers from the widgets' snapshot without opening it.

struct OpenInboxIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Inbox"
    static let description = IntentDescription("Shows your Postmere inbox.")
    static let supportedModes: IntentModes = .foreground

    @MainActor func perform() async throws -> some IntentResult {
        MobileRouter.shared.pending = .inbox
        return .result()
    }
}

struct ShowNeedsReplyIntent: AppIntent {
    static let title: LocalizedStringResource = "Show Needs Reply"
    static let description = IntentDescription("Shows the conversations waiting for your reply.")
    static let supportedModes: IntentModes = .foreground

    @MainActor func perform() async throws -> some IntentResult {
        MobileRouter.shared.pending = .needsReply
        return .result()
    }
}

struct NewMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "New Email"
    static let description = IntentDescription("Starts a new message in Postmere.")
    static let supportedModes: IntentModes = .foreground

    @MainActor func perform() async throws -> some IntentResult {
        MobileRouter.shared.pending = .compose
        return .result()
    }
}

struct StartTriageIntent: AppIntent {
    static let title: LocalizedStringResource = "Triage Inbox"
    static let description = IntentDescription("Goes through your unread mail one conversation at a time.")
    static let supportedModes: IntentModes = .foreground

    @MainActor func perform() async throws -> some IntentResult {
        MobileRouter.shared.pending = .triage
        return .result()
    }
}

struct AskMailIntent: AppIntent {
    static let title: LocalizedStringResource = "Ask Your Mail"
    static let description = IntentDescription("Asks a question about your mail and shows the answer with its sources.")
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Question", requestValueDialog: "What do you want to know?")
    var question: String?

    @MainActor func perform() async throws -> some IntentResult {
        if let question = question?.trimmingCharacters(in: .whitespacesAndNewlines), !question.isEmpty,
           let runtime = MobileAppDelegate.current?.runtime {
            runtime.pendingAIQuestion = question
        }
        MobileRouter.shared.pending = .ask
        return .result()
    }
}

/// "How's my inbox?": unread and waiting counts, read from what the widgets last saw.
struct MailSummaryIntent: AppIntent {
    static let title: LocalizedStringResource = "Mail Summary"
    static let description = IntentDescription("Tells you how much unread mail you have and how much is waiting for a reply.")

    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<Int> {
        guard let snapshot = MailWidgetSnapshot.load(), snapshot.isSignedIn else {
            return .result(value: 0, dialog: "Open Postmere and sign in first.")
        }
        let unread = snapshot.unread == 1 ? "1 unread conversation" : "\(snapshot.unread) unread conversations"
        let waiting = snapshot.needsReply == 0 ? "nothing waiting for a reply"
            : snapshot.needsReply == 1 ? "1 waiting for your reply" : "\(snapshot.needsReply) waiting for your reply"
        return .result(value: snapshot.unread, dialog: "You have \(unread) and \(waiting).")
    }
}

struct PostmereShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: MailSummaryIntent(), phrases: [
            "How's my \(.applicationName) inbox",
            "Check \(.applicationName)",
            "What's new in \(.applicationName)",
        ], shortTitle: "Mail Summary", systemImageName: "tray.full")
        AppShortcut(intent: AskMailIntent(), phrases: [
            "Ask \(.applicationName)",
            "Ask my mail in \(.applicationName)",
        ], shortTitle: "Ask Your Mail", systemImageName: "sparkles")
        AppShortcut(intent: ShowNeedsReplyIntent(), phrases: [
            "What needs a reply in \(.applicationName)",
            "Show needs reply in \(.applicationName)",
        ], shortTitle: "Needs Reply", systemImageName: "arrowshape.turn.up.left")
        AppShortcut(intent: StartTriageIntent(), phrases: [
            "Triage my inbox in \(.applicationName)",
            "Start triage in \(.applicationName)",
        ], shortTitle: "Triage", systemImageName: "rectangle.stack")
        AppShortcut(intent: NewMessageIntent(), phrases: [
            "New email in \(.applicationName)",
            "Write an email in \(.applicationName)",
        ], shortTitle: "New Email", systemImageName: "square.and.pencil")
        AppShortcut(intent: OpenInboxIntent(), phrases: [
            "Open my \(.applicationName) inbox",
        ], shortTitle: "Inbox", systemImageName: "tray")
    }
}
