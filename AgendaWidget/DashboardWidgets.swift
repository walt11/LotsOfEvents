import SwiftUI
import WidgetKit
import AppIntents
import EventKit

// Selection and pagination are independent for each layout, shared by instances of that layout.
// Events + Tasks moved to a new kind when it got its own options: iOS kept applying the old options to the old kind.
enum DashboardKind: String {
    case next = "NextUp", split = "EventsTasksDays", five = "FiveDayStrip", month = "MonthAgenda", focus = "FocusList", open = "OpenTime", tomorrow = "TomorrowBrief", catchUp = "CatchUp"
    var interactionKey: String { "\(rawValue).interactedAt" }
    var title: String {
        switch self { case .next: return "Next Up"; case .split: return "Events + Tasks"; case .five: return "Five-Day Strip"; case .month: return "Month + Agenda"; case .focus: return "Focus List"; case .open: return "Open Time"; case .tomorrow: return "Tomorrow Brief"; case .catchUp: return "Catch Up" }
    }
    var detail: String {
        switch self {
        case .next: return "Your next timed event, a pinned preparation reminder, and what follows."
        case .open: return "Find a gap in your selected calendars and plan an event in that time."
        case .tomorrow: return "Tomorrow’s events and reminders, ready for an evening glance."
        case .catchUp: return "Overdue reminders from your selected lists, priority first."
        case .split: return "Today's events and reminders, or today and the days ahead, plus undated tasks from the lists you choose for Today."
        case .five: return "Tap any of the next five dates to browse its agenda."
        case .month: return "A compact month calendar with the selected day's agenda."
        case .focus: return "Work through your selected reminder lists, including overdue and undated tasks."
        }
    }
}

struct DashboardEntry: StyledEntry {
    var date: Date
    var items: [AgendaItem] = []
    var tasks: [WidgetTask] = []
    var calendarAccess = false
    var hasCalendars = true
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
    /// Font, text size, and spacing: the Widget editor's, with this widget's own options on top.
    var look = WidgetLook.saved
    var preparation: WidgetTask? = nil
    var startHour = 9
    var endHour = 17
    var minimumMinutes = 30
    var completionUndo: WidgetUndoRecord? = nil
}

