import SwiftUI

/// The iPad's home page for a mailbox, shown beside the list while no conversation
/// is open, as on the Mac: a greeting, what is waiting, and a way to start on it.
struct MobileMailboxOverview: View {
    let runtime: MailRuntime
    let onAsk: () -> Void
    let onStartTriage: () -> Void
    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var overview: InboxOverview?

    private var store: MailStore { runtime.store }

    /// What the overview is built from; it is rebuilt off the main thread when this changes.
    private struct Source: Equatable {
        let revision: Int
        let key: MailboxViewKey?
        let title: String?
    }

    var body: some View {
        Group {
            if let overview {
                content(overview).id(overview.isInbox ? "inbox" : overview.title)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(Mobile.background)
        .task(id: Source(revision: store.mailboxDataRevision, key: store.mailboxViewData?.key, title: store.overviewTitle)) {
            guard let data = store.mailboxViewData else { return }
            let built = await Self.build(messages: store.messages, visible: data.messages,
                                         request: store.searchRequest(), title: store.overviewTitle)
            guard !Task.isCancelled else { return }
            withAnimation(.smooth) { overview = built }
        }
        .onAppear {
            guard !appeared else { return }
            if reduceMotion { appeared = true } else { withAnimation(.smooth(duration: 0.5)) { appeared = true } }
        }
    }

    private func content(_ overview: InboxOverview) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero(overview).overviewEntrance(appeared, order: 0)
                if overview.isInbox && runtime.backend.canAccessWorkspace {
                    askBar.overviewEntrance(appeared, order: 1)
                }
                let tiles = tiles(overview)
                if overview.isInbox, !tiles.isEmpty {
                    HStack(spacing: 10) { ForEach(tiles) { tile($0) } }
                        .overviewEntrance(appeared, order: 2)
                }
                ForEach(Array(overview.sections.enumerated()), id: \.element.id) { index, section in
                    sectionCard(section).overviewEntrance(appeared, order: 3 + index)
                }
                if overview.sections.isEmpty {
                    Label(overview.isInbox ? "Nothing waiting on you. Enjoy the quiet." : "Nothing here yet.",
                          systemImage: "checkmark.circle")
                        .foregroundStyle(.secondary)
                        .overviewEntrance(appeared, order: 3)
                }
            }
            .frame(maxWidth: 620, alignment: .leading)
            .padding(.horizontal, 36)
            .padding(.top, 48)
            .padding(.bottom, 40)
            .frame(maxWidth: .infinity)
        }
    }

    @concurrent private static func build(messages: [MailMessage], visible: [MailMessage],
                                          request: MailSearchRequest, title: String?) async -> InboxOverview {
        InboxOverview(messages: messages, visible: visible, request: request, title: title)
    }

    // MARK: Hero

    private func hero(_ overview: InboxOverview) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 12, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(1.1)
                    .foregroundStyle(palette.accent)
                Text(overview.isInbox ? greeting(at: context.date) : overview.title)
                    .font(.system(size: 38, weight: .medium, design: .serif))
                    .accessibilityAddTraits(.isHeader)
                Text(overview.summary)
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.smooth, value: overview.summary)
                if let section = overview.sections.first, !section.allIDs.isEmpty {
                    Button { startTriage(section) } label: {
                        Label("Go through \(section.title.lowercased())", systemImage: "rectangle.stack")
                            .font(.headline)
                            .padding(.horizontal, 6)
                            .frame(minHeight: 40)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(palette.accent)
                    .padding(.top, 8)
                } else if !MailAccount.sendingAccounts.isEmpty {
                    Button { store.beginCompose() } label: {
                        Label("New Message", systemImage: "square.and.pencil").font(.headline).frame(minHeight: 40)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(palette.accent)
                    .padding(.top, 8)
                }
            }
        }
    }

    private var askBar: some View {
        HStack(spacing: 10) {
            askField
            Button {
                runtime.pendingAIQuestion = MailAIAssist.briefingQuestion
                onAsk()
            } label: {
                Label("Brief Me", systemImage: "sun.horizon")
                    .font(.system(size: 15, weight: .semibold))
                    .padding(.horizontal, 16)
                    .frame(height: 46)
                    .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(palette.accent)
            .glassEffect(.regular.interactive(), in: Capsule())
            .accessibilityHint("Asks for a summary of today’s mail")
        }
    }

    private var askField: some View {
        Button(action: onAsk) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles").foregroundStyle(palette.accent)
                Text("Ask anything about your mail…").foregroundStyle(.secondary)
                Spacer()
            }
            .font(.system(size: 15.5))
            .padding(.horizontal, 16)
            .frame(height: 46)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: Capsule())
        .accessibilityLabel("Ask your mail")
    }

    // MARK: Tiles

    private struct Tile: Identifiable {
        let section: InboxOverview.Section
        let count: Int
        let title: String
        var id: String { section.id }
    }

    private func tiles(_ overview: InboxOverview) -> [Tile] {
        overview.sections.filter { $0.mailbox != nil }.map { section in
            section.mailbox == .inbox
                ? Tile(section: section, count: overview.unreadCount, title: "Unread")
                : Tile(section: section, count: section.count, title: section.title)
        }
    }

    private func tile(_ tile: Tile) -> some View {
        Button { startTriage(tile.section) } label: {
            HStack(spacing: 12) {
                Image(systemName: tile.section.mailbox?.mobileSymbol ?? "tray")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 34, height: 34)
                    .background(palette.accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(tile.count.formatted())
                        .font(.system(size: 22, weight: .semibold, design: .serif))
                        .monospacedDigit()
                        .contentTransition(.numericText(value: Double(tile.count)))
                    Text(tile.title).font(.caption.weight(.medium)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .mobileSettingsCard(cornerRadius: 16)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tile.count) \(tile.title)")
        .accessibilityHint("Starts triage")
    }

    // MARK: Sections

    private func sectionCard(_ section: InboxOverview.Section) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(section.title).font(.headline)
                Text(section.count.formatted()).font(.subheadline).foregroundStyle(.secondary)
                Spacer()
                if section.mailbox != nil {
                    Button("See All") { showAll(section) }.font(.subheadline.weight(.medium)).tint(palette.accent)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            ForEach(section.messages) { message in
                MobileHairline(leading: 16)
                Button { open(message, in: section.mailbox) } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(message.sender).font(.subheadline.weight(message.isUnread ? .semibold : .regular)).lineLimit(1)
                            Spacer()
                            Text(message.sentAt, format: .relative(presentation: .named))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Text(message.displaySubject).font(.subheadline).foregroundStyle(.primary).lineLimit(1)
                        Text(message.displayPreview).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .mobileSettingsCard(cornerRadius: 18)
    }

    // MARK: Actions

    private func startTriage(_ section: InboxOverview.Section) {
        let ids = Set(section.allIDs)
        let rows = store.messages.filter { ids.contains($0.id) }
        runtime.startTriage(MobileTriageQueue(rows: rows), store: store, title: section.title)
        if runtime.triage != nil { onStartTriage() }
    }

    private func showAll(_ section: InboxOverview.Section) {
        guard let mailbox = section.mailbox else { return }
        store.selectMailbox(mailbox)
        if mailbox == .inbox { store.unreadOnly = true }
    }

    private func open(_ message: MailMessage, in mailbox: Mailbox?) {
        if let mailbox, store.mailboxViewData?.messages.contains(where: { $0.id == message.id }) != true {
            store.selectedMailbox = mailbox
        }
        store.select(message)
    }

    private func greeting(at date: Date) -> String {
        let hour = Calendar.current.component(.hour, from: date)
        let greeting = hour < 5 ? "Working late" : hour < 12 ? "Good morning" : hour < 18 ? "Good afternoon" : "Good evening"
        let accounts = RemoteAccountRegistry.accounts.filter { store.selectedAccount == nil || $0.localID == store.selectedAccount }
        let names = Set(accounts.compactMap { account -> String? in
            let name = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("@"), name != "Me" else { return nil }
            return name.split(whereSeparator: \.isWhitespace).first.map(String.init)
        })
        guard names.count == 1, let name = names.first else { return greeting }
        return "\(greeting), \(name)"
    }
}

private extension View {
    func overviewEntrance(_ appeared: Bool, order: Int) -> some View {
        opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 10)
            .animation(.smooth(duration: 0.5).delay(Double(order) * 0.05), value: appeared)
    }
}
