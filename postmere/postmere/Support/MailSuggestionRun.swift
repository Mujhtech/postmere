import SwiftUI

/// One streamed review of a conversation: the assistant's overview arrives
/// first, then each validated suggestion, then the result validated as a whole.
///
/// Network chunks arrive in bursts. Received text and items are buffered and
/// revealed at a steady pace (catching up quickly when a backlog builds), so
/// the overview types fluidly and suggestions land one after another.
@MainActor @Observable
final class MailSuggestionRun {
    enum Phase: Equatable {
        case loading, consent, streaming, ready
        case failed(String, canRetry: Bool)
    }

    let sourceIDs: [UUID]
    private(set) var phase: Phase = .loading
    private(set) var settings: MailAISettings?
    /// Displayed text and items; the rest is still being revealed.
    private(set) var overview = ""
    private(set) var items: [MailAIItem] = []
    private(set) var result: MailAIResult?
    private(set) var requestID = UUID()
    private(set) var isRevealing = false
    private var pendingText = ""
    private var pendingItems: [MailAIItem] = []
    private var receivedItems = 0
    private var reveal: Task<Void, Never>?
    private var enablingStyleGuide: String?

    init(sourceIDs: [UUID]) { self.sourceIDs = sourceIDs }

    /// The caret shows while text is still arriving or being revealed.
    var isTyping: Bool { phase == .streaming && items.isEmpty && pendingItems.isEmpty || !pendingText.isEmpty }

    /// Restarts the run; the view's task observes `requestID`.
    func start(enabling: Bool = false) {
        reveal?.cancel()
        reveal = nil
        isRevealing = false
        enablingStyleGuide = enabling ? (settings?.styleGuide ?? "") : nil
        overview = ""
        pendingText = ""
        items = []
        pendingItems = []
        receivedItems = 0
        result = nil
        phase = .loading
        requestID = UUID()
    }

    func load(session: BackendSession) async {
        let current = requestID
        guard let generation = session.realtimeGeneration, session.scope != nil else {
            phase = .failed("Connect your workspace in Settings → Accounts to get suggestions.", canRetry: false)
            return
        }
        guard !sourceIDs.isEmpty else {
            phase = .failed("This conversation needs to sync before it can be reviewed.", canRetry: true)
            return
        }
        do {
            let settings: MailAISettings = if let style = enablingStyleGuide {
                try await session.request("PUT", "/v1/ai/settings", body: MailAISettingsInput(enabled: true, styleGuide: style))
            } else {
                try await session.request("GET", "/v1/ai/settings")
            }
            guard requestID == current, session.realtimeGeneration == generation else { return }
            self.settings = settings
            guard settings.available else {
                phase = .failed("Your workspace administrator needs to configure an AI provider.", canRetry: false)
                return
            }
            guard settings.enabled else { phase = .consent; return }
            phase = .streaming
            let result = try await session.suggest(messageIDs: sourceIDs, onDelta: { chunk in
                guard self.requestID == current else { throw CancellationError() }
                self.enqueue(text: chunk)
            }, onItem: { item in
                guard self.requestID == current else { throw CancellationError() }
                guard item.action != nil else { return }
                self.receivedItems += 1
                self.enqueue(item: item)
            })
            try Task.checkCancellation()
            guard requestID == current, session.realtimeGeneration == generation else { return }
            finish(with: result)
        } catch {
            guard !Task.isCancelled, requestID == current else { return }
            reveal?.cancel()
            pendingText = ""
            pendingItems = []
            withAnimation(.smooth) {
                items = []
                phase = .failed(error.localizedDescription, canRetry: (error as? BackendAIError)?.canRetry ?? true)
            }
        }
    }

    /// Reconciles what was streamed with the result validated as a whole.
    private func finish(with result: MailAIResult) {
        let final = result.items.filter { $0.action != nil }
        let shown = overview + pendingText
        if result.text.hasPrefix(shown) {
            pendingText += result.text.dropFirst(shown.count)
        } else {
            overview = ""
            pendingText = result.text
        }
        if receivedItems <= final.count {
            pendingItems += final.dropFirst(receivedItems)
        } else {
            items = []
            pendingItems = final
        }
        self.result = result
        withAnimation(.smooth(duration: 0.4)) { phase = .ready }
        startRevealing()
    }

    private func enqueue(text: String) {
        pendingText += text
        startRevealing()
    }

    private func enqueue(item: MailAIItem) {
        pendingItems.append(item)
        startRevealing()
    }

    private func startRevealing() {
        guard reveal == nil else { return }
        isRevealing = true
        reveal = Task { [weak self] in
            await self?.drain()
            self?.reveal = nil
            self?.isRevealing = false
        }
    }

    private func drain() async {
        // Text first, about one frame at a time, then each suggestion in turn.
        while !Task.isCancelled {
            if !pendingText.isEmpty {
                let count = max(2, pendingText.count / 10)
                let next = pendingText.prefix(count)
                overview += next
                pendingText.removeFirst(next.count)
                try? await Task.sleep(for: .milliseconds(16))
            } else if !pendingItems.isEmpty {
                let item = pendingItems.removeFirst()
                withAnimation(.spring(duration: 0.55, bounce: 0.18)) { items.append(item) }
                try? await Task.sleep(for: .milliseconds(140))
            } else {
                return
            }
        }
    }
}