struct DashboardProvider: AppIntentTimelineProvider {
    let kind: DashboardKind
    var preparationID: String? = nil
    var startHour = 9
    var endHour = 17
    var minimumMinutes = 30
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
        var entry = context.isPreview ? placeholder(in: context) : await load(theme: configuration.theme, sources: configuration.sources, accent: configuration.accent)
        entry.look = configuration.look
        return entry
    }
    func timeline(for configuration: AgendaConfigurationIntent, in context: Context) async -> Timeline<DashboardEntry> {
        await timeline(theme: configuration.theme, sources: configuration.sources, accent: configuration.accent).styled(configuration.look)
    }
    func timeline(theme: WidgetThemeOption, sources: [SourceEntity]?, days: Int = 1, accent: WidgetAccentOption = .app) async -> Timeline<DashboardEntry> {
        do {
            let entry = await load(theme: theme, sources: sources, days: days, accent: accent)
            let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: entry.date))!
            // Future timeline entries switch Next Up at starts/ends without depending on a fresh fetch.
            let cutoff = min(entry.date.addingTimeInterval(3600), midnight)
            let eventDates = entry.items.filter { !$0.reminder && !$0.allDay }.flatMap { [$0.eventStartDate ?? $0.date, $0.endDate ?? $0.date] }
            let dueDates = kind == .catchUp ? entry.tasks.filter(\.timed).compactMap { $0.due?.addingTimeInterval(1) } : []
            let ticks = kind == .open ? (1...12).map { entry.date.addingTimeInterval(Double($0) * 300) } : []
            let resetDate = WidgetDayNavigation.resetDate(key: kind.interactionKey)
            var transitions = Set(kind == .next || kind == .open || kind == .catchUp ? eventDates + dueDates + ticks : [])
            if let resetDate { transitions.insert(resetDate) }
            if let undo = entry.completionUndo { transitions.insert(undo.expires) }
            let future = transitions.filter { $0 > entry.date && $0 < cutoff }.sorted().map { date -> DashboardEntry in
                var updated = entry
                updated.date = date
                if let resetDate, date >= resetDate {
                    updated.selectedDay = Calendar.current.startOfDay(for: date)
                    updated.page = 0
                }
                return updated
            }
            return Timeline(entries: [entry] + future, policy: .after(min(entry.date.addingTimeInterval(WidgetRefresh.interval), midnight)))
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
        entry.calendarAccess = ContactDates.enabled || EKEventStore.authorizationStatus(for: .event) == .fullAccess
        entry.reminderAccess = EKEventStore.authorizationStatus(for: .reminder) == .fullAccess
        entry.hasCalendars = entry.calendarAccess && store.calendars(for: .event).contains {
            calendarIDs?.contains($0.calendarIdentifier) ?? Preferences.selected($0.calendarIdentifier, reminders: false)
        }
        let saved = Date(timeIntervalSince1970: Preferences.defaults.double(forKey: "\(kind.rawValue).day"))
        entry.selectedDay = WidgetDashboardData.selectedDay(saved: saved, now: now, month: kind == .month)
        entry.page = max(0, Preferences.defaults.integer(forKey: "\(kind.rawValue).page"))
        if [.open, .tomorrow, .catchUp].contains(kind) {
            let pagedOn = Date(timeIntervalSince1970: Preferences.defaults.double(forKey: "\(kind.rawValue).pagedOn"))
            if !calendar.isDate(pagedOn, inSameDayAs: now) { entry.page = 0 }
        }
        if (kind == .month || kind == .five) && !calendar.isDate(saved, inSameDayAs: entry.selectedDay) { entry.page = 0 }
        if !WidgetDayNavigation.isActive(at: now, key: kind.interactionKey) {
            entry.selectedDay = calendar.startOfDay(for: now)
            entry.page = 0
        }
        let from = kind == .month ? calendar.dateInterval(of: .month, for: now)!.start : now
        let days = kind == .split ? taskDays : kind == .month ? calendar.range(of: .day, in: .month, for: now)!.count : kind == .next ? 14 : 5
        // Events + Tasks and Focus List fetch their reminders below, so skip them here rather than fetching twice.
        let agendaLists = [.split, .focus, .open, .tomorrow, .catchUp, .next].contains(kind) ? Set<String>() : listIDs
        entry.items = await AgendaQuery.load(store: store, now: from, days: days, calendarIDs: calendarIDs, listIDs: agendaLists)
        if entry.reminderAccess && ([.split, .focus, .tomorrow, .catchUp].contains(kind)) {
            (entry.hasLists, entry.tasks) = await Self.tasks(store: store, listIDs: listIDs, now: now, days: kind == .split ? taskDays : nil)
        }
        entry.completionUndo = WidgetUndoRecord.current
        entry.startHour = startHour; entry.endHour = endHour; entry.minimumMinutes = minimumMinutes
        if kind == .next, entry.reminderAccess, let preparationID,
           let reminder = store.calendarItem(withIdentifier: preparationID) as? EKReminder, !reminder.isCompleted {
            entry.preparation = WidgetTask(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Reminder",
                due: reminder.dueDateComponents.flatMap { ($0.calendar ?? calendar).date(from: $0) },
                timed: reminder.dueDateComponents?.hour != nil, list: reminder.calendarTitle,
                color: reminder.calendarColor, writable: reminder.calendar?.allowsContentModifications ?? false, priority: reminder.priority)
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
        return (true, WidgetDashboardData.sortedTasks(reminders.compactMap { reminder in
            let due = reminder.dueDateComponents.flatMap { ($0.calendar ?? calendar).date(from: $0) }
            guard let id = reminder.calendar?.calendarIdentifier else { return nil }
            if let days, !TodayTasks.includes(due: due, listID: id, shown: shown(id), now: now, days: days, undatedLists: undated) { return nil }
            return WidgetTask(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Reminder", due: due, timed: reminder.dueDateComponents?.hour != nil, list: reminder.calendar.title, color: Color(cgColor: reminder.calendar.cgColor), writable: reminder.calendar.allowsContentModifications, priority: reminder.priority, overdue: due.map { ReminderDates.isOverdue(due: $0, timed: reminder.dueDateComponents?.hour != nil, now: now, calendar: calendar) } ?? false)
        }))
    }
}

