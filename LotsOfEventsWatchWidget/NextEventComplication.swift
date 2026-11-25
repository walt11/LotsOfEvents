import SwiftUI
import WidgetKit
import EventKit

struct NextEventEntry: TimelineEntry {
    let date: Date
    var title: String? = nil
    var start: Date? = nil
    var color: Color = .accentColor
    var access = true
}

/// The next timed event from the watch's own copy of Calendar, updated as each event ends.
struct NextEventProvider: TimelineProvider {
    func placeholder(in context: Context) -> NextEventEntry {
        NextEventEntry(date: .now, title: "Coffee with Alex", start: .now.addingTimeInterval(1800))
    }
    func getSnapshot(in context: Context, completion: @escaping (NextEventEntry) -> Void) {
        completion(context.isPreview ? placeholder(in: context) : entries(now: .now).first ?? NextEventEntry(date: .now))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<NextEventEntry>) -> Void) {
        let now = Date.now
        let list = entries(now: now)
        completion(Timeline(entries: list, policy: .after(min(list.last?.date ?? now, now.addingTimeInterval(3600)).addingTimeInterval(60))))
    }
    /// One entry now and one as each coming event ends, so the face moves on without a reload.
    private func entries(now: Date) -> [NextEventEntry] {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { return [NextEventEntry(date: now, access: false)] }
        let store = EKEventStore()
        let events = store.events(matching: store.predicateForEvents(withStart: now, end: now.addingTimeInterval(2 * 86400), calendars: nil))
            .filter { !$0.isAllDay && $0.endDate > now }
            .sorted { $0.startDate < $1.startDate }
        var result = [entry(at: now, event: events.first)]
        // End times can be out of order when events overlap. Recompute the next
        // eligible event at each chronological boundary, never displaying an ended event.
        for boundary in Set(events.map { $0.endDate! }).sorted().prefix(8) {
            result.append(entry(at: boundary, event: events.first { $0.endDate > boundary }))
        }
        return result
    }
    private func entry(at date: Date, event: EKEvent?) -> NextEventEntry {
        NextEventEntry(date: date, title: event?.title ?? (event == nil ? nil : "Event"), start: event?.startDate,
                       color: event?.calendar.map { Color(cgColor: $0.cgColor) } ?? .accentColor)
    }
}

struct NextEventComplicationView: View {
    let entry: NextEventEntry
    @Environment(\.widgetFamily) private var family
    private var time: String { entry.start?.formatted(date: .omitted, time: .shortened) ?? "" }
    var body: some View {
        Group {
            switch family {
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Label("Next", systemImage: "calendar").font(.caption2).foregroundStyle(entry.color).widgetAccentable()
                    Text(entry.title ?? message).font(.headline).lineLimit(1)
                    if entry.start != nil { Text(time).font(.caption) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            case .accessoryInline:
                if let title = entry.title { Text("\(time) \(title)") } else { Text(message) }
            case .accessoryCorner:
                Image(systemName: "calendar").font(.title3).widgetAccentable()
                    .widgetLabel { Text(entry.title.map { "\(time) \($0)" } ?? message) }
            default:
                VStack(spacing: 0) {
                    Image(systemName: "calendar").font(.caption2).widgetAccentable()
                    if let start = entry.start {
                        Text(start, format: .dateTime.hour(.defaultDigits(amPM: .omitted)).minute()).font(.system(size: 13, weight: .semibold)).minimumScaleFactor(0.7)
                    } else { Image(systemName: "checkmark").font(.caption2) }
                }
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }
    private var message: String { entry.access ? "No events soon" : "Open LotsOfEvents" }
}

@main
struct NextEventComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "NextEventComplication", provider: NextEventProvider()) { NextEventComplicationView(entry: $0) }
            .configurationDisplayName("Next Event")
            .description("Your next event on the watch face.")
            .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}
