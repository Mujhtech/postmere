import Foundation

nonisolated struct CalendarRSVPInput: Encodable, Sendable {
    let accountId: UUID
    let icalUid: String
    let organizer: String
    let start: Date
    let end: Date
    let response: String
}
nonisolated struct CalendarRSVPResult: Decodable, Sendable { let status: String; let response: String }
nonisolated struct BookingSlot: Codable, Identifiable, Sendable {
    var id: UUID = UUID()
    let start: Date
    let end: Date
}
nonisolated struct BookingSlotInput: Encodable, Sendable { let start: Date; let end: Date }
nonisolated struct BookingLinkInput: Encodable, Sendable {
    let accountId: UUID
    let title: String
    let description: String
    let timeZone: String
    let durationMinutes: Int
    let expiresAt: Date
    let slots: [BookingSlotInput]
}
nonisolated struct BookingLink: Decodable, Identifiable, Sendable {
    let id: UUID
    let accountId: UUID
    let title: String
    let description: String
    let timeZone: String
    let durationMinutes: Int
    let url: String
    let expiresAt: Date
    let disabledAt: Date?
    let createdAt: Date
    let slots: [BookingSlot]
}
nonisolated struct BookingLinks: Decodable, Sendable { let items: [BookingLink] }
nonisolated struct CalendarBooking: Decodable, Identifiable, Sendable {
    let id: UUID
    let linkId: UUID
    let start: Date
    let end: Date
    let guestName: String
    let guestEmail: String
    let status: String
    let createdAt: Date
}
nonisolated struct CalendarBookings: Decodable, Sendable { let items: [CalendarBooking] }
nonisolated struct SharedCalendar: Decodable, Identifiable, Sendable {
    let accountId: UUID
    let email: String
    let userId: UUID
    let enabled: Bool
    let isMine: Bool
    var id: UUID { accountId }
}
nonisolated struct SharedCalendars: Decodable, Sendable { let items: [SharedCalendar] }
nonisolated struct CalendarSharingInput: Encodable, Sendable { let enabled: Bool }
nonisolated struct FreeBusyInput: Encodable, Sendable { let accountIds: [UUID]; let start: Date; let end: Date }
nonisolated struct FreeBusyResult: Decodable, Sendable {
    let calendars: [CalendarBusyTimes]
    let start: Date
    let end: Date
}
nonisolated struct CalendarBusyTimes: Decodable, Identifiable, Sendable {
    let accountId: UUID
    let busy: [CalendarBusyInterval]
    var id: UUID { accountId }
}
nonisolated struct CalendarBusyInterval: Decodable, Sendable { let start: Date; let end: Date }
