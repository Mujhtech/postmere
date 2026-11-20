import AppKit
import SwiftUI

// List rows are reused across mailboxes. Match both the message and its content,
// which can arrive in a later sync.
private struct VerificationCodeSource: Equatable, Sendable {
    let id: UUID
    let subject: String
    let paragraphs: [String]
    let html: String?
    let preview: String

    init?(_ message: MailMessage) {
        guard !message.isOutgoing, !message.isDraft, message.mailbox != .outbox else { return nil }
        id = message.id
        subject = message.subject
        paragraphs = message.paragraphs
        html = message.bodyHTML
        preview = message.preview
    }

    @concurrent func detect() async -> String? {
        guard !Task.isCancelled else { return nil }
        return MailVerificationCode.detect(subject: subject, paragraphs: paragraphs, html: html, preview: preview)
    }
}

struct MailVerificationCodeView<Fallback: View>: View {
    let message: MailMessage
    var compact = false
    @ViewBuilder let fallback: Fallback
    @State private var match: (source: VerificationCodeSource, code: String)?

    var body: some View {
        let source = VerificationCodeSource(message)
        VStack(alignment: .leading, spacing: 0) {
            if let match, match.source == source {
                VerificationCodeButton(code: match.code, compact: compact)
                    .id(match.source.id)
                    .padding(compact ? .top : .bottom, compact ? 4 : 14)
            } else {
                fallback
            }
        }
        .task(id: source, priority: .utility) {
            guard let source else { match = nil; return }
            let code = await source.detect()
            guard !Task.isCancelled else { return }
            match = code.map { (source, $0) }
        }
    }
}

private struct VerificationCodeButton: View {
    let code: String
    let compact: Bool
    @State private var copiedAt: Date?

    var body: some View {
        Button {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            if pasteboard.setString(code, forType: .string) { copiedAt = .now }
        } label: {
            HStack(spacing: compact ? 6 : 9) {
                Text(verbatim: code)
                    .font(.system(size: compact ? 12 : 16, weight: .semibold, design: .monospaced))
                Image(systemName: copiedAt == nil ? "doc.on.doc" : "checkmark")
                    .font(.system(size: compact ? 11 : 13, weight: .medium))
                if !compact || copiedAt != nil {
                    Text(copiedAt == nil ? "Copy code" : "Copied")
                        .font(.system(size: compact ? 11 : 12, weight: .medium))
                }
            }
            .padding(.horizontal, compact ? 8 : 12)
            .padding(.vertical, compact ? 4 : 7)
            .background(.quaternary, in: Capsule())
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Copy verification code")
        .accessibilityLabel("Copy verification code")
        .accessibilityValue(copiedAt == nil ? code : "Copied")
        .onChange(of: code) { copiedAt = nil }
        .task(id: copiedAt) {
            guard copiedAt != nil else { return }
            try? await Task.sleep(for: .seconds(2))
            if !Task.isCancelled { copiedAt = nil }
        }
    }
}
