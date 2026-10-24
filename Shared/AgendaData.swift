import EventKit
import SwiftUI

struct AgendaItem: Identifiable {
    let id: String
    let title: String
    let date: Date
    let allDay: Bool
    let reminder: Bool
    let source: String
    let color: Color
    var notes: String? = nil
    var eventIdentifier: String? = nil
    var eventStartDate: Date? = nil
    var endDate: Date? = nil
    var widgetTimeLabel: String {
        let start = eventStartDate ?? date
        guard !reminder, let endDate, endDate > start else { return start.formatted(date: .omitted, time: .shortened) }
        return "\(start.formatted(date: .omitted, time: .shortened))–\(endDate.formatted(date: .omitted, time: .shortened))"
    }
    var timeLabel: String { allDay ? (reminder ? "Due" : "All day") : date.formatted(date: .omitted, time: .shortened) }
}

enum Preferences {
    static let defaults = UserDefaults(suiteName: Bundle.main.object(forInfoDictionaryKey: "AgendaAppGroup") as? String ?? "group.com.walt.LotsOfEvents")!
    static var days: Int {
        get { max(2, min(14, defaults.object(forKey: "days") as? Int ?? 5)) }
        set { defaults.set(newValue, forKey: "days") }
    }
    static func selected(_ id: String, reminders: Bool) -> Bool {
        let key = reminders ? "reminderLists" : "calendars"
        guard let ids = defaults.stringArray(forKey: key) else { return !reminders }
        return ids.contains(id)
    }
    static func setSelected(_ id: String, enabled: Bool, reminders: Bool, available: [EKCalendar]) {
        var ids = Set(available.filter { selected($0.calendarIdentifier, reminders: reminders) }.map(\.calendarIdentifier))
        if enabled { ids.insert(id) } else { ids.remove(id) }
        defaults.set(Array(ids), forKey: reminders ? "reminderLists" : "calendars")
        defaults.set(0, forKey: "page")
    }
}

enum AgendaQuery {
    static func window(now: Date, days: Int, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.startOfDay(for: now)
        return DateInterval(start: start, end: calendar.date(byAdding: .day, value: days, to: start)!)
    }
    static func sorted(_ items: [AgendaItem]) -> [AgendaItem] {
        items.sorted { a, b in
            if a.date != b.date { return a.date < b.date }
            if a.allDay != b.allDay { return a.allDay }
            if a.title != b.title { return a.title.localizedStandardCompare(b.title) == .orderedAscending }
            return a.id < b.id
        }
    }
    static func load(store: EKEventStore, now: Date = .now, days: Int? = nil) async -> [AgendaItem] {
        let range = window(now: now, days: days ?? Preferences.days)
        var items: [AgendaItem] = []
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            let calendars = store.calendars(for: .event).filter { Preferences.selected($0.calendarIdentifier, reminders: false) }
            if !calendars.isEmpty {
                items += store.events(matching: store.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars)).map {
                    AgendaItem(id: "event:\($0.calendarItemIdentifier):\($0.startDate.timeIntervalSince1970)", title: $0.title ?? "Untitled event", date: max($0.startDate, range.start), allDay: $0.isAllDay, reminder: false, source: $0.calendar.title, color: Color(cgColor: $0.calendar.cgColor), notes: $0.notes, eventIdentifier: $0.eventIdentifier, eventStartDate: $0.startDate, endDate: $0.endDate)
                }
            }
        }
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            let calendars = store.calendars(for: .reminder).filter { Preferences.selected($0.calendarIdentifier, reminders: true) }
            if !calendars.isEmpty {
                let reminders: [EKReminder] = await withCheckedContinuation { continuation in
                    store.fetchReminders(matching: store.predicateForReminders(in: calendars)) { continuation.resume(returning: $0 ?? []) }
                }
                items += reminders.compactMap { reminder in
                    guard !reminder.isCompleted, let components = reminder.dueDateComponents,
                          let due = (components.calendar ?? Calendar.current).date(from: components),
                          due >= range.start, due < range.end else { return nil }
                    return AgendaItem(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Reminder", date: due, allDay: components.hour == nil, reminder: true, source: reminder.calendar.title, color: Color(cgColor: reminder.calendar.cgColor), notes: reminder.notes)
                }
            }
        }
        return sorted(items)
    }
}

