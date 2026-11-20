import SwiftUI

@MainActor @Observable
final class MailConversationSummary {
    let id = UUID()
    let messageID: UUID
    let sessionID: UUID?
    let sourceIDs: [UUID]
    private(set) var text = ""
    private(set) var requestID = UUID()
    private(set) var phase: Phase = .loading
    private var enablingStyleGuide: String?

    enum Phase {
        case loading
        case consent(MailAISettings)
        case failed(String, canRetry: Bool = true)
        case ready(MailAIResult)
    }

    init(messageID: UUID, sessionID: UUID?, sourceIDs: [UUID]) {
        self.messageID = messageID
        self.sessionID = sessionID
        self.sourceIDs = sourceIDs
    }

    func start(enablingWith styleGuide: String? = nil) {
        text = ""
        phase = .loading
        enablingStyleGuide = styleGuide
        requestID = UUID()
    }

    func load(session: BackendSession) async {
        let current = requestID
        guard !Task.isCancelled, case .loading = phase else { return }
        guard let generation = session.realtimeGeneration, session.scope != nil else {
            phase = .failed("Connect your workspace in Settings → Accounts to summarize this conversation.")
            return
        }
        guard generation == sessionID else { return }
        guard !sourceIDs.isEmpty else {
            phase = .failed("This conversation needs to sync before it can be summarized.")
            return
        }
        do {
            let settings: MailAISettings
            if let style = enablingStyleGuide {
                settings = try await session.request("PUT", "/v1/ai/settings",
                                                     body: MailAISettingsInput(enabled: true, styleGuide: style))
            } else {
                settings = try await session.request("GET", "/v1/ai/settings")
            }
            try Task.checkCancellation()
            guard session.realtimeGeneration == generation, requestID == current else { return }
            guard settings.available else {
                phase = .failed("Your workspace administrator needs to configure an AI provider.")
                return
            }
            guard settings.enabled else {
                phase = .consent(settings)
                return
            }
            let result = try await session.summarize(messageIDs: sourceIDs) { chunk in
                guard self.requestID == current else { throw CancellationError() }
                self.text.append(chunk)
            }
            try Task.checkCancellation()
            guard session.realtimeGeneration == generation, requestID == current else { return }
            let hasContent = !result.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || result.items.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            phase = hasContent ? .ready(result) : .failed("No summary was returned for this conversation.")
        } catch {
            guard !Task.isCancelled, session.realtimeGeneration == generation, requestID == current else { return }
            text = ""
            phase = .failed(error.localizedDescription, canRetry: (error as? BackendAIError)?.canRetry ?? true)
        }
    }
}

struct MailConversationSummaryView: View {
    let summary: MailConversationSummary
    @Binding var isExpanded: Bool
    let onOpenSource: (UUID) -> Void
    @Environment(\.postmereAccent) private var palette
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch summary.phase {
            case .loading:
                if summary.text.isEmpty {
                    HStack(spacing: 7) {
                        ProgressView().controlSize(.small).accessibilityHidden(true)
                        Text("Summarizing…").font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    summaryDisclosure
                    if isExpanded { summaryText(summary.text) }
                }
            case .consent(let settings):
                summaryTitle
                Text(settings.dataNotice).font(.callout).foregroundStyle(.secondary)
                Button("Enable and Summarize") { summary.start(enablingWith: settings.styleGuide) }
                    .buttonStyle(.link)
            case .failed(let message, let canRetry):
                summaryTitle
                Text(message).font(.callout).foregroundStyle(.secondary)
                if canRetry {
                    Button("Retry") { summary.start() }
                        .buttonStyle(.link)
                }
            case .ready(let result):
                summaryDisclosure
                if isExpanded {
                    summaryContent(result)
                }
            }
        }
        .tint(palette.accentInk)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var summaryDisclosure: some View {
        Button {
            isExpanded.toggle()
        } label: {
            HStack(spacing: 6) {
                summaryTitle
                PostmereIcon(isExpanded ? "chevron.down" : "chevron.right", size: 10)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Summary")
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }

    private var summaryTitle: some View {
        PostmereLabel("Summary", symbol: "sparkles", size: 13)
            .font(.callout.weight(.semibold))
            .foregroundStyle(palette.accentInk)
    }

    private func summaryText(_ text: String) -> some View {
        Text(verbatim: text)
            .font(.body)
            .lineSpacing(2)
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private func summaryContent(_ result: MailAIResult) -> some View {
        let prose = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let items = result.items.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !prose.isEmpty {
            summaryText(prose)
            if !items.isEmpty {
                DisclosureGroup("Details", isExpanded: $showsDetails) {
                    summaryItems(items, sources: result.sources)
                }
                .font(.callout)
            }
        } else {
            summaryItems(items, sources: result.sources)
        }
    }

    private func summaryItems(_ items: [MailAIItem], sources: [MailAISource]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.kind.replacingOccurrences(of: "_", with: " ").capitalized)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(verbatim: item.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    ForEach(sources.filter { item.sourceIds.contains($0.id) && summary.sourceIDs.contains($0.id) }) { source in
                        let name = source.sender.isEmpty ? MailMessage.displaySubject(source.subject) : source.sender
                        let label = "\(name) · \(source.sentAt.formatted(date: .abbreviated, time: .shortened))"
                        Button { onOpenSource(source.id) } label: {
                            PostmereLabel(label, symbol: "envelope", size: 12)
                                .font(.caption)
                                .lineLimit(1)
                        }
                        .buttonStyle(.link)
                        .help("Show original message")
                        .accessibilityLabel("Show source message, \(label)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
