import Foundation

nonisolated enum MailCalendarAccess: String, Sendable {
    case notDetermined, denied, restricted, writeOnly, full, unavailable
    var canRead: Bool { self == .full }
    var canWrite: Bool { self == .full || self == .writeOnly }
}

nonisolated struct MailCalendarChoice: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let source: String
    let isWritable: Bool
}

nonisolated struct MailCalendarEvent: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarTitle: String
    let location: String
    let isBusy: Bool
}

nonisolated struct MailCalendarEventDraft: Identifiable, Codable, Hashable, Sendable {
    var id = UUID()
    var title: String
    var start: Date
    var end: Date
    var timeZoneIdentifier: String
    var isAllDay: Bool
    var location: String
    var notes: String
    var urlString: String
    var calendarID: String?

    init(title: String = "", start: Date = .now, end: Date? = nil,
         timeZoneIdentifier: String = TimeZone.current.identifier, isAllDay: Bool = false,
         location: String = "", notes: String = "", urlString: String = "", calendarID: String? = nil) {
        self.title = title
        self.start = start
        self.end = end ?? start.addingTimeInterval(3_600)
        self.timeZoneIdentifier = timeZoneIdentifier
        self.isAllDay = isAllDay
        self.location = location
        self.notes = notes
        self.urlString = urlString
        self.calendarID = calendarID
    }

    func validated() throws -> Self {
        var result = self
        result.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.title.isEmpty else { throw MailCalendarError.missingTitle }
        guard let timeZone = TimeZone(identifier: timeZoneIdentifier) else { throw MailCalendarError.invalidTimeZone }
        guard start.timeIntervalSinceReferenceDate.isFinite, end.timeIntervalSinceReferenceDate.isFinite, end > start else {
            throw MailCalendarError.invalidDateRange
        }
        if isAllDay {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = timeZone
            result.start = calendar.startOfDay(for: start)
            result.end = calendar.startOfDay(for: end)
            guard result.end > result.start else { throw MailCalendarError.invalidDateRange }
        }
        result.urlString = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        if !result.urlString.isEmpty {
            guard let url = URL(string: result.urlString), ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil else { throw MailCalendarError.invalidLink }
        }
        return result
    }
}

nonisolated struct MailDateSuggestion: Identifiable, Hashable, Sendable {
    let id: String
    let matchedText: String
    let start: Date
    let end: Date
    let timeZoneIdentifier: String
    let isAllDay: Bool

    func eventDraft(title: String, notes: String = "") -> MailCalendarEventDraft {
        MailCalendarEventDraft(title: title, start: start, end: end, timeZoneIdentifier: timeZoneIdentifier,
                               isAllDay: isAllDay, notes: notes)
    }
}

nonisolated enum MailDateDetector {
    /// Detection proposes a reviewable draft only. Relative dates use the
    /// system detector's current date; they are never written automatically.
    static func suggestions(in text: String, timeZone: TimeZone = .current) -> [MailDateSuggestion] {
        let text = String(text.prefix(32_000))
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return [] }
        let source = text as NSString
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var seen: Set<String> = []
        return detector.matches(in: text, range: NSRange(location: 0, length: source.length)).compactMap { match in
            guard let date = match.date else { return nil }
            let matched = source.substring(with: match.range)
            let hasTime = matched.range(of: #"(?i)(\d\s*:\s*\d|\d\s*(a\.?m\.?|p\.?m\.?)\b|\bnoon\b|\bmidnight\b)"#, options: .regularExpression) != nil
            let zone = match.timeZone ?? timeZone
            var localCalendar = calendar
            localCalendar.timeZone = zone
            let start = hasTime ? date : localCalendar.startOfDay(for: date)
            let end = hasTime ? start.addingTimeInterval(match.duration > 0 ? match.duration : 3_600)
                : localCalendar.date(byAdding: .day, value: max(1, Int(match.duration / 86_400)), to: start) ?? start.addingTimeInterval(86_400)
            let identity = "\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)|\(zone.identifier)"
            guard seen.insert(identity).inserted else { return nil }
            return MailDateSuggestion(id: identity, matchedText: matched, start: start, end: end,
                                      timeZoneIdentifier: zone.identifier, isAllDay: !hasTime)
        }.prefix(8).map { $0 }
    }
}

