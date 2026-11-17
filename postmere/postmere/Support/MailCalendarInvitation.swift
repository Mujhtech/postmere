import Foundation

nonisolated enum MailInvitationResponse: String, CaseIterable, Sendable {
    case accepted, tentative, declined
    var title: String {
        switch self {
        case .accepted: "Accept"
        case .tentative: "Maybe"
        case .declined: "Decline"
        }
    }
}

nonisolated struct MailCalendarInvitation: Identifiable, Sendable {
    let uid: String?
    let sequence: Int
    let method: String
    let title: String
    let start: Date
    let end: Date
    let timeZoneIdentifier: String
    let isAllDay: Bool
    let organizer: String
    let attendees: [String]
    let location: String
    let notes: String
    let urlString: String
    let recurrence: String?
    let isCanceled: Bool
    let warnings: [String]
    var id: String { "\(uid ?? title)|\(start.timeIntervalSince1970)|\(sequence)" }
    var canRespond: Bool { method == "REQUEST" && uid != nil && !organizer.isEmpty && !isCanceled }

    var eventDraft: MailCalendarEventDraft {
        MailCalendarEventDraft(title: title, start: start, end: end, timeZoneIdentifier: timeZoneIdentifier,
            isAllDay: isAllDay, location: location, notes: notes, urlString: urlString)
    }
}

