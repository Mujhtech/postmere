import SwiftUI
import AppKit

struct CalendarHomeView: View {
    let runtime: MailRuntime
    @State private var selection = 0
    var body: some View {
        VStack(spacing: 0) {
            Picker("Calendar", selection: $selection) {
                Text("On this Mac").tag(0)
                Text("Booking links").tag(1)
                Text("Team availability").tag(2)
            }.pickerStyle(.segmented).labelsHidden().padding(20)
            if selection == 0 { CalendarAgendaView() }
            else { WorkspaceCalendarPanel(session: runtime.backend, selection: selection) }
        }.tint(PostmereTheme.accent)
    }
}

private struct WorkspaceCalendarPanel: View {
    let session: BackendSession
    let selection: Int
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(selection == 1 ? "Booking links" : "Team availability").font(PostmereTheme.sheetTitle)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(22)
            Divider()
            if session.isConnected {
                if selection == 1 { BookingLinksView(session: session) }
                else { SharedAvailabilityView(session: session) }
            } else {
                ContentUnavailableView {
                    PostmereLabel("Connect your workspace", symbol: "calendar", size: 36)
                } description: { Text("Sign in in Settings → Accounts to use booking links and shared availability.") }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(width: 680, height: 540)
    }
}

struct BookingLinksView: View {
    let session: BackendSession
    var onInsert: ((String) -> Void)?
    @State private var links: [BookingLink] = []
    @State private var bookings: [CalendarBooking] = []
    @State private var showsCreate = false
    @State private var error: String?
    @State private var notice: String?
    @State private var disabling: BookingLink?
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Availability is checked when your guest opens and books a time.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Create Link…") { showsCreate = true }
                    .disabled(!session.accounts.contains { $0.status == "connected" && $0.capabilities?.contains("calendar") == true })
            }.padding(18)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if links.isEmpty {
                        Text("Offer a few times, then share one link. Enable calendar access in Settings → Accounts to get started.")
                            .font(.system(size: 13)).foregroundStyle(.secondary)
                    }
                    ForEach(links) { link in
                        VStack(alignment: .leading, spacing: 9) {
                            HStack {
                                Text(link.title).font(.system(size: 14, weight: .semibold))
                                Spacer()
                                Text("\(link.durationMinutes) min").font(.caption).foregroundStyle(.secondary)
                            }
                            Text("\(link.slots.count) offered times · \(link.timeZone)").font(.caption).foregroundStyle(.secondary)
                            if link.disabledAt != nil || link.expiresAt <= .now { Text("Link inactive").font(.caption).foregroundStyle(.secondary) }
                            else {
                                HStack {
                                    if let onInsert { Button("Insert Link") { onInsert("\(link.title): \(link.url)") } }
                                    Button("Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(link.url, forType: .string); notice = "Booking link copied." }
                                    Button("Open Page") { if let url = safeURL(link.url) { NSWorkspace.shared.open(url) } }
                                        .disabled(safeURL(link.url) == nil)
                                    Spacer()
                                    Button("Disable", role: .destructive) { disabling = link }
                                }.controlSize(.small)
                            }
                        }.padding(16).background(PostmereTheme.subtleFill, in: .rect(cornerRadius: PostmereTheme.cardRadius))
                    }
                    if !bookings.isEmpty {
                        Text("Bookings").font(.headline).padding(.top, 8)
                        ForEach(bookings) { booking in
                            VStack(alignment: .leading, spacing: 5) {
                                HStack { Text(booking.guestName).fontWeight(.medium); Spacer(); Text(booking.status.capitalized).foregroundStyle(.secondary) }
                                Text(booking.guestEmail).foregroundStyle(.secondary)
                                Text(booking.start, format: .dateTime.month(.abbreviated).day().hour().minute())
                                if booking.status == "uncertain" {
                                    Text("The provider did not confirm the result. This time remains reserved; check your provider calendar before arranging another meeting.")
                                        .foregroundStyle(.secondary)
                                }
                            }.font(.system(size: 12)).padding(.vertical, 6)
                        }
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    if let notice { Text(notice).font(.caption).foregroundStyle(PostmereTheme.accentInk) }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }.scrollIndicators(.never)
        }.task(id: session.scope) {
            links = []; bookings = []; error = nil; notice = nil; disabling = nil
            if session.isConnected { await load() }
        }
            .sheet(isPresented: $showsCreate, onDismiss: { Task { await load() } }) { CreateBookingLinkView(session: session) }
            .confirmationDialog("Disable this booking link?", isPresented: Binding(get: { disabling != nil }, set: { if !$0 { disabling = nil } }), titleVisibility: .visible) {
                if let link = disabling { Button("Disable Link", role: .destructive) { Task { await disable(link) } } }
            } message: { Text("The link will stop accepting new bookings. Existing calendar events remain.") }
    }
    private func safeURL(_ text: String) -> URL? {
        guard let url = URL(string: text), let connectedURL = session.credential?.baseURL,
              let origin = URL(string: connectedURL),
              url.scheme?.lowercased() == origin.scheme?.lowercased(), url.host?.lowercased() == origin.host?.lowercased(),
              (url.port ?? (url.scheme == "https" ? 443 : 80)) == (origin.port ?? (origin.scheme == "https" ? 443 : 80)),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.hasPrefix("/book/") else { return nil }
        return url
    }
    private func load() async {
        let scope = session.scope
        do {
            let response: BookingLinks = try await session.request("GET", "/v1/calendar/booking-links")
            let history: CalendarBookings = try await session.request("GET", "/v1/calendar/bookings")
            guard session.scope == scope else { return }
            links = response.items; bookings = history.items; error = nil
        } catch { if session.scope == scope { self.error = error.localizedDescription } }
    }
    private func disable(_ link: BookingLink) async {
        do { let _: BackendEmpty = try await session.request("DELETE", "/v1/calendar/booking-links/\(link.id.uuidString)"); await load() }
        catch { self.error = error.localizedDescription }
    }
}

