import SwiftUI
import WidgetKit
import AppIntents
import EventKit

struct PageAgendaIntent: AppIntent {
    static let title: LocalizedStringResource = "Page through agenda"
    @Parameter(title: "Page") var page: Int
    init() {}
    init(page: Int) { self.page = page }
    func perform() async throws -> some IntentResult {
        Preferences.defaults.set(max(0, page), forKey: "page")
        Preferences.defaults.set(Date.now.timeIntervalSince1970, forKey: "agendaPagedOn")
        WidgetCenter.shared.reloadTimelines(ofKind: "UpcomingAgenda")
        return .result()
    }
}

struct AgendaEntry: StyledEntry {
    var date: Date
    let items: [AgendaItem]
    var page: Int
    let connected: Bool
    var theme: AgendaTheme = .selected
    var selectedDay: Date = .now
    var dayPage: Int = 0
    var days: Int = Preferences.days
    /// How far ahead items were loaded. Past `days`, they only fill space that would otherwise be empty.
    var loadedDays: Int? = nil
    var accentRGB = AccentStore.rgb
    /// This widget's own accent choice.
    var accent: WidgetAccentOption = .app
    /// Set when the Three-Day Agenda shows tasks with complete buttons instead of reminders as agenda rows.
    var showTasks = false
    var tasks: [WidgetTask] = []
    var hasLists = false
    var completionUndo: WidgetUndoRecord? = nil
    /// Font, text size, and spacing: the Widget editor's, with this widget's own options on top.
    var look = WidgetLook.saved
}

struct AgendaProvider: AppIntentTimelineProvider {
    var threeDay = false
    static let fillDays = 21
    func placeholder(in context: Context) -> AgendaEntry {
        AgendaEntry(date: .now, items: [
            AgendaItem(id: "1", title: "Morning walk", date: .now, allDay: false, reminder: false, source: "Personal", color: .teal),
            AgendaItem(id: "2", title: "Pick up groceries", date: .now, allDay: true, reminder: true, source: "Reminders", color: .orange),
            AgendaItem(id: "3", title: "Coffee with Alex", date: .now.addingTimeInterval(86400), allDay: false, reminder: false, source: "Personal", color: .purple)
        ], page: 0, connected: true)
    }
    func snapshot(for configuration: AgendaConfigurationIntent, in context: Context) async -> AgendaEntry {
        var entry = context.isPreview ? placeholder(in: context) : await entry(theme: configuration.theme, sources: configuration.sources, accent: configuration.accent)
        entry.look = configuration.look
        return entry
    }
    func timeline(for configuration: AgendaConfigurationIntent, in context: Context) async -> Timeline<AgendaEntry> {
        await timeline(theme: configuration.theme, sources: configuration.sources, accent: configuration.accent).styled(configuration.look)
    }
    func timeline(theme: WidgetThemeOption, sources: [SourceEntity]?, tasks: Bool = false, accent: WidgetAccentOption = .app) async -> Timeline<AgendaEntry> {
        let entry = await entry(theme: theme, sources: sources, tasks: tasks, accent: accent)
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))!
        var entries = [entry]
        if let resetDate = WidgetDayNavigation.resetDate(key: threeDay ? WidgetDayNavigation.interactionKey : "agendaPagedOn"), resetDate > entry.date,
           resetDate < midnight {
            var reset = entry
            reset.date = resetDate
            reset.selectedDay = Calendar.current.startOfDay(for: resetDate)
            reset.dayPage = 0
            reset.page = 0
            entries.append(reset)
        }
        if threeDay, let undo = entry.completionUndo, undo.expires > entry.date, undo.expires < midnight {
            var expired = entries.last ?? entry
            expired.date = undo.expires
            if let resetDate = WidgetDayNavigation.resetDate(), resetDate > undo.expires { expired = entry; expired.date = undo.expires }
            entries.append(expired)
            entries.sort { $0.date < $1.date }
        }
        return Timeline(entries: entries, policy: .after(min(Date.now.addingTimeInterval(900), midnight)))
    }
    func entry(theme: WidgetThemeOption, sources: [SourceEntity]?, tasks: Bool = false, accent: WidgetAccentOption = .app) async -> AgendaEntry {
        let now = Date.now
        let store = EKEventStore()
        let sources = sources ?? []
        // An empty choice means "use the app's Sources selection".
        let calendarIDs = sources.isEmpty ? nil : Set(sources.filter { !$0.reminders }.map(\.id))
        let listIDs = sources.isEmpty ? nil : Set(sources.filter(\.reminders).map(\.id))
        // Tasks are fetched separately so they get complete buttons, so leave reminders out of the agenda rows.
        // Three weeks out, so a large widget whose chosen range fits can keep going instead of leaving space empty.
        let loaded = threeDay ? 3 : max(Preferences.days, AgendaProvider.fillDays)
        let items = await AgendaQuery.load(store: store, now: now, days: loaded, calendarIDs: calendarIDs, listIDs: tasks ? [] : listIDs)
        let start = Calendar.current.startOfDay(for: now)
        let end = Calendar.current.date(byAdding: .day, value: 3, to: start)!
        let saved = Date(timeIntervalSince1970: Preferences.defaults.double(forKey: "selectedWidgetDay"))
        let active = !threeDay || WidgetDayNavigation.isActive(at: now)
        let selected = active && saved >= start && saved < end ? saved : start
        var entry = AgendaEntry(date: now, items: items, page: Preferences.defaults.integer(forKey: "page"), connected: ContactDates.enabled || EKEventStore.authorizationStatus(for: .event) == .fullAccess || EKEventStore.authorizationStatus(for: .reminder) == .fullAccess, theme: theme.theme ?? .selected, selectedDay: selected, dayPage: active && saved == selected ? Preferences.defaults.integer(forKey: "dayWidgetPage") : 0, days: threeDay ? 3 : Preferences.days)
        let pagedOn = Date(timeIntervalSince1970: Preferences.defaults.double(forKey: "agendaPagedOn"))
        if !Calendar.current.isDate(pagedOn, inSameDayAs: now) || !WidgetDayNavigation.isActive(at: now, key: "agendaPagedOn") { entry.page = 0 }
        entry.completionUndo = WidgetUndoRecord.current
        entry.accent = accent
        entry.loadedDays = loaded
        if tasks && EKEventStore.authorizationStatus(for: .reminder) == .fullAccess {
            entry.showTasks = true
            (entry.hasLists, entry.tasks) = await DashboardProvider.tasks(store: store, listIDs: listIDs, now: now, days: 3)
        }
        return entry
    }
}

