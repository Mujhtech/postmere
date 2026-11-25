import SwiftUI

/// Public sender information stays beside the conversation, including when the
/// user explicitly reveals it in a narrow window. This view never presents UI.
struct SenderContextView: View {
    let message: MailMessage
    let target: SenderProfileTarget?
    let research: MailSenderProfile
    let onRefresh: () -> Void
    let onClose: () -> Void
    var onEnable: () -> Void = {}
    var isEnabling = false
    var enableError: String?
    /// Your history with this person, from your own mail.
    var relationship: MailRelationship?
    var onOpenMessage: (UUID) -> Void = { _ in }
    /// Starts a new message to the sender with an AI instruction.
    var onDraftIntro: ((String) -> Void)?
    @Environment(\.mailboxInset) private var inset
    @Environment(\.postmereAccent) private var palette
    @Environment(\.openSettings) private var openSettings
    @AppStorage("settingsTab") private var settingsTab = "general"

    private var isLoading: Bool {
        guard research.target == target else { return target != nil }
        if case .loading = research.phase { return true }
        return false
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("Sender details").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 4)
                Button(action: onRefresh) { PostmereIcon("arrow.clockwise", size: 13) }
                    .help("Refresh sender details").accessibilityLabel("Refresh sender details")
                    .disabled(target == nil || isLoading || isEnabling)
                Button(action: onClose) { PostmereIcon("sidebar.right", size: 15) }
                    .help("Hide sender details").accessibilityLabel("Hide sender details")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 18).padding(.vertical, 15)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(message.isOutgoing ? "You" : message.sender.isEmpty ? message.senderEmail : message.sender)
                            .font(.system(size: 17, weight: .semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(verbatim: message.senderEmail)
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Text("From this message").font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                    Divider()
                    if let relationship, !relationship.isEmpty {
                        history(relationship)
                        Divider()
                    }
                    if target == nil {
                        stateMessage("Sender research unavailable", detail: message.isOutgoing
                            ? "Choose an incoming message to see its sender’s public details."
                            : "Connect this message’s account to look up public sender details.", symbol: "person.crop.rectangle")
                    } else if research.target != target {
                        loading
                    } else {
                        switch research.phase {
                        case .idle, .loading: loading
                        case .failed(let error):
                            stateMessage("Couldn’t load sender details", detail: error, symbol: "exclamationmark.circle")
                            Button("Try Again", action: onRefresh).controlSize(.small)
                        case .loaded(let response):
                            result(response)
                        }
                    }
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(inset)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sender details")
    }
    private var loading: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) { ProgressView().controlSize(.small); Text("Finding public details…").font(.system(size: 12, weight: .medium)) }
            Text("Looking for professional information and public profiles.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    private func stateMessage(_ title: String, detail: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            PostmereIcon(symbol, size: 23).foregroundStyle(.secondary).padding(.bottom, 2)
            Text(title).font(.system(size: 13, weight: .semibold))
            Text(detail).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
    @ViewBuilder private func result(_ response: BackendSenderProfileResponse) -> some View {
        switch response.status {
        case .matched:
            if let profile = response.profile {
                VStack(alignment: .leading, spacing: 17) {
                    if profile.hasPerson {
                        HStack(spacing: 6) {
                            PostmereIcon("sparkles", size: 12)
                            Text("Public profile").font(.system(size: 11, weight: .medium))
                        }.foregroundStyle(palette.accentInk)
                    }
                    if let zone = profile.localTimeZone {
                        localTime(zone)
                    }
                    profileField("Name", field: "name", value: profile.name, profile: profile)
                    profileField("Role", field: "job_title", value: profile.jobTitle, profile: profile)
                    profileField("Company", field: "company", value: profile.company, profile: profile)
                    profileField("Location", field: "location", value: profile.location, profile: profile)
                    profileField("About", field: "bio", value: profile.bio, profile: profile)
                    if !profile.publicLinks.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                fieldTitle("Online")
                                citations(profile.sources(for: "links"), in: profile)
                            }
                            ForEach(profile.publicLinks) { item in
                                if let url = item.destination {
                                    Link(destination: url) {
                                        HStack(spacing: 7) {
                                            PostmereIcon(linkSymbol(item.label), size: 12)
                                            Text(item.label.isEmpty ? url.host ?? "Website" : item.label).lineLimit(2)
                                            Spacer(minLength: 0)
                                            PostmereIcon("arrow.up.right", size: 10)
                                        }.font(.system(size: 12))
                                    }.foregroundStyle(palette.accentInk).help(url.absoluteString)
                                }
                            }
                        }
                    }
                    if !profile.publicActivity.isEmpty {
                        activity(profile.publicActivity, in: profile)
                    }
                    if !profile.publicTalkingPoints.isEmpty {
                        talkingPoints(profile.publicTalkingPoints, in: profile)
                    }
                    if let company = profile.publicCompany {
                        if profile.hasPerson { Divider() }
                        companySection(company, in: profile)
                    }
                    if let onDraftIntro, !message.isOutgoing {
                        Button { onDraftIntro(profile.introPrompt(fallbackName: message.sender.isEmpty ? message.senderEmail : message.sender)) } label: {
                            Label("Draft intro", systemImage: "square.and.pencil")
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Write a first message using these details. You review it before sending.")
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Divider().padding(.bottom, 4)
                    fieldTitle("Sources")
                    ForEach(Array(profile.publicSources.enumerated()), id: \.element.id) { index, source in
                        if let url = source.destination {
                            Link(destination: url) {
                                Text("[\(index + 1)] \(source.displayName)").font(.system(size: 11)).multilineTextAlignment(.leading)
                            }.foregroundStyle(palette.accentInk).help(url.absoluteString)
                        }
                    }
                    Text("AI-researched public information. A profile match does not verify the sender’s identity.")
                        .font(.system(size: 10)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    checkedDate(response.checkedAt)
                }
            }
        case .notFound:
            stateMessage("No clear public match", detail: "There isn’t enough public information to confidently connect this address to a professional profile.", symbol: "person.crop.rectangle")
            checkedDate(response.checkedAt)
        case .disabled:
            stateMessage("Enable sender research", detail: "AI assistance researches public sources using the sender’s name and email address. Message content is not included.", symbol: "sparkles")
            Button(isEnabling ? "Enabling…" : "Enable AI & Find Details", action: onEnable)
                .controlSize(.small).buttonStyle(.borderedProminent).disabled(isEnabling)
            Button("AI Settings") { settingsTab = "ai"; openSettings() }.controlSize(.small)
            if let enableError { Text(enableError).font(.system(size: 11)).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
        case .unconfigured:
            stateMessage("Sender research isn’t available", detail: "AI assistance needs to be configured for this workspace. Ask your workspace administrator to enable it.", symbol: "sparkles")
        }
    }
    @ViewBuilder private func profileField(_ title: String, field: String, value: String?, profile: BackendSenderProfile) -> some View {
        // Never display a researched fact without its supporting inline citation.
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !profile.sources(for: field).isEmpty {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 5) {
                    fieldTitle(title)
                    citations(profile.sources(for: field), in: profile)
                }
                Text(verbatim: value).font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    private func fieldTitle(_ title: String) -> some View {
        Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
    }
    private func citations(_ sources: [BackendSenderProfile.Source], in profile: BackendSenderProfile) -> some View {
        HStack(spacing: 4) {
            ForEach(sources) { source in
                if let url = source.destination, let index = profile.publicSources.firstIndex(where: { $0.id == source.id }) {
                    Link("[\(index + 1)]", destination: url)
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(palette.accentInk)
                        .help(source.displayName).accessibilityLabel("Source: \(source.displayName)")
                }
            }
        }
    }
    @ViewBuilder private func checkedDate(_ date: Date?) -> some View {
        if let date {
            Text("Checked \(date.formatted(date: .abbreviated, time: .shortened))")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }
    // MARK: Your history

    private func history(_ history: MailRelationship) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                PostmereIcon("bubble.left.and.bubble.right", size: 12)
                Text("Your history").font(.system(size: 11, weight: .medium))
            }.foregroundStyle(palette.accentInk)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 9) {
                if let first = history.firstContact {
                    fact("Since", first.formatted(.dateTime.month(.abbreviated).year()),
                         history.lastContact.map { "Last \($0.formatted(.relative(presentation: .named)))" })
                }
                fact("Messages", "\(history.fromThem) from them · \(history.fromYou) from you",
                     history.conversations == 1 ? "1 conversation" : "\(history.conversations) conversations")
                if let time = history.theirReplyTime {
                    fact("They reply", MailRelationship.duration(time), nil)
                }
                if let time = history.yourReplyTime {
                    fact("You reply", MailRelationship.duration(time), nil)
                }
                if let hour = history.usualHour {
                    fact("Usually writes", MailRelationship.window(from: hour), "Your time. A good moment to reach them.")
                }
                if let subject = history.lastSubject {
                    fact("Last topic", subject, nil)
                }
            }
            waiting("Waiting on you", history.waitingOnYou)
            waiting("Waiting on them", history.waitingOnThem)
            Text("From your own mail on this Mac.")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
    }

    private func fact(_ title: String, _ value: String, _ detail: String?) -> some View {
        GridRow {
            fieldTitle(title)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: value).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder private func waiting(_ title: String, _ threads: [MailRelationship.Thread]) -> some View {
        if !threads.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                fieldTitle("\(title) · \(threads.count)")
                ForEach(threads.prefix(3)) { thread in
                    Button { onOpenMessage(thread.messageID) } label: {
                        HStack(spacing: 6) {
                            Text(verbatim: thread.subject).lineLimit(1)
                            Spacer(minLength: 4)
                            Text(thread.date.formatted(.relative(presentation: .named)))
                                .foregroundStyle(.secondary).fixedSize()
                        }
                        .font(.system(size: 12))
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(palette.accentInk)
                    .help("Open “\(thread.subject)”")
                }
            }
        }
    }

    // MARK: Public research

    private func localTime(_ zone: TimeZone) -> some View {
        TimelineView(.everyMinute) { context in
            let time = context.date.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))
            let offset = (zone.secondsFromGMT(for: context.date) - TimeZone.current.secondsFromGMT(for: context.date)) / 3_600
            HStack(spacing: 6) {
                PostmereIcon("clock", size: 12).foregroundStyle(.secondary)
                Text("\(time) their time").font(.system(size: 12.5, weight: .medium))
                if offset != 0 {
                    Text(offset > 0 ? "\(offset)h ahead" : "\(-offset)h behind")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func activity(_ items: [BackendSenderProfile.Activity], in profile: BackendSenderProfile) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            fieldTitle("Recent activity")
            ForEach(items) { item in
                if let url = item.destination {
                    Link(destination: url) {
                        HStack(alignment: .firstTextBaseline, spacing: 7) {
                            PostmereIcon(activitySymbol(item.kind), size: 11).foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: item.title).font(.system(size: 12)).foregroundStyle(.primary)
                                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                Text([item.kind.capitalized, item.displayDate, url.host].compactMap { $0 }.joined(separator: " · "))
                                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(.rect)
                    }
                    .help(url.absoluteString)
                }
            }
        }
    }

    private func talkingPoints(_ points: [BackendSenderProfile.TalkingPoint], in profile: BackendSenderProfile) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            fieldTitle("Talking points")
            ForEach(points) { point in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(palette.accentInk).frame(width: 4, height: 4).offset(y: -2)
                    Text(verbatim: point.text).font(.system(size: 12)).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    citations(profile.publicSources.filter { $0.url == point.sourceUrl }, in: profile)
                }
            }
        }
    }

    private func companySection(_ company: BackendSenderProfile.Company, in profile: BackendSenderProfile) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                PostmereIcon("building.2", size: 12)
                Text("Company").font(.system(size: 11, weight: .medium))
                citations(profile.publicSources.filter { company.sourceUrls.contains($0.url) }, in: profile)
            }.foregroundStyle(palette.accentInk)
            VStack(alignment: .leading, spacing: 3) {
                Text(verbatim: company.name).font(.system(size: 14, weight: .semibold))
                if let summary = company.summary {
                    Text(verbatim: summary).font(.system(size: 12.5)).foregroundStyle(.secondary)
                        .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
            }
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 7) {
                ForEach([("Industry", company.industry), ("Size", company.size), ("Funding", company.funding),
                         ("Based in", company.headquarters)], id: \.0) { title, value in
                    if let value {
                        GridRow {
                            fieldTitle(title)
                            Text(verbatim: value).font(.system(size: 12.5)).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
            if company.hiring != nil || company.careersURL != nil {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text(verbatim: company.hiring ?? "Careers page").font(.system(size: 12.5))
                        .fixedSize(horizontal: false, vertical: true)
                    if let careers = company.careersURL {
                        Link(destination: careers) { PostmereIcon("arrow.up.right", size: 10) }
                            .foregroundStyle(palette.accentInk).help(careers.absoluteString)
                            .accessibilityLabel("Open careers page")
                    }
                }
            }
            if !company.news.isEmpty {
                VStack(alignment: .leading, spacing: 7) {
                    fieldTitle("In the news")
                    ForEach(company.news) { item in
                        if let url = item.destination {
                            Link(destination: url) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: item.title).font(.system(size: 12)).foregroundStyle(.primary)
                                        .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
                                    Text([item.displayDate, url.host].compactMap { $0 }.joined(separator: " · "))
                                        .font(.system(size: 10.5)).foregroundStyle(.secondary)
                                }
                            }
                            .help(url.absoluteString)
                        }
                    }
                }
            }
            if let website = company.websiteURL {
                Link(destination: website) {
                    HStack(spacing: 6) {
                        PostmereIcon("link", size: 11)
                        Text(website.host ?? company.domain)
                    }.font(.system(size: 12))
                }
                .foregroundStyle(palette.accentInk)
            }
        }
    }

    private func activitySymbol(_ kind: String) -> String {
        switch kind {
        case "talk", "podcast": "bubble.left.and.bubble.right"
        case "article", "post": "doc.text"
        case "project": "chevron.left.forwardslash.chevron.right"
        case "news": "note.text"
        default: "link"
        }
    }

    private func linkSymbol(_ label: String) -> String {
        switch label.lowercased() {
        case "linkedin": "person.crop.rectangle"
        case "x", "twitter": "at"
        default: "link"
        }
    }
}
