import EventKit
import Foundation
import Observation

nonisolated struct MailCalendarSnapshot: Sendable {
    let events: [MailCalendarEvent]
    let calendars: [MailCalendarChoice]
    let defaultCalendarID: String?
}

/// All EKObjects stay in one actor and one long-lived store. Synchronous
/// EventKit database queries therefore never run on the UI actor.
private actor MailCalendarDatabase {
    private var eventStore: EKEventStore?

    private func store() -> EKEventStore {
        if let eventStore { return eventStore }
        let created = EKEventStore()
        eventStore = created
        return created
    }

    func requestAccess(full: Bool) async throws -> Bool {
        let store = store()
        return try await (full ? store.requestFullAccessToEvents() : store.requestWriteOnlyAccessToEvents())
    }

    func snapshot(from start: Date, to end: Date) throws -> MailCalendarSnapshot {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw MailCalendarError.accessRequired }
        guard end > start, end.timeIntervalSince(start) <= 366 * 86_400 else { throw MailCalendarError.invalidDateRange }
        let store = store()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let events = store.events(matching: predicate).filter { $0.status != .canceled }.compactMap { event -> MailCalendarEvent? in
            guard let start = event.startDate, let end = event.endDate else { return nil }
            return MailCalendarEvent(id: "\(event.eventIdentifier ?? event.calendarItemIdentifier)|\(start.timeIntervalSince1970)",
                title: event.title ?? "Untitled event", start: start, end: end, isAllDay: event.isAllDay,
                calendarTitle: event.calendar.title, location: event.location ?? "", isBusy: event.availability != .free)
        }.sorted { $0.start < $1.start }
        let calendars = store.calendars(for: .event).map {
            MailCalendarChoice(id: $0.calendarIdentifier, title: $0.title, source: $0.source.title, isWritable: $0.allowsContentModifications)
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return MailCalendarSnapshot(events: events, calendars: calendars, defaultCalendarID: store.defaultCalendarForNewEvents?.calendarIdentifier)
    }

    func save(_ draft: MailCalendarEventDraft) throws -> String {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status == .fullAccess || status == .writeOnly else { throw MailCalendarError.accessDenied }
        let draft = try draft.validated()
        let store = store()
        let calendar: EKCalendar?
        if let id = draft.calendarID {
            guard status == .fullAccess else { throw MailCalendarError.accessRequired }
            calendar = store.calendar(withIdentifier: id)
        } else { calendar = store.defaultCalendarForNewEvents }
        guard let calendar else { throw MailCalendarError.noWritableCalendar }
        guard calendar.allowsContentModifications else { throw MailCalendarError.readOnlyCalendar }
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.start
        event.endDate = draft.end
        event.timeZone = TimeZone(identifier: draft.timeZoneIdentifier)
        event.isAllDay = draft.isAllDay
        event.location = draft.location.isEmpty ? nil : draft.location
        event.notes = draft.notes.isEmpty ? nil : draft.notes
        event.url = draft.urlString.isEmpty ? nil : URL(string: draft.urlString)
        event.calendar = calendar
        do {
            try store.save(event, span: .thisEvent, commit: true)
            return event.eventIdentifier ?? event.calendarItemIdentifier
        } catch {
            store.reset()
            throw error
        }
    }
}

@MainActor
@Observable
final class MailCalendarService {
    static let shared = MailCalendarService()
    private(set) var isEnabled: Bool
    private(set) var access: MailCalendarAccess
    private(set) var events: [MailCalendarEvent] = []
    private(set) var calendars: [MailCalendarChoice] = []
    private(set) var defaultCalendarID: String?
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let database = MailCalendarDatabase()
    @ObservationIgnored private var refreshID = UUID()
    @ObservationIgnored private var lastRange: DateInterval?
    @ObservationIgnored private var changeTask: Task<Void, Never>?

    init(defaults: UserDefaults = .standard, observeChanges: Bool = true) {
        self.defaults = defaults
        isEnabled = defaults.bool(forKey: "calendarIntegrationEnabled")
        access = Self.currentAccess()
        if observeChanges {
            changeTask = Task { [weak self] in
                for await _ in NotificationCenter.default.notifications(named: .EKEventStoreChanged).map({ _ in true }) {
                    guard let self else { return }
                    self.access = Self.currentAccess()
                    if let range = self.lastRange { await self.refreshAgenda(from: range.start, to: range.end) }
                }
            }
        }
    }

    deinit { changeTask?.cancel() }

    /// Only a user action such as Connect Calendar should call this method.
    func connectAgenda() async {
        errorMessage = nil
        do {
            guard Bundle.main.object(forInfoDictionaryKey: "NSCalendarsFullAccessUsageDescription") != nil else {
                throw MailCalendarError.missingPrivacyDescription
            }
            let granted = access == .full ? true : try await database.requestAccess(full: true)
            access = Self.currentAccess()
            guard granted, access.canRead else { throw MailCalendarError.accessDenied }
            isEnabled = true
            defaults.set(true, forKey: "calendarIntegrationEnabled")
            let start = Calendar.current.startOfDay(for: .now)
            await refreshAgenda(from: start, to: Calendar.current.date(byAdding: .day, value: 7, to: start)!)
        } catch { errorMessage = error.localizedDescription }
    }

    func disconnectAgenda() {
        isEnabled = false
        defaults.set(false, forKey: "calendarIntegrationEnabled")
        refreshID = UUID()
        events = []
        calendars = []
        defaultCalendarID = nil
        isLoading = false
        errorMessage = nil
    }

    func refreshAgenda(from start: Date, to end: Date) async {
        access = Self.currentAccess()
        lastRange = DateInterval(start: start, end: max(start, end))
        guard isEnabled, access.canRead else { events = []; calendars = []; isLoading = false; return }
        let request = UUID()
        refreshID = request
        isLoading = true
        do {
            let snapshot = try await database.snapshot(from: start, to: end)
            guard request == refreshID, isEnabled, !Task.isCancelled else { return }
            events = snapshot.events
            calendars = snapshot.calendars
            defaultCalendarID = snapshot.defaultCalendarID
            errorMessage = nil
        } catch {
            guard request == refreshID else { return }
            events = []
            errorMessage = error.localizedDescription
        }
        if request == refreshID { isLoading = false }
    }

    func events(from start: Date, to end: Date) async throws -> [MailCalendarEvent] {
        guard isEnabled, Self.currentAccess().canRead else { throw MailCalendarError.accessRequired }
        return try await database.snapshot(from: start, to: end).events
    }

    /// Called only after the event review's Add Event button. Creation requests
    /// write-only access unless the person already opted in to the agenda.
    func saveReviewedEvent(_ draft: MailCalendarEventDraft) async throws -> String {
        let draft = try draft.validated()
        access = Self.currentAccess()
        if !access.canWrite {
            guard access == .notDetermined else { throw MailCalendarError.accessDenied }
            guard Bundle.main.object(forInfoDictionaryKey: "NSCalendarsWriteOnlyAccessUsageDescription") != nil else {
                throw MailCalendarError.missingPrivacyDescription
            }
            let granted = try await database.requestAccess(full: false)
            access = Self.currentAccess()
            guard granted, access.canWrite else { throw MailCalendarError.accessDenied }
        }
        let id = try await database.save(draft)
        if let range = lastRange, isEnabled { await refreshAgenda(from: range.start, to: range.end) }
        return id
    }

    private static func currentAccess() -> MailCalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .restricted: .restricted
        case .writeOnly: .writeOnly
        case .fullAccess: .full
        @unknown default: .unavailable
        }
    }
}
