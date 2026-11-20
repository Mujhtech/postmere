import SwiftUI

struct InboxOverviewView: View {
    let store: MailStore
    @Environment(MailRuntime.self) private var runtime

    var body: some View {
        if let overview = store.mailboxViewData?.overview {
            content(overview)
        } else {
            ProgressView("Loading mailbox…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func content(_ overview: InboxOverview) -> some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(alignment: .leading, spacing: 26) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                                .font(.caption.weight(.semibold)).textCase(.uppercase)
                                .tracking(0.8).foregroundStyle(.secondary)
                            Text(overview.isInbox ? greeting(at: context.date) : overview.title)
                                .font(.system(size: geometry.size.width < 440 ? 28 : 36, weight: .medium, design: .serif))
                                .accessibilityAddTraits(.isHeader)
                            Text(runtime.isSyncingBackend && overview.isInbox && overview.sections.isEmpty ? "Checking for new mail…" : overview.summary)
                                .font(.body).foregroundStyle(.secondary)
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 10) { actions(overview) }
                        VStack(alignment: .leading, spacing: 9) { actions(overview) }
                    }
                    .controlSize(.large).buttonBorderShape(.capsule)
                    ForEach(overview.sections) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 6) {
                                Text(section.title).fontWeight(.semibold)
                                Text(section.count.formatted()).monospacedDigit()
                            }
                            .foregroundStyle(.secondary)
                            .font(.callout)
                            .accessibilityElement(children: .combine)
                            .accessibilityAddTraits(.isHeader)
                            ForEach(section.messages) { message in
                                Button { open(message, in: section.mailbox) } label: {
                                    HStack(spacing: 10) {
                                        ParticipantPhoto(address: message.senderEmail, name: message.sender, size: 32, verifiedMark: store.displayedSenderMark(for: message))
                                        VStack(alignment: .leading, spacing: 3) {
                                            Text(message.sender).fontWeight(.semibold).lineLimit(1)
                                            Text(message.displaySubject).foregroundStyle(.secondary).lineLimit(1)
                                        }
                                        Spacer(minLength: 4)
                                        Text((section.mailbox == .followUps ? message.workflow.followUpAt ?? message.sentAt : message.sentAt),
                                             format: .dateTime.month(.abbreviated).day())
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                    .padding(.vertical, 5)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                .frame(maxWidth: 620, alignment: .leading)
                .padding(.horizontal, geometry.size.width < 440 ? 18 : 36)
                .padding(.top, min(90, max(30, geometry.size.height * 0.095)))
                .padding(.bottom, 36)
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private func actions(_ overview: InboxOverview) -> some View {
        if let section = overview.sections.first, let first = section.messages.first {
            let triage = overview.isInbox && section.mailbox != nil
            Button {
                if triage, let mailbox = section.mailbox {
                    store.selectedMailbox = mailbox
                    if mailbox == .inbox { store.unreadOnly = true }
                }
                open(first, in: section.mailbox)
            } label: {
                Label(triage ? "Start triage" : "Open conversation", systemImage: "tray")
            }.buttonStyle(.borderedProminent)
        } else if !MailAccount.sendingAccounts.isEmpty && !store.isComposing {
            Button { store.beginCompose() } label: { Label("New message", systemImage: "square.and.pencil") }
                .buttonStyle(.borderedProminent)
        }
        if runtime.backend.canAccessWorkspace {
            Button { runtime.showsAIQuestion = true } label: { Label("Ask about your mail", systemImage: "sparkles") }
                .buttonStyle(.bordered)
        }
    }

    private func open(_ message: MailMessage, in mailbox: Mailbox?) {
        if let mailbox, store.mailboxViewData?.messages.contains(where: { $0.id == message.id }) != true {
            store.selectedMailbox = mailbox
        }
        store.select(message)
    }

    private func greeting(at date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let greeting = hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let accounts = RemoteAccountRegistry.accounts.filter { store.selectedAccount == nil || $0.localID == store.selectedAccount }
        let givenNames = Set(accounts.compactMap { account -> String? in
            let name = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("@"), name != "Me" else { return nil }
            return name.split(whereSeparator: \.isWhitespace).first.map(String.init)
        })
        guard givenNames.count == 1, let name = givenNames.first else { return greeting }
        return "\(greeting), \(name)"
    }
}