/// Bounded, display-only iCalendar parsing. Remote attachments and linked
/// resources are never fetched. Scheduling/RSVP is a separate provider action.
/// Content unfolding, escaped TEXT and exclusive all-day DTEND follow RFC 5545.
nonisolated enum MailCalendarInvitationParser {
    private struct Property {
        let name: String
        let parameters: [String: String]
        let value: String
    }

    static func parse(data: Data, defaultTimeZone: TimeZone = .current) throws -> [MailCalendarInvitation] {
        guard data.count <= 512 * 1_024 else { throw MailCalendarError.invitationTooLarge }
        guard let text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw MailCalendarError.invalidInvitation }
        var lines: [String] = []
        for line in text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n").components(separatedBy: "\n") {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !lines.isEmpty { lines[lines.count - 1] += line.dropFirst() }
            else { lines.append(line) }
        }
        guard lines.contains(where: { $0.uppercased() == "BEGIN:VCALENDAR" }) else { throw MailCalendarError.invalidInvitation }
        var method = "PUBLISH"
        var properties: [Property]?
        var nestedDepth = 0
        var results: [MailCalendarInvitation] = []
        for line in lines {
            guard let property = property(line) else { continue }
            if property.name == "BEGIN", property.value.uppercased() == "VEVENT" {
                properties = []; nestedDepth = 0; continue
            }
            if property.name == "END", property.value.uppercased() == "VEVENT", nestedDepth == 0 {
                if let properties, let event = event(properties, method: method, defaultTimeZone: defaultTimeZone) { results.append(event) }
                properties = nil
                if results.count >= 32 { break }
                continue
            }
            if properties != nil {
                if property.name == "BEGIN" { nestedDepth += 1; continue }
                if property.name == "END" { nestedDepth = max(0, nestedDepth - 1); continue }
                if nestedDepth == 0 { properties?.append(property) }
            } else if property.name == "METHOD" { method = property.value.uppercased() }
        }
        guard !results.isEmpty else { throw MailCalendarError.invalidInvitation }
        return results
    }

    private static func event(_ properties: [Property], method: String, defaultTimeZone: TimeZone) -> MailCalendarInvitation? {
        func first(_ name: String) -> Property? { properties.first { $0.name == name } }
        guard let startProperty = first("DTSTART") else { return nil }
        let allDay = startProperty.parameters["VALUE"]?.uppercased() == "DATE" || startProperty.value.count == 8
        let requestedZone = startProperty.parameters["TZID"]
        let timeZone = startProperty.value.hasSuffix("Z") ? TimeZone(secondsFromGMT: 0)!
            : requestedZone.flatMap(TimeZone.init(identifier:)) ?? defaultTimeZone
        guard let start = date(startProperty, fallbackZone: timeZone) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        var warnings: [String] = []
        if let requestedZone, TimeZone(identifier: requestedZone) == nil {
            warnings.append("The time zone \(requestedZone) is not recognized. Review the times before adding a local event.")
        }
        let end: Date
        if let endProperty = first("DTEND"), let value = date(endProperty, fallbackZone: timeZone) { end = value }
        else if let duration = first("DURATION").flatMap({ duration($0.value, from: start, calendar: calendar) }) { end = duration }
        else if allDay { end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400) }
        else {
            end = start.addingTimeInterval(3_600)
            warnings.append("No supported end time was supplied. Review the proposed one-hour duration.")
        }
        guard end > start else { return nil }
        let recurrence = first("RRULE")?.value
        if recurrence != nil { warnings.append("This invitation repeats. Adding a local copy creates this occurrence only.") }
        let isCanceled = method == "CANCEL" || first("STATUS")?.value.uppercased() == "CANCELLED"
        let title = unescape(first("SUMMARY")?.value ?? "Calendar invitation")
        let urlString = first("URL")?.value ?? ""
        let safeURL = URL(string: urlString).flatMap { ["https", "http"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil && $0.user == nil && $0.password == nil ? $0.absoluteString : nil } ?? ""
        return MailCalendarInvitation(uid: first("UID")?.value.nilIfBlank, sequence: max(0, Int(first("SEQUENCE")?.value ?? "") ?? 0),
            method: method, title: title, start: start, end: end, timeZoneIdentifier: timeZone.identifier, isAllDay: allDay,
            organizer: address(first("ORGANIZER")?.value ?? ""),
            attendees: properties.filter { $0.name == "ATTENDEE" }.map { address($0.value) }.filter { !$0.isEmpty },
            location: unescape(first("LOCATION")?.value ?? ""), notes: unescape(first("DESCRIPTION")?.value ?? ""),
            urlString: safeURL, recurrence: recurrence, isCanceled: isCanceled, warnings: warnings)
    }

    private static func property(_ line: String) -> Property? {
        var quoted = false
        var separator: String.Index?
        for index in line.indices {
            if line[index] == "\"" { quoted.toggle() }
            if line[index] == ":", !quoted { separator = index; break }
        }
        guard let separator else { return nil }
        let left = String(line[..<separator])
        let value = String(line[line.index(after: separator)...])
        var pieces: [String] = []
        var piece = ""
        quoted = false
        for character in left {
            if character == "\"" { quoted.toggle() }
            if character == ";", !quoted { pieces.append(piece); piece = "" }
            else { piece.append(character) }
        }
        pieces.append(piece)
        guard let name = pieces.first, !name.isEmpty else { return nil }
        var parameters: [String: String] = [:]
        for piece in pieces.dropFirst() {
            let parts = piece.split(separator: "=", maxSplits: 1).map(String.init)
            if parts.count == 2 { parameters[parts[0].uppercased()] = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return Property(name: name.uppercased(), parameters: parameters, value: value)
    }

    private static func date(_ property: Property, fallbackZone: TimeZone) -> Date? {
        let value = property.value
        let isDate = property.parameters["VALUE"]?.uppercased() == "DATE" || value.count == 8
        guard value.range(of: isDate ? #"^\d{8}$"# : #"^\d{8}T\d{6}Z?$"#, options: .regularExpression) != nil else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = value.hasSuffix("Z") ? TimeZone(secondsFromGMT: 0)
            : property.parameters["TZID"].flatMap(TimeZone.init(identifier:)) ?? fallbackZone
        formatter.isLenient = false
        formatter.dateFormat = isDate ? "yyyyMMdd" : value.hasSuffix("Z") ? "yyyyMMdd'T'HHmmss'Z'" : "yyyyMMdd'T'HHmmss"
        return formatter.date(from: value)
    }

    private static func duration(_ value: String, from date: Date, calendar: Calendar) -> Date? {
        guard let expression = try? NSRegularExpression(pattern: #"^P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$"#),
              let match = expression.firstMatch(in: value, range: NSRange(location: 0, length: value.utf16.count)) else { return nil }
        let source = value as NSString
        func component(_ index: Int) -> Int { match.range(at: index).location == NSNotFound ? 0 : Int(source.substring(with: match.range(at: index))) ?? 0 }
        let weeks = component(1), days = component(2), hours = component(3), minutes = component(4), seconds = component(5)
        guard weeks <= 52, days <= 366, hours <= 8_784, minutes <= 527_040, seconds <= 31_622_400 else { return nil }
        return calendar.date(byAdding: DateComponents(day: weeks * 7 + days, hour: hours, minute: minutes, second: seconds), to: date)
    }

    private static func address(_ value: String) -> String {
        guard value.lowercased().hasPrefix("mailto:") else { return "" }
        let address = String(value.dropFirst(7)).removingPercentEncoding ?? String(value.dropFirst(7))
        guard address.range(of: #"^[^\s<>@]+@[^\s<>@]+\.[^\s<>@]+$"#, options: .regularExpression) != nil else { return "" }
        return address
    }

    private static func unescape(_ value: String) -> String {
        var result = ""
        var escaped = false
        for character in value {
            if escaped {
                result.append(character == "n" || character == "N" ? "\n" : character)
                escaped = false
            } else if character == "\\" { escaped = true }
            else { result.append(character) }
        }
        if escaped { result.append("\\") }
        return result
    }
}

nonisolated private extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
