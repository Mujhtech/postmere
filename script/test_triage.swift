import Foundation

@main
struct TriageChecks {
    @MainActor static func main() async {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()
        func settle() async { try? await Task.sleep(for: .milliseconds(20)) }

        // A batch is one card before the queue; archiving it counts every message.
        let session = TriageSession(title: "Inbox", ids: [a, b, c, d, e], batch: [c, d, e])
        precondition(session.showsBatch && session.currentID == nil && session.total == 3 && session.position == 0)
        session.archiveBatch()
        precondition(!session.showsBatch && session.currentID == a && session.position == 1 && session.count(of: .archive) == 3)
        precondition(session.conversationCount == 5)
        // Undo brings the batch back while it was the last decision.
        precondition(session.undoBatch() == [c, d, e] && session.showsBatch && session.decisions.isEmpty)
        session.archiveBatch()
        session.decide(.reply)
        await settle()
        precondition(session.currentID == b && session.undoBatch() == nil, "Undo after later decisions undoes those first")
        precondition(session.undo()?.id == a)
        session.decide(.skip); await settle()
        session.decide(.skip); await settle()
        precondition(session.isFinished && session.progress == 1)

        // One by one puts the batch first in the queue.
        let review = TriageSession(title: "Inbox", ids: [a, b, c, d], batch: [c, d])
        review.reviewBatch()
        precondition(!review.showsBatch && review.ids == [c, d, a, b] && review.currentID == c && review.total == 4)

        // No batch: the plain queue.
        let plain = TriageSession(title: "Inbox", ids: [a, b])
        precondition(!plain.showsBatch && plain.currentID == a && plain.total == 2)
        print("Triage session checks passed")
    }
}
