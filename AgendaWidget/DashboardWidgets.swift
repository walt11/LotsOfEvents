import SwiftUI
import WidgetKit
import AppIntents
import EventKit

// Selection and pagination are independent for each layout, shared by instances of that layout.
enum DashboardKind: String {
    case next = "NextUp", split = "EventsTasks", five = "FiveDayStrip", month = "MonthAgenda", focus = "FocusList"
    var title: String {
        switch self { case .next: return "Next Up"; case .split: return "Events + Tasks"; case .five: return "Five-Day Strip"; case .month: return "Month + Agenda"; case .focus: return "Focus List" }
    }
    var detail: String {
        switch self {
        case .next: return "Your next timed event and what follows it."
        case .split: return "Today's events and selected reminders, with completion buttons."
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
        context.isPreview ? placeholder(in: context) : await load(configuration)
    }
    func timeline(for configuration: AgendaConfigurationIntent, in context: Context) async -> Timeline<DashboardEntry> {
        do {
            let entry = await load(configuration)
            let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: entry.date))!
            // Future timeline entries switch Next Up at starts/ends without depending on a fresh fetch.
            let cutoff = min(entry.date.addingTimeInterval(3600), midnight)
            let transitions = Set(entry.items.filter { !$0.reminder && !$0.allDay }.flatMap { [$0.eventStartDate ?? $0.date, $0.endDate ?? $0.date] })
                .filter { $0 > entry.date && $0 < cutoff }.sorted()
            let future = transitions.map { date -> DashboardEntry in
                let updated = DashboardEntry(date: date, items: entry.items, tasks: entry.tasks, calendarAccess: entry.calendarAccess, reminderAccess: entry.reminderAccess, hasLists: entry.hasLists, theme: entry.theme, selectedDay: entry.selectedDay, page: entry.page)
                return updated
            }
            return Timeline(entries: [entry] + (kind == .next ? future : []), policy: .after(min(entry.date.addingTimeInterval(900), midnight)))
        }
    }
    private func load(_ configuration: AgendaConfigurationIntent) async -> DashboardEntry {
        let now = Date.now
        let calendar = Calendar.current
        let store = EKEventStore()
        var entry = DashboardEntry(date: now, theme: configuration.theme.theme ?? .selected)
        let sources = configuration.sources ?? []
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
            let lists = store.calendars(for: .reminder).filter { listIDs?.contains($0.calendarIdentifier) ?? Preferences.selected($0.calendarIdentifier, reminders: true) }
            entry.hasLists = !lists.isEmpty
            if !lists.isEmpty {
                let reminders = await store.reminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists))
                entry.tasks = WidgetDashboardData.sortedTasks(reminders.map { reminder in
                    let due = reminder.dueDateComponents.flatMap { ($0.calendar ?? calendar).date(from: $0) }
                    return WidgetTask(id: reminder.calendarItemIdentifier, title: reminder.title ?? "Reminder", due: due, timed: reminder.dueDateComponents?.hour != nil, list: reminder.calendar.title, color: Color(cgColor: reminder.calendar.cgColor), writable: reminder.calendar.allowsContentModifications, priority: reminder.priority)
                })
            }
        }
        return entry
    }
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
            .supportedFamilies(kind == .next ? [.systemSmall, .accessoryInline, .accessoryCircular, .accessoryRectangular] : [.systemSmall])
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
    var body: some WidgetConfiguration { DashboardConfiguration(kind: .split).body }
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
    @Environment(\.colorScheme) private var scheme
    @Environment(\.widgetFamily) private var family
    private var secondary: Color { entry.theme.secondary(scheme) }
    // Headers and highlights follow the app's accent color; the theme sets the background.
    private var accent: Color { entry.theme.widgetAccent(appRGB: entry.accentRGB).color }
    private var onAccent: Color { entry.theme.widgetAccent(appRGB: entry.accentRGB).onColor }
    /// Accent-colored text. On a custom background without its own accent, the app accent may not stand out, so use the text color.
    private var accentText: Color {
        entry.theme == .custom && !entry.theme.widgetAccent(appRGB: entry.accentRGB).custom ? entry.theme.text(scheme) : accent
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
                case .split: split(height: geometry.size.height)
                case .five: fiveDays(height: geometry.size.height)
                case .month: month(height: geometry.size.height)
                case .focus: focus(height: geometry.size.height)
                }
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .padding(12)
        .foregroundStyle(entry.theme.text(scheme))
        .containerBackground(for: .widget) { entry.theme.backgroundView(scheme) }
        .widgetURL(URL(string: kind == .focus ? "lotsofevents://reminders" : "lotsofevents://agenda"))
    }
    private func header(_ title: String, addReminder: Bool = false) -> some View {
        HStack(spacing: 2) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold, design: entry.theme == .gallery ? .monospaced : .default)).foregroundStyle(secondary).lineLimit(1)
            Spacer(minLength: 0)
            Link(destination: URL(string: addReminder ? "lotsofevents://quick-add?type=reminder" : "lotsofevents://quick-add")!) {
                Image(systemName: "plus").font(.system(size: 12, weight: .medium)).frame(width: 22, height: 18)
            }.accessibilityLabel(addReminder ? "New reminder" : "New event")
        }.frame(height: 18)
    }
    private func eventRow(_ item: AgendaItem) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 3)
            VStack(alignment: .leading, spacing: 0) {
                Text(item.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                if !item.allDay { Text(item.widgetTimeLabel).font(.system(size: 9)).foregroundStyle(secondary).lineLimit(1).frame(height: 12) }
            }
            Spacer(minLength: 0)
        }.frame(height: item.allDay ? 14 : 26).padding(.bottom, 1)
    }
    private func taskRow(_ task: WidgetTask, detail: Bool = false) -> some View {
        HStack(spacing: 6) {
            Button(intent: CompleteWidgetReminderIntent(task: task)) {
                Image(systemName: "circle").font(.system(size: 17)).foregroundStyle(task.color).frame(width: 24, height: detail ? 30 : 24)
            }.buttonStyle(.plain).disabled(!task.writable).accessibilityLabel("Complete \(task.title)")
            VStack(alignment: .leading, spacing: 1) {
                Text(task.title).font(.system(size: 11, weight: .medium)).lineLimit(1)
                if detail {
                    Text(task.due.map { $0.formatted(date: .abbreviated, time: task.timed ? .shortened : .omitted) } ?? task.list)
                        .font(.system(size: 9)).foregroundStyle(secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }.frame(height: detail ? 31 : 24)
    }
    private func pager(_ pages: Int, page: Int) -> some View {
        HStack(spacing: 5) {
            Spacer(minLength: 0)
            if pages > 1 {
                Button(intent: DashboardPageIntent(kind: kind, page: (page + pages - 1) % pages)) { Image(systemName: "chevron.left").frame(width: 24, height: 14) }.accessibilityLabel("Previous page")
                Text("\(page + 1)/\(pages)").font(.system(size: 9))
                Button(intent: DashboardPageIntent(kind: kind, page: (page + 1) % pages)) { Image(systemName: "chevron.right").frame(width: 24, height: 14) }.accessibilityLabel("Next page")
            }
            Spacer(minLength: 0)
        }.font(.system(size: 10, weight: .bold)).foregroundStyle(secondary).buttonStyle(.plain).frame(height: 14)
    }
    private func empty(_ text: String) -> some View {
        Text(text).font(.system(size: 11)).foregroundStyle(secondary).fixedSize(horizontal: false, vertical: true)
    }
    private var nextUp: some View {
        let events = WidgetDashboardData.nextEvents(entry.items, now: entry.date)
        return VStack(alignment: .leading, spacing: 4) {
            header(entry.date.formatted(.dateTime.weekday(.wide).day()))
            if !entry.calendarAccess { empty("Open the app to connect calendars.") }
            else if let next = events.first {
                let start = next.eventStartDate ?? next.date
                if start <= entry.date {
                    Text("HAPPENING NOW").font(.system(size: 9, weight: .bold)).foregroundStyle(accentText)
                } else if Calendar.current.isDate(start, inSameDayAs: entry.date) {
                    HStack(spacing: 3) { Text("IN"); Text(start, style: .relative) }.font(.system(size: 10, weight: .semibold)).foregroundStyle(accentText).lineLimit(1)
                } else { Text(start.formatted(.dateTime.weekday(.abbreviated).month().day())).font(.system(size: 10)).foregroundStyle(accentText) }
                Text(next.title).font(.system(size: 15, weight: .semibold, design: entry.theme == .gallery ? .serif : .default)).lineLimit(2).minimumScaleFactor(0.85)
                Text(next.widgetTimeLabel).font(.system(size: 10)).foregroundStyle(secondary).lineLimit(1)
                Spacer(minLength: 0)
                if events.count > 1 {
                    Divider()
                    Text("AFTER THAT").font(.system(size: 8, weight: .semibold)).foregroundStyle(secondary)
                    HStack(spacing: 4) {
                        Text(events[1].title).font(.system(size: 11)).lineLimit(1)
                        Spacer(minLength: 0)
                        Text(WidgetDashboardData.laterLabel(events[1], now: entry.date)).font(.system(size: 8)).foregroundStyle(secondary).lineLimit(1)
                    }
                }
            } else { empty("No timed events in the next 14 days."); Spacer(minLength: 0) }
        }
    }
    private func split(height: CGFloat) -> some View {
        let events = WidgetAgendaLayout.items(on: entry.date, from: entry.items).filter { !$0.reminder }
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: today)!
        let tasks = entry.tasks.filter { $0.due == nil || $0.due! < tomorrow }
        let eventCount = height >= 150 ? 2 : 1
        let taskCount = max(1, Int((height - 18 - CGFloat(eventCount * 27) - 25 - 14) / 24))
        let pages = max(1, max((events.count + eventCount - 1) / eventCount, (tasks.count + taskCount - 1) / taskCount))
        let page = min(entry.page, pages - 1)
        return VStack(alignment: .leading, spacing: 0) {
            header("Today · \(entry.date.formatted(.dateTime.month(.abbreviated).day()))")
            if !entry.calendarAccess { empty("Connect calendars in the app.") }
            else if events.isEmpty { empty("No events today") }
            else {
                ForEach(Array(events.dropFirst(min(page, (events.count - 1) / eventCount) * eventCount).prefix(eventCount))) { eventRow($0) }
            }
            Spacer(minLength: 2)
            Divider().padding(.vertical, 3)
            Text("REMINDERS").font(.system(size: 9, weight: .semibold, design: entry.theme == .gallery ? .monospaced : .default)).foregroundStyle(secondary).frame(height: 14)
            if !entry.reminderAccess { empty("Connect Reminders in the app.") }
            else if !entry.hasLists { empty("Choose reminder lists in Sources.") }
            else if tasks.isEmpty { empty("All caught up") }
            else { ForEach(Array(tasks.dropFirst(min(page, (tasks.count - 1) / taskCount) * taskCount).prefix(taskCount))) { taskRow($0) } }
            Spacer(minLength: 0)
            pager(pages, page: page)
        }
    }
    private func fiveDays(height: CGFloat) -> some View {
        let days = (0..<5).map { Calendar.current.date(byAdding: .day, value: $0, to: today)! }
        let items = WidgetAgendaLayout.items(on: entry.selectedDay, from: entry.items)
        let pages = WidgetAgendaLayout.pages(items: items, height: max(0, height - 74), headings: false)
        let page = min(entry.page, pages.count - 1)
        return VStack(alignment: .leading, spacing: 0) {
            header(entry.date.formatted(.dateTime.month(.wide)))
            HStack(spacing: 2) {
                ForEach(days, id: \.self) { day in
                    let selected = Calendar.current.isDate(day, inSameDayAs: entry.selectedDay)
                    Button(intent: DashboardDayIntent(kind: kind, date: day)) {
                        VStack(spacing: 1) {
                            Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased()).font(.system(size: 8, weight: .medium))
                            Text(day.formatted(.dateTime.day())).font(.system(size: 15, weight: .medium))
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
                ForEach(0..<7) { i in Text(symbols[(i + calendar.firstWeekday - 1) % 7]).font(.system(size: 8)).foregroundStyle(secondary).frame(maxWidth: .infinity) }
            }.frame(height: 11)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 1), count: 7), spacing: 0) {
                ForEach(Array(days.enumerated()), id: \.offset) { _, day in
                    if let day {
                        let selected = calendar.isDate(day, inSameDayAs: entry.selectedDay)
                        let marked = !WidgetAgendaLayout.items(on: day, from: entry.items).isEmpty
                        Button(intent: DashboardDayIntent(kind: kind, date: day)) {
                            Text(day.formatted(.dateTime.day())).font(.system(size: 9, weight: selected ? .bold : .regular))
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
        let count = max(1, Int((height - 18 - 20 - 14) / 31))
        let pages = max(1, (entry.tasks.count + count - 1) / count)
        let page = min(entry.page, pages - 1)
        return VStack(alignment: .leading, spacing: 0) {
            header("Focus List", addReminder: true)
            Text("\(entry.tasks.count) remaining").font(.system(size: 12, weight: .semibold)).frame(height: 20)
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
