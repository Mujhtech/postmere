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
    var calendarId = "primary"
    var conflictCalendarIds = ["primary"]
    var availability: WeeklyBookingAvailability? = nil
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
    let calendarId: String?
    let conflictCalendarIds: [String]?
    let availability: WeeklyBookingAvailability?
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
    var statusLabel: String {
        switch status {
        case "checking", "creating": "Scheduling"
        case "confirmed": "Confirmed"
        case "uncertain": "Confirmation pending"
        case "cancelling", "cancel_uncertain": "Cancellation pending"
        case "cancelled": "Cancelled"
        case "failed": "Not booked"
        default: "Checking status"
        }
    }
}
nonisolated struct CalendarBookings: Decodable, Sendable { let items: [CalendarBooking] }
nonisolated struct SharedCalendar: Decodable, Identifiable, Sendable {
    let accountId: UUID
    let email: String
    let userId: UUID
    let enabled: Bool
    let isMine: Bool
    let calendarIds: [String]?
    var id: UUID { accountId }
}
nonisolated struct SharedCalendars: Decodable, Sendable { let items: [SharedCalendar] }
nonisolated struct CalendarSharingInput: Encodable, Sendable { let enabled: Bool; var calendarIds = ["primary"] }
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

nonisolated struct WeeklyBookingAvailability: Codable, Sendable {
    let startDate: String
    let endDate: String
    let weekdays: [Int]
    let startMinute: Int
    let endMinute: Int
}
nonisolated struct ProviderCalendar: Decodable, Identifiable, Sendable {
    let id: String
    let name: String
    let isPrimary: Bool
    let canWrite: Bool
}
nonisolated struct ProviderCalendars: Decodable, Sendable {
    let items: [ProviderCalendar]
    let requiresReconnect: Bool
}
nonisolated struct CalendarBookingResult: Decodable, Sendable {
    let id: UUID
    let status: String
    let start: Date
    let end: Date
    let message: String
}
