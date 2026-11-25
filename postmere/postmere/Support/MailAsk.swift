import SwiftUI

/// Text that arrives in network bursts but is revealed at a steady pace,
/// catching up quickly when a backlog builds.
@MainActor @Observable
final class PacedText {
    private(set) var shown = ""
    private(set) var isRevealing = false
    private var pending = ""
    private var task: Task<Void, Never>?

    func append(_ text: String) {
        pending += text
        guard task == nil else { return }
        isRevealing = true
        task = Task { [weak self] in
            while let self, !Task.isCancelled, !self.pending.isEmpty {
                let next = self.pending.prefix(max(2, self.pending.count / 10))
                self.shown += next
                self.pending.removeFirst(next.count)
                try? await Task.sleep(for: .milliseconds(16))
            }
            self?.task = nil
            self?.isRevealing = false
        }
    }

    /// Reconciles with the final text, continuing the reveal where it is.
    func finish(with text: String) {
        let received = shown + pending
        if text.hasPrefix(received) {
            append(String(text.dropFirst(received.count)))
        } else {
            reset()
            append(text)
        }
    }

    /// Stops revealing and drops text that has not been shown yet.
    func halt() {
        task?.cancel()
        task = nil
        pending = ""
        isRevealing = false
    }

    func reset() {
        task?.cancel()
        task = nil
        shown = ""
        pending = ""
        isRevealing = false
    }
}

/// One question and its streamed answer.
@MainActor @Observable
final class MailAskTurn: Identifiable {
    enum Phase: Equatable {
        case searching, answering, done
        case failed(String, canRetry: Bool)
    }

    let id = UUID()
    let question: String
    let accountIDs: [UUID]
    let answer = PacedText()
    private(set) var phase: Phase = .searching
    private(set) var sources: [MailAISource] = []
    private(set) var result: MailAIResult?

    init(question: String, accountIDs: [UUID]) {
        self.question = question
        self.accountIDs = accountIDs
    }

    /// Cited sources first, then anything else the answer drew on.
    var orderedSources: [MailAISource] {
        let cited = Set(result?.items.flatMap(\.sourceIds) ?? [])
        return sources.filter { cited.contains($0.id) } + sources.filter { !cited.contains($0.id) }
    }

    /// Ends a turn the user stopped: a partial answer stays as it is.
    func stop() {
        guard phase == .searching || phase == .answering || answer.isRevealing else { return }
        answer.halt()
        withAnimation(.smooth) {
            phase = answer.shown.isEmpty ? .failed("Stopped.", canRetry: true) : .done
        }
    }

    func run(session: BackendSession) async {
        phase = .searching
        answer.reset()
        sources = []
        result = nil
        do {
            let result = try await session.ask(question: question, accountIDs: accountIDs, onSources: { found in
                withAnimation(.spring(duration: 0.5, bounce: 0.2)) {
                    self.sources = found
                    self.phase = .answering
                }
            }, onDelta: { chunk in
                if self.phase == .searching { withAnimation(.smooth) { self.phase = .answering } }
                self.answer.append(chunk)
            })
            try Task.checkCancellation()
            answer.finish(with: result.text)
            withAnimation(.smooth(duration: 0.4)) {
                if sources.isEmpty { sources = result.sources }
                self.result = result
                phase = .done
            }
        } catch {
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) {
                phase = .failed(error.localizedDescription, canRetry: (error as? BackendAIError)?.canRetry ?? true)
            }
        }
    }
}

/// Display name and address parsed from a source's "Name <email>" sender.
extension MailAISource {
    var senderAddress: String { MailSenderDomain.email(in: sender) ?? "" }
    var senderName: String {
        let name = sender.split(separator: "<").first.map { $0.trimmingCharacters(in: .whitespaces.union(.init(charactersIn: "\""))) } ?? ""
        return name.isEmpty ? (senderAddress.isEmpty ? "Unknown sender" : senderAddress) : name
    }
}
