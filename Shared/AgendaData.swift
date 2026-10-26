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
    /// The original item's ID when this row repeats a multi-day event on a later day.
    var sourceID: String? = nil
    var location: String? = nil
    /// The Agenda's second line: the list for reminders, otherwise where or how long. The color bar already identifies the calendar.
    var agendaDetail: String? {
        if reminder { return source }
        if let location, !location.isEmpty { return location }
        guard !allDay, !continuation, let endDate else { return nil }
        let seconds = endDate.timeIntervalSince(eventStartDate ?? date)
        guard seconds >= 60 else { return nil }
        return Duration.seconds(seconds).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
    /// True when this row shows an event that began before the row's day.
    var continuation: Bool { sourceID != nil || (eventStartDate.map { $0 < date } ?? false) }
    private var continuationLabel: String {
        guard let endDate, endDate > date, Calendar.current.isDate(endDate, inSameDayAs: date) else { return "All day" }
        return "Until \(endDate.formatted(date: .omitted, time: .shortened))"
    }
    var widgetTimeLabel: String {
        if continuation && !allDay { return continuationLabel }
        let start = eventStartDate ?? date
        guard !reminder, let endDate, endDate > start else { return start.formatted(date: .omitted, time: .shortened) }
        return "\(start.formatted(date: .omitted, time: .shortened))–\(endDate.formatted(date: .omitted, time: .shortened))"
    }
    var timeLabel: String {
        if continuation && !allDay { return continuationLabel }
        return allDay ? (reminder ? "Due" : "All day") : date.formatted(date: .omitted, time: .shortened)
    }
}

extension Date {
    /// The next :00 or :30 boundary in local time, used as the default start for new events.
    func roundedUpToHalfHour(calendar: Calendar = .current) -> Date {
        let hour = calendar.dateInterval(of: .hour, for: self)!.start
        let offset = timeIntervalSince(hour)
        return offset == 0 ? self : hour.addingTimeInterval(offset <= 1800 ? 1800 : 3600)
    }
}

extension EKCalendarItem {
    // A deleted item loses its calendar, and EventKit's implicitly unwrapped `calendar` would crash.
    var calendarColor: Color { Color(cgColor: calendar?.cgColor ?? CGColor(gray: 0.6, alpha: 1)) }
    var calendarTitle: String { calendar?.title ?? "" }
    var isWritable: Bool { calendar?.allowsContentModifications ?? false }
}