private struct CreateBookingLinkView: View {
    let session: BackendSession
    @Environment(\.dismiss) private var dismiss
    @State private var accountID: UUID?
    @State private var title = "Meet with me"
    @State private var duration = 30
    @State private var nextTime = Date.now.addingTimeInterval(86_400)
    @State private var times: [Date] = []
    @State private var expiry = Date.now.addingTimeInterval(7 * 86_400)
    @State private var busy = false
    @State private var error: String?
    private var accounts: [BackendAccount] { session.accounts.filter { $0.status == "connected" && $0.capabilities?.contains("calendar") == true } }
    private var offeredStart: Date { Calendar.current.dateInterval(of: .minute, for: nextTime)?.start ?? nextTime }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create booking link").font(PostmereTheme.sheetTitle)
            Form {
                Picker("Calendar account", selection: $accountID) {
                    Text("Choose account").tag(Optional<UUID>.none)
                    ForEach(accounts) { Text($0.email).tag(Optional($0.id)) }
                }
                TextField("Meeting title", text: $title)
                Picker("Duration", selection: $duration) {
                    ForEach([15, 30, 45, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                }
                DatePicker("Link expires", selection: $expiry, in: Date.now...Date.now.addingTimeInterval(90 * 86_400))
                LabeledContent("Time zone", value: TimeZone.current.identifier)
            }.disabled(busy)
            HStack {
                DatePicker("Offer a time", selection: $nextTime,
                           in: Date.now.addingTimeInterval(5 * 60)...Date.now.addingTimeInterval(90 * 86_400 - Double(duration) * 60))
                Button("Add") {
                    let time = offeredStart
                    if !times.contains(time) { times.append(time); times.sort() }
                }.disabled(times.count >= 100 || offeredStart <= Date.now.addingTimeInterval(5 * 60) || times.contains(offeredStart))
            }.disabled(busy)
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(times, id: \.self) { time in
                        HStack {
                            Text(time, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day().hour().minute())
                            Spacer()
                            Button { times.removeAll { $0 == time } } label: { PostmereIcon("xmark", size: 11) }.buttonStyle(.borderless).help("Remove time").disabled(busy)
                        }.font(.system(size: 12))
                    }
                }
            }.scrollIndicators(.never).frame(height: 120)
            Text("Checks your primary provider calendar. Anyone with the link can book one of these times; the page shows the meeting title. Existing busy times are excluded automatically.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(busy ? "Creating…" : "Create Link") { Task { await create() } }
                    .buttonStyle(.borderedProminent).disabled(busy || accountID == nil || times.isEmpty || title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.padding(24).frame(width: 570)
            .onAppear { accountID = accounts.first?.id }
    }
    private func create() async {
        guard !busy else { return }
        guard let accountID, accounts.contains(where: { $0.id == accountID }) else {
            error = "Choose a connected account with calendar access."; return
        }
        let now = Date.now
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTitle.isEmpty, cleanedTitle.unicodeScalars.count <= 160,
              !cleanedTitle.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            error = "Use a meeting title of 1–160 characters on one line."; return
        }
        guard !times.isEmpty, times.count <= 100,
              times.allSatisfy({ $0 > now.addingTimeInterval(5 * 60) && $0.addingTimeInterval(Double(duration) * 60) <= now.addingTimeInterval(90 * 86_400) }) else {
            error = "Offer times at least five minutes ahead, with each meeting ending within the next 90 days."; return
        }
        guard expiry > now, expiry <= now.addingTimeInterval(90 * 86_400), times.allSatisfy({ $0 < expiry }) else {
            error = "Set the link’s expiry after its offered times and within the next 90 days."; return
        }
        busy = true; error = nil
        defer { busy = false }
        do {
            let _: BookingLink = try await session.request("POST", "/v1/calendar/booking-links", body:
                BookingLinkInput(accountId: accountID, title: cleanedTitle, description: "", timeZone: TimeZone.current.identifier,
                    durationMinutes: duration, expiresAt: expiry,
                    slots: times.map { BookingSlotInput(start: $0, end: $0.addingTimeInterval(Double(duration) * 60)) }))
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

private struct SharedAvailabilityView: View {
    let session: BackendSession
    @State private var calendars: [SharedCalendar] = []
    @State private var selected: Set<UUID> = []
    @State private var day = Date.now
    @State private var result: FreeBusyResult?
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Shares busy times from your primary calendar with this workspace. Event names and attendees remain private.").font(.caption).foregroundStyle(.secondary)
                ForEach(calendars.filter(\.isMine)) { calendar in
                    Toggle("Share busy times · \(calendar.email)", isOn: Binding(get: { calendar.enabled }, set: { value in Task { await share(calendar, enabled: value) } }))
                        .font(.system(size: 12)).disabled(busy)
                }
                Divider()
                Text("Check availability · up to 8 calendars").font(.headline)
                ForEach(calendars) { calendar in
                    Toggle(calendar.email, isOn: Binding(get: { selected.contains(calendar.id) }, set: { value in if value { selected.insert(calendar.id) } else { selected.remove(calendar.id) }; result = nil }))
                        .font(.system(size: 12)).disabled(busy || (!selected.contains(calendar.id) && selected.count >= 8))
                }
                HStack {
                    DatePicker("Day", selection: $day,
                               in: Calendar.current.startOfDay(for: .now)...(Calendar.current.date(byAdding: .day, value: 365, to: .now) ?? Date.now.addingTimeInterval(365 * 86_400)),
                               displayedComponents: .date).disabled(busy)
                    Spacer()
                    Button("Check") { Task { await check() } }.disabled(busy || selected.isEmpty)
                }
                if let result {
                    ForEach(result.calendars) { calendar in
                        VStack(alignment: .leading, spacing: 7) {
                            Text(calendars.first { $0.id == calendar.id }?.email ?? "Calendar").font(.subheadline.weight(.medium))
                            if calendar.busy.isEmpty { Text("No busy times on this primary calendar.").font(.caption).foregroundStyle(.secondary) }
                            ForEach(Array(calendar.busy.enumerated()), id: \.offset) { _, interval in
                                Text("Busy · \(interval.start.formatted(date: .omitted, time: .shortened))–\(interval.end.formatted(date: .omitted, time: .shortened))")
                                    .font(.system(size: 12))
                            }
                        }
                    }
                }
                if calendars.isEmpty { Text("Connect an account with calendar access or ask a teammate to share their availability.").font(.caption).foregroundStyle(.secondary) }
                if let error { Text(error).font(.caption).foregroundStyle(.red) }
            }.padding(22).frame(maxWidth: .infinity, alignment: .leading)
        }.scrollIndicators(.never).task(id: session.scope) {
            calendars = []; selected = []; result = nil; error = nil
            if session.isConnected { await load() }
        }.onChange(of: day) { result = nil }
    }
    private func load() async {
        let scope = session.scope
        do {
            let response: SharedCalendars = try await session.request("GET", "/v1/calendar/sharing")
            guard session.scope == scope else { return }
            calendars = response.items; selected.formIntersection(Set(calendars.map(\.id))); result = nil; error = nil
        } catch { if session.scope == scope { self.error = error.localizedDescription } }
    }
    private func share(_ calendar: SharedCalendar, enabled: Bool) async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        do { let _: BackendEmpty = try await session.request("PUT", "/v1/calendar/sharing/\(calendar.id.uuidString)", body: CalendarSharingInput(enabled: enabled)); await load() }
        catch { self.error = error.localizedDescription }
    }
    private func check() async {
        guard !busy, !selected.isEmpty, selected.count <= 8 else { return }
        busy = true; error = nil; result = nil
        defer { busy = false }
        let scope = session.scope
        let requestedCalendars = selected
        let start = Calendar.current.startOfDay(for: day)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return }
        do {
            let response: FreeBusyResult = try await session.request("POST", "/v1/calendar/free-busy", body: FreeBusyInput(accountIds: Array(requestedCalendars), start: start, end: end))
            guard session.scope == scope, selected == requestedCalendars, Calendar.current.startOfDay(for: day) == start else { return }
            result = response
        } catch { if session.scope == scope { self.error = error.localizedDescription } }
    }
}
