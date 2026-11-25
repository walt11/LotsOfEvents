import AppIntents
import Foundation
import EventKit
import WidgetKit

enum ReminderDates {
    static func due(_ reminder: EKReminder) -> Date? {
        guard let components = reminder.dueDateComponents else { return nil }
        return (components.calendar ?? Calendar.current).date(from: components)
    }
    static func isOverdue(_ reminder: EKReminder, now: Date = .now) -> Bool {
        guard !reminder.isCompleted, let due = due(reminder) else { return false }
        return isOverdue(due: due, timed: reminder.dueDateComponents?.hour != nil, now: now)
    }
    /// The one definition of overdue: a timed task once its time passes, a date-only task once its day ends.
    static func isOverdue(due: Date, timed: Bool, now: Date = .now, calendar: Calendar = .current) -> Bool {
        timed ? due < now : due < calendar.startOfDay(for: now)
    }
    static func components(_ date: Date, timed: Bool, calendar: Calendar = .current) -> DateComponents {
        var result = calendar.dateComponents(timed ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day], from: date)
        result.calendar = calendar
        if timed { result.timeZone = calendar.timeZone }
        return result
    }
}

struct QuickAddParse: Equatable {
    var title: String
    var date: Date?
    var duration: TimeInterval?
    /// True when the text named a day but no time.
    var allDay = false
    var repeats: QuickAddRepeat? = nil
    /// How many days an all-day item covers, like "Dec 3-5" or "for 3 days".
    var spanDays = 1
}

/// A repeat named in Quick Add text, like "every day", "every other Tuesday", or "every Monday and Wednesday".
struct QuickAddRepeat: Equatable {
    var frequency: EKRecurrenceFrequency
    /// Days of the week (1 = Sunday … 7 = Saturday) for "every Monday" or "every weekday"; empty otherwise.
    var weekdays: [Int] = []
    var monthDay: Int? = nil
    /// 2 for "every other", 3 for "every 3 weeks".
    var interval = 1
    var title: String {
        if let monthDay { return "Every month on day \(monthDay)" }
        if interval == 1, weekdays == [2, 3, 4, 5, 6] { return "Every weekday" }
        if interval == 1, weekdays == [1, 7] { return "Every weekend" }
        let lead = interval == 1 ? "Every" : interval == 2 ? "Every other" : "Every \(interval)"
        if !weekdays.isEmpty {
            let calendar = Calendar.current
            let names = weekdays.count == 1 ? calendar.weekdaySymbols[weekdays[0] - 1]
                : weekdays.map { calendar.shortWeekdaySymbols[$0 - 1] }.joined(separator: ", ")
            return interval > 2 ? "Every \(interval) weeks on \(names)" : "\(lead) \(names)"
        }
        let unit: String
        switch frequency {
        case .daily: unit = "day"
        case .weekly: unit = "week"
        case .monthly: unit = "month"
        case .yearly: unit = "year"
        @unknown default: return "Repeats"
        }
        return "\(lead) \(unit)\(interval > 2 ? "s" : "")"
    }
    var rule: EKRecurrenceRule {
        EKRecurrenceRule(recurrenceWith: frequency, interval: max(1, interval),
                         daysOfTheWeek: weekdays.isEmpty ? nil : weekdays.compactMap { EKWeekday(rawValue: $0).map(EKRecurrenceDayOfWeek.init) },
                         daysOfTheMonth: monthDay.map { [NSNumber(value: $0)] }, monthsOfTheYear: nil, weeksOfTheYear: nil, daysOfTheYear: nil, setPositions: nil, end: nil)
    }
}

