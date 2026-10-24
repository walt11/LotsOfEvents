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
        WidgetCenter.shared.reloadTimelines(ofKind: "UpcomingAgenda")
        return .result()
    }
}

struct AgendaEntry: TimelineEntry {
    let date: Date
    let items: [AgendaItem]
    let page: Int
    let connected: Bool
    var theme: AgendaTheme = .selected
    var selectedDay: Date = .now
    var dayPage: Int = 0
    var days: Int = Preferences.days
}

struct AgendaProvider: AppIntentTimelineProvider {
    var threeDay = false
    func placeholder(in context: Context) -> AgendaEntry {
        AgendaEntry(date: .now, items: [
            AgendaItem(id: "1", title: "Morning walk", date: .now, allDay: false, reminder: false, source: "Personal", color: .teal),
            AgendaItem(id: "2", title: "Pick up groceries", date: .now, allDay: true, reminder: true, source: "Reminders", color: .orange),
            AgendaItem(id: "3", title: "Coffee with Alex", date: .now.addingTimeInterval(86400), allDay: false, reminder: false, source: "Personal", color: .purple)
        ], page: 0, connected: true)
    }
    func snapshot(for configuration: AgendaConfigurationIntent, in context: Context) async -> AgendaEntry {
        context.isPreview ? placeholder(in: context) : await entry(configuration)
    }
    func timeline(for configuration: AgendaConfigurationIntent, in context: Context) async -> Timeline<AgendaEntry> {
        let entry = await entry(configuration)
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))!
        return Timeline(entries: [entry], policy: .after(min(Date.now.addingTimeInterval(900), midnight)))
    }
    private func entry(_ configuration: AgendaConfigurationIntent) async -> AgendaEntry {
        let now = Date.now
        let sources = configuration.sources ?? []
        // An empty choice means "use the app's Sources selection".
        let calendarIDs = sources.isEmpty ? nil : Set(sources.filter { !$0.reminders }.map(\.id))
        let listIDs = sources.isEmpty ? nil : Set(sources.filter(\.reminders).map(\.id))
        let items = await AgendaQuery.load(store: EKEventStore(), now: now, days: threeDay ? 3 : nil, calendarIDs: calendarIDs, listIDs: listIDs)
        let start = Calendar.current.startOfDay(for: now)
        let end = Calendar.current.date(byAdding: .day, value: 3, to: start)!
        let saved = Date(timeIntervalSince1970: Preferences.defaults.double(forKey: "selectedWidgetDay"))
        let selected = saved >= start && saved < end ? saved : start
        return AgendaEntry(date: now, items: items, page: Preferences.defaults.integer(forKey: "page"), connected: EKEventStore.authorizationStatus(for: .event) == .fullAccess || EKEventStore.authorizationStatus(for: .reminder) == .fullAccess, theme: configuration.theme.theme ?? .selected, selectedDay: selected, dayPage: saved == selected ? Preferences.defaults.integer(forKey: "dayWidgetPage") : 0, days: threeDay ? 3 : Preferences.days)
    }
}

struct AgendaWidgetView: View {
    let entry: AgendaEntry
    @Environment(\.colorScheme) private var colorScheme
    private var todayColor: Color { entry.theme.text(colorScheme) }
    private func itemPages(height: CGFloat) -> [[AgendaItem]] {
        WidgetAgendaLayout.pages(items: WidgetAgendaLayout.byDay(entry.items, start: entry.date, days: entry.days), height: max(0, height - 15), headings: true)
    }
    var body: some View {
        GeometryReader { geometry in
            let itemPages = itemPages(height: geometry.size.height)
            let pages = itemPages.count
            let page = min(max(0, entry.page), pages - 1)
            let visibleItems = itemPages[page]
            agenda(visibleItems: visibleItems, page: page, pages: pages)
                .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .padding(12)
        .foregroundStyle(entry.theme.text(colorScheme))
        .containerBackground(for: .widget) {
            entry.theme.background(colorScheme)
        }
        .widgetURL(URL(string: "lotsofevents://agenda"))
    }
    private func agenda(visibleItems: [AgendaItem], page: Int, pages: Int) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if entry.items.isEmpty {
                Text(dayLabel(entry.date)).font(.system(size: 9, weight: .semibold)).foregroundStyle(todayColor)
                    .padding(.trailing, 28)
                Spacer(minLength: 4)
                Text(entry.connected ? "All clear ahead" : "Connect your calendars").font(.headline)
                Text(entry.connected ? "No items in the next \(entry.days) days." : "Open the app to choose calendars and reminder lists.")
                    .font(.caption).foregroundStyle(entry.theme.secondary(colorScheme))
            } else {
                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                    // Share spare height evenly between entries, keeping dates with their first event.
                    if index > 0 { Spacer(minLength: 0) }
                    if index == 0 || !Calendar.current.isDate(visibleItems[index - 1].date, inSameDayAs: item.date) {
                        Text(dayLabel(item.date))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Calendar.current.isDate(item.date, inSameDayAs: entry.date) ? todayColor : entry.theme.secondary(colorScheme))
                            .lineLimit(1)
                            .padding(.trailing, index == 0 ? 28 : 0)
                            .frame(height: 15, alignment: .bottomLeading)
                    }
                    HStack(spacing: 4) {
                        RoundedRectangle(cornerRadius: 2)
                            .fill(item.color)
                            .frame(width: 3)
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.title).font(.system(size: 11, weight: .semibold)).lineLimit(1)
                            if !item.allDay {
                                Text(item.widgetTimeLabel).font(.system(size: 9))
                                    .foregroundStyle(entry.theme.secondary(colorScheme)).lineLimit(1)
                                    .frame(height: 12, alignment: .leading)
                            }

                        }
                        Spacer(minLength: 0)
                    }
                    .frame(height: item.allDay ? 14 : 26)
                    .padding(.bottom, 1)
                }
            }
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Spacer(minLength: 0)
                if pages > 1 {
                    Button(intent: PageAgendaIntent(page: (page + pages - 1) % pages)) {
                        Image(systemName: "chevron.left").frame(width: 24, height: 14)
                    }.accessibilityLabel("Previous agenda page")
                    Text("\(page + 1)/\(pages)").font(.system(size: 9)).foregroundStyle(entry.theme.secondary(colorScheme))
                    Button(intent: PageAgendaIntent(page: (page + 1) % pages)) {
                        Image(systemName: "chevron.right").frame(width: 24, height: 14)
                    }.accessibilityLabel("Next agenda page")
                }
                Spacer(minLength: 0)

            }.font(.system(size: 10, weight: .bold)).foregroundStyle(entry.theme.secondary(colorScheme)).buttonStyle(.plain)
                .frame(height: 14)
        }
        .overlay(alignment: .topTrailing) {
            Link(destination: URL(string: "lotsofevents://quick-add")!) {
                Image(systemName: "plus")
                    .font(.system(size: 11, weight: .semibold))
                    .frame(width: 24, height: 15)
            }
            .foregroundStyle(entry.theme.secondary(colorScheme))
            .accessibilityLabel("Quick add")
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


@main
struct LotsOfEventsWidgets: WidgetBundle {
    var body: some Widget {
        UpcomingAgendaWidget()
        ThreeDayAgendaWidget()
        NextUpWidget()
        EventsTasksWidget()
        FiveDayStripWidget()
        MonthAgendaWidget()
        FocusListWidget()
        QuickAddEventControl()
        QuickAddReminderControl()
    }
}
