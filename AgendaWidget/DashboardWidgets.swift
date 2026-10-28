import SwiftUI
import WidgetKit
import AppIntents
import EventKit

// Selection and pagination are independent for each layout, shared by instances of that layout.
// Events + Tasks moved to a new kind when it got its own options: iOS kept applying the old options to the old kind.
enum DashboardKind: String {
    case next = "NextUp", split = "EventsTasksDays", five = "FiveDayStrip", month = "MonthAgenda", focus = "FocusList"
    var title: String {
        switch self { case .next: return "Next Up"; case .split: return "Events + Tasks"; case .five: return "Five-Day Strip"; case .month: return "Month + Agenda"; case .focus: return "Focus List" }
    }
    var detail: String {
        switch self {
        case .next: return "Your next timed event and what follows it."
        case .split: return "Today's events and reminders, or today and the days ahead, plus undated tasks from the lists you choose for Today."
        case .five: return "Tap any of the next five dates to browse its agenda."
        case .month: return "A compact month calendar with the selected day's agenda."
        case .focus: return "Work through your selected reminder lists, including overdue and undated tasks."
        }
    }
}

struct DashboardEntry: TimelineEntry {
    let date: Date
    var items: [AgendaItem] = []
    var tasks: [WidgetTask] = []
    var calendarAccess = false
    var reminderAccess = false
    var hasLists = false
    var theme: AgendaTheme = .selected
    var selectedDay: Date = .now
    var page = 0
    var accentRGB = AccentStore.rgb
    /// This widget's own accent choice.
    var accent: WidgetAccentOption = .app
    /// Days Events + Tasks covers, starting today: 1 for just today.
    var days = 1
}