struct AgendaWidgetView: View {
    let entry: AgendaEntry
    private var look: WidgetLook { entry.look }
    @Environment(\.colorScheme) private var colorScheme
    /// Today's heading uses the accent, except on a custom background without a chosen accent, where it may not stand out.
    private var todayColor: Color {
        let accent = entry.theme.widgetAccent(appRGB: entry.accentRGB, chosen: entry.accent)
        return entry.theme == .custom && !accent.custom ? entry.theme.text(colorScheme) : accent.color
    }
    // Timed rows have a second line; pagination budgets the same heights as the rendered rows.
    private var rowHeight: CGFloat { look.row(look.showTimes ? 28 : 16) }
    private var allDayHeight: CGFloat { look.row(16) }
    private var headingHeight: CGFloat { look.row(13) }
    private func itemPages(height: CGFloat) -> [[AgendaItem]] {
        func pages(days: Int) -> [[AgendaItem]] {
            WidgetAgendaLayout.pages(items: WidgetAgendaLayout.byDay(entry.items, start: entry.date, days: days), height: max(0, height), headings: true,
                                     rowHeight: rowHeight, allDayHeight: allDayHeight, headingHeight: headingHeight)
        }
        // Pages cover the chosen Days Ahead. When those all fit with room to spare, later days fill the one page.
        let chosen = pages(days: entry.days)
        guard chosen.count == 1, let loaded = entry.loadedDays, loaded > entry.days else { return chosen }
        return [pages(days: loaded)[0]]
    }
    var body: some View {
        GeometryReader { geometry in
            let unpaged = itemPages(height: geometry.size.height)
            let itemPages = unpaged.count > 1 ? itemPages(height: geometry.size.height - 22) : unpaged
            let pages = itemPages.count
            let page = min(max(0, entry.page), pages - 1)
            let visibleItems = itemPages[page]
            agenda(visibleItems: visibleItems, page: page, pages: pages)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .padding(WidgetContentLayout.insets)
        .foregroundStyle(entry.theme.text(colorScheme))
        .containerBackground(for: .widget) {
            entry.theme.backgroundView(colorScheme)
        }
        .widgetURL(URL(string: "lotsofevents://agenda"))
    }
    private func agenda(visibleItems: [AgendaItem], page: Int, pages: Int) -> some View {
        VStack(spacing: 0) {
            list(visibleItems: visibleItems)
            if pages > 1 {
                HStack(spacing: 10) {
                    railButton("chevron.left", page: page - 1, enabled: page > 0, label: "Previous agenda page")
                    Text("\(page + 1) of \(pages)").font(look.font(8)).foregroundStyle(entry.theme.secondary(colorScheme))
                    railButton("chevron.right", page: page + 1, enabled: page < pages - 1, label: "Next agenda page")
                }.frame(maxWidth: .infinity).frame(height: 22)
            }
        }
        .overlay(alignment: .topTrailing) {
            if look.showAddButton {
            Link(destination: URL(string: "lotsofevents://quick-add")!) {
                Image(systemName: "plus")
                    .font(look.font(11, .semibold))
                    .frame(width: 28, height: 18)
            }
            .foregroundStyle(entry.theme.secondary(colorScheme))
            .accessibilityLabel("Quick add")
            }
        }
    }
    private func railButton(_ symbol: String, page: Int, enabled: Bool, label: String) -> some View {
        Button(intent: PageAgendaIntent(page: page)) {
            Image(systemName: symbol).font(look.font(11, .semibold)).frame(width: 28, height: 22)
                .background(entry.theme.text(colorScheme).opacity(enabled ? 0.08 : 0), in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? entry.theme.text(colorScheme) : entry.theme.secondary(colorScheme).opacity(0.4))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
    private func list(visibleItems: [AgendaItem]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if entry.items.isEmpty {
                Text(dayLabel(entry.date)).font(look.font(9, .semibold, theme: entry.theme == .gallery ? .monospaced : .default)).foregroundStyle(todayColor)
                    .padding(.trailing, 28)
                Spacer(minLength: 4)
                Text(entry.connected ? "All clear ahead" : "Connect your calendars").font(.headline)
                Text(entry.connected ? "No items in the next \(entry.days) days." : "Open the app to choose calendars and reminder lists.")
                    .font(.caption).foregroundStyle(entry.theme.secondary(colorScheme))
            } else {
                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                    if index == 0 || !Calendar.current.isDate(visibleItems[index - 1].date, inSameDayAs: item.date) {
                        Text(dayLabel(item.date))
                            .font(look.font(9, .semibold, theme: entry.theme == .gallery ? .monospaced : .default))
                            .foregroundStyle(Calendar.current.isDate(item.date, inSameDayAs: entry.date) ? todayColor : entry.theme.secondary(colorScheme))
                            .lineLimit(1)
                            .padding(.trailing, index == 0 && look.showAddButton ? 28 : 0)
                            .frame(height: headingHeight, alignment: .bottomLeading)
                    }
                    HStack(spacing: 5) {
                        if look.showColorBars {
                            RoundedRectangle(cornerRadius: 1.5)
                                .fill(item.color)
                                .frame(width: 3, height: 12)
                        }
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 3) {
                                if let symbol = item.dateSymbol { Image(systemName: symbol).foregroundStyle(item.color) }
                                Text(item.title).lineLimit(1)
                            }.font(look.font(11, .medium))
                            if !item.allDay && look.showTimes {
                                Text(item.widgetTimeLabel).font(look.font(9)).monospacedDigit()
                                    .foregroundStyle(entry.theme.secondary(colorScheme)).lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: item.allDay ? allDayHeight : rowHeight)

                }
            }
            Spacer(minLength: 0)
        }
    }
    private func dayLabel(_ date: Date) -> String {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: entry.date)!
        if Calendar.current.isDate(date, inSameDayAs: tomorrow) { return "TOMORROW" }
        return date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()).uppercased()
    }
}

struct UpcomingAgendaWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "UpcomingAgenda", intent: AgendaConfigurationIntent.self, provider: AgendaProvider()) { AgendaWidgetView(entry: $0) }
            .contentMarginsDisabled()
            .configurationDisplayName("Upcoming Agenda")
            .description("Today and the days ahead, with your selected reminders. Tap + to add an event.")
            .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
