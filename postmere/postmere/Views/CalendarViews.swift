import SwiftUI

struct CalendarAgendaView: View {
    private let service: MailCalendarService
    @State private var day = Calendar.current.startOfDay(for: Date())

    init(service: MailCalendarService? = nil) { self.service = service ?? .shared }

    var body: some View {
        VStack(spacing: 0) {
            if !service.isEnabled || !service.access.canRead {
                CalendarIntegrationSettingsView(service: service).padding(24)
                Spacer()
            } else {
                HStack {
                    DatePicker("Week starting", selection: $day, displayedComponents: .date)
                    Spacer()
                    Button("Today") { day = Calendar.current.startOfDay(for: .now) }
                    if service.isLoading { ProgressView().controlSize(.small) }
                }.padding(.horizontal, 24).padding(.vertical, 14)
                Divider()
                if let error = service.errorMessage { Text(error).font(.caption).foregroundStyle(.red).padding() }
                if service.events.isEmpty && !service.isLoading {
                    ContentUnavailableView {
                        PostmereLabel.emptyState("No events this week", symbol: "calendar", size: 36)
                    } description: { Text("Choose another week or add an event.") }
                } else {
                    List(service.events) { event in
                        HStack(alignment: .top, spacing: 14) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(event.start, format: .dateTime.weekday(.abbreviated).month(.abbreviated).day())
                                Text(event.isAllDay ? "All day" : event.start.formatted(date: .omitted, time: .shortened))
                                    .foregroundStyle(.secondary)
                            }.font(.system(size: 12)).frame(width: 110, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(event.title).font(.system(size: 13, weight: .medium))
                                Text([event.calendarTitle, event.location].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if !event.isBusy { Text("Free").font(.caption).foregroundStyle(.secondary) }
                        }.padding(.vertical, 6)
                    }.listStyle(.inset)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task(id: "\(day.timeIntervalSince1970)|\(service.isEnabled)") {
            let start = Calendar.current.startOfDay(for: day)
            if let end = Calendar.current.date(byAdding: .day, value: 7, to: start) { await service.refreshAgenda(from: start, to: end) }
        }
    }
}

struct CalendarIntegrationSettingsView: View {
    @Environment(\.postmereAccent) private var palette
    private let service: MailCalendarService
    @State private var isConnecting = false
    init(service: MailCalendarService? = nil) { self.service = service ?? .shared }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Calendar agenda and availability").font(.system(size: 13, weight: .semibold))
            Text("Connect calendars on this Mac to see upcoming events and check times before sharing availability.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            if service.isEnabled && service.access.canRead {
                HStack {
                    Text("Calendar connected").font(.system(size: 12)).foregroundStyle(palette.accentInk)
                    Spacer()
                    Button("Disconnect") { service.disconnectAgenda() }
                }
            } else {
                HStack {
                    Button("Connect Calendar") {
                        isConnecting = true
                        Task { await service.connectAgenda(); isConnecting = false }
                    }.disabled(isConnecting || service.access == .restricted)
                    if isConnecting { ProgressView().controlSize(.small) }
                }
                if service.access == .denied || service.access == .restricted {
                    Text("Manage access in System Settings → Privacy & Security → Calendars.").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let error = service.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}

struct CalendarEventDraftView: View {
    private let service: MailCalendarService
    private let onSaved: ((String) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MailCalendarEventDraft
    @State private var isSaving = false
    @State private var saveError: String?

    init(draft: MailCalendarEventDraft, service: MailCalendarService? = nil, onSaved: ((String) -> Void)? = nil) {
        _draft = State(initialValue: draft)
        self.service = service ?? .shared
        self.onSaved = onSaved
    }

    private var timeZone: TimeZone { TimeZone(identifier: draft.timeZoneIdentifier) ?? .current }
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = timeZone
        return value
    }
    private var validationError: String? {
        do { _ = try draft.validated(); return nil } catch { return error.localizedDescription }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review Event").font(PostmereTheme.sheetTitle)
            TextField("Event title", text: $draft.title).textFieldStyle(.roundedBorder)
            Toggle("All day", isOn: $draft.isAllDay).toggleStyle(.checkbox)
            if draft.isAllDay {
                DatePicker("First day", selection: $draft.start, displayedComponents: .date)
                DatePicker("Last day", selection: Binding(get: {
                    calendar.date(byAdding: .day, value: -1, to: draft.end) ?? draft.start
                }, set: { date in
                    draft.end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: date)) ?? date
                }), displayedComponents: .date)
            } else {
                DatePicker("Starts", selection: $draft.start)
                DatePicker("Ends", selection: $draft.end)
            }
            Picker("Time zone", selection: $draft.timeZoneIdentifier) {
                ForEach(TimeZone.knownTimeZoneIdentifiers, id: \.self) { Text($0).tag($0) }
            }
            Picker("Calendar", selection: $draft.calendarID) {
                Text("Default Calendar").tag(nil as String?)
                ForEach(service.calendars.filter(\.isWritable)) { calendar in
                    Text("\(calendar.title) · \(calendar.source)").tag(Optional(calendar.id))
                }
            }
            TextField("Location", text: $draft.location).textFieldStyle(.roundedBorder)
            TextField("Event link (optional)", text: $draft.urlString).textFieldStyle(.roundedBorder)
            VStack(alignment: .leading, spacing: 6) {
                Text("Notes").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $draft.notes).font(.system(size: 12)).scrollContentBackground(.hidden)
                    .frame(height: 90).padding(6)
                    .background(PostmereTheme.subtleFill, in: .rect(cornerRadius: 6))
                    .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(PostmereTheme.rule) }
            }
            Text("Adds a local calendar event. It does not send invitations or reply to an organizer.")
                .font(.caption).foregroundStyle(.secondary)
            if let error = saveError ?? validationError { Text(error).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).disabled(isSaving)
                Button("Add Event") {
                    isSaving = true
                    Task {
                        do {
                            let id = try await service.saveReviewedEvent(draft)
                            onSaved?(id)
                            dismiss()
                        } catch { saveError = error.localizedDescription }
                        isSaving = false
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(isSaving || validationError != nil)
            }
        }
        .padding(24).frame(width: 570)
        .environment(\.timeZone, timeZone)
        .onChange(of: draft.isAllDay) {
            if draft.isAllDay {
                draft.start = calendar.startOfDay(for: draft.start)
                draft.end = calendar.date(byAdding: .day, value: 1, to: draft.start) ?? draft.start.addingTimeInterval(86_400)
            }
        }
    }
}

struct AvailabilityPickerView: View {
    private let service: MailCalendarService
    private let onInsert: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var day = Calendar.current.startOfDay(for: Date())
    @State private var duration = 30
    @State private var slots: [MailAvailabilitySlot] = []
    @State private var selected: [String: MailAvailabilitySlot] = [:]
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var loadID = UUID()

