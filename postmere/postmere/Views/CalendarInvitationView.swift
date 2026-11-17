import SwiftUI

struct CalendarInvitationView: View {
    let invitation: MailCalendarInvitation
    let onAddLocalEvent: (MailCalendarEventDraft) -> Void
    var onRespond: ((MailInvitationResponse) async throws -> Void)?
    @State private var isResponding = false
    @State private var responseMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            PostmereLabel(invitation.isCanceled ? "Canceled invitation" : "Calendar invitation", symbol: "calendar", size: 17)
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            Text(invitation.title).font(.headline)
            Text(invitation.isAllDay
                 ? invitation.start.formatted(date: .complete, time: .omitted)
                 : invitation.start.formatted(date: .abbreviated, time: .shortened) + "–" + invitation.end.formatted(date: .omitted, time: .shortened))
            Text(invitation.timeZoneIdentifier).font(.caption).foregroundStyle(.secondary)
            if !invitation.organizer.isEmpty { Text("Organizer: \(invitation.organizer)").font(.system(size: 12)).textSelection(.enabled) }
            if !invitation.location.isEmpty { Text(invitation.location).font(.system(size: 12)) }
            if !invitation.notes.isEmpty { Text(invitation.notes).font(.system(size: 12)).lineLimit(6).textSelection(.enabled) }
            ForEach(invitation.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            HStack {
                ForEach(MailInvitationResponse.allCases, id: \.self) { response in
                    Button(response.title) {
                        guard let onRespond else { return }
                        isResponding = true
                        Task {
                            do { try await onRespond(response); responseMessage = "Response sent: \(response.title)" }
                            catch { responseMessage = error.localizedDescription }
                            isResponding = false
                        }
                    }.disabled(onRespond == nil || !invitation.canRespond || isResponding)
                }
                Spacer()
                Button("Review Local Copy") { onAddLocalEvent(invitation.eventDraft) }.disabled(invitation.isCanceled)
            }
            if onRespond == nil {
                Text("RSVP requires a supported calendar provider. A local copy does not send a response.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let responseMessage { Text(responseMessage).font(.caption) }
        }.padding(16)
        .background(PostmereTheme.subtleFill, in: .rect(cornerRadius: PostmereTheme.cardRadius))
        .environment(\.timeZone, TimeZone(identifier: invitation.timeZoneIdentifier) ?? .current)
    }
}