struct DashboardProvider: AppIntentTimelineProvider {
    let kind: DashboardKind
    func placeholder(in context: Context) -> DashboardEntry {
        let now = Date.now
        return DashboardEntry(date: now, items: [
            AgendaItem(id: "sample-event", title: "Allergy injections", date: now.addingTimeInterval(2700), allDay: false, reminder: false, source: "Health", color: .blue, endDate: now.addingTimeInterval(4500)),
            AgendaItem(id: "sample-dinner", title: "Dinner with Alex", date: now.addingTimeInterval(10800), allDay: false, reminder: false, source: "Personal", color: .green, endDate: now.addingTimeInterval(14400))
        ], tasks: [
            WidgetTask(id: "sample-task", title: "Call physical therapy", due: nil, timed: false, list: "Personal", color: .blue, writable: false, priority: 0),
            WidgetTask(id: "sample-task2", title: "Pick up prescription", due: now, timed: false, list: "Personal", color: .orange, writable: false, priority: 0)
        ], calendarAccess: true, reminderAccess: true, hasLists: true, selectedDay: Calendar.current.startOfDay(for: now))
    }
    func snapshot(for configuration: AgendaConfigurationIntent, in context: Context) async -> DashboardEntry {
        context.isPreview ? placeholder(in: context) : await load(theme: configuration.theme, sources: configuration.sources, accent: configuration.accent)
    }
    func timeline(for configuration: AgendaConfigurationIntent, in context: Context) async -> Timeline<DashboardEntry> {
        await timeline(theme: configuration.theme, sources: configuration.sources, accent: configuration.accent)
    }
    func timeline(theme: WidgetThemeOption, sources: [SourceEntity]?, days: Int = 1, accent: WidgetAccentOption = .app) async -> Timeline<DashboardEntry> {
        do {
            let entry = await load(theme: theme, sources: sources, days: days, accent: accent)
            let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: entry.date))!
            // Future timeline entries switch Next Up at starts/ends without depending on a fresh fetch.
            let cutoff = min(entry.date.addingTimeInterval(3600), midnight)
            let transitions = Set(entry.items.filter { !$0.reminder && !$0.allDay }.flatMap { [$0.eventStartDate ?? $0.date, $0.endDate ?? $0.date] })
                .filter { $0 > entry.date && $0 < cutoff }.sorted()
            let future = transitions.map { date -> DashboardEntry in
                let updated = DashboardEntry(date: date, items: entry.items, tasks: entry.tasks, calendarAccess: entry.calendarAccess, reminderAccess: entry.reminderAccess, hasLists: entry.hasLists, theme: entry.theme, selectedDay: entry.selectedDay, page: entry.page, accent: entry.accent, days: entry.days)
                return updated
            }
            return Timeline(entries: [entry] + (kind == .next ? future : []), policy: .after(min(entry.date.addingTimeInterval(900), midnight)))
        }
    }
    func load(theme: WidgetThemeOption, sources: [SourceEntity]?, days taskDays: Int = 1, accent: WidgetAccentOption = .app) async -> DashboardEntry {
        let now = Date.now
        let calendar = Calendar.current
        let store = EKEventStore()
        var entry = DashboardEntry(date: now, theme: theme.theme ?? .selected, accent: accent, days: taskDays)
        let sources = sources ?? []
        // An empty choice means "use the app's Sources selection".
        let calendarIDs = sources.isEmpty ? nil : Set(sources.filter { !$0.reminders }.map(\.id))
        let listIDs = sources.isEmpty ? nil : Set(sources.filter(\.reminders).map(\.id))
        entry.calendarAccess = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        entry.reminderAccess = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        let saved = Date(timeIntervalSince1970: Preferences.defaults.double(forKey: "\(kind.rawValue).day"))
        entry.selectedDay = WidgetDashboardData.selectedDay(saved: saved, now: now, month: kind == .month)
        entry.page = max(0, Preferences.defaults.integer(forKey: "\(kind.rawValue).page"))
        if (kind == .month || kind == .five) && !calendar.isDate(saved, inSameDayAs: entry.selectedDay) { entry.page = 0 }
        let from = kind == .month ? calendar.dateInterval(of: .month, for: now)!.start : now
        let days = kind == .month ? calendar.range(of: .day, in: .month, for: now)!.count : kind == .next ? 14 : 5
        // Events + Tasks and Focus List fetch their reminders below, so skip them here rather than fetching twice.
        let agendaLists = kind == .split || kind == .focus ? Set<String>() : listIDs
        entry.items = await AgendaQuery.load(store: store, now: from, days: days, calendarIDs: calendarIDs, listIDs: agendaLists)
        if entry.reminderAccess && (kind == .split || kind == .focus) {
            (entry.hasLists, entry.tasks) = await Self.tasks(store: store, listIDs: listIDs, now: now, days: kind == .split ? taskDays : nil)
        }
        return entry
    }
    /// Incomplete reminders from the shown lists. With `days`, only those due by then plus undated ones from the lists
    /// chosen for Today, even lists not shown elsewhere; without it, every one.
    static func tasks(store: EKEventStore, listIDs: Set<String>?, now: Date, days: Int?) async -> (hasLists: Bool, tasks: [WidgetTask]) {
        let calendar = Calendar.current
        let shown = { (id: String) in listIDs?.contains(id) ?? Preferences.selected(id, reminders: true) }
        let undated = days == nil ? [] : TodayTasks.undatedLists
        let lists = store.calendars(for: .reminder).filter { shown($0.calendarIdentifier) || undated.contains($0.calendarIdentifier) }
        guard !lists.isEmpty else { return (false, []) }
        let reminders = await store.reminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists))
        let today = calendar.startOfDay(for: now)
        return (true, WidgetDashboardData.sortedTasks(reminders.compactMap { reminder in
            let due = reminder.dueDateComponents.flatMap { ($0.calendar ?? calendar).date(from: $0) }
            let id = reminder.calendar.calendarIdentifier
            if let days, !TodayTasks.includes(due: due, listID: id, shown: shown(id), now: now, days: days, undatedLists: undated) { return nil }
            return WidgetTask(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Reminder", due: due, timed: reminder.dueDateComponents?.hour != nil, list: reminder.calendar.title, color: Color(cgColor: reminder.calendar.cgColor), writable: reminder.calendar.allowsContentModifications, priority: reminder.priority, overdue: due.map { $0 < today } ?? false)
        }))
    }
}