/// Flat, low-saturation palettes with separate light and dark variants.
enum AgendaTheme: String, CaseIterable, Identifiable {
    case graphite, slate, sage, sand, clay, lavender, black
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    static var selected: AgendaTheme {
        AgendaTheme(rawValue: Preferences.defaults.string(forKey: "widgetTheme") ?? "") ?? .graphite
    }
    private var colors: (light: UInt, dark: UInt, ink: UInt, accent: UInt, darkAccent: UInt) {
        switch self {
        case .graphite: return (0xD2D0CC, 0x101112, 0x292B2D, 0x704B48, 0xAF8984)
        case .slate: return (0xC6CED3, 0x121920, 0x293B49, 0x3E586A, 0x829BAE)
        case .sage: return (0xC9CFC3, 0x161D17, 0x303F31, 0x445B46, 0x8FA187)
        case .sand: return (0xD5CBBA, 0x1D1914, 0x493E2E, 0x685337, 0xAF9878)
        case .clay: return (0xD4C3B9, 0x201715, 0x50372E, 0x744D40, 0xB18B7A)
        case .lavender: return (0xCCC5D3, 0x1A1621, 0x41354E, 0x604D71, 0x9E8DB0)
        case .black: return (0x000000, 0x000000, 0xE0DDD7, 0xA5A19A, 0xA5A19A)
        }
    }
    func background(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? colors.dark : colors.light) }
    func text(_ scheme: ColorScheme) -> Color { (scheme == .dark || self == .black) ? .white : .black }
    func secondary(_ scheme: ColorScheme) -> Color { text(scheme).opacity(0.6) }
    func accent(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? colors.darkAccent : colors.accent) }
    private func color(_ hex: UInt) -> Color {
        Color(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}


enum WidgetAgendaLayout {
    static func items(on day: Date, from items: [AgendaItem], calendar: Calendar = .current) -> [AgendaItem] {
        let start = calendar.startOfDay(for: day)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return items.filter { item in
            if item.reminder || item.endDate == nil { return item.date >= start && item.date < end }
            let eventStart = item.eventStartDate ?? item.date
            return eventStart < end && (item.endDate! > start || (item.endDate! == eventStart && eventStart >= start))
        }.sorted {
            if $0.allDay != $1.allDay { return $0.allDay }
            return $0.date < $1.date
        }
    }
    static func pages(items: [AgendaItem], height: CGFloat, headings: Bool, calendar: Calendar = .current) -> [[AgendaItem]] {
        var pages: [[AgendaItem]] = []
        var current: [AgendaItem] = []
        var used: CGFloat = 0
        for item in items {
            var header: CGFloat = headings && (current.last.map { !calendar.isDate($0.date, inSameDayAs: item.date) } ?? true) ? 15 : 0
            let row: CGFloat = item.allDay ? 15 : 27
            if !current.isEmpty && used + header + row > height {
                pages.append(current)
                current = []
                used = 0
                header = headings ? 15 : 0
            }
            current.append(item)
            used += header + row
        }
        if !current.isEmpty { pages.append(current) }
        return pages.isEmpty ? [[]] : pages
    }
}

struct WidgetTask: Identifiable {
    let id: String
    let title: String
    let due: Date?
    let timed: Bool
    let list: String
    let color: Color
    let writable: Bool
    let priority: Int
}

enum WidgetDashboardData {
    static func nextEvents(_ items: [AgendaItem], now: Date) -> [AgendaItem] {
        items.filter { !$0.reminder && !$0.allDay && ($0.endDate ?? $0.date) > now }
            .sorted { ($0.eventStartDate ?? $0.date) < ($1.eventStartDate ?? $1.date) }
    }
    static func sortedTasks(_ tasks: [WidgetTask]) -> [WidgetTask] {
        tasks.sorted {
            if $0.due != $1.due { return ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            if $0.priority != $1.priority { return ($0.priority == 0 ? 10 : $0.priority) < ($1.priority == 0 ? 10 : $1.priority) }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }
    static func monthDays(_ date: Date, calendar: Calendar = .current) -> [Date?] {
        let start = calendar.dateInterval(of: .month, for: date)!.start
        let offset = (calendar.component(.weekday, from: start) - calendar.firstWeekday + 7) % 7
        let count = calendar.range(of: .day, in: .month, for: date)!.count
        return Array(repeating: nil, count: offset) + (0..<count).map { calendar.date(byAdding: .day, value: $0, to: start) }
    }
    static func selectedDay(saved: Date, now: Date, month: Bool, calendar: Calendar = .current) -> Date {
        let start = month ? calendar.dateInterval(of: .month, for: now)!.start : calendar.startOfDay(for: now)
        let end = month ? calendar.dateInterval(of: .month, for: now)!.end : calendar.date(byAdding: .day, value: 5, to: start)!
        return saved >= start && saved < end ? calendar.startOfDay(for: saved) : calendar.startOfDay(for: now)
    }
}
