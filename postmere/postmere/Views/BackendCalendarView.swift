import SwiftUI
import AppKit

struct CalendarHomeView: View {
    let runtime: MailRuntime
    @State private var selection = 0
    @State private var eventDraft: MailCalendarEventDraft?

    var body: some View {
        VStack(spacing: 0) {
            PostmereSheetHeader("Calendar") {
                if selection == 0 {
                    Button { eventDraft = MailCalendarEventDraft() } label: {
                        PostmereLabel("New Event", symbol: "plus", size: 14)
                    }
                }
            }
            Picker("Calendar", selection: $selection) {
                Text("On this Mac").tag(0)
                Text("Booking links").tag(1)
                Text("Team availability").tag(2)
            }.pickerStyle(.segmented).labelsHidden().padding(.horizontal, 24).padding(.bottom, 16)
            Divider()
            if selection == 0 {
                CalendarAgendaView()
            } else if runtime.backend.isConnected {
                if selection == 1 { BookingLinksView(session: runtime.backend) }
                else { SharedAvailabilityView(session: runtime.backend) }
            } else {
                ContentUnavailableView {
                    PostmereLabel.emptyState("Connect your workspace", symbol: "calendar", size: 36)
                } description: { Text("Sign in to use booking links and shared availability.") } actions: {
                    AccountSettingsButton()
                }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(width: 680, height: 590)
        .tint(PostmereTheme.accent)
        .sheet(item: $eventDraft) { CalendarEventDraftView(draft: $0) }
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
    @State private var cancelling: CalendarBooking?
    @State private var updatingBooking: UUID?
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
                            Text("\(link.slots.count) offered times · \(link.timeZone)\(link.availability == nil ? "" : " · Weekly hours")").font(.caption).foregroundStyle(.secondary)
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
                                HStack { Text(booking.guestName).fontWeight(.medium); Spacer(); Text(booking.statusLabel).foregroundStyle(.secondary) }
                                Text(booking.guestEmail).foregroundStyle(.secondary)
                                Text(booking.start, format: .dateTime.month(.abbreviated).day().hour().minute())
                                if ["uncertain", "cancel_uncertain"].contains(booking.status) {
                                    Text("This time remains reserved until the provider confirms the result. Checking status does not create another event.")
                                        .foregroundStyle(.secondary)
                                }
                                HStack {
                                    if ["uncertain", "cancel_uncertain", "creating", "cancelling"].contains(booking.status) {
                                        Button("Check Status") { Task { await updateBooking(booking, action: "reconcile") } }
                                    }
                                    if ["confirmed", "cancel_uncertain"].contains(booking.status) {
                                        Button(booking.status == "cancel_uncertain" ? "Retry Cancellation…" : "Cancel Booking…", role: .destructive) { cancelling = booking }
                                    }
                                    if updatingBooking == booking.id { ProgressView().controlSize(.small) }
                                }.controlSize(.small).disabled(updatingBooking != nil)
                            }.font(.system(size: 12)).padding(.vertical, 6)
                        }
                    }
                    if let error { Text(error).font(.caption).foregroundStyle(.red) }
                    if let notice { Text(notice).font(.caption).foregroundStyle(PostmereTheme.accentInk) }
                }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        }.task(id: session.scope) {
            links = []; bookings = []; error = nil; notice = nil; disabling = nil; cancelling = nil; updatingBooking = nil
            if session.isConnected { await load() }
        }
            .sheet(isPresented: $showsCreate, onDismiss: { Task { await load() } }) { CreateBookingLinkView(session: session) }
            .confirmationDialog("Disable this booking link?", isPresented: Binding(get: { disabling != nil }, set: { if !$0 { disabling = nil } }), titleVisibility: .visible) {
                if let link = disabling { Button("Disable Link", role: .destructive) { Task { await disable(link) } } }
            } message: { Text("The link will stop accepting new bookings. Existing calendar events remain.") }
            .confirmationDialog("Cancel this booking?", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }), titleVisibility: .visible) {
                if let booking = cancelling { Button("Cancel Booking", role: .destructive) { Task { await updateBooking(booking, action: "cancel") } } }
            } message: { Text("The calendar provider will cancel the event and notify its guest. The time becomes available after cancellation is confirmed.") }
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
    private func updateBooking(_ booking: CalendarBooking, action: String) async {
        guard updatingBooking == nil else { return }
        let scope = session.scope
        updatingBooking = booking.id; error = nil; notice = nil
        defer { if session.scope == scope { updatingBooking = nil } }
        do {
            let result: CalendarBookingResult = try await session.request("POST", "/v1/calendar/bookings/\(booking.id.uuidString)/\(action)")
            guard session.scope == scope else { return }
            notice = result.message
            await load()
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
    @State private var expiry = Date.now.addingTimeInterval(14 * 86_400)
    @State private var providerCalendars: [ProviderCalendar] = []
    @State private var targetCalendar = "primary"
    @State private var conflictCalendars: Set<String> = ["primary"]
    @State private var requiresReconnect = false
    @State private var loadingCalendars = false
    @State private var repeatsWeekly = false
    @State private var timeZone = TimeZone.current.identifier
    @State private var firstDay = Date.now.addingTimeInterval(86_400)
    @State private var lastDay = Date.now.addingTimeInterval(7 * 86_400)
    @State private var weekdays: Set<Int> = [1, 2, 3, 4, 5]
    @State private var startMinute = 9 * 60
    @State private var endMinute = 17 * 60
    @State private var busy = false
    @State private var error: String?
    private var accounts: [BackendAccount] { session.accounts.filter { $0.status == "connected" && $0.capabilities?.contains("calendar") == true } }
    private var selectedZone: TimeZone { TimeZone(identifier: timeZone) ?? .current }
    private var offeredStart: Date { Calendar.current.dateInterval(of: .minute, for: nextTime)?.start ?? nextTime }
    private var canCreate: Bool {
        !busy && !loadingCalendars && accountID != nil && providerCalendars.contains { $0.id == targetCalendar && $0.canWrite }
            && !conflictCalendars.isEmpty && (repeatsWeekly ? !weekdays.isEmpty : !times.isEmpty)
            && !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Create booking link").font(PostmereTheme.sheetTitle)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
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
                        TextField("Time zone", text: $timeZone).help("An IANA time zone, such as Africa/Lagos or America/New_York")
                        Picker("Create events in", selection: $targetCalendar) {
                            ForEach(providerCalendars.filter(\.canWrite)) { Text($0.name).tag($0.id) }
                        }.disabled(loadingCalendars || providerCalendars.isEmpty)
                    }
                    if loadingCalendars { ProgressView("Loading calendars…").controlSize(.small) }
                    if requiresReconnect {
                        Text("Your primary calendar is available. Reconnect calendar access in Settings → Accounts to choose additional calendars.").font(.caption).foregroundStyle(.secondary)
                    }
                    if !providerCalendars.isEmpty {
                        Text("Check conflicts in").font(.subheadline.weight(.medium))
                        ForEach(providerCalendars) { calendar in
                            Toggle(calendar.name, isOn: Binding(get: { conflictCalendars.contains(calendar.id) }, set: { selected in
                                if selected { conflictCalendars.insert(calendar.id) } else if calendar.id != targetCalendar { conflictCalendars.remove(calendar.id) }
                            })).font(.system(size: 12))
                                .disabled(calendar.id == targetCalendar || (!conflictCalendars.contains(calendar.id) && conflictCalendars.count >= 8))
                        }
                    }
                    Divider()
                    Toggle("Repeat weekly availability", isOn: $repeatsWeekly)
                    if repeatsWeekly {
                        Form {
                            DatePicker("First day", selection: $firstDay, in: Date.now...Date.now.addingTimeInterval(90 * 86_400), displayedComponents: .date)
                            DatePicker("Last day", selection: $lastDay, in: Date.now...Date.now.addingTimeInterval(90 * 86_400), displayedComponents: .date)
                            Picker("From", selection: $startMinute) {
                                ForEach(Array(stride(from: 0, through: 23 * 60 + 30, by: 30)), id: \.self) { Text(hourLabel($0)).tag($0) }
                            }
                            Picker("Until", selection: $endMinute) {
                                ForEach(Array(stride(from: 30, through: 24 * 60, by: 30)), id: \.self) { Text(hourLabel($0)).tag($0) }
                            }
                        }.environment(\.timeZone, selectedZone)
                        HStack(spacing: 8) {
                            ForEach(1...7, id: \.self) { day in
                                Toggle(["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"][day - 1], isOn: Binding(get: { weekdays.contains(day) }, set: { selected in
                                    if selected { weekdays.insert(day) } else { weekdays.remove(day) }
                                })).toggleStyle(.button).controlSize(.small)
                            }
                        }
                        Text("Weekly hours follow this time zone. Times skipped or repeated by a daylight saving change are omitted. Up to 1,000 times are offered before the link expires.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        HStack {
                            DatePicker("Offer a time", selection: $nextTime, in: Date.now.addingTimeInterval(5 * 60)...Date.now.addingTimeInterval(90 * 86_400 - Double(duration) * 60))
                                .environment(\.timeZone, selectedZone)
                            Button("Add") {
                                let time = offeredStart
                                if !times.contains(time) { times.append(time); times.sort() }
                            }.disabled(times.count >= 100 || offeredStart <= Date.now.addingTimeInterval(5 * 60) || times.contains(offeredStart))
                        }
                        ForEach(times, id: \.self) { time in
                            HStack {
                                Text(timeLabel(time))
                                Spacer()
                                Button { times.removeAll { $0 == time } } label: { PostmereIcon("xmark", size: 11) }
                                    .buttonStyle(.borderless).help("Remove time")
                            }.font(.system(size: 12))
                        }
                    }
                    Text("Anyone with the link can book a time. All selected calendars are checked again before an invitation is created in your booking calendar.")
                        .font(.caption).foregroundStyle(.secondary)
                }.disabled(busy)
            }.frame(maxHeight: 480)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(busy ? "Creating…" : "Create Link") { Task { await create() } }
                    .buttonStyle(.borderedProminent).disabled(!canCreate)
            }
        }.padding(24).frame(width: 600)
            .onAppear { accountID = accounts.first?.id }
            .task(id: accountID) { await loadCalendars() }
            .onChange(of: targetCalendar) { previous, value in
                if conflictCalendars.count >= 8 && !conflictCalendars.contains(value) {
                    targetCalendar = previous
                    error = "Uncheck a conflict calendar before choosing a different booking calendar. You can check up to eight calendars."
                } else { conflictCalendars.insert(value) }
            }
    }
    private func timeLabel(_ date: Date) -> String {
        var format = Date.FormatStyle(date: .abbreviated, time: .shortened)
        format.timeZone = selectedZone
        return format.format(date)
    }
    private func hourLabel(_ minute: Int) -> String { String(format: "%02d:%02d", minute / 60, minute % 60) }
    private func dayString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = selectedZone; formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    private func loadCalendars() async {
        providerCalendars = []; targetCalendar = "primary"; conflictCalendars = ["primary"]; requiresReconnect = false
        guard let accountID else { return }
        let scope = session.scope
        loadingCalendars = true; error = nil
        defer { if session.scope == scope, self.accountID == accountID { loadingCalendars = false } }
        do {
            let response: ProviderCalendars = try await session.request("GET", "/v1/calendar/accounts/\(accountID.uuidString)/calendars")
            guard session.scope == scope, self.accountID == accountID else { return }
            providerCalendars = response.items; requiresReconnect = response.requiresReconnect
            targetCalendar = response.items.first(where: { $0.isPrimary && $0.canWrite })?.id ?? response.items.first(where: \.canWrite)?.id ?? "primary"
            conflictCalendars = [targetCalendar]
        } catch { if session.scope == scope, self.accountID == accountID { self.error = error.localizedDescription } }
    }
    private func create() async {
        guard canCreate, let accountID, accounts.contains(where: { $0.id == accountID }) else { return }
        let now = Date.now
        let cleanedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanedTitle.isEmpty, cleanedTitle.unicodeScalars.count <= 160,
              !cleanedTitle.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              TimeZone(identifier: timeZone) != nil else {
            error = "Use a meeting title of 1–160 characters and a valid IANA time zone."; return
        }
        guard expiry > now, expiry <= now.addingTimeInterval(90 * 86_400) else { error = "Set an expiry within the next 90 days."; return }
        let availability: WeeklyBookingAvailability?
        if repeatsWeekly {
            guard !weekdays.isEmpty, startMinute < endMinute, dayString(firstDay) <= dayString(lastDay) else {
                error = "Choose weekdays, an end date after the start date, and an end time after the start time."; return
            }
            availability = WeeklyBookingAvailability(startDate: dayString(firstDay), endDate: dayString(lastDay), weekdays: weekdays.sorted(), startMinute: startMinute, endMinute: endMinute)
        } else {
            guard !times.isEmpty, times.count <= 100,
                  times.allSatisfy({ $0 > now.addingTimeInterval(5 * 60) && $0.addingTimeInterval(Double(duration) * 60) <= min(expiry, now.addingTimeInterval(90 * 86_400)) }) else {
                error = "Offer times at least five minutes ahead, with each meeting ending before the link expires."; return
            }
            availability = nil
        }
        let scope = session.scope
        busy = true; error = nil
        defer { busy = false }
        do {
            let _: BookingLink = try await session.request("POST", "/v1/calendar/booking-links", body:
                BookingLinkInput(accountId: accountID, title: cleanedTitle, description: "", timeZone: timeZone,
                    durationMinutes: duration, expiresAt: expiry,
                    slots: repeatsWeekly ? [] : times.map { BookingSlotInput(start: $0, end: $0.addingTimeInterval(Double(duration) * 60)) },
                    calendarId: targetCalendar, conflictCalendarIds: conflictCalendars.sorted(), availability: availability))
            guard session.scope == scope else { return }
            dismiss()
        } catch { if session.scope == scope { self.error = error.localizedDescription } }
    }
}

