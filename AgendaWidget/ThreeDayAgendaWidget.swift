import SwiftUI
import UIKit
import WidgetKit
import AppIntents

/// Optical centering for weekday-over-date tabs. Text line boxes leave room above the weekday's capitals
/// and below the digits for descenders they don't have, so a plainly centered stack looks high.
enum DayTabMetrics {
    static func offset(weekdaySize: CGFloat, weekdayWeight: UIFont.Weight, dateSize: CGFloat, dateWeight: UIFont.Weight) -> CGFloat {
        let weekday = UIFont.systemFont(ofSize: weekdaySize, weight: weekdayWeight)
        let date = UIFont.systemFont(ofSize: dateSize, weight: dateWeight)
        return (-date.descender - (weekday.ascender - weekday.capHeight)) / 2
    }
}

// Instances added before tasks came use the old kind with plain agenda options, so the tasks version is a new kind.
let threeDayKind = "ThreeDayAgendaTasks"

struct SelectWidgetDayIntent: AppIntent {
    static let title: LocalizedStringResource = "Select agenda day"
    @Parameter(title: "Day") var timestamp: Double
    init() {}
    init(day: Date) { timestamp = day.timeIntervalSince1970 }
    func perform() async throws -> some IntentResult {
        Preferences.defaults.set(timestamp, forKey: "selectedWidgetDay")
        Preferences.defaults.set(0, forKey: "dayWidgetPage")
        WidgetCenter.shared.reloadTimelines(ofKind: threeDayKind)
        return .result()
    }
}

/// Scrolls the selected day's list; `page` is the first row shown.
struct PageDayWidgetIntent: AppIntent {
    static let title: LocalizedStringResource = "Scroll selected day"
    @Parameter(title: "Page") var page: Int
    init() {}
    init(page: Int) { self.page = page }
    func perform() async throws -> some IntentResult {
        Preferences.defaults.set(max(0, page), forKey: "dayWidgetPage")
        WidgetCenter.shared.reloadTimelines(ofKind: threeDayKind)
        return .result()
    }
}

struct ThreeDayProvider: AppIntentTimelineProvider {
    private let base = AgendaProvider(threeDay: true)
    func placeholder(in context: Context) -> AgendaEntry { base.placeholder(in: context) }
    func snapshot(for configuration: ThreeDayConfigurationIntent, in context: Context) async -> AgendaEntry {
        context.isPreview ? placeholder(in: context) : await base.entry(theme: configuration.theme, sources: configuration.sources, tasks: configuration.tasks, accent: configuration.accent)
    }
    func timeline(for configuration: ThreeDayConfigurationIntent, in context: Context) async -> Timeline<AgendaEntry> {
        await base.timeline(theme: configuration.theme, sources: configuration.sources, tasks: configuration.tasks, accent: configuration.accent)
    }
}

