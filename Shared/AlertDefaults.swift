import EventKit
import Foundation

/// Default alert times, like Apple Calendar's and Reminders' settings. They're added as alarms on the items
/// the app creates, so Apple's Calendar and Reminders deliver them and they sync to the user's other devices.
/// Kept in the App Group so Quick Add from Control Center and Siri uses them too.
enum EventAlertOption: Int, CaseIterable, Identifiable {
    case none = -1, atTime = 0, minutes5 = 5, minutes10 = 10, minutes15 = 15, minutes30 = 30
    case hour1 = 60, hours2 = 120, day1 = 1440, days2 = 2880, week1 = 10080
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .atTime: return "At time of event"
        case .minutes5: return "5 minutes before"
        case .minutes10: return "10 minutes before"
        case .minutes15: return "15 minutes before"
        case .minutes30: return "30 minutes before"
        case .hour1: return "1 hour before"
        case .hours2: return "2 hours before"
        case .day1: return "1 day before"
        case .days2: return "2 days before"
        case .week1: return "1 week before"
        }
    }
}

/// All-day alerts fire on a chosen day at the time set in `AlertDefaults.allDayMinute` (9 AM by default, as in Apple Calendar).
enum AllDayAlertOption: Int, CaseIterable, Identifiable {
    case none = -1, dayOf = 0, dayBefore = 1, twoDaysBefore = 2, weekBefore = 7
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .dayOf: return "On day of event"
        case .dayBefore: return "1 day before"
        case .twoDaysBefore: return "2 days before"
        case .weekBefore: return "1 week before"
        }
    }
}

enum ReminderAlertOption: Int, CaseIterable, Identifiable {
    case none = -1, atTime = 0, minutes5 = 5, minutes15 = 15, minutes30 = 30, hour1 = 60, day1 = 1440
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .none: return "None"
        case .atTime: return "At due time"
        case .minutes5: return "5 minutes before"
        case .minutes15: return "15 minutes before"
        case .minutes30: return "30 minutes before"
        case .hour1: return "1 hour before"
        case .day1: return "1 day before"
        }
    }
}

enum AlertDefaults {
    private static var store: UserDefaults { Preferences.defaults }
    static var event: EventAlertOption {
        get { (store.object(forKey: "alertEvent") as? Int).flatMap(EventAlertOption.init) ?? .minutes15 }
        set { store.set(newValue.rawValue, forKey: "alertEvent") }
    }
    static var allDayEvent: AllDayAlertOption {
        get { (store.object(forKey: "alertAllDayEvent") as? Int).flatMap(AllDayAlertOption.init) ?? .dayOf }
        set { store.set(newValue.rawValue, forKey: "alertAllDayEvent") }
    }
    static var reminder: ReminderAlertOption {
        get { (store.object(forKey: "alertReminder") as? Int).flatMap(ReminderAlertOption.init) ?? .atTime }
        set { store.set(newValue.rawValue, forKey: "alertReminder") }
    }
    /// Time of day for all-day event alerts, in minutes after midnight; 9:00 AM by default.
    static var allDayMinute: Int {
        get { store.object(forKey: "alertAllDayMinute") as? Int ?? 540 }
        set { store.set(newValue, forKey: "alertAllDayMinute") }
    }
    /// Like Reminders' "Today Notification": an alert on the due day for reminders that have no time. Off by default,
    /// since Apple Reminders may already notify for these.
    static var dateOnlyEnabled: Bool {
        get { store.bool(forKey: "alertDateOnly") }
        set { store.set(newValue, forKey: "alertDateOnly") }
    }
    /// Minutes after midnight; 9:00 AM by default.
    static var dateOnlyMinute: Int {
        get { store.object(forKey: "alertDateOnlyMinute") as? Int ?? 540 }
        set { store.set(newValue, forKey: "alertDateOnlyMinute") }
    }

    /// The alarm offset from an event's start: from midnight for all-day events, as Apple Calendar stores them.
    static func eventOffset(allDay: Bool, timed: EventAlertOption = event, allDayOption: AllDayAlertOption = allDayEvent,
                            allDayMinute minute: Int = allDayMinute) -> TimeInterval? {
        if allDay {
            guard allDayOption != .none else { return nil }
            return TimeInterval(-allDayOption.rawValue * 86_400 + minute * 60)
        }
        guard timed != .none else { return nil }
        return TimeInterval(-timed.rawValue * 60)
    }
    /// When a new reminder's alert should fire, or nil for none.
    static func reminderAlarmDate(due: Date, timed: Bool, option: ReminderAlertOption = reminder,
                                  dateOnly: Bool = dateOnlyEnabled, dateOnlyMinute minute: Int = dateOnlyMinute,
                                  calendar: Calendar = .current) -> Date? {
        if timed { return option == .none ? nil : due.addingTimeInterval(TimeInterval(-option.rawValue * 60)) }
        guard dateOnly else { return nil }
        return calendar.date(byAdding: .minute, value: minute, to: calendar.startOfDay(for: due))
    }

    /// Adds the default alert to a new event that has none yet.
    static func apply(to event: EKEvent) {
        guard event.alarms?.isEmpty ?? true, let offset = eventOffset(allDay: event.isAllDay) else { return }
        event.addAlarm(EKAlarm(relativeOffset: offset))
    }
    /// Adds the default alert to a new reminder due on `due`.
    static func apply(to reminder: EKReminder, due: Date, timed: Bool) {
        guard let date = reminderAlarmDate(due: due, timed: timed) else { return }
        reminder.addAlarm(EKAlarm(absoluteDate: date))
    }
}

/// Counts for the Today's Reminders Lock Screen widget.
enum TodayReminderCounts {
    /// Open reminders due by the end of `now`'s day (including overdue ones), soonest first.
    static func dueToday(_ items: [(title: String, due: Date?)], now: Date, calendar: Calendar = .current) -> [String] {
        let end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return items.compactMap { item in item.due.map { ($0, item.title) } }
            .filter { $0.0 < end }.sorted { $0.0 < $1.0 }.map(\.1)
    }
}
