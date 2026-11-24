import EventKit
import EventKitUI
import SwiftUI

// MARK: - Add to Calendar

/// iOS's own event editor, filled in from a date found in an email. It runs outside the
/// app, so nothing is read from or written to the calendar unless you tap Add.
struct MobileEventEditor: UIViewControllerRepresentable {
    let draft: MailCalendarEventDraft
    @Environment(\.dismiss) private var dismiss

    private static let store = EKEventStore()

    func makeUIViewController(context: Context) -> EKEventEditViewController {
        let event = EKEvent(eventStore: Self.store)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.isAllDay = draft.isAllDay
        event.timeZone = TimeZone(identifier: draft.timeZoneIdentifier)
        if !draft.location.isEmpty { event.location = draft.location }
        if !draft.notes.isEmpty { event.notes = draft.notes }
        if let url = URL(string: draft.urlString), !draft.urlString.isEmpty { event.url = url }
        let controller = EKEventEditViewController()
        controller.eventStore = Self.store
        controller.event = event
        controller.editViewDelegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: EKEventEditViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator { dismiss() } }

    final class Coordinator: NSObject, EKEventEditViewDelegate {
        let done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }

        func eventEditViewController(_ controller: EKEventEditViewController, didCompleteWith action: EKEventEditViewAction) {
            if action == .saved { UINotificationFeedbackGenerator().notificationOccurred(.success) }
            done()
        }
    }
}

extension MailMessage {
    /// Dates and times mentioned in the message, offered as calendar events.
    var calendarSuggestions: [MailDateSuggestion] {
        Array(MailDateDetector.suggestions(in: ([subject] + paragraphs).joined(separator: "\n")).prefix(5))
    }
}

// MARK: - Availability

/// Pick free times across a few days; they go into the message as a list.
struct MobileAvailabilitySheet: View {
    let onInsert: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var service = MailCalendarService.shared
    @State private var day = Calendar.current.startOfDay(for: .now)
    @State private var duration = 30
    @State private var slots: [MailAvailabilitySlot] = []
    @State private var selected: [String: MailAvailabilitySlot] = [:]
    @State private var loading = false
    @State private var error: String?

