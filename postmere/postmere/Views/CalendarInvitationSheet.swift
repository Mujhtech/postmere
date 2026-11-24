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
            .mailPanelSurface()
            .sheet(item: $draft) { CalendarEventDraftView(draft: $0) }
    }
}