struct ThreeDayAgendaWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: threeDayKind, intent: ThreeDayConfigurationIntent.self, provider: ThreeDayProvider()) {
            ThreeDayAgendaView(entry: $0)
        }
        .contentMarginsDisabled()
        .configurationDisplayName("Three-Day Agenda")
        .description("Tap today, tomorrow, or the next day to see its events and tasks. Tap a circle to complete a task.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct ThreeDayAgendaView: View {
    let entry: AgendaEntry
    private let look = WidgetLook.saved
    @Environment(\.colorScheme) private var colorScheme
    private var accent: (color: Color, onColor: Color, custom: Bool) { entry.theme.widgetAccent(appRGB: entry.accentRGB, chosen: entry.accent) }
    private var muted: Color { entry.theme.secondary(colorScheme) }
    private var days: [Date] {
        let today = Calendar.current.startOfDay(for: entry.date)
        return (0..<3).map { Calendar.current.date(byAdding: .day, value: $0, to: today)! }
    }
    private var rowHeight: CGFloat { look.row(18) }
    private var taskHeight: CGFloat { look.row(19) }
    private var labelHeight: CGFloat { look.row(13) }

    private enum Line: Identifiable {
        case label(String, alert: Bool), event(AgendaItem), task(WidgetTask)
        var id: String {
            switch self {
            case .label(let title, _): "label-\(title)"
            case .event(let item): "event-\(item.id)"
            case .task(let task): "task-\(task.id)"
            }
        }
        var isLabel: Bool { if case .label = self { true } else { false } }
    }
    private func height(_ line: Line) -> CGFloat {
        switch line {
        case .label: labelHeight
        case .event: rowHeight
        case .task: taskHeight
        }
    }

    /// The selected day's events, then its tasks; today also lists overdue and undated tasks.
    private var lines: [Line] {
        let calendar = Calendar.current
        let day = entry.selectedDay
        let events: [Line] = WidgetAgendaLayout.items(on: day, from: entry.items).map { .event($0) }
        guard entry.showTasks else { return events }
        let isToday = calendar.isDate(day, inSameDayAs: entry.date)
        let due = entry.tasks.filter { task in !task.overdue && task.due.map { calendar.isDate($0, inSameDayAs: day) } ?? false }
        let groups: [(String, Bool, [WidgetTask])] = [
            ("OVERDUE", true, isToday ? entry.tasks.filter(\.overdue) : []),
            ("TASKS", false, due),
            ("ANYTIME", false, isToday ? entry.tasks.filter { $0.due == nil } : [])
        ]
        return groups.filter { !$0.2.isEmpty }.reduce(events) { lines, group in
            lines + (look.showSectionLabels ? [.label(group.0, alert: group.1)] : []) + group.2.map { .task($0) }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let lines = self.lines
            let heights = lines.map(height)
            let room = max(0, geometry.size.height - 62)
            let maxStart = WidgetScroll.maxStart(heights, in: room)
            let start = min(max(0, entry.dayPage), maxStart)
            let shown = WidgetScroll.visible(heights, from: start, in: room)
            // Never end on a section label with none of its rows.
            let count = shown > 1 && lines[start + shown - 1].isLabel ? shown - 1 : shown
            let step = WidgetScroll.step(visible: count)
            VStack(alignment: .leading, spacing: 0) {
                dayTabs.padding(.bottom, 7)
                if !entry.connected {
                    Text("Open the app to connect calendars and reminders.").font(.caption).foregroundStyle(muted)
                } else if lines.isEmpty {
                    Text("No items for this day").font(.caption).foregroundStyle(muted).padding(.top, 4)
                } else {
                    ForEach(lines[start..<start + count]) { line($0) }
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    Spacer(minLength: 0)
                    if maxStart > 0 {
                        scrollButton("chevron.up", to: max(0, start - step), enabled: start > 0, label: "Scroll up")
                        scrollButton("chevron.down", to: min(maxStart, start + step), enabled: start < maxStart, label: "Scroll down")
                    }
                    Spacer(minLength: 0)
                }
                // Quick Add, opened on the day selected in this widget.
                .overlay(alignment: .trailing) {
                    if look.showAddButton {
                    Link(destination: URL(string: "lotsofevents://quick-add?day=\(Int(entry.selectedDay.timeIntervalSince1970))")!) {
                        Image(systemName: "plus").font(look.font(12, .semibold)).frame(width: 28, height: 22)
                    }
                    .accessibilityLabel("Add to \(entry.selectedDay.formatted(.dateTime.weekday(.wide)))")
                    }
                }
                .buttonStyle(.plain).foregroundStyle(muted).frame(height: 16)
            }.frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        }
        .padding(12)
        .foregroundStyle(entry.theme.text(colorScheme))
        .containerBackground(for: .widget) { entry.theme.backgroundView(colorScheme) }
        .widgetURL(URL(string: "lotsofevents://agenda"))
    }

    private var dayTabs: some View {
        HStack(spacing: 6) {
            ForEach(days, id: \.self) { day in
                let selected = Calendar.current.isDate(day, inSameDayAs: entry.selectedDay)
                Button(intent: SelectWidgetDayIntent(day: day)) {
                    VStack(spacing: 0) {
                        Text(day.formatted(.dateTime.weekday(.abbreviated)).uppercased()).font(look.font(11, .semibold))
                        Text(day.formatted(.dateTime.day())).font(look.font(19, .medium, theme: entry.theme == .gallery ? .serif : .default))
                    }
                    .offset(y: DayTabMetrics.offset(weekdaySize: 11, weekdayWeight: .semibold, dateSize: 19, dateWeight: .medium))
                    .frame(maxWidth: .infinity).frame(height: 38)
                    // On a custom background the accent can vanish, so unselected days use the readable text color.
                    .foregroundStyle(selected ? accent.onColor : entry.theme == .custom && !accent.custom ? entry.theme.text(colorScheme) : accent.color)
                    .background(selected ? accent.color : .clear, in: RoundedRectangle(cornerRadius: 11))
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(day.formatted(date: .complete, time: .omitted))
                    .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private func scrollButton(_ symbol: String, to offset: Int, enabled: Bool, label: String) -> some View {
        Button(intent: PageDayWidgetIntent(page: offset)) {
            Image(systemName: symbol).font(look.font(11, .semibold)).frame(width: 30, height: 22)
                .background(entry.theme.text(colorScheme).opacity(enabled ? 0.08 : 0), in: Capsule())
        }
        .foregroundStyle(enabled ? entry.theme.text(colorScheme) : muted.opacity(0.4))
        .disabled(!enabled)
        .accessibilityLabel(label)
    }

    @ViewBuilder private func line(_ line: Line) -> some View {
        switch line {
        case .label(let title, let alert):
            Text(title).font(look.font(8, .semibold, theme: entry.theme == .gallery ? .monospaced : .default))
                .foregroundStyle(alert ? .red : muted).frame(height: labelHeight, alignment: .bottomLeading)
        case .event(let item):
            // One line per item, with the start time on the right, so more fit.
            HStack(spacing: 5) {
                if look.showColorBars { RoundedRectangle(cornerRadius: 2).fill(item.color).frame(width: 4, height: 13) }
                Text(item.title).font(look.font(12, .medium)).lineLimit(1)
                Spacer(minLength: 2)
                if !item.allDay && look.showTimes {
                    Text(item.widgetStartLabel).font(look.font(10)).monospacedDigit().lineLimit(1).foregroundStyle(muted)
                }
            }.frame(height: rowHeight)
        case .task(let task):
            HStack(spacing: 2) {
                Button(intent: CompleteWidgetReminderIntent(task: task)) {
                    Image(systemName: "circle").font(look.font(14)).foregroundStyle(task.color).frame(width: 22, height: taskHeight)
                }.buttonStyle(.plain).disabled(!task.writable).accessibilityLabel("Complete \(task.title)")
                Text(task.title).font(look.font(12)).lineLimit(1)
                Spacer(minLength: 2)
                if task.timed && !task.overdue && look.showTimes, let label = task.trailingLabel {
                    Text(label).font(look.font(10)).monospacedDigit().foregroundStyle(muted).lineLimit(1)
                }
            }.frame(height: taskHeight)
        }
    }
}
