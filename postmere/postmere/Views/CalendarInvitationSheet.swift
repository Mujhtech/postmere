import SwiftUI

struct CalendarInvitationSheet: View {
    let invitation: MailCalendarInvitation
    var session: BackendSession?
    var account: MailAccount?
    @State private var draft: MailCalendarEventDraft?
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PostmereSheetHeader("Invitation")
            CalendarInvitationView(invitation: invitation, onAddLocalEvent: { draft = $0 }, onRespond: responseAction)
                .padding(.horizontal, 24).padding(.bottom, 24)
        }.frame(width: 620)
            .sheet(item: $draft) { CalendarEventDraftView(draft: $0) }
    }

    private var responseAction: ((MailInvitationResponse) async throws -> Void)? {
        guard let session, session.isConnected, let identity = account?.remote,
              identity.scope == session.scope,
              let connectedAccount = session.accounts.first(where: { $0.id == identity.accountID }),
              connectedAccount.status == "connected", connectedAccount.capabilities?.contains("calendar") == true,
              let uid = invitation.uid else { return nil }
        return { response in
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