    private var checksCalendar: Bool { service.isEnabled && service.access.canRead }
    private var picked: [MailAvailabilitySlot] { selected.values.filter { $0.start >= .now }.sorted { $0.start < $1.start } }
    private var days: [Date] {
        (0..<14).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: Calendar.current.startOfDay(for: .now)) }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    dayStrip
                    HStack(spacing: 8) {
                        ForEach([15, 30, 45, 60, 90], id: \.self) { minutes in
                            chip(minutes < 60 ? "\(minutes)m" : minutes == 60 ? "1h" : "1½h", selected: duration == minutes) {
                                duration = minutes
                            }
                        }
                    }
                    if !checksCalendar {
                        Button {
                            Task { await service.connectAgenda() }
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: "calendar.badge.checkmark").foregroundStyle(palette.accent)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("Hide busy times").font(.subheadline.weight(.semibold))
                                    Text("Allow Calendar access to leave out times you’re booked.")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                            }
                            .padding(12)
                            .background(palette.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                    slotGrid
                    if let error { Text(error).font(.footnote).foregroundStyle(PostmereTheme.destructiveInk) }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
            }
            .safeAreaInset(edge: .bottom) { insertBar }
            .navigationTitle("Share Availability")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                if !selected.isEmpty {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Clear") { withAnimation(.snappy) { selected = [:] } }
                    }
                }
            }
            .task(id: "\(day.timeIntervalSince1970)|\(duration)|\(checksCalendar)") { await load() }
        }
    }

    private var dayStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(days, id: \.self) { date in
                    let isSelected = Calendar.current.isDate(date, inSameDayAs: day)
                    let count = selected.values.count { Calendar.current.isDate($0.start, inSameDayAs: date) }
                    Button { withAnimation(.snappy) { day = date } } label: {
                        VStack(spacing: 3) {
                            Text(date, format: .dateTime.weekday(.abbreviated)).font(.caption2.weight(.semibold))
                            Text(date, format: .dateTime.day()).font(.system(size: 19, weight: .bold, design: .rounded))
                            Circle().fill(count > 0 ? (isSelected ? Color.white : palette.accent) : .clear).frame(width: 5, height: 5)
                        }
                        .foregroundStyle(isSelected ? .white : .primary)
                        .frame(width: 50, height: 66)
                        .background(isSelected ? AnyShapeStyle(palette.accent) : AnyShapeStyle(Mobile.raised),
                                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .scrollClipDisabled()
    }

    @ViewBuilder private var slotGrid: some View {
        if loading && slots.isEmpty {
            ProgressView().frame(maxWidth: .infinity).padding(.vertical, 30)
        } else if slots.isEmpty {
            Text("No free times between 9 am and 5 pm on this day.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 8)], spacing: 8) {
                ForEach(slots) { slot in
                    let on = selected[slot.id] != nil
                    Button {
                        withAnimation(.snappy(duration: 0.2)) {
                            if on { selected.removeValue(forKey: slot.id) } else { selected[slot.id] = slot }
                        }
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Text(slot.start, format: .dateTime.hour().minute())
                            .font(.system(size: 15, weight: .semibold))
                            .monospacedDigit()
                            .foregroundStyle(on ? .white : .primary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .background(on ? AnyShapeStyle(palette.accent) : AnyShapeStyle(Mobile.raised),
                                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(on ? .isSelected : [])
                }
            }
        }
    }

    private var insertBar: some View {
        Button {
            Task { await insert() }
        } label: {
            Text(picked.isEmpty ? "Choose times" : "Insert \(picked.count) time\(picked.count == 1 ? "" : "s")")
                .font(.headline)
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.tint(picked.isEmpty ? Color.secondary.opacity(0.35) : palette.accent).interactive(), in: Capsule())
        .disabled(picked.isEmpty || loading)
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(selected ? .white : .primary)
                .padding(.horizontal, 14)
                .frame(height: 34)
                .background(selected ? AnyShapeStyle(palette.accent) : AnyShapeStyle(Mobile.raised), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func load() async {
        loading = true
        error = nil
        defer { loading = false }
        let start = Calendar.current.startOfDay(for: day)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { return }
        var events: [MailCalendarEvent] = []
        if checksCalendar {
            do { events = try await service.events(from: start, to: end) } catch { self.error = error.localizedDescription }
        }
        guard !Task.isCancelled else { return }
        slots = MailAvailability.slots(on: day, busyEvents: events, durationMinutes: duration)
    }

    private func insert() async {
        let proposed = picked
        guard let first = proposed.first, let last = proposed.last else { return }
        if checksCalendar {
            loading = true
            defer { loading = false }
            do {
                let busy = try await service.events(from: first.start, to: last.end)
                let free = proposed.filter { slot in !busy.contains { $0.isBusy && $0.start < slot.end && $0.end > slot.start } }
                if free.count != proposed.count {
                    selected = Dictionary(uniqueKeysWithValues: free.map { ($0.id, $0) })
                    error = "Some of those times just got booked. Check the selection again."
                    return
                }
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        onInsert(MailAvailability.text(for: proposed))
        dismiss()
    }
}

// MARK: - Booking links

/// Links people use to book time with you, and what they've booked.
struct MobileBookingLinksScreen: View {
    let session: BackendSession
    /// Set when opened from the composer: tapping a link inserts it.
    var onInsert: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var links: [BookingLink] = []
    @State private var bookings: [CalendarBooking] = []
    @State private var loaded = false
    @State private var creates = false
    @State private var error: String?
    @State private var cancelling: CalendarBooking?
    @State private var copied: UUID?

    private var canCreate: Bool {
        session.accounts.contains { $0.status == "connected" && $0.capabilities?.contains("calendar") == true }
    }

    var body: some View {
        List {
            let active = links.filter { $0.disabledAt == nil && $0.expiresAt > .now }
            Section {
                ForEach(active) { link in linkRow(link) }
                if active.isEmpty && loaded {
                    Text(canCreate ? "Offer some times and share one link. People pick a time that suits them."
                                   : "Turn on calendar access for an account on your Mac, then create links here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Links")
            } footer: {
                Text("Your calendar is checked again whenever someone books.")
            }
            if !bookings.isEmpty {
                Section("Bookings") {
                    ForEach(bookings.sorted { $0.start > $1.start }) { booking in bookingRow(booking) }
                }
            }
            if let error {
                Section { Text(error).foregroundStyle(PostmereTheme.destructiveInk) }
            }
        }
        .overlay { if !loaded { ProgressView() } }
        .mobileSettingsCanvas()
        .navigationTitle("Booking Links")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Link", systemImage: "plus") { creates = true }.disabled(!canCreate)
            }
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(isPresented: $creates, onDismiss: { Task { await load() } }) {
            MobileCreateBookingLinkSheet(session: session)
        }
        .confirmationDialog("Cancel this booking?", isPresented: Binding(get: { cancelling != nil }, set: { if !$0 { cancelling = nil } }),
                            titleVisibility: .visible, presenting: cancelling) { booking in
            Button("Cancel Booking", role: .destructive) { Task { await update(booking, action: "cancel") } }
        } message: { _ in
            Text("The event is cancelled and the guest is told. The time opens up again.")
        }
    }

    private func linkRow(_ link: BookingLink) -> some View {
        Button {
            if let onInsert {
                onInsert("\(link.title): \(link.url)")
                dismiss()
            } else {
                UIPasteboard.general.string = link.url
                withAnimation(.snappy) { copied = link.id }
            }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: "calendar.badge.clock")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(palette.accent)
                    .frame(width: 40, height: 40)
                    .background(palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.title).font(.subheadline.weight(.semibold))
                    Text("\(link.durationMinutes) min · \(link.availability == nil ? "\(link.slots.count) times" : "Weekly hours") · until \(link.expiresAt.formatted(.dateTime.day().month(.abbreviated)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 6)
                if onInsert != nil {
                    Text("Insert").font(.subheadline.weight(.semibold)).foregroundStyle(palette.accent)
                } else {
                    Image(systemName: copied == link.id ? "checkmark" : "doc.on.doc")
                        .foregroundStyle(copied == link.id ? palette.accent : .secondary)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy Link", systemImage: "doc.on.doc") { UIPasteboard.general.string = link.url }
            ShareLink(item: link.url) { Label("Share…", systemImage: "square.and.arrow.up") }
        }
        .swipeActions {
            Button("Turn Off", role: .destructive) { Task { await disable(link) } }
        }
    }

    private func bookingRow(_ booking: CalendarBooking) -> some View {
        HStack(spacing: 12) {
            ParticipantPhoto(address: booking.guestEmail, name: booking.guestName, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(booking.guestName).font(.subheadline.weight(.semibold))
                Text(booking.start.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 6)
            Text(booking.statusLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(booking.status == "confirmed" ? palette.accent : .secondary)
        }
        .swipeActions {
            if ["confirmed", "cancel_uncertain"].contains(booking.status) {
                Button("Cancel", role: .destructive) { cancelling = booking }
            }
            if ["uncertain", "cancel_uncertain", "creating", "cancelling"].contains(booking.status) {
                Button("Check") { Task { await update(booking, action: "reconcile") } }.tint(.blue)
            }
        }
    }

    private func load() async {
        do {
            let response: BookingLinks = try await session.request("GET", "/v1/calendar/booking-links")
            let history: CalendarBookings = try await session.request("GET", "/v1/calendar/bookings")
            withAnimation(.snappy) {
                links = response.items
                bookings = history.items
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
        loaded = true
    }

    private func update(_ booking: CalendarBooking, action: String) async {
        do {
            let _: CalendarBookingResult = try await session.request(
                "POST", "/v1/calendar/bookings/\(booking.id.uuidString)/\(action)")
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func disable(_ link: BookingLink) async {
        do {
            let _: BackendEmpty = try await session.request("DELETE", "/v1/calendar/booking-links/\(link.id.uuidString)")
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// A booking link from weekly hours: which days, which hours, how long.
struct MobileCreateBookingLinkSheet: View {
    let session: BackendSession
    @Environment(\.dismiss) private var dismiss
    @Environment(\.postmereAccent) private var palette
    @State private var accountID: UUID?
    @State private var title = "Meet with me"
    @State private var duration = 30
    @State private var weekdays: Set<Int> = [1, 2, 3, 4, 5]
    @State private var startMinute = 9 * 60
    @State private var endMinute = 17 * 60
    @State private var weeks = 2
    @State private var calendars: [ProviderCalendar] = []
    @State private var target = "primary"
    @State private var busy = false
    @State private var error: String?

    private var accounts: [BackendAccount] {
        session.accounts.filter { $0.status == "connected" && $0.capabilities?.contains("calendar") == true }
    }

    private var canSave: Bool {
        !busy && accountID != nil && !weekdays.isEmpty && startMinute < endMinute
            && !title.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title)
                    Picker("Length", selection: $duration) {
                        ForEach([15, 30, 45, 60], id: \.self) { Text("\($0) minutes").tag($0) }
                    }
                    if accounts.count > 1 {
                        Picker("Account", selection: $accountID) {
                            ForEach(accounts) { Text($0.email).tag(Optional($0.id)) }
                        }
                    }
                    if calendars.filter(\.canWrite).count > 1 {
                        Picker("Add events to", selection: $target) {
                            ForEach(calendars.filter(\.canWrite)) { Text($0.name).tag($0.id) }
                        }
                    }
                }
                Section {
                    HStack(spacing: 6) {
                        ForEach(1...7, id: \.self) { day in
                            let on = weekdays.contains(day)
                            Button {
                                if on { weekdays.remove(day) } else { weekdays.insert(day) }
                            } label: {
                                Text(["M", "T", "W", "T", "F", "S", "S"][day - 1])
                                    .font(.system(size: 14, weight: .bold))
                                    .foregroundStyle(on ? .white : .primary)
                                    .frame(maxWidth: .infinity, minHeight: 38)
                                    .background(on ? AnyShapeStyle(palette.accent) : AnyShapeStyle(Mobile.raised), in: Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Calendar.current.weekdaySymbols[day % 7])
                            .accessibilityAddTraits(on ? .isSelected : [])
                        }
                    }
                    Picker("From", selection: $startMinute) {
                        ForEach(Array(stride(from: 6 * 60, through: 21 * 60, by: 30)), id: \.self) { Text(label($0)).tag($0) }
                    }
                    Picker("Until", selection: $endMinute) {
                        ForEach(Array(stride(from: 7 * 60, through: 23 * 60, by: 30)), id: \.self) { Text(label($0)).tag($0) }
                    }
                    Picker("For the next", selection: $weeks) {
                        ForEach([1, 2, 4, 8], id: \.self) { Text("\($0) week\($0 == 1 ? "" : "s")").tag($0) }
                    }
                } header: {
                    Text("When you’re free")
                } footer: {
                    Text("Times follow \(TimeZone.current.identifier). Anyone with the link can book; your calendar is checked first.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(PostmereTheme.destructiveInk) }
                }
            }
            .navigationTitle("New Booking Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if busy { ProgressView() } else {
                        Button("Create", systemImage: "checkmark") { Task { await create() } }.disabled(!canSave)
                    }
                }
            }
            .onAppear { accountID = accountID ?? accounts.first?.id }
            .task(id: accountID) { await loadCalendars() }
        }
    }

    private func label(_ minute: Int) -> String {
        let date = Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: .now) ?? .now
        return date.formatted(date: .omitted, time: .shortened)
    }

    private func day(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private func loadCalendars() async {
        guard let accountID else { return }
        do {
            let response: ProviderCalendars = try await session.request("GET", "/v1/calendar/accounts/\(accountID.uuidString)/calendars")
            calendars = response.items
            target = response.items.first { $0.isPrimary && $0.canWrite }?.id ?? response.items.first(where: \.canWrite)?.id ?? "primary"
        } catch {
            calendars = []
            target = "primary"
        }
    }

    private func create() async {
        guard canSave, let accountID else { return }
        busy = true
        error = nil
        defer { busy = false }
        let first = Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now
        let last = Calendar.current.date(byAdding: .day, value: weeks * 7, to: .now) ?? first
        let expiry = Calendar.current.date(byAdding: .day, value: 1, to: last) ?? last
        let availability = WeeklyBookingAvailability(startDate: day(first), endDate: day(last), weekdays: weekdays.sorted(),
                                                     startMinute: startMinute, endMinute: endMinute)
        do {
            let _: BookingLink = try await session.request("POST", "/v1/calendar/booking-links", body:
                BookingLinkInput(accountId: accountID, title: title.trimmingCharacters(in: .whitespaces), description: "",
                                 timeZone: TimeZone.current.identifier, durationMinutes: duration, expiresAt: expiry,
                                 slots: [], calendarId: target, conflictCalendarIds: [target], availability: availability))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
