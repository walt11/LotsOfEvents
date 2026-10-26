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
        return reminder.dueDateComponents?.hour == nil ? due < Calendar.current.startOfDay(for: now) : due < now
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
}

/// Pulls a date or time out of phrases such as "Lunch with Sam Friday 1pm".
enum QuickAddParser {
    private static let detector = try! NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue)
    private static let timeWords = try! NSRegularExpression(pattern: #"\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.)|\d{1,2}:\d{2}|\b(noon|midnight|morning|afternoon|evening|tonight)\b"#, options: .caseInsensitive)
    static func parse(_ text: String, calendar: Calendar = .current) -> QuickAddParse {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let result = extract(trimmed, calendar: calendar)
        // The detector reads words like "Lunch" or "Dinner" as times, which can swallow the whole title.
        // Keep the first word as the title and look for the date in the rest.
        guard result.title.isEmpty, result.date != nil, let space = trimmed.firstIndex(of: " ") else { return result }
        var rest = extract(String(trimmed[space...]).trimmingCharacters(in: .whitespaces), calendar: calendar)
        guard rest.date != nil else { return result }
        rest.title = ([String(trimmed[..<space])] + (rest.title.isEmpty ? [] : [rest.title])).joined(separator: " ")
        return rest
    }
    /// Whether the text mentions a day (as opposed to only a time), e.g. "Friday" or "tomorrow 3pm".
    static func namesDay(_ text: String) -> Bool {
        let pattern = #"\b(today|tonight|tomorrow|yesterday|mon|tue|wed|thu|fri|sat|sun)[a-z]*\b|\b(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\b|\d{1,2}/\d{1,2}|\bnext\b"#
        return text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
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
            if let due = parsed.date {
                item.dueDateComponents = ReminderDates.components(due, timed: !parsed.allDay)
                AlertDefaults.apply(to: item, due: due, timed: !parsed.allDay)
            }
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
            event.endDate = start.addingTimeInterval(parsed.allDay ? 0 : parsed.duration ?? 3600)
            AlertDefaults.apply(to: event)
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
