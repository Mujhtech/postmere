import SwiftUI

/// The message reader creates this only for the body of an expanded message.
struct MailMessageInvitation: View {
    let message: MailMessage
    let runtime: MailRuntime
    let showDetails: (MailCalendarInvitation) -> Void
    @State private var state = Presentation()
    @State private var retry = 0

    private struct Source: Equatable, Sendable {
        let id: UUID
        let subject: String
        let sender: String
        let text: [String]
        let html: String?
        let files: [MailAttachment]
        let retry: Int

        @concurrent func evidence() async -> (events: [MailCalendarInvitation], link: MailMeetingLink?, legacy: Bool) {
            let limit = MailAttachment.maximumCalendarBytes
            // Bound work even for a newsletter with a very large HTML body.
            var sample = ""
            for paragraph in text {
                let remaining = limit - sample.utf8.count
                guard remaining > 1 else { break }
                sample += String(decoding: paragraph.utf8.prefix(remaining - 1), as: UTF8.self) + "\n"
            }
            let source = sample.trimmingCharacters(in: .whitespacesAndNewlines)
            let events = source.hasPrefix("BEGIN:VCALENDAR") ? (try? MailCalendarInvitationParser.parse(data: Data(source.utf8))) ?? [] : []
            let link = MailMeetingLink.first(in: sample) ?? html.flatMap { MailMeetingLink.first(in: String(decoding: $0.utf8.prefix(limit), as: UTF8.self), html: true) }
            let title = subject.lowercased()
            let legacy = link != nil && (sender.caseInsensitiveCompare("calendar-notification@google.com") == .orderedSame
                || ["invitation:", "updated invitation:", "canceled event:", "cancelled event:"].contains(where: title.hasPrefix)
                || sample.localizedCaseInsensitiveContains("Invitation from Google Calendar")
                || (html?.prefix(64_000).localizedCaseInsensitiveContains("calendar.google.com/calendar/event") == true))
            return (events, link, legacy)
        }
    }

    private struct Presentation {
        var events: [MailCalendarInvitation] = []
        var link: MailMeetingLink?
        var loading = false
        var error: String?
    }

    var body: some View {
        let source = Source(id: message.id, subject: message.subject, sender: message.senderEmail, text: message.paragraphs,
                            html: message.bodyHTML, files: message.attachments.filter(\.isCalendarFile), retry: retry)
        VStack(alignment: .leading, spacing: 8) {
            ForEach(state.events) { event in
                CalendarInvitationView(invitation: event, onAddLocalEvent: { _ in showDetails(event) },
                                       onRespond: runtime.backend.invitationResponse(for: event, account: message.mailAccount),
                                       showDetails: { showDetails(event) })
            }
            if state.events.isEmpty, state.link != nil || state.loading || state.error != nil {
                HStack(spacing: 10) {
                    if let link = state.link { Link(link.title, destination: link.url).buttonStyle(.bordered) }
                    if state.loading { ProgressView().controlSize(.small); Text("Loading invitation…").font(.callout) }
                    if let error = state.error {
                        Text(error).font(.callout).foregroundStyle(.secondary)
                        Button("Retry") { retry += 1 }.buttonStyle(.link)
                    }
                }
            }
        }
        .padding(.bottom, state.events.isEmpty && state.link == nil && !state.loading && state.error == nil ? 0 : 16)
        .task(id: source) { await load(source) }
    }

    private func load(_ source: Source) async {
        let evidence = await source.evidence()
        guard !Task.isCancelled else { return }
        let canceled = ["canceled:", "cancelled:", "canceled event:", "cancelled event:"].contains(where: source.subject.lowercased().hasPrefix)
        let link = canceled ? nil : evidence.link
        if !evidence.events.isEmpty { state = Presentation(events: evidence.events); return }
        let legacy = source.files.isEmpty && evidence.legacy && message.backendMessageID != nil && runtime.backend.canAccessWorkspace
        guard !source.files.isEmpty || legacy else { state = Presentation(link: link); return }
        state = Presentation(link: link, loading: true)
        var events: [MailCalendarInvitation] = []
        var failed = false
        // Clients sometimes attach both the MIME alternative and invitation.ics for the same event.
        var seen: Set<String> = []
        let cachedFiles = source.files.filter { $0.inlineCalendarData != nil || $0.localURL != nil }
        let remoteFiles = source.files.filter { $0.inlineCalendarData == nil && $0.localURL == nil }
        let sources: [MailAttachment?] = legacy ? [nil] : (cachedFiles + remoteFiles).prefix(8).map(Optional.some)
        for attachment in sources {
            do {
                let data = try await runtime.calendarInvitationBytes(attachment: attachment, message: message)
                let parsed = try await MailCalendarInvitationParser.parseInBackground(data)
                guard !Task.isCancelled else { return }
                for var event in parsed where seen.insert(event.id).inserted {
                    if event.meetingLink == nil, parsed.count == 1 { event.meetingLink = link }
                    events.append(event)
                }
                if !events.isEmpty { state = Presentation(events: events) }
            } catch BackendError.response(404, _) where legacy {
                // Some ordinary meeting messages have a join link but no calendar alternative.
            } catch { failed = true }
            guard !Task.isCancelled else { return }
        }
        state = Presentation(events: events, link: link, error: events.isEmpty && failed ? "Invitation details unavailable." : nil)
    }
}
