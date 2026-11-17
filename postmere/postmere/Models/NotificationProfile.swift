import Foundation

struct NotificationProfile: Codable, Identifiable, Equatable {
    var id: String
    var enabled = false
    var scheduleEnabled = false
    var startMinute = 9 * 60
    var endMinute = 18 * 60
    var weekdays = Set(2...6)
    var showPreview = true

    private var openingMinute: Int { min(max(startMinute, 0), 1_439) }
    private var closingMinute: Int { min(max(endMinute, 0), 1_439) }
    private var validWeekdays: Set<Int> { weekdays.intersection(1...7) }

    func permits(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled else { return false }
        guard scheduleEnabled else { return true }
        let minute = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        let day = calendar.component(.weekday, from: date)
        // Equal times mean the whole selected calendar day, starting at midnight.
        if openingMinute == closingMinute { return validWeekdays.contains(day) }
        if openingMinute < closingMinute {
            return validWeekdays.contains(day) && minute >= openingMinute && minute < closingMinute
        }
        if minute >= openingMinute { return validWeekdays.contains(day) }
        let previousDay = day == 1 ? 7 : day - 1
        return minute < closingMinute && validWeekdays.contains(previousDay)
    }

    func nextPermittedDate(after date: Date, calendar: Calendar = .current) -> Date? {
        guard enabled else { return nil }
        if permits(date, calendar: calendar) { return date }
        guard scheduleEnabled, !validWeekdays.isEmpty else { return nil }
        let startOfDay = calendar.startOfDay(for: date)
        let minute = openingMinute == closingMinute ? 0 : openingMinute
        for offset in 0...8 {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startOfDay) else { continue }
            // During a fall-back transition the opening time can occur twice.
            // During a spring-forward gap, use the next existing local time.
            let candidates = [Calendar.RepeatedTimePolicy.first, .last].compactMap { policy in
                calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0,
                              of: day, matchingPolicy: .nextTime, repeatedTimePolicy: policy)
            }
            if let candidate = candidates.filter({
                $0 >= date && calendar.isDate($0, inSameDayAs: day) && permits($0, calendar: calendar)
            }).min() { return candidate }
        }
        return nil
    }
}
