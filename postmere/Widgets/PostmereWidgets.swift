import SwiftUI
import WidgetKit

@main
struct PostmereWidgets: WidgetBundle {
    var body: some Widget {
        InboxWidget()
        NeedsReplyWidget()
        QuickActionsWidget()
        ComposeControl()
        AskControl()
        TriageControl()
        MailSendLiveActivity()
        AssistantLiveActivity()
    }
}

// MARK: - Timeline

struct MailEntry: TimelineEntry {
    let date: Date
    let snapshot: MailWidgetSnapshot
    let relevance: TimelineEntryRelevance?
}

/// Reads the snapshot the app wrote. The app reloads widgets when mail changes;
/// a periodic refresh keeps relative times honest in between.
struct MailProvider: TimelineProvider {
    func placeholder(in context: Context) -> MailEntry {
        MailEntry(date: .now, snapshot: .sample, relevance: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (MailEntry) -> Void) {
        let snapshot = context.isPreview ? .sample : (MailWidgetSnapshot.load() ?? .sample)
        completion(MailEntry(date: .now, snapshot: snapshot, relevance: nil))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<MailEntry>) -> Void) {
        let snapshot = MailWidgetSnapshot.load() ?? .signedOut
        // Unread mail and anything waiting on a reply make the widget worth surfacing in a Smart Stack.
        let score = Float(min(snapshot.unread, 20) + snapshot.needsReply * 3)
        let entry = MailEntry(date: .now, snapshot: snapshot,
                              relevance: score > 0 ? TimelineEntryRelevance(score: score, duration: 60 * 60) : nil)
        completion(Timeline(entries: [entry], policy: .after(.now.addingTimeInterval(30 * 60))))
    }
}