/// Events + Tasks uses its own options, which add the choice of just today or today and the days ahead.
struct EventsTasksProvider: AppIntentTimelineProvider {
    private let base = DashboardProvider(kind: .split)
    static var upcomingDays: Int { Preferences.days }
    func placeholder(in context: Context) -> DashboardEntry { base.placeholder(in: context) }
    func snapshot(for configuration: EventsTasksConfigurationIntent, in context: Context) async -> DashboardEntry {
        var entry = context.isPreview ? placeholder(in: context) : await base.load(theme: configuration.theme, sources: configuration.sources, days: days(configuration), accent: configuration.accent)
        entry.look = configuration.look
        return entry
    }
    func timeline(for configuration: EventsTasksConfigurationIntent, in context: Context) async -> Timeline<DashboardEntry> {
        await base.timeline(theme: configuration.theme, sources: configuration.sources, days: days(configuration), accent: configuration.accent).styled(configuration.look)
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
        Preferences.defaults.set(Date.now.timeIntervalSince1970, forKey: kind.interactionKey)
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
        let now = Date.now
        if !WidgetDayNavigation.isActive(at: now, key: kind.interactionKey) {
            Preferences.defaults.set(Calendar.current.startOfDay(for: now).timeIntervalSince1970, forKey: "\(kind.rawValue).day")
        }
        Preferences.defaults.set(now.timeIntervalSince1970, forKey: kind.interactionKey)
        Preferences.defaults.set(max(0, page), forKey: "\(kind.rawValue).page")
        Preferences.defaults.set(Date.now.timeIntervalSince1970, forKey: "\(kind.rawValue).pagedOn")
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
        guard reminder.calendar?.allowsContentModifications == true else { throw WidgetReminderError.readOnly }
        let currentDue = reminder.dueDateComponents.flatMap { ($0.calendar ?? Calendar.current).date(from: $0) }?.timeIntervalSince1970 ?? -1
        // Do not let a stale button complete the next occurrence of a repeating reminder.
        guard currentDue == expectedDue else { WidgetCenter.shared.reloadAllTimelines(); return .result() }
        if !reminder.isCompleted {
            reminder.isCompleted = true
            try store.save(reminder, commit: true)
            WidgetUndoRecord(token: UUID().uuidString, identifier: reminder.calendarItemIdentifier, title: reminder.title ?? "Task", completedAt: reminder.completionDate ?? .now).save()
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
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: DashboardKind.next.rawValue, intent: NextUpConfigurationIntent.self, provider: NextUpProvider()) { DashboardView(entry: $0, kind: .next) }
            .contentMarginsDisabled().configurationDisplayName("Next Up").description(DashboardKind.next.detail)
            .supportedFamilies([.systemSmall, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
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
    private var look: WidgetLook { entry.look }
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
                case .next: nextUp(height: geometry.size.height)
                case .split: TodayDashboardWidgetView(entry: entry, size: geometry.size, previewFamily: previewFamily)
                case .five: fiveDays(height: geometry.size.height)
                case .month: month(height: geometry.size.height)
                case .focus: focus(height: geometry.size.height)
                case .open: openTime
                case .tomorrow: tomorrowBrief(height: geometry.size.height)
                case .catchUp: catchUp(height: geometry.size.height)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        // Measure and paginate inside the same safe content margins used by every layout.
        .padding(WidgetContentLayout.insets)
        .foregroundStyle(entry.theme.text(scheme))
        .overlay(alignment: .bottom) { WidgetUndoButton(record: entry.completionUndo, date: entry.date) }
        .containerBackground(for: .widget) { entry.theme.backgroundView(scheme) }
        .widgetURL(URL(string: kind == .focus || kind == .catchUp ? "lotsofevents://reminders" : "lotsofevents://agenda"))
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
            HStack(spacing: 3) {
                                if let symbol = item.dateSymbol { Image(systemName: symbol).foregroundStyle(item.color) }
                                Text(item.title).lineLimit(1)
                            }.font(look.font(11, .medium))
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
    private var openTime: some View {
        let slots = WidgetCompanionData.openSlots(items: entry.items, now: entry.date, startHour: entry.startHour, endHour: entry.endHour, minimumMinutes: entry.minimumMinutes)
        let page = min(entry.page, max(0, slots.count - 1))
        return VStack(alignment: .leading, spacing: 4) {
            header("Open Time")
            if !entry.calendarAccess { empty("Open the app to connect calendars.") }
            else if !entry.hasCalendars { empty("Choose calendars in Edit Widget or in the app.") }
            else if entry.startHour < 0 || entry.endHour > 24 || entry.startHour >= entry.endHour {
                empty("Edit Widget to choose a start hour before the end hour.")
            } else if !slots.isEmpty {
                let slot = slots[page]
                Text(Duration.seconds(slot.duration).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated)))
                    .font(look.font(23, .medium, theme: entry.theme == .gallery ? .serif : .default)).lineLimit(1).minimumScaleFactor(0.7)
                Text(slot.start <= entry.date ? "Free now" : "Free from \(slot.start.formatted(date: .omitted, time: .shortened))")
                    .font(look.font(11, .medium)).lineLimit(1)
                Text("Until \(slot.end.formatted(date: .omitted, time: .shortened))")
                    .font(look.font(9)).foregroundStyle(secondary).lineLimit(1)
                Spacer(minLength: 0)
                Link(destination: WidgetCompanionData.eventURL(for: slot)) {
                    Label("Plan this time", systemImage: "plus").font(look.font(10, .medium))
                        .frame(maxWidth: .infinity).padding(.vertical, 5)
                        .background(accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
                }.accessibilityLabel("Create event from \(slot.start.formatted(date: .omitted, time: .shortened)) to \(slot.end.formatted(date: .omitted, time: .shortened))")
                pager(slots.count, page: page)
            } else {
                empty("No \(entry.minimumMinutes)-minute gaps left today.")
                Spacer(minLength: 0)
                Text("Selected calendars · Edit Widget to change hours")
                    .font(look.font(9)).foregroundStyle(secondary)
            }
        }
    }

    private enum BriefRow {
        case event(AgendaItem), task(WidgetTask)
    }
    private func briefHeight(_ row: BriefRow) -> CGFloat {
        switch row {
        case .event(let item): look.row(!item.allDay && look.showTimes ? 28 : 17)
        case .task(let task): look.row(task.timed && look.showTimes ? 28 : 22)
        }
    }
    private func tomorrowBrief(height: CGFloat) -> some View {
        let day = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let events = WidgetAgendaLayout.items(on: day, from: entry.items).filter { !$0.reminder }
        let tasks = WidgetCompanionData.tomorrowTasks(entry.tasks, now: entry.date)
        let rows = events.map(BriefRow.event) + tasks.map(BriefRow.task)
        let pages = WidgetCompanionData.pages(heights: rows.map(briefHeight), height: max(0, height - look.row(18) - 25))
        let page = min(entry.page, pages.count - 1)
        return VStack(alignment: .leading, spacing: 0) {
            header("Tomorrow · \(day.formatted(.dateTime.day()))")
            if !entry.calendarAccess && !entry.reminderAccess { empty("Open the app to connect calendars and reminders.") }
            else if rows.isEmpty { empty("All clear tomorrow") }
            else {
                ForEach(Array(pages[page]), id: \.self) { index in
                    switch rows[index] {
                    case .event(let item):
                        HStack(spacing: 5) {
                            if look.showColorBars { Capsule().fill(item.color).frame(width: 3, height: item.allDay ? 12 : 23) }
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 3) {
                                if let symbol = item.dateSymbol { Image(systemName: symbol).foregroundStyle(item.color) }
                                Text(item.title).lineLimit(1)
                            }.font(look.font(11, .medium))
                                if !item.allDay && look.showTimes { Text(item.widgetTimeLabel).font(look.font(9)).foregroundStyle(secondary).lineLimit(1) }
                            }
                            Spacer(minLength: 0)
                        }.frame(height: briefHeight(rows[index]))
                    case .task(let task):
                        HStack(spacing: 4) {
                            Button(intent: CompleteWidgetReminderIntent(task: task)) {
                                Image(systemName: "circle").font(look.font(15)).foregroundStyle(task.color).frame(width: 23, height: briefHeight(rows[index]))
                            }.buttonStyle(.plain).disabled(!task.writable).accessibilityLabel("Complete \(task.title)")
                            VStack(alignment: .leading, spacing: 1) {
                                Text(task.title).font(look.font(11)).lineLimit(1)
                                if task.timed && look.showTimes, let due = task.due { Text(due.formatted(date: .omitted, time: .shortened)).font(look.font(9)).foregroundStyle(secondary) }
                            }
                            Spacer(minLength: 0)
                        }.frame(height: briefHeight(rows[index]))
                    }
                }
            }
            Spacer(minLength: 0)
            if pages.count > 1 { pager(pages.count, page: page) }
            else { Text("\(events.count) \(events.count == 1 ? "event" : "events") · \(tasks.count) \(tasks.count == 1 ? "reminder" : "reminders")").font(look.font(8)).foregroundStyle(secondary).lineLimit(1) }
        }
    }