nonisolated struct MailAvailabilitySlot: Identifiable, Hashable, Sendable {
    let start: Date
    let end: Date
    let timeZoneIdentifier: String
    var id: String { "\(start.timeIntervalSince1970)|\(end.timeIntervalSince1970)|\(timeZoneIdentifier)" }
}

nonisolated enum MailAvailability {
    static func slots(on day: Date, busyEvents: [MailCalendarEvent], durationMinutes: Int = 30,
                      startHour: Int = 9, endHour: Int = 17, timeZone: TimeZone = .current,
                      now: Date = .now) -> [MailAvailabilitySlot] {
        guard [15, 30, 45, 60, 90, 120].contains(durationMinutes), (0...23).contains(startHour),
              (1...24).contains(endHour), startHour < endHour else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let dayStart = calendar.startOfDay(for: day)
        guard let first = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: dayStart),
              let last = endHour == 24 ? calendar.date(byAdding: .day, value: 1, to: dayStart)
                : calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: dayStart) else { return [] }
        var start = first
        var result: [MailAvailabilitySlot] = []
        while let end = calendar.date(byAdding: .minute, value: durationMinutes, to: start), end <= last {
            if start >= now && !busyEvents.contains(where: { $0.isBusy && $0.start < end && $0.end > start }) {
                result.append(MailAvailabilitySlot(start: start, end: end, timeZoneIdentifier: timeZone.identifier))
            }
            start = end
        }
        return result
    }

    static func text(for slots: [MailAvailabilitySlot], locale: Locale = .current) -> String {
        let slots = Array(Set(slots)).sorted { $0.start < $1.start }
        guard !slots.isEmpty else { return "" }
        let formatter = DateFormatter()
        formatter.locale = locale
        var lines = ["I’m available at these times:"]
        for slot in slots {
            let zone = TimeZone(identifier: slot.timeZoneIdentifier) ?? .current
            formatter.timeZone = zone
            formatter.setLocalizedDateFormatFromTemplate("EEE MMM d jmm")
            let start = formatter.string(from: slot.start)
            formatter.setLocalizedDateFormatFromTemplate("jmm")
            let end = formatter.string(from: slot.end)
            let seconds = zone.secondsFromGMT(for: slot.start)
            let sign = seconds < 0 ? "−" : "+"
            let offset = String(format: "UTC%@%02d:%02d", sign, abs(seconds) / 3_600, abs(seconds) % 3_600 / 60)
            lines.append("• \(start)–\(end) (\(zone.identifier), \(offset))")
        }
        return lines.joined(separator: "\n")
    }
}

nonisolated enum MailCalendarError: LocalizedError {
    case accessRequired, accessDenied, missingPrivacyDescription, noWritableCalendar, readOnlyCalendar
    case missingTitle, invalidDateRange, invalidTimeZone, invalidLink, invalidInvitation, invitationTooLarge

    var errorDescription: String? {
        switch self {
        case .accessRequired: "Connect Calendar to read your events."
        case .accessDenied: "Calendar access is unavailable. You can change Postmere’s access in System Settings."
        case .missingPrivacyDescription: "Calendar access is not configured in this build."
        case .noWritableCalendar: "No writable calendar is available. Add one in Calendar first."
        case .readOnlyCalendar: "Choose a calendar that allows new events."
        case .missingTitle: "Give this event a title."
        case .invalidDateRange: "The event must end after it starts."
        case .invalidTimeZone: "Choose a valid time zone."
        case .invalidLink: "Use an http or https link without a username or password."
        case .invalidInvitation: "This file does not contain a supported calendar event."
        case .invitationTooLarge: "This invitation is too large to preview."
        }
    }
}
