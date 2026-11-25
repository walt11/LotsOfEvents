import SwiftUI
import WidgetKit
import EventKit

/// Today's open reminders and progress, for the Lock Screen.
struct TodayRemindersEntry: TimelineEntry {
    let date: Date
    var titles: [String] = []
    var open = 0
    var done = 0
    var access = true
}

struct TodayRemindersProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> TodayRemindersEntry {
        TodayRemindersEntry(date: .now, titles: ["Pick up prescription", "Call mom"], open: 2, done: 3)
    }
    func snapshot(for configuration: AgendaConfigurationIntent, in context: Context) async -> TodayRemindersEntry {
        context.isPreview ? placeholder(in: context) : await load(configuration)
    }
    func timeline(for configuration: AgendaConfigurationIntent, in context: Context) async -> Timeline<TodayRemindersEntry> {
        let entry = await load(configuration)
        let midnight = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: .now))!
        return Timeline(entries: [entry], policy: .after(min(Date.now.addingTimeInterval(WidgetRefresh.interval), midnight)))
    }
    private func load(_ configuration: AgendaConfigurationIntent) async -> TodayRemindersEntry {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else { return TodayRemindersEntry(date: .now, access: false) }
        let store = EKEventStore()
        let chosen = (configuration.sources ?? []).filter(\.reminders).map(\.id)
        let lists = store.calendars(for: .reminder).filter {
            chosen.isEmpty ? Preferences.selected($0.calendarIdentifier, reminders: true) : chosen.contains($0.calendarIdentifier)
        }
        guard !lists.isEmpty else { return TodayRemindersEntry(date: .now) }
        let open = await store.reminders(matching: store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: lists))
        let done = await store.reminders(matching: store.predicateForCompletedReminders(withCompletionDateStarting: Calendar.current.startOfDay(for: .now), ending: nil, calendars: lists))
        let titles = TodayReminderCounts.dueToday(open.map { ($0.title ?? "Reminder", ReminderDates.due($0)) }, now: .now)
        return TodayRemindersEntry(date: .now, titles: titles, open: titles.count, done: done.count)
    }
}

struct TodayRemindersView: View {
    let entry: TodayRemindersEntry
    @Environment(\.widgetFamily) private var family
    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                if !entry.access { Text("Open LotsOfEvents") }
                else if entry.open == 0 { Label("All done today", systemImage: "checkmark.circle") }
                else { Label("\(entry.open) reminder\(entry.open == 1 ? "" : "s") left", systemImage: "checklist") }
            case .accessoryCircular:
                Gauge(value: Double(entry.done), in: 0...Double(max(1, entry.done + entry.open))) {
                    Image(systemName: "checklist")
                } currentValueLabel: {
                    Text(entry.open == 0 ? "✓" : "\(entry.open)")
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .accessibilityLabel(entry.open == 0 ? "All reminders done today" : "\(entry.open) reminders left today")
            default:
                VStack(alignment: .leading, spacing: 1) {
                    Text("TODAY · \(entry.done) OF \(entry.done + entry.open) DONE").font(.caption2.weight(.semibold)).widgetAccentable()
                    if !entry.access { Text("Open LotsOfEvents to connect Reminders").font(.caption) }
                    else if entry.titles.isEmpty { Text("All caught up").font(.headline) }
                    ForEach(entry.titles.prefix(2), id: \.self) { title in
                        Label(title, systemImage: "circle").font(.caption).lineLimit(1)
                    }
                    if entry.titles.count > 2 { Text("+\(entry.titles.count - 2) more").font(.caption2).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .containerBackground(for: .widget) { Color.clear }
        .widgetURL(URL(string: "lotsofevents://reminders"))
    }
}

struct TodayRemindersWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "TodayReminders", intent: AgendaConfigurationIntent.self, provider: TodayRemindersProvider()) {
            TodayRemindersView(entry: $0)
        }
        .configurationDisplayName("Today’s Reminders")
        .description("What’s left to do today and how much you’ve finished.")
        .supportedFamilies([.accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}