    private func catchUp(height: CGFloat) -> some View {
        let tasks = WidgetCompanionData.overdueTasks(entry.tasks, now: entry.date)
        let pages = WidgetCompanionData.pages(heights: tasks.map { _ in look.row(33) }, height: max(0, height - look.row(18) - 25))
        let page = min(entry.page, pages.count - 1)
        return VStack(alignment: .leading, spacing: 0) {
            header("Catch Up", addReminder: true)
            if !entry.reminderAccess { empty("Open the app to connect reminders.") }
            else if !entry.hasLists { empty("Choose reminder lists in Edit Widget or in the app.") }
            else if tasks.isEmpty { empty("All caught up"); Text("No overdue reminders.").font(look.font(9)).foregroundStyle(secondary) }
            else {
                ForEach(Array(pages[page]), id: \.self) { index in
                    let task = tasks[index]
                    HStack(spacing: 5) {
                        Button(intent: CompleteWidgetReminderIntent(task: task)) {
                            Image(systemName: "circle").font(look.font(16)).foregroundStyle(task.color).frame(width: 24, height: look.row(33))
                        }.buttonStyle(.plain).disabled(!task.writable).accessibilityLabel("Complete \(task.title)")
                        VStack(alignment: .leading, spacing: 1) {
                            Text(task.title).font(look.font(11, .medium)).lineLimit(1)
                            if let due = task.due {
                                let days = Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: due), to: today).day ?? 0
                                Text("\(days == 0 ? "Earlier today" : days == 1 ? "Yesterday" : "\(days) days overdue") · \(task.list)")
                                    .font(look.font(9)).foregroundStyle(secondary).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            Spacer(minLength: 0)
            if pages.count > 1 { pager(pages.count, page: page) }
            else if !tasks.isEmpty { Text("\(tasks.count) overdue · Priority first").font(look.font(8)).foregroundStyle(secondary) }
        }
    }

    private func nextUp(height: CGFloat) -> some View {
        let events = WidgetDashboardData.nextEvents(entry.items, now: entry.date)
        return VStack(alignment: .leading, spacing: 2) {
            header("Next Up")
            if !entry.calendarAccess { empty("Open the app to connect calendars.") }
            else if let next = events.first {
                let start = next.eventStartDate ?? next.date
                if start <= entry.date {
                    Text("HAPPENING NOW").font(look.font(9, .bold)).foregroundStyle(accentText)
                } else if Calendar.current.isDate(start, inSameDayAs: entry.date) {
                    HStack(spacing: 3) { Text("IN"); Text(start, style: .relative) }.font(look.font(10, .semibold)).foregroundStyle(accentText).lineLimit(1)
                } else { Text(start.formatted(.dateTime.weekday(.abbreviated).month().day())).font(look.font(10)).foregroundStyle(accentText) }
                HStack(spacing: 5) {
                    if look.showColorBars { Capsule().fill(next.color).frame(width: 3) }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(next.title).font(look.font(15, .semibold, theme: entry.theme == .gallery ? .serif : .default))
                            .lineLimit(entry.preparation == nil && height >= look.row(120) ? 2 : 1).minimumScaleFactor(0.85)
                        if look.showTimes { Text(next.widgetTimeLabel).font(look.font(10)).foregroundStyle(secondary).lineLimit(1) }
                    }
                }.fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                if let preparation = entry.preparation {
                    Divider()
                    if look.showSectionLabels && height >= look.row(130) { Text("BEFORE YOU GO").font(look.font(8, .semibold)).foregroundStyle(secondary) }
                    taskRow(preparation)
                }
                if events.count > 1 && entry.preparation == nil {
                    Divider()
                    if look.showSectionLabels && height >= look.row(130) { Text("AFTER THAT").font(look.font(8, .semibold)).foregroundStyle(secondary) }
                    HStack(spacing: 4) {
                        Text(events[1].title).font(look.font(11)).lineLimit(1)
                        Spacer(minLength: 0)
                        if look.showTimes { Text(WidgetDashboardData.laterLabel(events[1], now: entry.date)).font(look.font(8)).foregroundStyle(secondary).lineLimit(1) }
                    }
                }
                if entry.preparation != nil && events.count > 1 && height >= look.row(130) {
                    Text("Then · \(events[1].title)").font(look.font(8)).foregroundStyle(secondary).lineLimit(1)
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

struct NextUpProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> DashboardEntry { DashboardProvider(kind: .next).placeholder(in: context) }
    private func base(_ configuration: NextUpConfigurationIntent) -> DashboardProvider {
        DashboardProvider(kind: .next, preparationID: configuration.preparation?.id)
    }
    func snapshot(for configuration: NextUpConfigurationIntent, in context: Context) async -> DashboardEntry {
        var entry = context.isPreview ? placeholder(in: context) : await base(configuration).load(theme: configuration.theme, sources: configuration.sources, accent: configuration.accent)
        entry.look = configuration.look
        return entry
    }
    func timeline(for configuration: NextUpConfigurationIntent, in context: Context) async -> Timeline<DashboardEntry> {
        await base(configuration).timeline(theme: configuration.theme, sources: configuration.sources, accent: configuration.accent).styled(configuration.look)
    }
}

struct OpenTimeProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> DashboardEntry { DashboardProvider(kind: .open).placeholder(in: context) }
    private func base(_ configuration: OpenTimeConfigurationIntent) -> DashboardProvider {
        DashboardProvider(kind: .open, startHour: configuration.startHour, endHour: configuration.endHour, minimumMinutes: max(1, min(1440, configuration.minimumMinutes)))
    }
    func snapshot(for configuration: OpenTimeConfigurationIntent, in context: Context) async -> DashboardEntry {
        var entry = context.isPreview ? placeholder(in: context) : await base(configuration).load(theme: configuration.theme, sources: configuration.sources, accent: configuration.accent)
        entry.look = configuration.look
        return entry
    }
    func timeline(for configuration: OpenTimeConfigurationIntent, in context: Context) async -> Timeline<DashboardEntry> {
        await base(configuration).timeline(theme: configuration.theme, sources: configuration.sources, accent: configuration.accent).styled(configuration.look)
    }
}

struct OpenTimeWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: DashboardKind.open.rawValue, intent: OpenTimeConfigurationIntent.self, provider: OpenTimeProvider()) { DashboardView(entry: $0, kind: .open) }
            .contentMarginsDisabled().configurationDisplayName("Open Time").description(DashboardKind.open.detail).supportedFamilies([.systemSmall])
    }
}
struct TomorrowBriefWidget: Widget {
    var body: some WidgetConfiguration { DashboardConfiguration(kind: .tomorrow).body }
}
struct CatchUpWidget: Widget {
    var body: some WidgetConfiguration { DashboardConfiguration(kind: .catchUp).body }
}

struct UndoWidgetReminderIntent: AppIntent {
    static let title: LocalizedStringResource = "Undo task completion"
    @Parameter(title: "Completion") var token: String
    init() {}
    init(token: String) { self.token = token }
    func perform() async throws -> some IntentResult {
        try WidgetUndoRecord.undo(token: token)
        return .result()
    }
}

struct WidgetUndoButton: View {
    let record: WidgetUndoRecord?
    let date: Date
    var body: some View {
        if let record, record.expires > date {
            Button(intent: UndoWidgetReminderIntent(token: record.token)) {
                Label("Undo", systemImage: "arrow.uturn.backward")
                    .font(.caption.weight(.semibold)).padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.regularMaterial, in: Capsule())
            }.buttonStyle(.plain).accessibilityLabel("Undo completion of \(record.title)")
        }
    }
}
