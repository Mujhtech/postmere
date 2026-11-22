import SwiftUI

/// One pass through a set of conversations: a fixed queue, where the user is,
/// and what they decided, so a decision can be undone and summarized.
@MainActor @Observable
final class TriageSession {
    enum Decision: String, CaseIterable {
        case archive, unsubscribe, trash, snooze, reply, needsReply, skip

        var title: String {
            switch self {
            case .archive: "Archived"
            case .unsubscribe: "Unsubscribed"
            case .trash: "Trashed"
            case .snooze: "Snoozed"
            case .reply: "Replied"
            case .needsReply: "Needs reply"
            case .skip: "Skipped"
            }
        }
    }

    /// Bulk mail offered as one decision before the queue.
    enum BatchState { case none, pending, archived }

    let title: String
    private(set) var ids: [UUID]
    private(set) var batch: [UUID]
    private(set) var batchState: BatchState
    private(set) var index = 0
    private(set) var decisions: [(id: UUID, decision: Decision)] = []
    /// How the current card leaves; read by the transition as it departs.
    private(set) var exit: Decision = .skip
    /// Undo brings the previous card back from the side it left.
    private(set) var isReturning = false

    init(title: String, ids: [UUID], batch: [UUID] = []) {
        self.title = title
        let grouped = Set(batch)
        self.ids = ids.filter { !grouped.contains($0) }
        self.batch = batch
        batchState = batch.isEmpty ? .none : .pending
    }

    var showsBatch: Bool { batchState == .pending }
    var currentID: UUID? { !showsBatch && ids.indices.contains(index) ? ids[index] : nil }
    var isFinished: Bool { !showsBatch && index >= ids.count }
    /// Cards in this pass: the batch counts as one.
    var total: Int { ids.count + (batchState == .none ? 0 : 1) }
    var position: Int { batchState == .archived ? index + 1 : index }
    /// Conversations covered, including an archived batch.
    var conversationCount: Int { ids.count + (batchState == .archived ? batch.count : 0) }
    var progress: Double { total == 0 ? 1 : Double(min(position, total)) / Double(total) }

    /// Archives the whole batch as one decision.
    func archiveBatch() {
        guard showsBatch else { return }
        decisions.append(contentsOf: batch.map { ($0, Decision.archive) })
        exit = .archive
        isReturning = false
        withAnimation(.spring(duration: 0.42, bounce: 0.12)) { batchState = .archived }
    }

    /// Puts the batch back into the queue, ahead of everything else.
    func reviewBatch() {
        guard showsBatch else { return }
        exit = .skip
        withAnimation(.spring(duration: 0.42, bounce: 0.12)) {
            ids = batch + ids
            batchState = .none
        }
    }

    /// Brings an archived batch back when it was the last decision.
    func undoBatch() -> [UUID]? {
        guard batchState == .archived, index == 0, decisions.count == batch.count else { return nil }
        decisions.removeAll()
        isReturning = true
        withAnimation(.spring(duration: 0.42, bounce: 0.15)) { batchState = .pending }
        return batch
    }

    func count(of decision: Decision) -> Int { decisions.count { $0.decision == decision } }

    /// Records the decision, then advances on the next frame so the departing
    /// card is drawn with this decision's exit before it leaves.
    func decide(_ decision: Decision) {
        guard let id = currentID else { return }
        decisions.append((id, decision))
        exit = decision
        isReturning = false
        DispatchQueue.main.async {
            withAnimation(.spring(duration: 0.42, bounce: 0.12)) { self.index += 1 }
        }
    }

    func undo() -> (id: UUID, decision: Decision)? {
        guard let last = decisions.popLast() else { return nil }
        exit = last.decision
        isReturning = true
        withAnimation(.spring(duration: 0.42, bounce: 0.15)) { index = max(0, index - 1) }
        return last
    }
}
