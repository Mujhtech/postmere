import SwiftUI

struct CalendarInvitationView: View {
    @Environment(\.mailboxInset) private var inset
    let invitation: MailCalendarInvitation
    let onAddLocalEvent: (MailCalendarEventDraft) -> Void
    var onRespond: ((MailInvitationResponse) async throws -> Void)?
    var showDetails: (() -> Void)?
    @State private var isResponding = false
    @State private var responseMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "calendar").font(.system(size: 22)).foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(invitation.isCanceled ? "Canceled invitation" : "Calendar invitation")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(invitation.title).font(.headline).textSelection(.enabled)
                    Text(schedule).font(.callout)
                    if !invitation.organizer.isEmpty {
                        Text(invitation.organizer).font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled).accessibilityLabel("Organizer, \(invitation.organizer)")
                    }
                }
                Spacer(minLength: 4)
                if let showDetails {
                    Button("Details", action: showDetails).buttonStyle(.link)
                        .accessibilityLabel("Invitation details")
                }
            }
            if !invitation.location.isEmpty && invitation.location != invitation.meetingLink?.url.absoluteString {
                Label(invitation.location, systemImage: "mappin").font(.callout).textSelection(.enabled)
            }
            if showDetails == nil {
                if !invitation.notes.isEmpty { Text(invitation.notes).font(.callout).lineLimit(6).textSelection(.enabled) }
                ForEach(invitation.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { actions }
                VStack(alignment: .leading, spacing: 8) { actions }
            }
            if let responseMessage { Text(responseMessage).font(.caption) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(inset, in: .rect(cornerRadius: PostmereTheme.cardRadius))
    }

    private var schedule: String {
        if invitation.isAllDay {
            var calendar = Calendar.current
            calendar.timeZone = TimeZone(identifier: invitation.timeZoneIdentifier) ?? .current
            let last = calendar.date(byAdding: .day, value: -1, to: invitation.end) ?? invitation.start
            func day(_ date: Date) -> String {
                date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted, timeZone: calendar.timeZone))
            }
            return calendar.isDate(invitation.start, inSameDayAs: last) ? "\(day(invitation.start)) · All day" : "\(day(invitation.start)) – \(day(last)) · All day"
        }
        let times = invitation.hasEstimatedEnd ? invitation.start.formatted(date: .abbreviated, time: .shortened)
            : (invitation.start..<invitation.end).formatted(date: .abbreviated, time: .shortened)
        return times + " · " + (TimeZone.current.abbreviation(for: invitation.start) ?? TimeZone.current.identifier)
    }

    @ViewBuilder private var actions: some View {
        if let link = invitation.meetingLink, !invitation.isCanceled {
            Link(link.title, destination: link.url).buttonStyle(.borderedProminent).help(link.url.absoluteString)
        }
        if let onRespond, invitation.canRespond {
            HStack(spacing: 6) {
                ForEach(MailInvitationResponse.allCases, id: \.self) { response in
                    Button(response.title) {
                        guard !isResponding else { return }
                        isResponding = true
                        Task {
                            do { try await onRespond(response); responseMessage = "Response sent: \(response.title)" }
                            catch { responseMessage = error.localizedDescription }
                            isResponding = false
                        }
                    }
                }
                if isResponding { ProgressView().controlSize(.small) }
            }
            .disabled(isResponding)
        }
        if showDetails == nil && !invitation.isCanceled {
            Button("Review Local Copy") { onAddLocalEvent(invitation.eventDraft) }
        }
    }
}