/// Pulls a date or time out of phrases such as "Lunch with Sam Friday 1pm".
enum QuickAddParser {
    private static func regex(_ pattern: String) -> NSRegularExpression { try! NSRegularExpression(pattern: pattern, options: .caseInsensitive) }
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    private static let timeWords = regex(#"\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.)|\d{1,2}:\d{2}|\b(noon|midnight|morning|afternoon|evening|tonight)\b"#)
    private static let dayName = "(?:sunday|monday|tuesday|wednesday|thursday|friday|saturday|sun|mon|tues|tue|wed|thurs|thur|thu|fri|sat)"
    private static let fullDay = "(?:sunday|monday|tuesday|wednesday|thursday|friday|saturday)"
    private static let monthName = "(?:january|february|march|april|may|june|july|august|september|october|november|december|jan|feb|mar|apr|jun|jul|aug|sept|sep|oct|nov|dec)"
    private static let joiner = #"\s*(?:,\s*and|,|and|&|/|\+)\s*"#
    private static let rangeWord = #"\s*(?:-|–|—|\bto\b|\bthrough\b|\bthru\b|\buntil\b)\s*"#
    private static let ordinal = "(?:st|nd|rd|th)?"
    private static let monthlyPattern = regex(#"\b(?:every\s+month|monthly)\s+on\s+(?:the\s+)?(first|second|third|fourth|fifth|[12][0-9]|3[01]|[1-9])(?:st|nd|rd|th)?\b"#)
    private static let repeatPattern = regex(#"\b(?:every\s+(?:(?:other|\d+)\s+)?(?:"# + dayName + "s?(?:" + joiner + dayName + #"s?)*|day|week|month|year|weekday|workday|weekend)s?|(?:on\s+)?(?:weekdays|weekends)|daily|weekly|monthly|yearly|annually|bi-?weekly|fortnightly)\b"#)
    private static let pluralDays = regex(#"\b(?:on\s+)?("# + fullDay + "s(?:" + joiner + fullDay + #"s)*)\b"#)
    private static let dayInPhrase = regex(#"\b"# + dayName + #"s?\b"#)
    private static let monthRange = regex("\\b(" + monthName + #")\.?\s+(\d{1,2})"# + ordinal + rangeWord + "(?:(" + monthName + #")\.?\s+)?(\d{1,2})"# + ordinal + #"\b(?!\s*(?:am\b|pm\b|a\.m|p\.m|:))"#)
    private static let weekdayRange = regex("\\b(" + dayName + ")" + rangeWord + "(" + dayName + ")\\b")
    private static let timeRange = regex(#"(?:\bfrom\s+)?(?<![\d/:])\b(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\s*(?:-|–|—|\bto\b|\buntil\b|\btill?\b)\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\b"#)
    private static let lengthPattern = regex(#"\bfor\s+(?:(an?\s+hour\s+and\s+a\s+half)|(half\s+an?\s+hour)|(an?|\d+(?:\.\d+)?)\s*(minutes?|mins?|m|hours?|hrs?|h|days?|d|weeks?|wks?))\b"#)
    private static let relativePattern = regex(#"\bin\s+(?:(half\s+an?\s+hour)|(an?|\d+(?:\.\d+)?)\s*(minutes?|mins?|hours?|hrs?|days?|weeks?|months?))\b"#)
    private static let namesDayPattern = regex(#"\b(?:today|tonight|tomorrow|tmrw|yesterday)\b|\b"# + dayName + #"\b|\b"# + monthName + #"\.?\s+\d{1,2}\b|\b\d{1,2}"# + ordinal + #"\s+(?:of\s+)?"# + monthName + #"\b|\d{1,2}/\d{1,2}|\bnext\s+(?:week|month|year|weekend|"# + dayName + #")\b|\bthe\s+\d{1,2}(?:st|nd|rd|th)\b|\bin\s+(?:half\s+an?\s+hour|(?:an?|\d+(?:\.\d+)?)\s*(?:minutes?|mins?|hours?|hrs?|days?|weeks?|months?))\b"#)

    private static func tidy(_ text: String) -> String { text.split(whereSeparator: \.isWhitespace).joined(separator: " ") }
    private static func removing(_ range: Range<String.Index>, from text: String, inserting replacement: String = " ") -> String {
        tidy(text.replacingCharacters(in: range, with: " \(replacement) "))
    }
    private static func group(_ match: NSTextCheckingResult, _ index: Int, in text: String) -> String? {
        Range(match.range(at: index), in: text).map { String(text[$0]) }
    }
    private static func first(_ pattern: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text))
    }
    private static func dayIndex(_ name: String) -> Int? {
        ["sun", "mon", "tue", "wed", "thu", "fri", "sat"].firstIndex(of: String(name.lowercased().prefix(3))).map { $0 + 1 }
    }
    private static func monthIndex(_ name: String) -> Int? {
        ["jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec"].firstIndex(of: String(name.lowercased().prefix(3))).map { $0 + 1 }
    }
    private static func days(in phrase: String) -> [Int] {
        let matches = dayInPhrase.matches(in: phrase, range: NSRange(phrase.startIndex..., in: phrase))
        return Array(Set(matches.compactMap { group($0, 0, in: phrase).flatMap(dayIndex) })).sorted()
    }

    /// Finds a repeat phrase and returns it with the phrase removed from the text.
    static func extractRepeat(_ text: String) -> (repeats: QuickAddRepeat?, rest: String) {
        if let match = first(monthlyPattern, in: text), let range = Range(match.range, in: text), let number = group(match, 1, in: text)?.lowercased() {
            let day = Int(number) ?? ["first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5][number]!
            return (QuickAddRepeat(frequency: .monthly, monthDay: day), removing(range, from: text))
        }
        if let match = first(repeatPattern, in: text), let range = Range(match.range, in: text) {
            return (repeatFrom(String(text[range]).lowercased()), removing(range, from: text))
        }
        if let match = first(pluralDays, in: text), let range = Range(match.range, in: text) {
            return (QuickAddRepeat(frequency: .weekly, weekdays: days(in: String(text[range]))), removing(range, from: text))
        }
        return (nil, text)
    }
    private static func repeatFrom(_ phrase: String) -> QuickAddRepeat {
        var interval = 1
        if phrase.contains(" other ") || phrase.hasPrefix("bi") || phrase == "fortnightly" { interval = 2 }
        else if let number = phrase.split(separator: " ").compactMap({ Int($0) }).first { interval = max(1, number) }
        let named = days(in: phrase)
        if !named.isEmpty { return QuickAddRepeat(frequency: .weekly, weekdays: named, interval: interval) }
        if phrase.contains("weekday") || phrase.contains("workday") { return QuickAddRepeat(frequency: .weekly, weekdays: [2, 3, 4, 5, 6], interval: interval) }
        if phrase.contains("weekend") { return QuickAddRepeat(frequency: .weekly, weekdays: [1, 7], interval: interval) }
        if phrase.contains("week") || phrase == "fortnightly" { return QuickAddRepeat(frequency: .weekly, interval: interval) }
        if phrase.contains("day") || phrase == "daily" { return QuickAddRepeat(frequency: .daily, interval: interval) }
        if phrase.contains("month") { return QuickAddRepeat(frequency: .monthly, interval: interval) }
        return QuickAddRepeat(frequency: .yearly, interval: interval)
    }

    /// "Dec 3-5", "Dec 28 to Jan 2", or "Friday to Sunday": keeps the first day and returns how many days it covers.
    private static func extractDayRange(_ text: String, calendar: Calendar, now: Date) -> (days: Int, rest: String) {
        if let match = first(monthRange, in: text), let range = Range(match.range, in: text),
           let startName = group(match, 1, in: text), let startMonth = monthIndex(startName),
           let startDay = group(match, 2, in: text).flatMap(Int.init), let endDay = group(match, 4, in: text).flatMap(Int.init) {
            let endMonth = group(match, 3, in: text).flatMap(monthIndex) ?? startMonth
            let year = calendar.component(.year, from: now)
            if let start = calendar.date(from: DateComponents(year: year, month: startMonth, day: startDay)),
               var end = calendar.date(from: DateComponents(year: year, month: endMonth, day: endDay)) {
                if end < start, let next = calendar.date(byAdding: .year, value: 1, to: end) { end = next }
                let count = (calendar.dateComponents([.day], from: start, to: end).day ?? 0) + 1
                if (2...366).contains(count) { return (count, removing(range, from: text, inserting: "\(startName) \(startDay)")) }
            }
        }
        if let match = first(weekdayRange, in: text), let range = Range(match.range, in: text),
           let startName = group(match, 1, in: text), let startIndex = dayIndex(startName),
           let endIndex = group(match, 2, in: text).flatMap(dayIndex), startIndex != endIndex {
            return ((endIndex - startIndex + 7) % 7 + 1, removing(range, from: text, inserting: startName))
        }
        return (1, text)
    }

    /// "2-4pm", "2pm to 3:30pm", or "from 9:00 to 10:30": keeps the start time and returns the length.
    private static func extractTimeRange(_ text: String) -> (minutes: Int?, rest: String) {
        guard let match = first(timeRange, in: text), let range = Range(match.range, in: text),
              let h1 = group(match, 1, in: text).flatMap(Int.init), let h2 = group(match, 4, in: text).flatMap(Int.init),
              h1 <= 23, h2 <= 23 else { return (nil, text) }
        let m1 = group(match, 2, in: text).flatMap(Int.init), m2 = group(match, 5, in: text).flatMap(Int.init)
        let mer1 = group(match, 3, in: text)?.lowercased(), mer2 = group(match, 6, in: text)?.lowercased()
        guard mer1 != nil || mer2 != nil || (m1 != nil && m2 != nil), (m1 ?? 0) < 60, (m2 ?? 0) < 60 else { return (nil, text) }
        func clock(_ hour: Int, _ meridiem: String?) -> Int {
            guard let meridiem, hour <= 12 else { return hour }
            return meridiem == "pm" ? (hour % 12) + 12 : hour % 12
        }
        var endHour = clock(h2, mer2 ?? mer1)
        var startHour = clock(h1, mer1 ?? mer2)
        let endMinutes = endHour * 60 + (m2 ?? 0)
        if mer1 == nil, mer2 != nil, startHour * 60 + (m1 ?? 0) >= endMinutes { startHour = clock(h1, mer2 == "pm" ? "am" : "pm") } // "11-1pm"
        if mer2 == nil, mer1 != nil, startHour * 60 + (m1 ?? 0) >= endMinutes, h2 <= 12 { endHour = clock(h2, mer1 == "pm" ? "am" : "pm") } // "11am-1"
        if mer1 == nil, mer2 == nil, startHour * 60 + (m1 ?? 0) >= endMinutes, endHour <= 12 { endHour += 12 }
        var length = endHour * 60 + (m2 ?? 0) - startHour * 60 - (m1 ?? 0)
        if length <= 0 { length += 24 * 60 }
        let spoken = "\(startHour % 12 == 0 ? 12 : startHour % 12):\(String(format: "%02d", m1 ?? 0))\(startHour < 12 ? "am" : "pm")"
        return (length, removing(range, from: text, inserting: spoken))
    }

    private enum Length: Equatable { case minutes(Double), days(Int) }
    /// "for 90 minutes", "for an hour", "for 3 days".
    private static func extractLength(_ text: String) -> (length: Length?, rest: String) {
        guard let match = first(lengthPattern, in: text), let range = Range(match.range, in: text) else { return (nil, text) }
        let rest = removing(range, from: text)
        if match.range(at: 1).location != NSNotFound { return (.minutes(90), rest) }
        if match.range(at: 2).location != NSNotFound { return (.minutes(30), rest) }
        guard let amount = group(match, 3, in: text)?.lowercased(), let unit = group(match, 4, in: text)?.lowercased() else { return (nil, text) }
        let value = Double(amount) ?? 1
        guard value > 0 else { return (nil, text) }
        if unit.hasPrefix("h") { return (.minutes(value * 60), rest) }
        if unit.hasPrefix("m") { return (.minutes(value), rest) }
        if unit.hasPrefix("w") { return (.days(max(1, Int(value * 7))), rest) }
        return (.days(max(1, Int(value))), rest)
    }

    private enum Relative { case seconds(TimeInterval), days(Int), months(Int) }
    /// "in 2 hours", "in half an hour", "in 3 days".
    private static func extractRelative(_ text: String) -> (relative: Relative?, rest: String) {
        guard let match = first(relativePattern, in: text), let range = Range(match.range, in: text) else { return (nil, text) }
        let rest = removing(range, from: text)
        if match.range(at: 1).location != NSNotFound { return (.seconds(1800), rest) }
        guard let amount = group(match, 2, in: text)?.lowercased(), let unit = group(match, 3, in: text)?.lowercased() else { return (nil, text) }
        let value = Double(amount) ?? 1
        guard value > 0 else { return (nil, text) }
        if unit.hasPrefix("mo") { return (.months(max(1, Int(value))), rest) }
        if unit.hasPrefix("mi") { return (.seconds(value * 60), rest) }
        if unit.hasPrefix("h") { return (.seconds(value * 3600), rest) }
        if unit.hasPrefix("w") { return (.days(max(1, Int(value * 7))), rest) }
        return (.days(max(1, Int(value))), rest)
    }

    /// A sensible start when a length is given for a day with no time, like "Lunch tomorrow for 90 minutes".
    private static func usualHour(for title: String) -> Int {
        let lowered = title.lowercased()
        if lowered.contains("breakfast") { return 8 }
        if lowered.contains("lunch") { return 12 }
        if lowered.contains("dinner") || lowered.contains("supper") { return 18 }
        return 9
    }

    static func parse(_ text: String, calendar: Calendar = .current, now: Date = .now) -> QuickAddParse {
        let (repeats, withoutRepeat) = extractRepeat(text.trimmingCharacters(in: .whitespacesAndNewlines))
        let (spanDays, afterDays) = extractDayRange(withoutRepeat, calendar: calendar, now: now)
        let (rangeMinutes, afterRange) = extractTimeRange(afterDays)
        let (length, afterLength) = extractLength(afterRange)
        let (relative, remaining) = extractRelative(afterLength)
        var result = parseDate(remaining, calendar: calendar)
        result.repeats = repeats

        switch relative {
        case .seconds(let seconds):
            result.date = now.addingTimeInterval(seconds)
            result.allDay = false
            if result.title.isEmpty { result.title = remaining }
        case .days, .months:
            let today = calendar.startOfDay(for: now)
            var target = today
            if case .days(let count) = relative { target = calendar.date(byAdding: .day, value: count, to: today) ?? today }
            if case .months(let count) = relative { target = calendar.date(byAdding: .month, value: count, to: today) ?? today }
            if let date = result.date, !result.allDay {
                let time = calendar.dateComponents([.hour, .minute], from: date)
                result.date = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: target)
            } else {
                result.date = target
                result.allDay = true
            }
            if result.title.isEmpty { result.title = remaining }
        case nil: break
        }

        if let rangeMinutes { result.duration = TimeInterval(rangeMinutes * 60) }
        switch length {
        case .minutes(let minutes):
            result.duration = minutes * 60
            if result.allDay, let date = result.date {
                result.date = calendar.date(bySettingHour: usualHour(for: result.title), minute: 0, second: 0, of: date)
                result.allDay = false
            }
        case .days(let count):
            if let date = result.date, !result.allDay {
                result.duration = TimeInterval(count) * 86400
                result.date = date
            } else {
                result.date = result.date ?? calendar.startOfDay(for: now)
                result.allDay = true
                result.spanDays = count
            }
        case nil: break
        }
        if spanDays > 1 {
            if result.allDay { result.spanDays = spanDays } else if result.date != nil { result.duration = TimeInterval(spanDays - 1) * 86400 + (result.duration ?? 3600) }
        }

        if let monthDay = repeats?.monthDay {
            let today = calendar.startOfDay(for: now)
            var components = DateComponents(day: monthDay)
            if let parsedDate = result.date, !result.allDay {
                let time = calendar.dateComponents([.hour, .minute], from: parsedDate)
                components.hour = time.hour; components.minute = time.minute
            }
            let base = result.date ?? today
            let start = calendar.dateInterval(of: .month, for: base)!.start
            if let next = calendar.nextDate(after: max(start.addingTimeInterval(-1), today.addingTimeInterval(-1)), matching: components, matchingPolicy: .strict) {
                result.date = next
                if components.hour == nil { result.allDay = true }
            }
        }
        // "every Monday and Wednesday" with no date starts on the next of those days (or today, if it is one).
        if let weekdays = repeats?.weekdays, !weekdays.isEmpty {
            let today = calendar.startOfDay(for: now)
            let start = (0..<7).lazy.compactMap { calendar.date(byAdding: .day, value: $0, to: today) }
                .first { weekdays.contains(calendar.component(.weekday, from: $0)) } ?? today
            if let date = result.date, !result.allDay, !namesDay(withoutRepeat) {
                let time = calendar.dateComponents([.hour, .minute], from: date)
                result.date = calendar.date(bySettingHour: time.hour ?? 9, minute: time.minute ?? 0, second: 0, of: start)
            } else if result.date == nil {
                result.date = start
                result.allDay = true
            }
        }
        return result
    }
    private static func parseDate(_ text: String, calendar: Calendar) -> QuickAddParse {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = extract(trimmed, calendar: calendar)
        // The detector reads words like "Lunch" or "Dinner" as times, which can swallow the whole title.
        // Keep the first word as the title and look for the date in the rest.
        guard result.title.isEmpty, result.date != nil else { return result }
        guard let space = trimmed.firstIndex(of: " ") else {
            // A lone "Lunch" is a title, while a lone "tomorrow" or "3pm" is only a date.
            return namesDay(trimmed) || timeWords.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil ? result : QuickAddParse(title: trimmed)
        }
        var rest = extract(String(trimmed[space...]).trimmingCharacters(in: .whitespaces), calendar: calendar)
        guard rest.date != nil else { return result }
        rest.title = ([String(trimmed[..<space])] + (rest.title.isEmpty ? [] : [rest.title])).joined(separator: " ")
        return rest
    }
    /// Whether the text mentions a day (as opposed to only a time), e.g. "Friday" or "tomorrow 3pm".
    /// Whole words only, so "Wedding", "Marketing", and "Monica" don't count.
    static func namesDay(_ text: String) -> Bool { first(namesDayPattern, in: text) != nil }
    private static func extract(_ trimmed: String, calendar: Calendar) -> QuickAddParse {
        let all = NSRange(trimmed.startIndex..., in: trimmed)
        guard let match = detector.firstMatch(in: trimmed, range: all), let date = match.date, let range = Range(match.range, in: trimmed) else {
            return QuickAddParse(title: trimmed)
        }
        let phrase = String(trimmed[range])
        // NSDataDetector doesn't report whether a time was given, so look for one in the matched words.
        let timed = timeWords.firstMatch(in: phrase, range: NSRange(phrase.startIndex..., in: phrase)) != nil
        var title = trimmed.replacingCharacters(in: range, with: " ")
            .components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        for suffix in [" at", " on", " by", " due", " from"] where title.lowercased().hasSuffix(suffix) {
            title = String(title.dropLast(suffix.count))
        }
        return QuickAddParse(title: title, date: timed ? date : calendar.startOfDay(for: date), duration: match.duration > 0 ? match.duration : nil, allDay: !timed)
    }
}

/// One-tap day and time shortcuts for Quick Add; each phrase is something the parser understands.
enum QuickAddShortcuts {
    static func days(now: Date = .now, calendar: Calendar = .current) -> [(label: String, phrase: String)] {
        // "This weekend" means today on a weekend, otherwise the coming Saturday.
        let weekend = calendar.isDateInWeekend(now) ? "today" : "Saturday"
        return [("Today", "today"), ("Tomorrow", "tomorrow"), ("This weekend", weekend), ("Next week", "next Monday")]
    }
    static let times: [(label: String, phrase: String)] = [("9 AM", "9am"), ("Noon", "12pm"), ("6 PM", "6pm")]
}

enum QuickAddKind: String, AppEnum {
    case event, reminder
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Item Type"
    static let caseDisplayRepresentations: [QuickAddKind: DisplayRepresentation] = [.event: "Event", .reminder: "Reminder"]
}

enum QuickAddError: LocalizedError {
    case noAccess(QuickAddKind), noDefault(QuickAddKind), empty
    var errorDescription: String? {
        switch self {
        case .noAccess(let kind): return kind == .event ? "Open LotsOfEvents and allow Calendar access." : "Open LotsOfEvents and allow Reminders access."
        case .noDefault(let kind): return kind == .event ? "Choose a default calendar in Settings → Calendar." : "Choose a default list in the Reminders app."
        case .empty: return "Type a title, like “Lunch Friday 1pm”."
        }
    }
}

/// Saves a parsed Quick Add phrase; shared by the in-app sheet and the system prompt intent.
enum QuickAddSaver {
    static func eventStart(_ parsed: QuickAddParse) -> Date { parsed.date ?? Date.now.roundedUpToHalfHour() }
    @discardableResult
    /// `calendarID` picks the calendar or list; nil uses the account default.
    static func save(_ parsed: QuickAddParse, as kind: QuickAddKind, in store: EKEventStore, calendarID: String? = nil) throws -> String {
        guard !parsed.title.isEmpty else { throw QuickAddError.empty }
        switch kind {
        case .reminder:
            guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw QuickAddError.noAccess(kind) }
            guard let list = calendarID.flatMap({ store.calendar(withIdentifier: $0) }) ?? store.defaultCalendarForNewReminders() else { throw QuickAddError.noDefault(kind) }
            let item = EKReminder(eventStore: store)
            item.title = parsed.title
            item.calendar = list
            // A repeating reminder needs a due date to repeat from; today if none was given.
            if let due = parsed.date ?? (parsed.repeats == nil ? nil : Calendar.current.startOfDay(for: .now)) {
                let timed = parsed.date != nil && !parsed.allDay
                item.dueDateComponents = ReminderDates.components(due, timed: timed)
                AlertDefaults.apply(to: item, due: due, timed: timed)
            }
            if let repeats = parsed.repeats { item.addRecurrenceRule(repeats.rule) }
            try store.save(item, commit: true)
            guard let due = parsed.date else { return "Added “\(parsed.title)” to \(list.title)." }
            return "Added “\(parsed.title)”, due \(describe(due, allDay: parsed.allDay))."
        case .event:
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw QuickAddError.noAccess(kind) }
            guard let calendar = calendarID.flatMap({ store.calendar(withIdentifier: $0) }) ?? store.defaultCalendarForNewEvents else { throw QuickAddError.noDefault(kind) }
            let start = eventStart(parsed)
            let event = EKEvent(eventStore: store)
            event.title = parsed.title
            event.calendar = calendar
            event.isAllDay = parsed.allDay
            event.startDate = start
            event.endDate = parsed.allDay ? Calendar.current.date(byAdding: .day, value: max(0, parsed.spanDays - 1), to: start) ?? start
                : start.addingTimeInterval(parsed.duration ?? 3600)
            AlertDefaults.apply(to: event)
            if let repeats = parsed.repeats { event.addRecurrenceRule(repeats.rule) }
            try store.save(event, span: .thisEvent, commit: true)
            return "Added “\(parsed.title)” \(describe(start, allDay: parsed.allDay))."
        }
    }
    private static func describe(_ date: Date, allDay: Bool) -> String {
        let calendar = Calendar.current
        let day = calendar.isDateInToday(date) ? "today" : calendar.isDateInTomorrow(date) ? "tomorrow" : date.formatted(.dateTime.weekday(.wide).month().day())
        return allDay ? day : "\(day) at \(date.formatted(date: .omitted, time: .shortened))"
    }
}

/// Asks for a phrase in a system prompt (from Control Center, the Lock Screen, the Action button, or Siri) and saves it without opening the app.
struct QuickAddIntent: AppIntent {
    static let title: LocalizedStringResource = "Quick Add"
    static let description = IntentDescription("Add an event or reminder by typing a phrase like “Lunch Friday 1pm”.")
    @Parameter(title: "What", requestValueDialog: IntentDialog("What would you like to add?")) var text: String
    @Parameter(title: "Add as", default: .event) var kind: QuickAddKind
    static var parameterSummary: some ParameterSummary { Summary("Add \(\.$text) as \(\.$kind)") }
    init() {}
    init(kind: QuickAddKind) { self.kind = kind }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let message = try QuickAddSaver.save(QuickAddParser.parse(text), as: kind, in: EKEventStore())
        WidgetCenter.shared.reloadAllTimelines()
        return .result(dialog: IntentDialog(stringLiteral: message))
    }
}