/// Events + Tasks uses its own options, which add the choice of just today or today and the days ahead.
struct EventsTasksProvider: AppIntentTimelineProvider {
    private let base = DashboardProvider(kind: .split)
    static let upcomingDays = 5
    func placeholder(in context: Context) -> DashboardEntry { base.placeholder(in: context) }
    func snapshot(for configuration: EventsTasksConfigurationIntent, in context: Context) async -> DashboardEntry {
        context.isPreview ? placeholder(in: context) : await base.load(theme: configuration.theme, sources: configuration.sources, days: days(configuration), accent: configuration.accent)
    }
    func timeline(for configuration: EventsTasksConfigurationIntent, in context: Context) async -> Timeline<DashboardEntry> {
        await base.timeline(theme: configuration.theme, sources: configuration.sources, days: days(configuration), accent: configuration.accent)
    }
    private func days(_ configuration: EventsTasksConfigurationIntent) -> Int { configuration.upcoming ? Self.upcomingDays : 1 }
}

struct DashboardDayIntent: AppIntent {
    static let title: LocalizedStringResource = "Choose widget date"
    @Parameter(title: "Widget") var kind: String
    @Parameter(title: "Date") var timestamp: Double
    init() {}
    init(kind: DashboardKind, date: Date) { self.kind = kind.rawValue; timestamp = date.timeIntervalSince1970 }
    func perform() async throws -> some IntentResult {
        guard let kind = DashboardKind(rawValue: kind), kind == .five || kind == .month else { return .result() }
        Preferences.defaults.set(timestamp, forKey: "\(kind.rawValue).day")
        Preferences.defaults.set(0, forKey: "\(kind.rawValue).page")
        WidgetCenter.shared.reloadTimelines(ofKind: kind.rawValue)
        return .result()
    }
}

struct DashboardPageIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn widget page"
    @Parameter(title: "Widget") var kind: String
    @Parameter(title: "Page") var page: Int
    init() {}
    init(kind: DashboardKind, page: Int) { self.kind = kind.rawValue; self.page = page }
    func perform() async throws -> some IntentResult {
        guard let kind = DashboardKind(rawValue: kind) else { return .result() }
        Preferences.defaults.set(max(0, page), forKey: "\(kind.rawValue).page")
        WidgetCenter.shared.reloadTimelines(ofKind: kind.rawValue)
        return .result()
    }
}

struct CompleteWidgetReminderIntent: AppIntent {
    static let title: LocalizedStringResource = "Complete reminder"
    @Parameter(title: "Reminder") var identifier: String
    @Parameter(title: "Expected due date") var expectedDue: Double
    init() {}
    init(task: WidgetTask) { identifier = task.id; expectedDue = task.due?.timeIntervalSince1970 ?? -1 }
    func perform() async throws -> some IntentResult {
        let store = EKEventStore()
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { throw WidgetReminderError.access }
        guard let reminder = store.calendarItem(withIdentifier: identifier) as? EKReminder else {
            WidgetCenter.shared.reloadAllTimelines()
            return .result()
        }
        // Widgets can be limited to lists outside the app's selection, so only writability is checked here.
        guard reminder.calendar.allowsContentModifications else { throw WidgetReminderError.readOnly }
        let currentDue = reminder.dueDateComponents.flatMap { ($0.calendar ?? Calendar.current).date(from: $0) }?.timeIntervalSince1970 ?? -1
        // Do not let a stale button complete the next occurrence of a repeating reminder.
        guard currentDue == expectedDue else { WidgetCenter.shared.reloadAllTimelines(); return .result() }
        if !reminder.isCompleted {
            reminder.isCompleted = true
            try store.save(reminder, commit: true)
        }
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

enum WidgetReminderError: LocalizedError {
    case access, readOnly
    var errorDescription: String? {
        switch self { case .access: return "Open LotsOfEvents and allow Reminders access."; case .readOnly: return "This list is read-only. Open the app to manage it." }
    }
}

@MainActor
struct DashboardConfiguration {
    let kind: DashboardKind
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind.rawValue, intent: AgendaConfigurationIntent.self, provider: DashboardProvider(kind: kind)) { DashboardView(entry: $0, kind: kind) }
            .contentMarginsDisabled()
            .configurationDisplayName(kind.title)
            .description(kind.detail)
            .supportedFamilies(kind == .next ? [.systemSmall, .accessoryInline, .accessoryCircular, .accessoryRectangular]
                               : [.systemSmall])
    }
}

