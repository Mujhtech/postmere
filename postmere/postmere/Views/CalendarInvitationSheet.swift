import SwiftUI

struct CalendarInvitationSheet: View {
    let invitation: MailCalendarInvitation
    var session: BackendSession?
    var account: MailAccount?
    @State private var draft: MailCalendarEventDraft?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PostmereSheetHeader("Invitation")
            CalendarInvitationView(invitation: invitation, onAddLocalEvent: { draft = $0 }, onRespond: session?.invitationResponse(for: invitation, account: account))
                .padding(.horizontal, 24).padding(.bottom, 24)
        }.frame(width: 620)
            .sheet(item: $draft) { CalendarEventDraftView(draft: $0) }
    }
}

extension BackendSession {
    func invitationResponse(for invitation: MailCalendarInvitation, account: MailAccount?) -> ((MailInvitationResponse) async throws -> Void)? {
        guard invitation.canRespond, isConnected, let identity = account?.remote,
              identity.scope == scope,
              invitation.organizer.caseInsensitiveCompare(identity.email) != .orderedSame,
              invitation.attendees.contains(where: { $0.caseInsensitiveCompare(identity.email) == .orderedSame }),
              let connectedAccount = accounts.first(where: { $0.id == identity.accountID }),
              connectedAccount.status == "connected", connectedAccount.capabilities?.contains("calendar") == true,
              let uid = invitation.uid else { return nil }
        return { [weak self] response in
            guard let session = self else { throw BackendError.notConnected }
            guard session.isConnected, session.scope == identity.scope else { throw BackendError.notConnected }
            do {
                let result: CalendarRSVPResult = try await session.request("POST", "/v1/calendar/invitations/respond",
                    body: CalendarRSVPInput(accountId: identity.accountID, icalUid: uid, organizer: invitation.organizer,
                        start: invitation.start, end: invitation.end, response: response.rawValue))
                guard result.status == "responded", result.response == response.rawValue else { throw BackendError.invalidResponse }
            } catch {
                if case BackendError.response(409, _) = error {
                    throw BackendError.response(409, "The calendar provider could not confirm this response. Check the matching invitation in this account’s primary calendar before trying again.")
                }
                throw error
            }
        }
    }
}
