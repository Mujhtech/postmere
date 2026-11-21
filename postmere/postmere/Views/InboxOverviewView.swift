import SwiftUI

/// The home page for a mailbox: shown whenever no conversation is open.
struct InboxOverviewView: View {
    let store: MailStore
    @Environment(MailRuntime.self) private var runtime

    var body: some View {
        if let overview = store.mailboxViewData?.overview {
            OverviewContent(store: store, overview: overview)
                .id(overview.isInbox ? "inbox" : overview.title)
        } else {
            ProgressView("Loading mailbox…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

private struct OverviewContent: View {
    let store: MailStore
    let overview: InboxOverview

    @Environment(MailRuntime.self) private var runtime
    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var appeared = false
    @State private var question = ""

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.width < 520
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    hero(compact: compact).entrance(appeared, order: 0)
                    // The bar hands off to the Ask panel while it is open.
                    if overview.isInbox && runtime.backend.canAccessWorkspace && !runtime.showsAIQuestion {
                        askBar.entrance(appeared, order: 1)
                            .transition(.opacity.combined(with: .offset(x: 24)))
                    }
                    if overview.isInbox, !tiles.isEmpty {
                        tileRow.entrance(appeared, order: 2)
                    }
                    ForEach(Array(overview.sections.enumerated()), id: \.element.id) { index, section in
                        SectionCard(store: store, section: section, onOpen: open, onSeeAll: { showAll(section) })
                            .entrance(appeared, order: 3 + index)
                    }
                    if overview.sections.isEmpty {
                        emptyState.entrance(appeared, order: 3)
                    }
                }
                .frame(maxWidth: 640, alignment: .leading)
                .padding(.horizontal, compact ? 20 : 40)
                .padding(.top, min(84, max(28, geometry.size.height * 0.09)))
                .padding(.bottom, 40)
                .frame(maxWidth: .infinity)
            }
        }
        .tint(palette.accentInk)
        .onAppear {
            guard !appeared else { return }
            if reduceMotion { appeared = true } else { withAnimation(.smooth(duration: 0.5)) { appeared = true } }
        }
    }

    // MARK: Hero