    init(service: MailCalendarService? = nil, onInsert: @escaping (String) -> Void) {
        self.service = service ?? .shared
        self.onInsert = onInsert
    }

    private var checkedWithCalendar: Bool { service.isEnabled && service.access.canRead }
    private var selectedSlots: [MailAvailabilitySlot] { selected.values.filter { $0.start >= .now }.sorted { $0.start < $1.start } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Share Availability").font(PostmereTheme.sheetTitle)
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            HStack {
                DatePicker("Day", selection: $day, in: Calendar.current.startOfDay(for: .now)..., displayedComponents: .date)
                Picker("Duration", selection: $duration) {
                    ForEach([15, 30, 45, 60, 90, 120], id: \.self) { Text("\($0) minutes").tag($0) }
                }.frame(width: 200)
            }
            Text("Times shown in \(TimeZone.current.identifier). Choose times on one or more days.")
                .font(.caption).foregroundStyle(.secondary)
            if !checkedWithCalendar {
                Text("Calendar conflicts have not been checked. You can select times manually or connect Calendar.")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Connect Calendar") { Task { await service.connectAgenda() } }
            }
            if isLoading { ProgressView().controlSize(.small) }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 8) {
                    ForEach(slots) { slot in
                        Toggle(isOn: Binding(get: { selected[slot.id] != nil }, set: { isSelected in
                            if isSelected { selected[slot.id] = slot } else { selected.removeValue(forKey: slot.id) }
                        })) {
                            Text("\(slot.start.formatted(date: .omitted, time: .shortened))–\(slot.end.formatted(date: .omitted, time: .shortened))")
                                .font(.system(size: 12)).monospacedDigit()
                        }.toggleStyle(.checkbox).padding(8)
                    }
                }
                if slots.isEmpty && !isLoading { Text("No times are available during 9 am–5 pm for this day.").foregroundStyle(.secondary).padding() }
            }.frame(minHeight: 120, maxHeight: 210)
            Divider()
            HStack {
                Text("\(selectedSlots.count) selected").font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Clear") { selected = [:] }.disabled(selected.isEmpty)
            }
            ScrollView {
                Text(selectedSlots.isEmpty ? "Your availability text will appear here." : MailAvailability.text(for: selectedSlots))
                    .font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }.frame(height: 100)
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Insert Availability") { Task { await insert() } }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(selectedSlots.isEmpty || isLoading)
            }
        }.padding(24).frame(width: 650, height: 590)
        .task(id: "\(day.timeIntervalSince1970)|\(duration)|\(checkedWithCalendar)") { await load() }
        .onChange(of: service.events) { Task { await load() } }
    }

    private func load() async {
        let request = UUID()
        loadID = request
        isLoading = true
        errorMessage = nil
        let start = Calendar.current.startOfDay(for: day)
        guard let end = Calendar.current.date(byAdding: .day, value: 1, to: start) else { isLoading = false; return }
        var events: [MailCalendarEvent] = []
        if checkedWithCalendar {
            do { events = try await service.events(from: start, to: end) }
            catch {
                guard request == loadID else { return }
                errorMessage = error.localizedDescription
                slots = []; isLoading = false; return
            }
        }
        guard request == loadID, !Task.isCancelled else { return }
        slots = MailAvailability.slots(on: day, busyEvents: events, durationMinutes: duration)
        let allowed = Set(slots.map(\.id))
        selected = selected.filter { $0.value.start < start || $0.value.start >= end || allowed.contains($0.key) }
        isLoading = false
    }

    private func insert() async {
        let proposed = selectedSlots
        guard let first = proposed.first, let last = proposed.last else { return }
        isLoading = true
        defer { isLoading = false }
        if checkedWithCalendar {
            do {
                let busy = try await service.events(from: first.start, to: last.end)
                let valid = proposed.filter { slot in !busy.contains { $0.isBusy && $0.start < slot.end && $0.end > slot.start } }
                if valid.count != proposed.count {
                    selected = Dictionary(uniqueKeysWithValues: valid.map { ($0.id, $0) })
                    errorMessage = "Some times are no longer available. Review the updated selection."
                    return
                }
            } catch { errorMessage = error.localizedDescription; return }
        }
        onInsert(MailAvailability.text(for: proposed))
        dismiss()
    }
}
