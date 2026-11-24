import SwiftUI
import UIKit

// MARK: - AI summary

/// The streamed AI summary of a conversation, shown above the thread. It drops in with a
/// travelling glow and placeholder lines, lets the words stream in, then settles once it's done.
struct MobileSummaryCard: View {
    let summary: MailConversationSummary
    let onClose: () -> Void
    @Environment(\.postmereAccent) private var palette
    @State private var showsDetails = false

    private enum Stage: Hashable { case waiting, streaming, consent, failed, ready }

    private var stage: Stage {
        switch summary.phase {
        case .loading: summary.text.isEmpty ? .waiting : .streaming
        case .consent: .consent
        case .failed: .failed
        case .ready: .ready
        }
    }

    private var isWorking: Bool { stage == .waiting || stage == .streaming }

    /// The prose, whether it's still streaming or finished, so it stays one view between the two.
    private var prose: String? {
        switch summary.phase {
        case .loading: summary.text.isEmpty ? nil : summary.text
        case .ready(let result):
            result.text.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        default: nil
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if stage == .waiting {
                MobileSkeletonLines(tint: palette.accent)
                    .padding(.vertical, 2)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .topLeading)))
            }
            if let prose {
                Text(verbatim: prose)
                    .font(.system(size: 15.5))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(.opacity)
                    .transition(.blurReplace)
            }
            switch summary.phase {
            case .consent(let settings):
                Text(settings.dataNotice).font(.subheadline).foregroundStyle(.secondary)
                    .transition(.blurReplace)
                Button("Enable and Summarize") { summary.start(enablingWith: settings.styleGuide) }
                    .buttonStyle(.glassProminent)
                    .tint(palette.accent)
                    .transition(.blurReplace)
            case .failed(let message, let canRetry):
                Text(message).font(.subheadline).foregroundStyle(.secondary)
                    .transition(.blurReplace)
                if canRetry {
                    Button("Try Again", systemImage: "arrow.clockwise") { summary.start() }
                        .buttonStyle(.glass)
                        .transition(.blurReplace)
                }
            case .ready(let result):
                details(result, hasProse: prose != nil)
            case .loading:
                EmptyView()
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(palette.accent.opacity(isWorking ? 0.06 : 0.09), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay { MobileAIGlowBorder(isActive: isWorking, color: palette.accent) }
        .animation(MobileMotion.reveal, value: stage)
        .animation(MobileMotion.stream, value: summary.text.count)
        .sensoryFeedback(.impact(flexibility: .soft, intensity: 0.7), trigger: stage) { _, new in new == .ready }
        .accessibilityElement(children: .contain)
    }

    private var header: some View {
        HStack(spacing: 6) {
            Label("Summary", systemImage: "sparkles")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(palette.accent)
                .symbolEffect(.breathe.pulse.byLayer, options: .repeating, isActive: isWorking)
                .symbolEffect(.bounce.up, value: stage == .ready)
            if isWorking {
                Text("Summarizing…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .mobileShimmer()
                    .transition(.blurReplace)
            }
            Spacer()
            Button("Close summary", systemImage: "xmark", action: onClose)
                .labelStyle(.iconOnly)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
                .buttonStyle(.plain)
        }
    }

    @ViewBuilder private func details(_ result: MailAIResult, hasProse: Bool) -> some View {
        let items = result.items.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if !items.isEmpty {
            if !hasProse || showsDetails {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Circle().fill(palette.accent.opacity(0.7)).frame(width: 5, height: 5)
                                .alignmentGuide(.firstTextBaseline) { $0[.bottom] + 4 }
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.kind.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                Text(verbatim: item.text)
                                    .font(.subheadline)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .transition(MobileMotion.staggered(index))
                    }
                }
                .transition(.opacity)
            }
            if hasProse {
                Button {
                    withAnimation(MobileMotion.reveal) { showsDetails.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(showsDetails ? "Hide details" : "Show details")
                            .contentTransition(.interpolate)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 11, weight: .bold))
                            .rotationEffect(.degrees(showsDetails ? 180 : 0))
                    }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(palette.accent)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.blurReplace)
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Verification codes

/// A one-time code found in the message, copied with one tap.
struct MobileVerificationCode: View {
    let message: MailMessage
    @State private var code: String?
    @State private var copied = false
    @Environment(\.postmereAccent) private var palette

    private struct Source: Equatable, Sendable {
        let id: UUID
        let subject: String
        let paragraphs: [String]
        let html: String?
        let preview: String

        @concurrent func detect() async -> String? {
            MailVerificationCode.detect(subject: subject, paragraphs: paragraphs, html: html, preview: preview)
        }
    }

    var body: some View {
        let source = message.isOutgoing || message.isDraft ? nil
            : Source(id: message.id, subject: message.subject, paragraphs: message.paragraphs,
                     html: message.bodyHTML, preview: message.preview)
        Group {
            if let code {
                Button {
                    UIPasteboard.general.string = code
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    copied = true
                } label: {
                    HStack(spacing: 12) {
                        Image(systemName: "key.fill").foregroundStyle(palette.accent)
                        Text(verbatim: code)
                            .font(.system(size: 22, weight: .semibold, design: .monospaced))
                            .tracking(2)
                        Spacer()
                        Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(copied ? AnyShapeStyle(palette.accent) : AnyShapeStyle(.secondary))
                    }
                    .padding(.horizontal, 16)
                    .frame(minHeight: 58)
                    .background(Mobile.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Copy verification code \(code)")
                .task(id: copied) {
                    guard copied else { return }
                    try? await Task.sleep(for: .seconds(2))
                    copied = false
                }
            }
        }
        .task(id: source, priority: .utility) {
            guard let source else { code = nil; return }
            let found = await source.detect()
            if !Task.isCancelled { code = found }
        }
    }
}

// MARK: - Calendar invitations

/// Invitations attached to or described by the message, with RSVP and join buttons.
struct MobileInvitations: View {
    let message: MailMessage
    let runtime: MailRuntime
    @State private var events: [MailCalendarInvitation] = []
    @State private var link: MailMeetingLink?
    @State private var loading = false
    @State private var failed = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(events) { event in
                MobileInvitationCard(invitation: event,
                                     respond: runtime.backend.invitationResponse(for: event, account: message.mailAccount))
            }
            if events.isEmpty {
                if let link {
                    Link(destination: link.url) {
                        Label(link.title, systemImage: "video.fill").font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.glassProminent)
                }
                if loading {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading invitation…") }
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                if failed { Text("Invitation details unavailable.").font(.footnote).foregroundStyle(.secondary) }
            }
        }
        .task(id: message.id) { await load() }
    }

    private func load() async {
        let limit = MailAttachment.maximumCalendarBytes
        let paragraphs = message.paragraphs
        let html = message.bodyHTML
        let evidence: (events: [MailCalendarInvitation], link: MailMeetingLink?) = await Task.detached(priority: .utility) {
            var sample = ""
            for paragraph in paragraphs {
                let remaining = limit - sample.utf8.count
                guard remaining > 1 else { break }
                sample += String(decoding: paragraph.utf8.prefix(remaining - 1), as: UTF8.self) + "\n"
            }
            let trimmed = sample.trimmingCharacters(in: .whitespacesAndNewlines)
            let events = trimmed.hasPrefix("BEGIN:VCALENDAR")
                ? (try? MailCalendarInvitationParser.parse(data: Data(trimmed.utf8))) ?? [] : []
            let link = MailMeetingLink.first(in: sample)
                ?? html.flatMap { MailMeetingLink.first(in: String(decoding: $0.utf8.prefix(limit), as: UTF8.self), html: true) }
            return (events, link)
        }.value
        guard !Task.isCancelled else { return }
        let canceled = ["canceled:", "cancelled:", "canceled event:", "cancelled event:"]
            .contains(where: message.subject.lowercased().hasPrefix)
        link = canceled ? nil : evidence.link
        if !evidence.events.isEmpty { events = evidence.events; return }
        let files = message.attachments.filter(\.isCalendarFile)
        guard !files.isEmpty else { return }
        loading = true
        defer { loading = false }
        var found: [MailCalendarInvitation] = []
        var seen: Set<String> = []
        for attachment in files.prefix(8) {
            do {
                let data = try await runtime.calendarInvitationBytes(attachment: attachment, message: message)
                let parsed = try await MailCalendarInvitationParser.parseInBackground(data)
                guard !Task.isCancelled else { return }
                for var event in parsed where seen.insert(event.id).inserted {
                    if event.meetingLink == nil, parsed.count == 1 { event.meetingLink = link }
                    found.append(event)
                }
                events = found
            } catch {
                failed = found.isEmpty
            }
        }
    }
}

private struct MobileInvitationCard: View {
    let invitation: MailCalendarInvitation
    let respond: ((MailInvitationResponse) async throws -> Void)?
    @Environment(\.postmereAccent) private var palette
    @State private var responding: MailInvitationResponse?
    @State private var answered: MailInvitationResponse?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                VStack(spacing: 0) {
                    Text(invitation.start.formatted(.dateTime.month(.abbreviated)).uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 2)
                        .background(invitation.isCanceled ? Color.secondary : Color.red)
                    Text(invitation.start.formatted(.dateTime.day()))
                        .font(.system(size: 20, weight: .semibold))
                        .frame(maxHeight: .infinity)
                }
                .frame(width: 46, height: 50)
                .background(Mobile.background)
                .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(invitation.isCanceled ? "Canceled" : "Invitation")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Text(invitation.title).font(.headline).strikethrough(invitation.isCanceled)
                    Text(schedule).font(.subheadline).foregroundStyle(.secondary)
                    if !invitation.location.isEmpty && invitation.location != invitation.meetingLink?.url.absoluteString {
                        Label(invitation.location, systemImage: "mappin").font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            if !invitation.isCanceled {
                HStack(spacing: 8) {
                    if let respond, invitation.canRespond {
                        ForEach(MailInvitationResponse.allCases, id: \.self) { response in
                            Button {
                                answer(response, with: respond)
                            } label: {
                                Group {
                                    if responding == response { ProgressView().controlSize(.small) }
                                    else { Text(response.title) }
                                }
                                .font(.subheadline.weight(.semibold))
                                .frame(maxWidth: .infinity, minHeight: 34)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(answered == response ? Color.white : .primary)
                            .background(answered == response ? palette.accent : Mobile.background, in: Capsule())
                            .disabled(responding != nil)
                        }
                    }
                }
                if let link = invitation.meetingLink {
                    Link(destination: link.url) {
                        Label(link.title, systemImage: "video.fill")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity, minHeight: 34)
                    }
                    .buttonStyle(.glassProminent)
                    .tint(palette.accent)
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(PostmereTheme.destructiveInk) }
        }
        .padding(14)
        .background(Mobile.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var schedule: String {
        if invitation.isAllDay {
            return invitation.start.formatted(.dateTime.weekday(.wide).day().month(.wide)) + " · All day"
        }
        let day = invitation.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
        let start = invitation.start.formatted(date: .omitted, time: .shortened)
        if invitation.hasEstimatedEnd { return "\(day) · \(start)" }
        return "\(day) · \(start) – \(invitation.end.formatted(date: .omitted, time: .shortened))"
    }

    private func answer(_ response: MailInvitationResponse, with respond: @escaping (MailInvitationResponse) async throws -> Void) {
        responding = response
        error = nil
        Task {
            defer { responding = nil }
            do {
                try await respond(response)
                answered = response
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Spam check

/// The verdict of an opt-in AI spam check.
struct MobileSpamCheck: View {
    let message: MailMessage
    let runtime: MailRuntime
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        if let phase = runtime.spamChecks.phase(for: message, session: runtime.backend) {
            let look = appearance(phase)
            HStack(alignment: .top, spacing: 12) {
                Group {
                    if case .checking = phase { ProgressView().controlSize(.small) }
                    else { Image(systemName: look.symbol).font(.system(size: 20, weight: .semibold)) }
                }
                .foregroundStyle(look.tint)
                .frame(width: 26, height: 26)
                VStack(alignment: .leading, spacing: 4) {
                    Text(look.title).font(.subheadline.weight(.semibold))
                    Text(reason(phase)).font(.footnote).foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        if case .result(let decision) = phase, decision.verdict != .noSpamSignals,
                           runtime.store.canMoveMessage(message, to: .junk) {
                            Button("Move to Junk") { runtime.store.moveMessage(message.id, to: .junk) }
                                .buttonStyle(.glassProminent)
                                .tint(PostmereTheme.destructiveInk)
                        }
                        if case .failed = phase {
                            Button("Try Again") { runtime.spamChecks.check(message, session: runtime.backend) }
                                .buttonStyle(.glass)
                        }
                        if !isChecking(phase) {
                            Button("Dismiss") { runtime.spamChecks.dismiss(message, session: runtime.backend) }
                                .buttonStyle(.glass)
                        }
                    }
                    .font(.footnote.weight(.semibold))
                    .padding(.top, 4)
                }
                Spacer(minLength: 0)
            }
            .padding(14)
            .background(look.tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
    }

    private func isChecking(_ phase: MailSpamChecks.Phase) -> Bool {
        if case .checking = phase { return true }
        return false
    }

    private func reason(_ phase: MailSpamChecks.Phase) -> String {
        switch phase {
        case .checking: "Reviewing the sender, links and wording."
        case .failed(let reason): reason
        case .result(let decision): decision.reason
        }
    }

    private func appearance(_ phase: MailSpamChecks.Phase) -> (title: String, symbol: String, tint: Color) {
        switch phase {
        case .checking: ("Checking for spam", "shield", .secondary)
        case .failed: ("Spam check unavailable", "exclamationmark.circle", .secondary)
        case .result(let decision):
            switch decision.verdict {
            case .possibleSpam: ("This looks like spam", "exclamationmark.shield.fill", PostmereTheme.destructiveInk)
            case .noSpamSignals: ("No spam signals found", "checkmark.shield.fill", .green)
            case .uncertain: ("Hard to tell", "questionmark.circle.fill", .orange)
            }
        }
    }
}

// MARK: - Unsubscribe

nonisolated private struct MobileUnsubscribeOptions: Decodable, Sendable { let oneClickUrl: String?; let reason: String? }
nonisolated private struct MobileUnsubscribeInput: Encodable, Sendable { let expectedUrl: String }
nonisolated private struct MobileUnsubscribeResult: Decodable, Sendable { let accepted: Bool; let httpStatus: Int }

/// One-tap removal when the sender supports it, else their email or web route,
/// plus Postmere's own archive and block.
struct MobileUnsubscribeSheet: View {
    let message: MailMessage
    let runtime: MailRuntime
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.postmereAccent) private var palette
    @State private var remote: MobileUnsubscribeOptions?
    @State private var busy = false
    @State private var accepted = false
    @State private var status: String?
    @State private var error: String?
    @State private var archives = true
    @State private var blocks = false
    @State private var applied = false

    private var store: MailStore { runtime.store }
    private var options: MailUnsubscribeOptions { MailUnsubscribeService.options(for: message) }
    private var oneClickURL: URL? {
        message.mailAccount.isRemote ? remote?.oneClickUrl.flatMap(URL.init(string:)) : options.oneClickURL
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(message.sender.isEmpty ? message.senderEmail : message.sender).font(.headline)
                        Text(message.senderEmail).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 4)
                }
                if let url = oneClickURL {
                    Section {
                        Button {
                            Task { await requestOneClick(url) }
                        } label: {
                            HStack {
                                Text(accepted ? "Request accepted" : "Unsubscribe").font(.body.weight(.semibold))
                                Spacer()
                                if busy { ProgressView() } else if accepted { Image(systemName: "checkmark.circle.fill") }
                            }
                        }
                        .disabled(busy || accepted)
                        .foregroundStyle(accepted ? AnyShapeStyle(.secondary) : AnyShapeStyle(palette.accent))
                    } footer: {
                        Text("Sends a removal request to \(url.host ?? "the sender").")
                    }
                }
                if !options.methods.isEmpty {
                    Section(oneClickURL == nil ? "Unsubscribe" : "Other options") {
                        ForEach(Array(options.methods.enumerated()), id: \.offset) { _, method in
                            switch method {
                            case .email(let email):
                                Button {
                                    prepareEmail(email)
                                } label: {
                                    Label("Prepare unsubscribe email", systemImage: "envelope")
                                }
                            case .web(let url):
                                Button {
                                    Task { await openWeb(url) }
                                } label: {
                                    Label("Open \(url.host ?? "unsubscribe page")", systemImage: "safari")
                                }
                            }
                        }
                    }
                } else if oneClickURL == nil {
                    Section {
                        Text(remote?.reason ?? options.explanation ?? "This sender didn’t include a supported unsubscribe link.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let status { Section { Text(status).foregroundStyle(.secondary) } }
                if let error { Section { Text(error).foregroundStyle(PostmereTheme.destructiveInk) } }
                Section {
                    Toggle("Archive this message", isOn: $archives)
                    Toggle("Send future mail to Trash", isOn: $blocks)
                    Button(applied ? "Applied" : "Apply") { applyLocal() }
                        .disabled(applied || (!archives && !blocks))
                } header: {
                    Text("In Postmere")
                } footer: {
                    Text("These organize your mail. They don’t remove you from the sender’s list.")
                }
            }
            .tint(palette.accent)
            .navigationTitle("Unsubscribe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .task {
                guard let id = message.backendMessageID, message.mailAccount.remote?.scope == runtime.backend.scope else { return }
                do { remote = try await runtime.backend.request("GET", "/v1/mail/messages/\(id.uuidString)/unsubscribe") }
                catch { self.error = error.localizedDescription }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func requestOneClick(_ url: URL) async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            if message.mailAccount.isRemote {
                guard let id = message.backendMessageID, message.mailAccount.remote?.scope == runtime.backend.scope else {
                    throw BackendError.notConnected
                }
                let response: MobileUnsubscribeResult = try await runtime.backend.request(
                    "POST", "/v1/mail/messages/\(id.uuidString)/unsubscribe",
                    body: MobileUnsubscribeInput(expectedUrl: url.absoluteString))
                guard response.accepted else { throw MailUnsubscribeError.http(response.httpStatus) }
            } else {
                try await MailUnsubscribeService().requestOneClick(for: message)
            }
            accepted = true
            status = "The sender accepted your request. Their list may take a little while to update."
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func openWeb(_ url: URL) async {
        do {
            let checked = try await MailUnsubscribeService().validateBrowserURL(url)
            openURL(checked)
            status = "Finish on \(url.host ?? "the sender’s website"). Postmere can’t confirm removal there."
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func prepareEmail(_ email: MailUnsubscribeEmail) {
        guard !store.isComposing else {
            error = "Close your current draft before preparing an unsubscribe email."
            return
        }
        dismiss()
        store.beginCompose()
        store.draftAccount = message.mailAccount
        store.draftProviderAccountEmail = message.providerAccountEmail
        store.draftTo = email.recipients.joined(separator: ", ")
        store.draftSubject = email.subject
        store.draftBody = email.body
    }

    private func applyLocal() {
        if archives { store.moveMessages([message.id], to: .archive) }
        if blocks {
            store.saveSenderRule(SenderRule(email: message.senderEmail, account: message.account,
                                            route: .blocked, providerAccountEmail: message.providerAccountEmail),
                                 applyToExisting: false)
            store.lastAction = archives ? "Archived · future mail goes to Trash" : "Future mail goes to Trash"
        }
        applied = true
    }
}

// MARK: - Sender

/// Who this is: your history with them from your own mail, VIP, and the public profile
/// the workspace researches (role, company, links, talking points), as on the Mac.
struct MobileSenderSheet: View {
    let message: MailMessage
    let runtime: MailRuntime
    let onOpen: (MailMessage) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var vip = false
    @State private var research = MailSenderProfile()
    @State private var relationship: MailRelationship?
    @State private var lookup = Lookup()
    @State private var isEnabling = false
    @State private var enableError: String?

    /// Each request to research the sender; changing it reloads.
    private struct Lookup: Equatable {
        var id = UUID()
        var refresh = false
    }

    private var store: MailStore { runtime.store }
    private var accountKey: String { MailContactIdentity.accountKey(for: message) }
    private var displayName: String { message.sender.isEmpty ? message.senderEmail : message.sender }

    private var target: SenderProfileTarget? {
        SenderProfileTarget.make(message: message, scope: runtime.backend.scope,
                                 sessionGeneration: runtime.backend.realtimeGeneration)
    }

    private var isLoading: Bool {
        guard target != nil else { return false }
        guard research.target == target else { return true }
        if case .loading = research.phase { return true }
        return isEnabling
    }

    private var profile: BackendSenderProfile? {
        guard research.target == target, case .loaded(let response) = research.phase,
              response.status == .matched else { return nil }
        return response.profile
    }

    var body: some View {
        let context = store.senderContext(email: message.senderEmail, accountKey: accountKey)
        NavigationStack {
            List {
                Section { identity }
                Section {
                    Toggle(isOn: Binding(get: { vip }, set: { vip = store.setSenderVIP($0, email: message.senderEmail, accountKey: accountKey) ? $0 : vip })) {
                        Label("VIP", systemImage: "star.circle.fill")
                    }
                    .tint(palette.accent)
                } footer: {
                    Text("Mail from VIPs always notifies you and stands out in your inbox.")
                }
                if !message.isOutgoing { researchSections }
                historySection(context)
                if !context.conversations.isEmpty {
                    Section("Recent") {
                        ForEach(context.conversations.prefix(8)) { conversation in
                            Button {
                                dismiss()
                                onOpen(conversation.latestMessage)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack {
                                        Text(conversation.latestMessage.displaySubject).lineLimit(1)
                                        Spacer()
                                        Text(conversation.latestMessage.sentAt.mobileListDate)
                                            .font(.footnote).foregroundStyle(.secondary)
                                    }
                                    Text(conversation.latestMessage.preview)
                                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .foregroundStyle(.primary)
                            }
                        }
                    }
                }
            }
            .animation(MobileMotion.reveal, value: isLoading)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if target != nil {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Refresh sender details", systemImage: "arrow.clockwise") {
                            lookup = Lookup(refresh: true)
                        }
                        .disabled(isLoading)
                        .symbolEffect(.rotate, value: lookup.id)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .onAppear { vip = store.hasSenderVIP(email: message.senderEmail, accountKey: accountKey) }
            .task {
                guard !message.isOutgoing else { return }
                relationship = MailRelationship.build(email: message.senderEmail, accountKey: accountKey,
                                                      messages: store.messages.filter(store.isAccountVisible))
            }
            .task(id: lookup) { await load(lookup) }
            .onDisappear { research.cancel() }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: Identity

    private var identity: some View {
        VStack(spacing: 10) {
            ParticipantPhoto(address: message.senderEmail, name: message.sender, size: 76,
                             verifiedMark: message.verifiedSenderMark)
            Text(displayName)
                .font(.title3.weight(.bold))
                .multilineTextAlignment(.center)
            if let headline = profile.flatMap(headline) {
                Text(verbatim: headline)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .transition(.blurReplace)
            }
            Text(verbatim: message.senderEmail)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            if let zone = profile?.localTimeZone {
                localTime(zone).transition(.blurReplace)
            }
            HStack(spacing: 10) {
                if !MailAccount.sendingAccounts.isEmpty {
                    action("Email", symbol: "envelope.fill") {
                        dismiss()
                        store.beginCompose()
                        store.draftTo = message.senderEmail
                    }
                }
                action("Copy", symbol: "doc.on.doc.fill") {
                    UIPasteboard.general.string = message.senderEmail
                }
                if let profile, !MailAccount.sendingAccounts.isEmpty, runtime.backend.canAccessWorkspace {
                    action("Intro", symbol: "sparkles") { draftIntro(profile) }
                        .transition(.scale(scale: 0.8).combined(with: .opacity))
                }
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
        .listRowBackground(Color.clear)
        .animation(MobileMotion.reveal, value: profile != nil)
    }

    /// "Head of Design at Acme", only from cited fields.
    private func headline(_ profile: BackendSenderProfile) -> String? {
        let role = profile.sources(for: "job_title").isEmpty ? nil : profile.jobTitle
        let company = profile.sources(for: "company").isEmpty ? nil : profile.company
        let text = [role, company].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: " at ")
        return text.isEmpty ? nil : text
    }

    private func localTime(_ zone: TimeZone) -> some View {
        TimelineView(.everyMinute) { context in
            let time = context.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
            let offset = (zone.secondsFromGMT(for: context.date) - TimeZone.current.secondsFromGMT(for: context.date)) / 3_600
            HStack(spacing: 5) {
                Image(systemName: "clock")
                Text("\(time) their time")
                if offset != 0 {
                    Text(offset > 0 ? "· \(offset)h ahead" : "· \(-offset)h behind").foregroundStyle(.secondary)
                }
            }
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Mobile.raised, in: Capsule())
        }
    }

    // MARK: History

    @ViewBuilder private func historySection(_ context: MailSenderContext) -> some View {
        if let relationship, !relationship.isEmpty {
            Section {
                if let first = relationship.firstContact {
                    fact("Since", first.formatted(.dateTime.month(.abbreviated).year()),
                         relationship.lastContact.map { "Last \($0.formatted(.relative(presentation: .named)))" })
                }
                fact("Messages", "\(relationship.fromThem) from them · \(relationship.fromYou) from you",
                     relationship.conversations == 1 ? "1 conversation" : "\(relationship.conversations) conversations")
                if let time = relationship.theirReplyTime { fact("They reply", MailRelationship.duration(time), nil) }
                if let time = relationship.yourReplyTime { fact("You reply", MailRelationship.duration(time), nil) }
                if let hour = relationship.usualHour {
                    fact("Usually writes", MailRelationship.window(from: hour), "Your time. A good moment to reach them.")
                }
                if !context.attachments.isEmpty {
                    fact("Attachments", context.attachments.count.formatted(), nil)
                }
                waiting("Waiting on you", relationship.waitingOnYou)
                waiting("Waiting on them", relationship.waitingOnThem)
            } header: {
                Text("Your history")
            } footer: {
                Text("From your own mail on this iPhone.")
            }
        } else {
            Section("History") {
                LabeledContent("Messages", value: context.messageCount.formatted())
                if let last = context.lastContact {
                    LabeledContent("Last contact", value: last.formatted(date: .abbreviated, time: .omitted))
                }
                if !context.attachments.isEmpty {
                    LabeledContent("Attachments", value: context.attachments.count.formatted())
                }
            }
        }
    }

    private func fact(_ title: String, _ value: String, _ detail: String?) -> some View {
        LabeledContent {
            VStack(alignment: .trailing, spacing: 1) {
                Text(verbatim: value).foregroundStyle(.primary)
                if let detail { Text(detail).font(.footnote).foregroundStyle(.secondary) }
            }
            .multilineTextAlignment(.trailing)
        } label: {
            Text(title)
        }
    }

    @ViewBuilder private func waiting(_ title: String, _ threads: [MailRelationship.Thread]) -> some View {
        if !threads.isEmpty {
            DisclosureGroup {
                ForEach(threads.prefix(5)) { thread in
                    Button {
                        guard let target = store.messages.first(where: { $0.id == thread.messageID }) else { return }
                        dismiss()
                        onOpen(target)
                    } label: {
                        HStack {
                            Text(verbatim: thread.subject).lineLimit(1)
                            Spacer(minLength: 6)
                            Text(thread.date.formatted(.relative(presentation: .named)))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(palette.accent)
                }
            } label: {
                LabeledContent(title, value: threads.count.formatted())
            }
        }
    }

    // MARK: Public research

    @ViewBuilder private var researchSections: some View {
        if target == nil {
            Section("Public profile") {
                note("Connect this message’s account to your workspace to look up public details about the sender.",
                     symbol: "person.crop.rectangle")
            }
        } else if isLoading {
            Section {
                VStack(alignment: .leading, spacing: 12) {
                    Label("Finding public details…", systemImage: "sparkles")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(palette.accent)
                        .symbolEffect(.breathe.pulse.byLayer, options: .repeating)
                    MobileSkeletonLines(widths: [0.55, 0.9, 0.75], tint: palette.accent)
                }
                .padding(.vertical, 4)
                .transition(.opacity)
            } header: {
                Text("Public profile")
            } footer: {
                Text("Looking for professional information and public profiles.")
            }
        } else if research.target == target {
            switch research.phase {
            case .failed(let error):
                Section("Public profile") {
                    note(error, symbol: "exclamationmark.circle")
                    Button("Try Again") { lookup = Lookup(refresh: true) }
                }
            case .loaded(let response):
                loaded(response)
            case .idle, .loading:
                EmptyView()
            }
        }
    }

    @ViewBuilder private func loaded(_ response: BackendSenderProfileResponse) -> some View {
        switch response.status {
        case .matched:
            if let profile = response.profile { matched(profile, checkedAt: response.checkedAt) }
        case .notFound:
            Section {
                note("There isn’t enough public information to confidently connect this address to a professional profile.",
                     symbol: "person.crop.rectangle")
            } header: { Text("No clear public match") } footer: { checked(response.checkedAt) }
        case .disabled:
            Section {
                note("AI assistance researches public sources using the sender’s name and email address. Message content is not included.",
                     symbol: "sparkles")
                Button(isEnabling ? "Enabling…" : "Enable AI & Find Details") { enable() }
                    .disabled(isEnabling)
                if let enableError {
                    Text(enableError).font(.footnote).foregroundStyle(PostmereTheme.destructiveInk)
                }
            } header: { Text("Sender research") }
        case .unconfigured:
            Section("Sender research") {
                note("AI assistance needs to be configured for this workspace. Ask your workspace administrator to enable it.",
                     symbol: "sparkles")
            }
        }
    }

    @ViewBuilder private func matched(_ profile: BackendSenderProfile, checkedAt: Date?) -> some View {
        Section {
            field("Name", "name", profile.name, profile)
            field("Role", "job_title", profile.jobTitle, profile)
            field("Company", "company", profile.company, profile)
            field("Location", "location", profile.location, profile)
            field("About", "bio", profile.bio, profile)
            ForEach(profile.publicLinks) { item in
                if let url = item.destination {
                    Link(destination: url) {
                        rowLink(item.label.isEmpty ? url.host ?? "Website" : item.label, symbol: linkSymbol(item.label))
                    }
                }
            }
        } header: {
            Label(profile.hasPerson ? "Public profile" : "Public details", systemImage: "sparkles")
                .foregroundStyle(palette.accent)
        }
        .transition(.opacity)
        if !profile.publicTalkingPoints.isEmpty {
            Section("Talking points") {
                ForEach(profile.publicTalkingPoints) { point in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(verbatim: point.text).textSelection(.enabled)
                        citations(profile.publicSources.filter { $0.url == point.sourceUrl }, in: profile)
                    }
                }
            }
        }
        if !profile.publicActivity.isEmpty {
            Section("Recent activity") {
                ForEach(profile.publicActivity) { item in
                    if let url = item.destination {
                        Link(destination: url) {
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Image(systemName: activitySymbol(item.kind)).foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: item.title).foregroundStyle(.primary).multilineTextAlignment(.leading)
                                    Text([item.kind.capitalized, item.displayDate, url.host].compactMap { $0 }.joined(separator: " · "))
                                        .font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        if let company = profile.publicCompany { companySection(company, in: profile) }
        Section {
            ForEach(Array(profile.publicSources.enumerated()), id: \.element.id) { index, source in
                if let url = source.destination {
                    Link(destination: url) {
                        Text("[\(index + 1)] \(source.displayName)").font(.footnote).multilineTextAlignment(.leading)
                    }
                    .foregroundStyle(palette.accent)
                }
            }
        } header: {
            Text("Sources")
        } footer: {
            VStack(alignment: .leading, spacing: 4) {
                Text("AI-researched public information. A profile match does not verify the sender’s identity.")
                checked(checkedAt)
            }
        }
    }

    private func companySection(_ company: BackendSenderProfile.Company, in profile: BackendSenderProfile) -> some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(verbatim: company.name).font(.headline)
                if let summary = company.summary {
                    Text(verbatim: summary).font(.subheadline).foregroundStyle(.secondary).textSelection(.enabled)
                }
                citations(profile.publicSources.filter { company.sourceUrls.contains($0.url) }, in: profile)
            }
            ForEach([("Industry", company.industry), ("Size", company.size), ("Funding", company.funding),
                     ("Based in", company.headquarters)], id: \.0) { title, value in
                if let value { LabeledContent(title, value: value) }
            }
            if company.hiring != nil || company.careersURL != nil {
                let hiring = HStack(spacing: 8) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Text(verbatim: company.hiring ?? "Careers page").foregroundStyle(.primary)
                }
                if let careers = company.careersURL {
                    Link(destination: careers) { HStack { hiring; Spacer(); Image(systemName: "arrow.up.right").foregroundStyle(.tertiary) } }
                } else {
                    hiring
                }
            }
            ForEach(company.news) { item in
                if let url = item.destination {
                    Link(destination: url) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: item.title).foregroundStyle(.primary).multilineTextAlignment(.leading)
                            Text([item.displayDate, url.host].compactMap { $0 }.joined(separator: " · "))
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            if let website = company.websiteURL {
                Link(destination: website) { rowLink(website.host ?? company.domain, symbol: "link") }
            }
        } header: {
            Label("Company", systemImage: "building.2")
        }
    }

    /// A researched fact, shown only with the source that supports it.
    @ViewBuilder private func field(_ title: String, _ key: String, _ value: String?, _ profile: BackendSenderProfile) -> some View {
        let sources = profile.sources(for: key)
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !sources.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    citations(sources, in: profile)
                }
                Text(verbatim: value).textSelection(.enabled)
            }
        }
    }

    private func citations(_ sources: [BackendSenderProfile.Source], in profile: BackendSenderProfile) -> some View {
        HStack(spacing: 4) {
            ForEach(sources) { source in
                if let url = source.destination, let index = profile.publicSources.firstIndex(where: { $0.id == source.id }) {
                    Link("[\(index + 1)]", destination: url)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(palette.accent)
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Source: \(source.displayName)")
                }
            }
        }
    }

    private func rowLink(_ title: String, symbol: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(palette.accent).frame(width: 20)
            Text(title).foregroundStyle(.primary).lineLimit(2)
            Spacer(minLength: 0)
            Image(systemName: "arrow.up.right").font(.footnote).foregroundStyle(.tertiary)
        }
    }

    private func note(_ text: String, symbol: String) -> some View {
        Label {
            Text(text).font(.subheadline).foregroundStyle(.secondary)
        } icon: {
            Image(systemName: symbol).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func checked(_ date: Date?) -> some View {
        if let date { Text("Checked \(date.formatted(date: .abbreviated, time: .shortened))") }
    }

    private func activitySymbol(_ kind: String) -> String {
        switch kind {
        case "talk", "podcast": "bubble.left.and.bubble.right"
        case "article", "post": "doc.text"
        case "project": "chevron.left.forwardslash.chevron.right"
        case "news": "newspaper"
        default: "link"
        }
    }

    private func linkSymbol(_ label: String) -> String {
        switch label.lowercased() {
        case "linkedin": "person.crop.rectangle"
        case "x", "twitter": "at"
        case "github": "chevron.left.forwardslash.chevron.right"
        default: "link"
        }
    }

    // MARK: Actions

    private func load(_ lookup: Lookup) async {
        guard !message.isOutgoing, let target else { return }
        await research.load(target: target, refresh: lookup.refresh) { messageID, input in
            try await runtime.backend.request(SenderProfileRequest.method, SenderProfileRequest.path(messageID: messageID), body: input)
        }
    }

    private func enable() {
        isEnabling = true
        enableError = nil
        Task {
            defer { isEnabling = false }
            do {
                let settings: MailAISettings = try await runtime.backend.request("GET", "/v1/ai/settings")
                if !settings.enabled {
                    let _: MailAISettings = try await runtime.backend.request(
                        "PUT", "/v1/ai/settings", body: MailAISettingsInput(enabled: true, styleGuide: settings.styleGuide))
                }
                lookup = Lookup(refresh: true)
            } catch {
                enableError = error.localizedDescription
            }
        }
    }

    /// Opens the composer to the sender with the AI writer already drafting a first message.
    private func draftIntro(_ profile: BackendSenderProfile) {
        dismiss()
        store.beginCompose(account: message.mailAccount.isConnected ? message.mailAccount : nil)
        store.draftTo = message.senderEmail
        store.pendingWriterPrompt = profile.introPrompt(fallbackName: displayName)
    }

    private func action(_ title: String, symbol: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 17))
                Text(title).font(.caption.weight(.semibold))
            }
            .frame(width: 84, height: 56)
            .foregroundStyle(palette.accent)
            .background(Mobile.raised, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Suggested next steps

/// The assistant reviews the conversation and proposes reply, archive or follow-up.
struct MobileSuggestionsSheet: View {
    let runtime: MailRuntime
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var run: MailSuggestionRun
    @State private var applied: [Int: () -> Void] = [:]
    @State private var dismissed: Set<Int> = []

    init(runtime: MailRuntime, messages: [MailMessage]) {
        self.runtime = runtime
        let scope = runtime.backend.scope
        let ids = Array(Set(messages.filter { $0.mailAccount.remote?.scope == scope }.compactMap(\.backendMessageID)))
        _run = State(initialValue: MailSuggestionRun(sourceIDs: Array(ids.prefix(30))))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch run.phase {
                    case .consent:
                        Text(run.settings?.dataNotice ?? "").font(.subheadline).foregroundStyle(.secondary)
                        Button("Enable AI and Review") { run.start(enabling: true) }
                            .buttonStyle(.glassProminent)
                            .tint(palette.accent)
                    case .failed(let message, let canRetry):
                        Text(message).font(.subheadline).foregroundStyle(.secondary)
                        if canRetry { Button("Try Again", action: rerun).buttonStyle(.glass) }
                    case .loading, .streaming, .ready:
                        if run.overview.isEmpty && run.phase != .ready {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("Reading the conversation…").foregroundStyle(.secondary)
                            }
                            .font(.subheadline)
                        }
                        if !run.overview.isEmpty {
                            Text(verbatim: run.overview)
                                .font(.system(size: 16))
                                .lineSpacing(2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(run.items.indices.filter { !dismissed.contains($0) }, id: \.self) { index in
                            card(index)
                                .transition(.move(edge: .bottom).combined(with: .opacity))
                        }
                        if run.phase == .ready && !run.isRevealing {
                            if run.items.indices.allSatisfy({ dismissed.contains($0) }) {
                                Label("Nothing needs doing here.", systemImage: "checkmark.circle")
                                    .foregroundStyle(.secondary)
                            }
                            Text("Suggestions can be wrong. Nothing changes until you apply one.")
                                .font(.footnote)
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
                .padding(Mobile.gutter)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle("Next steps")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Run again", systemImage: "arrow.clockwise", action: rerun)
                        .disabled(run.phase == .loading || run.phase == .streaming)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
            .task(id: run.requestID) { await run.load(session: runtime.backend) }
        }
        .presentationDetents([.medium, .large])
    }

    private func card(_ index: Int) -> some View {
        let item = run.items[index]
        let done = applied[index] != nil
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: done ? "checkmark" : symbol(item))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(done ? .white : palette.accent)
                .frame(width: 34, height: 34)
                .background(done ? palette.accent : palette.accent.opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 4) {
                Text(done ? appliedTitle(item) : title(item)).font(.subheadline.weight(.semibold))
                if !done { Text(verbatim: item.text).font(.footnote).foregroundStyle(.secondary) }
                HStack(spacing: 8) {
                    if done {
                        Button("Undo") { withAnimation(.snappy) { applied.removeValue(forKey: index)?() } }
                    } else {
                        Button("Apply") { withAnimation(.snappy) { apply(index) } }
                            .buttonStyle(.glassProminent)
                            .tint(palette.accent)
                            .disabled(run.phase != .ready || localMessage(for: item) == nil)
                        Button("Dismiss") { withAnimation(.snappy) { _ = dismissed.insert(index) } }
                            .buttonStyle(.glass)
                    }
                }
                .font(.footnote.weight(.semibold))
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .background(Mobile.raised, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private func rerun() {
        withAnimation(.snappy) {
            applied = [:]
            dismissed = []
            run.start()
        }
    }

    private func symbol(_ item: MailAIItem) -> String {
        switch item.action {
        case "archive": "archivebox"
        case "follow_up": "bell"
        default: "arrowshape.turn.up.left"
        }
    }

    private func title(_ item: MailAIItem) -> String {
        switch item.action {
        case "archive": "Archive this conversation"
        case "follow_up": item.dueAt.map { "Follow up \($0.mobileScheduleLabel)" } ?? "Set a follow-up"
        default: "Add to Needs Reply"
        }
    }

    private func appliedTitle(_ item: MailAIItem) -> String {
        switch item.action {
        case "archive": "Archived"
        case "follow_up": "Follow-up set"
        default: "Added to Needs Reply"
        }
    }

    private func localMessage(for item: MailAIItem) -> MailMessage? {
        guard let targetID = item.messageId, item.sourceIds.contains(targetID) else { return nil }
        let scope = runtime.backend.scope
        return runtime.store.messages.first { $0.backendMessageID == targetID && $0.mailAccount.remote?.scope == scope }
    }

    private func apply(_ index: Int) {
        let item = run.items[index]
        guard applied[index] == nil, let message = localMessage(for: item) else { return }
        let store = runtime.store
        switch item.action {
        case "needs_reply":
            store.setNeedsReply(true, for: message.id)
            applied[index] = { store.setNeedsReply(message.needsReply, for: message.id) }
        case "archive":
            store.moveMessages([message.id], to: .archive)
            applied[index] = { store.moveMessages([message.id], to: message.mailbox) }
        case "follow_up":
            guard let date = item.dueAt else { return }
            store.setFollowUp(message.id, at: date, onlyIfNoReply: true)
            applied[index] = {
                if let previous = message.workflow.followUpAt {
                    store.setFollowUp(message.id, at: previous, onlyIfNoReply: message.workflow.followUpOnlyIfNoReply)
                } else {
                    store.clearFollowUp(message.id)
                }
            }
        default:
            return
        }
    }
}

// MARK: - Share with the team

/// Shares a snapshot of the conversation with workspace members, each with view or comment access.
struct MobileShareSheet: View {
    let runtime: MailRuntime
    let message: MailMessage
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var members: [WorkspaceMember]?
    @State private var permissions: [UUID: String] = [:]
    @State private var error: String?
    @State private var saving = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(message.displaySubject).font(.headline)
                } footer: {
                    Text("Members see a snapshot. Bcc recipients and attachment contents stay private. Share again to include later messages.")
                }
                if let members {
                    if members.isEmpty {
                        Text("No other workspace members yet.").foregroundStyle(.secondary)
                    } else {
                        Section("Members") {
                            ForEach(members) { member in
                                Picker(selection: Binding(get: { permissions[member.userId] ?? "none" },
                                                          set: { permissions[member.userId] = $0 })) {
                                    Text("No access").tag("none")
                                    Text("View").tag("view")
                                    Text("Comment & reply").tag("comment")
                                } label: {
                                    HStack(spacing: 10) {
                                        ParticipantPhoto(address: member.email, name: "", size: 30)
                                        Text(member.email).lineLimit(1)
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                        }
                    }
                } else if error == nil {
                    HStack { Spacer(); ProgressView(); Spacer() }.listRowBackground(Color.clear)
                }
                if let error {
                    Text(error).foregroundStyle(PostmereTheme.destructiveInk)
                }
            }
            .tint(palette.accent)
            .navigationTitle("Share with Team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", systemImage: "xmark") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else {
                        Button("Share") { Task { await save() } }
                            .fontWeight(.semibold)
                            .disabled(!permissions.values.contains { $0 != "none" })
                    }
                }
            }
            .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    private func load() async {
        do {
            let response: WorkspaceMembers = try await runtime.backend.request("GET", "/v1/workspace/members")
            members = response.members.filter { $0.userId != runtime.backend.credential?.userID }
        } catch { self.error = error.localizedDescription }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let selected = (members ?? []).compactMap { member -> SharedMemberInput? in
            guard let permission = permissions[member.userId], permission != "none" else { return nil }
            return SharedMemberInput(userId: member.userId, permission: permission)
        }
        do {
            guard let identity = message.mailAccount.remote, identity.scope == runtime.backend.scope,
                  let thread = message.providerThreadID else { throw BackendError.notConnected }
            let _: SharedThread = try await runtime.backend.request(
                "POST", "/v1/shared/threads",
                body: ShareThreadInput(accountId: identity.accountID, providerThreadId: thread, members: selected))
            runtime.store.lastAction = "Conversation shared"
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