/// Lock Screen versions of Next Up. These render in the system's tinted style, so they ignore the widget theme.
struct NextUpAccessory: View {
    let entry: DashboardEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        let next = entry.calendarAccess ? WidgetDashboardData.nextEvents(entry.items, now: entry.date).first : nil
        let start = next.map { $0.eventStartDate ?? $0.date }
        switch family {
        case .accessoryInline:
            if let next, let start { Text("\(start.formatted(date: .omitted, time: .shortened)) \(next.title)") }
            else { Text(entry.calendarAccess ? "No upcoming events" : "Connect calendars") }
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Image(systemName: "calendar").font(.system(size: 11, weight: .semibold))
                    if let start, start > entry.date { Text(start, format: .dateTime.hour().minute()).font(.system(size: 11, weight: .semibold)).minimumScaleFactor(0.6) }
                    else if start != nil { Text("Now").font(.system(size: 12, weight: .semibold)) }
                    else { Text("–").font(.system(size: 12, weight: .semibold)) }
                }.padding(4)
            }.accessibilityLabel(next.map { "Next: \($0.title)" } ?? "No upcoming events")
        default:
            VStack(alignment: .leading, spacing: 1) {
                if let next, let start {
                    Group {
                        if start <= entry.date { Text("Now") }
                        else if Calendar.current.isDate(start, inSameDayAs: entry.date) { Text("In \(start, style: .relative)") }
                        else { Text(start.formatted(.dateTime.weekday(.abbreviated).hour().minute())) }
                    }.font(.caption2.weight(.semibold)).widgetAccentable()
                    Text(next.title).font(.headline).lineLimit(1)
                    Text(next.widgetTimeLabel).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("Next Up").font(.caption2.weight(.semibold)).widgetAccentable()
                    Text(entry.calendarAccess ? "No upcoming events" : "Open LotsOfEvents to connect calendars").font(.caption).lineLimit(2)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct NextUpWidget: Widget {
    var body: some WidgetConfiguration { DashboardConfiguration(kind: .next).body }
}
struct EventsTasksWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: DashboardKind.split.rawValue, intent: EventsTasksConfigurationIntent.self, provider: EventsTasksProvider()) { DashboardView(entry: $0, kind: .split) }
            .contentMarginsDisabled()
            .configurationDisplayName(DashboardKind.split.title)
            .description(DashboardKind.split.detail)
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
struct FiveDayStripWidget: Widget {
    var body: some WidgetConfiguration { DashboardConfiguration(kind: .five).body }
}
struct MonthAgendaWidget: Widget {
    var body: some WidgetConfiguration { DashboardConfiguration(kind: .month).body }
}
struct FocusListWidget: Widget {
    var body: some WidgetConfiguration { DashboardConfiguration(kind: .focus).body }
}

struct DashboardView: View {
    let entry: DashboardEntry
    let kind: DashboardKind
    /// Set by the in-app preview, where there's no widget family in the environment.
    var previewFamily: WidgetFamily? = nil
    private let look = WidgetLook.saved
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetFamily) private var environmentFamily
    private var family: WidgetFamily { previewFamily ?? environmentFamily }
    private var secondary: Color { entry.theme.secondary(scheme) }
    // Headers and highlights follow the app's accent color; the theme sets the background.
    private var accent: Color { entry.theme.widgetAccent(appRGB: entry.accentRGB, chosen: entry.accent).color }
    private var onAccent: Color { entry.theme.widgetAccent(appRGB: entry.accentRGB, chosen: entry.accent).onColor }
    /// Accent-colored text. On a custom background without its own accent, the app accent may not stand out, so use the text color.
    private var accentText: Color {
        entry.theme == .custom && !entry.theme.widgetAccent(appRGB: entry.accentRGB, chosen: entry.accent).custom ? entry.theme.text(scheme) : accent
    }
    private var today: Date { Calendar.current.startOfDay(for: entry.date) }
    @ViewBuilder var body: some View {
        switch family {
        case .accessoryInline, .accessoryCircular, .accessoryRectangular:
            NextUpAccessory(entry: entry)
                .containerBackground(for: .widget) { Color.clear }
                .widgetURL(URL(string: "lotsofevents://agenda"))
        default: themed
        }
    }
    private var themed: some View {
        GeometryReader { geometry in
            Group {
                switch kind {
                case .next: nextUp
                case .split: TodayDashboardWidgetView(entry: entry, size: geometry.size, previewFamily: previewFamily)
                case .five: fiveDays(height: geometry.size.height)
                case .month: month(height: geometry.size.height)
                case .focus: focus(height: geometry.size.height)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        // The Events + Tasks list uses a slightly tighter margin to fit more rows.
        .padding(kind == .split ? 10 : 12)
        .foregroundStyle(entry.theme.text(scheme))
        .containerBackground(for: .widget) { entry.theme.backgroundView(scheme) }
        .widgetURL(URL(string: kind == .focus ? "lotsofevents://reminders" : "lotsofevents://agenda"))
    }
    private func header(_ title: String, addReminder: Bool = false) -> some View {
        HStack(spacing: 2) {
            Text(title.uppercased()).font(look.font(9, .semibold, theme: entry.theme == .gallery ? .monospaced : .default)).foregroundStyle(secondary).lineLimit(1)
            Spacer(minLength: 0)
            if look.showAddButton {
                Link(destination: URL(string: addReminder ? "lotsofevents://quick-add?type=reminder" : "lotsofevents://quick-add")!) {
                    Image(systemName: "plus").font(look.font(12, .medium)).frame(width: 22, height: 18)
                }.accessibilityLabel(addReminder ? "New reminder" : "New event")
            }
        }.frame(height: look.row(18))
    }
    private func eventRow(_ item: AgendaItem) -> some View {
        // One line per event, with the start time on the right, so more fit.
        HStack(spacing: 5) {
            if look.showColorBars { RoundedRectangle(cornerRadius: 1.5).fill(item.color).frame(width: 3, height: 12) }
            Text(item.title).font(look.font(11, .medium)).lineLimit(1)
            Spacer(minLength: 2)
            if !item.allDay && look.showTimes { Text(item.widgetStartLabel).font(look.font(9)).monospacedDigit().foregroundStyle(secondary).lineLimit(1) }
        }.frame(height: look.row(16))
    }
    private func taskRow(_ task: WidgetTask, detail: Bool = false) -> some View {
        HStack(spacing: 6) {
            Button(intent: CompleteWidgetReminderIntent(task: task)) {
                Image(systemName: "circle").font(look.font(17)).foregroundStyle(task.color).frame(width: 24, height: look.row(detail ? 30 : 24))
            }.buttonStyle(.plain).disabled(!task.writable).accessibilityLabel("Complete \(task.title)")
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).font(look.font(11, .medium)).lineLimit(1)
                if detail {
                    Text(task.due.map { $0.formatted(date: .abbreviated, time: task.timed ? .shortened : .omitted) } ?? task.list)
                        .font(look.font(9)).foregroundStyle(secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }.frame(height: look.row(detail ? 31 : 24))
    }
    private func pager(_ pages: Int, page: Int) -> some View {
        HStack(spacing: 5) {
            Spacer(minLength: 0)
            if pages > 1 {
                Button(intent: DashboardPageIntent(kind: kind, page: (page + pages - 1) % pages)) { Image(systemName: "chevron.left").frame(width: 24, height: 14) }.accessibilityLabel("Previous page")
                Text("\(page + 1)/\(pages)").font(look.font(9))
                Button(intent: DashboardPageIntent(kind: kind, page: (page + 1) % pages)) { Image(systemName: "chevron.right").frame(width: 24, height: 14) }.accessibilityLabel("Next page")
            }
            Spacer(minLength: 0)
        }.font(look.font(10, .bold)).foregroundStyle(secondary).buttonStyle(.plain).frame(height: 14)
    }
    private func empty(_ text: String) -> some View {
        Text(text).font(look.font(11)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
    }
    private var nextUp: some View {
        let events = WidgetDashboardData.nextEvents(entry.items, now: entry.date)
        return VStack(alignment: .leading, spacing: 4) {
            header(entry.date.formatted(.dateTime.weekday(.wide).day()))
            if !entry.calendarAccess { empty("Open the app to connect calendars.") }
            else if let next = events.first {
                let start = next.eventStartDate ?? next.date
                if start <= entry.date {
                    Text("HAPPENING NOW").font(look.font(9, .bold)).foregroundStyle(accentText)
                } else if Calendar.current.isDate(start, inSameDayAs: entry.date) {
                    HStack(spacing: 3) { Text("IN"); Text(start, style: .relative) }.font(look.font(10, .semibold)).foregroundStyle(accentText).lineLimit(1)
                } else { Text(start.formatted(.dateTime.weekday(.abbreviated).month().day())).font(look.font(10)).foregroundStyle(accentText) }
                Text(next.title).font(look.font(15, .semibold, theme: entry.theme == .gallery ? .serif : .default)).lineLimit(2).minimumScaleFactor(0.85)
                if look.showTimes { Text(next.widgetTimeLabel).font(look.font(10)).foregroundStyle(secondary).lineLimit(1) }
                Spacer(minLength: 0)
                if events.count > 1 {
                    Divider()
                    if look.showSectionLabels { Text("AFTER THAT").font(look.font(8, .semibold)).foregroundStyle(secondary) }
                    HStack(spacing: 4) {
                        Text(events[1].title).font(look.font(11)).lineLimit(1)
                        Spacer(minLength: 0)
                        if look.showTimes { Text(WidgetDashboardData.laterLabel(events[1], now: entry.date)).font(look.font(8)).foregroundStyle(secondary).lineLimit(1) }
                    }
                }
            } else { empty("No timed events in the next 14 days."); Spacer(minLength: 0) }
        }
    }
    private func fiveDays(height: CGFloat) -> some View {
        let days = (0..<5).map { Calendar.current.date(byAdding: .day, value: $0, to: today)! }
        let items = WidgetAgendaLayout.items(on: entry.selectedDay, from: entry.items)
        let pages = WidgetAgendaLayout.pages(items: items, height: max(0, height - 56 - look.row(18)), headings: false, rowHeight: look.row(16), allDayHeight: look.row(16))
        let page = min(entry.page, pages.count - 1)
        return VStack(alignment: .leading, spacing: 0) {
            header(entry.date.formatted(.dateTime.month(.wide)))
            HStack(spacing: 2) {
                ForEach(days, id: \.self) { day in
                    let selected = Calendar.current.isDate(day, inSameDayAs: entry.selectedDay)
                    Button(intent: DashboardDayIntent(kind: kind, date: day)) {
                        VStack(spacing: 1) {
                            Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased()).font(look.font(8, .medium))
                            Text(day.formatted(.dateTime.day())).font(look.font(15, .medium))
                        }
                        .offset(y: DayTabMetrics.offset(weekdaySize: 8, weekdayWeight: .medium, dateSize: 15, dateWeight: .medium))
                        .frame(maxWidth: .infinity).frame(height: 35)
                            .foregroundStyle(selected ? onAccent : entry.theme.text(scheme))
                            .background(selected ? accent : .clear, in: RoundedRectangle(cornerRadius: 8))
                    }.buttonStyle(.plain).accessibilityLabel(day.formatted(date: .complete, time: .omitted)).accessibilityAddTraits(selected ? .isSelected : [])
                }
            }.padding(.bottom, 6)
            if !entry.calendarAccess && !entry.reminderAccess { empty("Connect calendars or reminders in the app.") }
            else if items.isEmpty { empty("No items for this day") }
            else { ForEach(pages[page]) { eventRow($0) } }
            Spacer(minLength: 0)
            pager(pages.count, page: page)
        }
    }
    private func month(height: CGFloat) -> some View {
        let calendar = Calendar.current
        let days = WidgetDashboardData.monthDays(entry.date)
        let rows = (days.count + 6) / 7
        let cellHeight = max(9, min(19, (height - 72) / CGFloat(rows)))
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        let items = WidgetAgendaLayout.items(on: entry.selectedDay, from: entry.items)
        let item = items.isEmpty ? nil : items[min(entry.page, items.count - 1)]
        return VStack(alignment: .leading, spacing: 0) {
            header(entry.date.formatted(.dateTime.month(.wide).year()))
            HStack(spacing: 0) {
                ForEach(0..<7) { i in Text(symbols[(i + calendar.firstWeekday - 1) % 7]).font(look.font(8)).foregroundStyle(secondary).frame(maxWidth: .infinity) }
            }.frame(height: 11)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        let selected = calendar.isDate(day, inSameDayAs: entry.selectedDay)
                        let marked = !WidgetAgendaLayout.items(on: day, from: entry.items).isEmpty
                        Button(intent: DashboardDayIntent(kind: kind, date: day)) {
                            Text(day.formatted(.dateTime.day())).font(look.font(9, selected ? .bold : .regular))
                                .frame(maxWidth: .infinity).frame(height: cellHeight)
                                .foregroundStyle(selected ? onAccent : entry.theme.text(scheme))
                                .background(selected ? accent : .clear, in: RoundedRectangle(cornerRadius: 4))
                                .overlay(alignment: .bottom) { if marked { Circle().fill(selected ? onAccent : accent).frame(width: 2, height: 2) } }
                        }.buttonStyle(.plain).accessibilityLabel(day.formatted(date: .complete, time: .omitted)).accessibilityAddTraits(selected ? .isSelected : [])
                    } else { Color.clear.frame(height: cellHeight) }
                }
            }
            Spacer(minLength: 2)
            if let item { eventRow(item) }
            else { empty(entry.calendarAccess || entry.reminderAccess ? "No items on \(entry.selectedDay.formatted(.dateTime.month().day()))" : "Connect calendars in the app.") }
            pager(max(1, items.count), page: min(entry.page, max(0, items.count - 1)))
        }
    }
    private func focus(height: CGFloat) -> some View {
        let count = max(1, Int((height - look.row(18) - 20 - 14) / look.row(31)))
        let pages = max(1, (entry.tasks.count + count - 1) / count)
        let page = min(entry.page, pages - 1)
        return VStack(alignment: .leading, spacing: 0) {
            header("Focus List", addReminder: true)
            Text("\(entry.tasks.count) remaining").font(look.font(12, .semibold)).frame(height: 20)
            if !entry.reminderAccess { empty("Open the app to connect Reminders.") }
            else if !entry.hasLists { empty("Select reminder lists in Sources.") }
            else if entry.tasks.isEmpty { empty("All caught up") }
            else {
                ForEach(Array(entry.tasks.dropFirst(page * count).prefix(count))) { task in
                    taskRow(task, detail: true)
                }
            }
            Spacer(minLength: 0)
            pager(pages, page: page)
        }
    }
}
