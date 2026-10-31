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
    /// A Zoom, Meet, Teams, or other video-call link found in the event.
    var joinURL: URL? = nil
    /// An invitation the user hasn't answered yet.
    var needsReply = false
    var birthday = false
    var blocksAvailability = true
    var contactDateID: String? = nil
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
    /// Just the start time, for one-line widget rows.
    var widgetStartLabel: String {
        if continuation && !allDay { return continuationLabel }
        return (eventStartDate ?? date).formatted(date: .omitted, time: .shortened)
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
    var isWritable: Bool { (self as? EKEvent)?.contactDateID == nil && (calendar?.allowsContentModifications ?? false) }
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
    /// Calendars and reminder lists are both shown unless hidden, so ones added later appear by default.
    /// Older builds stored an explicit list of chosen ones; those choices are kept until migrated.
    static func selected(_ id: String, reminders: Bool, in store: UserDefaults = defaults) -> Bool {
        let (hiddenKey, legacyKey) = keys(reminders: reminders)
        if let hidden = store.stringArray(forKey: hiddenKey) { return !hidden.contains(id) }
        return store.stringArray(forKey: legacyKey)?.contains(id) ?? true
    }
    private static func keys(reminders: Bool) -> (hidden: String, legacy: String) {
        reminders ? ("hiddenReminderLists", "reminderLists") : ("hiddenCalendars", "calendars")
    }
    static func setSelected(_ id: String, enabled: Bool, reminders: Bool, available: [String], in store: UserDefaults = defaults) {
        migrate(reminders: reminders, available: available, in: store)
        let key = keys(reminders: reminders).hidden
        var hidden = Set(store.stringArray(forKey: key) ?? [])
        if enabled { hidden.remove(id) } else { hidden.insert(id) }
        store.set(Array(hidden), forKey: key)
        store.set(0, forKey: "page")
        // The shown calendars no longer match a saved set.
        store.removeObject(forKey: "activeCalendarSet")
    }
    /// Converts the original explicit calendar selection into exclusions.
    static func migrateCalendars(available: [String], in store: UserDefaults = defaults) {
        migrate(reminders: false, available: available, in: store)
    }
    /// Converts an older explicit selection into exclusions.
    static func migrate(reminders: Bool, available: [String], in store: UserDefaults = defaults) {
        let (hiddenKey, legacyKey) = keys(reminders: reminders)
        guard store.stringArray(forKey: hiddenKey) == nil, let legacy = store.stringArray(forKey: legacyKey) else { return }
        store.set(available.filter { !legacy.contains($0) }, forKey: hiddenKey)
        store.removeObject(forKey: legacyKey)
    }
}

