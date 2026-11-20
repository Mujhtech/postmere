import Foundation

@main
private struct CalendarChecks {
    @MainActor
    static func main() async throws {
        let zone = TimeZone(identifier: "America/Los_Angeles")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let day = calendar.date(from: DateComponents(year: 2027, month: 3, day: 14))!
        let nine = calendar.date(bySettingHour: 9, minute: 0, second: 0, of: day)!
        let all = MailAvailability.slots(on: day, busyEvents: [], timeZone: zone, now: .distantPast)
        precondition(all.count == 16 && all.first?.start == nine, "DST must not move 9 am working hours")
        let busy = MailCalendarEvent(id: "busy", title: "Private title", start: nine.addingTimeInterval(1_800),
            end: nine.addingTimeInterval(5_400), isAllDay: false, calendarTitle: "Calendar", location: "", isBusy: true)
        let free = MailCalendarEvent(id: "free", title: "Free event", start: nine, end: nine.addingTimeInterval(1_800),
            isAllDay: false, calendarTitle: "Calendar", location: "", isBusy: false)
        let available = MailAvailability.slots(on: day, busyEvents: [busy, free], timeZone: zone, now: .distantPast)
        precondition(available.count == 14 && available.first?.start == nine, "Half-open conflicts must allow adjacent and free events")
        let allDay = MailCalendarEvent(id: "day", title: "Away", start: day, end: calendar.date(byAdding: .day, value: 1, to: day)!,
            isAllDay: true, calendarTitle: "Calendar", location: "", isBusy: true)
        precondition(MailAvailability.slots(on: day, busyEvents: [allDay], timeZone: zone, now: .distantPast).isEmpty)
        let text = MailAvailability.text(for: [all[1], all[0], all[0]], locale: Locale(identifier: "en_US"))
        precondition(text.components(separatedBy: "\n").count == 3 && text.contains("America/Los_Angeles") && text.contains("UTC−07:00"))
        precondition(!text.contains("Private title"), "Availability text must never disclose calendar event details")
        print("PASS: DST working hours, adjacent/free/all-day conflicts, deduplicated timezone-explicit availability")

        let invalid = MailCalendarEventDraft(title: "Meeting", start: nine, end: nine)
        do { _ = try invalid.validated(); preconditionFailure("Zero-length events must fail") } catch MailCalendarError.invalidDateRange { }
        do { _ = try MailCalendarEventDraft(title: "Meeting", urlString: "javascript:alert(1)").validated(); preconditionFailure("Unsafe event links must fail") } catch MailCalendarError.invalidLink { }
        do { _ = try MailCalendarEventDraft(title: "Meeting", timeZoneIdentifier: "Not/A_Timezone").validated(); preconditionFailure("Invalid time zones must fail") } catch MailCalendarError.invalidTimeZone { }
        let detection = MailDateDetector.suggestions(in: "Please join on November 24, 2027 at 3:30 PM for our review.")
        precondition(!detection.isEmpty && detection.first?.isAllDay == false && detection.first!.end > detection.first!.start)
        print("PASS: reviewable date recognition and event validation")

        let invitation = """
        BEGIN:VCALENDAR
        VERSION:2.0
        METHOD:REQUEST
        BEGIN:VEVENT
        UID:meeting-123@example.com
        SEQUENCE:3
        DTSTART:20271124T150000Z
        DTEND:20271124T160000Z
        SUMMARY:Project 
         review
        ORGANIZER;CN="Ada; Organizer":mailto:ada@example.com
        ATTENDEE;PARTSTAT=NEEDS-ACTION:mailto:me@example.com
        DESCRIPTION:First line\\nSecond\\, line
        LOCATION:Room 2
        X-GOOGLE-CONFERENCE:https://meet.google.com/abc-defg-hij
        URL:javascript:bad
        RRULE:FREQ=WEEKLY;COUNT=4
        BEGIN:VALARM
        SUMMARY:Alarm title must not replace the event
        END:VALARM
        END:VEVENT
        END:VCALENDAR
        """
        let parsed = try MailCalendarInvitationParser.parse(data: Data(invitation.utf8), defaultTimeZone: zone)
        precondition(parsed.count == 1)
        let event = parsed[0]
        precondition(event.title == "Project review" && event.sequence == 3 && event.organizer == "ada@example.com")
        precondition(event.attendees == ["me@example.com"] && event.notes == "First line\nSecond, line")
        precondition(event.end.timeIntervalSince(event.start) == 3_600 && event.canRespond && event.urlString.isEmpty)
        precondition(event.recurrence != nil && !event.warnings.isEmpty)
        let withoutEnd = try MailCalendarInvitationParser.parse(data: Data(invitation.replacingOccurrences(of: "DTEND:20271124T160000Z", with: "").utf8))[0]
        precondition(withoutEnd.hasEstimatedEnd && !withoutEnd.canRespond)
        precondition(event.meetingLink?.title == "Join Google Meet" && event.meetingLink?.url.host == "meet.google.com")
        let legacyHTML = #"<a href="https://meet.google.com/abc-defg-hij?authuser=0&amp;pli=1">Join</a>"#
        precondition(MailMeetingLink.first(in: legacyHTML, html: true)?.url.query == "authuser=0&pli=1")
        precondition(MailMeetingLink.first(in: #"<img src="https://meet.google.com/abc-defg-hij">"#, html: true) == nil)
        precondition(MailMeetingLink.first(in: "https://meet.google.com.attacker.example/abc-defg-hij") == nil)
        precondition(MailMeetingLink.first(in: "https://meet.google.com@attacker.example/abc-defg-hij") == nil)
        precondition(MailMeetingLink.first(in: "Meet at https://meet.google.com/abc-defg-hij.")?.title == "Join Google Meet")
        let canceled = try MailCalendarInvitationParser.parse(data: Data(invitation.replacingOccurrences(of: "METHOD:REQUEST", with: "METHOD:CANCEL").utf8))
        precondition(canceled[0].isCanceled && !canceled[0].canRespond)
        let daily = "BEGIN:VCALENDAR\nBEGIN:VEVENT\nUID:day\nDTSTART;VALUE=DATE:20270314\nSUMMARY:Day off\nEND:VEVENT\nEND:VCALENDAR"
        let dailyEvent = try MailCalendarInvitationParser.parse(data: Data(daily.utf8), defaultTimeZone: zone)[0]
        precondition(dailyEvent.isAllDay && dailyEvent.end.timeIntervalSince(dailyEvent.start) == 23 * 3_600,
                     "All-day exclusive end must follow the local day across DST")
        do { _ = try MailCalendarInvitationParser.parse(data: Data(repeating: 65, count: 512 * 1_024 + 1)); preconditionFailure("Oversized invitations must fail") } catch MailCalendarError.invitationTooLarge { }
        print("PASS: folded/escaped invitations, nested alarms, UTC, recurrence warnings, cancellation, safe URLs, and all-day DST")

        let suite = "Postmere-Calendar-Checks-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = MailCalendarService(defaults: defaults, observeChanges: false)
        precondition(!service.isEnabled && service.events.isEmpty)
        await service.refreshAgenda(from: day, to: day.addingTimeInterval(86_400))
        precondition(service.events.isEmpty && !service.isLoading)
        do { _ = try await service.events(from: day, to: day.addingTimeInterval(86_400)); preconditionFailure("Disabled integration must block reads") } catch MailCalendarError.accessRequired { }
        do { _ = try await service.saveReviewedEvent(MailCalendarEventDraft(title: "")); preconditionFailure("Invalid drafts must fail before any permission request") } catch MailCalendarError.missingTitle { }
        service.disconnectAgenda()
        precondition(!defaults.bool(forKey: "calendarIntegrationEnabled"))
        print("PASS: opt-in calendar gate and pre-permission validation; no permission request or calendar read/write performed")

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        let legacy = #"{"id":"11111111-1111-1111-1111-111111111111","account_id":"22222222-2222-2222-2222-222222222222","title":"Meeting","description":"","time_zone":"Africa/Lagos","duration_minutes":30,"url":"https://postmere.example/book/fixture","expires_at":"2027-03-20T00:00:00Z","created_at":"2027-03-01T00:00:00Z","slots":[]}"#
        let oldLink = try decoder.decode(BookingLink.self, from: Data(legacy.utf8))
        precondition(oldLink.calendarId == nil && oldLink.availability == nil)
        let rule = WeeklyBookingAvailability(startDate: "2027-03-02", endDate: "2027-03-19", weekdays: [1, 3, 5], startMinute: 540, endMinute: 1020)
        let payload = BookingLinkInput(accountId: oldLink.accountId, title: "Weekly", description: "", timeZone: "America/New_York", durationMinutes: 30, expiresAt: oldLink.expiresAt, slots: [], calendarId: "work@example.test", conflictCalendarIds: ["primary", "work@example.test"], availability: rule)
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        let encoded = try JSONSerialization.jsonObject(with: encoder.encode(payload)) as! [String: Any]
        precondition(encoded["calendar_id"] as? String == "work@example.test")
        let encodedRule = encoded["availability"] as! [String: Any]
        precondition(encodedRule["start_date"] as? String == "2027-03-02" && encodedRule["start_minute"] as? Int == 540)
        let list = try decoder.decode(ProviderCalendars.self, from: Data(#"{"items":[{"id":"primary","name":"Primary","is_primary":true,"can_write":true}],"requires_reconnect":true}"#.utf8))
        precondition(list.requiresReconnect && list.items.first?.isPrimary == true)
        let cancellation = try decoder.decode(CalendarBookingResult.self, from: Data(#"{"id":"11111111-1111-1111-1111-111111111111","status":"cancel_uncertain","start":"2027-03-20T09:00:00Z","end":"2027-03-20T09:30:00Z","message":"Cancellation pending"}"#.utf8))
        precondition(cancellation.status == "cancel_uncertain" && cancellation.end > cancellation.start)
        print("PASS: legacy booking responses, secondary calendars, weekly availability wire keys, reconnect state, and uncertain cancellation decoding")
    }
}