    private func hero(compact: Bool) -> some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(.system(size: 11, weight: .semibold))
                    .textCase(.uppercase)
                    .tracking(1.1)
                    .foregroundStyle(palette.accentInk)
                Text(overview.isInbox ? greeting(at: context.date) : overview.title)
                    .font(.system(size: compact ? 30 : 40, weight: .medium, design: .serif))
                    .accessibilityAddTraits(.isHeader)
                Text(runtime.isSyncingBackend && overview.isInbox && overview.sections.isEmpty ? "Checking for new mail…" : overview.summary)
                    .font(.system(size: 15))
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
                    .animation(.smooth, value: overview.summary)
                primaryAction.padding(.top, 8)
            }
        }
    }

    @ViewBuilder private var primaryAction: some View {
        if let section = overview.sections.first, section.messages.first != nil {
            TriageLaunchButton(store: store, section: section) { startTriage(section) }
        } else if !MailAccount.sendingAccounts.isEmpty && !store.isComposing {
            Button { store.beginCompose() } label: { Label("New message", systemImage: "square.and.pencil") }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .controlSize(.large)
                .tint(palette.accent)
        }
    }

    // MARK: Ask

    private var askBar: some View {
        HStack(spacing: 10) {
            PostmereIcon("postmere.ask", size: 16).foregroundStyle(palette.accentInk)
            TextField("Ask anything about your mail…", text: $question)
                .textFieldStyle(.plain)
                .font(.system(size: 14.5))
                .onSubmit(ask)
            if question.isEmpty {
                Text("⏎")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(.tertiary)
                    .transition(.opacity)
            } else {
                Button(action: ask) {
                    PostmereIcon("arrow.up", size: 12)
                        .foregroundStyle(.white)
                        .frame(width: 26, height: 26)
                        .background(palette.accent, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Ask")
                .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
        .padding(.leading, 16)
        .padding(.trailing, 8)
        .frame(height: 44)
        .background(PostmereTheme.paper, in: .rect(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(PostmereTheme.rule))
        .shadow(color: .black.opacity(0.05), radius: 12, y: 5)
        .animation(.snappy(duration: 0.2), value: question.isEmpty)
    }

    private func ask() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        runtime.pendingAIQuestion = text.isEmpty ? nil : text
        runtime.showsAIQuestion = true
        question = ""
    }

    // MARK: Tiles

    private struct Tile: Identifiable {
        let section: InboxOverview.Section
        let count: Int
        let title: String
        var id: String { section.id }
    }

    /// Queue counts; the unread tile counts every unread conversation, as the summary does.
    private var tiles: [Tile] {
        overview.sections.filter { $0.mailbox != nil }.map { section in
            section.mailbox == .inbox
                ? Tile(section: section, count: overview.unreadCount, title: "Unread")
                : Tile(section: section, count: section.count, title: section.title)
        }
    }

    private var tileRow: some View {
        HStack(spacing: 10) {
            ForEach(tiles) { tile in
                Button { startTriage(tile.section) } label: {
                    HStack(spacing: 12) {
                        PostmereIcon(symbol(for: tile.section.mailbox), size: 15)
                            .foregroundStyle(palette.accentInk)
                            .frame(width: 34, height: 34)
                            .background(palette.accentInk.opacity(0.10), in: Circle())
                        VStack(alignment: .leading, spacing: 0) {
                            Text(tile.count.formatted())
                                .font(.system(size: 22, weight: .semibold, design: .serif))
                                .monospacedDigit()
                                .contentTransition(.numericText(value: Double(tile.count)))
                            Text(tile.title)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer(minLength: 0)
                        PostmereIcon("chevron.right", size: 10).foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                }
                .buttonStyle(OverviewTileStyle())
                .animation(.snappy, value: tile.count)
                .help("Start with \(tile.title.lowercased())")
                .accessibilityLabel("\(tile.count) \(tile.title)")
            }
        }
    }

    // MARK: Empty

    private var emptyState: some View {
        HStack(spacing: 12) {
            PostmereIcon("checkmark.circle", size: 18).foregroundStyle(palette.accentInk)
            Text(overview.isInbox ? "Nothing waiting on you. Enjoy the quiet." : "Nothing here yet.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PostmereTheme.rule.opacity(0.25), in: .rect(cornerRadius: 14, style: .continuous))
    }

    // MARK: Navigation

    private func symbol(for mailbox: Mailbox?) -> String {
        switch mailbox {
        case .needsReply: "arrowshape.turn.up.left"
        case .followUps: "bell"
        case .inbox: "envelope"
        default: "tray"
        }
    }

    /// Works through every conversation in the section one at a time.
    private func startTriage(_ section: InboxOverview.Section) {
        guard !section.allIDs.isEmpty else { return }
        withAnimation(.spring(duration: 0.5, bounce: 0.12)) {
            runtime.triage = TriageSession(title: section.title, ids: section.allIDs)
        }
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
        let givenNames = Set(accounts.compactMap { account -> String? in
            let name = account.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !name.contains("@"), name != "Me" else { return nil }
            return name.split(whereSeparator: \.isWhitespace).first.map(String.init)
        })
        guard givenNames.count == 1, let name = givenNames.first else { return greeting }
        return "\(greeting), \(name)"
    }
}

// MARK: - Section card

private struct SectionCard: View {
    let store: MailStore
    let section: InboxOverview.Section
    let onOpen: (MailMessage, Mailbox?) -> Void
    let onSeeAll: () -> Void

    @Environment(\.mailboxInset) private var inset

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Text(section.title).font(.system(size: 13, weight: .semibold))
                Text(section.count.formatted())
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText(value: Double(section.count)))
                Spacer()
                if section.mailbox != nil, section.count > section.messages.count {
                    Button("See all", action: onSeeAll)
                        .buttonStyle(.accentLink)
                        .font(.caption)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            VStack(spacing: 2) {
                ForEach(section.messages) { message in
                    OverviewRow(store: store, message: message, mailbox: section.mailbox) {
                        onOpen(message, section.mailbox)
                    }
                }
            }
            .padding(5)
            .background(inset.opacity(0.7), in: .rect(cornerRadius: 14, style: .continuous))
        }
        .animation(.snappy, value: section.count)
    }
}

private struct OverviewRow: View {
    let store: MailStore
    let message: MailMessage
    let mailbox: Mailbox?
    let onOpen: () -> Void

    @Environment(\.postmereAccent) private var palette
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            HStack(spacing: 11) {
                ParticipantPhoto(address: message.senderEmail, name: message.sender, size: 32,
                                 verifiedMark: store.displayedSenderMark(for: message))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        if message.isUnread {
                            Circle().fill(palette.accent).frame(width: 6, height: 6)
                        }
                        Text(message.sender).font(.system(size: 13, weight: message.isUnread ? .semibold : .medium)).lineLimit(1)
                    }
                    Text(message.displaySubject)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(mailbox == .followUps ? message.workflow.followUpAt ?? message.sentAt : message.sentAt,
                     format: .dateTime.month(.abbreviated).day())
                    .font(.caption)
                    .foregroundStyle(.secondary)
                PostmereIcon("chevron.right", size: 9)
                    .foregroundStyle(.tertiary)
                    .opacity(hovering ? 1 : 0)
                    .offset(x: hovering ? 0 : -3)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(hovering ? palette.selectionFill : .clear, in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(.rect(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

// MARK: - Styles

private struct OverviewTileStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        TileBody(configuration: configuration)
    }

    private struct TileBody: View {
        let configuration: ButtonStyleConfiguration
        @Environment(\.postmereAccent) private var palette
        @Environment(\.mailboxInset) private var inset
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @State private var hovering = false

        var body: some View {
            configuration.label
                .background(hovering ? palette.selectionFill : inset.opacity(0.7),
                            in: .rect(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(hovering ? palette.accentInk.opacity(0.2) : .clear))
                .offset(y: hovering && !reduceMotion ? -2 : 0)
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .onHover { hovering = $0 }
                .animation(.easeOut(duration: 0.18), value: hovering)
                .animation(.snappy(duration: 0.2), value: configuration.isPressed)
        }
    }
}

private extension View {
    /// Fades and rises into place, each block slightly after the one above.
    func entrance(_ appeared: Bool, order: Int) -> some View {
        opacity(appeared ? 1 : 0)
            .offset(y: appeared ? 0 : 14)
            .animation(.smooth(duration: 0.55).delay(0.06 * Double(order)), value: appeared)
    }
}

// MARK: - Triage launch

/// The home page's main call to action: who is waiting, how many, and
/// roughly how long a pass will take.
private struct TriageLaunchButton: View {
    let store: MailStore
    let section: InboxOverview.Section
    let action: () -> Void

    @Environment(\.postmereAccent) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var sheen = false

    /// About fifteen seconds a conversation, rounded up to whole minutes.
    private var minutes: Int { max(1, Int((Double(section.count) * 15 / 60).rounded(.up))) }
    private var senders: [MailMessage] {
        var seen = Set<String>()
        return section.messages.filter { seen.insert($0.senderEmail.lowercased()).inserted }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                HStack(spacing: -9) {
                    ForEach(Array(senders.prefix(3).enumerated()), id: \.element.id) { index, message in
                        ParticipantPhoto(address: message.senderEmail, name: message.sender, size: 28, verifiedMark: nil)
                            .overlay(Circle().strokeBorder(palette.accent, lineWidth: 2))
                            .zIndex(Double(3 - index))
                            .offset(x: hovering && !reduceMotion ? CGFloat(index) * 2 : 0)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text("Start triage")
                        .font(.system(size: 14.5, weight: .semibold))
                    Text("\(section.count.formatted()) \(section.count == 1 ? "conversation" : "conversations") · about \(minutes) min")
                        .font(.system(size: 12))
                        .opacity(0.82)
                        .contentTransition(.numericText(value: Double(section.count)))
                }
                .foregroundStyle(.white)
                Spacer(minLength: 6)
                PostmereIcon("arrow.right", size: 13)
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .background(.white.opacity(hovering ? 0.28 : 0.18), in: Circle())
                    .offset(x: hovering && !reduceMotion ? 3 : 0)
            }
            .padding(.leading, 12)
            .padding(.trailing, 12)
            .frame(height: 56)
            .frame(minWidth: 300, maxWidth: 380)
            .background { surface }
            .contentShape(.rect(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(TriageLaunchPressStyle())
        .offset(y: hovering && !reduceMotion ? -2 : 0)
        .onHover { inside in
            hovering = inside
            guard inside, !reduceMotion else { return }
            sheen = false
            withAnimation(.easeInOut(duration: 0.9)) { sheen = true }
        }
        .animation(.spring(duration: 0.35, bounce: 0.3), value: hovering)
        .help("Go through each conversation one at a time, deciding with a single key")
        .accessibilityLabel("Start triage, \(section.count) conversations, about \(minutes) minutes")
    }

    private var surface: some View {
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)
        return shape
            .fill(LinearGradient(colors: [palette.accent, palette.accentInk], startPoint: .topLeading, endPoint: .bottomTrailing))
            // A soft highlight along the top edge gives the surface some depth.
            .overlay(shape.fill(LinearGradient(colors: [.white.opacity(0.22), .clear], startPoint: .top, endPoint: .center)))
            .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .overlay {
                GeometryReader { proxy in
                    LinearGradient(colors: [.clear, .white.opacity(0.35), .clear], startPoint: .leading, endPoint: .trailing)
                        .frame(width: proxy.size.width * 0.35)
                        .rotationEffect(.degrees(18))
                        .offset(x: sheen ? proxy.size.width * 1.2 : -proxy.size.width * 0.5)
                }
                .clipShape(shape)
                .allowsHitTesting(false)
            }
            .shadow(color: palette.accent.opacity(hovering ? 0.45 : 0.3), radius: hovering ? 20 : 14, y: hovering ? 10 : 7)
    }
}

private struct TriageLaunchPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? -0.04 : 0)
            .animation(.snappy(duration: 0.18), value: configuration.isPressed)
    }
}