/// The app accent, kept in the App Group so widgets use the same color. -1 means the default graphite steel blue.
enum AccentStore {
    static let key = "appAccentRGB"
    static var rgb: Int { Preferences.defaults.object(forKey: key) as? Int ?? -1 }
    static func color(_ rgb: Int) -> Color {
        if rgb == -1 { return GalleryPalette.accent }
        return Color(red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255, blue: Double(rgb & 255) / 255)
    }
    /// Black or white, whichever reads better on the accent.
    static func contrastingText(_ rgb: Int) -> Color {
        if rgb == -1 { return GalleryPalette.onAccent }
        let channels = [Double((rgb >> 16) & 255), Double((rgb >> 8) & 255), Double(rgb & 255)].map { value -> Double in
            let c = value / 255
            return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722 > 0.179 ? .black : .white
    }
    /// Earlier builds kept the accent in the app's own defaults, out of the widgets' reach.
    static func migrateFromAppDefaults() {
        guard Preferences.defaults.object(forKey: key) == nil, let old = UserDefaults.standard.object(forKey: key) as? Int else { return }
        Preferences.defaults.set(old, forKey: key)
        UserDefaults.standard.removeObject(forKey: key)
    }
}

enum Preferences {
    // UserDefaults is documented as thread-safe.
    nonisolated(unsafe) static let defaults = UserDefaults(suiteName: Bundle.main.object(forInfoDictionaryKey: "AgendaAppGroup") as? String ?? "group.com.walt.LotsOfEvents")!
    static var days: Int {
        get { max(2, min(14, defaults.object(forKey: "days") as? Int ?? 5)) }
        set { defaults.set(newValue, forKey: "days") }
    }
    /// Reminder lists are opt-in. Calendars are stored as exclusions so calendars added later appear by default.
    static func selected(_ id: String, reminders: Bool, in store: UserDefaults = defaults) -> Bool {
        if reminders { return store.stringArray(forKey: "reminderLists")?.contains(id) ?? false }
        if let hidden = store.stringArray(forKey: "hiddenCalendars") { return !hidden.contains(id) }
        return store.stringArray(forKey: "calendars")?.contains(id) ?? true
    }
    static func setSelected(_ id: String, enabled: Bool, reminders: Bool, available: [String], in store: UserDefaults = defaults) {
        if reminders {
            var ids = Set(available.filter { selected($0, reminders: true, in: store) })
            if enabled { ids.insert(id) } else { ids.remove(id) }
            store.set(Array(ids), forKey: "reminderLists")
        } else {
            migrateCalendars(available: available, in: store)
            var hidden = Set(store.stringArray(forKey: "hiddenCalendars") ?? [])
            if enabled { hidden.remove(id) } else { hidden.insert(id) }
            store.set(Array(hidden), forKey: "hiddenCalendars")
        }
        store.set(0, forKey: "page")
    }
    /// Converts the original explicit calendar selection into exclusions.
    static func migrateCalendars(available: [String], in store: UserDefaults = defaults) {
        guard store.stringArray(forKey: "hiddenCalendars") == nil, let legacy = store.stringArray(forKey: "calendars") else { return }
        store.set(available.filter { !legacy.contains($0) }, forKey: "hiddenCalendars")
        store.removeObject(forKey: "calendars")
    }
}

/// Carries EventKit objects, which aren't Sendable, out of EventKit's fetch callback.
struct EventKitResult<Value>: @unchecked Sendable { let value: Value }

extension EKEventStore {
    /// Runs in the caller's isolation, so a main-actor store never crosses actors.
    nonisolated(nonsending) func reminders(matching predicate: NSPredicate) async -> [EKReminder] {
        let result: EventKitResult<[EKReminder]> = await withCheckedContinuation { continuation in
            fetchReminders(matching: predicate) { continuation.resume(returning: EventKitResult(value: $0 ?? [])) }
        }
        return result.value
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
    /// `calendarIDs` and `listIDs` override the app's source selections, e.g. for a configured widget.
    nonisolated(nonsending) static func load(store: EKEventStore, now: Date = .now, days: Int? = nil, calendarIDs: Set<String>? = nil, listIDs: Set<String>? = nil) async -> [AgendaItem] {
        let range = window(now: now, days: days ?? Preferences.days)
        var items: [AgendaItem] = []
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            let calendars = store.calendars(for: .event).filter { calendarIDs?.contains($0.calendarIdentifier) ?? Preferences.selected($0.calendarIdentifier, reminders: false) }
            if !calendars.isEmpty {
                items += store.events(matching: store.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars)).map {
                    AgendaItem(id: "event:\($0.calendarItemIdentifier):\($0.startDate.timeIntervalSince1970)", title: $0.title ?? "Untitled event", date: max($0.startDate, range.start), allDay: $0.isAllDay, reminder: false, source: $0.calendar.title, color: Color(cgColor: $0.calendar.cgColor), notes: $0.notes, eventIdentifier: $0.eventIdentifier, eventStartDate: $0.startDate, endDate: $0.endDate, location: $0.location)
                }
            }
        }
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            let calendars = store.calendars(for: .reminder).filter { listIDs?.contains($0.calendarIdentifier) ?? Preferences.selected($0.calendarIdentifier, reminders: true) }
            if !calendars.isEmpty {
                let reminders = await store.reminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: calendars))
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
    case charcoal, gallery, graphite, slate, sage, sand, clay, lavender, black
    /// The user's own colors, gradient, and border from Settings (`CustomWidgetStyle`).
    case custom
    var id: String { rawValue }
    var title: String { self == .gallery ? "Soft Gallery" : rawValue.capitalized }
    static var selected: AgendaTheme {
        AgendaTheme(rawValue: Preferences.defaults.string(forKey: "widgetTheme") ?? "") ?? .charcoal
    }
    private var colors: (light: UInt, dark: UInt, ink: UInt, accent: UInt, darkAccent: UInt) {
        switch self {
        case .charcoal: return (0x303032, 0x303032, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF)
        case .gallery: return (0xFFFDF8, 0x2A3038, 0x342D27, 0xB94D2C, 0xE99B7E)
        case .graphite: return (0xD2D0CC, 0x101112, 0x292B2D, 0x704B48, 0xAF8984)
        case .slate: return (0xC6CED3, 0x121920, 0x293B49, 0x3E586A, 0x829BAE)
        case .sage: return (0xC9CFC3, 0x161D17, 0x303F31, 0x445B46, 0x8FA187)
        case .sand: return (0xD5CBBA, 0x1D1914, 0x493E2E, 0x685337, 0xAF9878)
        case .clay: return (0xD4C3B9, 0x201715, 0x50372E, 0x744D40, 0xB18B7A)
        case .lavender: return (0xCCC5D3, 0x1A1621, 0x41354E, 0x604D71, 0x9E8DB0)
        case .black: return (0x000000, 0x000000, 0xE0DDD7, 0xA5A19A, 0xA5A19A)
        case .custom: return (0xD2D0CC, 0x101112, 0x292B2D, 0x704B48, 0xAF8984)
        }
    }
    func background(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? colors.dark : colors.light) }
    /// The widget background; the custom theme can be a gradient with a border, so this is a view rather than a color.
    @ViewBuilder func backgroundView(_ scheme: ColorScheme) -> some View {
        if self == .custom { CustomWidgetStyle.saved.background }
        else if self == .charcoal {
            charcoalFill.overlay { ContainerRelativeShape().strokeBorder(Self.charcoalEdge, lineWidth: 0.5) }
        }
        else if self == .gallery {
            ZStack { background(scheme); ContainerRelativeShape().strokeBorder(color(scheme == .dark ? 0x454E59 : 0xDED8CB), lineWidth: 1) }
        } else { background(scheme) }
    }
    /// Compensated against the side-by-side device capture for the Home Screen surface highlight.
    var charcoalFill: LinearGradient {
        LinearGradient(stops: [.init(color: color(0x202022), location: 0), .init(color: color(0x1E1E20), location: 0.5), .init(color: color(0x1D1D1F), location: 0.93), .init(color: color(0x1D1D1F), location: 1)], startPoint: .top, endPoint: .bottom)
    }
    static var charcoalEdge: LinearGradient {
        LinearGradient(colors: [.white.opacity(0.06), .white.opacity(0.015), .white.opacity(0.04)], startPoint: .top, endPoint: .bottom)
    }
    /// The widget accent: the custom style's own accent if it has one, otherwise the app accent.
    func widgetAccent(appRGB: Int) -> (color: Color, onColor: Color, custom: Bool) {
        if self == .charcoal { return (.white, .black, true) }
        if self == .custom, let accent = CustomWidgetStyle.saved.accent {
            return (accent.color, CustomWidgetStyle.contrastingText(on: accent), true)
        }
        return (AccentStore.color(appRGB), AccentStore.contrastingText(appRGB), false)
    }
    func text(_ scheme: ColorScheme) -> Color {
        if self == .charcoal { return .white }
        if self == .gallery { return color(scheme == .dark ? 0xEEE7DB : 0x342D27) }
        if self == .custom { return CustomWidgetStyle.saved.text }
        return (scheme == .dark || self == .black) ? .white : .black
    }
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
    /// Lists each day's items in order, repeating multi-day events under every day they cover.
    static func byDay(_ items: [AgendaItem], start: Date, days: Int, calendar: Calendar = .current) -> [AgendaItem] {
        let first = calendar.startOfDay(for: start)
        return (0..<days).flatMap { offset -> [AgendaItem] in
            let day = calendar.date(byAdding: .day, value: offset, to: first)!
            return self.items(on: day, from: items, calendar: calendar).map { item in
                guard item.date < day else { return item }
                return AgendaItem(id: "\(item.sourceID ?? item.id)@\(day.timeIntervalSince1970)", title: item.title, date: day, allDay: item.allDay, reminder: item.reminder, source: item.source, color: item.color, notes: item.notes, eventIdentifier: item.eventIdentifier, eventStartDate: item.eventStartDate, endDate: item.endDate, sourceID: item.sourceID ?? item.id, location: item.location)
            }
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
    /// "3:00 PM" for later today, otherwise weekday and time.
    static func laterLabel(_ item: AgendaItem, now: Date, calendar: Calendar = .current) -> String {
        let start = item.eventStartDate ?? item.date
        return calendar.isDate(start, inSameDayAs: now) ? start.formatted(date: .omitted, time: .shortened) : start.formatted(.dateTime.weekday(.abbreviated).hour().minute())
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