/// What the Today views (the Agenda's Today section and the Events + Tasks widget) show: reminders that are overdue
/// or due today from the shown lists, plus undated reminders from the lists chosen for Today.
enum TodayTasks {
    static let key = "todayUndatedLists"
    static var undatedLists: Set<String> {
        get { Set(Preferences.defaults.stringArray(forKey: key) ?? []) }
        set { Preferences.defaults.set(Array(newValue), forKey: key) }
    }
    /// `shown` is whether the reminder's list is shown in the agenda; undated reminders only need their list chosen for Today.
    /// Dated reminders count through `days` days from today, including overdue ones.
    static func includes(due: Date?, listID: String, shown: Bool, now: Date, days: Int = 1, undatedLists: Set<String> = undatedLists,
                         calendar: Calendar = .current) -> Bool {
        guard let due else { return undatedLists.contains(listID) }
        return shown && due < calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: now))!
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
        var birthdayContacts = Set<String>()
        if EKEventStore.authorizationStatus(for: .event) == .fullAccess {
            let calendars = store.calendars(for: .event).filter { calendarIDs?.contains($0.calendarIdentifier) ?? Preferences.selected($0.calendarIdentifier, reminders: false) }
            if !calendars.isEmpty {
                let events = store.events(matching: store.predicateForEvents(withStart: range.start, end: range.end, calendars: calendars))
                birthdayContacts = Set(events.compactMap(\.birthdayContactIdentifier))
                items += events.map {
                    AgendaItem(id: "event:\($0.calendarItemIdentifier):\($0.startDate.timeIntervalSince1970)", title: $0.title ?? "Untitled event", date: max($0.startDate, range.start), allDay: $0.isAllDay, reminder: false, source: $0.calendar.title, color: Color(cgColor: $0.calendar.cgColor), notes: $0.notes, eventIdentifier: $0.eventIdentifier, eventStartDate: $0.startDate, endDate: $0.endDate, location: $0.location,
                               joinURL: MeetingLink.url(for: $0), needsReply: $0.needsReply, birthday: $0.isBirthday, blocksAvailability: $0.blocksTime)
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
        items += ContactDates.items(in: range, excludingBirthdays: birthdayContacts)
        return sorted(items)
    }
}

/// Flat, low-saturation palettes with separate light and dark variants.
enum AgendaTheme: String, CaseIterable, Identifiable {
    /// Uses the app theme's colors, so widgets change along with the app.
    case matchApp
    case charcoal, gallery, graphite, slate, sage, sand, clay, lavender, black
    /// The user's own colors, gradient, and border from Settings (`CustomWidgetStyle`).
    case custom
    var id: String { rawValue }
    var title: String {
        switch self {
        case .gallery: return "Soft Gallery"
        case .matchApp: return "Match App Theme"
        default: return rawValue.capitalized
        }
    }
    static var selected: AgendaTheme {
        AgendaTheme(rawValue: Preferences.defaults.string(forKey: "widgetTheme") ?? "") ?? .matchApp
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
        case .matchApp:
            let c = AppTheme.current.colors
            return (c.card, c.card, c.ink, c.accent, c.accent)
        }
    }
    func background(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? colors.dark : colors.light) }
    /// The widget background; the custom theme can be a gradient with a border, so this is a view rather than a color.
    @ViewBuilder func backgroundView(_ scheme: ColorScheme) -> some View {
        if self == .custom { CustomWidgetStyle.saved.background }
        else if self == .charcoal {
            charcoalFill.overlay { ContainerRelativeShape().strokeBorder(Self.charcoalEdge, lineWidth: 0.5) }
        }
        else if self == .matchApp {
            ZStack { GalleryPalette.card; ContainerRelativeShape().strokeBorder(GalleryPalette.line, lineWidth: 0.5) }
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
    /// The widget accent: the widget's own choice, then the custom style's own accent, otherwise the app accent.
    func widgetAccent(appRGB: Int, chosen: WidgetAccentOption = .app) -> (color: Color, onColor: Color, custom: Bool) {
        if let rgb = chosen.rgb { return (AccentStore.color(rgb), AccentStore.contrastingText(rgb), true) }
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
        if self == .matchApp { return GalleryPalette.ink }
        return (scheme == .dark || self == .black) ? .white : .black
    }
    func secondary(_ scheme: ColorScheme) -> Color {
        if self == .custom { return CustomWidgetStyle.saved.secondary }
        return self == .matchApp ? GalleryPalette.muted : text(scheme).opacity(0.6)
    }
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
    static func pages(items: [AgendaItem], height: CGFloat, headings: Bool, rowHeight: CGFloat = 27, allDayHeight: CGFloat = 15,
                      headingHeight: CGFloat = 15, calendar: Calendar = .current) -> [[AgendaItem]] {
        var pages: [[AgendaItem]] = []
        var current: [AgendaItem] = []
        var used: CGFloat = 0
        for item in items {
            var header: CGFloat = headings && (current.last.map { !calendar.isDate($0.date, inSameDayAs: item.date) } ?? true) ? headingHeight : 0
            let row: CGFloat = item.allDay ? allDayHeight : rowHeight
            if !current.isEmpty && used + header + row > height {
                pages.append(current)
                current = []
                used = 0
                header = headings ? headingHeight : 0
            }
            current.append(item)
            used += header + row
        }
        if !current.isEmpty { pages.append(current) }
        return pages.isEmpty ? [[]] : pages
    }
}

/// Fits rows of varying heights into a widget without paging.
enum WidgetFit {
    /// How many leading rows fit in `height`, leaving room for a "+N more" line whenever some rows don't fit.
    static func count(_ heights: [CGFloat], in height: CGFloat, moreLine: CGFloat = 14) -> Int {
        if heights.reduce(0, +) <= height { return heights.count }
        var used: CGFloat = 0
        var fits = 0
        for row in heights {
            guard used + row + moreLine <= height else { break }
            used += row
            fits += 1
        }
        return fits
    }
}

/// Widgets can't scroll, so the Events + Tasks widget fakes it: it shows a window of rows starting at a saved
/// offset, and its up/down buttons move that offset.
enum WidgetScroll {
    /// How many rows from `start` fit in `height`.
    static func visible(_ heights: [CGFloat], from start: Int, in height: CGFloat) -> Int {
        var used: CGFloat = 0
        var count = 0
        for row in heights.dropFirst(start) {
            guard used + row <= height else { break }
            used += row
            count += 1
        }
        return count
    }
    /// The furthest offset worth scrolling to: the first row of the last screenful.
    static func maxStart(_ heights: [CGFloat], in height: CGFloat) -> Int {
        var used: CGFloat = 0
        var start = heights.count
        while start > 0, used + heights[start - 1] <= height {
            used += heights[start - 1]
            start -= 1
        }
        return start
    }
    /// Scrolling moves by a screenful less one row, so the last row stays in view for context.
    static func step(visible: Int) -> Int { max(1, visible - 1) }
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
    var overdue = false
    /// "Overdue", a time for timed reminders due today, or nil.
    var trailingLabel: String? {
        if overdue { return "Overdue" }
        guard let due, timed else { return nil }
        return due.formatted(date: .omitted, time: .shortened)
    }
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

/// Pure calculations shared by the widgets and their tests.
enum WidgetCompanionData {
    static func pages(heights: [CGFloat], height: CGFloat) -> [Range<Int>] {
        guard !heights.isEmpty else { return [0..<0] }
        var result: [Range<Int>] = []
        var start = 0, used: CGFloat = 0
        for index in heights.indices {
            if index > start && used + heights[index] > height {
                result.append(start..<index); start = index; used = 0
            }
            used += heights[index]
        }
        result.append(start..<heights.count)
        return result
    }

    /// Merge occupied intervals before finding gaps. All-day busy events block the working day;
    /// reminders and events explicitly marked Free do not.
    static func openSlots(items: [AgendaItem], now: Date, startHour: Int = 9, endHour: Int = 17,
                          minimumMinutes: Int = 30, calendar: Calendar = .current) -> [DateInterval] {
        guard (0...23).contains(startHour), (1...24).contains(endHour), startHour < endHour else { return [] }
        let day = calendar.startOfDay(for: now)
        guard let start = calendar.date(bySettingHour: startHour, minute: 0, second: 0, of: day),
              let end = endHour == 24 ? calendar.date(byAdding: .day, value: 1, to: day) : calendar.date(bySettingHour: endHour, minute: 0, second: 0, of: day) else { return [] }
        var cursor = max(start, now)
        guard cursor < end else { return [] }
        let busy = items.filter { !$0.reminder && $0.blocksAvailability }.compactMap { item -> DateInterval? in
            let a = max(start, item.eventStartDate ?? item.date)
            let b = min(end, item.endDate ?? item.date)
            return b > a ? DateInterval(start: a, end: b) : nil
        }.sorted { $0.start < $1.start }
        var gaps: [DateInterval] = []
        let minimum = TimeInterval(max(1, minimumMinutes) * 60)
        for interval in busy {
            if interval.start.timeIntervalSince(cursor) >= minimum { gaps.append(DateInterval(start: cursor, end: interval.start)) }
            cursor = max(cursor, interval.end)
        }
        if end.timeIntervalSince(cursor) >= minimum { gaps.append(DateInterval(start: cursor, end: end)) }
        return gaps
    }
    static func tomorrowTasks(_ tasks: [WidgetTask], now: Date, calendar: Calendar = .current) -> [WidgetTask] {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))!
        return WidgetDashboardData.sortedTasks(tasks.filter { $0.due.map { calendar.isDate($0, inSameDayAs: tomorrow) } ?? false })
    }
    static func overdueTasks(_ tasks: [WidgetTask], now: Date, calendar: Calendar = .current) -> [WidgetTask] {
        tasks.filter { task in
            guard let due = task.due else { return false }
            return task.timed ? due < now : due < calendar.startOfDay(for: now)
        }.sorted {
            let lhs = $0.priority == 0 ? 10 : $0.priority
            let rhs = $1.priority == 0 ? 10 : $1.priority
            if lhs != rhs { return lhs < rhs }
            if $0.due != $1.due { return ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
            return $0.id < $1.id
        }
    }
    static func eventURL(for slot: DateInterval) -> URL {
        var url = URLComponents()
        url.scheme = "lotsofevents"; url.host = "plan-time"
        url.queryItems = [URLQueryItem(name: "start", value: String(slot.start.timeIntervalSince1970)),
                          URLQueryItem(name: "end", value: String(slot.end.timeIntervalSince1970))]
        return url.url!
    }
    static func eventInterval(from url: URL) -> DateInterval? {
        guard url.scheme == "lotsofevents", url.host == "plan-time",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let a = items.first(where: { $0.name == "start" })?.value.flatMap(Double.init),
              let b = items.first(where: { $0.name == "end" })?.value.flatMap(Double.init),
              a.isFinite, b.isFinite, b > a, b - a <= 86400,
              a > 0, b < 32_503_680_000 else { return nil }
        return DateInterval(start: Date(timeIntervalSince1970: a), end: Date(timeIntervalSince1970: b))
    }
}