private struct SharedAvailabilityView: View {
    let session: BackendSession
    @State private var editingCalendar: SharedCalendar?
    @State private var calendars: [SharedCalendar] = []
    @State private var selected: Set<UUID> = []
    @State private var day = Date.now
    @State private var result: FreeBusyResult?
    @State private var error: String?
    @State private var busy = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Shares busy times from your selected calendars with this workspace. Event names and attendees remain private.").font(.caption).foregroundStyle(.secondary)
                ForEach(calendars.filter(\.isMine)) { calendar in
                    HStack {
                        Toggle("Share busy times · \(calendar.email)", isOn: Binding(get: { calendar.enabled }, set: { value in Task { await share(calendar, enabled: value) } }))
                            .font(.system(size: 12)).disabled(busy)
                        if calendar.enabled {
                            Button("Calendars…") { editingCalendar = calendar }.controlSize(.small).disabled(busy)
                        }
                    }
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
                            if calendar.busy.isEmpty { Text("No busy times in the selected calendars.").font(.caption).foregroundStyle(.secondary) }
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
        }.task(id: session.scope) {
            calendars = []; selected = []; result = nil; error = nil
            if session.isConnected { await load() }
        }.onChange(of: day) { result = nil }
            .sheet(item: $editingCalendar, onDismiss: { Task { await load() } }) { calendar in
                SharedCalendarSelectionView(session: session, calendar: calendar)
            }
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
        do { let _: BackendEmpty = try await session.request("PUT", "/v1/calendar/sharing/\(calendar.id.uuidString)", body: CalendarSharingInput(enabled: enabled, calendarIds: calendar.calendarIds ?? ["primary"])); await load() }
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

private struct SharedCalendarSelectionView: View {
    let session: BackendSession
    let calendar: SharedCalendar
    @Environment(\.dismiss) private var dismiss
    @State private var calendars: [ProviderCalendar] = []
    @State private var selected: Set<String> = []
    @State private var requiresReconnect = false
    @State private var busy = false
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Shared calendars").font(PostmereTheme.sheetTitle)
            Text(calendar.email).font(.subheadline).foregroundStyle(.secondary)
            Text("Share combined busy times from up to eight calendars. Event details remain private.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(calendars) { item in
                        Toggle(item.name, isOn: Binding(get: { selected.contains(item.id) }, set: { value in
                            if value { selected.insert(item.id) } else { selected.remove(item.id) }
                        })).disabled(busy || (!selected.contains(item.id) && selected.count >= 8))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: 300)
            if requiresReconnect { Text("Reconnect calendar access in Settings → Accounts to select additional calendars.").font(.caption).foregroundStyle(.secondary) }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if busy { ProgressView().controlSize(.small) }
                Button("Save Shared Calendars") { Task { await save() } }.buttonStyle(.borderedProminent).disabled(busy || selected.isEmpty || calendars.isEmpty)
            }
        }.padding(24).frame(width: 480)
            .task { await load() }
    }
    private func load() async {
        let scope = session.scope
        busy = true; defer { busy = false }
        do {
            let response: ProviderCalendars = try await session.request("GET", "/v1/calendar/accounts/\(calendar.accountId.uuidString)/calendars")
            guard session.scope == scope else { return }
            calendars = response.items; requiresReconnect = response.requiresReconnect
            selected = Set(calendar.calendarIds ?? ["primary"]).intersection(Set(calendars.map(\.id)))
        } catch { if session.scope == scope { self.error = error.localizedDescription } }
    }
    private func save() async {
        guard !busy, !selected.isEmpty, selected.count <= 8 else { return }
        let scope = session.scope
        busy = true; defer { busy = false }
        do {
            let _: BackendEmpty = try await session.request("PUT", "/v1/calendar/sharing/\(calendar.accountId.uuidString)", body: CalendarSharingInput(enabled: true, calendarIds: selected.sorted()))
            guard session.scope == scope else { return }
            dismiss()
        } catch { if session.scope == scope { self.error = error.localizedDescription } }
    }
}
